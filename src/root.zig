pub const x11 = @import("x11.zig");
pub const win32 = @import("win32.zig");
pub const common = @import("common.zig");
pub const wayland = switch (builtin.os.tag) {
    .linux => @import("wayland.zig"),
    else => struct {},
};
pub const queue = @import("queue.zig");
pub const keys = @import("keys.zig");
pub const any = @import("any.zig");

pub const WindowID = common.WindowID;
pub const Size = common.Size;
pub const Position = common.Position;
pub const Height = common.Height;
pub const Width = common.Width;
pub const BBox = common.BBox;
pub const X = common.X;
pub const Y = common.Y;
pub const Scancode = common.Scancode;
pub const Key = common.Key;
pub const Modifiers = common.Modifiers;
pub const MouseButton = common.MouseButton;
pub const Icon = common.Icon;
pub const Cursor = common.Cursor;
pub const WindowOptions = common.WindowOptions;
pub const WindowStatus = common.WindowStatus;
pub const Event = common.Event;

pub const WindowManager = any.WindowManager;
pub const Image = any.Image;
pub const Window = any.Window;
pub const WindowSource = any.WindowSource;

const std = @import("std");
const testing = std.testing;

const builtin = @import("builtin");

test {
    _ = common;
    _ = queue;
    _ = x11;
    _ = win32;
    _ = keys;
    _ = any;
    if (builtin.os.tag == .linux) {
        _ = wayland;
    }
}
