//! A positioned image with DPI scaling.
//! Wraps the platform image with logical coordinates, applying
//! nearest-neighbor scaling when the window has a scaling factor.

platform_image: PlatformImage,
window: *Window,
bbox: common.BBox,
scaling: f32,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, window: *Window, bbox: common.BBox) !@This() {
    const s = window.scaling;

    const phys_width = scale(bbox.width, s);
    const phys_height = scale(bbox.height, s);

    const platform_image = try window.createImage(.{ .width = phys_width, .height = phys_height });

    return .{
        .platform_image = platform_image,
        .window = window,
        .bbox = bbox,
        .scaling = s,
        .allocator = allocator,
    };
}

pub fn deinit(self: *@This()) void {
    self.platform_image.deinit();
}

pub fn setPixels(self: *@This(), pixels: []const u8) !void {
    if (self.scaling == 1.0) {
        try self.platform_image.setPixels(pixels);
    } else {
        const phys_width = scale(self.bbox.width, self.scaling);
        const phys_height = scale(self.bbox.height, self.scaling);
        const scaled = try nearestNeighbor(
            self.allocator,
            pixels,
            self.bbox.width,
            self.bbox.height,
            phys_width,
            phys_height,
        );
        defer self.allocator.free(scaled);
        try self.platform_image.setPixels(scaled);
    }
}

pub fn draw(self: *@This()) !void {
    try self.platform_image.draw(.{
        .x = scale(self.bbox.x, self.scaling),
        .y = scale(self.bbox.y, self.scaling),
        .width = scale(self.bbox.width, self.scaling),
        .height = scale(self.bbox.height, self.scaling),
    });
}

pub fn setX(self: *@This(), x: common.X) void {
    self.bbox.x = x;
}

pub fn setY(self: *@This(), y: common.Y) void {
    self.bbox.y = y;
}

pub fn width(self: *const @This()) u16 {
    return self.bbox.width;
}

pub fn height(self: *const @This()) u16 {
    return self.bbox.height;
}

fn scale(v: anytype, scaling: f32) @TypeOf(v) {
    if (scaling == 1.0) return v;
    return @intFromFloat(@as(f32, @floatFromInt(v)) * scaling);
}

fn nearestNeighbor(
    allocator: std.mem.Allocator,
    src: []const u8,
    src_width: common.Width,
    src_height: common.Height,
    dst_width: common.Width,
    dst_height: common.Height,
) ![]u8 {
    const y_ratio: f64 = @as(f64, @floatFromInt(src_height)) / @as(f64, @floatFromInt(dst_height));
    const x_ratio: f64 = @as(f64, @floatFromInt(src_width)) / @as(f64, @floatFromInt(dst_width));

    const dst_pixels = try allocator.alloc(u8, @as(usize, dst_width) * dst_height * 4);

    var dst_y: usize = 0;
    while (dst_y < dst_height) : (dst_y += 1) {
        var dst_x: usize = 0;
        while (dst_x < dst_width) : (dst_x += 1) {
            const src_x = @min(@as(usize, @intFromFloat(@as(f32, @floatFromInt(dst_x)) * x_ratio)), @as(usize, src_width) -| 1);
            const src_y = @min(@as(usize, @intFromFloat(@as(f32, @floatFromInt(dst_y)) * y_ratio)), @as(usize, src_height) -| 1);

            const src_idx = (src_y * src_width + src_x) * 4;
            const dst_idx = (dst_y * dst_width + dst_x) * 4;

            @memcpy(dst_pixels[dst_idx..][0..4], src[src_idx..][0..4]);
        }
    }

    return dst_pixels;
}

test "nearestNeighbor 2x upscale" {
    const allocator = testing.allocator;

    // 2x2 source image: red, green, blue, white
    const src = [_]u8{
        255, 0, 0, 255, // red
        0, 255, 0, 255, // green
        0, 0, 255, 255, // blue
        255, 255, 255, 255, // white
    };

    // Scale 2x2 -> 4x4
    const result = try nearestNeighbor(allocator, &src, 2, 2, 4, 4);
    defer allocator.free(result);

    // 4x4 = 16 pixels * 4 bytes = 64 bytes
    try testing.expectEqual(@as(usize, 64), result.len);

    // Top-left quadrant should be red (first pixel repeated)
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, result[0..4]); // (0,0)
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, result[4..8]); // (1,0)
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, result[16..20]); // (0,1)
}

test "nearestNeighbor identity (no scaling)" {
    const allocator = testing.allocator;

    // 2x2 source
    const src = [_]u8{
        1,  2,  3,  4,
        5,  6,  7,  8,
        9,  10, 11, 12,
        13, 14, 15, 16,
    };

    // Same size: 2x2 -> 2x2
    const result = try nearestNeighbor(allocator, &src, 2, 2, 2, 2);
    defer allocator.free(result);

    try testing.expectEqualSlices(u8, &src, result);
}

test "nearestNeighbor 2x downscale" {
    const allocator = testing.allocator;

    // 4x4 source image
    const src = [_]u8{
        // Row 0
        255, 0, 0, 255, // red
        255, 0, 0, 255, // red
        0, 255, 0, 255, // green
        0, 255, 0, 255, // green
        // Row 1
        255, 0, 0, 255, // red
        255, 0, 0, 255, // red
        0, 255, 0, 255, // green
        0, 255, 0, 255, // green
        // Row 2
        0, 0, 255, 255, // blue
        0, 0, 255, 255, // blue
        255, 255, 255, 255, // white
        255, 255, 255, 255, // white
        // Row 3
        0, 0, 255, 255, // blue
        0, 0, 255, 255, // blue
        255, 255, 255, 255, // white
        255, 255, 255, 255, // white
    };

    // Scale 4x4 -> 2x2
    const result = try nearestNeighbor(allocator, &src, 4, 4, 2, 2);
    defer allocator.free(result);

    // 2x2 = 4 pixels * 4 bytes = 16 bytes
    try testing.expectEqual(@as(usize, 16), result.len);

    // Should sample corners: red, green, blue, white
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, result[0..4]); // red
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255 }, result[4..8]); // green
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, result[8..12]); // blue
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 255 }, result[12..16]); // white
}

test "nearestNeighbor single pixel upscale" {
    const allocator = testing.allocator;

    // 1x1 source
    const src = [_]u8{ 128, 64, 32, 255 };

    // Scale 1x1 -> 3x3
    const result = try nearestNeighbor(allocator, &src, 1, 1, 3, 3);
    defer allocator.free(result);

    // 3x3 = 9 pixels * 4 bytes = 36 bytes
    try testing.expectEqual(@as(usize, 36), result.len);

    // All pixels should be the same color
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        try testing.expectEqualSlices(u8, &src, result[i * 4 .. i * 4 + 4]);
    }
}

const std = @import("std");
const testing = std.testing;
const common = @import("common.zig");
const any = @import("any.zig");
const PlatformImage = any.PlatformImage;
const Window = any.Window;
