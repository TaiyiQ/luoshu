//! Hardware-schedule visualizer built on raygui — the seed of the draw.zig
//! rewrite, selected with `--viz gui`. It replays the same schedule as
//! draw.physical, but the world renderer is deliberately small and every
//! playback control lives in a transport bar along the bottom of the
//! window: scrub slider, exact-frame box, play/pause, and playback speed.
//! Frame numbers are 0-based throughout, matching verify diagnostics.

const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const schedule = @import("schedule");
const arch_mod = @import("arch");
const assembly_mod = @import("assembly");
const viewmodel = @import("viewmodel");

const Point = schedule.Point;
const OpKind = schedule.OpKind;
const ZoneRect = viewmodel.ZoneRect;

const palette = struct {
    pub const bg = rl.Color{ .r = 48, .g = 52, .b = 70, .a = 255 };
    pub const panel_bg = rl.Color{ .r = 36, .g = 39, .b = 58, .a = 255 };
    pub const divider = rl.Color{ .r = 65, .g = 69, .b = 89, .a = 255 };
    pub const text = rl.Color{ .r = 198, .g = 208, .b = 245, .a = 255 };
    pub const text_sub = rl.Color{ .r = 115, .g = 121, .b = 148, .a = 255 };
    pub const accent = rl.Color{ .r = 129, .g = 200, .b = 190, .a = 255 };
    pub const slot_off = rl.Color{ .r = 115, .g = 121, .b = 148, .a = 255 };
    pub const slot_on = rl.Color{ .r = 166, .g = 209, .b = 137, .a = 255 };
    pub const qdot = rl.Color{ .r = 131, .g = 139, .b = 167, .a = 100 };
    pub const zone_storage = rl.Color{ .r = 56, .g = 62, .b = 82, .a = 80 };
    pub const zone_compute = rl.Color{ .r = 46, .g = 70, .b = 66, .a = 90 };
    pub const zone_readout = rl.Color{ .r = 72, .g = 56, .b = 80, .a = 90 };
    pub const zone_active = rl.Color{ .r = 65, .g = 130, .b = 120, .a = 120 };
    pub const zone_border = rl.Color{ .r = 115, .g = 121, .b = 148, .a = 100 };
    pub const op_move = rl.Color{ .r = 129, .g = 200, .b = 190, .a = 255 };
    pub const op_raman = rl.Color{ .r = 244, .g = 184, .b = 228, .a = 255 };
    pub const op_rydberg = rl.Color{ .r = 239, .g = 159, .b = 118, .a = 255 };
    pub const op_load = rl.Color{ .r = 147, .g = 154, .b = 183, .a = 255 };
    pub const op_store = rl.Color{ .r = 231, .g = 130, .b = 132, .a = 255 };
};

fn opFill(op: OpKind) rl.Color {
    return switch (op) {
        .move => palette.op_move,
        .raman, .measure => palette.op_raman,
        .rydberg => palette.op_rydberg,
        .load => palette.op_load,
        .store => palette.op_store,
    };
}

const ATOM_R: f32 = 300.0;
const ATOM_R_LOADED: f32 = 450.0;

// Transport bar layout.
const BAR_H: f32 = 90;
const PAD: f32 = 12;
const BTN_W: f32 = 44;
const BTN_H: f32 = 34;
const ROW2_H: f32 = 24;
const FRAME_BOX_W: f32 = 110;

fn toVec(p: Point) rl.Vector2 {
    return .{ .x = @floatFromInt(p.x), .y = @floatFromInt(p.y) };
}

const BBox = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    fn fromPoints(points: []const Point) BBox {
        if (points.len == 0) return .{ .min_x = -10, .min_y = -10, .max_x = 10, .max_y = 10 };
        var b = BBox{
            .min_x = std.math.floatMax(f32),
            .min_y = std.math.floatMax(f32),
            .max_x = std.math.floatMin(f32),
            .max_y = std.math.floatMin(f32),
        };
        for (points) |p| {
            const v = toVec(p);
            b.min_x = @min(b.min_x, v.x);
            b.min_y = @min(b.min_y, v.y);
            b.max_x = @max(b.max_x, v.x);
            b.max_y = @max(b.max_y, v.y);
        }
        return b;
    }
};

const Camera = struct {
    offset: rl.Vector2 = .{ .x = 0, .y = 0 },
    zoom: f32 = 1.0,

    fn worldToScreen(self: Camera, world: rl.Vector2) rl.Vector2 {
        return .{
            .x = (world.x - self.offset.x) * self.zoom,
            .y = (world.y - self.offset.y) * self.zoom,
        };
    }

    fn screenToWorld(self: Camera, screen: rl.Vector2) rl.Vector2 {
        return .{
            .x = screen.x / self.zoom + self.offset.x,
            .y = screen.y / self.zoom + self.offset.y,
        };
    }

    fn fitToRect(self: *Camera, bbox: BBox, screen_w: f32, screen_h: f32) void {
        const dx = bbox.max_x - bbox.min_x;
        const dy = bbox.max_y - bbox.min_y;
        const pad = @max(dx, dy) * 0.15;
        self.zoom = @min(screen_w / (dx + pad), screen_h / (dy + pad));
        self.offset = .{
            .x = (bbox.min_x + bbox.max_x) / 2 - screen_w / (2 * self.zoom),
            .y = (bbox.min_y + bbox.max_y) / 2 - screen_h / (2 * self.zoom),
        };
    }
};

fn drawZone(cam: Camera, r: ZoneRect, fill: rl.Color) void {
    const tl = cam.worldToScreen(.{ .x = @floatFromInt(r.x0), .y = @floatFromInt(r.y0) });
    const br = cam.worldToScreen(.{ .x = @floatFromInt(r.x1), .y = @floatFromInt(r.y1) });
    const rec = rl.Rectangle{ .x = tl.x, .y = tl.y, .width = br.x - tl.x, .height = br.y - tl.y };
    rl.drawRectangleRounded(rec, 0.06, 8, fill);
    rl.drawRectangleRoundedLinesEx(rec, 0.06, 8, 1.0, palette.zone_border);
}

fn drawSlot(cam: Camera, slot: Point, positions: []const Point, loaded: []const bool, idle: []const Point) void {
    const screen = cam.worldToScreen(toVec(slot));
    const radius = ATOM_R * cam.zoom;

    var occupied = for (positions, 0..) |p, id| {
        if (id < loaded.len and loaded[id]) continue; // in the AOD, not this trap
        if (p.x == slot.x and p.y == slot.y) break true;
    } else false;
    // Idle atoms (delivered but unused) hold their trap in every frame.
    if (!occupied) occupied = for (idle) |p| {
        if (p.x == slot.x and p.y == slot.y) break true;
    } else false;

    if (occupied) {
        rl.drawCircleV(screen, radius, palette.slot_on);
    } else {
        rl.drawCircleLinesV(screen, radius, palette.slot_off);
    }
}

fn drawQubit(cam: Camera, font: rl.Font, pos: Point, id: usize, is_active: bool, is_loaded: bool, fill: rl.Color) void {
    const screen = cam.worldToScreen(toVec(pos));
    const radius = (if (is_loaded) ATOM_R_LOADED else ATOM_R) * cam.zoom;

    rl.drawCircleV(screen, radius, palette.qdot);
    if (is_loaded) rl.drawCircleLinesV(screen, radius * 1.2, palette.accent);

    if (is_active) {
        rl.drawCircleV(screen, radius, fill);
        var buf: [8]u8 = undefined;
        const label = std.fmt.bufPrintSentinel(&buf, "{d}", .{id}, 0) catch "?";
        rl.drawTextEx(font, label, .{ .x = screen.x + radius + 10, .y = screen.y - 12 }, 24, 0.5, palette.text);
    }
}

// raygui reads style colors as 0xRRGGBBAA ints; setting them on .default
// propagates the base properties to every control.
fn styleGui(font: rl.Font) void {
    rg.setFont(font);
    rg.setStyle(.default, .{ .default = .text_size }, 20);
    rg.setStyle(.default, .{ .default = .text_spacing }, 1);
    rg.setStyle(.default, .{ .default = .background_color }, rl.colorToInt(palette.panel_bg));
    rg.setStyle(.default, .{ .default = .line_color }, rl.colorToInt(palette.divider));
    rg.setStyle(.default, .{ .control = .base_color_normal }, rl.colorToInt(palette.bg));
    rg.setStyle(.default, .{ .control = .border_color_normal }, rl.colorToInt(palette.divider));
    rg.setStyle(.default, .{ .control = .text_color_normal }, rl.colorToInt(palette.text));
    rg.setStyle(.default, .{ .control = .base_color_focused }, rl.colorToInt(palette.divider));
    rg.setStyle(.default, .{ .control = .border_color_focused }, rl.colorToInt(palette.accent));
    rg.setStyle(.default, .{ .control = .text_color_focused }, rl.colorToInt(palette.text));
    rg.setStyle(.default, .{ .control = .base_color_pressed }, rl.colorToInt(palette.accent));
    rg.setStyle(.default, .{ .control = .border_color_pressed }, rl.colorToInt(palette.accent));
    rg.setStyle(.default, .{ .control = .text_color_pressed }, rl.colorToInt(palette.bg));
}

pub fn physical(gpa: std.mem.Allocator, layout: arch_mod.ArchConfig, s: schedule.Hardware, asm_doc: ?assembly_mod.Assembly) !void {
    if (s.placement.len == 0 or s.frames.items.len == 0) return;

    // Frames are never empty and never have gaps; frame index == timestep.
    const frame_count = s.frames.items.len;
    const last_frame = frame_count - 1;

    var vm = try viewmodel.ViewModel.init(gpa, &s);
    defer vm.deinit();

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
    rl.initWindow(1280, 800, "Hardware schedule");
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
    const idle = idle_buf.items;

    const bbox = BBox.fromPoints(sites);
    var camera = Camera{};
    camera.fitToRect(
        bbox,
        @floatFromInt(rl.getScreenWidth()),
        @as(f32, @floatFromInt(rl.getScreenHeight())) - BAR_H,
    );

    var frame: usize = 0;
    var playing = false;
    var clock: f32 = 0; // frame-units elapsed at the current frame while playing
    var speed: f32 = 2.5; // playback rate in frames per second
    var frame_box: i32 = 0; // valueBox binding for exact-frame entry
    var editing = false; // the frame box owns the keyboard while true

    var panning = false;
    var last_mouse_pos: rl.Vector2 = undefined;

    var active = try gpa.alloc(bool, s.placement.len);
    defer gpa.free(active);

    var draw_positions = try gpa.alloc(Point, s.placement.len);
    defer gpa.free(draw_positions);

    while (!rl.windowShouldClose()) {
        const dt = rl.getFrameTime();
        const sw: f32 = @floatFromInt(rl.getScreenWidth());
        const sh: f32 = @floatFromInt(rl.getScreenHeight());
        const bar_y = sh - BAR_H;

        // ── Input ──────────────────────────────────────────────────
        if (!editing) {
            if (rl.isKeyPressed(.k) or rl.isKeyPressedRepeat(.k)) {
                playing = false;
                frame = @min(frame + 1, last_frame);
            }
            if (rl.isKeyPressed(.j) or rl.isKeyPressedRepeat(.j)) {
                playing = false;
                if (frame > 0) frame -= 1;
            }
            if (rl.isKeyPressed(.space)) {
                playing = !playing;
                clock = 0;
            }
            if (rl.isKeyPressed(.r)) {
                camera.fitToRect(bbox, sw, sh - BAR_H);
                playing = false;
                clock = 0;
                frame = 0;
            }
        }
        if (rl.isKeyPressed(.escape)) {
            if (editing) editing = false else break;
        }

        const mouse_pos = rl.getMousePosition();
        if (rl.isMouseButtonPressed(.right) and mouse_pos.y < bar_y) {
            panning = true;
            last_mouse_pos = mouse_pos;
        }
        if (rl.isMouseButtonReleased(.right)) panning = false;
        if (panning) {
            camera.offset.x -= (mouse_pos.x - last_mouse_pos.x) / camera.zoom;
            camera.offset.y -= (mouse_pos.y - last_mouse_pos.y) / camera.zoom;
            last_mouse_pos = mouse_pos;
        }

        const wheel = rl.getMouseWheelMove();
        if (wheel != 0 and mouse_pos.y < bar_y) {
            camera.zoom += wheel * 0.05 * camera.zoom;
            const mw = camera.screenToWorld(mouse_pos);
            camera.offset.x = mw.x - mouse_pos.x / camera.zoom;
            camera.offset.y = mw.y - mouse_pos.y / camera.zoom;
        }

        if (playing) {
            clock += dt * speed;
            if (clock >= 1) {
                const steps: usize = @intFromFloat(clock);
                clock -= @floatFromInt(steps);
                frame += steps;
                if (frame >= last_frame) {
                    frame = last_frame;
                    playing = false;
                    clock = 0;
                }
            }
        }

        // Ops executing at this timestep (frames are never empty).
        const frame_ops = s.frames.items[frame].items;
        const primary_op: OpKind = frame_ops[0];
        const accent = opFill(primary_op);
        const loaded = vm.loaded[frame];

        // Active = involved in any op this frame; a rydberg pulse lights up
        // every atom inside the pulsed zone.
        @memset(active, false);
        var rydberg_zone: ?schedule.Zone = null;
        for (frame_ops) |op| switch (op) {
            .move => |m| active[m.qubit] = true,
            .raman => |r| for (r.targets) |t| {
                active[t.qubit] = true;
            },
            .measure => |m| for (m.qubits) |q| {
                active[q] = true;
            },
            .load => |ld| active[ld.qubit] = true,
            .store => |st| active[st.qubit] = true,
            .rydberg => |r| {
                rydberg_zone = r.zone;
                const zr = switch (r.zone) {
                    .storage => storage_rect,
                    .compute => compute_rect,
                    .readout => readout_rect,
                };
                for (vm.positions[frame], 0..) |p, q| {
                    if (p.x >= zr.x0 and p.x <= zr.x1 and
                        p.y >= zr.y0 and p.y <= zr.y1)
                        active[q] = true;
                }
            },
        };

        // Moves animate src -> dest across the first 60% of the frame period.
        @memcpy(draw_positions, vm.positions[frame]);
        const move_t: f32 = if (playing) blk: {
            const lin = @min(clock / 0.6, 1.0);
            break :blk lin * lin * (3.0 - 2.0 * lin); // smoothstep
        } else 1.0;
        if (move_t < 1.0) {
            for (frame_ops) |op| {
                if (op != .move) continue;
                const m = op.move;
                const sv = toVec(m.src);
                const ev = toVec(m.dest);
                draw_positions[m.qubit] = .{
                    .x = @intFromFloat(sv.x + (ev.x - sv.x) * move_t),
                    .y = @intFromFloat(sv.y + (ev.y - sv.y) * move_t),
                };
            }
        }

        // ── Draw world ─────────────────────────────────────────────
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(palette.bg);

        drawZone(camera, storage_rect, if (rydberg_zone == .storage) palette.zone_active else palette.zone_storage);
        drawZone(camera, compute_rect, if (rydberg_zone == .compute) palette.zone_active else palette.zone_compute);
        drawZone(camera, readout_rect, if (rydberg_zone == .readout) palette.zone_active else palette.zone_readout);

        for (sites) |slot| drawSlot(camera, slot, vm.positions[frame], loaded, idle);

        for (frame_ops) |op| {
            if (op != .move) continue;
            const m = op.move;
            rl.drawLineEx(
                camera.worldToScreen(toVec(m.src)),
                camera.worldToScreen(toVec(draw_positions[m.qubit])),
                2.0,
                rl.Color{ .r = accent.r, .g = accent.g, .b = accent.b, .a = 140 },
            );
        }

        for (draw_positions, 0..) |pos, id| {
            const is_loaded = id < loaded.len and loaded[id];
            drawQubit(camera, font, pos, id, id < active.len and active[id], is_loaded, accent);
        }

        // ── Transport bar ──────────────────────────────────────────
        rl.drawRectangleRec(.{ .x = 0, .y = bar_y, .width = sw, .height = BAR_H }, palette.panel_bg);
        rl.drawLineEx(.{ .x = 0, .y = bar_y }, .{ .x = sw, .y = bar_y }, 1.0, palette.divider);

        const row1_y = bar_y + PAD;
        var x: f32 = PAD;
        if (rg.button(.{ .x = x, .y = row1_y, .width = BTN_W, .height = BTN_H }, "|<")) {
            frame = 0;
            playing = false;
            clock = 0;
        }
        x += BTN_W + 6;
        if (rg.button(.{ .x = x, .y = row1_y, .width = BTN_W, .height = BTN_H }, "<")) {
            playing = false;
            if (frame > 0) frame -= 1;
        }
        x += BTN_W + 6;
        if (rg.button(.{ .x = x, .y = row1_y, .width = 2 * BTN_W, .height = BTN_H }, if (playing) "pause" else "play")) {
            playing = !playing;
            clock = 0;
        }
        x += 2 * BTN_W + 6;
        if (rg.button(.{ .x = x, .y = row1_y, .width = BTN_W, .height = BTN_H }, ">")) {
            playing = false;
            frame = @min(frame + 1, last_frame);
        }
        x += BTN_W + PAD;

        // Scrub slider over the whole schedule.
        const slider_w = @max(60, sw - x - FRAME_BOX_W - 2 * PAD);
        var frame_f: f32 = @floatFromInt(frame);
        _ = rg.sliderBar(
            .{ .x = x, .y = row1_y, .width = slider_w, .height = BTN_H },
            null,
            null,
            &frame_f,
            0,
            @floatFromInt(last_frame),
        );
        const scrubbed: usize = @intFromFloat(@round(@max(0, frame_f)));
        if (scrubbed != frame) {
            frame = @min(scrubbed, last_frame);
            playing = false;
            clock = 0;
        }

        // Exact-frame entry: click, type the frame number, enter jumps
        // there. 0-based, so verify's "frame N" pastes in verbatim.
        if (!editing) frame_box = @intCast(frame);
        if (rg.valueBox(
            .{ .x = x + slider_w + PAD, .y = row1_y, .width = FRAME_BOX_W, .height = BTN_H },
            "",
            &frame_box,
            0,
            @intCast(last_frame),
            editing,
        ) != 0) {
            editing = !editing;
            if (!editing) { // committed with enter or a click away
                frame = @min(@as(usize, @intCast(@max(0, frame_box))), last_frame);
                playing = false;
                clock = 0;
            }
        }

        // Row 2: playback speed + status line.
        const row2_y = row1_y + BTN_H + 8;
        var spd_buf: [16]u8 = undefined;
        const spd_txt = std.fmt.bufPrintSentinel(&spd_buf, "{d:.1}/s", .{speed}, 0) catch "?";
        rl.drawTextEx(font, "speed", .{ .x = PAD, .y = row2_y + 2 }, 20, 1, palette.text_sub);
        _ = rg.sliderBar(
            .{ .x = PAD + 70, .y = row2_y, .width = 160, .height = ROW2_H },
            null,
            null,
            &speed,
            0.5,
            60,
        );
        rl.drawTextEx(font, spd_txt, .{ .x = PAD + 240, .y = row2_y + 2 }, 20, 1, palette.text_sub);

        const zone_txt = switch (primary_op) {
            .rydberg => |r| @tagName(r.zone),
            .measure => |m| @tagName(m.zone),
            else => "-",
        };
        var status_buf: [160]u8 = undefined;
        const op_txt = std.fmt.bufPrintSentinel(&status_buf, "{s} @ {s}", .{ @tagName(primary_op), zone_txt }, 0) catch "?";
        const op_w = rl.measureTextEx(font, op_txt, 20, 1).x;
        var counts_buf: [160]u8 = undefined;
        const counts_txt = std.fmt.bufPrintSentinel(
            &counts_buf,
            "  |  frame {d} / {d}  |  move {d}  raman {d}  rydberg {d}  measure {d}",
            .{ frame, last_frame, vm.summary.move, vm.summary.raman, vm.summary.rydberg, vm.summary.measure },
            0,
        ) catch "?";
        const status_x = PAD + 330;
        rl.drawTextEx(font, op_txt, .{ .x = status_x, .y = row2_y + 2 }, 20, 1, accent);
        rl.drawTextEx(font, counts_txt, .{ .x = status_x + op_w, .y = row2_y + 2 }, 20, 1, palette.text_sub);
    }
}
