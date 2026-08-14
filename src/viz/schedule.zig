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
const drawNotice = common.drawNotice;
const drawPanel = common.drawPanel;
const drawChromeStrip = common.drawChromeStrip;
const drawTextCentered = common.drawTextCentered;
const drawTextRight = common.drawTextRight;
const Camera = common.Camera;
const Viewport = common.Viewport;
const BBox = common.BBox;

const FONT = common.FONT;
const FONT_LG = common.FONT_LG;
const PAD = common.PAD;
const BAR_H = common.BAR_H;
const BTN_W = common.BTN_W;
const BTN_H = common.BTN_H;
const BTN_GAP = common.BTN_GAP;
const ROW2_H = common.ROW2_H;
const FRAME_BOX_W = common.FRAME_BOX_W;
const CONTENT_X = common.CONTENT_X;
const CONTENT_Y = common.CONTENT_Y;

const Point = schedule.Point;
const OpKind = schedule.OpKind;
const ZoneRect = viewmodel.ZoneRect;

/// Set of occupied trap positions.
const PointSet = std.AutoHashMap(Point, void);

const ATOM_R: f32 = 300.0;
const ATOM_R_LOADED: f32 = 450.0;

const SPEED_W: f32 = 160; // speed slider width in the transport bar

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
    const rec = cam.rect(.{
        .x = @floatFromInt(r.x0),
        .y = @floatFromInt(r.y0),
        .width = @floatFromInt(r.x1 - r.x0),
        .height = @floatFromInt(r.y1 - r.y0),
    });
    rl.drawRectangleRounded(rec, 0.06, 8, fill);
    rl.drawRectangleRoundedLinesEx(rec, 0.06, 8, 1.0, palette.zone_border);
}

/// One trap site, filled when `occupied` (the frame's occupancy set from
/// occupiedNow) holds an atom at its position.
fn drawSlot(cam: Camera, slot: Point, occupied: *const PointSet) void {
    const screen = cam.worldToScreen(toVec(slot));
    const radius = ATOM_R * cam.zoom;

    if (occupied.contains(slot)) {
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

    for (positions, loaded, 0..) |pos, is_loaded, id| {
        if (!is_loaded) continue;
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

const DIM_HEAD: f32 = 7.0; // arrowhead length in screen px

/// One CAD-style dimension: extension lines from the feature anchors out
/// to an offset lane, a double-headed arrow spanning the lane, and the
/// distance label beside it. Returns false without drawing while the
/// arrow is too short on screen to carry its label — zooming in resolves
/// progressively finer spacings.
fn drawDimension(cam: Camera, font: rl.Font, d: viewmodel.Dimension) bool {
    const qa = cam.worldToScreen(.{
        .x = @floatFromInt(d.a.x + d.lane_nm.x),
        .y = @floatFromInt(d.a.y + d.lane_nm.y),
    });
    const qb = cam.worldToScreen(.{
        .x = @floatFromInt(d.b.x + d.lane_nm.x),
        .y = @floatFromInt(d.b.y + d.lane_nm.y),
    });

    const dx = qb.x - qa.x;
    const dy = qb.y - qa.y;
    const len = @sqrt(dx * dx + dy * dy);
    const horizontal = @abs(dx) >= @abs(dy);
    const label_w = rl.measureTextEx(font, d.label, FONT, 1).x;
    // A horizontal label sits over its arrow; a vertical arrow only has
    // to clear the label's height beside it.
    const needed: f32 = if (horizontal) label_w + 2 * DIM_HEAD else FONT + DIM_HEAD;
    if (len < needed) return false;

    const line = withAlpha(palette.dimension, 200);
    const ext = withAlpha(palette.dimension, 90);

    rl.drawLineEx(
        cam.worldToScreen(toVec(d.a)),
        overshoot(cam.worldToScreen(toVec(d.a)), qa),
        1.0,
        ext,
    );

    rl.drawLineEx(
        cam.worldToScreen(toVec(d.b)),
        overshoot(cam.worldToScreen(toVec(d.b)), qb),
        1.0,
        ext,
    );

    rl.drawLineEx(qa, qb, 1.5, line);

    const u = rl.Vector2{ .x = dx / len, .y = dy / len };
    const perp = rl.Vector2{ .x = -u.y, .y = u.x };

    drawArrowHead(qa, u, perp, line);
    drawArrowHead(qb, .{ .x = -u.x, .y = -u.y }, perp, line);

    const mid = rl.Vector2{
        .x = (qa.x + qb.x) / 2,
        .y = (qa.y + qb.y) / 2,
    };

    if (horizontal) {
        drawTextCentered(
            font,
            d.label,
            mid.x,
            mid.y - FONT - 4,
            FONT,
            palette.dimension,
        );
    } else {
        drawTextRight(
            font,
            d.label,
            mid.x - DIM_HEAD - 4,
            mid.y - FONT / 2,
            FONT,
            palette.dimension,
        );
    }
    return true;
}

/// Extension lines run a few px past the arrow lane, CAD-style.
fn overshoot(from: rl.Vector2, to: rl.Vector2) rl.Vector2 {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const n = @sqrt(dx * dx + dy * dy);

    if (n == 0) return to;

    return .{
        .x = to.x + dx / n * 4,
        .y = to.y + dy / n * 4,
    };
}

/// Open V arrowhead with its tip at `tip`; `in` points along the shaft.
fn drawArrowHead(tip: rl.Vector2, in: rl.Vector2, perp: rl.Vector2, color: rl.Color) void {
    const base = rl.Vector2{
        .x = tip.x + in.x * DIM_HEAD,
        .y = tip.y + in.y * DIM_HEAD,
    };

    const s = DIM_HEAD * 0.4;

    rl.drawLineEx(
        tip,
        .{
            .x = base.x + perp.x * s,
            .y = base.y + perp.y * s,
        },
        1.5,
        color,
    );

    rl.drawLineEx(
        tip,
        .{
            .x = base.x - perp.x * s,
            .y = base.y - perp.y * s,
        },
        1.5,
        color,
    );
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

fn drawQubit(
    cam: Camera,
    font: rl.Font,
    pos: Point,
    id: usize,
    is_active: bool,
    is_loaded: bool,
    fill: rl.Color,
) void {
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
                .y = screen.y - FONT_LG / 2,
            },
            FONT_LG,
            0.5,
            palette.text,
        );
    }
}

/// The hardware-schedule replay: playback state, camera, and the scratch
/// buffers the render loop fills each frame. World drawing and the
/// transport bar both live here so run() stays a thin view switcher.
pub const ScheduleView = struct {
    // Owns everything init precomputes: spec strings, dimensions, trap
    // sites, idle positions, and the per-frame scratch buffers.
    arena: std.heap.ArenaAllocator,

    s: *const schedule.Hardware,
    vm: *const viewmodel.ViewModel,
    specs: SpecSheet,
    specs_w: f32,
    sites: []const Point,
    idle: []const Point,
    active: []bool,
    active_idx: []usize,
    draw_positions: []Point,
    occupied: PointSet,
    dims: []const viewmodel.Dimension,
    show_specs: bool = true,
    show_dims: bool = true,

    frame: usize = 0,
    playing: bool = false,
    clock: f32 = 0, // frame-units elapsed at the current frame while playing
    speed: f32 = 2.5, // playback rate in frames per second
    frame_box: i32 = 0, // valueBox binding for exact-frame entry
    editing: bool = false, // the frame box owns the keyboard while true

    vp: Viewport = .{},

    /// Precompute everything the render loop reads. `asm_sites` is the
    /// assembly-delivered storage occupancy (empty without an assembly
    /// doc); the extra sites past the qubit count are the idle atoms.
    pub fn init(
        gpa: std.mem.Allocator,
        s: *const schedule.Hardware,
        vm: *const viewmodel.ViewModel,
        asm_sites: []const schedule.Site,
        font: rl.Font,
    ) !ScheduleView {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const specs = try SpecSheet.build(a, s.cfg);
        const sites = try viewmodel.allSlmSites(a, s.cfg);
        const idle = try viewmodel.idleSites(a, s.cfg, asm_sites, vm.num_qubits);
        const active = try a.alloc(bool, s.placement.len);
        const active_idx = try a.alloc(usize, s.placement.len);
        const draw_positions = try a.alloc(Point, s.placement.len);
        const dims = try viewmodel.buildDimensions(a, s.cfg);

        // Sized once for every stored atom plus every idle atom, so the
        // per-frame rebuild in occupiedNow cannot fail.
        var occupied = PointSet.init(gpa);
        errdefer occupied.deinit();

        try occupied.ensureTotalCapacity(@intCast(s.placement.len + idle.len));

        return .{
            .arena = arena,
            .s = s,
            .vm = vm,
            .specs = specs,
            .specs_w = specs.width(font),
            .sites = sites,
            .idle = idle,
            .active = active,
            .active_idx = active_idx,
            .draw_positions = draw_positions,
            .occupied = occupied,
            .dims = dims,
        };
    }

    pub fn deinit(v: *ScheduleView) void {
        v.occupied.deinit();
        v.arena.deinit();
    }

    pub fn empty(v: *const ScheduleView) bool {
        return v.s.placement.len == 0 or v.s.frames.items.len == 0;
    }

    fn lastFrame(v: *const ScheduleView) usize {
        return v.s.frames.items.len -| 1;
    }

    /// Jump to a frame and stop playback.
    pub fn seek(v: *ScheduleView, frame: usize) void {
        v.frame = @min(frame, v.lastFrame());
        v.playing = false;
        v.clock = 0;
    }

    pub fn fit(v: *ScheduleView, region: rl.Rectangle) void {
        v.vp.fit(BBox.fromPoints(v.sites), region);
    }

    pub fn input(v: *ScheduleView) void {
        if (rl.isKeyPressed(.d)) v.show_dims = !v.show_dims;
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
            if (v.frame >= v.lastFrame()) {
                v.frame = v.lastFrame();
                v.playing = false;
                v.clock = 0;
            }
        }
    }

    const Zones = struct {
        storage: ZoneRect,
        compute: ZoneRect,
        readout: ZoneRect,
    };

    /// The zone rects, derived from the config; cheap enough to rebuild
    /// per frame.
    fn zoneRects(v: *const ScheduleView) Zones {
        return .{
            .storage = viewmodel.zoneRect(v.s.cfg.storage_zone.box()),
            .compute = viewmodel.zoneRect(v.s.cfg.compute_zone.box()),
            .readout = viewmodel.zoneRect(v.s.cfg.readout_zone.box()),
        };
    }

    /// Mark every qubit involved in an op this frame; a rydberg pulse
    /// lights up every atom inside the pulsed zone. Returns that zone.
    fn computeActive(v: *ScheduleView, frame_ops: []const OpKind, zones: Zones) ?schedule.Zone {
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
                    .storage => zones.storage,
                    .compute => zones.compute,
                    .readout => zones.readout,
                };
                for (v.vm.positions[v.frame], 0..) |p, q| {
                    if (p.x >= zr.x0 and p.x <= zr.x1 and
                        p.y >= zr.y0 and p.y <= zr.y1)
                        v.active[q] = true;
                }
            },
        };
        return rydberg_zone;
    }

    /// Fill draw_positions with this frame's positions, movers lerped
    /// src -> dest across the first 60% of the frame period while playing.
    fn interpolate(v: *ScheduleView, frame_ops: []const OpKind) void {
        @memcpy(v.draw_positions, v.vm.positions[v.frame]);
        const move_t: f32 = if (v.playing) blk: {
            const lin = @min(v.clock / 0.6, 1.0);
            break :blk lin * lin * (3.0 - 2.0 * lin); // smoothstep
        } else 1.0;
        if (move_t >= 1.0) return;

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

    /// Rebuild the occupied-trap set for this frame: stored atoms (not
    /// riding the AOD) plus the idle atoms, which hold their trap in every
    /// frame. Capacity is ensured at init, so this cannot fail.
    fn occupiedNow(
        v: *ScheduleView,
        positions: []const Point,
        loaded: []const bool,
    ) *const PointSet {
        v.occupied.clearRetainingCapacity();
        for (positions, loaded) |p, l| {
            if (!l) v.occupied.putAssumeCapacity(p, {});
        }
        for (v.idle) |p| v.occupied.putAssumeCapacity(p, {});
        return &v.occupied;
    }

    pub fn drawWorld(v: *ScheduleView, font: rl.Font) void {
        const zones = v.zoneRects();
        const is_empty = v.empty();
        const frame_ops: []const OpKind = if (is_empty) &.{} else v.s.frames.items[v.frame].items;
        const positions: []const Point = if (is_empty) &.{} else v.vm.positions[v.frame];
        const loaded: []const bool = if (is_empty) &.{} else v.vm.loaded[v.frame];

        const rydberg_zone = v.computeActive(frame_ops, zones);
        if (!is_empty) v.interpolate(frame_ops);

        drawZone(
            v.vp.cam,
            zones.storage,
            if (rydberg_zone == .storage) palette.zone_active else palette.zone_storage,
        );
        drawZone(
            v.vp.cam,
            zones.compute,
            if (rydberg_zone == .compute) palette.zone_active else palette.zone_compute,
        );
        drawZone(
            v.vp.cam,
            zones.readout,
            if (rydberg_zone == .readout) palette.zone_active else palette.zone_readout,
        );

        if (!is_empty) drawAodHighlight(v.vp.cam, v.draw_positions, loaded, frame_ops);

        const occupied = v.occupiedNow(positions, loaded);
        for (v.sites) |slot| drawSlot(v.vp.cam, slot, occupied);

        if (!is_empty) v.drawAtoms(font, frame_ops, loaded, rydberg_zone);

        if (v.show_dims) v.drawDims(font);
        if (is_empty) drawNotice(font, "empty schedule");
    }

    /// The moving world: move trails, blockade halos, then the atoms.
    fn drawAtoms(
        v: *ScheduleView,
        font: rl.Font,
        frame_ops: []const OpKind,
        loaded: []const bool,
        rydberg_zone: ?schedule.Zone,
    ) void {
        const tint = opFill(frame_ops[0]);

        for (frame_ops) |op| {
            if (op != .move) continue;
            const m = op.move;
            rl.drawLineEx(
                v.vp.cam.worldToScreen(toVec(m.src)),
                v.vp.cam.worldToScreen(toVec(v.draw_positions[m.qubit])),
                2.0,
                withAlpha(tint, 140),
            );
        }

        // Halo every active pair within the blockade radius of the pulse,
        // pairing over the gathered active indices rather than all atoms.
        if (rydberg_zone != null) {
            var n_act: usize = 0;
            for (v.active[0..v.vm.num_qubits], 0..) |is_act, i| {
                if (is_act) {
                    v.active_idx[n_act] = i;
                    n_act += 1;
                }
            }

            const db: i64 = v.s.cfg.constraints.db_nm;
            const db2 = db * db;
            for (v.active_idx[0..n_act], 0..) |ia, k| {
                for (v.active_idx[k + 1 .. n_act]) |ib| {
                    const pa = v.draw_positions[ia];
                    const pb = v.draw_positions[ib];
                    const dx: i64 = @as(i64, pa.x) - @as(i64, pb.x);
                    const dy: i64 = @as(i64, pa.y) - @as(i64, pb.y);
                    if (dx * dx + dy * dy <= db2)
                        drawPairHalo(v.vp.cam, pa, pb, palette.op_rydberg);
                }
            }
        }

        for (v.draw_positions, loaded, v.active, 0..) |pos, is_loaded, is_active, id| {
            drawQubit(v.vp.cam, font, pos, id, is_active, is_loaded, tint);
        }
    }

    /// Dimension arrows mapping the spec-sheet numbers onto the layout.
    /// Finer spacings resolve as the camera zooms in; a hint stands in
    /// while every arrow is still too short for its label.
    fn drawDims(v: *const ScheduleView, font: rl.Font) void {
        var shown: usize = 0;

        for (v.dims) |d| {
            if (drawDimension(v.vp.cam, font, d)) shown += 1;
        }

        if (shown == 0 and v.dims.len > 0) {
            const sw: f32 = @floatFromInt(rl.getScreenWidth());
            drawTextRight(
                font,
                "dimensions: zoom in",
                sw - PAD,
                CONTENT_Y,
                FONT,
                palette.text_sub,
            );
        }
    }

    pub fn drawBar(v: *ScheduleView, font: rl.Font, sw: f32, sh: f32) void {
        const bar_y = sh - BAR_H;
        drawChromeStrip(bar_y, sw, BAR_H, bar_y);

        const row1_y = bar_y + PAD;

        var x: f32 = PAD;
        if (rg.button(.{
            .x = x,
            .y = row1_y,
            .width = BTN_W,
            .height = BTN_H,
        }, "|<")) v.seek(0);
        x += BTN_W + BTN_GAP;

        if (rg.button(.{
            .x = x,
            .y = row1_y,
            .width = BTN_W,
            .height = BTN_H,
        }, "<")) v.seek(v.frame -| 1);
        x += BTN_W + BTN_GAP;

        const play_label: [:0]const u8 = if (v.playing) "pause" else "play";
        if (rg.button(.{
            .x = x,
            .y = row1_y,
            .width = 2 * BTN_W,
            .height = BTN_H,
        }, play_label)) {
            v.playing = !v.playing;
            v.clock = 0;
        }
        x += 2 * BTN_W + BTN_GAP;

        if (rg.button(.{
            .x = x,
            .y = row1_y,
            .width = BTN_W,
            .height = BTN_H,
        }, ">")) v.seek(v.frame + 1);
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
            @floatFromInt(@max(v.lastFrame(), 1)),
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
            @intCast(v.lastFrame()),
            v.editing,
        ) != 0) {
            v.editing = !v.editing;
            // Committed with enter or a click away.
            if (!v.editing) v.seek(@intCast(@max(0, v.frame_box)));
        }

        // Row 2: playback speed + status line, laid out with a cursor so
        // the columns derive from the measured text instead of magic
        // offsets. The speed readout gets a fixed worst-case slot so the
        // status line doesn't jiggle as the digits change.
        const row2_y = row1_y + BTN_H + 8;
        var spd_buf: [16]u8 = undefined;
        const spd_txt = std.fmt.bufPrintSentinel(
            &spd_buf,
            "{d:.1}/s",
            .{v.speed},
            0,
        ) catch "?";

        var bx: f32 = PAD;
        rl.drawTextEx(
            font,
            "speed",
            .{ .x = bx, .y = row2_y + 2 },
            FONT,
            1,
            palette.text_sub,
        );
        bx += rl.measureTextEx(font, "speed", FONT, 1).x + PAD;

        _ = rg.sliderBar(
            .{
                .x = bx,
                .y = row2_y,
                .width = SPEED_W,
                .height = ROW2_H,
            },
            null,
            null,
            &v.speed,
            0.5,
            60,
        );
        bx += SPEED_W + PAD;

        rl.drawTextEx(
            font,
            spd_txt,
            .{ .x = bx, .y = row2_y + 2 },
            FONT,
            1,
            palette.text_sub,
        );
        bx += rl.measureTextEx(font, "00.0/s", FONT, 1).x + 2 * PAD;

        const primary_op: OpKind = v.s.frames.items[v.frame].items[0];
        const zone_txt = switch (primary_op) {
            .rydberg => |r| @tagName(r.zone),
            .measure => |m| @tagName(m.zone),
            else => "-",
        };

        var status_buf: [160]u8 = undefined;
        const op_txt = std.fmt.bufPrintSentinel(
            &status_buf,
            "{s} @ {s}",
            .{ @tagName(primary_op), zone_txt },
            0,
        ) catch "?";
        const op_w = rl.measureTextEx(font, op_txt, FONT, 1).x;

        var counts_buf: [160]u8 = undefined;
        const counts_txt = std.fmt.bufPrintSentinel(
            &counts_buf,
            "  |  frame {d} / {d}  |  move {d}  raman {d}  rydberg {d}  measure {d}",
            .{
                v.frame,
                v.lastFrame(),
                v.vm.summary.move,
                v.vm.summary.raman,
                v.vm.summary.rydberg,
                v.vm.summary.measure,
            },
            0,
        ) catch "?";

        rl.drawTextEx(
            font,
            op_txt,
            .{ .x = bx, .y = row2_y + 2 },
            FONT,
            1,
            opFill(primary_op),
        );

        rl.drawTextEx(
            font,
            counts_txt,
            .{ .x = bx + op_w, .y = row2_y + 2 },
            FONT,
            1,
            palette.text_sub,
        );
    }

    /// Architecture spec sheet, toggled with `h`: the geometry and
    /// constraint numbers behind the picture, pinned top-left. The panel
    /// is sized from the measured text (specs_w), and the schedule's fit
    /// region starts past it, so neither the text nor the grid ever sits
    /// under it.
    pub fn drawSpecs(v: *const ScheduleView, font: rl.Font) void {
        const row_h: f32 = FONT + 4;
        const h = @as(f32, spec_keys.len) * row_h + 2 * PAD + row_h + 8;

        const rec = rl.Rectangle{
            .x = CONTENT_X,
            .y = CONTENT_Y,
            .width = v.specs_w,
            .height = h,
        };
        drawPanel(rec, withAlpha(palette.panel_bg, 235));

        var y = CONTENT_Y + PAD;
        rl.drawTextEx(
            font,
            v.specs.title,
            .{ .x = 2 * PAD, .y = y },
            FONT_LG,
            0.5,
            palette.accent,
        );
        y += row_h + 8;

        for (spec_keys, v.specs.vals) |key, val| {
            rl.drawTextEx(
                font,
                key,
                .{ .x = 2 * PAD, .y = y },
                FONT,
                0.5,
                palette.text_sub,
            );

            rl.drawTextEx(
                font,
                val,
                .{ .x = PAD + SPEC_VAL_X, .y = y },
                FONT,
                0.5,
                palette.text,
            );

            y += row_h;
        }
    }
};

// ── Arch spec sheet ──────────────────────────────────────────────────────────

const SPEC_VAL_X: f32 = 210; // value column offset from the panel's left edge

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
            .title = try p(arena, "{s}  v{s}", .{
                cfg.platform.name,
                cfg.platform.version,
            }, 0),
            .vals = .{
                try p(arena, "{d} x {d} max", .{
                    aod.max_num_row,
                    aod.max_num_col,
                }, 0),
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
                try p(arena, "{d:.1} / {d:.1} um", .{
                    um(cz.dr_nm),
                    um(cz.dw_nm),
                }, 0),
                try p(arena, "{d} x {d}", .{
                    ro.num_row,
                    ro.num_col,
                }, 0),
                try p(arena, "{d:.1} um", .{um(con.db_nm)}, 0),
                try p(arena, "{d:.1} um", .{um(con.dz_nm)}, 0),
            },
        };
    }

    /// Panel width covering the widest line, plus padding.
    pub fn width(s: SpecSheet, font: rl.Font) f32 {
        var w = PAD + rl.measureTextEx(font, s.title, FONT_LG, 0.5).x;
        for (s.vals) |v| {
            w = @max(w, SPEC_VAL_X + rl.measureTextEx(font, v, FONT, 0.5).x);
        }
        return w + PAD;
    }
};

fn um(nm: u32) f64 {
    return @as(f64, @floatFromInt(nm)) / 1000.0;
}
