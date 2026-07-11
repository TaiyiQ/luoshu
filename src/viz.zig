//! Single-window raygui visualizer, selected with `--viz gui`. One window
//! hosts every view as a tab — the flat circuit, the staged circuit, the
//! hardware schedule, and the logical routing tables — instead of the
//! classic flow of closing one window to reach the next. Every view has
//! its own camera: wheel zooms at
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
    logical = 3,

    fn next(v: View) View {
        return switch (v) {
            .circuit => .stages,
            .stages => .schedule,
            .schedule => .logical,
            .logical => .circuit,
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

/// Row/column crosshair for atoms riding the AOD. The bands span the full
/// screen; the tab and transport bars paint over them afterwards.
fn drawAodHighlight(cam: Camera, positions: []const Point, loaded: []const bool, frame_ops: []const OpKind) void {
    const fill = rl.Color{ .r = palette.accent.r, .g = palette.accent.g, .b = palette.accent.b, .a = 15 };
    const edge = rl.Color{ .r = palette.accent.r, .g = palette.accent.g, .b = palette.accent.b, .a = 55 };
    const hw = ATOM_R * cam.zoom;
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());

    for (positions, 0..) |pos, id| {
        if (id >= loaded.len or !loaded[id]) continue;
        const s = cam.worldToScreen(toVec(pos));

        // Horizontal row — visible while the atom is in the AOD (disappears on store).
        rl.drawRectangleV(.{ .x = 0, .y = s.y - hw }, .{ .x = sw, .y = 2.0 * hw }, fill);
        rl.drawLineEx(.{ .x = 0, .y = s.y }, .{ .x = sw, .y = s.y }, 1.0, edge);

        // Vertical column — only at the timestep this atom is loaded (picked up).
        const being_loaded = for (frame_ops) |op| {
            if (op == .load and op.load.qubit == @as(u32, @intCast(id))) break true;
        } else false;
        if (being_loaded) {
            rl.drawRectangleV(.{ .x = s.x - hw, .y = 0 }, .{ .x = 2.0 * hw, .y = sh }, fill);
            rl.drawLineEx(.{ .x = s.x, .y = 0 }, .{ .x = s.x, .y = sh }, 1.0, edge);
        }
    }
}

/// Halo enclosing a pair of atoms sitting within the blockade radius during
/// a rydberg pulse — the pairs that actually entangle.
fn drawPairHalo(cam: Camera, a: Point, b: Point, color: rl.Color) void {
    const sa = cam.worldToScreen(toVec(a));
    const sb = cam.worldToScreen(toVec(b));
    const base_r = ATOM_R * cam.zoom;
    const center = rl.Vector2{ .x = (sa.x + sb.x) / 2.0, .y = (sa.y + sb.y) / 2.0 };
    const dx = sb.x - sa.x;
    const dy = sb.y - sa.y;
    const r = @sqrt(dx * dx + dy * dy) / 2.0 + base_r * 1.8;

    rl.drawCircleV(center, r, rl.Color{ .r = color.r, .g = color.g, .b = color.b, .a = 12 });
    rl.drawCircleLinesV(center, r, rl.Color{ .r = color.r, .g = color.g, .b = color.b, .a = 90 });
    rl.drawCircleLinesV(center, r + 2.0, rl.Color{ .r = color.r, .g = color.g, .b = color.b, .a = 40 });
    rl.drawCircleLinesV(center, r + 4.0, rl.Color{ .r = color.r, .g = color.g, .b = color.b, .a = 15 });
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
    specs: SpecSheet,
    specs_w: f32,
    storage_rect: ZoneRect,
    compute_rect: ZoneRect,
    readout_rect: ZoneRect,
    sites: []const Point,
    idle: []const Point,
    active: []bool,
    draw_positions: []Point,
    last_frame: usize,
    db_nm: u32,
    show_specs: bool = true,

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

        drawAodHighlight(v.cam, v.draw_positions, loaded, frame_ops);

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

        // Halo every active pair within the blockade radius of the pulse.
        if (rydberg_zone != null) {
            const db: i64 = v.db_nm;
            const db2 = db * db;
            for (v.draw_positions[0..v.vm.num_qubits], 0..) |pa, ia| {
                if (!v.active[ia]) continue;
                for (v.draw_positions[0..v.vm.num_qubits], 0..) |pb, ib| {
                    if (ib <= ia or !v.active[ib]) continue;
                    const dx: i64 = @as(i64, pa.x) - @as(i64, pb.x);
                    const dy: i64 = @as(i64, pa.y) - @as(i64, pb.y);
                    if (dx * dx + dy * dy <= db2) drawPairHalo(v.cam, pa, pb, palette.op_rydberg);
                }
            }
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

    /// Architecture spec sheet, toggled with `h`: the geometry and
    /// constraint numbers behind the picture, pinned top-left. The panel
    /// is sized from the measured text (specs_w), and the schedule's fit
    /// region starts past it, so neither the text nor the grid ever sits
    /// under it.
    fn drawSpecs(v: ScheduleView, font: rl.Font) void {
        const row_h: f32 = 24;
        const h = @as(f32, spec_keys.len) * row_h + 2 * PAD + row_h + 8;

        const rec = rl.Rectangle{ .x = PAD, .y = TAB_H + PAD, .width = v.specs_w, .height = h };
        rl.drawRectangleRounded(rec, 0.06, 6, rl.Color{
            .r = palette.panel_bg.r,
            .g = palette.panel_bg.g,
            .b = palette.panel_bg.b,
            .a = 235,
        });
        rl.drawRectangleRoundedLinesEx(rec, 0.06, 6, 1.0, palette.divider);

        var y = TAB_H + 2 * PAD;
        rl.drawTextEx(font, v.specs.title(), .{ .x = 2 * PAD, .y = y }, 20, 0.5, palette.accent);
        y += row_h + 8;

        for (spec_keys, 0..) |key, i| {
            rl.drawTextEx(font, key, .{ .x = 2 * PAD, .y = y }, 18, 0.5, palette.text_sub);
            rl.drawTextEx(font, v.specs.val(i), .{ .x = PAD + SPEC_VAL_X, .y = y }, 18, 0.5, palette.text);
            y += row_h;
        }
    }
};

// ── Arch spec sheet ──────────────────────────────────────────────────────────

const SPEC_VAL_X: f32 = 180; // value column offset from the panel's left edge

const spec_keys = [_][:0]const u8{
    "aod grid",
    "aod sep",
    "storage slm",
    "compute slm",
    "compute dr/dw",
    "readout slm",
    "blockade db",
    "zone gap dz",
    "fidelity 1q/2q",
    "fidelity readout",
};

/// The spec sheet's text, formatted once at startup (the arch config never
/// changes mid-run) so the panel can be sized to the measured strings.
/// Values live in fixed buffers with recorded lengths — no slices — so the
/// struct copies safely into ScheduleView.
const SpecSheet = struct {
    title_buf: [64]u8,
    title_len: usize,
    bufs: [spec_keys.len][96]u8,
    lens: [spec_keys.len]usize,

    fn build(cfg: arch_mod.ArchConfig) SpecSheet {
        var s: SpecSheet = undefined;
        s.title_len = fmtInto(&s.title_buf, "{s}  v{s}", .{ cfg.platform.name, cfg.platform.version });

        const aod = cfg.aod;
        const st = cfg.storage_zone.slm;
        const cz = cfg.compute_zone;
        const c0 = cz.slms[0];
        const ro = cfg.readout_zone.slm;
        const con = cfg.constraints;

        s.lens[0] = fmtInto(&s.bufs[0], "{d} x {d} max", .{ aod.max_num_row, aod.max_num_col });
        s.lens[1] = fmtInto(&s.bufs[1], ">= {d:.1} um", .{um(aod.min_sep_nm)});
        s.lens[2] = fmtInto(&s.bufs[2], "{d} x {d}  @ {d:.1} x {d:.1} um", .{ st.num_row, st.num_col, um(st.sep_nm[0]), um(st.sep_nm[1]) });
        s.lens[3] = fmtInto(&s.bufs[3], "{d} x ({d} x {d})  @ {d:.1} x {d:.1} um", .{ cz.slms.len, c0.num_row, c0.num_col, um(c0.sep_nm[0]), um(c0.sep_nm[1]) });
        s.lens[4] = fmtInto(&s.bufs[4], "{d:.1} / {d:.1} um", .{ um(cz.dr_nm), um(cz.dw_nm) });
        s.lens[5] = fmtInto(&s.bufs[5], "{d} x {d}", .{ ro.num_row, ro.num_col });
        s.lens[6] = fmtInto(&s.bufs[6], "{d:.1} um", .{um(con.db_nm)});
        s.lens[7] = fmtInto(&s.bufs[7], "{d:.1} um", .{um(con.dz_nm)});
        s.lens[8] = fmtInto(&s.bufs[8], "{d} / {d}", .{ con.one_qubit_gate_fidelity, con.two_qubit_gate_fidelity });
        s.lens[9] = fmtInto(&s.bufs[9], "{d}", .{con.readout_fidelity});
        return s;
    }

    fn title(s: *const SpecSheet) [:0]const u8 {
        return s.title_buf[0..s.title_len :0];
    }

    fn val(s: *const SpecSheet, i: usize) [:0]const u8 {
        return s.bufs[i][0..s.lens[i] :0];
    }

    /// Panel width covering the widest line, plus padding.
    fn width(s: *const SpecSheet, font: rl.Font) f32 {
        var w = PAD + rl.measureTextEx(font, s.title(), 20, 0.5).x;
        for (0..spec_keys.len) |i| {
            w = @max(w, SPEC_VAL_X + rl.measureTextEx(font, s.val(i), 18, 0.5).x);
        }
        return w + PAD;
    }
};

fn fmtInto(buf: []u8, comptime fmt: []const u8, args: anytype) usize {
    const r = std.fmt.bufPrintSentinel(buf, fmt, args, 0) catch {
        buf[0] = '?';
        buf[1] = 0;
        return 1;
    };
    return r.len;
}

fn um(nm: u32) f64 {
    return @as(f64, @floatFromInt(nm)) / 1000.0;
}

// ── Logical view ─────────────────────────────────────────────────────────────

// Slot-table geometry, world units.
const CELL_W: f32 = 64;
const CELL_H: f32 = 44;
const TBL_LABEL_H: f32 = 36;
const TBL_GAP: f32 = 70;
const ROW_LABEL_W: f32 = 70;

/// The logical routing tables (viewmodel.SlotTables) as a zoomable grid —
/// the scalable version of route.Sequence.print()'s ASCII: per round, the
/// SLM row of fixed qubits, then one row per timestep showing which qubit
/// each AOD column holds. An AOD entry over an occupied SLM column is a CZ
/// firing at that timestep, so those cells get the rydberg highlight. All
/// rounds stack vertically, labeled by stage and round.
const LogicalView = struct {
    tables: *const viewmodel.SlotTables,
    cam: Camera = .{},
    touched: bool = false,

    const slm_fill = rl.Color{ .r = palette.op_load.r, .g = palette.op_load.g, .b = palette.op_load.b, .a = 70 };
    const ride_fill = rl.Color{ .r = palette.accent.r, .g = palette.accent.g, .b = palette.accent.b, .a = 45 };
    const fire_fill = rl.Color{ .r = palette.op_rydberg.r, .g = palette.op_rydberg.g, .b = palette.op_rydberg.b, .a = 120 };

    fn empty(v: LogicalView) bool {
        return v.tables.rounds.len == 0;
    }

    fn tableHeight(round: viewmodel.SlotTables.Round) f32 {
        return @as(f32, @floatFromInt(1 + round.moveable.len)) * CELL_H;
    }

    fn bbox(v: LogicalView) BBox {
        if (v.empty()) return .{ .min_x = -10, .min_y = -10, .max_x = 10, .max_y = 10 };
        var w: f32 = 1;
        var y: f32 = 0;
        for (v.tables.rounds) |round| {
            w = @max(w, @as(f32, @floatFromInt(round.fixed.len)) * CELL_W);
            y += TBL_LABEL_H + tableHeight(round) + TBL_GAP;
        }
        return .{ .min_x = -ROW_LABEL_W, .min_y = 0, .max_x = w, .max_y = y - TBL_GAP };
    }

    fn fit(v: *LogicalView, region: rl.Rectangle) void {
        v.cam.fitToRegion(v.bbox(), region);
        v.touched = false;
    }

    fn draw(v: LogicalView, font: rl.Font, region: rl.Rectangle) void {
        if (v.empty()) {
            rl.drawTextEx(font, "nothing routed (no CZ stages)", .{ .x = PAD, .y = TAB_H + PAD }, 20, 1, palette.text_sub);
            return;
        }

        // Mouse in world space, for the row hover highlight; the tab bar
        // and anything outside the region don't hover.
        const mouse = rl.getMousePosition();
        const mw: ?rl.Vector2 = if (rl.checkCollisionPointRec(mouse, region))
            v.cam.screenToWorld(mouse)
        else
            null;

        var ty: f32 = 0;
        for (v.tables.rounds) |round| {
            v.drawLabel(font, round, ty);
            v.drawRound(font, round, ty + TBL_LABEL_H, mw);
            ty += TBL_LABEL_H + tableHeight(round) + TBL_GAP;
        }

        // Cell-color legend pinned under the tab bar.
        var lx: f32 = PAD;
        lx = legendChip(font, lx, region.y, slm_fill, "SLM");
        lx = legendChip(font, lx, region.y, ride_fill, "AOD");
        _ = legendChip(font, lx, region.y, fire_fill, "CZ fires");
    }

    // A table's stage/round landmark; clamped readable at any zoom.
    fn drawLabel(v: LogicalView, font: rl.Font, round: viewmodel.SlotTables.Round, ty: f32) void {
        const s = v.cam.worldToScreen(.{ .x = 0, .y = ty });
        const fs = std.math.clamp(24.0 * v.cam.zoom, 12, 26);
        var buf: [48]u8 = undefined;
        const txt = std.fmt.bufPrintSentinel(
            &buf,
            "S{d}  round {d}/{d}",
            .{ round.stage, round.ri, round.n_in_stage - 1 },
            0,
        ) catch "?";
        rl.drawTextEx(font, txt, .{ .x = s.x, .y = s.y }, fs, 0.5, palette.text);
    }

    fn drawRound(v: LogicalView, font: rl.Font, round: viewmodel.SlotTables.Round, ty: f32, mw: ?rl.Vector2) void {
        const cam = v.cam;
        const n_slots = round.fixed.len;
        const n_rows = 1 + round.moveable.len;
        const cell_h = CELL_H * cam.zoom;
        const fs = std.math.clamp(20.0 * cam.zoom, 0, 24);
        const show_text = cell_h >= 13;
        const table_w = @as(f32, @floatFromInt(n_slots)) * CELL_W;

        // The hovered row and column, banded under the cells so their
        // fills stay on top; together they crosshair the hovered cell.
        const table_h = @as(f32, @floatFromInt(n_rows)) * CELL_H;
        const band = rl.Color{ .r = palette.accent.r, .g = palette.accent.g, .b = palette.accent.b, .a = 28 };
        var hover_row: ?usize = null;
        var hover_col: ?usize = null;
        if (mw) |m| {
            if (m.y >= ty and m.y < ty + table_h) {
                if (m.x >= -ROW_LABEL_W and m.x <= table_w)
                    hover_row = @intFromFloat((m.y - ty) / CELL_H);
                if (m.x >= 0 and m.x < table_w)
                    hover_col = @intFromFloat(m.x / CELL_W);
            }
        }
        if (hover_row) |r| {
            const tl = cam.worldToScreen(.{ .x = -ROW_LABEL_W, .y = ty + @as(f32, @floatFromInt(r)) * CELL_H });
            rl.drawRectangleRec(
                .{ .x = tl.x, .y = tl.y, .width = (table_w + ROW_LABEL_W) * cam.zoom, .height = cell_h },
                band,
            );
        }
        if (hover_col) |c| {
            const tl = cam.worldToScreen(.{ .x = @as(f32, @floatFromInt(c)) * CELL_W, .y = ty });
            rl.drawRectangleRec(
                .{ .x = tl.x, .y = tl.y, .width = CELL_W * cam.zoom, .height = table_h * cam.zoom },
                band,
            );
        }

        // Cells: the SLM row, then one row per timestep.
        for (0..n_slots) |i| {
            const wx = @as(f32, @floatFromInt(i)) * CELL_W;

            if (round.fixed[i]) |q| {
                v.drawCell(font, wx, ty, slm_fill, q, show_text, fs);
            } else if (show_text) {
                v.drawDot(wx, ty);
            }

            for (round.moveable, 0..) |row, t| {
                const wy = ty + @as(f32, @floatFromInt(1 + t)) * CELL_H;
                if (row[i]) |q| {
                    const fill = if (round.fixed[i] != null) fire_fill else ride_fill;
                    v.drawCell(font, wx, wy, fill, q, show_text, fs);
                } else if (show_text) {
                    v.drawDot(wx, wy);
                }
            }
        }

        // Grid lines, with a heavier rule setting the SLM row apart.
        const x1 = @as(f32, @floatFromInt(n_slots)) * CELL_W;
        const y1 = ty + @as(f32, @floatFromInt(n_rows)) * CELL_H;
        for (0..n_slots + 1) |i| {
            const x = @as(f32, @floatFromInt(i)) * CELL_W;
            rl.drawLineEx(cam.worldToScreen(.{ .x = x, .y = ty }), cam.worldToScreen(.{ .x = x, .y = y1 }), 1.0, palette.divider);
        }
        for (0..n_rows + 1) |r| {
            const y = ty + @as(f32, @floatFromInt(r)) * CELL_H;
            const thick: f32 = if (r == 1) 2.5 else 1.0;
            rl.drawLineEx(cam.worldToScreen(.{ .x = 0, .y = y }), cam.worldToScreen(.{ .x = x1, .y = y }), thick, palette.divider);
        }

        // Row labels in the left margin: SLM, then t0..tN.
        if (cell_h >= 10) {
            const lfs = std.math.clamp(18.0 * cam.zoom, 10, 22);
            for (0..n_rows) |r| {
                var buf: [12]u8 = undefined;
                const txt = if (r == 0)
                    "SLM"
                else
                    std.fmt.bufPrintSentinel(&buf, "t{d}", .{r - 1}, 0) catch "?";
                const tw = rl.measureTextEx(font, txt, lfs, 0.5).x;
                const s = cam.worldToScreen(.{ .x = 0, .y = ty + (@as(f32, @floatFromInt(r)) + 0.5) * CELL_H });
                const col = if (hover_row == r) palette.text else palette.text_sub;
                rl.drawTextEx(font, txt, .{ .x = s.x - tw - 10, .y = s.y - lfs / 2 }, lfs, 0.5, col);
            }
        }
    }

    fn drawCell(v: LogicalView, font: rl.Font, wx: f32, wy: f32, fill: rl.Color, q: usize, show_text: bool, fs: f32) void {
        const tl = v.cam.worldToScreen(.{ .x = wx, .y = wy });
        rl.drawRectangleRec(
            .{ .x = tl.x, .y = tl.y, .width = CELL_W * v.cam.zoom, .height = CELL_H * v.cam.zoom },
            fill,
        );
        if (!show_text) return;
        var buf: [12]u8 = undefined;
        const txt = std.fmt.bufPrintSentinel(&buf, "{d}", .{q}, 0) catch "?";
        const tw = rl.measureTextEx(font, txt, fs, 0.5).x;
        const c = v.cam.worldToScreen(.{ .x = wx + CELL_W / 2, .y = wy + CELL_H / 2 });
        rl.drawTextEx(font, txt, .{ .x = c.x - tw / 2, .y = c.y - fs / 2 }, fs, 0.5, palette.text);
    }

    // The ASCII table's `·`: an empty slot.
    fn drawDot(v: LogicalView, wx: f32, wy: f32) void {
        const c = v.cam.worldToScreen(.{ .x = wx + CELL_W / 2, .y = wy + CELL_H / 2 });
        rl.drawCircleV(c, @max(1.0, 2.5 * v.cam.zoom), palette.qdot);
    }
};

fn legendChip(font: rl.Font, x: f32, region_y: f32, fill: rl.Color, txt: [:0]const u8) f32 {
    rl.drawRectangleRounded(.{ .x = x, .y = region_y + 10, .width = 14, .height = 14 }, 0.3, 4, fill);
    rl.drawTextEx(font, txt, .{ .x = x + 18, .y = region_y + 8 }, 18, 0.5, palette.text_sub);
    return x + 18 + rl.measureTextEx(font, txt, 18, 0.5).x + PAD;
}

// ── Tab bar + entry point ────────────────────────────────────────────────────

fn drawTabs(font: rl.Font, view: *View, sw: f32) void {
    rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = sw, .height = TAB_H }, palette.panel_bg);
    rl.drawLineEx(.{ .x = 0, .y = TAB_H }, .{ .x = sw, .y = TAB_H }, 1.0, palette.divider);

    var idx: i32 = @intFromEnum(view.*);
    _ = rg.toggleGroup(
        .{ .x = PAD, .y = (TAB_H - BTN_H) / 2, .width = TAB_W, .height = BTN_H },
        "circuit;stages;schedule;logical",
        &idx,
    );
    view.* = @enumFromInt(std.math.clamp(idx, 0, 3));

    const hint = "1-4 view   wheel zoom   drag pan   r fit   h specs";
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
    var logical = LogicalView{ .tables = &tables };
    const specs = SpecSheet.build(layout);
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
            if (!sched.touched) sched.cam.fitToRegion(sched_bbox, sched_region);
            if (!logical.touched) logical.fit(logical_region);
            fitted = true;
        }

        // ── Input ──────────────────────────────────────────────────
        if (!sched.editing) {
            if (rl.isKeyPressed(.one)) view = .circuit;
            if (rl.isKeyPressed(.two)) view = .stages;
            if (rl.isKeyPressed(.three)) view = .schedule;
            if (rl.isKeyPressed(.four)) view = .logical;
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
                .logical => logical.fit(logical_region),
            };

            if (view == .schedule) {
                sched.input();
                // Toggling the panel resizes the world's region; follow
                // with a refit unless the user has taken the camera.
                if (rl.isKeyPressed(.h)) {
                    sched.show_specs = !sched.show_specs;
                    if (!sched.touched) {
                        const sp: f32 = if (sched.show_specs) sched.specs_w + 2 * PAD else 0;
                        sched.cam.fitToRegion(sched_bbox, .{
                            .x = sp,
                            .y = TAB_H,
                            .width = @max(1, sw - sp),
                            .height = @max(1, sh - TAB_H - BAR_H),
                        });
                    }
                }
            }
        }
        if (rl.isKeyPressed(.escape)) {
            if (sched.editing) sched.editing = false else break;
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
        // A click on another tab leaves the frame box mid-edit; drop the
        // edit so 1/2/3 and j/k aren't dead on return.
        if (view != .schedule) sched.editing = false;
    }
}
