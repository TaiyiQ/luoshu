//! Single-window raygui visualizer, selected with `--viz gui`. One window
//! hosts all three views as tabs — the flat circuit, the staged circuit,
//! and the hardware schedule — instead of the classic flow of closing one
//! window to reach the next. Every view has its own camera: wheel zooms at
//! the cursor, dragging pans, `r` refits, and the window is resizable.
//! Playback controls for the schedule live in a transport bar along the
//! bottom: scrub slider, exact-frame box, play/pause, and playback speed.
//! Frame numbers are 0-based throughout, matching verify diagnostics.

const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const schedule = @import("schedule");
const arch_mod = @import("arch");
const assembly_mod = @import("assembly");
const circuit_mod = @import("circuit");
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
    pub const wire = rl.Color{ .r = 90, .g = 95, .b = 120, .a = 255 };
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

// Tab bar layout.
const TAB_H: f32 = 46;
const TAB_W: f32 = 110;

// Transport bar layout.
const BAR_H: f32 = 90;
const PAD: f32 = 12;
const BTN_W: f32 = 44;
const BTN_H: f32 = 34;
const ROW2_H: f32 = 24;
const FRAME_BOX_W: f32 = 110;

// Circuit diagram geometry, in world units (the camera maps them to pixels).
const COL_W: f32 = 60;
const WIRE_DY: f32 = 56;
const GATE_BOX: f32 = 40;
const CZ_R: f32 = 8;
const GUTTER_W: f32 = 70;

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

    /// Fit `bbox` into `region`, a screen-space rectangle (so views can
    /// center content between the tab bar and the transport bar).
    fn fitToRegion(self: *Camera, bbox: BBox, region: rl.Rectangle) void {
        const dx = bbox.max_x - bbox.min_x;
        const dy = bbox.max_y - bbox.min_y;
        const pad = @max(@max(dx, dy) * 0.15, 1.0);
        self.zoom = @min(region.width / (dx + pad), region.height / (dy + pad));
        self.offset = .{
            .x = (bbox.min_x + bbox.max_x) / 2 - (region.x + region.width / 2) / self.zoom,
            .y = (bbox.min_y + bbox.max_y) / 2 - (region.y + region.height / 2) / self.zoom,
        };
    }
};

const View = enum(i32) {
    circuit = 0,
    stages = 1,
    schedule = 2,

    fn next(v: View) View {
        return switch (v) {
            .circuit => .stages,
            .stages => .schedule,
            .schedule => .circuit,
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

// ── Circuit views ────────────────────────────────────────────────────────────

/// The flat and staged circuit diagrams: wires and gates laid out in world
/// space (columns from viewmodel.CircuitLayout) behind a pan/zoom camera,
/// with the qubit labels pinned in a left gutter and stage labels pinned
/// along the top so they stay readable wherever the camera is.
const CircuitView = struct {
    lay: viewmodel.CircuitLayout,
    show_stages: bool,
    cam: Camera = .{},
    touched: bool = false,

    fn wireY(q: usize) f32 {
        return @as(f32, @floatFromInt(q)) * WIRE_DY;
    }

    fn colX(col: usize) f32 {
        return (@as(f32, @floatFromInt(col)) + 0.5) * COL_W;
    }

    fn bbox(v: CircuitView) BBox {
        const w: f32 = @as(f32, @floatFromInt(@max(v.lay.n_cols, 1))) * COL_W;
        const h: f32 = @as(f32, @floatFromInt(@max(v.lay.num_qubits, 1) - 1)) * WIRE_DY;
        return .{ .min_x = -COL_W, .min_y = -WIRE_DY, .max_x = w + COL_W, .max_y = h + WIRE_DY };
    }

    fn fit(v: *CircuitView, region: rl.Rectangle) void {
        v.cam.fitToRegion(v.bbox(), region);
        v.touched = false;
    }

    fn draw(v: CircuitView, font: rl.Font, region: rl.Rectangle) void {
        const cam = v.cam;
        const nq = v.lay.num_qubits;
        const content_w: f32 = @as(f32, @floatFromInt(v.lay.n_cols)) * COL_W;

        for (0..nq) |q| {
            const y = wireY(q);
            const a = cam.worldToScreen(.{ .x = -COL_W * 0.5, .y = y });
            const b = cam.worldToScreen(.{ .x = content_w + COL_W * 0.5, .y = y });
            rl.drawLineEx(a, b, 1.0, palette.wire);
        }

        // Stage dividers between the columns of consecutive stages.
        if (v.show_stages) {
            for (v.lay.stage_cols[@min(1, v.lay.stage_cols.len)..]) |sc| {
                const x = @as(f32, @floatFromInt(sc)) * COL_W;
                const a = cam.worldToScreen(.{ .x = x, .y = -WIRE_DY });
                const b = cam.worldToScreen(.{ .x = x, .y = wireY(nq -| 1) + WIRE_DY });
                rl.drawLineEx(a, b, 1.0, palette.divider);
            }
        }

        // Gates. Labels drop out once boxes shrink below legibility, so a
        // zoomed-out overview reads as a clean gate map.
        const box = GATE_BOX * cam.zoom;
        const fs = 22.0 * cam.zoom;
        for (v.lay.laid) |lg| {
            switch (lg.gate) {
                .u => |g| v.drawGateBox(font, lg.col, g.qubit, "U", palette.accent, box, fs),
                .reset => |g| v.drawGateBox(font, lg.col, g.qubit, "R", palette.op_store, box, fs),
                // CZ is symmetric, so both qubits get the filled control dot
                // (dot-and-⊕ would read as a CX).
                .cz => |g| {
                    const x = colX(lg.col);
                    const ca = cam.worldToScreen(.{ .x = x, .y = wireY(g.control) });
                    const cb = cam.worldToScreen(.{ .x = x, .y = wireY(g.target) });
                    rl.drawLineEx(ca, cb, @max(1.0, 2.5 * cam.zoom), palette.op_rydberg);
                    rl.drawCircleV(ca, @max(2.0, CZ_R * cam.zoom), palette.op_rydberg);
                    rl.drawCircleV(cb, @max(2.0, CZ_R * cam.zoom), palette.op_rydberg);
                },
            }
        }

        v.drawGutter(font, region);
        v.drawStageLabels(font, region);
    }

    fn drawGateBox(v: CircuitView, font: rl.Font, col: usize, q: u32, label: [:0]const u8, fill: rl.Color, box: f32, fs: f32) void {
        const c = v.cam.worldToScreen(.{ .x = colX(col), .y = wireY(q) });
        const rec = rl.Rectangle{ .x = c.x - box / 2, .y = c.y - box / 2, .width = box, .height = box };
        rl.drawRectangleRounded(rec, 0.2, 4, fill);
        if (box >= 14) {
            const tw = rl.measureTextEx(font, label, fs, 0).x;
            rl.drawTextEx(font, label, .{ .x = c.x - tw / 2, .y = c.y - fs / 2 }, fs, 0, palette.bg);
        }
    }

    // Qubit labels pinned to a left gutter; at low zoom only every k-th
    // label draws, so a thousand wires don't smear into one column of text.
    fn drawGutter(v: CircuitView, font: rl.Font, region: rl.Rectangle) void {
        rl.drawRectangleRec(.{ .x = 0, .y = region.y, .width = GUTTER_W, .height = region.height }, palette.panel_bg);
        rl.drawLineEx(.{ .x = GUTTER_W, .y = region.y }, .{ .x = GUTTER_W, .y = region.y + region.height }, 1.0, palette.divider);

        const spacing = WIRE_DY * v.cam.zoom;
        if (spacing < 1) return;
        const fs = std.math.clamp(20.0 * v.cam.zoom, 10.0, 24.0);
        const step: usize = if (spacing >= fs + 2) 1 else @intFromFloat(@ceil((fs + 2) / spacing));
        var q: usize = 0;
        while (q < v.lay.num_qubits) : (q += step) {
            const sy = v.cam.worldToScreen(.{ .x = 0, .y = wireY(q) }).y;
            if (sy < region.y + fs / 2 or sy > region.y + region.height) continue;
            var buf: [12]u8 = undefined;
            const label = std.fmt.bufPrintSentinel(&buf, "q{d}", .{q}, 0) catch "?";
            rl.drawTextEx(font, label, .{ .x = 10, .y = sy - fs / 2 }, fs, 0.5, palette.text_sub);
        }
    }

    // Stage labels pinned below the tab bar at each stage's first column.
    fn drawStageLabels(v: CircuitView, font: rl.Font, region: rl.Rectangle) void {
        if (!v.show_stages) return;
        for (v.lay.stage_cols, 0..) |sc, s| {
            const sx = v.cam.worldToScreen(.{ .x = @as(f32, @floatFromInt(sc)) * COL_W, .y = 0 }).x;
            if (sx < GUTTER_W or sx > region.x + region.width) continue;
            var buf: [16]u8 = undefined;
            const label = std.fmt.bufPrintSentinel(&buf, "S{d}", .{s}, 0) catch "?";
            rl.drawTextEx(font, label, .{ .x = sx + 4, .y = region.y + 6 }, 18, 0.5, palette.text_sub);
        }
    }
};

// ── Schedule view ────────────────────────────────────────────────────────────

/// The hardware-schedule replay: playback state, camera, and the scratch
/// buffers the render loop fills each frame. World drawing and the
/// transport bar both live here so run() stays a thin view switcher.
const ScheduleView = struct {
    s: *const schedule.Hardware,
    vm: *const viewmodel.ViewModel,
    storage_rect: ZoneRect,
    compute_rect: ZoneRect,
    readout_rect: ZoneRect,
    sites: []const Point,
    idle: []const Point,
    active: []bool,
    draw_positions: []Point,
    last_frame: usize,

    frame: usize = 0,
    playing: bool = false,
    clock: f32 = 0, // frame-units elapsed at the current frame while playing
    speed: f32 = 2.5, // playback rate in frames per second
    frame_box: i32 = 0, // valueBox binding for exact-frame entry
    editing: bool = false, // the frame box owns the keyboard while true

    cam: Camera = .{},
    touched: bool = false,

    fn empty(v: ScheduleView) bool {
        return v.s.placement.len == 0 or v.s.frames.items.len == 0;
    }

    fn input(v: *ScheduleView) void {
        if (v.empty()) return;
        if (rl.isKeyPressed(.k) or rl.isKeyPressedRepeat(.k)) {
            v.playing = false;
            v.frame = @min(v.frame + 1, v.last_frame);
        }
        if (rl.isKeyPressed(.j) or rl.isKeyPressedRepeat(.j)) {
            v.playing = false;
            if (v.frame > 0) v.frame -= 1;
        }
        if (rl.isKeyPressed(.space)) {
            v.playing = !v.playing;
            v.clock = 0;
        }
    }

    fn update(v: *ScheduleView, dt: f32) void {
        if (!v.playing) return;
        v.clock += dt * v.speed;
        if (v.clock >= 1) {
            const steps: usize = @intFromFloat(v.clock);
            v.clock -= @floatFromInt(steps);
            v.frame += steps;
            if (v.frame >= v.last_frame) {
                v.frame = v.last_frame;
                v.playing = false;
                v.clock = 0;
            }
        }
    }

    fn drawWorld(v: *ScheduleView, font: rl.Font) void {
        if (v.empty()) {
            drawZone(v.cam, v.storage_rect, palette.zone_storage);
            drawZone(v.cam, v.compute_rect, palette.zone_compute);
            drawZone(v.cam, v.readout_rect, palette.zone_readout);
            for (v.sites) |slot| drawSlot(v.cam, slot, &.{}, &.{}, v.idle);
            rl.drawTextEx(font, "empty schedule", .{ .x = PAD, .y = TAB_H + PAD }, 20, 1, palette.text_sub);
            return;
        }

        // Ops executing at this timestep (frames are never empty).
        const frame_ops = v.s.frames.items[v.frame].items;
        const primary_op: OpKind = frame_ops[0];
        const accent = opFill(primary_op);
        const loaded = v.vm.loaded[v.frame];

        // Active = involved in any op this frame; a rydberg pulse lights up
        // every atom inside the pulsed zone.
        @memset(v.active, false);
        var rydberg_zone: ?schedule.Zone = null;
        for (frame_ops) |op| switch (op) {
            .move => |m| v.active[m.qubit] = true,
            .raman => |r| for (r.targets) |t| {
                v.active[t.qubit] = true;
            },
            .measure => |m| for (m.qubits) |q| {
                v.active[q] = true;
            },
            .load => |ld| v.active[ld.qubit] = true,
            .store => |st| v.active[st.qubit] = true,
            .rydberg => |r| {
                rydberg_zone = r.zone;
                const zr = switch (r.zone) {
                    .storage => v.storage_rect,
                    .compute => v.compute_rect,
                    .readout => v.readout_rect,
                };
                for (v.vm.positions[v.frame], 0..) |p, q| {
                    if (p.x >= zr.x0 and p.x <= zr.x1 and
                        p.y >= zr.y0 and p.y <= zr.y1)
                        v.active[q] = true;
                }
            },
        };

        // Moves animate src -> dest across the first 60% of the frame period.
        @memcpy(v.draw_positions, v.vm.positions[v.frame]);
        const move_t: f32 = if (v.playing) blk: {
            const lin = @min(v.clock / 0.6, 1.0);
            break :blk lin * lin * (3.0 - 2.0 * lin); // smoothstep
        } else 1.0;
        if (move_t < 1.0) {
            for (frame_ops) |op| {
                if (op != .move) continue;
                const m = op.move;
                const sv = toVec(m.src);
                const ev = toVec(m.dest);
                v.draw_positions[m.qubit] = .{
                    .x = @intFromFloat(sv.x + (ev.x - sv.x) * move_t),
                    .y = @intFromFloat(sv.y + (ev.y - sv.y) * move_t),
                };
            }
        }

        drawZone(v.cam, v.storage_rect, if (rydberg_zone == .storage) palette.zone_active else palette.zone_storage);
        drawZone(v.cam, v.compute_rect, if (rydberg_zone == .compute) palette.zone_active else palette.zone_compute);
        drawZone(v.cam, v.readout_rect, if (rydberg_zone == .readout) palette.zone_active else palette.zone_readout);

        for (v.sites) |slot| drawSlot(v.cam, slot, v.vm.positions[v.frame], loaded, v.idle);

        for (frame_ops) |op| {
            if (op != .move) continue;
            const m = op.move;
            rl.drawLineEx(
                v.cam.worldToScreen(toVec(m.src)),
                v.cam.worldToScreen(toVec(v.draw_positions[m.qubit])),
                2.0,
                rl.Color{ .r = accent.r, .g = accent.g, .b = accent.b, .a = 140 },
            );
        }

        for (v.draw_positions, 0..) |pos, id| {
            const is_loaded = id < loaded.len and loaded[id];
            drawQubit(v.cam, font, pos, id, id < v.active.len and v.active[id], is_loaded, accent);
        }
    }

    fn drawBar(v: *ScheduleView, font: rl.Font, sw: f32, sh: f32) void {
        const bar_y = sh - BAR_H;
        rl.drawRectangleRec(.{ .x = 0, .y = bar_y, .width = sw, .height = BAR_H }, palette.panel_bg);
        rl.drawLineEx(.{ .x = 0, .y = bar_y }, .{ .x = sw, .y = bar_y }, 1.0, palette.divider);

        const row1_y = bar_y + PAD;
        var x: f32 = PAD;
        if (rg.button(.{ .x = x, .y = row1_y, .width = BTN_W, .height = BTN_H }, "|<")) {
            v.frame = 0;
            v.playing = false;
            v.clock = 0;
        }
        x += BTN_W + 6;
        if (rg.button(.{ .x = x, .y = row1_y, .width = BTN_W, .height = BTN_H }, "<")) {
            v.playing = false;
            if (v.frame > 0) v.frame -= 1;
        }
        x += BTN_W + 6;
        if (rg.button(.{ .x = x, .y = row1_y, .width = 2 * BTN_W, .height = BTN_H }, if (v.playing) "pause" else "play")) {
            v.playing = !v.playing;
            v.clock = 0;
        }
        x += 2 * BTN_W + 6;
        if (rg.button(.{ .x = x, .y = row1_y, .width = BTN_W, .height = BTN_H }, ">")) {
            v.playing = false;
            v.frame = @min(v.frame + 1, v.last_frame);
        }
        x += BTN_W + PAD;

        // Scrub slider over the whole schedule.
        const slider_w = @max(60, sw - x - FRAME_BOX_W - 2 * PAD);
        var frame_f: f32 = @floatFromInt(v.frame);
        _ = rg.sliderBar(
            .{ .x = x, .y = row1_y, .width = slider_w, .height = BTN_H },
            null,
            null,
            &frame_f,
            0,
            @floatFromInt(@max(v.last_frame, 1)),
        );
        const scrubbed: usize = @intFromFloat(@round(@max(0, frame_f)));
        if (scrubbed != v.frame) {
            v.frame = @min(scrubbed, v.last_frame);
            v.playing = false;
            v.clock = 0;
        }

        // Exact-frame entry: click, type the frame number, enter jumps
        // there. 0-based, so verify's "frame N" pastes in verbatim.
        if (!v.editing) v.frame_box = @intCast(v.frame);
        if (rg.valueBox(
            .{ .x = x + slider_w + PAD, .y = row1_y, .width = FRAME_BOX_W, .height = BTN_H },
            "",
            &v.frame_box,
            0,
            @intCast(v.last_frame),
            v.editing,
        ) != 0) {
            v.editing = !v.editing;
            if (!v.editing) { // committed with enter or a click away
                v.frame = @min(@as(usize, @intCast(@max(0, v.frame_box))), v.last_frame);
                v.playing = false;
                v.clock = 0;
            }
        }

        // Row 2: playback speed + status line.
        const row2_y = row1_y + BTN_H + 8;
        var spd_buf: [16]u8 = undefined;
        const spd_txt = std.fmt.bufPrintSentinel(&spd_buf, "{d:.1}/s", .{v.speed}, 0) catch "?";
        rl.drawTextEx(font, "speed", .{ .x = PAD, .y = row2_y + 2 }, 20, 1, palette.text_sub);
        _ = rg.sliderBar(
            .{ .x = PAD + 70, .y = row2_y, .width = 160, .height = ROW2_H },
            null,
            null,
            &v.speed,
            0.5,
            60,
        );
        rl.drawTextEx(font, spd_txt, .{ .x = PAD + 240, .y = row2_y + 2 }, 20, 1, palette.text_sub);

        const frame_ops = v.s.frames.items[v.frame].items;
        const primary_op: OpKind = frame_ops[0];
        const accent = opFill(primary_op);
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
            .{ v.frame, v.last_frame, v.vm.summary.move, v.vm.summary.raman, v.vm.summary.rydberg, v.vm.summary.measure },
            0,
        ) catch "?";
        const status_x = PAD + 330;
        rl.drawTextEx(font, op_txt, .{ .x = status_x, .y = row2_y + 2 }, 20, 1, accent);
        rl.drawTextEx(font, counts_txt, .{ .x = status_x + op_w, .y = row2_y + 2 }, 20, 1, palette.text_sub);
    }
};

// ── Tab bar + entry point ────────────────────────────────────────────────────

fn drawTabs(font: rl.Font, view: *View, sw: f32) void {
    rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = sw, .height = TAB_H }, palette.panel_bg);
    rl.drawLineEx(.{ .x = 0, .y = TAB_H }, .{ .x = sw, .y = TAB_H }, 1.0, palette.divider);

    var idx: i32 = @intFromEnum(view.*);
    _ = rg.toggleGroup(
        .{ .x = PAD, .y = (TAB_H - BTN_H) / 2, .width = TAB_W, .height = BTN_H },
        "circuit;stages;schedule",
        &idx,
    );
    view.* = @enumFromInt(std.math.clamp(idx, 0, 2));

    const hint = "1/2/3 view   wheel zoom   drag pan   r fit";
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
    const sched_bbox = BBox.fromPoints(sites);

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
    var sched = ScheduleView{
        .s = &s,
        .vm = &vm,
        .storage_rect = storage_rect,
        .compute_rect = compute_rect,
        .readout_rect = readout_rect,
        .sites = sites,
        .idle = idle_buf.items,
        .active = active,
        .draw_positions = draw_positions,
        .last_frame = s.frames.items.len -| 1,
    };

    var view: View = .circuit;
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
        const sched_region = rl.Rectangle{ .x = 0, .y = TAB_H, .width = sw, .height = @max(1, sh - TAB_H - BAR_H) };
        const region = if (view == .schedule) sched_region else circuit_region;

        if (!fitted or rl.isWindowResized()) {
            if (!flat.touched) flat.fit(circuit_region);
            if (!staged.touched) staged.fit(circuit_region);
            if (!sched.touched) sched.cam.fitToRegion(sched_bbox, sched_region);
            fitted = true;
        }

        // ── Input ──────────────────────────────────────────────────
        if (!sched.editing) {
            if (rl.isKeyPressed(.one)) view = .circuit;
            if (rl.isKeyPressed(.two)) view = .stages;
            if (rl.isKeyPressed(.three)) view = .schedule;
            if (rl.isKeyPressed(.tab)) view = view.next();

            if (rl.isKeyPressed(.r)) switch (view) {
                .circuit => flat.fit(circuit_region),
                .stages => staged.fit(circuit_region),
                .schedule => {
                    sched.cam.fitToRegion(sched_bbox, sched_region);
                    sched.touched = false;
                    sched.frame = 0;
                    sched.playing = false;
                    sched.clock = 0;
                },
            };

            if (view == .schedule) sched.input();
        }
        if (rl.isKeyPressed(.escape)) {
            if (sched.editing) sched.editing = false else break;
        }

        const cam: *Camera, const touched: *bool = switch (view) {
            .circuit => .{ &flat.cam, &flat.touched },
            .stages => .{ &staged.cam, &staged.touched },
            .schedule => .{ &sched.cam, &sched.touched },
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
            },
        }

        drawTabs(font, &view, sw);
        // A click on another tab leaves the frame box mid-edit; drop the
        // edit so 1/2/3 and j/k aren't dead on return.
        if (view != .schedule) sched.editing = false;
    }
}
