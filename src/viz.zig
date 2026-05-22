const std = @import("std");
const rl = @import("raylib");
const schedule = @import("schedule");
const arch_mod = @import("arch");

const Point = schedule.Point;
const Op = schedule.Op;

const palette = struct {
    pub const bg = rl.Color{ .r = 48, .g = 52, .b = 70, .a = 255 };
    pub const slot_off = rl.Color{ .r = 115, .g = 121, .b = 148, .a = 255 };
    pub const slot_on_fill = rl.Color{ .r = 166, .g = 209, .b = 137, .a = 255 };
    pub const slot_on_stroke = rl.Color{ .r = 129, .g = 200, .b = 190, .a = 255 };
    pub const qdot = rl.Color{ .r = 131, .g = 139, .b = 167, .a = 100 };
    pub const qact_fill = rl.Color{ .r = 129, .g = 200, .b = 190, .a = 255 };
    pub const qact_stroke = rl.Color{ .r = 234, .g = 153, .b = 156, .a = 255 };
    pub const qmeas_fill = rl.Color{ .r = 244, .g = 184, .b = 228, .a = 255 };
    pub const qmeas_stroke = rl.Color{ .r = 202, .g = 158, .b = 230, .a = 255 };
    pub const arrow = rl.Color{ .r = 181, .g = 190, .b = 226, .a = 255 };
    pub const text = rl.Color{ .r = 198, .g = 208, .b = 245, .a = 255 };
    pub const text_sub = rl.Color{ .r = 165, .g = 173, .b = 206, .a = 255 };
    pub const zone_storage = rl.Color{ .r = 56, .g = 62, .b = 82, .a = 80 };
    pub const zone_compute = rl.Color{ .r = 46, .g = 70, .b = 66, .a = 90 };
    pub const zone_compute_active = rl.Color{ .r = 65, .g = 130, .b = 120, .a = 120 };
    pub const zone_border = rl.Color{ .r = 115, .g = 121, .b = 148, .a = 100 };
};

const BBox = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    fn dx(self: BBox) f32 {
        return self.max_x - self.min_x;
    }

    fn dy(self: BBox) f32 {
        return self.max_y - self.min_y;
    }

    fn cx(self: BBox) f32 {
        return (self.min_x + self.max_x) / 2;
    }

    fn cy(self: BBox) f32 {
        return (self.min_y + self.max_y) / 2;
    }

    fn pad(self: BBox) f32 {
        return 2 * @max(self.dx() * 0.1, self.dy() * 0.1);
    }
};

// -----------------------------------------------------------------------
// Simple 2D camera with pan & zoom
// -----------------------------------------------------------------------
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

    fn fitToRect(
        self: *Camera,
        bbox: BBox,
        screen_w: f32,
        screen_h: f32,
    ) void {
        self.zoom = @min(screen_w / (bbox.dx() + bbox.pad()), screen_h / (bbox.dy() + bbox.pad()));

        const center = rl.Vector2{ .x = bbox.cx(), .y = bbox.cy() };
        self.offset = .{
            .x = center.x - screen_w / (2 * self.zoom),
            .y = center.y - screen_h / (2 * self.zoom),
        };
    }
};

fn computeBoundingBox(slots: []const Point) BBox {
    if (slots.len == 0) return .{
        .min_x = -10,
        .min_y = -10,
        .max_x = 10,
        .max_y = 10,
    };

    var min_x = std.math.floatMax(f32);
    var min_y = std.math.floatMax(f32);
    var max_x = std.math.floatMin(f32);
    var max_y = std.math.floatMin(f32);

    for (slots) |s| {
        const x: f32 = @floatFromInt(s.x);
        const y: f32 = @floatFromInt(s.y);
        min_x = @min(min_x, x);
        min_y = @min(min_y, y);
        max_x = @max(max_x, x);
        max_y = @max(max_y, y);
    }

    return .{
        .min_x = min_x,
        .min_y = min_y,
        .max_x = max_x,
        .max_y = max_y,
    };
}

fn drawArrow(start: rl.Vector2, end: rl.Vector2, thickness: f32, color: rl.Color) void {
    rl.drawLineEx(start, end, thickness, color);
    const dx = end.x - start.x;
    const dy = end.y - start.y;
    const head_len: f32 = 15.0;
    const wing_off: f32 = std.math.pi / 7.0;
    const ang = std.math.atan2(dy, dx);
    const a1 = ang + std.math.pi - wing_off;
    const a2 = ang + std.math.pi + wing_off;
    const w1 = rl.Vector2{ .x = end.x + std.math.cos(a1) * head_len, .y = end.y + std.math.sin(a1) * head_len };
    const w2 = rl.Vector2{ .x = end.x + std.math.cos(a2) * head_len, .y = end.y + std.math.sin(a2) * head_len };
    rl.drawLineEx(end, w1, thickness, color);
    rl.drawLineEx(end, w2, thickness, color);
}

// ZoneRect in world-space (nm).
const ZoneRect = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

fn slmZoneRect(zone_ox: i32, zone_oy: i32, slm: arch_mod.Slm) ZoneRect {
    const pad_x: i32 = @intCast(slm.sep_nm[0] / 2);
    const pad_y: i32 = @intCast(slm.sep_nm[1] / 2);
    const x0 = zone_ox + slm.offset_nm[0] - pad_x;
    const y0 = zone_oy + slm.offset_nm[1] - pad_y;
    const x1 = x0 + @as(i32, @intCast((slm.num_col - 1) * slm.sep_nm[0])) + 2 * pad_x;
    const y1 = y0 + @as(i32, @intCast((slm.num_row - 1) * slm.sep_nm[1])) + 2 * pad_y;
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

fn drawZone(cam: Camera, font: rl.Font, r: ZoneRect, fill: rl.Color, label: [:0]const u8) void {
    const tl = cam.worldToScreen(.{ .x = @floatFromInt(r.x0), .y = @floatFromInt(r.y0) });
    const br = cam.worldToScreen(.{ .x = @floatFromInt(r.x1), .y = @floatFromInt(r.y1) });
    const rec = rl.Rectangle{ .x = tl.x, .y = tl.y, .width = br.x - tl.x, .height = br.y - tl.y };
    rl.drawRectangleRounded(rec, 0.06, 8, fill);
    rl.drawRectangleRoundedLinesEx(rec, 0.06, 8, 1.0, palette.zone_border);
    rl.drawTextEx(font, label, .{ .x = tl.x + 8, .y = tl.y + 6 }, 13, 0.5, palette.text_sub);
}

fn drawSlot(cam: Camera, slot: Point, positions: []const Point) void {
    const world = rl.Vector2{ .x = @floatFromInt(slot.x), .y = @floatFromInt(slot.y) };
    const screen = cam.worldToScreen(world);
    const world_radius: f32 = 600.0;
    const screen_radius = world_radius * cam.zoom;
    var occupied = false;
    for (positions) |p| {
        if (p.x == slot.x and p.y == slot.y) {
            occupied = true;
            break;
        }
    }
    if (occupied) {
        rl.drawCircleV(screen, screen_radius, palette.slot_on_fill);
    } else {
        rl.drawCircleLinesV(screen, screen_radius, palette.slot_off);
    }
}

fn drawQubit(cam: Camera, font: rl.Font, pos: Point, id: usize, active: bool, fill: rl.Color, stroke: rl.Color) void {
    const world = rl.Vector2{ .x = @floatFromInt(pos.x), .y = @floatFromInt(pos.y) };
    const screen = cam.worldToScreen(world);
    const world_radius: f32 = 600.0;
    const screen_radius = world_radius * cam.zoom;

    rl.drawCircleV(screen, screen_radius, palette.qdot);

    if (active) {
        rl.drawCircleV(screen, screen_radius, fill);
        rl.drawCircleLinesV(screen, screen_radius * 1.5, stroke);

        var buf: [16]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "{d}", .{id}) catch "?";
        const font_size: f32 = 28;
        rl.drawTextEx(font, label, .{ .x = screen.x + screen_radius + 4, .y = screen.y - font_size / 2.0 }, font_size, 0.5, palette.text);
    }
}

fn drawHeader(font: rl.Font, op: Op, frame: usize, total: usize, playing: bool) void {
    const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
    const margin: f32 = 22;

    var buf: [128]u8 = undefined;
    const header = std.fmt.bufPrintZ(&buf, "t={d}  {s}  [{d}/{d}]", .{ op.t, @tagName(op.kind), frame + 1, total }) catch "?";
    rl.drawTextEx(font, header, .{ .x = margin, .y = margin }, 40, 0.8, palette.text);

    var footer_buf: [192]u8 = undefined;
    const footer = std.fmt.bufPrintZ(&footer_buf, "j/k step   space {s}   r reset   scroll zoom   right-drag pan", .{
        if (playing) "pause" else "play",
    }) catch "?";
    rl.drawTextEx(font, footer, .{ .x = margin, .y = screen_h - margin - 14 }, 28, 0.8, palette.text_sub);
}

fn drawOperationInfo(font: rl.Font, op: Op) struct { fill: rl.Color, stroke: rl.Color } {
    const margin: f32 = 22;
    const y: f32 = 22 + 26 + 6;
    var text: [192]u8 = undefined;

    switch (op.kind) {
        .move => |m| {
            const sub = std.fmt.bufPrintZ(&text, "aod={d}  axis={s}  {s} → {s}  ({d} atoms)", .{
                m.aod, @tagName(m.translate), @tagName(m.src_zone), @tagName(m.dest_zone), m.atoms.len,
            }) catch "?";
            rl.drawTextEx(font, sub, .{ .x = margin, .y = y }, 28, 0.8, palette.text_sub);
            return .{ .fill = palette.qact_fill, .stroke = palette.qact_stroke };
        },
        .raman => |r| {
            const sub = std.fmt.bufPrintZ(&text, "angle={d:.4}  phase={d:.4}  ({d} targets)", .{
                r.angle, r.phase, r.targets.len,
            }) catch "?";
            rl.drawTextEx(font, sub, .{ .x = margin, .y = y }, 28, 0.8, palette.text_sub);
            return .{ .fill = palette.qmeas_fill, .stroke = palette.qmeas_stroke };
        },
        .rydberg => |r| {
            const sub = std.fmt.bufPrintZ(&text, "zone={s}", .{@tagName(r.zone)}) catch "?";
            rl.drawTextEx(font, sub, .{ .x = margin, .y = y }, 28, 0.8, palette.text_sub);
            return .{ .fill = palette.qact_fill, .stroke = palette.qact_stroke };
        },
        .measure => |m| {
            const sub = std.fmt.bufPrintZ(&text, "zone={s}  ({d} qubits)", .{ @tagName(m.zone), m.qubits.len }) catch "?";
            rl.drawTextEx(font, sub, .{ .x = margin, .y = y }, 28, 0.8, palette.text_sub);
            return .{ .fill = palette.qmeas_fill, .stroke = palette.qmeas_stroke };
        },
    }
}

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
// Main interactive slideshow
// -----------------------------------------------------------------------
pub fn showSlideshow(allocator: std.mem.Allocator, layout: arch_mod.ArchConfig, s: schedule.PhysicalSchedule) !void {
    if (s.placement.len == 0 or s.ops.len == 0) return;

    const initial_pos = try initialPositions(allocator, s.placement, s.ops);
    defer allocator.free(initial_pos);

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
            if (op.kind == .move) {
                for (op.kind.move.atoms) |a| {
                    cur[a.qubit] = a.dest;
                }
            }
        }
    }

    // Pre-compute zone rects (world-space nm) for background drawing.
    const sz = layout.storage_zone;
    const storage_rect = slmZoneRect(sz.offset_nm[0], sz.offset_nm[1], sz.slm);

    const ez = layout.entanglement_zone;
    var compute_rect = slmZoneRect(ez.offset_nm[0], ez.offset_nm[1], ez.slms[0]);
    for (ez.slms[1..]) |slm| {
        const r = slmZoneRect(ez.offset_nm[0], ez.offset_nm[1], slm);
        compute_rect.x0 = @min(compute_rect.x0, r.x0);
        compute_rect.y0 = @min(compute_rect.y0, r.y0);
        compute_rect.x1 = @max(compute_rect.x1, r.x1);
        compute_rect.y1 = @max(compute_rect.y1, r.y1);
    }

    rl.setConfigFlags(rl.ConfigFlags{
        .fullscreen_mode = true,
        .window_resizable = true,
        .msaa_4x_hint = true,
        .window_highdpi = true,
    });
    rl.setTraceLogLevel(rl.TraceLogLevel.err);

    rl.initWindow(0, 0, "Physical schedule slideshow");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    const font = rl.loadFontEx(
        "/home/ruben/.local/share/fonts/JetBrainsMonoNerdFont-Regular.ttf",
        64,
        null,
    ) catch try rl.getFontDefault();
    defer rl.unloadFont(font);
    rl.setTextureFilter(font.texture, .bilinear);

    const screen_w = rl.getScreenWidth();
    const screen_h = rl.getScreenHeight();

    const bbox = computeBoundingBox(s.compute_slots);
    var camera = Camera{};
    camera.fitToRect(bbox, @floatFromInt(screen_w), @floatFromInt(screen_h));

    var panning = false;
    var last_mouse_pos: rl.Vector2 = undefined;

    var frame: usize = 0;
    var playing = false;
    var timer: f32 = 0.0;
    const step_sec: f32 = 0.5;

    var active = try allocator.alloc(bool, initial_pos.len);
    defer allocator.free(active);

    while (!rl.windowShouldClose()) {
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
        if (rl.isKeyPressed(.r)) {
            camera.fitToRect(bbox, @floatFromInt(screen_w), @floatFromInt(screen_h));
            playing = false;
            timer = 0;
            frame = 0;
        }

        const mouse_pos = rl.getMousePosition();
        if (rl.isMouseButtonPressed(.right)) {
            panning = true;
            last_mouse_pos = mouse_pos;
        }
        if (rl.isMouseButtonReleased(.right)) panning = false;
        if (panning) {
            const delta = rl.Vector2{ .x = mouse_pos.x - last_mouse_pos.x, .y = mouse_pos.y - last_mouse_pos.y };
            camera.offset.x -= delta.x / camera.zoom;
            camera.offset.y -= delta.y / camera.zoom;
            last_mouse_pos = mouse_pos;
        }

        const wheel = rl.getMouseWheelMove();
        if (wheel != 0) {
            camera.zoom += wheel * 0.05 * camera.zoom;
            const mouse_world = camera.screenToWorld(mouse_pos);
            camera.offset.x = mouse_world.x - mouse_pos.x / camera.zoom;
            camera.offset.y = mouse_world.y - mouse_pos.y / camera.zoom;
        }

        if (playing) {
            timer += rl.getFrameTime();
            if (timer >= step_sec) {
                timer = 0;
                if (frame + 1 < frame_count) frame += 1 else playing = false;
            }
        }

        const op = s.ops[frame];

        // Determine active qubits for this op.
        @memset(active, false);
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

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(palette.bg);

        // Zone backgrounds — compute zone pulses brighter during Rydberg.
        drawZone(camera, font, storage_rect, palette.zone_storage, "storage");
        const compute_fill = if (op.kind == .rydberg) palette.zone_compute_active else palette.zone_compute;
        drawZone(camera, font, compute_rect, compute_fill, "compute");

        // SLM trap sites.
        for (s.compute_slots) |slot| drawSlot(camera, slot, frame_positions[frame]);

        // Shuttle arrows for all move operations.
        if (op.kind == .move) {
            for (op.kind.move.atoms) |a| {
                const start_screen = camera.worldToScreen(.{ .x = @floatFromInt(a.src.x), .y = @floatFromInt(a.src.y) });
                const end_screen = camera.worldToScreen(.{ .x = @floatFromInt(a.dest.x), .y = @floatFromInt(a.dest.y) });
                drawArrow(start_screen, end_screen, @max(2.0 * camera.zoom, 1.0), palette.arrow);
            }
        }

        const colors = drawOperationInfo(font, op);
        for (frame_positions[frame], 0..) |pos, id| {
            drawQubit(camera, font, pos, id, active[id], colors.fill, colors.stroke);
        }

        drawHeader(font, op, frame, frame_count, playing);
    }
}
