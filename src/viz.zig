const std = @import("std");
const rl = @import("raylib");
const schedule = @import("schedule");

const Point = schedule.Point;
const Op = schedule.Op;

// -----------------------------------------------------------------------
// Zone – one vertical band in the visualisation
// -----------------------------------------------------------------------
const Zone = struct {
    y_lo: i32,
    y_hi: i32,
    x_lo: i32,
    x_hi: i32,
    band_top: f64,
    band_bot: f64,
};

// -----------------------------------------------------------------------
// Layout – maps logical (x,y) to screen coordinates
// -----------------------------------------------------------------------
const Layout = struct {
    zones: []const Zone,
    radius: f64 = 5.0,

    const canvas_w: f64 = 2800;
    const canvas_h: f64 = 1600;
    const header_h: f64 = 70;
    const margin: f64 = 50;
    const band_gap: f64 = 36;

    // -----------------------------------------------------------------------
    // Build the complete Layout from all data
    // -----------------------------------------------------------------------
    fn init(allocator: std.mem.Allocator, positions: []const Point, ops: []const Op, slots: []const Point) !Layout {
        // 1. collect all y values
        const ys = try collectYValues(allocator, positions, slots, ops);
        defer allocator.free(ys);

        // 2. find min gap and threshold
        const min_gap = findMinGap(ys);
        const threshold = min_gap * 10;

        // 3. split into zones
        const zones = try splitIntoZones(allocator, ys, threshold);

        // 4. compute x extents
        computeXExtents(zones, positions, slots, ops);

        // 5. sort top‑down
        sortZonesTopDown(zones);

        // 6. assign screen bands
        assignBands(zones);

        // 7. final Layout owns the zones slice
        return .{ .zones = zones };
    }

    // Find which zone contains the given y coordinate
    fn zoneOf(self: Layout, p: Point) Zone {
        for (self.zones) |z| {
            if (p.y >= z.y_lo and p.y <= z.y_hi) return z;
        }
        return self.zones[0];
    }

    // Project a Point onto screen coordinates
    fn project(self: Layout, p: Point) struct { x: f64, y: f64 } {
        const z = self.zoneOf(p);
        const x_span = @as(f64, @floatFromInt(z.x_hi - z.x_lo));
        const y_span = @as(f64, @floatFromInt(z.y_hi - z.y_lo));
        const draw_w = canvas_w - 2 * margin;

        const px = if (x_span > 0)
            margin + @as(f64, @floatFromInt(p.x - z.x_lo)) * (draw_w / x_span)
        else
            canvas_w / 2.0;

        const py = if (y_span > 0)
            z.band_bot - @as(f64, @floatFromInt(p.y - z.y_lo)) / y_span * (z.band_bot - z.band_top)
        else
            (z.band_top + z.band_bot) / 2.0;

        return .{ .x = px, .y = py };
    }
};

// -----------------------------------------------------------------------
// Helper: collect all y values from points, slots and move destinations
// -----------------------------------------------------------------------
fn collectYValues(allocator: std.mem.Allocator, positions: []const Point, slots: []const Point, ops: []const Op) ![]i32 {
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(allocator);

    for (positions) |p| try list.append(allocator, p.y);
    for (slots) |s| try list.append(allocator, s.y);
    for (ops) |op| {
        if (op.kind == .move) {
            for (op.kind.move.atoms) |a| {
                try list.append(allocator, a.src.y);
                try list.append(allocator, a.dest.y);
            }
        }
    }

    const ys = try list.toOwnedSlice(allocator);
    std.mem.sort(i32, ys, {}, std.sort.asc(i32));
    return ys;
}

// -----------------------------------------------------------------------
// Find smallest non‑zero gap between consecutive y values
// -----------------------------------------------------------------------
fn findMinGap(ys: []const i32) i32 {
    var min_gap: i32 = std.math.maxInt(i32);
    for (ys[1..], 0..) |v, i| {
        const gap = v - ys[i];
        if (gap > 0 and gap < min_gap) min_gap = gap;
    }
    if (min_gap == std.math.maxInt(i32)) return 1;
    return min_gap;
}

// -----------------------------------------------------------------------
// Split y values into zones where gaps are bigger than threshold
// -----------------------------------------------------------------------
fn splitIntoZones(allocator: std.mem.Allocator, ys: []const i32, threshold: i32) ![]Zone {
    var zones: std.ArrayList(Zone) = .empty;
    defer zones.deinit(allocator);

    var lo = ys[0];
    for (ys[1..], 0..) |v, i| {
        if (v - ys[i] > threshold) {
            try zones.append(allocator, .{
                .y_lo = lo,
                .y_hi = ys[i],
                .x_lo = 0,
                .x_hi = 0,
                .band_top = 0,
                .band_bot = 0,
            });
            lo = v;
        }
    }
    try zones.append(allocator, .{
        .y_lo = lo,
        .y_hi = ys[ys.len - 1],
        .x_lo = 0,
        .x_hi = 0,
        .band_top = 0,
        .band_bot = 0,
    });
    return try zones.toOwnedSlice(allocator);
}

// -----------------------------------------------------------------------
// Compute x extents for each zone by scanning all points and moves
// -----------------------------------------------------------------------
fn computeXExtents(zones: []Zone, positions: []const Point, slots: []const Point, ops: []const Op) void {
    // initialise to extremes
    for (zones) |*z| {
        z.x_lo = std.math.maxInt(i32);
        z.x_hi = std.math.minInt(i32);
    }

    const updateZone = struct {
        fn call(zs: []Zone, p: Point) void {
            for (zs) |*z| {
                if (p.y >= z.y_lo and p.y <= z.y_hi) {
                    if (p.x < z.x_lo) z.x_lo = p.x;
                    if (p.x > z.x_hi) z.x_hi = p.x;
                    break;
                }
            }
        }
    }.call;

    for (positions) |p| updateZone(zones, p);
    for (slots) |s| updateZone(zones, s);
    for (ops) |op| {
        if (op.kind == .move) {
            for (op.kind.move.atoms) |a| {
                updateZone(zones, a.src);
                updateZone(zones, a.dest);
            }
        }
    }
}

// -----------------------------------------------------------------------
// Sort zones top‑down by their highest y (for drawing order)
// -----------------------------------------------------------------------
fn sortZonesTopDown(zones: []Zone) void {
    std.mem.sort(Zone, zones, {}, struct {
        fn cmp(_: void, a: Zone, b: Zone) bool {
            return a.y_hi > b.y_hi;
        }
    }.cmp);
}

// -----------------------------------------------------------------------
// Assign screen bands to each zone (equal height + gaps)
// -----------------------------------------------------------------------
fn assignBands(zones: []Zone) void {
    const n = @as(f64, @floatFromInt(zones.len));
    const draw_h = Layout.canvas_h - Layout.header_h - Layout.margin;
    const usable = draw_h - Layout.band_gap * (n - 1);
    const band_h = usable / n;
    var y_cursor = Layout.header_h;
    for (zones) |*z| {
        z.band_top = y_cursor;
        z.band_bot = y_cursor + band_h;
        y_cursor += band_h + Layout.band_gap;
    }
}

// -----------------------------------------------------------------------
// Raylib drawing helpers (unchanged, but kept clean)
// -----------------------------------------------------------------------
const palette = struct {
    pub const bg = rl.Color{ .r = 48, .g = 52, .b = 70, .a = 255 };
    pub const zone_fill = rl.Color{ .r = 65, .g = 69, .b = 89, .a = 255 };
    pub const zone_stroke = rl.Color{ .r = 115, .g = 121, .b = 148, .a = 255 };
    pub const slot_off = rl.Color{ .r = 115, .g = 121, .b = 148, .a = 255 };
    pub const slot_on_fill = rl.Color{ .r = 166, .g = 209, .b = 137, .a = 255 };
    pub const slot_on_stroke = rl.Color{ .r = 129, .g = 200, .b = 190, .a = 255 };
    pub const qdot = rl.Color{ .r = 131, .g = 139, .b = 167, .a = 100 };
    pub const qact_fill = rl.Color{ .r = 239, .g = 159, .b = 118, .a = 255 };
    pub const qact_stroke = rl.Color{ .r = 234, .g = 153, .b = 156, .a = 255 };
    pub const qmeas_fill = rl.Color{ .r = 244, .g = 184, .b = 228, .a = 255 };
    pub const qmeas_stroke = rl.Color{ .r = 202, .g = 158, .b = 230, .a = 255 };
    pub const arrow = rl.Color{ .r = 229, .g = 200, .b = 144, .a = 255 };
    pub const text = rl.Color{ .r = 198, .g = 208, .b = 245, .a = 255 };
    pub const text_sub = rl.Color{ .r = 165, .g = 173, .b = 206, .a = 255 };
};

fn projectV(cam: Layout, p: Point) rl.Vector2 {
    const proj = cam.project(p);
    return .{ .x = @floatCast(proj.x), .y = @floatCast(proj.y) };
}

fn drawArrow(start: rl.Vector2, end: rl.Vector2, thickness: f32, color: rl.Color) void {
    rl.drawLineEx(start, end, thickness, color);
    const dx = end.x - start.x;
    const dy = end.y - start.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;
    const head_len: f32 = 9.0;
    const wing_off: f32 = std.math.pi / 7.0;
    const ang = std.math.atan2(dy, dx);
    const a1 = ang + std.math.pi - wing_off;
    const a2 = ang + std.math.pi + wing_off;
    const w1 = rl.Vector2{
        .x = end.x + std.math.cos(a1) * head_len,
        .y = end.y + std.math.sin(a1) * head_len,
    };
    const w2 = rl.Vector2{
        .x = end.x + std.math.cos(a2) * head_len,
        .y = end.y + std.math.sin(a2) * head_len,
    };
    rl.drawLineEx(end, w1, thickness, color);
    rl.drawLineEx(end, w2, thickness, color);
}

// -----------------------------------------------------------------------
// Drawing a single frame – broken into small, clear steps
// -----------------------------------------------------------------------
fn drawZoneBackground(zone: Zone, index: usize) void {
    const rect = rl.Rectangle{
        .x = 30,
        .y = @floatCast(zone.band_top),
        .width = 1500,
        .height = @floatCast(zone.band_bot - zone.band_top),
    };
    rl.drawRectangleRec(rect, palette.zone_fill);

    var buf: [128]u8 = undefined;
    const label = std.fmt.bufPrintZ(&buf, "zone {d}  ·  y={d}..{d}", .{ index, zone.y_lo, zone.y_hi }) catch "?";
    rl.drawText(label, 42, @intFromFloat(zone.band_top + 6), 11, palette.text_sub);
}

fn drawSlot(cam: Layout, slot: Point, positions: []const Point) void {
    var occupied = false;
    for (positions) |p| {
        if (p.x == slot.x and p.y == slot.y) {
            occupied = true;
            break;
        }
    }
    const c = projectV(cam, slot);
    const r: f32 = @floatCast(cam.radius * 1.3);
    if (occupied) {
        rl.drawCircleV(c, r, palette.slot_on_fill);
        rl.drawCircleLinesV(c, r, palette.slot_on_stroke);
    } else {
        rl.drawCircleLinesV(c, r, palette.slot_off);
    }
}

fn drawHeader(frame_idx: usize, op: Op, total_frames: usize, playing: bool) void {
    var buf: [128]u8 = undefined;
    const header = std.fmt.bufPrintZ(&buf, "frame {d:0>3}  ·  t={d}  ·  {s}", .{
        frame_idx, op.t, @tagName(op.kind),
    }) catch "?";
    rl.drawText(header, 30, 18, 24, palette.text);

    var footer_buf: [160]u8 = undefined;
    const footer = std.fmt.bufPrintZ(&footer_buf, "{d}/{d}   j/k step   space {s}   esc quit", .{
        frame_idx + 1,
        total_frames,
        if (playing) "pause" else "play",
    }) catch "?";
    rl.drawText(footer, 30, @intFromFloat(Layout.canvas_h - 26), 12, palette.text_sub);
}

fn drawOperationInfo(op: Op) struct { fill: rl.Color, stroke: rl.Color } {
    var fill = palette.qact_fill;
    var stroke = palette.qact_stroke;
    var text: [192]u8 = undefined;

    switch (op.kind) {
        .move => |m| {
            const sub = std.fmt.bufPrintZ(&text, "aod={d}  axis={s}  {s} → {s}  ({d} atoms)", .{
                m.aod, @tagName(m.translate), @tagName(m.src_zone), @tagName(m.dest_zone), m.atoms.len,
            }) catch "?";
            rl.drawText(sub, 30, 44, 13, palette.text_sub);
        },
        .raman => |r| {
            const sub = std.fmt.bufPrintZ(&text, "angle={d:.4}  phase={d:.4}  ({d} targets)", .{
                r.angle, r.phase, r.targets.len,
            }) catch "?";
            rl.drawText(sub, 30, 44, 13, palette.text_sub);
        },
        .rydberg => |r| {
            const sub = std.fmt.bufPrintZ(&text, "zone={s}", .{@tagName(r.zone)}) catch "?";
            rl.drawText(sub, 30, 44, 13, palette.text_sub);
        },
        .measure => |m| {
            const sub = std.fmt.bufPrintZ(&text, "zone={s}  ({d} qubits)", .{ @tagName(m.zone), m.qubits.len }) catch "?";
            rl.drawText(sub, 30, 44, 13, palette.text_sub);
            fill = palette.qmeas_fill;
            stroke = palette.qmeas_stroke;
        },
    }
    return .{ .fill = fill, .stroke = stroke };
}

fn drawInactiveQubits(cam: Layout, positions: []const Point, active: []bool) void {
    for (positions, 0..) |p, id| {
        if (!active[id]) {
            const c = projectV(cam, p);
            rl.drawCircleV(c, 5.0, palette.qdot);
        }
    }
}

fn drawActiveQubits(cam: Layout, positions: []const Point, active: []bool, fill: rl.Color, stroke: rl.Color) void {
    for (positions, 0..) |p, id| {
        if (active[id]) {
            const c = projectV(cam, p);
            const r: f32 = @floatCast(cam.radius);
            rl.drawCircleV(c, r, fill);
            rl.drawCircleLinesV(c, r, stroke);

            var buf: [16]u8 = undefined;
            const label = std.fmt.bufPrintZ(&buf, "{d}", .{id}) catch "?";
            const text_w = rl.measureText(label, 11);

            const cx: i32 = @intFromFloat(c.x);
            const cy: i32 = @intFromFloat(c.y);
            rl.drawText(label, cx - @divTrunc(text_w, 2), cy - 5, 14, palette.text);
        }
    }
}

fn drawArrowsForMove(cam: Layout, op: Op, active: []bool) void {
    if (op.kind != .move) return;
    for (op.kind.move.atoms) |a| {
        active[a.qubit] = true;
        drawArrow(projectV(cam, a.src), projectV(cam, a.dest), 1.5, palette.arrow);
    }
}

fn markActiveQubits(op: Op, active: []bool) void {
    switch (op.kind) {
        .move => |m| {
            for (m.atoms) |a| active[a.qubit] = true;
        },
        .raman => |r| {
            for (r.targets) |t| active[t.qubit] = true;
        },
        .measure => |m| {
            for (m.qubits) |q| active[q] = true;
        },
        else => {},
    }
}

fn drawFrame(
    cam: Layout,
    positions: []const Point,
    slots: []const Point,
    active: []bool,
    op: Op,
    frame_idx: usize,
    total_frames: usize,
    playing: bool,
) void {
    // reset active flags
    @memset(active, false);

    // 1. zone backdrops
    for (cam.zones, 0..) |z, zi| drawZoneBackground(z, zi);

    // 2. slots
    for (slots) |s| drawSlot(cam, s, positions);

    // 3. header + footer
    drawHeader(frame_idx, op, total_frames, playing);

    // 4. operation info and pick highlight colours
    const colors = drawOperationInfo(op);

    // 5. mark which qubits are involved in this operation
    markActiveQubits(op, active);

    // 6. draw arrows for move ops (must happen before qubits)
    drawArrowsForMove(cam, op, active);

    // 7. inactive qubits (dim dots)
    drawInactiveQubits(cam, positions, active);

    // 8. active qubits (coloured circles with labels)
    drawActiveQubits(cam, positions, active, colors.fill, colors.stroke);
}

// -----------------------------------------------------------------------
// Build initial positions by applying moves backwards
// -----------------------------------------------------------------------
fn initialPositions(allocator: std.mem.Allocator, final: []const Point, ops: []const Op) ![]Point {
    var positions = try allocator.dupe(Point, final);
    var i = ops.len;
    while (i > 0) {
        i -= 1;
        if (ops[i].kind == .move) {
            for (ops[i].kind.move.atoms) |a| {
                positions[a.qubit] = a.src;
            }
        }
    }
    return positions;
}

// -----------------------------------------------------------------------
// Apply one operation to a position slice
// -----------------------------------------------------------------------
fn applyOp(positions: []Point, op: Op) void {
    if (op.kind == .move) {
        for (op.kind.move.atoms) |a| {
            positions[a.qubit] = a.dest;
        }
    }
}

// -----------------------------------------------------------------------
// Main interactive slideshow
// -----------------------------------------------------------------------
pub fn showSlideshow(allocator: std.mem.Allocator, s: schedule.PhysicalSchedule) !void {
    if (s.placement.len == 0 or s.ops.len == 0) return;

    // initial positions (before any op)
    const initial_pos = try initialPositions(allocator, s.placement, s.ops);
    defer allocator.free(initial_pos);

    // pre‑compute positions after each frame
    const frame_count = s.ops.len;
    var frame_positions = try allocator.alloc([]Point, frame_count);
    defer {
        for (frame_positions) |fp| allocator.free(fp);
        allocator.free(frame_positions);
    }
    {
        const cur = try allocator.dupe(Point, initial_pos);
        defer allocator.free(cur);
        for (s.ops, 0..) |op, i| {
            frame_positions[i] = try allocator.dupe(Point, cur);
            applyOp(cur, op);
        }
    }

    // build camera once (same for all frames)
    const cam = try Layout.init(allocator, initial_pos, s.ops, s.compute_slots);
    defer allocator.free(cam.zones);

    // scratch active flags
    const active = try allocator.alloc(bool, initial_pos.len);
    defer allocator.free(active);

    // start window
    rl.setConfigFlags(rl.ConfigFlags{
        .Copyright
        .fullscreen_mode = true,
        .msaa_4x_hint = true,
        .window_highdpi = true,
    });

    rl.initWindow(@intFromFloat(Layout.canvas_w), @intFromFloat(Layout.canvas_h), "Physical schedule slideshow");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var frame: usize = 0;
    var playing = false;
    var timer: f32 = 0.0;
    const step_sec: f32 = 0.7;

    while (!rl.windowShouldClose()) {
        // keyboard
        if (rl.isKeyPressed(.k)) {
            playing = false;
            frame = @min(frame + 1, frame_count - 1);
        }
        if (rl.isKeyPressed(.j)) {
            playing = false;
            if (frame > 0) frame -= 1;
        }
        if (rl.isKeyPressed(.space)) {
            playing = !playing;
            timer = 0;
        }

        if (playing) {
            timer += rl.getFrameTime();
            if (timer >= step_sec) {
                timer = 0;
                if (frame + 1 < frame_count) frame += 1 else playing = false;
            }
        }

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(palette.bg);

        drawFrame(
            cam,
            frame_positions[frame],
            s.compute_slots,
            active,
            s.ops[frame],
            frame,
            frame_count,
            playing,
        );
    }
}
