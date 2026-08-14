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
    /// Dimension annotations: spacing arrows and their labels.
    pub const dimension = rl.Color{ .r = 229, .g = 200, .b = 144, .a = 255 };
};

pub fn withAlpha(c: rl.Color, a: u8) rl.Color {
    return .{
        .r = c.r,
        .g = c.g,
        .b = c.b,
        .a = a,
    };
}

// UI font sizes. Every piece of text uses one of these two, and the
// row heights / offsets around text derive from them, so a bump here
// rescales the whole visualizer. Untyped so they coerce to f32 or i32.
pub const FONT = 24;
pub const FONT_LG = 28;

// Tab bar layout.
pub const TAB_H: f32 = 46;
pub const TAB_W: f32 = 130;

// Transport bar layout.
pub const BAR_H: f32 = 90;
pub const PAD: f32 = 12;
pub const BTN_W: f32 = 44;
pub const BTN_H: f32 = 34;
pub const ROW2_H: f32 = 24;
pub const FRAME_BOX_W: f32 = 110;

pub fn toVec(p: Point) rl.Vector2 {
    return .{
        .x = @floatFromInt(p.x),
        .y = @floatFromInt(p.y),
    };
}

pub const BBox = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    pub fn fromPoints(points: []const Point) BBox {
        var b = BBox{
            .min_x = std.math.floatMax(f32),
            .min_y = std.math.floatMax(f32),
            .max_x = -std.math.floatMax(f32),
            .max_y = -std.math.floatMax(f32),
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

    /// Map a world-space rectangle to screen space.
    pub fn rect(self: Camera, world: rl.Rectangle) rl.Rectangle {
        const tl = self.worldToScreen(.{ .x = world.x, .y = world.y });
        return .{
            .x = tl.x,
            .y = tl.y,
            .width = world.width * self.zoom,
            .height = world.height * self.zoom,
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

/// A view's pan/zoom state: the camera plus whether the user has touched
/// it - fits (initial, resize, `r`) keep re-framing only untouched views.
pub const Viewport = struct {
    cam: Camera = .{},
    touched: bool = false,

    pub fn fit(vp: *Viewport, bbox: BBox, region: rl.Rectangle) void {
        vp.cam.fitToRegion(bbox, region);
        vp.touched = false;
    }
};

// ── Shared chrome helpers ────────────────────────────────────────────────

/// Screen-space origin of pinned view content, just under the tab bar.
pub const CONTENT_X: f32 = PAD;
pub const CONTENT_Y: f32 = TAB_H + PAD;

/// Gap between adjacent transport-bar buttons.
pub const BTN_GAP: f32 = 6;

/// Smallest label size the zoom clamp allows.
pub const LABEL_MIN: f32 = 12;

/// Zoom-scaled label font size, clamped readable at any zoom.
pub fn labelSize(zoom: f32) f32 {
    return std.math.clamp(FONT * zoom, LABEL_MIN, FONT_LG);
}

/// Draw `txt` horizontally centered on `x`, top edge at `y`.
pub fn drawTextCentered(
    font: rl.Font,
    txt: [:0]const u8,
    x: f32,
    y: f32,
    fs: f32,
    color: rl.Color,
) void {
    const w = rl.measureTextEx(font, txt, fs, 1).x;
    rl.drawTextEx(
        font,
        txt,
        .{
            .x = x - w / 2,
            .y = y,
        },
        fs,
        1,
        color,
    );
}

/// Draw `txt` with its right edge at `x`, top edge at `y`.
pub fn drawTextRight(
    font: rl.Font,
    txt: [:0]const u8,
    x: f32,
    y: f32,
    fs: f32,
    color: rl.Color,
) void {
    const w = rl.measureTextEx(font, txt, fs, 1).x;
    rl.drawTextEx(
        font,
        txt,
        .{
            .x = x - w,
            .y = y,
        },
        fs,
        1,
        color,
    );
}

/// Rounded panel with the standard border.
pub fn drawPanel(rec: rl.Rectangle, bg: rl.Color) void {
    rl.drawRectangleRounded(rec, 0.06, 6, bg);
    rl.drawRectangleRoundedLinesEx(rec, 0.06, 6, 1.0, palette.divider);
}

/// Full-width chrome strip with its divider rule: the tab bar (divider
/// along its bottom edge) and the transport bar (divider along its top).
pub fn drawChromeStrip(y: f32, sw: f32, h: f32, divider_y: f32) void {
    rl.drawRectangleRec(
        .{
            .x = 0,
            .y = y,
            .width = sw,
            .height = h,
        },
        palette.panel_bg,
    );
    rl.drawLineEx(
        .{
            .x = 0,
            .y = divider_y,
        },
        .{
            .x = sw,
            .y = divider_y,
        },
        1.0,
        palette.divider,
    );
}

/// Placeholder line for a view with nothing to show, pinned at the
/// content origin.
pub fn drawNotice(font: rl.Font, txt: [:0]const u8) void {
    rl.drawTextEx(
        font,
        txt,
        .{
            .x = CONTENT_X,
            .y = CONTENT_Y,
        },
        FONT,
        1,
        palette.text_sub,
    );
}

// Raygui reads style colors.
pub fn styleGui(font: rl.Font) void {
    const int = rl.colorToInt;
    rg.setFont(font);
    rg.setStyle(.default, .{ .default = .text_size }, FONT);
    rg.setStyle(.default, .{ .default = .text_spacing }, 1);
    rg.setStyle(.default, .{ .default = .background_color }, int(palette.panel_bg));
    rg.setStyle(.default, .{ .default = .line_color }, int(palette.divider));
    rg.setStyle(.default, .{ .control = .base_color_normal }, int(palette.bg));
    rg.setStyle(.default, .{ .control = .border_color_normal }, int(palette.divider));
    rg.setStyle(.default, .{ .control = .text_color_normal }, int(palette.text));
    rg.setStyle(.default, .{ .control = .base_color_focused }, int(palette.divider));
    rg.setStyle(.default, .{ .control = .border_color_focused }, int(palette.accent));
    rg.setStyle(.default, .{ .control = .text_color_focused }, int(palette.text));
    rg.setStyle(.default, .{ .control = .base_color_pressed }, int(palette.accent));
    rg.setStyle(.default, .{ .control = .border_color_pressed }, int(palette.accent));
    rg.setStyle(.default, .{ .control = .text_color_pressed }, int(palette.bg));
}
