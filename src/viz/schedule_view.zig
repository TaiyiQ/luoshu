//! The hardware-schedule replay: playback state, camera, the world
//! drawing (zones, traps, atoms, AOD highlights, blockade halos), the
//! transport bar, and the architecture spec sheet.

const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const schedule = @import("schedule");
const arch_mod = @import("arch");
const viewmodel = @import("viewmodel");

const common = @import("common.zig");
const palette = common.palette;
const withAlpha = common.withAlpha;
const toVec = common.toVec;
const Camera = common.Camera;
const BBox = common.BBox;

const PAD = common.PAD;
const TAB_H = common.TAB_H;
const BAR_H = common.BAR_H;
const BTN_W = common.BTN_W;
const BTN_H = common.BTN_H;
const ROW2_H = common.ROW2_H;
const FRAME_BOX_W = common.FRAME_BOX_W;

const Point = schedule.Point;
const OpKind = schedule.OpKind;
const ZoneRect = viewmodel.ZoneRect;

const ATOM_R: f32 = 300.0;
const ATOM_R_LOADED: f32 = 450.0;

fn opFill(op: OpKind) rl.Color {
    return switch (op) {
        .move => palette.op_move,
        .raman, .measure => palette.op_raman,
        .rydberg => palette.op_rydberg,
        .load => palette.op_load,
        .store => palette.op_store,
    };
}

fn drawZone(cam: Camera, r: ZoneRect, fill: rl.Color) void {
    const tl = cam.worldToScreen(.{
        .x = @floatFromInt(r.x0),
        .y = @floatFromInt(r.y0),
    });
    const br = cam.worldToScreen(.{
        .x = @floatFromInt(r.x1),
        .y = @floatFromInt(r.y1),
    });
    const rec = rl.Rectangle{
        .x = tl.x,
        .y = tl.y,
        .width = br.x - tl.x,
        .height = br.y - tl.y,
    };
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
fn drawAodHighlight(
    cam: Camera,
    positions: []const Point,
    loaded: []const bool,
    frame_ops: []const OpKind,
) void {
    const fill = withAlpha(palette.accent, 15);
    const edge = withAlpha(palette.accent, 55);
    const hw = ATOM_R * cam.zoom;
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());

    for (positions, 0..) |pos, id| {
        if (id >= loaded.len or !loaded[id]) continue;
        const s = cam.worldToScreen(toVec(pos));

        // Horizontal row — visible while the atom is in the AOD (disappears on store).
        rl.drawRectangleV(
            .{ .x = 0, .y = s.y - hw },
            .{ .x = sw, .y = 2.0 * hw },
            fill,
        );
        rl.drawLineEx(
            .{ .x = 0, .y = s.y },
            .{ .x = sw, .y = s.y },
            1.0,
            edge,
        );

        // Vertical column — only at the timestep this atom is loaded (picked up).
        const being_loaded = for (frame_ops) |op| {
            if (op == .load and op.load.qubit == @as(u32, @intCast(id))) break true;
        } else false;
        if (being_loaded) {
            rl.drawRectangleV(
                .{ .x = s.x - hw, .y = 0 },
                .{ .x = 2.0 * hw, .y = sh },
                fill,
            );
            rl.drawLineEx(
                .{ .x = s.x, .y = 0 },
                .{ .x = s.x, .y = sh },
                1.0,
                edge,
            );
        }
    }
}

/// Halo enclosing a pair of atoms sitting within the blockade radius during
/// a rydberg pulse — the pairs that actually entangle.
fn drawPairHalo(cam: Camera, a: Point, b: Point, color: rl.Color) void {
    const sa = cam.worldToScreen(toVec(a));
    const sb = cam.worldToScreen(toVec(b));
    const base_r = ATOM_R * cam.zoom;
    const center = rl.Vector2{
        .x = (sa.x + sb.x) / 2.0,
        .y = (sa.y + sb.y) / 2.0,
    };
    const dx = sb.x - sa.x;
    const dy = sb.y - sa.y;
    const r = @sqrt(dx * dx + dy * dy) / 2.0 + base_r * 1.8;

    rl.drawCircleV(center, r, withAlpha(color, 12));
    rl.drawCircleLinesV(center, r, withAlpha(color, 90));
    rl.drawCircleLinesV(center, r + 2.0, withAlpha(color, 40));
    rl.drawCircleLinesV(center, r + 4.0, withAlpha(color, 15));
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
        rl.drawTextEx(
            font,
            label,
            .{
                .x = screen.x + radius + 10,
                .y = screen.y - 12,
            },
            24,
            0.5,
            palette.text,
        );
    }
}

/// The hardware-schedule replay: playback state, camera, and the scratch
/// buffers the render loop fills each frame. World drawing and the
/// transport bar both live here so run() stays a thin view switcher.
pub const ScheduleView = struct {
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

    pub fn empty(v: ScheduleView) bool {
        return v.s.placement.len == 0 or v.s.frames.items.len == 0;
    }

    /// Jump to a frame and stop playback.
    pub fn seek(v: *ScheduleView, frame: usize) void {
        v.frame = @min(frame, v.last_frame);
        v.playing = false;
        v.clock = 0;
    }

    pub fn fit(v: *ScheduleView, region: rl.Rectangle) void {
        v.cam.fitToRegion(BBox.fromPoints(v.sites), region);
        v.touched = false;
    }

    pub fn input(v: *ScheduleView) void {
        if (v.empty()) return;
        if (rl.isKeyPressed(.k) or rl.isKeyPressedRepeat(.k)) v.seek(v.frame + 1);
        if (rl.isKeyPressed(.j) or rl.isKeyPressedRepeat(.j)) v.seek(v.frame -| 1);
        if (rl.isKeyPressed(.space)) {
            v.playing = !v.playing;
            v.clock = 0;
        }
    }

    pub fn update(v: *ScheduleView, dt: f32) void {
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

    pub fn drawWorld(v: *ScheduleView, font: rl.Font) void {
        if (v.empty()) {
            drawZone(v.cam, v.storage_rect, palette.zone_storage);
            drawZone(v.cam, v.compute_rect, palette.zone_compute);
            drawZone(v.cam, v.readout_rect, palette.zone_readout);
            for (v.sites) |slot| drawSlot(v.cam, slot, &.{}, &.{}, v.idle);
            rl.drawTextEx(
                font,
                "empty schedule",
                .{ .x = PAD, .y = TAB_H + PAD },
                20,
                1,
                palette.text_sub,
            );
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
                withAlpha(accent, 140),
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

    pub fn drawBar(v: *ScheduleView, font: rl.Font, sw: f32, sh: f32) void {
        const bar_y = sh - BAR_H;
        rl.drawRectangleRec(
            .{
                .x = 0,
                .y = bar_y,
                .width = sw,
                .height = BAR_H,
            },
            palette.panel_bg,
        );
        rl.drawLineEx(
            .{ .x = 0, .y = bar_y },
            .{ .x = sw, .y = bar_y },
            1.0,
            palette.divider,
        );

        const row1_y = bar_y + PAD;

        var x: f32 = PAD;
        if (rg.button(.{
            .x = x,
            .y = row1_y,
            .width = BTN_W,
            .height = BTN_H,
        }, "|<")) v.seek(0);
        x += BTN_W + 6;

        if (rg.button(.{ .x = x, .y = row1_y, .width = BTN_W, .height = BTN_H }, "<")) v.seek(v.frame -| 1);
        x += BTN_W + 6;

        if (rg.button(.{ .x = x, .y = row1_y, .width = 2 * BTN_W, .height = BTN_H }, if (v.playing) "pause" else "play")) {
            v.playing = !v.playing;
            v.clock = 0;
        }
        x += 2 * BTN_W + 6;

        if (rg.button(.{ .x = x, .y = row1_y, .width = BTN_W, .height = BTN_H }, ">")) v.seek(v.frame + 1);
        x += BTN_W + PAD;

        // Scrub slider over the whole schedule.
        const slider_w = @max(60, sw - x - FRAME_BOX_W - 2 * PAD);
        var frame_f: f32 = @floatFromInt(v.frame);
        _ = rg.sliderBar(
            .{
                .x = x,
                .y = row1_y,
                .width = slider_w,
                .height = BTN_H,
            },
            null,
            null,
            &frame_f,
            0,
            @floatFromInt(@max(v.last_frame, 1)),
        );
        const scrubbed: usize = @intFromFloat(@round(@max(0, frame_f)));
        if (scrubbed != v.frame) v.seek(scrubbed);

        // Exact-frame entry: click, type the frame number, enter jumps
        // there. 0-based, so verify's "frame N" pastes in verbatim.
        if (!v.editing) v.frame_box = @intCast(v.frame);
        if (rg.valueBox(
            .{
                .x = x + slider_w + PAD,
                .y = row1_y,
                .width = FRAME_BOX_W,
                .height = BTN_H,
            },
            "",
            &v.frame_box,
            0,
            @intCast(v.last_frame),
            v.editing,
        ) != 0) {
            v.editing = !v.editing;
            // Committed with enter or a click away.
            if (!v.editing) v.seek(@intCast(@max(0, v.frame_box)));
        }

        // Row 2: playback speed + status line.
        const row2_y = row1_y + BTN_H + 8;
        var spd_buf: [16]u8 = undefined;
        const spd_txt = std.fmt.bufPrintSentinel(&spd_buf, "{d:.1}/s", .{v.speed}, 0) catch "?";
        rl.drawTextEx(font, "speed", .{ .x = PAD, .y = row2_y + 2 }, 20, 1, palette.text_sub);
        _ = rg.sliderBar(
            .{
                .x = PAD + 70,
                .y = row2_y,
                .width = 160,
                .height = ROW2_H,
            },
            null,
            null,
            &v.speed,
            0.5,
            60,
        );
        rl.drawTextEx(
            font,
            spd_txt,
            .{ .x = PAD + 240, .y = row2_y + 2 },
            20,
            1,
            palette.text_sub,
        );

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
            .{
                v.frame,
                v.last_frame,
                v.vm.summary.move,
                v.vm.summary.raman,
                v.vm.summary.rydberg,
                v.vm.summary.measure,
            },
            0,
        ) catch "?";

        const status_x = PAD + 330;

        rl.drawTextEx(
            font,
            op_txt,
            .{ .x = status_x, .y = row2_y + 2 },
            20,
            1,
            accent,
        );

        rl.drawTextEx(
            font,
            counts_txt,
            .{ .x = status_x + op_w, .y = row2_y + 2 },
            20,
            1,
            palette.text_sub,
        );
    }

    /// Architecture spec sheet, toggled with `h`: the geometry and
    /// constraint numbers behind the picture, pinned top-left. The panel
    /// is sized from the measured text (specs_w), and the schedule's fit
    /// region starts past it, so neither the text nor the grid ever sits
    /// under it.
    pub fn drawSpecs(v: ScheduleView, font: rl.Font) void {
        const row_h: f32 = 24;
        const h = @as(f32, spec_keys.len) * row_h + 2 * PAD + row_h + 8;

        const rec = rl.Rectangle{
            .x = PAD,
            .y = TAB_H + PAD,
            .width = v.specs_w,
            .height = h,
        };

        rl.drawRectangleRounded(
            rec,
            0.06,
            6,
            withAlpha(palette.panel_bg, 235),
        );

        rl.drawRectangleRoundedLinesEx(
            rec,
            0.06,
            6,
            1.0,
            palette.divider,
        );

        var y = TAB_H + 2 * PAD;
        rl.drawTextEx(
            font,
            v.specs.title,
            .{ .x = 2 * PAD, .y = y },
            20,
            0.5,
            palette.accent,
        );
        y += row_h + 8;

        for (spec_keys, v.specs.vals) |key, val| {
            rl.drawTextEx(
                font,
                key,
                .{ .x = 2 * PAD, .y = y },
                18,
                0.5,
                palette.text_sub,
            );

            rl.drawTextEx(
                font,
                val,
                .{ .x = PAD + SPEC_VAL_X, .y = y },
                18,
                0.5,
                palette.text,
            );

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
};

/// The spec sheet's text, formatted once at startup (the arch config never
/// changes mid-run) so the panel can be sized to the measured strings.
pub const SpecSheet = struct {
    title: [:0]const u8,
    vals: [spec_keys.len][:0]const u8,

    pub fn build(arena: std.mem.Allocator, cfg: arch_mod.ArchConfig) !SpecSheet {
        const aod = cfg.aod;
        const st = cfg.storage_zone.slm;
        const cz = cfg.compute_zone;
        const c0 = cz.slms[0];
        const ro = cfg.readout_zone.slm;
        const con = cfg.constraints;

        const p = std.fmt.allocPrintSentinel;
        return .{
            .title = try p(arena, "{s}  v{s}", .{ cfg.platform.name, cfg.platform.version }, 0),
            .vals = .{
                try p(arena, "{d} x {d} max", .{ aod.max_num_row, aod.max_num_col }, 0),
                try p(arena, ">= {d:.1} um", .{um(aod.min_sep_nm)}, 0),
                try p(arena, "{d} x {d}  @ {d:.1} x {d:.1} um", .{
                    st.num_row,
                    st.num_col,
                    um(st.sep_nm[0]),
                    um(st.sep_nm[1]),
                }, 0),
                try p(arena, "{d} x ({d} x {d})  @ {d:.1} x {d:.1} um", .{
                    cz.slms.len,
                    c0.num_row,
                    c0.num_col,
                    um(c0.sep_nm[0]),
                    um(c0.sep_nm[1]),
                }, 0),
                try p(arena, "{d:.1} / {d:.1} um", .{ um(cz.dr_nm), um(cz.dw_nm) }, 0),
                try p(arena, "{d} x {d}", .{ ro.num_row, ro.num_col }, 0),
                try p(arena, "{d:.1} um", .{um(con.db_nm)}, 0),
                try p(arena, "{d:.1} um", .{um(con.dz_nm)}, 0),
            },
        };
    }

    /// Panel width covering the widest line, plus padding.
    pub fn width(s: SpecSheet, font: rl.Font) f32 {
        var w = PAD + rl.measureTextEx(font, s.title, 20, 0.5).x;
        for (s.vals) |v| {
            w = @max(w, SPEC_VAL_X + rl.measureTextEx(font, v, 18, 0.5).x);
        }
        return w + PAD;
    }
};

fn um(nm: u32) f64 {
    return @as(f64, @floatFromInt(nm)) / 1000.0;
}
