const std = @import("std");
const rl = @import("raylib");
const schedule = @import("schedule");

const Point = schedule.Point;
const Op = schedule.Op;

const Zone2 = struct {
    y_lo: i32,
    y_hi: i32,
    x_lo: i32,
    x_hi: i32,
    band_top: f64,
    band_bot: f64,
};

const Camera = struct {
    zones: []const Zone2,
    radius: f64,

    const canvas_w: f64 = 1000;
    const canvas_h: f64 = 700;
    const header_h: f64 = 70;
    const margin: f64 = 50;
    const band_gap: f64 = 36;

    fn zoneOf(s: Camera, p: Point) Zone2 {
        for (s.zones) |z| if (p.y >= z.y_lo and p.y <= z.y_hi) return z;
        return s.zones[0];
    }

    fn project(s: Camera, p: Point) struct { x: f64, y: f64 } {
        const z = s.zoneOf(p);
        const x_span: f64 = @floatFromInt(z.x_hi - z.x_lo);
        const y_span: f64 = @floatFromInt(z.y_hi - z.y_lo);
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

fn computeCamera(allocator: std.mem.Allocator, positions: []const Point, ops: []const Op, slots: []const Point) !Camera {
    // 1. Every y value the slideshow will touch.
    var ys: std.ArrayListUnmanaged(i32) = .empty;
    defer ys.deinit(allocator);
    for (positions) |p| try ys.append(allocator, p.y);
    for (slots) |s| try ys.append(allocator, s.y);
    for (ops) |op| switch (op.kind) {
        .move => |m| for (m.atoms) |a| {
            try ys.append(allocator, a.src.y);
            try ys.append(allocator, a.dest.y);
        },
        else => {},
    };
    std.mem.sort(i32, ys.items, {}, std.sort.asc(i32));

    // 2. Smallest non-zero gap; anything ≥10× this is a zone boundary.
    var min_gap: i32 = std.math.maxInt(i32);
    for (ys.items[1..], 0..) |v, i| {
        const g = v - ys.items[i];
        if (g > 0 and g < min_gap) min_gap = g;
    }
    if (min_gap == std.math.maxInt(i32)) min_gap = 1;
    const threshold = min_gap * 10;

    // 3. Cut into zones at the big gaps.
    var zones: std.ArrayListUnmanaged(Zone2) = .empty;
    var lo = ys.items[0];
    for (ys.items[1..], 0..) |v, i| {
        if (v - ys.items[i] > threshold) {
            try zones.append(allocator, .{ .y_lo = lo, .y_hi = ys.items[i], .x_lo = 0, .x_hi = 0, .band_top = 0, .band_bot = 0 });
            lo = v;
        }
    }
    try zones.append(allocator, .{ .y_lo = lo, .y_hi = ys.items[ys.items.len - 1], .x_lo = 0, .x_hi = 0, .band_top = 0, .band_bot = 0 });

    // 4. Per-zone x extent.
    for (zones.items) |*z| {
        z.x_lo = std.math.maxInt(i32);
        z.x_hi = std.math.minInt(i32);
    }
    const considerPoint = struct {
        fn f(zs: []Zone2, p: Point) void {
            for (zs) |*z| if (p.y >= z.y_lo and p.y <= z.y_hi) {
                if (p.x < z.x_lo) z.x_lo = p.x;
                if (p.x > z.x_hi) z.x_hi = p.x;
                return;
            };
        }
    }.f;
    for (positions) |p| considerPoint(zones.items, p);
    for (slots) |s| considerPoint(zones.items, s);
    for (ops) |op| switch (op.kind) {
        .move => |m| for (m.atoms) |a| {
            considerPoint(zones.items, a.src);
            considerPoint(zones.items, a.dest);
        },
        else => {},
    };

    // 5. Top-down by physical y (highest y first → highest on canvas).
    std.mem.sort(Zone2, zones.items, {}, struct {
        fn lt(_: void, a: Zone2, b: Zone2) bool {
            return a.y_hi > b.y_hi;
        }
    }.lt);

    // 6. Allocate equal canvas bands.
    const n: f64 = @floatFromInt(zones.items.len);
    const draw_h = Camera.canvas_h - Camera.header_h - Camera.margin;
    const usable = draw_h - Camera.band_gap * (n - 1);
    const band_h = usable / n;
    var y_cursor: f64 = Camera.header_h;
    for (zones.items) |*z| {
        z.band_top = y_cursor;
        z.band_bot = y_cursor + band_h;
        y_cursor += band_h + Camera.band_gap;
    }

    return .{ .zones = try zones.toOwnedSlice(allocator), .radius = 7.0 };
}

// ======================================================================
// raylib rendering
// ======================================================================

/// Colour palette transcribed from the original SVG stylesheet so the
/// raylib viewer looks identical to the exported frames.
const palette = struct {
    pub const bg = rl.Color{ .r = 48, .g = 52, .b = 70, .a = 255 }; // base
    pub const zone_fill = rl.Color{ .r = 65, .g = 69, .b = 89, .a = 255 }; // surface0
    pub const zone_stroke = rl.Color{ .r = 115, .g = 121, .b = 148, .a = 255 }; // overlay0
    pub const slot_off = rl.Color{ .r = 115, .g = 121, .b = 148, .a = 255 }; // overlay0
    pub const slot_on_fill = rl.Color{ .r = 166, .g = 209, .b = 137, .a = 255 }; // green
    pub const slot_on_stroke = rl.Color{ .r = 129, .g = 200, .b = 190, .a = 255 }; // teal
    pub const qdot = rl.Color{ .r = 131, .g = 139, .b = 167, .a = 100 }; // overlay1, dimmed
    pub const qact_fill = rl.Color{ .r = 239, .g = 159, .b = 118, .a = 255 }; // peach
    pub const qact_stroke = rl.Color{ .r = 234, .g = 153, .b = 156, .a = 255 }; // maroon
    pub const qmeas_fill = rl.Color{ .r = 244, .g = 184, .b = 228, .a = 255 }; // pink
    pub const qmeas_stroke = rl.Color{ .r = 202, .g = 158, .b = 230, .a = 255 }; // mauve
    pub const arrow = rl.Color{ .r = 229, .g = 200, .b = 144, .a = 255 }; // yellow
    pub const text = rl.Color{ .r = 198, .g = 208, .b = 245, .a = 255 }; // text
    pub const text_sub = rl.Color{ .r = 165, .g = 173, .b = 206, .a = 255 }; // subtext0
};

fn projectV(cam: Camera, p: Point) rl.Vector2 {
    const proj = cam.project(p);
    return .{ .x = @floatCast(proj.x), .y = @floatCast(proj.y) };
}

/// Approximate the SVG `marker-end` arrowhead with two short line segments.
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

/// Manual dashed line; raylib has no built-in dashed primitive.
fn drawDashedLine(a: rl.Vector2, b: rl.Vector2, dash: f32, gap: f32, color: rl.Color) void {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;
    const ux = dx / len;
    const uy = dy / len;
    var t: f32 = 0;
    while (t < len) {
        const e = @min(t + dash, len);
        const p0 = rl.Vector2{ .x = a.x + ux * t, .y = a.y + uy * t };
        const p1 = rl.Vector2{ .x = a.x + ux * e, .y = a.y + uy * e };
        rl.drawLineV(p0, p1, color);
        t = e + gap;
    }
}

fn drawDashedRect(rect: rl.Rectangle, dash: f32, gap: f32, color: rl.Color) void {
    const x = rect.x;
    const y = rect.y;
    const w = rect.width;
    const h = rect.height;
    drawDashedLine(.{ .x = x, .y = y }, .{ .x = x + w, .y = y }, dash, gap, color);
    drawDashedLine(.{ .x = x + w, .y = y }, .{ .x = x + w, .y = y + h }, dash, gap, color);
    drawDashedLine(.{ .x = x, .y = y + h }, .{ .x = x + w, .y = y + h }, dash, gap, color);
    drawDashedLine(.{ .x = x, .y = y }, .{ .x = x, .y = y + h }, dash, gap, color);
}

fn drawFrame(
    cam: Camera,
    positions: []const Point,
    slots: []const Point,
    active: []bool,
    op: Op,
    frame_idx: usize,
    total_frames: usize,
    playing: bool,
) void {
    @memset(active, false);

    // Zone backdrops + labels.
    for (cam.zones, 0..) |z, zi| {
        const rect = rl.Rectangle{
            .x = 30,
            .y = @floatCast(z.band_top),
            .width = 940,
            .height = @floatCast(z.band_bot - z.band_top),
        };
        rl.drawRectangleRec(rect, palette.zone_fill);
        drawDashedRect(rect, 5, 4, palette.zone_stroke);

        var buf: [128]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "zone {d}  ·  y={d}..{d}", .{ zi, z.y_lo, z.y_hi }) catch "?";
        rl.drawText(label, 42, @intFromFloat(z.band_top + 6), 11, palette.text_sub);
    }

    // Compute slot indicators: grey ring if empty, green disc if occupied.
    for (slots) |s| {
        var occupied = false;
        for (positions) |p| if (p.x == s.x and p.y == s.y) {
            occupied = true;
            break;
        };
        const c = projectV(cam, s);
        const r: f32 = @floatCast(cam.radius * 1.3);
        if (occupied) {
            rl.drawCircleV(c, r, palette.slot_on_fill);
            rl.drawCircleLinesV(c, r, palette.slot_on_stroke);
        } else {
            rl.drawCircleLinesV(c, r, palette.slot_off);
        }
    }

    // Header.
    {
        var buf: [128]u8 = undefined;
        const header = std.fmt.bufPrintZ(&buf, "frame {d:0>3}  ·  t={d}  ·  {s}", .{
            frame_idx, op.t, @tagName(op.kind),
        }) catch "?";
        rl.drawText(header, 30, 18, 18, palette.text);
    }

    // Footer with controls hint.
    {
        var buf: [160]u8 = undefined;
        const footer = std.fmt.bufPrintZ(&buf, "{d}/{d}   j/k step   space {s}   esc quit", .{
            frame_idx + 1,
            total_frames,
            if (playing) "pause" else "play",
        }) catch "?";
        rl.drawText(footer, 30, @intFromFloat(Camera.canvas_h - 26), 12, palette.text_sub);
    }

    // Per-op visual + sub-text + active-qubit colour selection.
    var highlight_fill = palette.qact_fill;
    var highlight_stroke = palette.qact_stroke;

    switch (op.kind) {
        .move => |m| {
            var buf: [192]u8 = undefined;
            const sub = std.fmt.bufPrintZ(&buf, "aod={d}  axis={s}  {s} → {s}  ({d} atoms)", .{
                m.aod, @tagName(m.translate), @tagName(m.src_zone), @tagName(m.dest_zone), m.atoms.len,
            }) catch "?";
            rl.drawText(sub, 30, 44, 13, palette.text_sub);

            for (m.atoms) |a| {
                active[a.qubit] = true;
                drawArrow(projectV(cam, a.src), projectV(cam, a.dest), 1.5, palette.arrow);
            }
        },
        .raman => |r| {
            var buf: [160]u8 = undefined;
            const sub = std.fmt.bufPrintZ(&buf, "angle={d:.4}  phase={d:.4}  ({d} targets)", .{
                r.angle, r.phase, r.targets.len,
            }) catch "?";
            rl.drawText(sub, 30, 44, 13, palette.text_sub);

            for (r.targets) |t| active[t.qubit] = true;
        },
        .rydberg => |r| {
            var buf: [96]u8 = undefined;
            const sub = std.fmt.bufPrintZ(&buf, "zone={s}", .{@tagName(r.zone)}) catch "?";
            rl.drawText(sub, 30, 44, 13, palette.text_sub);
        },
        .measure => |m| {
            var buf: [96]u8 = undefined;
            const sub = std.fmt.bufPrintZ(&buf, "zone={s}  ({d} qubits)", .{
                @tagName(m.zone), m.qubits.len,
            }) catch "?";
            rl.drawText(sub, 30, 44, 13, palette.text_sub);

            highlight_fill = palette.qmeas_fill;
            highlight_stroke = palette.qmeas_stroke;
            for (m.qubits) |q| active[q] = true;
        },
    }

    // Inactive qubits first: small dim dots, no label.
    for (positions, 0..) |p, id| if (!active[id]) {
        const c = projectV(cam, p);
        rl.drawCircleV(c, 2.0, palette.qdot);
    };

    // Active qubits on top so the arrows / highlights sit cleanly.
    for (positions, 0..) |p, id| if (active[id]) {
        const c = projectV(cam, p);
        const r: f32 = @floatCast(cam.radius);
        rl.drawCircleV(c, r, highlight_fill);
        rl.drawCircleLinesV(c, r, highlight_stroke);

        var buf: [16]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "{d}", .{id}) catch "?";
        const text_w = rl.measureText(label, 11);
        rl.drawText(
            label,
            @as(i32, @intFromFloat(c.x)) - @divFloor(text_w, 2),
            @as(i32, @intFromFloat(c.y)) - 5,
            11,
            palette.text,
        );
    };
}

fn initialPositions(allocator: std.mem.Allocator, final: []const Point, ops: []const Op) ![]Point {
    const positions = try allocator.dupe(Point, final);
    var i = ops.len;
    while (i > 0) {
        i -= 1;
        switch (ops[i].kind) {
            .move => |m| for (m.atoms) |a| {
                positions[a.qubit] = a.src;
            },
            else => {},
        }
    }
    return positions;
}

fn applyOp(positions: []Point, op: Op) void {
    switch (op.kind) {
        .move => |m| for (m.atoms) |a| {
            positions[a.qubit] = a.dest;
        },
        else => {},
    }
}

/// Open a raylib window and step through the schedule interactively.
///   j / k     step back / forward one frame
///   space     toggle auto-play
///   esc       quit (raylib's default)
pub fn showSlideshow(
    allocator: std.mem.Allocator,
    s: schedule.PhysicalSchedule,
) !void {
    if (s.placement.len == 0 or s.ops.len == 0) return;

    // Positions of every qubit before any operation has been applied.
    const positions0 = try initialPositions(allocator, s.placement, s.ops);
    defer allocator.free(positions0);

    // Pre-compute each frame's position state so the user can scrub back
    // and forth without re-simulating the schedule on every keystroke.
    const frames = s.ops.len;
    const positions_per_frame = try allocator.alloc([]Point, frames);
    defer {
        for (positions_per_frame) |row| allocator.free(row);
        allocator.free(positions_per_frame);
    }
    {
        const cur = try allocator.dupe(Point, positions0);
        defer allocator.free(cur);
        for (s.ops, 0..) |op, i| {
            positions_per_frame[i] = try allocator.dupe(Point, cur);
            applyOp(cur, op);
        }
    }

    // Camera bounds are derived from every position the slideshow ever
    // touches, so the same projection is valid for every frame.
    const cam = try computeCamera(allocator, positions0, s.ops, s.compute_slots);
    defer allocator.free(cam.zones);

    // Scratch buffer reused each frame to mark which qubits are "active".
    const active = try allocator.alloc(bool, positions0.len);
    defer allocator.free(active);

    // ---- raylib window ---------------------------------------------------
    rl.initWindow(
        @intFromFloat(Camera.canvas_w),
        @intFromFloat(Camera.canvas_h),
        "Physical schedule slideshow",
    );
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var frame: usize = 0;
    var playing: bool = false;
    var play_timer: f32 = 0.0;
    const play_period: f32 = 0.7;

    while (!rl.windowShouldClose()) {
        // ---- input ------------------------------------------------------
        if (rl.isKeyPressed(.k)) {
            playing = false;
            if (frame + 1 < frames) frame += 1;
        }
        if (rl.isKeyPressed(.j)) {
            playing = false;
            if (frame > 0) frame -= 1;
        }
        if (rl.isKeyPressed(.space)) {
            playing = !playing;
            play_timer = 0;
        }

        if (playing) {
            play_timer += rl.getFrameTime();
            if (play_timer >= play_period) {
                play_timer = 0;
                if (frame + 1 < frames) {
                    frame += 1;
                } else {
                    playing = false;
                }
            }
        }

        // ---- draw -------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(palette.bg);
        drawFrame(
            cam,
            positions_per_frame[frame],
            s.compute_slots,
            active,
            s.ops[frame],
            frame,
            frames,
            playing,
        );
    }
}
