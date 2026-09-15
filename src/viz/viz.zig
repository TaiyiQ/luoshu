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
const assembly_mod = @import("assembly");
const circuit_mod = @import("circuit");
const viewmodel = @import("viewmodel");

const common = @import("common.zig");
const circuit_view = @import("circuit.zig");
const schedule_view = @import("schedule.zig");
const logical_view = @import("logical.zig");

const palette = common.palette;
const styleGui = common.styleGui;
const drawPanel = common.drawPanel;
const drawChromeStrip = common.drawChromeStrip;
const drawTextRight = common.drawTextRight;
const Viewport = common.Viewport;
const FONT = common.FONT;
const FONT_LG = common.FONT_LG;
const PAD = common.PAD;
const TAB_H = common.TAB_H;
const TAB_W = common.TAB_W;
const BTN_H = common.BTN_H;
const BAR_H = common.BAR_H;

const CircuitView = circuit_view.CircuitView;
const GUTTER_W = circuit_view.GUTTER_W;
const ScheduleView = schedule_view.ScheduleView;
const LogicalView = logical_view.LogicalView;

const font_ttf = @embedFile("JetBrainsMonoNerdFont-Regular.ttf");

const View = enum(i32) {
    circuit,
    stages,
    logical,
    schedule,

    const count: i32 = @typeInfo(View).@"enum".fields.len;

    // Tab-bar labels for toggleGroup; must match the field order above.
    const labels = "circuit;stages;logical;schedule";

    fn next(v: View) View {
        return switch (v) {
            .circuit => .stages,
            .stages => .logical,
            .logical => .schedule,
            .schedule => .circuit,
        };
    }
};

/// Screen region a view's world fills: the tab bar owns the top, the
/// schedule's transport bar the bottom, and the spec panel (while shown,
/// as `specs_pad`) the schedule's left edge — so fits never put content
/// under chrome.
fn regionFor(view: View, sw: f32, sh: f32, specs_pad: f32) rl.Rectangle {
    return switch (view) {
        .circuit, .stages => .{
            .x = GUTTER_W,
            .y = TAB_H,
            .width = @max(1, sw - GUTTER_W),
            .height = @max(1, sh - TAB_H),
        },
        .logical => .{
            .x = 0,
            .y = TAB_H,
            .width = sw,
            .height = @max(1, sh - TAB_H),
        },
        .schedule => .{
            .x = specs_pad,
            .y = TAB_H,
            .width = @max(1, sw - specs_pad),
            .height = @max(1, sh - TAB_H - BAR_H),
        },
    };
}

const shortcuts = [_]struct { key: [:0]const u8, desc: [:0]const u8 }{
    .{ .key = "1-4", .desc = "switch view" },
    .{ .key = "tab", .desc = "next view" },
    .{ .key = "r", .desc = "refit view (schedule: also rewind)" },
    .{ .key = "wheel", .desc = "zoom at the cursor" },
    .{ .key = "drag", .desc = "pan (schedule: right/middle button only)" },
    .{ .key = "space", .desc = "schedule: play / pause" },
    .{ .key = "j / k", .desc = "schedule: step a frame back / forward" },
    .{ .key = "h", .desc = "schedule: toggle the arch specs" },
    .{ .key = "d", .desc = "schedule: toggle dimension arrows" },
    .{ .key = "esc", .desc = "close edit or help, else quit" },
    .{ .key = "?", .desc = "toggle this help" },
};

/// Centered overlay listing every key binding, toggled with `?`.
fn drawHelp(font: rl.Font, sw: f32, sh: f32) void {
    const row_h: f32 = FONT + 6;
    const key_w: f32 = 130;
    var desc_w: f32 = 0;
    for (shortcuts) |sc| desc_w = @max(desc_w, rl.measureTextEx(font, sc.desc, FONT, 0.5).x);
    const w = key_w + desc_w + 3 * PAD;
    const h = @as(f32, shortcuts.len) * row_h + row_h + 3 * PAD;

    // Dim the world so the panel owns the eye.
    rl.drawRectangleRec(
        .{ .x = 0, .y = 0, .width = sw, .height = sh },
        rl.Color{ .r = 0, .g = 0, .b = 0, .a = 120 },
    );

    const rec = rl.Rectangle{
        .x = (sw - w) / 2,
        .y = (sh - h) / 2,
        .width = w,
        .height = h,
    };
    drawPanel(rec, palette.panel_bg);

    var y = rec.y + PAD;
    rl.drawTextEx(
        font,
        "shortcuts",
        .{ .x = rec.x + PAD, .y = y },
        FONT_LG,
        0.5,
        palette.accent,
    );
    y += row_h + PAD;
    for (shortcuts) |sc| {
        drawTextRight(font, sc.key, rec.x + key_w, y, FONT, palette.accent);
        rl.drawTextEx(
            font,
            sc.desc,
            .{ .x = rec.x + key_w + PAD, .y = y },
            FONT,
            0.5,
            palette.text,
        );
        y += row_h;
    }
}

fn drawTabs(font: rl.Font, view: *View, sw: f32) void {
    drawChromeStrip(0, sw, TAB_H, TAB_H);

    var idx: i32 = @intFromEnum(view.*);
    _ = rg.toggleGroup(
        .{
            .x = PAD,
            .y = (TAB_H - BTN_H) / 2,
            .width = TAB_W,
            .height = BTN_H,
        },
        View.labels,
        &idx,
    );
    view.* = @enumFromInt(std.math.clamp(idx, 0, View.count - 1));

    const hint = "1-4 view   r fit   ? shortcuts";

    drawTextRight(
        font,
        hint,
        sw - PAD,
        (TAB_H - FONT) / 2,
        FONT,
        palette.text_sub,
    );
}

pub fn run(
    gpa: std.mem.Allocator,
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

    rl.setConfigFlags(.{
        .fullscreen_mode = false,
        .window_resizable = true,
        .msaa_4x_hint = true,
        .window_highdpi = true,
    });
    rl.setTraceLogLevel(.err);
    rl.initWindow(1280, 800, "luoshu");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    // Escape is handled manually: it closes a pending frame-box edit first
    // and only quits when nothing is being edited.
    rl.setExitKey(.null);

    const font = rl.loadFontFromMemory(
        ".ttf",
        font_ttf,
        64,
        null,
    ) catch try rl.getFontDefault();
    defer rl.unloadFont(font);
    rl.setTextureFilter(font.texture, .bilinear);

    styleGui(font);

    var flat = CircuitView{ .lay = flat_lay, .show_stages = false };
    var staged = CircuitView{ .lay = staged_lay, .show_stages = true };
    var logical = LogicalView{ .tables = &tables };
    var sched = try ScheduleView.init(
        gpa,
        &s,
        &vm,
        if (asm_doc) |a| a.sites else &.{},
        font,
    );
    defer sched.deinit();

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

        // The spec panel owns the schedule's left edge while shown, so
        // fits (initial, resize, `r`) never put the grid under it.
        const specs_pad: f32 = if (sched.show_specs) sched.specs_w + 2 * PAD else 0;
        const region = regionFor(view, sw, sh, specs_pad);

        if (!fitted or rl.isWindowResized()) {
            if (!flat.vp.touched) flat.fit(regionFor(.circuit, sw, sh, specs_pad));
            if (!staged.vp.touched) staged.fit(regionFor(.stages, sw, sh, specs_pad));
            if (!sched.vp.touched) sched.fit(regionFor(.schedule, sw, sh, specs_pad));
            if (!logical.vp.touched) logical.fit(regionFor(.logical, sw, sh, specs_pad));
            fitted = true;
        }

        const prev_view = view;
        if (!sched.editing) {
            if (rl.isKeyPressed(.one)) view = .circuit;
            if (rl.isKeyPressed(.two)) view = .stages;
            if (rl.isKeyPressed(.three)) view = .logical;
            if (rl.isKeyPressed(.four)) view = .schedule;
            if (rl.isKeyPressed(.tab)) view = view.next();
            if (rl.isKeyPressed(.slash)) show_help = !show_help;

            if (rl.isKeyPressed(.r)) {
                const fr = regionFor(view, sw, sh, specs_pad);
                switch (view) {
                    .circuit => flat.fit(fr),
                    .stages => staged.fit(fr),
                    .logical => logical.fit(fr),
                    .schedule => {
                        sched.fit(fr);
                        sched.seek(0);
                    },
                }
            }

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

        const vp: *Viewport = switch (view) {
            .circuit => &flat.vp,
            .stages => &staged.vp,
            .schedule => &sched.vp,
            .logical => &logical.vp,
        };

        // Pan: right- or middle-drag everywhere; the circuit views take
        // left-drag too (the schedule reserves left for the transport bar).
        const mouse = rl.getMousePosition();
        const in_region = rl.checkCollisionPointRec(mouse, region);
        const pan_press = rl.isMouseButtonPressed(.right) or
            rl.isMouseButtonPressed(.middle) or
            (view != .schedule and rl.isMouseButtonPressed(.left));
        const pan_down = rl.isMouseButtonDown(.right) or
            rl.isMouseButtonDown(.middle) or
            (view != .schedule and rl.isMouseButtonDown(.left));
        if (pan_press and in_region) {
            panning = true;
            last_mouse = mouse;
        }
        if (!pan_down) panning = false;
        if (panning) {
            vp.cam.offset.x -= (mouse.x - last_mouse.x) / vp.cam.zoom;
            vp.cam.offset.y -= (mouse.y - last_mouse.y) / vp.cam.zoom;
            last_mouse = mouse;
            vp.touched = true;
        }

        // Zoom anchored at the cursor: the world point under the mouse
        // stays under the mouse.
        const wheel = rl.getMouseWheelMove();
        if (wheel != 0 and in_region) {
            const before = vp.cam.screenToWorld(mouse);
            vp.cam.zoom *= std.math.clamp(1.0 + wheel * 0.1, 0.5, 2.0);
            vp.cam.offset.x = before.x - mouse.x / vp.cam.zoom;
            vp.cam.offset.y = before.y - mouse.y / vp.cam.zoom;
            vp.touched = true;
        }

        if (view == .schedule) sched.update(dt);

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(palette.bg);

        const draw_region = regionFor(view, sw, sh, specs_pad);
        switch (view) {
            .circuit => flat.draw(font, draw_region),
            .stages => staged.draw(font, draw_region),
            .schedule => {
                sched.drawWorld(font);
                if (!sched.empty()) sched.drawBar(font, sw, sh);
                if (sched.show_specs) sched.drawSpecs(font);
            },
            .logical => logical.draw(font, draw_region),
        }

        drawTabs(font, &view, sw);
        if (show_help) drawHelp(font, sw, sh);
        // Switching away (key or tab click) leaves the frame box mid-edit;
        // drop the edit so 1/2/3 and j/k aren't dead on return.
        if (view != prev_view) sched.editing = false;
    }
}
