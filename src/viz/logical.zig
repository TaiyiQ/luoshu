//! The logical routing tables (viewmodel.SlotTables) as a zoomable grid —
//! the scalable version of route.Sequence.print()'s ASCII output.

const std = @import("std");
const rl = @import("raylib");
const viewmodel = @import("viewmodel");

const common = @import("common.zig");
const palette = common.palette;
const withAlpha = common.withAlpha;
const Camera = common.Camera;
const BBox = common.BBox;
const FONT = common.FONT;
const FONT_LG = common.FONT_LG;
const PAD = common.PAD;
const TAB_H = common.TAB_H;

// Slot-table geometry, world units.
const CELL_W: f32 = 64;
const CELL_H: f32 = 44;
const TBL_LABEL_H: f32 = 36;
const TBL_GAP: f32 = 70;
const ROW_LABEL_W: f32 = 70;

/// Per round, the SLM row of fixed qubits, then one row per timestep
/// showing which qubit each AOD column holds. An AOD entry over an
/// occupied SLM column is a CZ firing at that timestep, so those cells
/// get the rydberg highlight. All rounds stack vertically, labeled by
/// stage and round.
pub const LogicalView = struct {
    tables: *const viewmodel.SlotTables,
    cam: Camera = .{},
    touched: bool = false,

    const slm_fill = withAlpha(palette.op_load, 70);
    const ride_fill = withAlpha(palette.accent, 45);
    const fire_fill = withAlpha(palette.op_rydberg, 120);

    fn empty(v: LogicalView) bool {
        return v.tables.rounds.len == 0;
    }

    fn tableHeight(round: viewmodel.SlotTables.Round) f32 {
        return @as(f32, @floatFromInt(1 + round.moveable.len)) * CELL_H;
    }

    fn bbox(v: LogicalView) BBox {
        if (v.empty()) return .{
            .min_x = -10,
            .min_y = -10,
            .max_x = 10,
            .max_y = 10,
        };
        var w: f32 = 1;
        var y: f32 = 0;
        for (v.tables.rounds) |round| {
            w = @max(w, @as(f32, @floatFromInt(round.fixed.len)) * CELL_W);
            y += TBL_LABEL_H + tableHeight(round) + TBL_GAP;
        }
        return .{
            .min_x = -ROW_LABEL_W,
            .min_y = 0,
            .max_x = w,
            .max_y = y - TBL_GAP,
        };
    }

    pub fn fit(v: *LogicalView, region: rl.Rectangle) void {
        v.cam.fitToRegion(v.bbox(), region);
        v.touched = false;
    }

    pub fn draw(v: LogicalView, font: rl.Font, region: rl.Rectangle) void {
        if (v.empty()) {
            rl.drawTextEx(
                font,
                "nothing routed (no CZ stages)",
                .{ .x = PAD, .y = TAB_H + PAD },
                FONT,
                1,
                palette.text_sub,
            );
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
    fn drawLabel(
        v: LogicalView,
        font: rl.Font,
        round: viewmodel.SlotTables.Round,
        ty: f32,
    ) void {
        const s = v.cam.worldToScreen(.{ .x = 0, .y = ty });
        const fs = std.math.clamp(FONT_LG * v.cam.zoom, 14, FONT_LG);
        var buf: [48]u8 = undefined;
        const txt = std.fmt.bufPrintSentinel(
            &buf,
            "S{d}  round {d}/{d}",
            .{ round.stage, round.ri, round.n_in_stage - 1 },
            0,
        ) catch "?";

        rl.drawTextEx(
            font,
            txt,
            .{ .x = s.x, .y = s.y },
            fs,
            0.5,
            palette.accent,
        );
    }

    fn drawRound(
        v: LogicalView,
        font: rl.Font,
        round: viewmodel.SlotTables.Round,
        ty: f32,
        mw: ?rl.Vector2,
    ) void {
        const cam = v.cam;
        const n_slots = round.fixed.len;
        const n_rows = 1 + round.moveable.len;
        const cell_h = CELL_H * cam.zoom;
        const fs = std.math.clamp(FONT * cam.zoom, 0, FONT_LG);
        const show_text = cell_h >= 13;
        const table_w = @as(f32, @floatFromInt(n_slots)) * CELL_W;

        // The hovered row and column, banded under the cells so their
        // fills stay on top; together they crosshair the hovered cell.
        const table_h = @as(f32, @floatFromInt(n_rows)) * CELL_H;
        const band = withAlpha(palette.accent, 28);
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
            const tl = cam.worldToScreen(.{
                .x = -ROW_LABEL_W,
                .y = ty + @as(f32, @floatFromInt(r)) * CELL_H,
            });
            rl.drawRectangleRec(.{
                .x = tl.x,
                .y = tl.y,
                .width = (table_w + ROW_LABEL_W) * cam.zoom,
                .height = cell_h,
            }, band);
        }
        if (hover_col) |c| {
            const tl = cam.worldToScreen(.{
                .x = @as(f32, @floatFromInt(c)) * CELL_W,
                .y = ty,
            });
            rl.drawRectangleRec(.{
                .x = tl.x,
                .y = tl.y,
                .width = CELL_W * cam.zoom,
                .height = table_h * cam.zoom,
            }, band);
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
            rl.drawLineEx(
                cam.worldToScreen(.{ .x = x, .y = ty }),
                cam.worldToScreen(.{ .x = x, .y = y1 }),
                1.0,
                palette.divider,
            );
        }
        for (0..n_rows + 1) |r| {
            const y = ty + @as(f32, @floatFromInt(r)) * CELL_H;
            const thick: f32 = if (r == 1) 2.5 else 1.0;
            rl.drawLineEx(
                cam.worldToScreen(.{ .x = 0, .y = y }),
                cam.worldToScreen(.{ .x = x1, .y = y }),
                thick,
                palette.divider,
            );
        }

        // Row labels in the left margin: SLM, then t0..tN.
        if (cell_h >= 10) {
            const lfs = std.math.clamp(FONT * cam.zoom, 12, FONT_LG);
            for (0..n_rows) |r| {
                var buf: [12]u8 = undefined;
                const txt = if (r == 0)
                    "SLM"
                else
                    std.fmt.bufPrintSentinel(&buf, "t{d}", .{r - 1}, 0) catch "?";
                const tw = rl.measureTextEx(font, txt, lfs, 0.5).x;
                const s = cam.worldToScreen(.{
                    .x = 0,
                    .y = ty + (@as(f32, @floatFromInt(r)) + 0.5) * CELL_H,
                });
                const col = if (hover_row == r) palette.text else palette.text_sub;
                rl.drawTextEx(
                    font,
                    txt,
                    .{ .x = s.x - tw - 10, .y = s.y - lfs / 2 },
                    lfs,
                    0.5,
                    col,
                );
            }
        }
    }

    fn drawCell(
        v: LogicalView,
        font: rl.Font,
        wx: f32,
        wy: f32,
        fill: rl.Color,
        q: usize,
        show_text: bool,
        fs: f32,
    ) void {
        const tl = v.cam.worldToScreen(.{ .x = wx, .y = wy });
        rl.drawRectangleRec(.{
            .x = tl.x,
            .y = tl.y,
            .width = CELL_W * v.cam.zoom,
            .height = CELL_H * v.cam.zoom,
        }, fill);
        if (!show_text) return;
        var buf: [12]u8 = undefined;
        const txt = std.fmt.bufPrintSentinel(&buf, "{d}", .{q}, 0) catch "?";
        const tw = rl.measureTextEx(font, txt, fs, 0.5).x;
        const c = v.cam.worldToScreen(.{
            .x = wx + CELL_W / 2,
            .y = wy + CELL_H / 2,
        });
        rl.drawTextEx(
            font,
            txt,
            .{ .x = c.x - tw / 2, .y = c.y - fs / 2 },
            fs,
            0.5,
            palette.text,
        );
    }

    // The ASCII table's `·`: an empty slot.
    fn drawDot(v: LogicalView, wx: f32, wy: f32) void {
        const c = v.cam.worldToScreen(.{
            .x = wx + CELL_W / 2,
            .y = wy + CELL_H / 2,
        });
        rl.drawCircleV(c, @max(1.0, 2.5 * v.cam.zoom), palette.qdot);
    }
};

fn legendChip(font: rl.Font, x: f32, region_y: f32, fill: rl.Color, txt: [:0]const u8) f32 {
    rl.drawRectangleRounded(.{
        .x = x,
        .y = region_y + 10,
        .width = 14,
        .height = 14,
    }, 0.3, 4, fill);
    rl.drawTextEx(
        font,
        txt,
        .{ .x = x + 18, .y = region_y + 6 },
        FONT,
        0.5,
        palette.text_sub,
    );
    return x + 18 + rl.measureTextEx(font, txt, FONT, 0.5).x + PAD;
}
