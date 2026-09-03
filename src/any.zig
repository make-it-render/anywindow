pub const WindowManager = switch (builtin.os.tag) {
    .linux => linux.WindowManager,
    .windows => win32.WindowManager,
    else => @compileError("platform not supported"),
};

pub const Window = switch (builtin.os.tag) {
    .linux => linux.Window,
    .windows => win32.Window,
    else => @compileError("platform not supported"),
};

pub const Image = switch (builtin.os.tag) {
    .linux => linux.Image,
    .windows => win32.Image,
    else => @compileError("platform not supported"),
};

/// io-native event source adapter for the recvloop io loop. Its `receive(io)`
/// delegates to `WindowManager.receiveIo`, which reads in an io-cancelable way —
/// so a loop blocked on the window source is interrupted by group cancelation
/// (no `stop()` / internal-queue-close dance needed). Pass `&WindowSource{ .wm =
/// &wm }` as a source to `recvloop.eventLoop`.
pub const WindowSource = struct {
    wm: *WindowManager,

    pub fn receive(self: *@This(), io: std.Io) !?common.Event {
        return self.wm.receiveIo(io);
    }
};

test "init" {
    const environ: std.process.Environ = .empty;
    var wm = WindowManager.init(testing.io, environ, testing.allocator) catch return;
    defer wm.deinit();
}

// Proves the io-cancelable contract: a task blocked in `receiveIo` (X11: the raw
// socket read; Win32: the cancelable queue wait) is interrupted by `group.cancel`.
// If cancelation did NOT reach the blocked read, this test would hang forever
// rather than fail — so passing means the window source is genuinely cancelable.
// Skips when no display / no concurrency is available.
test "receiveIo blocked read is interrupted by io cancelation" {
    const environ: std.process.Environ = .empty;
    var wm = WindowManager.init(testing.io, environ, testing.allocator) catch return;
    defer wm.deinit();

    var group: std.Io.Group = .init;
    group.concurrent(testing.io, struct {
        fn run(io: std.Io, w: *WindowManager) std.Io.Cancelable!void {
            // No window is shown, so no events arrive — this blocks until canceled.
            _ = w.receiveIo(io) catch {};
        }
    }.run, .{ testing.io, &wm }) catch return;

    // Give the task a moment to actually reach the blocking read.
    std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};

    // The assertion is implicit: this returns instead of hanging.
    group.cancel(testing.io);
}

pub const x11 = switch (builtin.os.tag) {
    .linux => @import("x11.zig"),
    else => struct {},
};
pub const win32 = @import("win32.zig");
pub const linux = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    else => struct {},
};
const common = @import("common.zig");

const std = @import("std");
const testing = std.testing;

const builtin = @import("builtin");
