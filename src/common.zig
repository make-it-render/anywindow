//! Shared types for window management: events, geometry, keys.

pub const WindowID = usize;

pub const Height = u16;
pub const Width = u16;
pub const X = i16;
pub const Y = i16;

pub const Scancode = keys.Scancode;
pub const Key = keys.Key;
pub const Modifiers = keys.Modifiers;
pub const MouseButton = u8;

pub const BBox = struct {
    height: Height = 0,
    width: Width = 0,
    x: X = 0,
    y: Y = 0,
};

pub const Size = struct {
    width: Width = 0,
    height: Height = 0,
};

pub const Position = struct {
    x: X = 0,
    y: Y = 0,
};

pub const Icon = struct {
    width: u32,
    height: u32,
    pixels: []const u8, // RGBA, 4 bytes per pixel
};

pub const WindowOptions = struct {
    title: []const u8 = "",
    width: ?Width = null,
    height: ?Height = null,
    x: ?X = null,
    y: ?Y = null,
    background: [3]u8 = [3]u8{ 0, 0, 0 },
};

pub const WindowStatus = enum {
    open,
    closed,
};

pub const Event = union(enum) {
    nop: void,
    close: WindowID,
    draw: struct {
        window_id: WindowID,
        area: BBox = .{},
    },
    mouse_pressed: struct {
        x: X,
        y: Y,
        button: MouseButton,
        window_id: WindowID,
    },
    mouse_released: struct {
        x: X,
        y: Y,
        button: MouseButton,
        window_id: WindowID,
    },
    mouse_moved: struct {
        x: X,
        y: Y,
        window_id: WindowID,
    },
    key_pressed: struct {
        scancode: Scancode,
        key: Key,
        modifiers: Modifiers,
        window_id: WindowID,
    },
    key_released: struct {
        scancode: Scancode,
        key: Key,
        modifiers: Modifiers,
        window_id: WindowID,
    },
    resize: struct {
        width: Width,
        height: Height,
        window_id: WindowID,
    },
};

pub const keys = @import("keys.zig");
