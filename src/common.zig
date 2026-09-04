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

/// What the clipboard and primary-selection methods on `Window` fail with.
pub const ClipboardError = error{
    /// Nothing, or nothing textual, is on the selection. Always the answer of `getPrimaryText`
    /// on Windows, which has no primary selection.
    ClipboardEmpty,
    /// The selection owner never answered, or stopped mid-transfer.
    ClipboardTimeout,
    /// The backend cannot do this transfer: no clipboard on this connection, a compositor
    /// without the primary-selection protocol, a Wayland copy before any input.
    ClipboardUnsupported,
};

/// The two X11-style selections a `Window` can copy to and paste from: the clipboard proper,
/// and the primary selection that middle-click pastes on Linux desktops.
pub const Selection = enum {
    clipboard,
    primary,
};

/// What a window takes when something is dragged over it. The empty set refuses every drag.
pub const DropKinds = packed struct {
    text: bool = false,
    files: bool = false,

    pub fn any(self: @This()) bool {
        return self.text or self.files;
    }
};

/// The kind of payload a drop delivers.
pub const DropKind = enum {
    text,
    files,
};

/// A drop's payload, owned by whoever holds it. Files are absolute native paths (POSIX on
/// Linux, drive paths on Windows), decoded from `text/uri-list` or `CF_HDROP`.
pub const DropData = union(DropKind) {
    text: []u8,
    files: []const []u8,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        switch (self) {
            .text => |text| allocator.free(text),
            .files => |files| {
                for (files) |path| allocator.free(path);
                allocator.free(files);
            },
        }
    }

    /// A copy of the payload in `allocator`.
    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        switch (self) {
            .text => |text| return .{ .text = try allocator.dupe(u8, text) },
            .files => |files| {
                const copies = try allocator.alloc([]u8, files.len);
                var copied: usize = 0;
                errdefer {
                    for (copies[0..copied]) |path| allocator.free(path);
                    allocator.free(copies);
                }
                for (files) |path| {
                    copies[copied] = try allocator.dupe(u8, path);
                    copied += 1;
                }
                return .{ .files = copies };
            },
        }
    }
};

/// What a drag hands out. Text goes out as UTF-8 under every text type the platform knows;
/// files go out as `text/uri-list` (or `CF_HDROP` on Windows), and as that list under the
/// text types too.
pub const DragData = union(DropKind) {
    text: []const u8,
    files: []const []const u8,
};

/// What `Window.takeDrop` fails with.
pub const DropError = error{
    /// No drop is waiting: none happened since the last `takeDrop`.
    NoDrop,
};

/// What `Window.setDropTarget` and `Window.startDrag` fail with.
pub const DragError = error{
    /// The platform has nothing to register with or drag through: no data device on this
    /// Wayland connection, OLE refused on Windows.
    DragUnsupported,
    /// No mouse button is held on the window, so there is no press to hang the drag on.
    DragNoButton,
    /// A drag from this process is still running.
    DragInProgress,
    /// The payload or the drag's own state could not be allocated.
    OutOfMemory,
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
        /// The character this key types under the active layout and
        /// modifiers, or null for keys that type nothing (function,
        /// navigation and modifier keys, dead keys, control combinations).
        codepoint: ?u21 = null,
        /// True for the presses auto-repeat generates while the key is held.
        repeat: bool = false,
        window_id: WindowID,
    },
    key_released: struct {
        scancode: Scancode,
        key: Key,
        modifiers: Modifiers,
        window_id: WindowID,
    },
    /// A character no single key press typed: what a dead-key or compose
    /// sequence types, or the spacing accent of a sequence that broke. It
    /// follows the `key_pressed` events of the sequence, which carry a null
    /// `codepoint`, so a character arrives exactly once.
    text: struct {
        codepoint: u21,
        window_id: WindowID,
    },
    resize: struct {
        width: Width,
        height: Height,
        window_id: WindowID,
    },
    /// The window gained keyboard focus.
    focus_in: WindowID,
    /// The window lost keyboard focus.
    focus_out: WindowID,
    /// The window's scale factor (physical pixels per logical unit) changed,
    /// typically because it moved to a display with a different DPI. A
    /// `resize` with the new physical size follows when the buffer changed.
    scale_changed: struct {
        window_id: WindowID,
        scale: f32,
    },
    /// Some client claimed the system clipboard, so a `getClipboardText`
    /// would now return something else. Not sent for this process's own
    /// `setClipboardText` where the platform lets the backend tell (X11
    /// through XFixes, Win32 through the clipboard sequence number). On
    /// Wayland the compositor announces the selection again whenever one of
    /// our windows gains keyboard focus, since nothing reaches an unfocused
    /// client, so the event can also mean "it may have changed while you
    /// were away". The primary selection never raises it.
    clipboard_changed: void,
    /// A drag carrying something this window takes (see `Window.setDropTarget`)
    /// came over it; `kind` is what `drop` will deliver. The source holds the
    /// pointer for as long as the drag lasts, so the pointer events stop and
    /// `drag_motion` is the position. A drag the window refuses, or that
    /// carries nothing it takes, produces no events at all.
    drag_enter: struct {
        x: X,
        y: Y,
        kind: DropKind,
        window_id: WindowID,
    },
    /// The drag moved over the window. Only between `drag_enter` and the
    /// `drag_leave` or `drop` that ends the hover.
    drag_motion: struct {
        x: X,
        y: Y,
        window_id: WindowID,
    },
    /// The drag left without dropping, or a drop failed. Ends the hover
    /// `drag_enter` began.
    drag_leave: WindowID,
    /// Something was dropped and its payload is ready: `Window.takeDrop`
    /// returns it. Ends the hover.
    drop: struct {
        x: X,
        y: Y,
        kind: DropKind,
        window_id: WindowID,
    },
    /// A drag this window started (`Window.startDrag`) ended; `accepted` is
    /// whether a target took it.
    drag_finished: struct {
        accepted: bool,
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
    wait,
    /// Diagonal resize, top-left to bottom-right.
    resize_nwse,
    /// Diagonal resize, top-right to bottom-left.
    resize_nesw,
};

pub const keys = @import("keys.zig");

const std = @import("std");

test "DropData copies and frees both kinds" {
    const testing = std.testing;
    const text = try (DropData{ .text = @constCast("hello") }).dupe(testing.allocator);
    defer text.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", text.text);

    const originals = [_][]u8{ @constCast("/a"), @constCast("/b c") };
    const files = try (DropData{ .files = &originals }).dupe(testing.allocator);
    defer files.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), files.files.len);
    try testing.expectEqualStrings("/b c", files.files[1]);
}
