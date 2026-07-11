//! Shared drawing vocabulary for the visualizer's views: the color
//! palette, the pan/zoom camera, world-space bounding boxes, and the
//! screen-space chrome metrics (tab bar, transport bar).

const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const schedule = @import("schedule");

const Point = schedule.Point;

pub const palette = struct {
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
    /// Faint wash behind every other stage, so stage extents read at a
    /// glance; content draws over it.
    pub const stage_band = rl.Color{ .r = 198, .g = 208, .b = 245, .a = 10 };
};

pub fn withAlpha(c: rl.Color, a: u8) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}

// Tab bar layout.
pub const TAB_H: f32 = 46;
pub const TAB_W: f32 = 110;

// Transport bar layout.
pub const BAR_H: f32 = 90;
pub const PAD: f32 = 12;
pub const BTN_W: f32 = 44;
pub const BTN_H: f32 = 34;
pub const ROW2_H: f32 = 24;
pub const FRAME_BOX_W: f32 = 110;

pub fn toVec(p: Point) rl.Vector2 {
    return .{ .x = @floatFromInt(p.x), .y = @floatFromInt(p.y) };
}

pub const BBox = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    pub fn fromPoints(points: []const Point) BBox {
        if (points.len == 0) return .{
            .min_x = -10,
            .min_y = -10,
            .max_x = 10,
            .max_y = 10,
        };
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

pub const Camera = struct {
    offset: rl.Vector2 = .{ .x = 0, .y = 0 },
    zoom: f32 = 1.0,

    pub fn worldToScreen(self: Camera, world: rl.Vector2) rl.Vector2 {
        return .{
            .x = (world.x - self.offset.x) * self.zoom,
            .y = (world.y - self.offset.y) * self.zoom,
        };
    }

    pub fn screenToWorld(self: Camera, screen: rl.Vector2) rl.Vector2 {
        return .{
            .x = screen.x / self.zoom + self.offset.x,
            .y = screen.y / self.zoom + self.offset.y,
        };
    }

    /// Fit `bbox` into `region`, a screen-space rectangle (so views can
    /// center content between the tab bar and the transport bar).
    pub fn fitToRegion(self: *Camera, bbox: BBox, region: rl.Rectangle) void {
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

// raygui reads style colors as 0xRRGGBBAA ints; setting them on .default
// propagates the base properties to every control.
pub fn styleGui(font: rl.Font) void {
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
