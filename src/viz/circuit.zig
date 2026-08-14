//! The flat and staged circuit diagrams: wires and gates laid out in world
//! space (columns from viewmodel.CircuitLayout) behind a pan/zoom camera,
//! with the qubit labels pinned in a left gutter and stage labels pinned
//! along the top so they stay readable wherever the camera is.

const std = @import("std");
const rl = @import("raylib");
const viewmodel = @import("viewmodel");

const common = @import("common.zig");
const palette = common.palette;
const drawTextCentered = common.drawTextCentered;
const labelSize = common.labelSize;
const Viewport = common.Viewport;
const BBox = common.BBox;
const FONT = common.FONT;
const FONT_LG = common.FONT_LG;

// Circuit diagram geometry, in world units (the camera maps them to pixels).
const COL_W: f32 = 60;
const WIRE_DY: f32 = 56;
const GATE_BOX: f32 = 40;
const CZ_R: f32 = 8;
/// Width of the pinned qubit-label gutter; run() starts the circuit
/// regions past it.
pub const GUTTER_W: f32 = 80;

pub const CircuitView = struct {
    lay: viewmodel.CircuitLayout,
    show_stages: bool,
    vp: Viewport = .{},

    fn wireY(q: usize) f32 {
        return @as(f32, @floatFromInt(q)) * WIRE_DY;
    }

    fn colX(col: usize) f32 {
        return (@as(f32, @floatFromInt(col)) + 0.5) * COL_W;
    }

    fn bbox(v: CircuitView) BBox {
        const w: f32 = @as(f32, @floatFromInt(@max(v.lay.n_cols, 1))) * COL_W;
        const h: f32 = @as(f32, @floatFromInt(@max(v.lay.num_qubits, 1) - 1)) * WIRE_DY;
        return .{
            .min_x = -COL_W,
            .min_y = -WIRE_DY,
            .max_x = w + COL_W,
            .max_y = h + WIRE_DY,
        };
    }

    pub fn fit(v: *CircuitView, region: rl.Rectangle) void {
        v.vp.fit(v.bbox(), region);
    }

    pub fn draw(v: CircuitView, font: rl.Font, region: rl.Rectangle) void {
        const cam = v.vp.cam;
        const nq = v.lay.num_qubits;
        const content_w: f32 = @as(f32, @floatFromInt(v.lay.n_cols)) * COL_W;

        // Alternating stage bands under everything else.
        if (v.show_stages) {
            const band_h = wireY(nq -| 1) + 2 * WIRE_DY;
            for (v.lay.stage_cols, 0..) |sc, s| {
                if (s % 2 == 0) continue;
                const x0 = @as(f32, @floatFromInt(sc)) * COL_W;
                const end_col: f32 = if (s + 1 < v.lay.stage_cols.len)
                    @floatFromInt(v.lay.stage_cols[s + 1])
                else
                    @floatFromInt(v.lay.n_cols);
                rl.drawRectangleRec(cam.rect(.{
                    .x = x0,
                    .y = -WIRE_DY,
                    .width = end_col * COL_W - x0,
                    .height = band_h,
                }), palette.stage_band);
            }
        }

        for (0..nq) |q| {
            const y = wireY(q);
            const a = cam.worldToScreen(.{
                .x = -COL_W * 0.5,
                .y = y,
            });
            const b = cam.worldToScreen(.{
                .x = content_w + COL_W * 0.5,
                .y = y,
            });
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
        const fs = FONT_LG * cam.zoom;
        for (v.lay.laid) |lg| {
            switch (lg.gate) {
                .u => |g| v.drawGateBox(
                    font,
                    lg.col,
                    g.qubit,
                    "U",
                    palette.accent,
                    box,
                    fs,
                ),
                .reset => |g| v.drawGateBox(
                    font,
                    lg.col,
                    g.qubit,
                    "R",
                    palette.op_store,
                    box,
                    fs,
                ),
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

    fn drawGateBox(
        v: CircuitView,
        font: rl.Font,
        col: usize,
        q: u32,
        label: [:0]const u8,
        fill: rl.Color,
        box: f32,
        fs: f32,
    ) void {
        const c = v.vp.cam.worldToScreen(.{
            .x = colX(col),
            .y = wireY(q),
        });
        const rec = rl.Rectangle{
            .x = c.x - box / 2,
            .y = c.y - box / 2,
            .width = box,
            .height = box,
        };
        rl.drawRectangleRounded(rec, 0.2, 4, fill);
        if (box >= 14) {
            drawTextCentered(font, label, c.x, c.y - fs / 2, fs, palette.bg);
        }
    }

    // Qubit labels pinned to a left gutter; at low zoom only every k-th
    // label draws, so a thousand wires don't smear into one column of text.
    fn drawGutter(v: CircuitView, font: rl.Font, region: rl.Rectangle) void {
        rl.drawRectangleRec(
            .{
                .x = 0,
                .y = region.y,
                .width = GUTTER_W,
                .height = region.height,
            },
            palette.panel_bg,
        );
        rl.drawLineEx(
            .{ .x = GUTTER_W, .y = region.y },
            .{ .x = GUTTER_W, .y = region.y + region.height },
            1.0,
            palette.divider,
        );

        const spacing = WIRE_DY * v.vp.cam.zoom;

        if (spacing < 1) return;

        const fs = labelSize(v.vp.cam.zoom);
        const step: usize = if (spacing >= fs + 2)
            1
        else
            @intFromFloat(@ceil((fs + 2) / spacing));

        var q: usize = 0;
        while (q < v.lay.num_qubits) : (q += step) {
            const sy = v.vp.cam.worldToScreen(.{ .x = 0, .y = wireY(q) }).y;
            if (sy < region.y + fs / 2 or sy > region.y + region.height) continue;
            var buf: [12]u8 = undefined;
            const label = std.fmt.bufPrintSentinel(&buf, "q{d}", .{q}, 0) catch "?";
            rl.drawTextEx(
                font,
                label,
                .{ .x = 10, .y = sy - fs / 2 },
                fs,
                0.5,
                palette.text_sub,
            );
        }
    }

    // Stage labels pinned below the tab bar at each stage's first column.
    fn drawStageLabels(v: CircuitView, font: rl.Font, region: rl.Rectangle) void {
        if (!v.show_stages) return;
        for (v.lay.stage_cols, 0..) |sc, s| {
            const sx = v.vp.cam.worldToScreen(.{
                .x = @as(f32, @floatFromInt(sc)) * COL_W,
                .y = 0,
            }).x;
            if (sx < GUTTER_W or sx > region.x + region.width) continue;
            var buf: [16]u8 = undefined;
            const label = std.fmt.bufPrintSentinel(&buf, "S{d}", .{s}, 0) catch "?";
            rl.drawTextEx(
                font,
                label,
                .{ .x = sx + 4, .y = region.y + 6 },
                FONT,
                0.5,
                palette.accent,
            );
        }
    }
};
