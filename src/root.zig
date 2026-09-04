// The X11 backend reads its keysym tables from mir-wayland's XKB code and z11 speaks Unix sockets, so like the Wayland backend it exists only on Linux; a Windows build must not analyze it.
pub const x11 = switch (builtin.os.tag) {
    .linux => @import("x11.zig"),
    else => struct {},
};
pub const win32 = @import("win32.zig");
pub const common = @import("common.zig");
pub const wayland = switch (builtin.os.tag) {
    .linux => @import("wayland.zig"),
    else => struct {},
};
pub const queue = @import("queue.zig");
pub const keys = @import("keys.zig");
pub const any = @import("any.zig");
pub const uri_list = @import("uri_list.zig");

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
pub const DropKinds = common.DropKinds;
pub const DropKind = common.DropKind;
pub const DropData = common.DropData;
pub const DragData = common.DragData;
pub const DropError = common.DropError;
pub const DragError = common.DragError;

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
    _ = win32;
    _ = keys;
    _ = any;
    _ = uri_list;
    _ = @import("win32_drag.zig");
    if (builtin.os.tag == .linux) {
        _ = x11;
        _ = wayland;
        _ = @import("x11_drag.zig");
        _ = @import("wayland_drag.zig");
    }
}
