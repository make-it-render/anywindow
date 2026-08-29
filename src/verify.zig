//! Live end-to-end check against the running display server: creates a
//! window, presents frames, sets an icon, grabs and releases the cursor, and
//! roundtrips after every step — a rejected request kills the connection, so
//! a clean exit means the server accepted everything. On Wayland this
//! exercises the HiDPI/cursor/icon paths (plan phases 6-7) and prints which
//! optional globals the compositor offers; on X11 the same calls cross-check
//! that backend. Run with `zig build verify`.

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const environ = init.minimal.environ;

    var wm = try win.WindowManager.init(io, environ, allocator);
    defer wm.deinit();

    switch (wm) {
        .wayland => |*wayland| std.debug.print(
            "backend wayland: compositor v{d}, viewporter {}, fractional-scale {}, pointer-constraints {}, icon-manager {}, outputs {d}, default scale {d}/120\n",
            .{
                wayland.compositor_version,
                wayland.viewporter != 0,
                wayland.fractional_scale_manager != 0,
                wayland.pointer_constraints != 0,
                wayland.icon_manager != 0,
                wayland.outputs.count(),
                wayland.default_scale120,
            },
        ),
        .x11 => |*x| std.debug.print("backend x11: scaling {d}\n", .{x.scaling}),
    }

    var window = try wm.createWindow(.{ .title = "anywindow-verify", .width = 320, .height = 240 });
    defer window.deinit();
    try window.show();
    _ = try pump(io, &wm, &window);
    printScale(&window);
    printKeymap(&wm);

    // 64x64 quadrant test pattern, opaque.
    var icon_pixels: [64 * 64 * 4]u8 = undefined;
    for (0..64) |y| {
        for (0..64) |x| {
            const pixel = icon_pixels[(y * 64 + x) * 4 ..][0..4];
            pixel[0] = if (x < 32) 255 else 0;
            pixel[1] = if (y < 32) 255 else 0;
            pixel[2] = 128;
            pixel[3] = 255;
        }
    }
    try window.setIcon(.{ .width = 64, .height = 64, .pixels = &icon_pixels });
    _ = try pump(io, &wm, &window);
    std.debug.print("setIcon: ok\n", .{});

    window.grabCursor();
    _ = try pump(io, &wm, &window);
    window.releaseCursor();
    _ = try pump(io, &wm, &window);
    std.debug.print("grabCursor/releaseCursor: ok\n", .{});

    for (0..3) |_| {
        try window.beginDraw();
        try window.clear(.{});
        try window.endDraw();
        _ = try pump(io, &wm, &window);
    }

    // Fullscreen forces a compositor-driven size change: configure with the
    // output size -> buffer realloc, busy-slot retirement, queued .resize.
    window.toggleFullscreen();
    try pumpUntilResize(io, &wm, &window);
    try window.beginDraw();
    try window.clear(.{});
    try window.endDraw();
    printScale(&window);
    window.toggleFullscreen();
    try pumpUntilResize(io, &wm, &window);
    std.debug.print("fullscreen resize: ok\n", .{});

    printScale(&window);

    if (window.supportsFramePacing()) {
        try verifyFramePacing(io, &wm, &window);
        std.debug.print("frame pacing: ok\n", .{});
    } else {
        std.debug.print("frame pacing: unsupported on this backend\n", .{});
    }

    std.debug.print("verify: ok\n", .{});
}

/// Prove the compositor's frame callback reaches us: ask for a frame, present,
/// and roundtrip until the `frame_done` comes back. It only fires while the
/// surface is visible, which it is here, but the compositor decides when — so
/// pump with a small sleep, bounded so a broken path fails rather than hangs.
fn verifyFramePacing(io: std.Io, wm: *win.WindowManager, window: *win.Window) !void {
    window.requestFrame();
    try window.beginDraw();
    try window.clear(.{});
    try window.endDraw();

    const max_polls = 50;
    const poll_interval_ms = 20;
    for (0..max_polls) |_| {
        try window.redraw(.{});
        while (try wm.receiveIo(io)) |event| {
            switch (event) {
                .frame_done => return,
                .draw => break,
                .close => return error.WindowClosed,
                else => {},
            }
        }
        try io.sleep(std.Io.Duration.fromMilliseconds(poll_interval_ms), .awake);
    }
    return error.NoFrameCallback;
}

/// The compositor decides when a fullscreen change lands, so roundtrip until
/// the .resize shows up (bounded — a broken resize path must fail, not
/// hang). The sleep matters on X11, where the window manager is a separate
/// client and reacts long after our roundtrip returns.
fn pumpUntilResize(io: std.Io, wm: *win.WindowManager, window: *win.Window) !void {
    for (0..50) |_| {
        if (try pump(io, wm, window)) return;
        try io.sleep(std.Io.Duration.fromMilliseconds(20), .awake);
    }
    return error.NoResizeEvent;
}

/// Roundtrip: redraw() injects a synthetic .draw through the server, so
/// receiving it back proves everything sent before it was processed without
/// a protocol error. Events surfacing in the meantime are reported; returns
/// whether a .resize was among them.
fn pump(io: std.Io, wm: *win.WindowManager, window: *win.Window) !bool {
    var saw_resize = false;
    try window.redraw(.{});
    while (try wm.receiveIo(io)) |event| {
        switch (event) {
            .draw => return saw_resize,
            .resize => |resize| {
                std.debug.print("resize: {d}x{d}\n", .{ resize.width, resize.height });
                saw_resize = true;
            },
            .close => return error.WindowClosed,
            else => {},
        }
    }
    return error.ConnectionClosed;
}

/// Report the XKB keymap the compositor sent: layout names and the keysym
/// resolution of the home-row <AC01> key (keycode 38) — 'a' on a US or
/// French layout — base and shifted, per group.
fn printKeymap(wm: *win.WindowManager) void {
    switch (wm.*) {
        .wayland => |*wayland| {
            const keymap = &(wayland.keymap orelse {
                std.debug.print("keymap: none (US fallback table)\n", .{});
                return;
            });
            std.debug.print("keymap: {d} group(s)", .{keymap.group_names.len});
            for (keymap.group_names, 0..) |name, group| {
                const base = keymap.keysym(38, 0, @intCast(group));
                const shifted = keymap.keysym(38, 1, @intCast(group));
                std.debug.print(", \"{s}\" key38='{c}'/'{c}'", .{
                    name,
                    printable(base),
                    printable(shifted),
                });
            }
            std.debug.print("\n", .{});
        },
        .x11 => {},
    }
}

fn printable(keysym: u32) u8 {
    if (keysym >= 0x20 and keysym < 0x7F) return @intCast(keysym);
    return '?';
}

/// No event loop task is running, so reading backend state without the
/// state mutex is safe here.
fn printScale(window: *win.Window) void {
    switch (window.*) {
        .wayland => |*wayland| {
            const shared = wayland.shared;
            std.debug.print(
                "scale {d}/120: logical {d}x{d}, buffer {d}x{d}\n",
                .{ shared.scale120, shared.logical_width, shared.logical_height, shared.width, shared.height },
            );
        },
        .x11 => {},
    }
    std.debug.print("Window.scale(): {d}\n", .{window.scale()});
}

const std = @import("std");
const win = @import("anywindow");
