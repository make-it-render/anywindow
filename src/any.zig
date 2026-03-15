
pub const WindowManager = switch (builtin.os.tag) {
    .linux => x11.WindowManager,
    .windows => win32.WindowManager,
    else => @compileError("platform not supported"),
};

pub const Window = switch (builtin.os.tag) {
    .linux => x11.Window,
    .windows => win32.Window,
    else => @compileError("platform not supported"),
};

pub const PlatformImage = switch (builtin.os.tag) {
    .linux => x11.Image,
    .windows => win32.Image,
    else => @compileError("platform not supported"),
};

test "init" {
    var wm = WindowManager.init(testing.allocator) catch |err| switch (err) {
        error.WouldBlock, error.ConnectionRefused, error.FileNotFound => return,
        else => return err,
    };
        defer wm.deinit();
}

pub const x11 = @import("x11.zig");
pub const win32 = @import("win32.zig");

const std = @import("std");
const testing = std.testing;

const builtin = @import("builtin");
