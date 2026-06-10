const std = @import("std");
const rl = @import("raylib");
const schedule = @import("schedule");
const arch_mod = @import("arch");
const circuit = @import("circuit");

const Point = schedule.Point;
const Op = schedule.Op;

// Enumerate every SLM trap site across storage and compute zones. These are drawn
// as background indicators in the visualization.
pub fn allSlmSites(gpa: std.mem.Allocator, layout: arch_mod.ArchConfig) ![]const Point {
    var sites: std.ArrayList(Point) = .empty;

    {
        const slm = layout.storage_zone.slm;
        const x0 = layout.storage_zone.offset_nm[0] + slm.offset_nm[0];
        const y0 = layout.storage_zone.offset_nm[1] + slm.offset_nm[1];
        const x_sep_s: i32 = @intCast(slm.sep_nm[0]);
        const y_sep_s: i32 = @intCast(slm.sep_nm[1]);
        for (0..slm.num_row) |ri| for (0..slm.num_col) |ci| {
            try sites.append(gpa, .{
                .x = x0 + @as(i32, @intCast(ci)) * x_sep_s,
                .y = y0 + @as(i32, @intCast(ri)) * y_sep_s,
            });
        };
    }

    for (layout.compute_zone.slms) |slm| {
        const x0 = layout.compute_zone.offset_nm[0] + slm.offset_nm[0];
        const y0 = layout.compute_zone.offset_nm[1] + slm.offset_nm[1];
        const x_sep_s: i32 = @intCast(slm.sep_nm[0]);
        const y_sep_s: i32 = @intCast(slm.sep_nm[1]);
        for (0..slm.num_row) |ri| for (0..slm.num_col) |ci| {
            try sites.append(gpa, .{
                .x = x0 + @as(i32, @intCast(ci)) * x_sep_s,
                .y = y0 + @as(i32, @intCast(ri)) * y_sep_s,
            });
        };
    }

    return try sites.toOwnedSlice(gpa);
}

const palette = struct {
    pub const bg = rl.Color{ .r = 48, .g = 52, .b = 70, .a = 255 };
    pub const panel_bg = rl.Color{ .r = 36, .g = 39, .b = 58, .a = 235 };
    pub const slot_off = rl.Color{ .r = 115, .g = 121, .b = 148, .a = 255 };
    pub const slot_on_fill = rl.Color{ .r = 166, .g = 209, .b = 137, .a = 255 };
    pub const qdot = rl.Color{ .r = 131, .g = 139, .b = 167, .a = 100 };
    pub const qact_fill = rl.Color{ .r = 129, .g = 200, .b = 190, .a = 255 };
    pub const qact_stroke = rl.Color{ .r = 234, .g = 153, .b = 156, .a = 255 };
    pub const qmeas_fill = rl.Color{ .r = 244, .g = 184, .b = 228, .a = 255 };
    pub const qmeas_stroke = rl.Color{ .r = 202, .g = 158, .b = 230, .a = 255 };
    pub const qryd_fill = rl.Color{ .r = 239, .g = 159, .b = 118, .a = 255 };
    pub const qryd_stroke = rl.Color{ .r = 229, .g = 200, .b = 144, .a = 255 };
    pub const arrow = rl.Color{ .r = 181, .g = 190, .b = 226, .a = 200 };
    pub const text = rl.Color{ .r = 198, .g = 208, .b = 245, .a = 255 };
    pub const text_sub = rl.Color{ .r = 115, .g = 121, .b = 148, .a = 255 };
    pub const divider = rl.Color{ .r = 65, .g = 69, .b = 89, .a = 255 };
    pub const zone_storage = rl.Color{ .r = 56, .g = 62, .b = 82, .a = 80 };
    pub const zone_compute = rl.Color{ .r = 46, .g = 70, .b = 66, .a = 90 };
    pub const zone_compute_active = rl.Color{ .r = 65, .g = 130, .b = 120, .a = 120 };
    pub const zone_border = rl.Color{ .r = 115, .g = 121, .b = 148, .a = 100 };
    pub const qload_fill = rl.Color{ .r = 147, .g = 154, .b = 183, .a = 255 };
    pub const qload_stroke = rl.Color{ .r = 184, .g = 192, .b = 224, .a = 255 };
    pub const qstore_fill = rl.Color{ .r = 231, .g = 130, .b = 132, .a = 255 };
    pub const qstore_stroke = rl.Color{ .r = 243, .g = 139, .b = 168, .a = 255 };
};

const ATOM_R: f32 = 300.0;
const ATOM_R_LOADED: f32 = 450.0;

fn toVec(p: Point) rl.Vector2 {
    return .{ .x = @floatFromInt(p.x), .y = @floatFromInt(p.y) };
}

// -----------------------------------------------------------------------
// Bounding box
// -----------------------------------------------------------------------
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
        return @max(self.dx(), self.dy()) * 0.15;
    }
};

// -----------------------------------------------------------------------
// Camera
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

    fn fitToRect(self: *Camera, bbox: BBox, screen_w: f32, screen_h: f32) void {
        self.zoom = @min(
            screen_w / (bbox.dx() + bbox.pad()),
            screen_h / (bbox.dy() + bbox.pad()),
        );
        self.offset = .{
            .x = bbox.cx() - screen_w / (2 * self.zoom),
            .y = bbox.cy() - screen_h / (2 * self.zoom),
        };
    }
};

fn computeBoundingBox(slots: []const Point) BBox {
    if (slots.len == 0) return .{ .min_x = -10, .min_y = -10, .max_x = 10, .max_y = 10 };
    var min_x = std.math.floatMax(f32);
    var min_y = std.math.floatMax(f32);
    var max_x = std.math.floatMin(f32);
    var max_y = std.math.floatMin(f32);
    for (slots) |s| {
        const v = toVec(s);
        min_x = @min(min_x, v.x);
        min_y = @min(min_y, v.y);
        max_x = @max(max_x, v.x);
        max_y = @max(max_y, v.y);
    }
    return .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
}

// -----------------------------------------------------------------------
// Per-op accent colors
// -----------------------------------------------------------------------
fn opColors(op: Op) struct { fill: rl.Color, stroke: rl.Color } {
    return switch (op.kind) {
        .move => .{
            .fill = palette.qact_fill,
            .stroke = palette.qact_stroke,
        },
        .store => .{
            .fill = palette.qstore_fill,
            .stroke = palette.qstore_stroke,
        },
        .load => .{
            .fill = palette.qload_fill,
            .stroke = palette.qload_stroke,
        },
        .raman => .{
            .fill = palette.qmeas_fill,
            .stroke = palette.qmeas_stroke,
        },
        .rydberg => .{
            .fill = palette.qryd_fill,
            .stroke = palette.qryd_stroke,
        },
        .measure => .{
            .fill = palette.qmeas_fill,
            .stroke = palette.qmeas_stroke,
        },
    };
}

fn opAccent(op: Op) rl.Color {
    return opColors(op).fill;
}

fn drawMoveTail(cam: Camera, src: Point, dest: Point, tail_alpha: f32, fill: rl.Color) void {
    if (tail_alpha <= 0) return;

    const ss = cam.worldToScreen(toVec(src));
    const se = cam.worldToScreen(toVec(dest));
    const dx = se.x - ss.x;
    const dy = se.y - ss.y;

    if (@sqrt(dx * dx + dy * dy) < 1.0) return;

    const n: usize = 24;
    for (0..n) |i| {
        const f0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const f1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(n));
        const t = (f0 + f1) * 0.5;
        const p0 = rl.Vector2{ .x = ss.x + dx * f0, .y = ss.y + dy * f0 };
        const p1 = rl.Vector2{ .x = ss.x + dx * f1, .y = ss.y + dy * f1 };
        // Soft outer glow.
        const a_glow: u8 = @intFromFloat(t * t * tail_alpha * 28.0);
        rl.drawLineEx(p0, p1, 5.0, rl.Color{ .r = fill.r, .g = fill.g, .b = fill.b, .a = a_glow });
        // Thin bright core.
        const a_core: u8 = @intFromFloat(t * t * tail_alpha * 170.0);
        rl.drawLineEx(p0, p1, 1.0, rl.Color{ .r = fill.r, .g = fill.g, .b = fill.b, .a = a_core });
    }
}

fn drawArrivalRipple(cam: Camera, pos: Point, settle_t: f32, fill: rl.Color) void {
    if (settle_t <= 0) return;

    const screen = cam.worldToScreen(toVec(pos));
    const base_r = ATOM_R * cam.zoom;
    const fade: f32 = 1.0 - settle_t;
    const alpha: u8 = @intFromFloat(fade * 255.0);
    const r = base_r * (1.0 + settle_t * 2.0);
    const c = rl.Color{ .r = fill.r, .g = fill.g, .b = fill.b, .a = alpha };

    rl.drawCircleLinesV(screen, r - 1.5, c);
    rl.drawCircleLinesV(screen, r, c);
    rl.drawCircleLinesV(screen, r + 1.5, c);
}

fn drawStoreFlash(cam: Camera, pos: Point, fill: rl.Color) void {
    const screen = cam.worldToScreen(toVec(pos));
    const r = ATOM_R * cam.zoom;
    rl.drawCircleV(screen, r * 2.2, rl.Color{ .r = fill.r, .g = fill.g, .b = fill.b, .a = 25 });
    rl.drawCircleLinesV(screen, r * 1.8, rl.Color{ .r = fill.r, .g = fill.g, .b = fill.b, .a = 200 });
    rl.drawCircleLinesV(screen, r * 2.2, rl.Color{ .r = fill.r, .g = fill.g, .b = fill.b, .a = 100 });
    rl.drawCircleLinesV(screen, r * 2.8, rl.Color{ .r = fill.r, .g = fill.g, .b = fill.b, .a = 35 });
}

fn drawPairHalo(cam: Camera, a: Point, b: Point, color: rl.Color) void {
    const sa = cam.worldToScreen(toVec(a));
    const sb = cam.worldToScreen(toVec(b));
    const base_r = ATOM_R * cam.zoom;
    const cx = (sa.x + sb.x) / 2.0;
    const cy = (sa.y + sb.y) / 2.0;
    const dx = sb.x - sa.x;
    const dy = sb.y - sa.y;
    const r = @sqrt(dx * dx + dy * dy) / 2.0 + base_r * 1.8;
    const center = rl.Vector2{ .x = cx, .y = cy };

    rl.drawCircleV(center, r, rl.Color{ .r = color.r, .g = color.g, .b = color.b, .a = 12 });
    rl.drawCircleLinesV(center, r, rl.Color{ .r = color.r, .g = color.g, .b = color.b, .a = 90 });
    rl.drawCircleLinesV(center, r + 2.0, rl.Color{ .r = color.r, .g = color.g, .b = color.b, .a = 40 });
    rl.drawCircleLinesV(center, r + 4.0, rl.Color{ .r = color.r, .g = color.g, .b = color.b, .a = 15 });
}

fn drawGatePulse(cam: Camera, pos: Point, time: f32, color: rl.Color) void {
    const screen = cam.worldToScreen(toVec(pos));
    const base_r = ATOM_R * cam.zoom;
    const pulse = @sin(time * std.math.pi * 5.0);
    const r = base_r * (1.7 + 0.35 * pulse);
    const a1: u8 = @intFromFloat(80.0 + 100.0 * (0.5 + 0.5 * pulse));

    rl.drawCircleLinesV(screen, r, rl.Color{ .r = color.r, .g = color.g, .b = color.b, .a = a1 });
    rl.drawCircleLinesV(screen, r + 2.0, rl.Color{ .r = color.r, .g = color.g, .b = color.b, .a = a1 / 3 });
}

fn drawGhostQubit(cam: Camera, pos: Point, fill: rl.Color) void {
    const screen = cam.worldToScreen(toVec(pos));
    const screen_radius = ATOM_R * cam.zoom;

    rl.drawCircleV(screen, screen_radius, rl.Color{ .r = fill.r, .g = fill.g, .b = fill.b, .a = 35 });
    rl.drawCircleLinesV(screen, screen_radius, rl.Color{ .r = fill.r, .g = fill.g, .b = fill.b, .a = 90 });
}

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

fn drawZone(cam: Camera, r: ZoneRect, fill: rl.Color) void {
    const tl = cam.worldToScreen(.{ .x = @floatFromInt(r.x0), .y = @floatFromInt(r.y0) });
    const br = cam.worldToScreen(.{ .x = @floatFromInt(r.x1), .y = @floatFromInt(r.y1) });
    const rec = rl.Rectangle{ .x = tl.x, .y = tl.y, .width = br.x - tl.x, .height = br.y - tl.y };

    rl.drawRectangleRounded(rec, 0.06, 8, fill);
    rl.drawRectangleRoundedLinesEx(rec, 0.06, 8, 1.0, palette.zone_border);
}

fn drawAodHighlight(cam: Camera, positions: []const Point, loaded: []const bool, ops: []const Op, op_t: u32, sw: f32, sh: f32) void {
    const fill = rl.Color{ .r = palette.qact_fill.r, .g = palette.qact_fill.g, .b = palette.qact_fill.b, .a = 15 };
    const edge = rl.Color{ .r = palette.qact_fill.r, .g = palette.qact_fill.g, .b = palette.qact_fill.b, .a = 55 };
    const hw = ATOM_R * cam.zoom;

    for (positions, 0..) |pos, id| {
        if (id >= loaded.len or !loaded[id]) continue;
        const s = cam.worldToScreen(toVec(pos));

        // Horizontal row — visible while the atom is in the AOD (disappears on store).
        rl.drawRectangleV(.{ .x = 0, .y = s.y - hw }, .{ .x = sw, .y = 2.0 * hw }, fill);
        rl.drawLineEx(.{ .x = 0, .y = s.y }, .{ .x = sw, .y = s.y }, 1.0, edge);

        // Vertical column — only at the timestep this atom is loaded (picked up).
        var being_loaded = false;
        for (ops) |op| {
            if (op.t == op_t and op.kind == .load and op.kind.load.qubit == @as(u32, @intCast(id))) {
                being_loaded = true;
                break;
            }
        }
        if (being_loaded) {
            rl.drawRectangleV(.{ .x = s.x - hw, .y = 0 }, .{ .x = 2.0 * hw, .y = sh }, fill);
            rl.drawLineEx(.{ .x = s.x, .y = 0 }, .{ .x = s.x, .y = sh }, 1.0, edge);
        }
    }
}

fn drawSlot(cam: Camera, slot: Point, positions: []const Point, loaded: []const bool) void {
    const screen = cam.worldToScreen(toVec(slot));
    const screen_radius = ATOM_R * cam.zoom;

    var occupied = false;
    for (positions, 0..) |p, id| {
        if (id < loaded.len and loaded[id]) continue; // atom is in AOD, not in this SLM trap
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

fn drawQubit(cam: Camera, font: rl.Font, pos: Point, id: usize, active: bool, loaded: bool, fill: rl.Color, stroke: rl.Color) void {
    const screen = cam.worldToScreen(toVec(pos));
    const screen_radius = (if (loaded) ATOM_R_LOADED else ATOM_R) * cam.zoom;

    rl.drawCircleV(screen, screen_radius, palette.qdot);

    if (active) {
        rl.drawCircleV(screen, screen_radius, fill);
        rl.drawCircleLinesV(screen, screen_radius * 1.5, stroke);
        var buf: [8]u8 = undefined;
        const label = std.fmt.bufPrintSentinel(&buf, "{d}", .{id}, 0) catch "?";
        const lx = screen.x + screen_radius + 10;
        const ly = screen.y - 12;
        rl.drawTextEx(font, label, .{ .x = lx + 1, .y = ly }, 24, 0.5, palette.text);
        rl.drawTextEx(font, label, .{ .x = lx, .y = ly }, 24, 0.5, palette.text);
    }
}

// -----------------------------------------------------------------------
// HUD panel (screen-space)
// -----------------------------------------------------------------------

// Panel dimensions
const PANEL_W: f32 = 540;
const PAD: f32 = 18;

// Font sizes
const FS_SECTION: f32 = 22;
const FS_BADGE: f32 = 43;
const FS_CHIP: f32 = 26;
const FS_KV: f32 = 34;
const FS_PROGRESS: f32 = 29;
const FS_QUBIT: f32 = 24;
const FS_CTRL: f32 = 31;

// Row / box heights
const BADGE_H: f32 = 72;
const CHIP_H: f32 = 48;
const CHIP_GAP: f32 = 8;
const BAR_H: f32 = 10;
const KV_ROW_H: f32 = 48;
const QUBIT_SQ: f32 = 42;
const QUBIT_GAP: f32 = 8;
const CTRL_ROW_H: f32 = 46;

// KV layout
const KV_SP: f32 = 0.8;
const KV_VX: f32 = PAD + 230;

// Section header advances
const SEP_ADV: f32 = 27;
const LABEL_ADV: f32 = 48;

// Max qubits shown in ATOMS section before truncation
const ATOM_MAX: usize = 5;

fn sep(y: f32) void {
    rl.drawLineEx(.{ .x = PAD, .y = y }, .{ .x = PANEL_W - PAD, .y = y }, 1.0, palette.divider);
}

fn sectionLabel(font: rl.Font, label: [:0]const u8, y: f32) void {
    rl.drawTextEx(font, label, .{ .x = PAD, .y = y }, FS_SECTION, 2.0, palette.text_sub);
}

const Summary = struct {
    move: u32,
    raman: u32,
    rydberg: u32,
    measure: u32,
};

fn drawPanel(
    font: rl.Font,
    op: Op,
    frame: usize,
    total: usize,
    active: []const bool,
    num_qubits: usize,
    positions: []const Point,
    loaded: []const bool,
    summary: Summary,
    scroll: f32,
) f32 {
    const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
    const cw: f32 = PANEL_W - 2 * PAD;
    const accent = opAccent(op);

    const ctrl = [_][2][:0]const u8{
        .{ "j / k", "step" },
        .{ "space", "play / pause" },
        .{ "r", "reset" },
        .{ "scroll", "zoom / scroll" },
        .{ "drag", "pan" },
        .{ "h", "hide" },
    };

    const ctrl_block_h: f32 = SEP_ADV + LABEL_ADV + @as(f32, @floatFromInt(ctrl.len)) * CTRL_ROW_H;
    const avail_h: f32 = screen_h - ctrl_block_h;

    rl.drawRectangle(0, 0, @intFromFloat(PANEL_W), @intFromFloat(screen_h), palette.panel_bg);
    rl.drawLineEx(.{ .x = PANEL_W, .y = 0 }, .{ .x = PANEL_W, .y = screen_h }, 1.0, palette.divider);

    var y: f32 = PAD;

    // ── Schedule summary (2×2 chip grid) ─────────────────────────
    sep(y);
    y += SEP_ADV;
    sectionLabel(font, "SCHEDULE", y);
    y += LABEL_ADV;
    {
        const ChipData = struct { label: [:0]const u8, count: u32, color: rl.Color };
        const chips = [4]ChipData{
            .{ .label = "move", .count = summary.move, .color = palette.qact_fill },
            .{ .label = "raman", .count = summary.raman, .color = palette.qmeas_fill },
            .{ .label = "rydberg", .count = summary.rydberg, .color = palette.qryd_fill },
            .{ .label = "measure", .count = summary.measure, .color = palette.qmeas_stroke },
        };
        const chip_w: f32 = (cw - CHIP_GAP) / 2;
        for (chips, 0..) |chip, i| {
            const col: f32 = @floatFromInt(i % 2);
            const row: f32 = @floatFromInt(i / 2);
            const cx = PAD + col * (chip_w + CHIP_GAP);
            const chip_y = y + row * (CHIP_H + CHIP_GAP);
            const rec = rl.Rectangle{ .x = cx, .y = chip_y, .width = chip_w, .height = CHIP_H };
            const has = chip.count > 0;
            rl.drawRectangleRounded(rec, 0.3, 4, rl.Color{
                .r = chip.color.r,
                .g = chip.color.g,
                .b = chip.color.b,
                .a = if (has) @as(u8, 35) else 12,
            });
            rl.drawRectangleRoundedLinesEx(rec, 0.3, 4, 1.0, rl.Color{
                .r = chip.color.r,
                .g = chip.color.g,
                .b = chip.color.b,
                .a = if (has) @as(u8, 210) else 50,
            });
            var buf: [16]u8 = undefined;
            const txt = std.fmt.bufPrintSentinel(&buf, "{s} x{d}", .{ chip.label, chip.count }, 0) catch "?";
            const tw = rl.measureTextEx(font, txt, FS_CHIP, 0.8).x;
            rl.drawTextEx(font, txt, .{ .x = cx + (chip_w - tw) / 2, .y = chip_y + (CHIP_H - FS_CHIP) / 2 }, FS_CHIP, 0.8, rl.Color{
                .r = chip.color.r,
                .g = chip.color.g,
                .b = chip.color.b,
                .a = if (has) @as(u8, 255) else 90,
            });
        }
        y += 2 * CHIP_H + CHIP_GAP + PAD;
    }

    // ── Op badge ──────────────────────────────────────────────────
    {
        const rec = rl.Rectangle{ .x = PAD, .y = y, .width = cw, .height = BADGE_H };
        rl.drawRectangleRounded(rec, 0.3, 8, rl.Color{
            .r = accent.r,
            .g = accent.g,
            .b = accent.b,
            .a = 28,
        });
        rl.drawRectangleRoundedLinesEx(rec, 0.3, 8, 1.5, accent);
        const name: [:0]const u8 = @tagName(op.kind);
        const tw = rl.measureTextEx(font, name, FS_BADGE, 1.0).x;
        rl.drawTextEx(
            font,
            name,
            .{ .x = PAD + (cw - tw) / 2, .y = y + (BADGE_H - FS_BADGE) / 2 + 1 },
            FS_BADGE,
            1.0,
            accent,
        );
        y += BADGE_H + PAD;
    }

    // ── Zone indicator ────────────────────────────────────────────
    {
        const zone_str: [:0]const u8 = switch (op.kind) {
            .move => "-",
            .rydberg => |r| @tagName(r.zone),
            .measure => |m| @tagName(m.zone),
            .raman => "-",
            .load, .store => "storage",
        };
        rl.drawTextEx(font, "zone", .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
        rl.drawTextEx(font, zone_str, .{ .x = KV_VX, .y = y }, FS_KV, KV_SP, accent);
        y += KV_ROW_H;
    }

    // ── Progress bar ──────────────────────────────────────────────
    {
        const frac = @as(f32, @floatFromInt(frame + 1)) / @as(f32, @floatFromInt(total));
        rl.drawRectangleRounded(.{ .x = PAD, .y = y, .width = cw, .height = BAR_H }, 1.0, 4, rl.Color{
            .r = 65,
            .g = 69,
            .b = 89,
            .a = 180,
        });
        rl.drawRectangleRounded(
            .{ .x = PAD, .y = y, .width = cw * frac, .height = BAR_H },
            1.0,
            4,
            accent,
        );
        y += BAR_H + 21;
        var buf: [16]u8 = undefined;
        const prog = std.fmt.bufPrintSentinel(&buf, "{d} / {d}", .{ frame + 1, total }, 0) catch "?";
        rl.drawTextEx(
            font,
            prog,
            .{ .x = PAD, .y = y },
            FS_PROGRESS,
            0.5,
            palette.text_sub,
        );
        y += FS_PROGRESS + PAD;
    }

    // ── Atom positions ────────────────────────────────────────────
    // Each atom: one line "q{id}  (x, y) µm" — integer µm keeps width bounded.
    sep(y);
    y += SEP_ADV;
    sectionLabel(font, "ATOMS", y);
    y += LABEL_ADV;
    {
        var shown: usize = 0;
        var any_active = false;
        for (0..num_qubits) |q| {
            if (q >= active.len or !active[q]) continue;
            any_active = true;
            if (shown >= ATOM_MAX) {
                rl.drawTextEx(
                    font,
                    "...",
                    .{ .x = PAD, .y = y },
                    FS_KV,
                    KV_SP,
                    palette.text_sub,
                );
                y += KV_ROW_H;
                break;
            }
            var buf: [48]u8 = undefined;
            const line = if (q < positions.len) blk: {
                const pos = positions[q];
                break :blk std.fmt.bufPrintSentinel(
                    &buf,
                    "q{d}  ({d}, {d}) um",
                    .{ q, @divTrunc(pos.x, 1000), @divTrunc(pos.y, 1000) },
                    0,
                ) catch "?";
            } else blk: {
                break :blk std.fmt.bufPrintSentinel(&buf, "q{d}", .{q}, 0) catch "?";
            };
            rl.drawTextEx(
                font,
                line,
                .{ .x = PAD, .y = y },
                FS_KV,
                KV_SP,
                accent,
            );
            y += KV_ROW_H;
            shown += 1;
        }
        if (!any_active) {
            rl.drawTextEx(
                font,
                "-",
                .{ .x = PAD, .y = y },
                FS_KV,
                KV_SP,
                palette.text_sub,
            );
            y += KV_ROW_H;
        }
    }
    y += PAD;

    // ── Loaded atoms (AOD register) ───────────────────────────────
    sep(y);
    y += SEP_ADV;
    sectionLabel(font, "LOADED", y);
    y += LABEL_ADV;
    {
        var any_loaded = false;
        var shown: usize = 0;
        for (loaded, 0..) |l, q| {
            if (!l) continue;
            any_loaded = true;
            if (shown >= ATOM_MAX) {
                rl.drawTextEx(font, "...", .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
                y += KV_ROW_H;
                break;
            }
            var buf: [48]u8 = undefined;
            const line = if (q < positions.len) blk: {
                const pos = positions[q];
                break :blk std.fmt.bufPrintSentinel(
                    &buf,
                    "q{d}  ({d}, {d}) um",
                    .{ q, @divTrunc(pos.x, 1000), @divTrunc(pos.y, 1000) },
                    0,
                ) catch "?";
            } else blk: {
                break :blk std.fmt.bufPrintSentinel(&buf, "q{d}", .{q}, 0) catch "?";
            };
            rl.drawTextEx(font, line, .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.qact_fill);
            y += KV_ROW_H;
            shown += 1;
        }
        if (!any_loaded) {
            rl.drawTextEx(font, "-", .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
            y += KV_ROW_H;
        }
    }
    y += PAD;

    // ── Qubit roster (scrollable) ─────────────────────────────────
    sep(y);
    y += SEP_ADV;
    sectionLabel(font, "QUBITS", y);
    y += LABEL_ADV;
    var max_qubit_scroll: f32 = 0;
    {
        const per_row: usize = @intFromFloat(cw / (QUBIT_SQ + QUBIT_GAP));
        var num_active: usize = 0;
        for (0..num_qubits) |q| if (q < active.len and active[q]) {
            num_active += 1;
        };
        const num_rows: usize = if (num_active == 0) 0 else (num_active - 1) / per_row + 1;
        const qubit_content_h: f32 = @as(f32, @floatFromInt(num_rows)) * (QUBIT_SQ + QUBIT_GAP);
        const qubit_box_h: f32 = avail_h - y;

        if (qubit_box_h > 0) {
            rl.beginScissorMode(0, @intFromFloat(y), @intFromFloat(PANEL_W), @intFromFloat(qubit_box_h));
            var slot: usize = 0;
            for (0..num_qubits) |q| {
                if (q >= active.len or !active[q]) continue;
                const col = slot % per_row;
                const row_n = slot / per_row;
                const qx = PAD + @as(f32, @floatFromInt(col)) * (QUBIT_SQ + QUBIT_GAP);
                const qy = y + @as(f32, @floatFromInt(row_n)) * (QUBIT_SQ + QUBIT_GAP) - scroll;
                const rec = rl.Rectangle{ .x = qx, .y = qy, .width = QUBIT_SQ, .height = QUBIT_SQ };
                rl.drawRectangleRounded(rec, 0.3, 4, rl.Color{
                    .r = accent.r,
                    .g = accent.g,
                    .b = accent.b,
                    .a = 160,
                });
                rl.drawRectangleRoundedLinesEx(rec, 0.3, 4, 1.0, accent);
                var qb: [4]u8 = undefined;
                const ql = std.fmt.bufPrintSentinel(&qb, "{d}", .{q}, 0) catch "?";
                const qtw = rl.measureTextEx(font, ql, FS_QUBIT, 0.5).x;
                rl.drawTextEx(
                    font,
                    ql,
                    .{ .x = qx + (QUBIT_SQ - qtw) / 2, .y = qy + (QUBIT_SQ - FS_QUBIT) / 2 },
                    FS_QUBIT,
                    0.5,
                    palette.bg,
                );
                slot += 1;
            }
            rl.endScissorMode();

            if (qubit_content_h > qubit_box_h) {
                const sb_w: f32 = 5;
                const sb_x: f32 = PANEL_W - sb_w - 3;
                const thumb_h: f32 = @max(24, qubit_box_h * qubit_box_h / qubit_content_h);
                const thumb_y: f32 = y + (scroll / (qubit_content_h - qubit_box_h)) * (qubit_box_h - thumb_h);
                rl.drawRectangleRounded(.{ .x = sb_x, .y = y, .width = sb_w, .height = qubit_box_h }, 1.0, 4, rl.Color{
                    .r = 65,
                    .g = 69,
                    .b = 89,
                    .a = 100,
                });
                rl.drawRectangleRounded(.{ .x = sb_x, .y = thumb_y, .width = sb_w, .height = thumb_h }, 1.0, 4, rl.Color{
                    .r = 115,
                    .g = 121,
                    .b = 148,
                    .a = 210,
                });
            }

            max_qubit_scroll = @max(0, qubit_content_h - qubit_box_h);
        }
    }

    // ── Controls (fixed at bottom, never scrolls) ─────────────────
    sep(avail_h);
    var cy: f32 = avail_h + SEP_ADV;
    sectionLabel(font, "CONTROLS", cy);
    cy += LABEL_ADV;
    for (ctrl) |row| {
        rl.drawTextEx(font, row[0], .{ .x = PAD, .y = cy }, FS_CTRL, 0.8, palette.text_sub);
        rl.drawTextEx(font, row[1], .{ .x = KV_VX, .y = cy }, FS_CTRL, 0.8, palette.text);
        cy += CTRL_ROW_H;
    }

    return max_qubit_scroll;
}

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------
// -----------------------------------------------------------------------
// Main interactive slideshow
// -----------------------------------------------------------------------
pub fn physical(gpa: std.mem.Allocator, layout: arch_mod.ArchConfig, s: schedule.Hardware) !void {
    if (s.placement.len == 0 or s.ops.items.len == 0) return;

    var max_t: u32 = 0;
    for (s.ops.items) |op| max_t = @max(max_t, op.t);
    const frame_count = @as(usize, max_t) + 1;

    var frame_positions = try gpa.alloc([]Point, frame_count);
    defer {
        for (frame_positions) |fp| gpa.free(fp);
        gpa.free(frame_positions);
    }
    {
        const cur = try gpa.alloc(Point, s.initial.len);
        for (s.initial, 0..) |pos, i| cur[i] = pos;
        defer gpa.free(cur);
        for (0..frame_count) |t| {
            for (s.ops.items) |op| {
                if (op.t == @as(u32, @intCast(t)) and op.kind == .move) {
                    cur[op.kind.move.qubit] = op.kind.move.dest;
                }
            }
            frame_positions[t] = try gpa.dupe(Point, cur);
        }
    }

    var frame_loaded = try gpa.alloc([]bool, frame_count);
    defer {
        for (frame_loaded) |fl| gpa.free(fl);
        gpa.free(frame_loaded);
    }
    {
        const cur = try gpa.alloc(bool, s.placement.len);
        defer gpa.free(cur);
        @memset(cur, false);
        for (0..frame_count) |t| {
            for (s.ops.items) |op| {
                if (op.t != @as(u32, @intCast(t))) continue;
                switch (op.kind) {
                    .load => |ld| cur[ld.qubit] = true,
                    .store => |st| cur[st.qubit] = false,
                    else => {},
                }
            }
            frame_loaded[t] = try gpa.dupe(bool, cur);
        }
    }

    // Count logical qubits and op types across the full schedule.
    var num_qubits: usize = 0;
    var summary = Summary{ .move = 0, .raman = 0, .rydberg = 0, .measure = 0 };
    for (s.ops.items) |op| {
        switch (op.kind) {
            .move => |m| {
                summary.move += 1;
                num_qubits = @max(num_qubits, m.qubit + 1);
            },
            .raman => |r| {
                summary.raman += 1;
                for (r.targets) |t| {
                    num_qubits = @max(num_qubits, t.qubit + 1);
                }
            },
            .rydberg => {
                summary.rydberg += 1;
            },
            .measure => |m| {
                summary.measure += 1;
                for (m.qubits) |q| {
                    num_qubits = @max(num_qubits, q + 1);
                }
            },
            .load => |ld| num_qubits = @max(num_qubits, ld.qubit + 1),
            .store => |st| num_qubits = @max(num_qubits, st.qubit + 1),
        }
    }

    // Zone rects in world-space (nm).
    const sz = layout.storage_zone;
    const storage_rect = slmZoneRect(sz.offset_nm[0], sz.offset_nm[1], sz.slm);

    const ez = layout.compute_zone;
    var compute_rect = slmZoneRect(ez.offset_nm[0], ez.offset_nm[1], ez.slms[0]);
    for (ez.slms[1..]) |slm| {
        const r = slmZoneRect(ez.offset_nm[0], ez.offset_nm[1], slm);
        compute_rect.x0 = @min(compute_rect.x0, r.x0);
        compute_rect.y0 = @min(compute_rect.y0, r.y0);
        compute_rect.x1 = @max(compute_rect.x1, r.x1);
        compute_rect.y1 = @max(compute_rect.y1, r.y1);
    }

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

    const font = rl.loadFontEx(
        "./asset/JetBrainsMonoNerdFont-Regular.ttf",
        64,
        null,
    ) catch try rl.getFontDefault();
    defer rl.unloadFont(font);
    rl.setTextureFilter(font.texture, .bilinear);

    const screen_w = rl.getScreenWidth();
    const screen_h = rl.getScreenHeight();

    const sites = try allSlmSites(s.gpa, layout);
    defer s.gpa.free(sites);

    const bbox = computeBoundingBox(sites);
    var camera = Camera{};
    camera.fitToRect(bbox, @floatFromInt(screen_w), @floatFromInt(screen_h));

    var panning = false;
    var last_mouse_pos: rl.Vector2 = undefined;

    var frame: usize = 0;
    var playing = false;
    var timer: f32 = 0.0;
    const step_sec: f32 = 0.4;
    var panel_visible = false;
    var panel_scroll: f32 = 0;
    var panel_content_h: f32 = 0;

    const hold_delay: f32 = 0.3; // seconds before repeat starts
    const hold_rate: f32 = 0.06; // seconds between repeat steps
    var hold_k: f32 = 0.0;
    var hold_j: f32 = 0.0;

    var active = try gpa.alloc(bool, s.placement.len);
    defer gpa.free(active);

    var draw_positions = try gpa.alloc(Point, s.placement.len);
    defer gpa.free(draw_positions);

    while (!rl.windowShouldClose()) {
        const dt = rl.getFrameTime();
        // ── Input ──────────────────────────────────────────────────
        if (rl.isKeyPressed(.k)) {
            playing = false;
            frame = @min(frame + 1, frame_count - 1);
            hold_k = 0.0;
        } else if (rl.isKeyDown(.k)) {
            hold_k += dt;
            if (hold_k >= hold_delay) {
                const excess = hold_k - hold_delay;
                const steps: usize = @intFromFloat(excess / hold_rate);
                if (steps > 0) {
                    playing = false;
                    frame = @min(frame + steps, frame_count - 1);
                    hold_k -= @as(f32, @floatFromInt(steps)) * hold_rate;
                }
            }
        } else {
            hold_k = 0.0;
        }
        if (rl.isKeyPressed(.j)) {
            playing = false;
            if (frame > 0) frame -= 1;
            hold_j = 0.0;
        } else if (rl.isKeyDown(.j)) {
            hold_j += dt;
            if (hold_j >= hold_delay) {
                const excess = hold_j - hold_delay;
                const steps: usize = @intFromFloat(excess / hold_rate);
                if (steps > 0) {
                    playing = false;
                    if (frame >= steps) frame -= steps else frame = 0;
                    hold_j -= @as(f32, @floatFromInt(steps)) * hold_rate;
                }
            }
        } else {
            hold_j = 0.0;
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
        if (rl.isKeyPressed(.h)) panel_visible = !panel_visible;

        const mouse_pos = rl.getMousePosition();
        if (rl.isMouseButtonPressed(.right)) {
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
        if (wheel != 0) {
            if (panel_visible and mouse_pos.x < PANEL_W) {
                panel_scroll -= wheel * 50.0;
                panel_scroll = @max(0, @min(panel_scroll, panel_content_h));
            } else {
                camera.zoom += wheel * 0.05 * camera.zoom;
                const mw = camera.screenToWorld(mouse_pos);
                camera.offset.x = mw.x - mouse_pos.x / camera.zoom;
                camera.offset.y = mw.y - mouse_pos.y / camera.zoom;
            }
        }

        if (playing) {
            timer += dt;
            if (timer >= step_sec) {
                timer = 0;
                if (frame + 1 < frame_count) frame += 1 else playing = false;
            }
        }

        const op_t: u32 = @intCast(frame);

        // First op at this timestep — used for badge/colors/panel display.
        var primary_op: Op = s.ops.items[0];
        for (s.ops.items) |op| {
            if (op.t == op_t) {
                primary_op = op;
                break;
            }
        }

        var any_move = false;
        var any_raman = false;
        for (s.ops.items) |op| {
            if (op.t != op_t) continue;
            if (op.kind == .move) any_move = true;
            if (op.kind == .raman) any_raman = true;
        }

        // Throttle to 15 FPS on static frames — saves GPU/CPU when stepping manually.
        rl.setTargetFPS(if (playing or panning or any_raman) 60 else 15);

        // ── Draw ───────────────────────────────────────────────────
        rl.beginDrawing();
        defer rl.endDrawing();

        // Active qubits = union across all ops at this timestep.
        @memset(active, false);
        for (s.ops.items) |op| {
            if (op.t != op_t) continue;
            switch (op.kind) {
                .move => |m| active[m.qubit] = true,
                .raman => |r| for (r.targets) |tgt| {
                    active[tgt.qubit] = true;
                },
                .measure => |m| for (m.qubits) |q| {
                    active[q] = true;
                },
                .load => |ld| active[ld.qubit] = true,
                .store => |st| active[st.qubit] = true,
                .rydberg => {},
            }
        }

        rl.clearBackground(palette.bg);

        drawZone(camera, storage_rect, palette.zone_storage);
        drawZone(camera, compute_rect, palette.zone_compute);

        @memcpy(draw_positions, frame_positions[frame]);

        const travel_frac: f32 = 0.55;
        const move_t: f32 = blk: {
            if (!any_move or !playing) break :blk 1.0;
            const frac = @min(timer / (step_sec * travel_frac), 1.0);
            break :blk frac * frac * (3.0 - 2.0 * frac); // smoothstep
        };
        const settle_t: f32 = blk: {
            if (!any_move or !playing) break :blk 0.0;
            const travel_end = step_sec * travel_frac;
            if (timer <= travel_end) break :blk 0.0;
            break :blk @min((timer - travel_end) / (step_sec - travel_end), 1.0);
        };

        // Animate all moves at this timestep simultaneously.
        for (s.ops.items) |op| {
            if (op.t != op_t or op.kind != .move) continue;
            const a = op.kind.move;
            const sv = toVec(a.src);
            const ev = toVec(a.dest);
            draw_positions[a.qubit] = .{
                .x = @intFromFloat(sv.x + (ev.x - sv.x) * move_t),
                .y = @intFromFloat(sv.y + (ev.y - sv.y) * move_t),
            };
        }

        const sw: f32 = @floatFromInt(rl.getScreenWidth());
        const sh: f32 = @floatFromInt(rl.getScreenHeight());
        drawAodHighlight(camera, draw_positions, frame_loaded[frame], s.ops.items, op_t, sw, sh);

        for (sites) |slot| drawSlot(camera, slot, draw_positions, frame_loaded[frame]);

        // Ghost, tail, and ripple for every move at this timestep.
        for (s.ops.items) |op| {
            if (op.t != op_t or op.kind != .move) continue;
            const a = op.kind.move;
            const src_is_site = for (sites) |site| {
                if (site.x == a.src.x and site.y == a.src.y) break true;
            } else false;
            if (src_is_site) drawGhostQubit(camera, a.src, opColors(primary_op).fill);
            drawMoveTail(camera, a.src, draw_positions[a.qubit], 1.0, opColors(primary_op).fill);
            drawArrivalRipple(camera, a.dest, settle_t, opColors(primary_op).fill);
        }

        if (primary_op.kind == .rydberg) {
            const fill = opColors(primary_op).fill;
            const db: i64 = layout.constraints.db_nm;
            const db2 = db * db;
            for (draw_positions[0..num_qubits], 0..) |pa, ia| {
                if (!active[ia]) continue;
                for (draw_positions[0..num_qubits], 0..) |pb, ib| {
                    if (ib <= ia or !active[ib]) continue;
                    const dx: i64 = @as(i64, pa.x) - @as(i64, pb.x);
                    const dy: i64 = @as(i64, pa.y) - @as(i64, pb.y);
                    if (dx * dx + dy * dy <= db2) drawPairHalo(camera, pa, pb, fill);
                }
            }
        }

        const now: f32 = @floatCast(rl.getTime());
        const colors = opColors(primary_op);
        for (draw_positions, 0..) |pos, id| {
            const is_loaded = id < frame_loaded[frame].len and frame_loaded[frame][id];
            // Atoms being stored this frame render red, not with the generic op color.
            var fill = colors.fill;
            var stroke = colors.stroke;
            for (s.ops.items) |op| {
                if (op.t == op_t and op.kind == .store and op.kind.store.qubit == @as(u32, @intCast(id))) {
                    fill = palette.qstore_fill;
                    stroke = palette.qstore_stroke;
                    break;
                }
            }
            drawQubit(camera, font, pos, id, active[id], is_loaded, fill, stroke);
        }

        // Red glow overlay for every atom deposited into SLM at this timestep.
        for (s.ops.items) |op| {
            if (op.t == op_t and op.kind == .store) {
                drawStoreFlash(camera, op.kind.store.position, palette.qstore_fill);
            }
        }

        if (any_raman) {
            for (draw_positions, 0..) |pos, id| {
                if (id < active.len and active[id])
                    drawGatePulse(camera, pos, now, colors.stroke);
            }
        }

        if (panel_visible) {
            panel_content_h = drawPanel(
                font,
                primary_op,
                frame,
                frame_count,
                active,
                num_qubits,
                frame_positions[frame],
                frame_loaded[frame],
                summary,
                panel_scroll,
            );
        } else {
            rl.drawTextEx(font, "h  show panel", .{ .x = 16, .y = 16 }, 13, 0.8, palette.text_sub);
        }
    }
}

// -----------------------------------------------------------------------
// Stage graph: qubits as nodes, CZ gates as edges — one stage at a time.
// This mirrors the route.Graph built inside Stage.compile.
// Navigate with j / k.
// -----------------------------------------------------------------------
pub fn stageGraph(c: circuit.Circuit, p: circuit.Pipeline) !void {
    if (p.stages.items.len == 0) return;

    const n_stages = p.stages.items.len;
    const nq = c.n;

    rl.setConfigFlags(.{ .window_resizable = true, .msaa_4x_hint = true });
    rl.setTraceLogLevel(.err);
    rl.initWindow(900, 760, "stage graph");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    const font = rl.loadFontEx(
        "./asset/JetBrainsMonoNerdFont-Regular.ttf",
        64,
        null,
    ) catch try rl.getFontDefault();
    defer rl.unloadFont(font);
    rl.setTextureFilter(font.texture, .bilinear);

    var stage_idx: usize = 0;

    while (!rl.windowShouldClose()) {
        if (rl.isKeyPressed(.k) and stage_idx + 1 < n_stages) stage_idx += 1;
        if (rl.isKeyPressed(.j) and stage_idx > 0) stage_idx -= 1;

        const stage = p.stages.items[stage_idx];
        const sw: f32 = @floatFromInt(rl.getScreenWidth());
        const sh: f32 = @floatFromInt(rl.getScreenHeight());

        // Place qubits evenly on a circle centred on the canvas.
        const HEADER: f32 = 60;
        const FOOTER: f32 = 36;
        const cx: f32 = sw / 2.0;
        const cy: f32 = HEADER + (sh - HEADER - FOOTER) / 2.0;
        const graph_r: f32 = @min(sw / 2.0, (sh - HEADER - FOOTER) / 2.0) * 0.72;
        const NODE_R: f32 = 18.0;

        var pos: [256]rl.Vector2 = undefined;
        const n = @min(nq, 256);
        if (n == 1) {
            pos[0] = .{ .x = cx, .y = cy };
        } else {
            for (0..n) |q| {
                const t = @as(f32, @floatFromInt(q)) / @as(f32, @floatFromInt(n));
                const angle = 2.0 * std.math.pi * t - std.math.pi / 2.0;
                pos[q] = .{ .x = cx + graph_r * @cos(angle), .y = cy + graph_r * @sin(angle) };
            }
        }

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(palette.bg);

        // CZ edges.
        for (stage.cz_gates.items) |cz| {
            if (cz.control >= n or cz.target >= n) continue;
            rl.drawLineEx(pos[cz.control], pos[cz.target], 2.5, palette.qryd_stroke);
        }

        // Qubit nodes.
        for (0..n) |q| {
            var in_cz = false;
            for (stage.cz_gates.items) |cz| {
                if (cz.control == q or cz.target == q) {
                    in_cz = true;
                    break;
                }
            }
            var in_u = false;
            for (stage.u_gates.items) |ug| {
                if (ug.qubit == q) {
                    in_u = true;
                    break;
                }
            }

            const p0 = pos[q];
            if (in_cz) {
                rl.drawCircleV(p0, NODE_R + 5, rl.Color{ .r = palette.qryd_fill.r, .g = palette.qryd_fill.g, .b = palette.qryd_fill.b, .a = 35 });
                rl.drawCircleV(p0, NODE_R, palette.qryd_fill);
                rl.drawCircleLinesV(p0, NODE_R, palette.qryd_stroke);
            } else if (in_u) {
                rl.drawCircleV(p0, NODE_R, palette.qact_fill);
                rl.drawCircleLinesV(p0, NODE_R, palette.qact_stroke);
            } else {
                rl.drawCircleV(p0, NODE_R * 0.65, palette.qdot);
            }

            var buf: [8]u8 = undefined;
            const lbl = std.fmt.bufPrintSentinel(&buf, "{d}", .{q}, 0) catch "?";
            const tw = rl.measureTextEx(font, lbl, 16.0, 0.5).x;
            const tc = if (in_cz or in_u) palette.bg else palette.text_sub;
            rl.drawTextEx(font, lbl, .{ .x = p0.x - tw / 2.0, .y = p0.y - 8.0 }, 16.0, 0.5, tc);
        }

        // Header: stage counter + gate counts.
        {
            var buf: [64]u8 = undefined;
            const hdr = std.fmt.bufPrintSentinel(
                &buf,
                "Stage {d} / {d}     CZ {d}    U {d}",
                .{ stage_idx, n_stages - 1, stage.cz_gates.items.len, stage.u_gates.items.len },
                0,
            ) catch "?";
            const tw = rl.measureTextEx(font, hdr, 20.0, 1.0).x;
            rl.drawTextEx(font, hdr, .{ .x = sw / 2.0 - tw / 2.0, .y = 20.0 }, 20.0, 1.0, palette.text);
        }

        // Footer hint.
        rl.drawTextEx(font, "j  prev stage    k  next stage", .{ .x = 16.0, .y = sh - FOOTER + 8.0 }, 14.0, 0.6, palette.text_sub);
    }
}

fn wireY(q: usize, dy: f32, y_offset: f32) f32 {
    const fq: f32 = @floatFromInt(q);
    return fq * dy + dy + y_offset;
}

fn drawUGate(u: circuit.U, x: f32, dy: f32, y_offset: f32, font_size: i32) void {
    const box: f32 = 40;
    const qy = wireY(u.qubit, dy, y_offset);
    rl.drawRectangleV(
        .{ .x = x - box / 2, .y = qy - box / 2 },
        .{ .x = box, .y = box },
        .dark_purple,
    );
    rl.drawText("U", @intFromFloat(x - 6), @intFromFloat(qy - 10), font_size, .white);
}

fn drawCzGate(cz: circuit.Cz, x: f32, dy: f32, y_offset: f32) void {
    const radius: f32 = 8;
    const cy = wireY(cz.control, dy, y_offset);
    const ty = wireY(cz.target, dy, y_offset);
    rl.drawLineV(.{ .x = x, .y = cy }, .{ .x = x, .y = ty }, .dark_gray);
    rl.drawCircleV(.{ .x = x, .y = cy }, radius, .dark_gray);
    rl.drawCircleLinesV(.{ .x = x, .y = ty }, radius, .dark_gray);
    rl.drawLineV(.{ .x = x - radius, .y = ty }, .{ .x = x + radius, .y = ty }, .dark_gray);
    rl.drawLineV(.{ .x = x, .y = ty - radius }, .{ .x = x, .y = ty + radius }, .dark_gray);
}

/// Draw the circuit. Pass `stages` to group gates into labelled, divided
/// columns; pass `null` to lay every gate out flat in order.
pub fn pipeline(c: circuit.Circuit, p: ?circuit.Pipeline) !void {
    const screenWidth = 800;
    const screenHeight = 450;
    rl.initWindow(screenWidth, screenHeight, "circuit");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    const sw: f32 = @floatFromInt(screenWidth);
    const sh: f32 = @floatFromInt(screenHeight);
    const num_qubits: f32 = @floatFromInt(c.n);
    const font_size: i32 = 20;

    const dy: f32 = sh / (num_qubits + 1);
    const x_offset: f32 = @floatFromInt(3 * font_size);
    const y_offset: f32 = font_size / 2;
    const col_w: f32 = 60;

    const total_cols: usize = c.gates.items.len; // one column per gate
    const content_w: f32 = @as(f32, @floatFromInt(total_cols)) * col_w;
    const max_scroll: f32 = @max(0, content_w - (sw - x_offset));

    var scroll: f32 = 0;

    while (!rl.windowShouldClose()) {
        scroll -= rl.getMouseWheelMove() * 30;
        if (rl.isKeyDown(.k)) scroll += 8;
        if (rl.isKeyDown(.j)) scroll -= 8;
        scroll = std.math.clamp(scroll, 0, max_scroll);

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.ray_white);

        var buf: [32]u8 = undefined;

        // Wires.
        for (0..c.n) |q| {
            const y = wireY(q, dy, y_offset);
            rl.drawLineV(.{ .x = x_offset, .y = y }, .{ .x = sw, .y = y }, .dark_gray);
        }

        // Gates. The column index `col` advances per gate either way; the only
        // difference with stages is the divider + label drawn at each group's start.
        const colX = struct {
            fn at(col: usize, cw: f32, xo: f32, s: f32) f32 {
                return xo + (@as(f32, @floatFromInt(col)) + 0.5) * cw - s;
            }
        }.at;

        var col: usize = 0;
        if (p) |pipe| {
            for (pipe.stages.items, 0..) |stage, s| {
                const stage_x0 = x_offset + @as(f32, @floatFromInt(col)) * col_w - scroll;
                if (s > 0) rl.drawLineV(.{ .x = stage_x0, .y = 0 }, .{ .x = stage_x0, .y = sh }, .light_gray);
                const slabel = try std.fmt.bufPrintZ(&buf, "S{d}", .{s});
                rl.drawText(slabel, @intFromFloat(stage_x0 + 4), 4, font_size, .gray);

                for (stage.cz_gates.items) |gate| {
                    drawCzGate(gate, colX(col, col_w, x_offset, scroll), dy, y_offset);
                    col += 1;
                }

                for (stage.u_gates.items) |gate| {
                    drawUGate(gate, colX(col, col_w, x_offset, scroll), dy, y_offset, font_size);
                    col += 1;
                }
            }
        } else {
            for (c.gates.items) |gate| {
                switch (gate) {
                    .u => |g| drawUGate(g, colX(col, col_w, x_offset, scroll), dy, y_offset, font_size),
                    .cz => |g| drawCzGate(g, colX(col, col_w, x_offset, scroll), dy, y_offset),
                }
                col += 1;
            }
        }

        // Pinned qubit labels (mask the gutter first).
        rl.drawRectangle(0, 0, @intFromFloat(x_offset), screenHeight, .ray_white);
        for (0..c.n) |q| {
            const y: f32 = @as(f32, @floatFromInt(q)) * dy + dy;
            const str = try std.fmt.bufPrintZ(&buf, "q{d}", .{q});
            rl.drawText(str, font_size, @intFromFloat(y), font_size, .dark_gray);
        }

        // Scrollbar (only when overflowing).
        if (max_scroll > 0) {
            const track_y: f32 = sh - 16;
            const track_w: f32 = sw - x_offset;
            const thumb_w: f32 = @max(30, track_w * (track_w / content_w));
            const thumb_x: f32 = x_offset + (scroll / max_scroll) * (track_w - thumb_w);
            rl.drawRectangle(@intFromFloat(x_offset), @intFromFloat(track_y), @intFromFloat(track_w), 12, .light_gray);
            rl.drawRectangle(@intFromFloat(thumb_x), @intFromFloat(track_y), 12, 12, .gray);
            const m = rl.getMousePosition();
            if (rl.isMouseButtonDown(.left) and m.y >= track_y - 4) {
                const frac = std.math.clamp((m.x - x_offset - thumb_w / 2) / (track_w - thumb_w), 0, 1);
                scroll = frac * max_scroll;
            }
        }
    }
}
