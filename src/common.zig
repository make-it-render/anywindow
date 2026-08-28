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
    /// The compositor is about to repaint and the window may present a new
    /// frame — the answer to a `requestFrame`, delivered in step with the
    /// display's refresh. Only backends that pace this way emit it;
    /// `Window.supportsFramePacing` says which. The request is one-shot: to
    /// keep animating, call `requestFrame` again from here.
    frame_done: WindowID,
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
    mouse_scroll: struct {
        x: X,
        y: Y,
        scroll_x: f32,
        scroll_y: f32,
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

pub const Cursor = enum {
    default,
    hand,
    crosshair,
    text,
    not_allowed,
    resize_ns,
    resize_ew,
    move,
};

pub const keys = @import("keys.zig");
