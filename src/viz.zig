const std = @import("std");
const rl = @import("raylib");
const schedule = @import("schedule");
const arch_mod = @import("arch");

const Point = schedule.Point;
const Op = schedule.Op;

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
};

// -----------------------------------------------------------------------
// Bounding box
// -----------------------------------------------------------------------
const BBox = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    fn dx(self: BBox) f32 { return self.max_x - self.min_x; }
    fn dy(self: BBox) f32 { return self.max_y - self.min_y; }
    fn cx(self: BBox) f32 { return (self.min_x + self.max_x) / 2; }
    fn cy(self: BBox) f32 { return (self.min_y + self.max_y) / 2; }
    fn pad(self: BBox) f32 { return 2 * @max(self.dx() * 0.1, self.dy() * 0.1); }
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
        const x: f32 = @floatFromInt(s.x);
        const y: f32 = @floatFromInt(s.y);
        min_x = @min(min_x, x);
        min_y = @min(min_y, y);
        max_x = @max(max_x, x);
        max_y = @max(max_y, y);
    }
    return .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
}

// -----------------------------------------------------------------------
// Per-op accent colors
// -----------------------------------------------------------------------
fn opColors(op: Op) struct { fill: rl.Color, stroke: rl.Color } {
    return switch (op.kind) {
        .move    => .{ .fill = palette.qact_fill,  .stroke = palette.qact_stroke  },
        .raman   => .{ .fill = palette.qmeas_fill, .stroke = palette.qmeas_stroke },
        .rydberg => .{ .fill = palette.qryd_fill,  .stroke = palette.qryd_stroke  },
        .measure => .{ .fill = palette.qmeas_fill, .stroke = palette.qmeas_stroke },
    };
}

fn opAccent(op: Op) rl.Color {
    return opColors(op).fill;
}

// -----------------------------------------------------------------------
// World-space primitives
// -----------------------------------------------------------------------
fn drawArrow(start: rl.Vector2, end: rl.Vector2, thickness: f32, color: rl.Color) void {
    rl.drawLineEx(start, end, thickness, color);
    const dx = end.x - start.x;
    const dy = end.y - start.y;
    const head_len: f32 = 15.0;
    const wing_off: f32 = std.math.pi / 7.0;
    const ang = std.math.atan2(dy, dx);
    const a1 = ang + std.math.pi - wing_off;
    const a2 = ang + std.math.pi + wing_off;
    rl.drawLineEx(end, .{ .x = end.x + std.math.cos(a1) * head_len, .y = end.y + std.math.sin(a1) * head_len }, thickness, color);
    rl.drawLineEx(end, .{ .x = end.x + std.math.cos(a2) * head_len, .y = end.y + std.math.sin(a2) * head_len }, thickness, color);
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

fn drawSlot(cam: Camera, slot: Point, positions: []const Point) void {
    const screen = cam.worldToScreen(.{ .x = @floatFromInt(slot.x), .y = @floatFromInt(slot.y) });
    const screen_radius = 600.0 * cam.zoom;
    var occupied = false;
    for (positions) |p| {
        if (p.x == slot.x and p.y == slot.y) { occupied = true; break; }
    }
    if (occupied) {
        rl.drawCircleV(screen, screen_radius, palette.slot_on_fill);
    } else {
        rl.drawCircleLinesV(screen, screen_radius, palette.slot_off);
    }
}

fn drawQubit(cam: Camera, font: rl.Font, pos: Point, id: usize, active: bool, fill: rl.Color, stroke: rl.Color) void {
    const screen = cam.worldToScreen(.{ .x = @floatFromInt(pos.x), .y = @floatFromInt(pos.y) });
    const screen_radius = 600.0 * cam.zoom;
    rl.drawCircleV(screen, screen_radius, palette.qdot);
    if (active) {
        rl.drawCircleV(screen, screen_radius, fill);
        rl.drawCircleLinesV(screen, screen_radius * 1.5, stroke);
        var buf: [8]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "{d}", .{id}) catch "?";
        rl.drawTextEx(font, label, .{ .x = screen.x + screen_radius + 4, .y = screen.y - 11 }, 22, 0.5, palette.text);
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

const Summary = struct { move: u32, raman: u32, rydberg: u32, measure: u32 };

fn drawPanel(
    font: rl.Font,
    op: Op,
    frame: usize,
    total: usize,
    active: []const bool,
    num_qubits: usize,
    positions: []const Point,
    summary: Summary,
) void {
    const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
    const cw: f32 = PANEL_W - 2 * PAD;
    const accent = opAccent(op);

    rl.drawRectangle(0, 0, @intFromFloat(PANEL_W), @intFromFloat(screen_h), palette.panel_bg);
    rl.drawLineEx(.{ .x = PANEL_W, .y = 0 }, .{ .x = PANEL_W, .y = screen_h }, 1.0, palette.divider);

    var y: f32 = PAD;

    // ── Schedule summary (2×2 chip grid) ─────────────────────────
    sep(y); y += SEP_ADV;
    sectionLabel(font, "SCHEDULE", y); y += LABEL_ADV;
    {
        const ChipData = struct { label: [:0]const u8, count: u32, color: rl.Color };
        const chips = [4]ChipData{
            .{ .label = "move",    .count = summary.move,    .color = palette.qact_fill    },
            .{ .label = "raman",   .count = summary.raman,   .color = palette.qmeas_fill   },
            .{ .label = "rydberg", .count = summary.rydberg, .color = palette.qryd_fill    },
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
            rl.drawRectangleRounded(rec, 0.3, 4, rl.Color{ .r = chip.color.r, .g = chip.color.g, .b = chip.color.b, .a = if (has) @as(u8, 35) else 12 });
            rl.drawRectangleRoundedLinesEx(rec, 0.3, 4, 1.0, rl.Color{ .r = chip.color.r, .g = chip.color.g, .b = chip.color.b, .a = if (has) @as(u8, 210) else 50 });
            var buf: [16]u8 = undefined;
            const txt = std.fmt.bufPrintZ(&buf, "{s} ×{d}", .{ chip.label, chip.count }) catch "?";
            const tw = rl.measureTextEx(font, txt, FS_CHIP, 0.8).x;
            rl.drawTextEx(font, txt, .{ .x = cx + (chip_w - tw) / 2, .y = chip_y + (CHIP_H - FS_CHIP) / 2 }, FS_CHIP, 0.8,
                rl.Color{ .r = chip.color.r, .g = chip.color.g, .b = chip.color.b, .a = if (has) @as(u8, 255) else 90 });
        }
        y += 2 * CHIP_H + CHIP_GAP + PAD;
    }

    // ── Op badge ──────────────────────────────────────────────────
    {
        const rec = rl.Rectangle{ .x = PAD, .y = y, .width = cw, .height = BADGE_H };
        rl.drawRectangleRounded(rec, 0.3, 8, rl.Color{ .r = accent.r, .g = accent.g, .b = accent.b, .a = 28 });
        rl.drawRectangleRoundedLinesEx(rec, 0.3, 8, 1.5, accent);
        const name: [:0]const u8 = @tagName(op.kind);
        const tw = rl.measureTextEx(font, name, FS_BADGE, 1.0).x;
        rl.drawTextEx(font, name, .{ .x = PAD + (cw - tw) / 2, .y = y + (BADGE_H - FS_BADGE) / 2 + 1 }, FS_BADGE, 1.0, accent);
        y += BADGE_H + PAD;
    }

    // ── Progress bar ──────────────────────────────────────────────
    {
        const frac = @as(f32, @floatFromInt(frame + 1)) / @as(f32, @floatFromInt(total));
        rl.drawRectangleRounded(.{ .x = PAD, .y = y, .width = cw, .height = BAR_H }, 1.0, 4,
            rl.Color{ .r = 65, .g = 69, .b = 89, .a = 180 });
        rl.drawRectangleRounded(.{ .x = PAD, .y = y, .width = cw * frac, .height = BAR_H }, 1.0, 4, accent);
        y += BAR_H + 21;
        var buf: [16]u8 = undefined;
        const prog = std.fmt.bufPrintZ(&buf, "{d} / {d}", .{ frame + 1, total }) catch "?";
        rl.drawTextEx(font, prog, .{ .x = PAD, .y = y }, FS_PROGRESS, 0.5, palette.text_sub);
        y += FS_PROGRESS + PAD;
    }

    // ── Operation ─────────────────────────────────────────────────
    sep(y); y += SEP_ADV;
    sectionLabel(font, "OPERATION", y); y += LABEL_ADV;

    switch (op.kind) {
        .move => |m| {
            rl.drawTextEx(font, "aod",   .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
            var b0: [8]u8 = undefined;
            rl.drawTextEx(font, std.fmt.bufPrintZ(&b0, "{d}", .{m.aod}) catch "?", .{ .x = KV_VX, .y = y }, FS_KV, KV_SP, palette.text);
            y += KV_ROW_H;
            rl.drawTextEx(font, "axis",  .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
            rl.drawTextEx(font, @tagName(m.translate), .{ .x = KV_VX, .y = y }, FS_KV, KV_SP, palette.text);
            y += KV_ROW_H;
            rl.drawTextEx(font, "from",  .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
            rl.drawTextEx(font, @tagName(m.src_zone),  .{ .x = KV_VX, .y = y }, FS_KV, KV_SP, palette.text);
            y += KV_ROW_H;
            rl.drawTextEx(font, "to",    .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
            rl.drawTextEx(font, @tagName(m.dest_zone), .{ .x = KV_VX, .y = y }, FS_KV, KV_SP, palette.text);
            y += KV_ROW_H;
            rl.drawTextEx(font, "atoms", .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
            var b1: [8]u8 = undefined;
            rl.drawTextEx(font, std.fmt.bufPrintZ(&b1, "{d}", .{m.atoms.len}) catch "?", .{ .x = KV_VX, .y = y }, FS_KV, KV_SP, palette.text);
            y += KV_ROW_H;
        },
        .raman => |r| {
            rl.drawTextEx(font, "angle",   .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
            var b0: [16]u8 = undefined;
            rl.drawTextEx(font, std.fmt.bufPrintZ(&b0, "{d:.4}", .{r.angle}) catch "?", .{ .x = KV_VX, .y = y }, FS_KV, KV_SP, palette.text);
            y += KV_ROW_H;
            rl.drawTextEx(font, "phase",   .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
            var b1: [16]u8 = undefined;
            rl.drawTextEx(font, std.fmt.bufPrintZ(&b1, "{d:.4}", .{r.phase}) catch "?", .{ .x = KV_VX, .y = y }, FS_KV, KV_SP, palette.text);
            y += KV_ROW_H;
            rl.drawTextEx(font, "targets", .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
            var b2: [8]u8 = undefined;
            rl.drawTextEx(font, std.fmt.bufPrintZ(&b2, "{d}", .{r.targets.len}) catch "?", .{ .x = KV_VX, .y = y }, FS_KV, KV_SP, palette.text);
            y += KV_ROW_H;
        },
        .rydberg => |r| {
            rl.drawTextEx(font, "zone", .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
            rl.drawTextEx(font, @tagName(r.zone), .{ .x = KV_VX, .y = y }, FS_KV, KV_SP, palette.text);
            y += KV_ROW_H;
        },
        .measure => |m| {
            rl.drawTextEx(font, "zone",   .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
            rl.drawTextEx(font, @tagName(m.zone), .{ .x = KV_VX, .y = y }, FS_KV, KV_SP, palette.text);
            y += KV_ROW_H;
            rl.drawTextEx(font, "qubits", .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
            var b0: [8]u8 = undefined;
            rl.drawTextEx(font, std.fmt.bufPrintZ(&b0, "{d}", .{m.qubits.len}) catch "?", .{ .x = KV_VX, .y = y }, FS_KV, KV_SP, palette.text);
            y += KV_ROW_H;
        },
    }
    y += PAD;

    // ── Atom positions ────────────────────────────────────────────
    // Each atom: one line "q{id}  (x, y) µm" — integer µm keeps width bounded.
    sep(y); y += SEP_ADV;
    sectionLabel(font, "ATOMS", y); y += LABEL_ADV;
    {
        var shown: usize = 0;
        var any_active = false;
        for (0..num_qubits) |q| {
            if (q >= active.len or !active[q]) continue;
            any_active = true;
            if (shown >= ATOM_MAX) {
                rl.drawTextEx(font, "...", .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
                y += KV_ROW_H;
                break;
            }
            var buf: [48]u8 = undefined;
            const line = if (q < positions.len) blk: {
                const pos = positions[q];
                break :blk std.fmt.bufPrintZ(&buf, "q{d}  ({d}, {d}) µm",
                    .{ q, @divTrunc(pos.x, 1000), @divTrunc(pos.y, 1000) }) catch "?";
            } else blk: {
                break :blk std.fmt.bufPrintZ(&buf, "q{d}", .{q}) catch "?";
            };
            rl.drawTextEx(font, line, .{ .x = PAD, .y = y }, FS_KV, KV_SP, accent);
            y += KV_ROW_H;
            shown += 1;
        }
        if (!any_active) {
            rl.drawTextEx(font, "—", .{ .x = PAD, .y = y }, FS_KV, KV_SP, palette.text_sub);
            y += KV_ROW_H;
        }
    }
    y += PAD;

    // ── Qubit roster ──────────────────────────────────────────────
    sep(y); y += SEP_ADV;
    sectionLabel(font, "QUBITS", y); y += LABEL_ADV;
    {
        const per_row: usize = @intFromFloat(cw / (QUBIT_SQ + QUBIT_GAP));
        for (0..num_qubits) |q| {
            const col = q % per_row;
            const row_n = q / per_row;
            const qx = PAD + @as(f32, @floatFromInt(col)) * (QUBIT_SQ + QUBIT_GAP);
            const qy = y + @as(f32, @floatFromInt(row_n)) * (QUBIT_SQ + QUBIT_GAP);
            const rec = rl.Rectangle{ .x = qx, .y = qy, .width = QUBIT_SQ, .height = QUBIT_SQ };
            const is_active = q < active.len and active[q];
            const qfill = if (is_active) rl.Color{ .r = accent.r, .g = accent.g, .b = accent.b, .a = 160 }
                          else           rl.Color{ .r = 56, .g = 60, .b = 78, .a = 200 };
            rl.drawRectangleRounded(rec, 0.3, 4, qfill);
            rl.drawRectangleRoundedLinesEx(rec, 0.3, 4, 1.0, if (is_active) accent else palette.divider);
            var qb: [4]u8 = undefined;
            const ql = std.fmt.bufPrintZ(&qb, "{d}", .{q}) catch "?";
            const qtw = rl.measureTextEx(font, ql, FS_QUBIT, 0.5).x;
            rl.drawTextEx(font, ql, .{ .x = qx + (QUBIT_SQ - qtw) / 2, .y = qy + (QUBIT_SQ - FS_QUBIT) / 2 }, FS_QUBIT, 0.5,
                if (is_active) palette.bg else palette.text_sub);
        }
        const num_rows: usize = if (num_qubits == 0) 0 else (num_qubits - 1) / per_row + 1;
        y += @as(f32, @floatFromInt(num_rows)) * (QUBIT_SQ + QUBIT_GAP) + PAD;
    }

    // ── Controls (flows naturally below qubits) ───────────────────
    sep(y); y += SEP_ADV;
    sectionLabel(font, "CONTROLS", y); y += LABEL_ADV;
    const ctrl = [_][2][:0]const u8{
        .{ "j / k",  "step"         },
        .{ "space",  "play / pause" },
        .{ "r",      "reset"        },
        .{ "scroll", "zoom"         },
        .{ "drag",   "pan"          },
        .{ "h",      "hide"         },
    };
    for (ctrl) |row| {
        rl.drawTextEx(font, row[0], .{ .x = PAD,   .y = y }, FS_CTRL, 0.8, palette.text_sub);
        rl.drawTextEx(font, row[1], .{ .x = KV_VX, .y = y }, FS_CTRL, 0.8, palette.text);
        y += CTRL_ROW_H;
    }
}

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------
fn initialPositions(allocator: std.mem.Allocator, final: []const Point, ops: []const Op) ![]Point {
    var positions = try allocator.dupe(Point, final);
    var i = ops.len;
    while (i > 0) {
        i -= 1;
        if (ops[i].kind == .move) {
            for (ops[i].kind.move.atoms) |a| positions[a.qubit] = a.src;
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
                for (op.kind.move.atoms) |a| cur[a.qubit] = a.dest;
            }
        }
    }

    // Count logical qubits and op types across the full schedule.
    var num_qubits: usize = 0;
    var summary = Summary{ .move = 0, .raman = 0, .rydberg = 0, .measure = 0 };
    for (s.ops) |op| {
        switch (op.kind) {
            .move    => |m| { summary.move    += 1; for (m.atoms)   |a| { num_qubits = @max(num_qubits, a.qubit + 1); } },
            .raman   => |r| { summary.raman   += 1; for (r.targets) |t| { num_qubits = @max(num_qubits, t.qubit + 1); } },
            .rydberg =>      { summary.rydberg += 1; },
            .measure => |m| { summary.measure += 1; for (m.qubits)  |q| { num_qubits = @max(num_qubits, q + 1); } },
        }
    }

    // Zone rects in world-space (nm).
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

    rl.setConfigFlags(.{ .fullscreen_mode = true, .window_resizable = true, .msaa_4x_hint = true, .window_highdpi = true });
    rl.setTraceLogLevel(.err);
    rl.initWindow(0, 0, "Physical schedule");
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
    var panel_visible = false;

    var active = try allocator.alloc(bool, initial_pos.len);
    defer allocator.free(active);

    while (!rl.windowShouldClose()) {
        // ── Input ──────────────────────────────────────────────────
        if (rl.isKeyPressed(.k)) { playing = false; frame = @min(frame + 1, frame_count - 1); }
        if (rl.isKeyPressed(.j)) { playing = false; if (frame > 0) frame -= 1; }
        if (rl.isKeyPressed(.space)) { playing = !playing; timer = 0; }
        if (rl.isKeyPressed(.r)) {
            camera.fitToRect(bbox, @floatFromInt(screen_w), @floatFromInt(screen_h));
            playing = false; timer = 0; frame = 0;
        }
        if (rl.isKeyPressed(.h)) panel_visible = !panel_visible;

        const mouse_pos = rl.getMousePosition();
        if (rl.isMouseButtonPressed(.right)) { panning = true; last_mouse_pos = mouse_pos; }
        if (rl.isMouseButtonReleased(.right)) panning = false;
        if (panning) {
            camera.offset.x -= (mouse_pos.x - last_mouse_pos.x) / camera.zoom;
            camera.offset.y -= (mouse_pos.y - last_mouse_pos.y) / camera.zoom;
            last_mouse_pos = mouse_pos;
        }

        const wheel = rl.getMouseWheelMove();
        if (wheel != 0) {
            camera.zoom += wheel * 0.05 * camera.zoom;
            const mw = camera.screenToWorld(mouse_pos);
            camera.offset.x = mw.x - mouse_pos.x / camera.zoom;
            camera.offset.y = mw.y - mouse_pos.y / camera.zoom;
        }

        if (playing) {
            timer += rl.getFrameTime();
            if (timer >= step_sec) {
                timer = 0;
                if (frame + 1 < frame_count) frame += 1 else playing = false;
            }
        }

        const op = s.ops[frame];

        // Determine active qubits.
        @memset(active, false);
        switch (op.kind) {
            .move    => |m| for (m.atoms)   |a| { active[a.qubit] = true; },
            .raman   => |r| for (r.targets) |t| { active[t.qubit] = true; },
            .measure => |m| for (m.qubits)  |q| { active[q]       = true; },
            else => {},
        }

        // ── Draw ───────────────────────────────────────────────────
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(palette.bg);

        drawZone(camera, storage_rect, palette.zone_storage);
        drawZone(camera, compute_rect, if (op.kind == .rydberg) palette.zone_compute_active else palette.zone_compute);

        for (s.compute_slots) |slot| drawSlot(camera, slot, frame_positions[frame]);

        if (op.kind == .move) {
            for (op.kind.move.atoms) |a| {
                const ss = camera.worldToScreen(.{ .x = @floatFromInt(a.src.x),  .y = @floatFromInt(a.src.y)  });
                const es = camera.worldToScreen(.{ .x = @floatFromInt(a.dest.x), .y = @floatFromInt(a.dest.y) });
                drawArrow(ss, es, @max(2.0 * camera.zoom, 1.0), palette.arrow);
            }
        }

        const colors = opColors(op);
        for (frame_positions[frame], 0..) |pos, id| {
            drawQubit(camera, font, pos, id, active[id], colors.fill, colors.stroke);
        }

        if (panel_visible) {
            drawPanel(font, op, frame, frame_count, active, num_qubits, frame_positions[frame], summary);
        } else {
            rl.drawTextEx(font, "h  show panel", .{ .x = 16, .y = 16 }, 13, 0.8, palette.text_sub);
        }
    }
}
