//! Runtime Wayland/X11 backend dispatch for Linux. One binary serves both
//! session types: Wayland when $WAYLAND_DISPLAY is set (falling back to X11
//! if the Wayland connection fails), X11 otherwise.

pub const WindowManager = union(enum) {
    x11: x11.WindowManager,
    wayland: wayland.WindowManager,

    pub fn init(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator) !@This() {
        if (environ.getPosix("WAYLAND_DISPLAY") != null) {
            if (wayland.WindowManager.init(io, environ, allocator)) |wm| {
                return .{ .wayland = wm };
            } else |err| {
                log.warn("Wayland backend failed ({any}); falling back to X11", .{err});
            }
        }
        return .{ .x11 = try x11.WindowManager.init(io, environ, allocator) };
    }

    pub fn deinit(self: *@This()) void {
        switch (self.*) {
            inline else => |*wm| wm.deinit(),
        }
    }

    pub fn createWindow(self: *@This(), options: common.WindowOptions) !Window {
        return switch (self.*) {
            .x11 => |*wm| .{ .x11 = try wm.createWindow(options) },
            .wayland => |*wm| .{ .wayland = try wm.createWindow(options) },
        };
    }

    pub fn receiveIo(self: *@This(), io: std.Io) !?common.Event {
        switch (self.*) {
            inline else => |*wm| return wm.receiveIo(io),
        }
    }

    pub fn flush(self: *@This()) !void {
        switch (self.*) {
            inline else => |*wm| return wm.flush(),
        }
    }
};

pub const Window = union(enum) {
    x11: x11.Window,
    wayland: wayland.Window,

    pub fn deinit(self: *@This()) void {
        switch (self.*) {
            inline else => |*window| window.deinit(),
        }
    }

    pub fn close(self: *@This()) void {
        switch (self.*) {
            inline else => |*window| window.close(),
        }
    }

    pub fn show(self: *@This()) !void {
        switch (self.*) {
            inline else => |*window| return window.show(),
        }
    }

    pub fn toggleFullscreen(self: *@This()) void {
        switch (self.*) {
            inline else => |*window| window.toggleFullscreen(),
        }
    }

    pub fn setIcon(self: *@This(), icon: common.Icon) !void {
        switch (self.*) {
            inline else => |*window| return window.setIcon(icon),
        }
    }

    pub fn hideCursor(self: *@This()) void {
        switch (self.*) {
            inline else => |*window| window.hideCursor(),
        }
    }

    pub fn showCursor(self: *@This()) void {
        switch (self.*) {
            inline else => |*window| window.showCursor(),
        }
    }

    pub fn setCursor(self: *@This(), cursor: common.Cursor) void {
        switch (self.*) {
            inline else => |*window| window.setCursor(cursor),
        }
    }

    pub fn grabCursor(self: *@This()) void {
        switch (self.*) {
            inline else => |*window| window.grabCursor(),
        }
    }

    pub fn releaseCursor(self: *@This()) void {
        switch (self.*) {
            inline else => |*window| window.releaseCursor(),
        }
    }

    pub fn createImage(self: *@This(), allocator: std.mem.Allocator, size: common.Size) !Image {
        return switch (self.*) {
            .x11 => |*window| .{ .x11 = try window.createImage(allocator, size) },
            .wayland => |*window| .{ .wayland = try window.createImage(allocator, size) },
        };
    }

    pub fn destroyImage(self: *@This(), image: *Image) void {
        switch (self.*) {
            .x11 => |*window| window.destroyImage(&image.x11),
            .wayland => |*window| window.destroyImage(&image.wayland),
        }
    }

    pub fn clear(self: *@This(), area: common.BBox) !void {
        switch (self.*) {
            inline else => |*window| return window.clear(area),
        }
    }

    pub fn redraw(self: *@This(), area: common.BBox) !void {
        switch (self.*) {
            inline else => |*window| return window.redraw(area),
        }
    }

    pub fn supportsFramePacing(self: *const @This()) bool {
        switch (self.*) {
            inline else => |*window| return window.supportsFramePacing(),
        }
    }

    /// Physical pixels per logical unit for this window right now.
    pub fn scale(self: *@This()) f32 {
        switch (self.*) {
            inline else => |*window| return window.scale(),
        }
    }

    pub fn requestClose(self: *@This()) void {
        switch (self.*) {
            inline else => |*window| return window.requestClose(),
        }
    }

    pub fn requestFrame(self: *@This()) void {
        switch (self.*) {
            inline else => |*window| return window.requestFrame(),
        }
    }

    /// Put `text` on the system clipboard and serve it until another client copies.
    pub fn setClipboardText(self: *@This(), text: []const u8) !void {
        switch (self.*) {
            inline else => |*window| return window.setClipboardText(text),
        }
    }

    /// The clipboard's text as UTF-8, owned by the caller; waits for the owner at most one
    /// second. Fails with a `common.ClipboardError`.
    pub fn getClipboardText(self: *@This(), allocator: std.mem.Allocator) ![]u8 {
        switch (self.*) {
            inline else => |*window| return window.getClipboardText(allocator),
        }
    }

    pub fn beginDraw(self: *@This()) !void {
        switch (self.*) {
            inline else => |*window| return window.beginDraw(),
        }
    }

    pub fn endDraw(self: *@This()) !void {
        switch (self.*) {
            inline else => |*window| return window.endDraw(),
        }
    }
};

pub const Image = union(enum) {
    x11: x11.Image,
    wayland: wayland.Image,

    pub fn setPixels(self: *@This(), pixels: []const u8) void {
        switch (self.*) {
            inline else => |*image| image.setPixels(pixels),
        }
    }

    pub fn draw(self: *@This(), target: common.BBox) !void {
        switch (self.*) {
            inline else => |*image| return image.draw(target),
        }
    }

    pub fn deinit(self: *@This()) void {
        switch (self.*) {
            inline else => |*image| image.deinit(),
        }
    }
};

const std = @import("std");
const x11 = @import("x11.zig");
const wayland = @import("wayland.zig");
const common = @import("common.zig");

const log = std.log.scoped(.anywindow);
