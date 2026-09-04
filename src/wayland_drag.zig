//! Drag-and-drop state for the Wayland backend, with the decisions that need no socket (which mime type to take, how received bytes decode) kept pure and tested here. `wayland.zig` owns the socket, the dispatch and the state mutex the types here live under.

/// The mime type chosen from a drag offer and the kind of payload it decodes to.
pub const Choice = struct {
    mime: []const u8,
    kind: common.DropKind,
};

/// What a window takes from an offer: the uri-list when it wants files and the offer has one, else the best text mime type when it wants text; nothing when the source forbids copy (`source_actions` known without the copy bit) or nothing fits.
pub fn choose(kinds: common.DropKinds, has_uri_list: bool, text_mime: ?usize, source_actions: ?u32) ?Choice {
    if (source_actions) |actions| {
        if (actions & proto.data_device.dnd_action_copy == 0) return null;
    }
    if (kinds.files and has_uri_list) return .{ .mime = proto.data_device.mime_uri_list, .kind = .files };
    if (kinds.text) {
        if (text_mime) |index| return .{ .mime = proto.data_device.text_mime_types[index], .kind = .text };
    }
    return null;
}

/// A drag over one of our surfaces, from `enter` until `leave` or `drop`. Under the manager's state mutex.
pub const DropTarget = struct {
    /// The server-created offer; 0 for a drag carrying no data.
    offer: u32,
    window_id: common.WindowID,
    /// The `enter` serial, which `accept` quotes.
    serial: u32,
    /// What will be received at the drop; null while the drag is refused, in which case no event goes out.
    choice: ?Choice,
    /// The entered surface's scale, so motion converts like the enter did.
    scale120: u32,
    x: common.X,
    y: common.Y,
    /// A non-none `wl_data_offer.action` arrived, which version 3 requires before `finish`.
    action_received: bool = false,

    /// Whether `drag_enter` went out, so `drag_leave` must follow.
    pub fn entered(self: @This()) bool {
        return self.choice != null;
    }
};

/// The bytes of a dropped offer on their way out of the source's pipe. `receiveIo` must not block on a pipe the source fills at its own pace, so this runs beside it, reads to end of file, then posts a `wl_display.sync` whose `callback_done` `receiveIo` turns into the `drop` (or `drag_leave`) event.
pub const ReceiveTask = struct {
    fd: std.posix.fd_t,
    offer: u32,
    kind: common.DropKind,
    window_id: common.WindowID,
    x: common.X,
    y: common.Y,
    /// `finish` may be sent when the receive succeeds.
    finish_allowed: bool,
    data: std.ArrayList(u8) = .empty,
    outcome: Outcome = .pending,
    future: ?std.Io.Future(void) = null,
    /// Set by whoever tears the manager down, so a read gives up at the next poll slice.
    stop: std.atomic.Value(bool) = .init(false),

    pub const Outcome = enum { pending, received, timed_out, failed };

    /// Read the pipe to its end, then hand the bytes back through `WindowManager.postDropCallback`, which registers this task and sends the sync.
    pub fn run(self: *@This(), allocator: std.mem.Allocator, wm: *WindowManager) void {
        self.outcome = readPipe(allocator, self.fd, &self.data, receive_idle_ms, &self.stop);
        _ = std.os.linux.close(self.fd);
        if (self.stop.load(.acquire)) return;
        wm.postDropCallback(self) catch |err| log.debug("Drop callback could not be posted: {any}", .{err});
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }
};

/// How long a receive waits for the source to write more before giving up: the second a clipboard paste allows.
const receive_idle_ms: u32 = 1000;
/// Polls are sliced so a `stop` is noticed promptly.
const poll_slice_ms: u32 = 100;

/// Append everything `fd` delivers until end of file to `out`. Gives up after `idle_ms` with nothing arriving, or as soon as `stop` is set.
fn readPipe(allocator: std.mem.Allocator, fd: std.posix.fd_t, out: *std.ArrayList(u8), idle_ms: u32, stop: *const std.atomic.Value(bool)) ReceiveTask.Outcome {
    var chunk: [4096]u8 = undefined;
    var idle: u32 = 0;
    while (true) {
        if (stop.load(.acquire)) return .failed;
        var fds = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, @intCast(@min(poll_slice_ms, idle_ms))) catch return .failed;
        if (ready == 0) {
            idle += poll_slice_ms;
            if (idle >= idle_ms) return .timed_out;
            continue;
        }
        idle = 0;
        const count = std.posix.read(fd, &chunk) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return .failed,
        };
        if (count == 0) return .received;
        out.appendSlice(allocator, chunk[0..count]) catch return .failed;
    }
}

/// The payload `bytes` received as `kind` decode to, in `allocator`; null when a uri-list names no local file, which is a refused drop.
pub fn decode(allocator: std.mem.Allocator, kind: common.DropKind, bytes: []const u8) std.mem.Allocator.Error!?common.DropData {
    switch (kind) {
        .text => return .{ .text = try allocator.dupe(u8, bytes) },
        .files => {
            const paths = try uri_list.parse(allocator, bytes);
            if (paths.len == 0) {
                uri_list.free(allocator, paths);
                return null;
            }
            return .{ .files = paths };
        },
    }
}

/// A drag this process started: the source object and what it serves. Under the manager's state mutex.
pub const DragSource = struct {
    id: u32,
    window_id: common.WindowID,
    /// The text, or for a file drag the uri-list, which every offered mime type gets.
    bytes: []u8,
    files: bool,
    /// `dnd_drop_performed` arrived; `finished` or `cancelled` settles it.
    dropped: bool = false,

    /// The bytes to serve for `mime`, or null when the source never offered it.
    pub fn payloadFor(self: @This(), mime: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, mime, proto.data_device.mime_uri_list)) return if (self.files) self.bytes else null;
        for (proto.data_device.text_mime_types) |candidate| {
            if (std.mem.eql(u8, candidate, mime)) return self.bytes;
        }
        return null;
    }
};

/// Render what `startDrag` was given into the bytes a source serves.
pub fn renderPayload(allocator: std.mem.Allocator, data: common.DragData) std.mem.Allocator.Error![]u8 {
    return switch (data) {
        .text => |text| try allocator.dupe(u8, text),
        .files => |paths| try uri_list.format(allocator, paths),
    };
}

const std = @import("std");
const testing = std.testing;
const wl = @import("wayland");
const proto = wl.proto;
const common = @import("common.zig");
const uri_list = @import("uri_list.zig");
const WindowManager = @import("wayland.zig").WindowManager;

const log = std.log.scoped(.any_wayland);

test "choose prefers files over text and honours the window's kinds" {
    const both: common.DropKinds = .{ .text = true, .files = true };
    try testing.expectEqual(common.DropKind.files, choose(both, true, 0, null).?.kind);
    try testing.expectEqualStrings("text/uri-list", choose(both, true, 0, null).?.mime);
    try testing.expectEqual(common.DropKind.text, choose(both, false, 2, null).?.kind);
    try testing.expectEqualStrings("UTF8_STRING", choose(both, false, 2, null).?.mime);

    const text_only: common.DropKinds = .{ .text = true };
    try testing.expectEqual(common.DropKind.text, choose(text_only, true, 1, null).?.kind);
    try testing.expectEqual(@as(?Choice, null), choose(text_only, true, null, null));

    const files_only: common.DropKinds = .{ .files = true };
    try testing.expectEqual(@as(?Choice, null), choose(files_only, false, 0, null));
    try testing.expectEqual(@as(?Choice, null), choose(.{}, true, 0, null));
}

test "choose refuses a source that forbids copy" {
    const both: common.DropKinds = .{ .text = true, .files = true };
    try testing.expectEqual(@as(?Choice, null), choose(both, true, 0, proto.data_device.dnd_action_move));
    try testing.expect(choose(both, true, 0, proto.data_device.dnd_action_copy | proto.data_device.dnd_action_move) != null);
    try testing.expect(choose(both, true, 0, proto.data_device.dnd_action_copy) != null);
}

test "decode turns a uri-list into paths and refuses one with no local file" {
    const files = (try decode(testing.allocator, .files, "file:///a%20b\r\nhttps://x/\r\n")).?;
    defer files.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), files.files.len);
    try testing.expectEqualStrings("/a b", files.files[0]);

    try testing.expectEqual(@as(?common.DropData, null), try decode(testing.allocator, .files, "https://x/\r\n"));

    const text = (try decode(testing.allocator, .text, "hello")).?;
    defer text.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", text.text);
}

test "readPipe collects a pipe to end of file and times out on a silent one" {
    var pipe: [2]i32 = undefined;
    switch (std.os.linux.errno(std.os.linux.pipe2(&pipe, .{ .CLOEXEC = true }))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer _ = std.os.linux.close(pipe[0]);
    _ = std.os.linux.write(pipe[1], "abc", 3);
    _ = std.os.linux.write(pipe[1], "def", 3);
    _ = std.os.linux.close(pipe[1]);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const stop = std.atomic.Value(bool).init(false);
    try testing.expectEqual(ReceiveTask.Outcome.received, readPipe(testing.allocator, pipe[0], &out, 1000, &stop));
    try testing.expectEqualStrings("abcdef", out.items);

    var silent: [2]i32 = undefined;
    switch (std.os.linux.errno(std.os.linux.pipe2(&silent, .{ .CLOEXEC = true }))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer _ = std.os.linux.close(silent[0]);
    defer _ = std.os.linux.close(silent[1]);
    out.clearRetainingCapacity();
    try testing.expectEqual(ReceiveTask.Outcome.timed_out, readPipe(testing.allocator, silent[0], &out, 200, &stop));

    const stopped = std.atomic.Value(bool).init(true);
    try testing.expectEqual(ReceiveTask.Outcome.failed, readPipe(testing.allocator, silent[0], &out, 1000, &stopped));
}

test "a drag source serves its bytes for the mime types it offered" {
    const text = DragSource{ .id = 1, .window_id = 1, .bytes = @constCast("hi"), .files = false };
    try testing.expectEqualStrings("hi", text.payloadFor("text/plain").?);
    try testing.expectEqualStrings("hi", text.payloadFor("STRING").?);
    try testing.expectEqual(@as(?[]const u8, null), text.payloadFor("text/uri-list"));
    try testing.expectEqual(@as(?[]const u8, null), text.payloadFor("image/png"));

    const list = try renderPayload(testing.allocator, .{ .files = &.{ "/a", "/b c" } });
    defer testing.allocator.free(list);
    const files = DragSource{ .id = 2, .window_id = 1, .bytes = list, .files = true };
    try testing.expectEqualStrings("file:///a\r\nfile:///b%20c\r\n", files.payloadFor("text/uri-list").?);
    try testing.expectEqualStrings(list, files.payloadFor("UTF8_STRING").?);
}
