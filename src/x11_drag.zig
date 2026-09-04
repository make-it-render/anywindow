//! XDND state the X11 backend's reader task runs: a drag over one of our windows, a drag of our own, and the side tasks each needs on a connection of its own. `x11.zig` keeps the sockets and the dispatch.

/// The atoms the ranking and the serving compare against; the manager interns them once.
pub const TypeAtoms = struct {
    targets: u32,
    uri_list: u32,
    mime_utf8: u32,
    utf8_string: u32,
    mime_text_plain: u32,
    text: u32,
    string: u32,
};

/// The type a drop will be fetched as, and what it decodes to.
pub const Chosen = struct {
    atom: u32,
    kind: common.DropKind,
};

/// The type to take from what a source offers: `text/uri-list` when the window takes files, else the best text type when it takes text.
pub fn rankTypes(types: []const u32, kinds: common.DropKinds, atoms: TypeAtoms) ?Chosen {
    if (kinds.files and contains(types, atoms.uri_list)) return .{ .atom = atoms.uri_list, .kind = .files };
    if (kinds.text) {
        for ([_]u32{ atoms.mime_utf8, atoms.utf8_string, atoms.mime_text_plain, atoms.text, atoms.string }) |atom| {
            if (contains(types, atom)) return .{ .atom = atom, .kind = .text };
        }
    }
    return null;
}

fn contains(types: []const u32, atom: u32) bool {
    return std.mem.indexOfScalar(u32, types, atom) != null;
}

/// What a selection we own serves: the text, or for a file drag the uri-list, which every text target gets too.
pub const Payload = struct {
    bytes: []u8,
    kind: common.DropKind,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

/// The property type to write when `target` is asked of a payload of `kind`, or null when the payload has nothing for it. TEXT asks for whichever text type we like.
pub fn servedType(kind: common.DropKind, target: u32, atoms: TypeAtoms) ?u32 {
    if (target == atoms.uri_list) return if (kind == .files) atoms.uri_list else null;
    if (target == atoms.text) return atoms.utf8_string;
    if (target == atoms.utf8_string or target == atoms.string or target == atoms.mime_utf8 or target == atoms.mime_text_plain) return target;
    return null;
}

/// The answer to TARGETS for a payload of `kind`: the text types, and the uri-list first for files. TIMESTAMP and MULTIPLE are left out, as SDL leaves them.
pub fn targetList(kind: common.DropKind, atoms: TypeAtoms, buffer: *[7]u32) []const u32 {
    buffer[0] = atoms.targets;
    const offered = offeredTypes(kind, atoms, buffer[1..7]);
    return buffer[0 .. 1 + offered.len];
}

/// The types a drag of `kind` announces, most specific first.
pub fn offeredTypes(kind: common.DropKind, atoms: TypeAtoms, buffer: *[6]u32) []const u32 {
    var count: usize = 0;
    if (kind == .files) {
        buffer[count] = atoms.uri_list;
        count += 1;
    }
    for ([_]u32{ atoms.mime_utf8, atoms.utf8_string, atoms.mime_text_plain, atoms.text, atoms.string }) |atom| {
        buffer[count] = atom;
        count += 1;
    }
    return buffer[0..count];
}

/// A drag from another client (or from ourselves) over one of our windows, from XdndEnter until XdndLeave, a refused drop, or a delivered one. Reader task only.
pub const DropTarget = struct {
    /// The source window: where our answers go.
    source: u32,
    /// The version spoken, at most ours.
    version: u8,
    /// Our window under the drag.
    window: u32,
    /// What the drop will be fetched as; null when the window takes nothing the source offers, in which case every position is refused and no event goes out.
    chosen: ?Chosen,
    /// Our window's root origin, for turning root coordinates into window ones; read on the first position and again after a ConfigureNotify.
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    origin_valid: bool = false,
    /// Whether `drag_enter` went out, so `drag_leave` must end it.
    entered: bool = false,
    /// The last position, in window coordinates: where `drop` reports.
    x: common.X = 0,
    y: common.Y = 0,
    /// XdndDrop arrived and the ConvertSelection is out; the SelectionNotify or a timer settles it.
    awaiting_drop: bool = false,
    /// Ties the timer started at the drop to this wait.
    timer_generation: u32 = 0,
    /// INCR chunks received since the drop, so a slow but live source is not timed out.
    progress: u32 = 0,
    progress_at_timer: u32 = 0,
};

/// Where the pointer is during a drag of ours, in root coordinates, with the event's time.
pub const Position = struct {
    root_x: i16,
    root_y: i16,
    time: u32,
};

/// XDND allows one XdndPosition in flight: the next waits for the XdndStatus, and only the newest waits.
pub const PositionGate = struct {
    outstanding: bool = false,
    pending: ?Position = null,

    /// A new position: returned when it can go out now, held otherwise.
    pub fn offer(self: *@This(), position: Position) ?Position {
        if (self.outstanding) {
            self.pending = position;
            return null;
        }
        self.outstanding = true;
        return position;
    }

    /// The status came: the held position, if any, goes out now.
    pub fn statusArrived(self: *@This()) ?Position {
        self.outstanding = false;
        const pending = self.pending orelse return null;
        self.pending = null;
        self.outstanding = true;
        return pending;
    }

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }
};

/// A drag this process started, from `startDrag` until `drag_finished`. Reader task only, once the reader took it from the start message.
pub const DragSource = struct {
    /// Our window: the selection owner, the grab window, and where targets answer.
    window: u32,
    kind: common.DropKind,
    types: [6]u32,
    type_count: u8,
    /// The task holding the pointer grab and forwarding pointer events to `window`.
    grab: ?*PointerGrab,
    /// The toplevel under the pointer at the last motion, so the walk down to the XDND-aware window runs once per toplevel entered.
    frame: u32 = 0,
    frame_valid: bool = false,
    /// The XDND-aware window under the pointer, if any, and the version it speaks.
    target: ?Target = null,
    gate: PositionGate = .{},
    /// The last XdndStatus verdict from the current target; null until one came.
    accepted: ?bool = null,
    /// The button release, once it happened, with its time.
    release: ?u32 = null,
    state: State = .dragging,
    /// Ties a timer started for this drag to the wait it belongs to.
    timer_generation: u32 = 0,

    pub const Target = struct {
        window: u32,
        version: u8,
    };

    pub const State = enum { dragging, dropped };

    pub fn offered(self: *const @This()) []const u32 {
        return self.types[0..self.type_count];
    }

    /// The three types XdndEnter carries; the rest sit in XdndTypeList.
    pub fn enterTypes(self: @This()) [3]u32 {
        var first: [3]u32 = .{ 0, 0, 0 };
        for (first[0..@min(3, self.type_count)], self.types[0..@min(3, self.type_count)]) |*slot, atom| slot.* = atom;
        return first;
    }
};

/// What a MIR_DRAG_CONTROL ClientMessage to one of our windows says, in its first long; the second is a generation where one applies.
pub const Control = enum(u32) {
    /// A `Timer` ran out.
    timeout = 0,
    /// The `PointerGrab` task could not take the pointer.
    grab_failed = 1,
    /// `startDrag` set a drag up for the reader task to take.
    started = 2,
    _,
};

/// Send a control message to `window` from `conn`: with an empty mask it reaches the client that created the window, our reader task.
pub fn sendControl(io: std.Io, conn: std.Io.net.Stream, window: u32, control_atom: u32, code: Control, generation: u32) !void {
    const event = x11.proto.ClientMessageEvent{
        .window_id = window,
        .message_type = control_atom,
        .data = .{ @intFromEnum(code), generation, 0, 0, 0 },
    };
    try x11.send(io, conn, x11.proto.SendEvent{
        .destination = window,
        .event_mask = 0,
        .event = std.mem.toBytes(event),
    });
}

/// A wait on a silent peer: sleeps, then tells the reader task the time is up, from a connection of its own since the reader task cannot sleep and nothing else may write to the main one. A message whose generation the reader no longer expects is dropped.
pub const Timer = struct {
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    window: u32,
    control_atom: u32,
    generation: u32,
    duration: std.Io.Duration,
    future: ?std.Io.Future(void) = null,
    done: std.atomic.Value(bool) = .init(false),

    pub fn run(task: *Timer, io: std.Io) void {
        defer task.done.store(true, .release);
        task.fire(io) catch |err| switch (err) {
            error.Canceled => {},
            else => log.debug("Drag timer could not report: {any}", .{err}),
        };
    }

    fn fire(task: *Timer, io: std.Io) !void {
        try io.sleep(task.duration, .awake);
        const conn = try x11.connect(io, task.environ, .{});
        defer conn.close(io);
        const info = try x11.setup(io, task.environ, task.allocator, conn);
        defer info.deinit();
        try sendControl(io, conn, task.window, task.control_atom, .timeout, task.generation);
    }
};

/// The pointer grab of a drag, held on a connection of its own: every MotionNotify and ButtonRelease reaches the source window as its own event, in root coordinates, and the grab ends with the release or when the task is canceled.
// A grab is released only by the client that took it, and the reader task, which ends the drag, must never write to the main connection; canceling this task closes its connection, and the server drops the grab with it.
pub const PointerGrab = struct {
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    /// The source window: the grab window, and where the events go.
    window: u32,
    control_atom: u32,
    future: ?std.Io.Future(void) = null,
    done: std.atomic.Value(bool) = .init(false),

    pub fn run(task: *PointerGrab, io: std.Io) void {
        defer task.done.store(true, .release);
        task.forward(io) catch |err| switch (err) {
            error.Canceled => {},
            else => log.warn("The drag's pointer grab ended with {any}", .{err}),
        };
    }

    fn forward(task: *PointerGrab, io: std.Io) !void {
        const conn = try x11.connect(io, task.environ, .{});
        defer conn.close(io);
        const info = try x11.setup(io, task.environ, task.allocator, conn);
        defer info.deinit();

        // No owner_events and no confinement: every motion is reported against the source window in root coordinates wherever the pointer goes, which is what the target walk wants.
        try x11.send(io, conn, x11.proto.GrabPointer{
            .grab_window = task.window,
            .owner_events = 0,
            .event_mask = @intCast(x11.mask(&[_]x11.proto.EventMask{ .ButtonRelease, .PointerMotion })),
            .pointer_mode = 1,
            .keyboard_mode = 1,
            .confine_to = 0,
            .cursor = 0,
            .timestamp = 0,
        });
        const reply = try x11.receiveReply(io, conn, x11.proto.GrabPointerReply);
        const status: x11.proto.GrabStatus = if (reply) |grabbed| grabbed.status else .not_viewable;
        if (status != .success) {
            log.debug("GrabPointer for the drag answered {t}", .{status});
            try sendControl(io, conn, task.window, task.control_atom, .grab_failed, 0);
            return;
        }

        while (true) {
            const message = try x11.receive(io, conn, .none) orelse continue;
            switch (message) {
                .MotionNotify => |motion| try forwardEvent(io, conn, task.window, motion),
                .ButtonRelease => |release| {
                    try forwardEvent(io, conn, task.window, release);
                    // The grab has done its job; the reader task settles the drop.
                    try x11.send(io, conn, x11.proto.UngrabPointer{});
                    return;
                },
                .ErrorMessage => |failure| {
                    log.debug("X11 error on the drag's grab connection: {any}", .{failure.error_code});
                    return error.RequestFailed;
                },
                else => {},
            }
        }
    }

    fn forwardEvent(io: std.Io, conn: std.Io.net.Stream, window: u32, event: anytype) !void {
        try x11.send(io, conn, x11.proto.SendEvent{
            .destination = window,
            .event_mask = 0,
            .event = std.mem.toBytes(event),
        });
    }
};

const std = @import("std");
const testing = std.testing;
const x11 = @import("x11");
const common = @import("common.zig");

const log = std.log.scoped(.any_x11);

const test_atoms = TypeAtoms{ .targets = 1, .uri_list = 2, .mime_utf8 = 3, .utf8_string = 4, .mime_text_plain = 5, .text = 6, .string = 7 };

test "rankTypes takes files first, then the best text type, and only the kinds the window wants" {
    const both: common.DropKinds = .{ .text = true, .files = true };
    try testing.expectEqual(Chosen{ .atom = 2, .kind = .files }, rankTypes(&.{ 7, 2, 4 }, both, test_atoms).?);
    try testing.expectEqual(Chosen{ .atom = 4, .kind = .text }, rankTypes(&.{ 7, 5, 4 }, both, test_atoms).?);
    try testing.expectEqual(Chosen{ .atom = 7, .kind = .text }, rankTypes(&.{7}, both, test_atoms).?);
    try testing.expectEqual(@as(?Chosen, null), rankTypes(&.{ 2, 7 }, .{}, test_atoms));
    try testing.expectEqual(Chosen{ .atom = 7, .kind = .text }, rankTypes(&.{ 2, 7 }, .{ .text = true }, test_atoms).?);
    try testing.expectEqual(@as(?Chosen, null), rankTypes(&.{ 7, 3 }, .{ .files = true }, test_atoms));
    try testing.expectEqual(@as(?Chosen, null), rankTypes(&.{ 99, 0 }, both, test_atoms));
}

test "servedType answers the text targets for every payload and the uri-list for files only" {
    try testing.expectEqual(@as(?u32, 4), servedType(.text, 6, test_atoms));
    try testing.expectEqual(@as(?u32, 3), servedType(.text, 3, test_atoms));
    try testing.expectEqual(@as(?u32, null), servedType(.text, 2, test_atoms));
    try testing.expectEqual(@as(?u32, 2), servedType(.files, 2, test_atoms));
    try testing.expectEqual(@as(?u32, 7), servedType(.files, 7, test_atoms));
    try testing.expectEqual(@as(?u32, null), servedType(.files, 42, test_atoms));
}

test "targetList and offeredTypes list the uri-list ahead of the text types for files" {
    var buffer: [7]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4, 5, 6, 7 }, targetList(.files, test_atoms, &buffer));
    try testing.expectEqualSlices(u32, &.{ 1, 3, 4, 5, 6, 7 }, targetList(.text, test_atoms, &buffer));
    var offered: [6]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 3, 4, 5, 6, 7 }, offeredTypes(.text, test_atoms, &offered));
}

test "PositionGate lets one position out at a time and keeps only the newest behind it" {
    var gate: PositionGate = .{};
    const first: Position = .{ .root_x = 1, .root_y = 1, .time = 1 };
    const second: Position = .{ .root_x = 2, .root_y = 2, .time = 2 };
    const third: Position = .{ .root_x = 3, .root_y = 3, .time = 3 };
    try testing.expectEqual(first, gate.offer(first).?);
    try testing.expectEqual(@as(?Position, null), gate.offer(second));
    try testing.expectEqual(@as(?Position, null), gate.offer(third));
    try testing.expectEqual(third, gate.statusArrived().?);
    try testing.expect(gate.outstanding);
    try testing.expectEqual(@as(?Position, null), gate.statusArrived());
    try testing.expect(!gate.outstanding);
    gate.reset();
    try testing.expectEqual(first, gate.offer(first).?);
}

test "DragSource hands XdndEnter the first three types" {
    var source: DragSource = .{ .window = 1, .kind = .files, .types = .{ 2, 3, 4, 5, 6, 7 }, .type_count = 6, .grab = null };
    try testing.expectEqual([3]u32{ 2, 3, 4 }, source.enterTypes());
    source.type_count = 2;
    try testing.expectEqual([3]u32{ 2, 3, 0 }, source.enterTypes());
    try testing.expectEqual(@as(usize, 2), source.offered().len);
}

// The tasks need a live server; take their addresses so the bodies are analyzed.
test "task entry points compile" {
    _ = &Timer.run;
    _ = &PointerGrab.run;
    _ = &sendControl;
}
