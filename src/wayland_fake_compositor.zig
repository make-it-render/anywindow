//! A scripted Wayland compositor over a Unix socket, for tests only. It speaks just enough of the registry, seat, shm, xdg shell and version 3 data device for a real `WindowManager` to connect through `environ`, open a window, be dragged over and drag out. A test scripts the compositor's side with the event senders below and checks what the client sent through `waitFor`. Live compositors offer no input injection, so this is how the drag paths run unattended.

allocator: std.mem.Allocator,
io: std.Io,
temp_dir: std.testing.TmpDir,
/// `WAYLAND_DISPLAY=<absolute socket path>`, the one entry of the environ handed to the client.
environ_entry: [:0]u8,
environ_entries: [:null]?[*:0]const u8,
server: std.Io.net.Server,
thread: ?std.Thread = null,
/// Guards `requests`, `kinds` and `ids`; the serving thread fills them, the test reads them.
mutex: std.Io.Mutex = .init,
/// Both threads write events: the test its script, the serving thread its automatic answers.
write_mutex: std.Io.Mutex = .init,
conn: std.atomic.Value(i32) = .init(-1),
requests: std.ArrayList(Request) = .empty,
kinds: std.AutoHashMapUnmanaged(u32, Kind) = .empty,
ids: Ids = .{},
/// Descriptors received ahead of the request that declares them; serving thread only.
pending_fds: std.ArrayList(std.posix.fd_t) = .empty,
/// When set, the client is dragging onto itself: a `receive` on any offer is forwarded to this source as a `send` with the same pipe, and a `finish` becomes `dnd_drop_performed` and `dnd_finished` on it, as a compositor bridges a self drop.
self_source: std.atomic.Value(u32) = .init(0),

/// One request the client sent, args still encoded; `fd` for a `wl_data_offer.receive`.
pub const Request = struct {
    object: u32,
    opcode: u16,
    args: []u8,
    fd: ?std.posix.fd_t = null,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.args);
    }

    pub fn reader(self: @This()) wire.ArgReader {
        return .{ .bytes = self.args };
    }
};

/// The ids the client chose for the objects the script addresses.
pub const Ids = struct {
    registry: u32 = 0,
    seat: u32 = 0,
    pointer: u32 = 0,
    surface: u32 = 0,
    data_device_manager: u32 = 0,
    data_device: u32 = 0,
    data_source: u32 = 0,
};

const Kind = enum { registry, compositor, shm, wm_base, seat, pointer, data_device_manager, data_device, data_source, data_offer, other };

/// The registry as advertised: `(name, interface, version)`.
const globals = [_]struct { name: u32, interface: []const u8, version: u32 }{
    .{ .name = 1, .interface = "wl_compositor", .version = 6 },
    .{ .name = 2, .interface = "wl_shm", .version = 1 },
    .{ .name = 3, .interface = "xdg_wm_base", .version = 1 },
    .{ .name = 4, .interface = "wl_seat", .version = 5 },
    .{ .name = 5, .interface = "wl_data_device_manager", .version = 3 },
};

/// How long `waitFor` gives the client to send a request.
const wait_ms: u32 = 5000;

pub fn start(io: std.Io, allocator: std.mem.Allocator) !*@This() {
    const self = try allocator.create(@This());
    errdefer allocator.destroy(self);
    var temp_dir = std.testing.tmpDir(.{});
    errdefer temp_dir.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try temp_dir.dir.realPath(io, &path_buffer);
    const environ_entry = try std.fmt.allocPrintSentinel(allocator, "WAYLAND_DISPLAY={s}/wl", .{path_buffer[0..dir_len]}, 0);
    errdefer allocator.free(environ_entry);
    const socket_path = environ_entry["WAYLAND_DISPLAY=".len..];
    const entries = try allocator.allocSentinel(?[*:0]const u8, 1, null);
    errdefer allocator.free(entries);
    entries[0] = environ_entry.ptr;

    const address = try std.Io.net.UnixAddress.init(socket_path);
    const server = try address.listen(io, .{});

    self.* = .{
        .allocator = allocator,
        .io = io,
        .temp_dir = temp_dir,
        .environ_entry = environ_entry,
        .environ_entries = entries,
        .server = server,
    };
    self.thread = try std.Thread.spawn(.{}, serve, .{self});
    return self;
}

/// Stop serving and free everything. Close the client first, so the serving thread sees end of file; a thread still waiting to accept is woken by shutting the listener down.
pub fn deinit(self: *@This()) void {
    _ = linux.shutdown(self.server.socket.handle, linux.SHUT.RDWR);
    if (self.thread) |thread| thread.join();
    self.server.deinit(self.io);
    for (self.requests.items) |request| {
        if (request.fd) |fd| _ = std.os.linux.close(fd);
        request.deinit(self.allocator);
    }
    self.requests.deinit(self.allocator);
    self.kinds.deinit(self.allocator);
    for (self.pending_fds.items) |fd| _ = std.os.linux.close(fd);
    self.pending_fds.deinit(self.allocator);
    self.allocator.free(self.environ_entries);
    self.allocator.free(self.environ_entry);
    self.temp_dir.cleanup();
    const allocator = self.allocator;
    allocator.destroy(self);
}

/// The environ that makes a `WindowManager` connect here.
pub fn environ(self: *@This()) std.process.Environ {
    return .{ .block = .{ .slice = self.environ_entries } };
}

/// The ids the client chose so far.
pub fn idsSnapshot(self: *@This()) Ids {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.ids;
}

// The serving thread.

fn serve(self: *@This()) void {
    const stream = self.server.accept(self.io) catch return;
    defer stream.close(self.io);
    self.conn.store(stream.socket.handle, .release);

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(self.allocator);
    var chunk: [65536]u8 = undefined;
    while (true) {
        var control: [256]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        var iov = [1]std.posix.iovec{.{ .base = &chunk, .len = chunk.len }};
        var message = linux.msghdr{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };
        const rc = linux.recvmsg(stream.socket.handle, &message, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return,
        }
        if (rc == 0) return;
        self.collectFds(control[0..message.controllen]);
        input.appendSlice(self.allocator, chunk[0..rc]) catch return;

        var consumed: usize = 0;
        while (input.items.len - consumed >= wire.header_size) {
            const header = wire.parseHeader(input.items[consumed..][0..wire.header_size].*);
            if (header.size < wire.header_size or input.items.len - consumed < header.size) break;
            const body = input.items[consumed + wire.header_size .. consumed + header.size];
            self.handle(header.object_id, header.opcode, body) catch return;
            consumed += header.size;
        }
        input.replaceRange(self.allocator, 0, consumed, &.{}) catch return;
    }
}

fn collectFds(self: *@This(), control: []const u8) void {
    const header_size = std.mem.alignForward(usize, @sizeOf(linux.cmsghdr), @sizeOf(usize));
    var offset: usize = 0;
    while (offset + @sizeOf(linux.cmsghdr) <= control.len) {
        const header: *align(1) const linux.cmsghdr = @ptrCast(control[offset..].ptr);
        if (header.len < header_size or offset + header.len > control.len) break;
        if (header.level == std.posix.SOL.SOCKET and header.type == std.posix.SCM.RIGHTS) {
            const payload = control[offset + header_size .. offset + header.len];
            var index: usize = 0;
            while (index + 4 <= payload.len) : (index += 4) {
                const fd = std.mem.readInt(i32, payload[index..][0..4], native_endian);
                self.pending_fds.append(self.allocator, fd) catch {
                    _ = linux.close(fd);
                };
            }
        }
        offset += std.mem.alignForward(usize, header.len, @sizeOf(usize));
    }
}

/// Answer what the protocol needs answered, note the ids that matter, and record the request.
fn handle(self: *@This(), object: u32, opcode: u16, body: []const u8) !void {
    var args = wire.ArgReader{ .bytes = body };
    var fd: ?std.posix.fd_t = null;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (object == wire_display_id) {
        switch (opcode) {
            0 => {
                const callback = try args.uint();
                try self.sendLocked(&build(callback, 0, .{ .uint = 0 }));
            },
            1 => {
                self.ids.registry = try args.uint();
                try self.kinds.put(self.allocator, self.ids.registry, .registry);
                for (globals) |global| {
                    try self.sendLocked(&build(self.ids.registry, 0, .{ .uint = global.name, .string = global.interface, .uint2 = global.version }));
                }
            },
            else => {},
        }
    } else if (self.kinds.get(object)) |kind| switch (kind) {
        .registry => if (opcode == 0) {
            _ = try args.uint();
            const interface = try args.string();
            _ = try args.uint();
            const new_id = try args.uint();
            const bound: Kind = if (std.mem.eql(u8, interface, "wl_compositor")) .compositor else if (std.mem.eql(u8, interface, "wl_shm")) .shm else if (std.mem.eql(u8, interface, "xdg_wm_base")) .wm_base else if (std.mem.eql(u8, interface, "wl_seat")) .seat else if (std.mem.eql(u8, interface, "wl_data_device_manager")) .data_device_manager else .other;
            try self.kinds.put(self.allocator, new_id, bound);
            if (bound == .seat) {
                self.ids.seat = new_id;
                try self.sendLocked(&build(new_id, 0, .{ .uint = proto.wayland.seat_capability_pointer }));
            }
            if (bound == .data_device_manager) self.ids.data_device_manager = new_id;
        },
        .compositor => if (opcode == 0) {
            self.ids.surface = try args.uint();
        },
        .seat => if (opcode == 0) {
            self.ids.pointer = try args.uint();
            try self.kinds.put(self.allocator, self.ids.pointer, .pointer);
        },
        .data_device_manager => switch (opcode) {
            0 => {
                self.ids.data_source = try args.uint();
                try self.kinds.put(self.allocator, self.ids.data_source, .data_source);
            },
            1 => {
                self.ids.data_device = try args.uint();
                try self.kinds.put(self.allocator, self.ids.data_device, .data_device);
            },
            else => {},
        },
        .shm => if (opcode == 0) {
            if (self.pending_fds.items.len > 0) _ = linux.close(self.pending_fds.orderedRemove(0));
        },
        .data_offer => switch (opcode) {
            1 => {
                if (self.pending_fds.items.len > 0) fd = self.pending_fds.orderedRemove(0);
                const source = self.self_source.load(.acquire);
                if (source != 0) {
                    if (fd) |pipe_end| {
                        const mime = try args.string();
                        const message = build(source, 1, .{ .string = mime });
                        self.write_mutex.lockUncancelable(self.io);
                        defer self.write_mutex.unlock(self.io);
                        try wl.socket.sendWithFd(self.conn.load(.acquire), message.slice(), pipe_end);
                        _ = linux.close(pipe_end);
                        fd = null;
                    }
                }
            },
            3 => {
                const source = self.self_source.load(.acquire);
                if (source != 0) {
                    try self.sendLocked(&build(source, 3, .{}));
                    try self.sendLocked(&build(source, 4, .{}));
                }
            },
            else => {},
        },
        else => {},
    };
    try self.requests.append(self.allocator, .{ .object = object, .opcode = opcode, .args = try self.allocator.dupe(u8, body), .fd = fd });
}

const wire_display_id: u32 = 1;

// Scripting, from the test thread.

/// The first recorded request on `object` with `opcode`, removed from the record; waits up to `wait_ms` for it.
pub fn waitFor(self: *@This(), object: u32, opcode: u16) !Request {
    var waited: u32 = 0;
    while (waited <= wait_ms) : (waited += 5) {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.requests.items, 0..) |request, index| {
                if (request.object == object and request.opcode == opcode) return self.requests.orderedRemove(index);
            }
        }
        try self.io.sleep(std.Io.Duration.fromMilliseconds(5), .awake);
    }
    return error.RequestNeverCame;
}

/// True when no request on `object` with `opcode` was recorded, after giving the client `grace_ms`.
pub fn sawNone(self: *@This(), object: u32, opcode: u16, grace_ms: u32) !bool {
    try self.io.sleep(std.Io.Duration.fromMilliseconds(grace_ms), .awake);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.requests.items) |request| {
        if (request.object == object and request.opcode == opcode) return false;
    }
    return true;
}

/// Register a server-created offer id, then announce it on the data device.
pub fn newOffer(self: *@This(), offer: u32) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.kinds.put(self.allocator, offer, .data_offer);
    try self.sendLocked(&build(self.ids.data_device, 0, .{ .uint = offer }));
}

pub fn offerMime(self: *@This(), offer: u32, mime: []const u8) !void {
    try self.send(&build(offer, 0, .{ .string = mime }));
}

pub fn offerSourceActions(self: *@This(), offer: u32, actions: u32) !void {
    try self.send(&build(offer, 1, .{ .uint = actions }));
}

pub fn offerAction(self: *@This(), offer: u32, action: u32) !void {
    try self.send(&build(offer, 2, .{ .uint = action }));
}

pub fn dragEnter(self: *@This(), serial: u32, surface: u32, x: f32, y: f32, offer: u32) !void {
    const device = self.idsSnapshot().data_device;
    try self.send(&build(device, 1, .{ .uint = serial, .uint2 = surface, .fixed = fixed(x), .fixed2 = fixed(y), .uint3 = offer }));
}

pub fn dragLeave(self: *@This()) !void {
    try self.send(&build(self.idsSnapshot().data_device, 2, .{}));
}

pub fn dragMotion(self: *@This(), time: u32, x: f32, y: f32) !void {
    try self.send(&build(self.idsSnapshot().data_device, 3, .{ .uint = time, .fixed = fixed(x), .fixed2 = fixed(y) }));
}

pub fn dragDrop(self: *@This()) !void {
    try self.send(&build(self.idsSnapshot().data_device, 4, .{}));
}

pub fn pointerEnter(self: *@This(), serial: u32, surface: u32, x: f32, y: f32) !void {
    try self.send(&build(self.idsSnapshot().pointer, 0, .{ .uint = serial, .uint2 = surface, .fixed = fixed(x), .fixed2 = fixed(y) }));
}

pub fn pointerButton(self: *@This(), serial: u32, button: u32, pressed: bool) !void {
    const state: u32 = if (pressed) proto.wayland.state_pressed else proto.wayland.state_released;
    try self.send(&build(self.idsSnapshot().pointer, 3, .{ .uint = serial, .uint2 = 0, .uint3 = button, .uint4 = state }));
}

pub fn sourceTarget(self: *@This(), source: u32, mime: []const u8) !void {
    try self.send(&build(source, 0, .{ .string = mime }));
}

/// `wl_data_source.send` with the pipe end attached out of band; the fd stays the caller's to close.
pub fn sourceSend(self: *@This(), source: u32, mime: []const u8, fd: std.posix.fd_t) !void {
    const message = build(source, 1, .{ .string = mime });
    self.write_mutex.lockUncancelable(self.io);
    defer self.write_mutex.unlock(self.io);
    try wl.socket.sendWithFd(self.conn.load(.acquire), message.slice(), fd);
}

pub fn sourceCancelled(self: *@This(), source: u32) !void {
    try self.send(&build(source, 2, .{}));
}

pub fn sourceDropPerformed(self: *@This(), source: u32) !void {
    try self.send(&build(source, 3, .{}));
}

pub fn sourceFinished(self: *@This(), source: u32) !void {
    try self.send(&build(source, 4, .{}));
}

fn send(self: *@This(), message: *const Message) !void {
    self.write_mutex.lockUncancelable(self.io);
    defer self.write_mutex.unlock(self.io);
    try self.writeAll(message.slice());
}

/// For the serving thread, which already holds `mutex`; the write lock is separate, so this never inverts an order.
fn sendLocked(self: *@This(), message: *const Message) !void {
    try self.send(message);
}

fn writeAll(self: *@This(), bytes: []const u8) !void {
    const socket_fd = self.conn.load(.acquire);
    if (socket_fd < 0) return error.NotConnected;
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = linux.write(socket_fd, bytes[sent..].ptr, bytes.len - sent);
        switch (linux.errno(rc)) {
            .SUCCESS => sent += rc,
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

fn fixed(value: f32) wire.Fixed {
    return @intFromFloat(value * 256);
}

/// The arguments of one event, in this order: `uint`, `string`, `uint2`, `fixed`, `fixed2`, `uint3`, `uint4`. Only the ones set are written.
const Args = struct {
    uint: ?u32 = null,
    string: ?[]const u8 = null,
    uint2: ?u32 = null,
    fixed: ?wire.Fixed = null,
    fixed2: ?wire.Fixed = null,
    uint3: ?u32 = null,
    uint4: ?u32 = null,
};

const Message = struct {
    bytes: [256]u8,
    len: usize,

    fn slice(self: *const @This()) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Encode one event. The size is patched into the header once the arguments are in.
fn build(object: u32, opcode: u16, args: Args) Message {
    var message: Message = .{ .bytes = undefined, .len = 0 };
    var writer = std.Io.Writer.fixed(&message.bytes);
    wire.writeHeader(&writer, object, opcode, 0) catch unreachable;
    if (args.uint) |value| wire.writeUint(&writer, value) catch unreachable;
    if (args.string) |value| wire.writeString(&writer, value) catch unreachable;
    if (args.uint2) |value| wire.writeUint(&writer, value) catch unreachable;
    if (args.fixed) |value| wire.writeInt(&writer, value) catch unreachable;
    if (args.fixed2) |value| wire.writeInt(&writer, value) catch unreachable;
    if (args.uint3) |value| wire.writeUint(&writer, value) catch unreachable;
    if (args.uint4) |value| wire.writeUint(&writer, value) catch unreachable;
    message.len = writer.end;
    std.mem.writeInt(u32, message.bytes[4..8], (@as(u32, @intCast(message.len)) << 16) | opcode, .little);
    return message;
}

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const native_endian = @import("builtin").cpu.arch.endian();
const wl = @import("wayland");
const wire = wl.wire;
const proto = wl.proto;
const common = @import("common.zig");
const wayland = @import("wayland.zig");

// The scenarios. Each connects a real WindowManager to the fake and drives one drag.

const FakeCompositor = @This();

/// A manager and a window connected to a fake compositor, at a stable address.
const Rig = struct {
    fake: *FakeCompositor,
    wm: wayland.WindowManager,
    window: wayland.Window,

    fn start() !*Rig {
        const rig = try testing.allocator.create(Rig);
        errdefer testing.allocator.destroy(rig);
        rig.fake = try FakeCompositor.start(testing.io, testing.allocator);
        errdefer rig.fake.deinit();
        rig.wm = try wayland.WindowManager.init(testing.io, rig.fake.environ(), testing.allocator);
        errdefer rig.wm.deinit();
        rig.window = try rig.wm.createWindow(.{ .width = 300, .height = 200 });
        return rig;
    }

    fn deinit(self: *@This()) void {
        self.window.deinit();
        self.wm.deinit();
        self.fake.deinit();
        testing.allocator.destroy(self);
    }

    fn surface(self: *@This()) u32 {
        return @intCast(self.window.window_id);
    }

    fn receive(self: *@This()) !common.Event {
        return (try self.wm.receiveIo(testing.io)) orelse error.NoEvent;
    }

    /// Announce an offer carrying `mimes`, with the source's actions when given, and enter the window with it.
    fn enterWith(self: *@This(), offer: u32, mimes: []const []const u8, source_actions: ?u32, serial: u32) !void {
        try self.fake.newOffer(offer);
        for (mimes) |mime| try self.fake.offerMime(offer, mime);
        if (source_actions) |actions| try self.fake.offerSourceActions(offer, actions);
        try self.fake.dragEnter(serial, self.surface(), 10, 20, offer);
    }

    /// Answer the receive the client will send for `offer` with `bytes`, on a thread of its own: the client only sends it once the test thread pumps the drop through `receive`, and the `drop` event that pump returns needs the answer first.
    fn answerReceive(self: *@This(), offer: u32, expected_mime: []const u8, bytes: []const u8) !Answer {
        var answer: Answer = .{ .rig = self, .offer = offer, .expected_mime = expected_mime, .bytes = bytes };
        answer.thread = try std.Thread.spawn(.{}, Answer.run, .{&answer});
        return answer;
    }
};

/// The source's side of one receive: waits for the request, writes the bytes, closes the pipe. `finish` joins it and reports what went wrong, if anything.
const Answer = struct {
    rig: *Rig,
    offer: u32,
    expected_mime: []const u8,
    bytes: []const u8,
    thread: ?std.Thread = null,
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        self.serve() catch |err| {
            self.failure = err;
        };
    }

    fn serve(self: *@This()) !void {
        const receive_request = try self.rig.fake.waitFor(self.offer, 1);
        defer receive_request.deinit(testing.allocator);
        var args = receive_request.reader();
        const mime = try args.string();
        if (!std.mem.eql(u8, mime, self.expected_mime)) return error.WrongMime;
        const fd = receive_request.fd orelse return error.NoFd;
        defer _ = linux.close(fd);
        var sent: usize = 0;
        while (sent < self.bytes.len) {
            const rc = linux.write(fd, self.bytes[sent..].ptr, self.bytes.len - sent);
            if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
            sent += rc;
        }
    }

    fn finish(self: *@This()) !void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.failure) |err| return err;
    }
};

const copy = proto.data_device.dnd_action_copy;
const move = proto.data_device.dnd_action_move;
const uri_list_mime = proto.data_device.mime_uri_list;
const utf8_mime = proto.data_device.mime_utf8;
/// The evdev code of the left mouse button (`BTN_LEFT`).
const button_left: u32 = 0x110;

test "a file drag over a window taking files is entered, moved and dropped" {
    const rig = try Rig.start();
    defer rig.deinit();
    try rig.window.setDropTarget(.{ .text = true, .files = true });

    const offer: u32 = 0xff000001;
    try rig.enterWith(offer, &.{ uri_list_mime, utf8_mime }, copy | move, 7);
    const enter = try rig.receive();
    try testing.expectEqual(common.DropKind.files, enter.drag_enter.kind);
    try testing.expectEqual(@as(i16, 10), enter.drag_enter.x);
    try testing.expectEqual(@as(i16, 20), enter.drag_enter.y);
    try testing.expectEqual(@as(usize, rig.surface()), enter.drag_enter.window_id);

    const accept = try rig.fake.waitFor(offer, 0);
    defer accept.deinit(testing.allocator);
    var accept_args = accept.reader();
    try testing.expectEqual(@as(u32, 7), try accept_args.uint());
    try testing.expectEqualStrings(uri_list_mime, try accept_args.string());
    const set_actions = try rig.fake.waitFor(offer, 4);
    defer set_actions.deinit(testing.allocator);
    var actions_args = set_actions.reader();
    try testing.expectEqual(copy, try actions_args.uint());
    try testing.expectEqual(copy, try actions_args.uint());

    try rig.fake.offerAction(offer, copy);
    try rig.fake.dragMotion(1, 30, 40);
    const motion = try rig.receive();
    try testing.expectEqual(@as(i16, 30), motion.drag_motion.x);
    try testing.expectEqual(@as(i16, 40), motion.drag_motion.y);

    try rig.fake.dragDrop();
    var answer = try rig.answerReceive(offer, uri_list_mime, "file:///tmp/a.txt\r\nfile:///tmp/b%20c.txt\r\n");
    const drop = try rig.receive();
    try answer.finish();
    try testing.expectEqual(common.DropKind.files, drop.drop.kind);
    try testing.expectEqual(@as(i16, 30), drop.drop.x);
    try testing.expectEqual(@as(usize, rig.surface()), drop.drop.window_id);

    const data = try rig.window.takeDrop(testing.allocator);
    defer data.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), data.files.len);
    try testing.expectEqualStrings("/tmp/a.txt", data.files[0]);
    try testing.expectEqualStrings("/tmp/b c.txt", data.files[1]);
    try testing.expectError(error.NoDrop, rig.window.takeDrop(testing.allocator));

    // The transfer ends with finish, then the offer goes.
    (try rig.fake.waitFor(offer, 3)).deinit(testing.allocator);
    (try rig.fake.waitFor(offer, 2)).deinit(testing.allocator);
}

test "a window taking only text gets the text of a file drag" {
    const rig = try Rig.start();
    defer rig.deinit();
    try rig.window.setDropTarget(.{ .text = true });

    const offer: u32 = 0xff000002;
    try rig.enterWith(offer, &.{ uri_list_mime, utf8_mime }, copy, 8);
    const enter = try rig.receive();
    try testing.expectEqual(common.DropKind.text, enter.drag_enter.kind);
    const accept = try rig.fake.waitFor(offer, 0);
    defer accept.deinit(testing.allocator);
    var args = accept.reader();
    _ = try args.uint();
    try testing.expectEqualStrings(utf8_mime, try args.string());

    try rig.fake.offerAction(offer, copy);
    try rig.fake.dragDrop();
    var answer = try rig.answerReceive(offer, utf8_mime, "hello");
    const drop = try rig.receive();
    try answer.finish();
    try testing.expectEqual(common.DropKind.text, drop.drop.kind);
    const data = try rig.window.takeDrop(testing.allocator);
    defer data.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", data.text);
    (try rig.fake.waitFor(offer, 3)).deinit(testing.allocator);
}

test "a window taking nothing refuses silently and a leave destroys the offer" {
    const rig = try Rig.start();
    defer rig.deinit();
    try rig.window.setDropTarget(.{});

    const offer: u32 = 0xff000003;
    try rig.enterWith(offer, &.{ uri_list_mime, utf8_mime }, copy, 9);
    // A pointer enter after the drag enter proves the drag produced nothing: events come in order.
    try rig.fake.pointerEnter(1, rig.surface(), 1, 1);
    try testing.expectEqual(std.meta.Tag(common.Event).mouse_moved, std.meta.activeTag(try rig.receive()));

    const accept = try rig.fake.waitFor(offer, 0);
    defer accept.deinit(testing.allocator);
    var args = accept.reader();
    _ = try args.uint();
    try testing.expectEqualStrings("", try args.string());
    const set_actions = try rig.fake.waitFor(offer, 4);
    defer set_actions.deinit(testing.allocator);
    var actions_args = set_actions.reader();
    try testing.expectEqual(proto.data_device.dnd_action_none, try actions_args.uint());

    try rig.fake.dragLeave();
    try rig.fake.pointerEnter(2, rig.surface(), 1, 1);
    try testing.expectEqual(std.meta.Tag(common.Event).mouse_moved, std.meta.activeTag(try rig.receive()));
    (try rig.fake.waitFor(offer, 2)).deinit(testing.allocator);
}

test "a leave after an accepted enter ends the hover" {
    const rig = try Rig.start();
    defer rig.deinit();
    try rig.window.setDropTarget(.{ .text = true, .files = true });

    const offer: u32 = 0xff000004;
    try rig.enterWith(offer, &.{utf8_mime}, copy, 10);
    try testing.expectEqual(common.DropKind.text, (try rig.receive()).drag_enter.kind);
    try rig.fake.dragLeave();
    try testing.expectEqual(@as(usize, rig.surface()), (try rig.receive()).drag_leave);
    (try rig.fake.waitFor(offer, 2)).deinit(testing.allocator);
    try testing.expect(try rig.fake.sawNone(offer, 3, 20));
}

test "a source that forbids copy is refused, before or during the hover" {
    const rig = try Rig.start();
    defer rig.deinit();
    try rig.window.setDropTarget(.{ .text = true, .files = true });

    // Known before enter: no events at all.
    const first: u32 = 0xff000005;
    try rig.enterWith(first, &.{utf8_mime}, move, 11);
    try rig.fake.pointerEnter(1, rig.surface(), 1, 1);
    try testing.expectEqual(std.meta.Tag(common.Event).mouse_moved, std.meta.activeTag(try rig.receive()));
    const accept = try rig.fake.waitFor(first, 0);
    defer accept.deinit(testing.allocator);
    var args = accept.reader();
    _ = try args.uint();
    try testing.expectEqualStrings("", try args.string());
    try rig.fake.dragLeave();

    // Learned during the hover: the hover ends.
    const second: u32 = 0xff000006;
    try rig.enterWith(second, &.{utf8_mime}, null, 12);
    try testing.expectEqual(common.DropKind.text, (try rig.receive()).drag_enter.kind);
    try rig.fake.offerSourceActions(second, move);
    try testing.expectEqual(@as(usize, rig.surface()), (try rig.receive()).drag_leave);
    const refusal = try rig.fake.waitFor(second, 0);
    defer refusal.deinit(testing.allocator);
    const reaccept = try rig.fake.waitFor(second, 0);
    defer reaccept.deinit(testing.allocator);
    var reaccept_args = reaccept.reader();
    _ = try reaccept_args.uint();
    try testing.expectEqualStrings("", try reaccept_args.string());
}

test "a silent source times out into a refused drop and the next drop works" {
    const rig = try Rig.start();
    defer rig.deinit();
    try rig.window.setDropTarget(.{ .text = true });

    const offer: u32 = 0xff000007;
    try rig.enterWith(offer, &.{utf8_mime}, copy, 13);
    _ = try rig.receive();
    try rig.fake.offerAction(offer, copy);
    try rig.fake.dragDrop();
    // The source never writes (the pipe end sits in the record until deinit closes it): after the idle second the drop is refused, without finish.
    try testing.expectEqual(@as(usize, rig.surface()), (try rig.receive()).drag_leave);
    const receive_request = try rig.fake.waitFor(offer, 1);
    defer receive_request.deinit(testing.allocator);
    if (receive_request.fd) |fd| _ = linux.close(fd);
    (try rig.fake.waitFor(offer, 2)).deinit(testing.allocator);
    try testing.expect(try rig.fake.sawNone(offer, 3, 20));
    try testing.expectError(error.NoDrop, rig.window.takeDrop(testing.allocator));

    const next: u32 = 0xff000008;
    try rig.enterWith(next, &.{utf8_mime}, copy, 14);
    _ = try rig.receive();
    try rig.fake.offerAction(next, copy);
    try rig.fake.dragDrop();
    var answer = try rig.answerReceive(next, utf8_mime, "second");
    try testing.expectEqual(common.DropKind.text, (try rig.receive()).drop.kind);
    try answer.finish();
    const data = try rig.window.takeDrop(testing.allocator);
    defer data.deinit(testing.allocator);
    try testing.expectEqualStrings("second", data.text);
}

test "a uri-list naming no local file is a refused drop" {
    const rig = try Rig.start();
    defer rig.deinit();
    try rig.window.setDropTarget(.{ .files = true });

    const offer: u32 = 0xff000009;
    try rig.enterWith(offer, &.{uri_list_mime}, copy, 15);
    _ = try rig.receive();
    try rig.fake.offerAction(offer, copy);
    try rig.fake.dragDrop();
    var answer = try rig.answerReceive(offer, uri_list_mime, "https://example.com/\r\n");
    try testing.expectEqual(@as(usize, rig.surface()), (try rig.receive()).drag_leave);
    try answer.finish();
    (try rig.fake.waitFor(offer, 2)).deinit(testing.allocator);
    try testing.expect(try rig.fake.sawNone(offer, 3, 20));
}

test "without a settled action the drop is delivered but finish is withheld" {
    const rig = try Rig.start();
    defer rig.deinit();
    try rig.window.setDropTarget(.{ .text = true });

    const offer: u32 = 0xff00000a;
    try rig.enterWith(offer, &.{utf8_mime}, copy, 16);
    _ = try rig.receive();
    try rig.fake.dragDrop();
    var answer = try rig.answerReceive(offer, utf8_mime, "no action");
    try testing.expectEqual(common.DropKind.text, (try rig.receive()).drop.kind);
    try answer.finish();
    (try rig.fake.waitFor(offer, 2)).deinit(testing.allocator);
    try testing.expect(try rig.fake.sawNone(offer, 3, 20));
    const data = try rig.window.takeDrop(testing.allocator);
    defer data.deinit(testing.allocator);
    try testing.expectEqualStrings("no action", data.text);
}

test "a drag starts on the press serial, serves its text and ends finished" {
    const rig = try Rig.start();
    defer rig.deinit();

    try testing.expectError(error.DragNoButton, rig.window.startDrag(.{ .text = "hi" }));
    try rig.fake.pointerEnter(5, rig.surface(), 1, 1);
    _ = try rig.receive();
    try rig.fake.pointerButton(9, button_left, true);
    try testing.expectEqual(std.meta.Tag(common.Event).mouse_pressed, std.meta.activeTag(try rig.receive()));

    try rig.window.startDrag(.{ .text = "hi" });
    try testing.expectError(error.DragInProgress, rig.window.startDrag(.{ .text = "again" }));

    const ids = rig.fake.idsSnapshot();
    const create = try rig.fake.waitFor(ids.data_device_manager, 0);
    defer create.deinit(testing.allocator);
    var create_args = create.reader();
    const source = try create_args.uint();
    for (proto.data_device.text_mime_types) |mime| {
        const offered = try rig.fake.waitFor(source, 0);
        defer offered.deinit(testing.allocator);
        var offered_args = offered.reader();
        try testing.expectEqualStrings(mime, try offered_args.string());
    }
    const set_actions = try rig.fake.waitFor(source, 2);
    defer set_actions.deinit(testing.allocator);
    var actions_args = set_actions.reader();
    try testing.expectEqual(copy, try actions_args.uint());
    const start_drag = try rig.fake.waitFor(ids.data_device, 0);
    defer start_drag.deinit(testing.allocator);
    var start_args = start_drag.reader();
    try testing.expectEqual(source, try start_args.uint());
    try testing.expectEqual(rig.surface(), try start_args.uint());
    try testing.expectEqual(@as(u32, 0), try start_args.uint());
    try testing.expectEqual(@as(u32, 9), try start_args.uint());

    var pipe: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })));
    defer _ = linux.close(pipe[0]);
    try rig.fake.sourceTarget(source, proto.data_device.mime_text_plain);
    try rig.fake.sourceSend(source, proto.data_device.mime_text_plain, pipe[1]);
    _ = linux.close(pipe[1]);
    try rig.fake.sourceDropPerformed(source);
    try rig.fake.sourceFinished(source);
    const finished = try rig.receive();
    try testing.expect(finished.drag_finished.accepted);
    try testing.expectEqual(@as(usize, rig.surface()), finished.drag_finished.window_id);
    (try rig.fake.waitFor(source, 1)).deinit(testing.allocator);

    // The send task wrote the text into our pipe.
    var received: [16]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const rc = linux.read(pipe[0], received[total..].ptr, received.len - total);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        if (rc == 0) break;
        total += rc;
    }
    try testing.expectEqualStrings("hi", received[0..total]);

    // The release ends the press; a drag now has nothing to hang on.
    try rig.fake.pointerButton(10, button_left, false);
    _ = try rig.receive();
    try testing.expectError(error.DragNoButton, rig.window.startDrag(.{ .text = "late" }));
}

test "a file drag offers the uri-list first and a cancelled drag finishes unaccepted" {
    const rig = try Rig.start();
    defer rig.deinit();
    try rig.fake.pointerEnter(5, rig.surface(), 1, 1);
    _ = try rig.receive();
    try rig.fake.pointerButton(21, button_left, true);
    _ = try rig.receive();

    try rig.window.startDrag(.{ .files = &.{ "/a", "/b c" } });
    const ids = rig.fake.idsSnapshot();
    const create = try rig.fake.waitFor(ids.data_device_manager, 0);
    defer create.deinit(testing.allocator);
    var create_args = create.reader();
    const source = try create_args.uint();
    const first = try rig.fake.waitFor(source, 0);
    defer first.deinit(testing.allocator);
    var first_args = first.reader();
    try testing.expectEqualStrings(uri_list_mime, try first_args.string());

    var pipe: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })));
    defer _ = linux.close(pipe[0]);
    try rig.fake.sourceSend(source, uri_list_mime, pipe[1]);
    _ = linux.close(pipe[1]);
    try rig.fake.sourceCancelled(source);
    const finished = try rig.receive();
    try testing.expect(!finished.drag_finished.accepted);
    (try rig.fake.waitFor(source, 1)).deinit(testing.allocator);

    var received: [64]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const rc = linux.read(pipe[0], received[total..].ptr, received.len - total);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        if (rc == 0) break;
        total += rc;
    }
    try testing.expectEqualStrings("file:///a\r\nfile:///b%20c\r\n", received[0..total]);

    // Ended, so a new drag may start on the same press.
    try rig.window.startDrag(.{ .text = "next" });
}

test "a drop on a window that refuses destroys the offer without a receive" {
    const rig = try Rig.start();
    defer rig.deinit();
    try rig.window.setDropTarget(.{ .files = true });

    const offer: u32 = 0xff00000b;
    try rig.enterWith(offer, &.{utf8_mime}, copy, 17);
    try rig.fake.dragDrop();
    try rig.fake.pointerEnter(1, rig.surface(), 1, 1);
    try testing.expectEqual(std.meta.Tag(common.Event).mouse_moved, std.meta.activeTag(try rig.receive()));
    (try rig.fake.waitFor(offer, 2)).deinit(testing.allocator);
    try testing.expect(try rig.fake.sawNone(offer, 1, 20));
    try testing.expect(try rig.fake.sawNone(offer, 3, 20));
}

test "a drag from the window onto itself goes through both halves in one process" {
    const rig = try Rig.start();
    defer rig.deinit();
    try rig.window.setDropTarget(.{ .text = true });
    try rig.fake.pointerEnter(5, rig.surface(), 1, 1);
    _ = try rig.receive();
    try rig.fake.pointerButton(31, button_left, true);
    _ = try rig.receive();

    try rig.window.startDrag(.{ .text = "self" });
    const ids = rig.fake.idsSnapshot();
    const create = try rig.fake.waitFor(ids.data_device_manager, 0);
    defer create.deinit(testing.allocator);
    var create_args = create.reader();
    const source = try create_args.uint();
    rig.fake.self_source.store(source, .release);

    // The compositor announces our own source's offer over our own window.
    const offer: u32 = 0xff00000c;
    try rig.enterWith(offer, &proto.data_device.text_mime_types, copy, 32);
    try testing.expectEqual(common.DropKind.text, (try rig.receive()).drag_enter.kind);
    try rig.fake.offerAction(offer, copy);
    try rig.fake.dragDrop();
    // Our receive is forwarded to our source as a send; the send task writes, the receive task reads.
    const drop = try rig.receive();
    try testing.expectEqual(common.DropKind.text, drop.drop.kind);
    const data = try rig.window.takeDrop(testing.allocator);
    defer data.deinit(testing.allocator);
    try testing.expectEqualStrings("self", data.text);
    // Our finish reaches our source as finished.
    const finished = try rig.receive();
    try testing.expect(finished.drag_finished.accepted);
    (try rig.fake.waitFor(offer, 3)).deinit(testing.allocator);
    (try rig.fake.waitFor(source, 1)).deinit(testing.allocator);
}
