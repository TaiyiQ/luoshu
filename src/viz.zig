//! Single-window raygui visualizer. One window hosts every view as a
//! tab — the flat circuit, the staged circuit, the logical routing
//! tables, and the hardware schedule. Every view has its own camera:
//! wheel zooms at the cursor, dragging pans, `r` refits, and the window
//! is resizable. Playback controls for the schedule live in a transport
//! bar along the bottom: scrub slider, exact-frame box, play/pause, and
//! playback speed. Frame numbers are 0-based throughout, matching
//! verify diagnostics.
//!
//! Each view lives in its own file under `viz/`; this root owns the
//! window, the tab bar, the shared pan/zoom input, and the help overlay.

const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const schedule = @import("schedule");
const arch_mod = @import("arch");
const assembly_mod = @import("assembly");
const circuit_mod = @import("circuit");
const viewmodel = @import("viewmodel");

const common = @import("viz/common.zig");
const circuit_view = @import("viz/circuit_view.zig");
const schedule_view = @import("viz/schedule_view.zig");
const logical_view = @import("viz/logical_view.zig");

const palette = common.palette;
const styleGui = common.styleGui;
const Camera = common.Camera;
const PAD = common.PAD;
const TAB_H = common.TAB_H;
const TAB_W = common.TAB_W;
const BTN_H = common.BTN_H;
const BAR_H = common.BAR_H;

const CircuitView = circuit_view.CircuitView;
const GUTTER_W = circuit_view.GUTTER_W;
const ScheduleView = schedule_view.ScheduleView;
const SpecSheet = schedule_view.SpecSheet;
const LogicalView = logical_view.LogicalView;

const Point = schedule.Point;

const View = enum(i32) {
    circuit,
    stages,
    logical,
    schedule,

    fn next(v: View) View {
        return switch (v) {
            .circuit => .stages,
            .stages => .logical,
            .logical => .schedule,
            .schedule => .circuit,
        };
    }
};

// ── Shortcut help ────────────────────────────────────────────────────────────

const shortcuts = [_]struct { key: [:0]const u8, desc: [:0]const u8 }{
    .{ .key = "1-4", .desc = "switch view" },
    .{ .key = "tab", .desc = "next view" },
    .{ .key = "r", .desc = "refit view (schedule: also rewind)" },
    .{ .key = "wheel", .desc = "zoom at the cursor" },
    .{ .key = "drag", .desc = "pan (schedule: right/middle button only)" },
    .{ .key = "space", .desc = "schedule: play / pause" },
    .{ .key = "j / k", .desc = "schedule: step a frame back / forward" },
    .{ .key = "h", .desc = "schedule: toggle the arch specs" },
    .{ .key = "esc", .desc = "close edit or help, else quit" },
    .{ .key = "?", .desc = "toggle this help" },
};

/// Centered overlay listing every key binding, toggled with `?`.
fn drawHelp(font: rl.Font, sw: f32, sh: f32) void {
    const row_h: f32 = 26;
    const key_w: f32 = 110;
    var desc_w: f32 = 0;
    for (shortcuts) |sc| desc_w = @max(desc_w, rl.measureTextEx(font, sc.desc, 18, 0.5).x);
    const w = key_w + desc_w + 3 * PAD;
    const h = @as(f32, shortcuts.len) * row_h + row_h + 3 * PAD;

    // Dim the world so the panel owns the eye.
    rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = sw, .height = sh }, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 120 });

    const rec = rl.Rectangle{ .x = (sw - w) / 2, .y = (sh - h) / 2, .width = w, .height = h };
    rl.drawRectangleRounded(rec, 0.04, 6, palette.panel_bg);
    rl.drawRectangleRoundedLinesEx(rec, 0.04, 6, 1.0, palette.divider);

    var y = rec.y + PAD;
    rl.drawTextEx(font, "shortcuts", .{ .x = rec.x + PAD, .y = y }, 20, 0.5, palette.accent);
    y += row_h + PAD;
    for (shortcuts) |sc| {
        const kw = rl.measureTextEx(font, sc.key, 18, 0.5).x;
        rl.drawTextEx(font, sc.key, .{ .x = rec.x + key_w - kw, .y = y }, 18, 0.5, palette.accent);
        rl.drawTextEx(font, sc.desc, .{ .x = rec.x + key_w + PAD, .y = y }, 18, 0.5, palette.text);
        y += row_h;
    }
}

// ── Tab bar + entry point ────────────────────────────────────────────────────

fn drawTabs(font: rl.Font, view: *View, sw: f32) void {
    rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = sw, .height = TAB_H }, palette.panel_bg);
    rl.drawLineEx(.{ .x = 0, .y = TAB_H }, .{ .x = sw, .y = TAB_H }, 1.0, palette.divider);

    var idx: i32 = @intFromEnum(view.*);
    _ = rg.toggleGroup(
        .{ .x = PAD, .y = (TAB_H - BTN_H) / 2, .width = TAB_W, .height = BTN_H },
        "circuit;stages;logical;schedule",
        &idx,
    );
    view.* = @enumFromInt(std.math.clamp(idx, 0, 3));

    const hint = "1-4 view   r fit   ? shortcuts";
    const tw = rl.measureTextEx(font, hint, 16, 0.5).x;
    rl.drawTextEx(font, hint, .{ .x = sw - tw - PAD, .y = (TAB_H - 16) / 2 }, 16, 0.5, palette.text_sub);
}

pub fn run(
    gpa: std.mem.Allocator,
    layout: arch_mod.ArchConfig,
    s: schedule.Hardware,
    asm_doc: ?assembly_mod.Assembly,
    circ: circuit_mod.Circuit,
    pipe: circuit_mod.Pipeline,
) !void {
    var vm = try viewmodel.ViewModel.init(gpa, &s);
    defer vm.deinit();

    var flat_lay = try viewmodel.CircuitLayout.init(gpa, circ, null);
    defer flat_lay.deinit();

    var staged_lay = try viewmodel.CircuitLayout.init(gpa, circ, pipe);
    defer staged_lay.deinit();

    var tables = try viewmodel.SlotTables.init(gpa, &pipe);
    defer tables.deinit();

    // Zone rects in world-space (nm).
    const sz = layout.storage_zone;
    const storage_rect = viewmodel.slmZoneRect(sz.offset_nm[0], sz.offset_nm[1], sz.slm);

    const ez = layout.compute_zone;
    var compute_rect = viewmodel.slmZoneRect(ez.offset_nm[0], ez.offset_nm[1], ez.slms[0]);
    for (ez.slms[1..]) |slm| {
        const r = viewmodel.slmZoneRect(ez.offset_nm[0], ez.offset_nm[1], slm);
        compute_rect.x0 = @min(compute_rect.x0, r.x0);
        compute_rect.y0 = @min(compute_rect.y0, r.y0);
        compute_rect.x1 = @max(compute_rect.x1, r.x1);
        compute_rect.y1 = @max(compute_rect.y1, r.y1);
    }

    const rz = layout.readout_zone;
    const readout_rect = viewmodel.slmZoneRect(rz.offset_nm[0], rz.offset_nm[1], rz.slm);

    rl.setConfigFlags(.{
        .fullscreen_mode = false,
        .window_resizable = true,
        .msaa_4x_hint = true,
        .window_highdpi = true,
    });
    rl.setTraceLogLevel(.err);
    rl.initWindow(1280, 800, "gatecomp");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    // Escape is handled manually: it closes a pending frame-box edit first
    // and only quits when nothing is being edited.
    rl.setExitKey(.null);

    const font = rl.loadFontEx(
        "./asset/JetBrainsMonoNerdFont-Regular.ttf",
        64,
        null,
    ) catch try rl.getFontDefault();
    defer rl.unloadFont(font);
    rl.setTextureFilter(font.texture, .bilinear);

    styleGui(font);

    const sites = try viewmodel.allSlmSites(gpa, layout);
    defer gpa.free(sites);

    var idle_buf: std.ArrayList(Point) = .empty;
    defer idle_buf.deinit(gpa);
    if (asm_doc) |a| {
        const grid = layout.storage_zone.grid();
        for (a.sites[vm.num_qubits..]) |site| {
            try idle_buf.append(gpa, .{ .x = grid.x(site.col), .y = grid.y(site.row) });
        }
    }

    const active = try gpa.alloc(bool, s.placement.len);
    defer gpa.free(active);
    const draw_positions = try gpa.alloc(Point, s.placement.len);
    defer gpa.free(draw_positions);

    var flat = CircuitView{ .lay = flat_lay, .show_stages = false };
    var staged = CircuitView{ .lay = staged_lay, .show_stages = true };
    var logical = LogicalView{ .tables = &tables };

    var spec_arena = std.heap.ArenaAllocator.init(gpa);
    defer spec_arena.deinit();
    const specs = try SpecSheet.build(spec_arena.allocator(), layout);
    var sched = ScheduleView{
        .s = &s,
        .vm = &vm,
        .specs = specs,
        .specs_w = specs.width(font),
        .storage_rect = storage_rect,
        .compute_rect = compute_rect,
        .readout_rect = readout_rect,
        .sites = sites,
        .idle = idle_buf.items,
        .active = active,
        .draw_positions = draw_positions,
        .last_frame = s.frames.items.len -| 1,
        .db_nm = layout.constraints.db_nm,
    };

    var view: View = .circuit;
    var show_help = false;
    var panning = false;
    var last_mouse: rl.Vector2 = undefined;
    // The initial fit happens inside the loop, once the window reports its
    // real (highdpi-scaled) size.
    var fitted = false;

    while (!rl.windowShouldClose()) {
        const dt = rl.getFrameTime();
        const sw: f32 = @floatFromInt(rl.getScreenWidth());
        const sh: f32 = @floatFromInt(rl.getScreenHeight());

        // Screen regions: the tab bar owns the top; the schedule's
        // transport bar owns the bottom; each view's world fills the rest.
        const circuit_region = rl.Rectangle{ .x = GUTTER_W, .y = TAB_H, .width = @max(1, sw - GUTTER_W), .height = @max(1, sh - TAB_H) };
        // The spec panel owns the schedule's left edge while shown, so
        // fits (initial, resize, `r`) never put the grid under it.
        const specs_pad: f32 = if (sched.show_specs) sched.specs_w + 2 * PAD else 0;
        const sched_region = rl.Rectangle{ .x = specs_pad, .y = TAB_H, .width = @max(1, sw - specs_pad), .height = @max(1, sh - TAB_H - BAR_H) };
        const logical_region = rl.Rectangle{ .x = 0, .y = TAB_H, .width = sw, .height = @max(1, sh - TAB_H) };
        const region = switch (view) {
            .circuit, .stages => circuit_region,
            .schedule => sched_region,
            .logical => logical_region,
        };

        if (!fitted or rl.isWindowResized()) {
            if (!flat.touched) flat.fit(circuit_region);
            if (!staged.touched) staged.fit(circuit_region);
            if (!sched.touched) sched.fit(sched_region);
            if (!logical.touched) logical.fit(logical_region);
            fitted = true;
        }

        // ── Input ──────────────────────────────────────────────────
        if (!sched.editing) {
            if (rl.isKeyPressed(.one)) view = .circuit;
            if (rl.isKeyPressed(.two)) view = .stages;
            if (rl.isKeyPressed(.three)) view = .logical;
            if (rl.isKeyPressed(.four)) view = .schedule;
            if (rl.isKeyPressed(.tab)) view = view.next();
            if (rl.isKeyPressed(.slash)) show_help = !show_help;

            if (rl.isKeyPressed(.r)) switch (view) {
                .circuit => flat.fit(circuit_region),
                .stages => staged.fit(circuit_region),
                .schedule => {
                    sched.fit(sched_region);
                    sched.seek(0);
                },
                .logical => logical.fit(logical_region),
            };

            if (view == .schedule) {
                sched.input();
                // Toggling the panel resizes the world's region; the fit
                // block picks up the new region next frame (untouched
                // cameras only, as on a window resize).
                if (rl.isKeyPressed(.h)) {
                    sched.show_specs = !sched.show_specs;
                    fitted = false;
                }
            }
        }
        if (rl.isKeyPressed(.escape)) {
            if (sched.editing) {
                sched.editing = false;
            } else if (show_help) {
                show_help = false;
            } else break;
        }

        const cam: *Camera, const touched: *bool = switch (view) {
            .circuit => .{ &flat.cam, &flat.touched },
            .stages => .{ &staged.cam, &staged.touched },
            .schedule => .{ &sched.cam, &sched.touched },
            .logical => .{ &logical.cam, &logical.touched },
        };

        // Pan: right- or middle-drag everywhere; the circuit views take
        // left-drag too (the schedule reserves left for the transport bar).
        const mouse = rl.getMousePosition();
        const in_region = rl.checkCollisionPointRec(mouse, region);
        const pan_press = rl.isMouseButtonPressed(.right) or rl.isMouseButtonPressed(.middle) or
            (view != .schedule and rl.isMouseButtonPressed(.left));
        const pan_down = rl.isMouseButtonDown(.right) or rl.isMouseButtonDown(.middle) or
            (view != .schedule and rl.isMouseButtonDown(.left));
        if (pan_press and in_region) {
            panning = true;
            last_mouse = mouse;
        }
        if (!pan_down) panning = false;
        if (panning) {
            cam.offset.x -= (mouse.x - last_mouse.x) / cam.zoom;
            cam.offset.y -= (mouse.y - last_mouse.y) / cam.zoom;
            last_mouse = mouse;
            touched.* = true;
        }

        // Zoom anchored at the cursor: the world point under the mouse
        // stays under the mouse.
        const wheel = rl.getMouseWheelMove();
        if (wheel != 0 and in_region) {
            const before = cam.screenToWorld(mouse);
            cam.zoom *= std.math.clamp(1.0 + wheel * 0.1, 0.5, 2.0);
            cam.offset.x = before.x - mouse.x / cam.zoom;
            cam.offset.y = before.y - mouse.y / cam.zoom;
            touched.* = true;
        }

        if (view == .schedule) sched.update(dt);

        // ── Draw ───────────────────────────────────────────────────
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(palette.bg);

        switch (view) {
            .circuit => flat.draw(font, circuit_region),
            .stages => staged.draw(font, circuit_region),
            .schedule => {
                sched.drawWorld(font);
                if (!sched.empty()) sched.drawBar(font, sw, sh);
                if (sched.show_specs) sched.drawSpecs(font);
            },
            .logical => logical.draw(font, logical_region),
        }

        drawTabs(font, &view, sw);
        if (show_help) drawHelp(font, sw, sh);
        // A click on another tab leaves the frame box mid-edit; drop the
        // edit so 1/2/3 and j/k aren't dead on return.
        if (view != .schedule) sched.editing = false;
    }
}
