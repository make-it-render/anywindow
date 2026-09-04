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
    try verifyKeys(io, &wm, &window);

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

    // Last: these run the reader on a task, and canceling that mid-message would
    // confuse the synchronous pumps above.
    try verifyClipboard(io, environ, allocator, &wm, &window);
    try verifyDragAndDrop(io, environ, allocator, &wm, &window);

    std.debug.print("verify: ok\n", .{});
}

/// Drag and drop on X11, both roles. As a target, against a bare XDND peer on
/// its own connection: a file list through the three types XdndEnter carries,
/// five types through XdndTypeList, a text-only source, a leave, a source that
/// never answers the ConvertSelection (refused within about a second, and the
/// next drop works), and a window that takes nothing (refused, no event). As a
/// source, against a GTK 3 window (the embedded `verify_drop_target.py`): text,
/// a file list, and a release over the root; then a self drop into a second
/// window of our own. The pointer is not needed: XDND is ClientMessage traffic,
/// and the rig injects the source's motion and release at its own window
/// through the server, as `verifyKeys` does for keys. The reader runs on a task
/// meanwhile and logs every event.
fn verifyDragAndDrop(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator, wm: *win.WindowManager, window: *win.Window) !void {
    const backend = switch (wm.*) {
        .x11 => |*x11_backend| x11_backend,
        .wayland => {
            std.debug.print("drag and drop: not driven on Wayland (no input injection protocol); see the plan's checklist\n", .{});
            return;
        },
    };
    const window_id = window.x11.window_id;

    var events = EventLog{ .allocator = allocator };
    defer events.deinit();
    var reader = try io.concurrent(dragReaderLoop, .{ io, wm, &events });
    defer reader.cancel(io);

    try window.setDropTarget(.{ .text = true, .files = true });
    var peer = try Peer.init(io, environ, allocator);
    defer peer.deinit(io);
    const centre = try peer.centreOf(io, window_id);
    std.debug.print("drag: our window's centre in root coordinates: {d}, {d}\n", .{ centre.x, centre.y });

    // 1. A file list, the uri-list among the three types the enter carries.
    {
        const dropped = try dropFromPeer(io, allocator, &peer, &events, window, centre, .{
            .types = &.{ peer.atoms.uri_list, peer.atoms.mime_utf8, peer.atoms.utf8_string },
            .answer_target = peer.atoms.uri_list,
            .answer = "file:///tmp/a.txt\r\nfile:///tmp/b%20c.txt\r\nhttps://example.com/\r\n",
        });
        defer dropped.deinit(allocator);
        try expectFiles(dropped, &.{ "/tmp/a.txt", "/tmp/b c.txt" });
        std.debug.print("drag: files from a bare peer: ok\n", .{});
    }

    // 2. Five types, the uri-list beyond the third so only XdndTypeList finds it.
    {
        const dropped = try dropFromPeer(io, allocator, &peer, &events, window, centre, .{
            .types = &.{ peer.atoms.string, peer.atoms.text, peer.atoms.utf8_string, peer.atoms.uri_list, peer.atoms.mime_utf8 },
            .answer_target = peer.atoms.uri_list,
            .answer = "file:///home/x/one\r\n",
        });
        defer dropped.deinit(allocator);
        try expectFiles(dropped, &.{"/home/x/one"});
        std.debug.print("drag: files through XdndTypeList: ok\n", .{});
    }

    // 3. A text-only source: the best text type is asked for.
    {
        const dropped = try dropFromPeer(io, allocator, &peer, &events, window, centre, .{
            .types = &.{ peer.atoms.string, peer.atoms.text, peer.atoms.utf8_string },
            .answer_target = peer.atoms.utf8_string,
            .answer = "hello from the peer",
        });
        defer dropped.deinit(allocator);
        if (dropped != .text or !std.mem.eql(u8, dropped.text, "hello from the peer")) return error.DropTextMismatch;
        std.debug.print("drag: text from a bare peer: ok\n", .{});
    }

    // 4. Enter, position, leave: drag_enter then drag_leave, nothing else.
    {
        try peer.enter(io, window_id, &.{ peer.atoms.utf8_string, 0, 0 });
        try peer.position(io, window_id, centre);
        const status = try peer.awaitStatus(io, window_id);
        if (!status.accept) return error.DropRefused;
        _ = try events.expect(io, .drag_enter, "leave test");
        try peer.leave(io, window_id);
        _ = try events.expect(io, .drag_leave, "leave test");
        try events.expectNone(io, "after a leave");
        std.debug.print("drag: leave: ok\n", .{});
    }

    // 5. A source that never answers the ConvertSelection: refused within about
    // a second, drag_leave, and the next drop works.
    {
        try peer.enter(io, window_id, &.{ peer.atoms.utf8_string, 0, 0 });
        try peer.position(io, window_id, centre);
        _ = try peer.awaitStatus(io, window_id);
        _ = try events.expect(io, .drag_enter, "silent source");
        try peer.drop(io, window_id);
        const started = std.Io.Clock.now(.awake, io);
        const finished = try peer.awaitFinished(io, window_id, 3000);
        if (finished.accepted) return error.SilentSourceAccepted;
        const waited_ms = @divTrunc(started.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds, std.time.ns_per_ms);
        _ = try events.expect(io, .drag_leave, "silent source");
        std.debug.print("drag: silent source refused after {d} ms: ok\n", .{waited_ms});
        peer.drain(io);
        const dropped = try dropFromPeer(io, allocator, &peer, &events, window, centre, .{
            .types = &.{ peer.atoms.utf8_string, 0, 0 },
            .answer_target = peer.atoms.utf8_string,
            .answer = "after the silence",
        });
        defer dropped.deinit(allocator);
        if (dropped != .text or !std.mem.eql(u8, dropped.text, "after the silence")) return error.DropTextMismatch;
        std.debug.print("drag: the drop after a silent source: ok\n", .{});
    }

    // 6. A window that takes nothing: XdndStatus refuses and no event goes out.
    {
        try window.setDropTarget(.{});
        try peer.enter(io, window_id, &.{ peer.atoms.uri_list, peer.atoms.utf8_string, 0 });
        try peer.position(io, window_id, centre);
        const status = try peer.awaitStatus(io, window_id);
        if (status.accept) return error.RefusalExpected;
        try peer.leave(io, window_id);
        try events.expectNone(io, "a window taking nothing");
        try window.setDropTarget(.{ .text = true, .files = true });
        std.debug.print("drag: a window taking nothing refuses: ok\n", .{});
    }

    // 7. Source against a GTK 3 window: text, a file list, then a release over the root.
    try verifyDragToGtk(io, allocator, backend, &peer, &events, window);

    // 8. Self drop: our source into a second window of ours, both halves in one process.
    {
        var second = try wm.createWindow(.{ .title = "anywindow-verify-target", .width = 200, .height = 200, .x = 400, .y = 10 });
        defer second.deinit();
        try second.show();
        try second.setDropTarget(.{ .text = true });
        try io.sleep(std.Io.Duration.fromMilliseconds(300), .awake);
        peer.drain(io);
        const second_centre = try peer.centreOf(io, second.x11.window_id);
        try window.startDrag(.{ .text = "self drop" });
        try injectMotion(io, backend, window, second_centre);
        try io.sleep(std.Io.Duration.fromMilliseconds(50), .awake);
        try injectMotion(io, backend, window, .{ .x = second_centre.x + 1, .y = second_centre.y });
        _ = try events.expect(io, .drag_enter, "self drop");
        _ = try events.expect(io, .drag_motion, "self drop");
        try injectRelease(io, backend, window, second_centre);
        _ = try events.expect(io, .drop, "self drop");
        const dropped = try second.takeDrop(allocator);
        defer dropped.deinit(allocator);
        if (dropped != .text or !std.mem.eql(u8, dropped.text, "self drop")) return error.DropTextMismatch;
        const finished = try events.expect(io, .drag_finished, "self drop");
        if (!finished.drag_finished.accepted) return error.SelfDropRefused;
        std.debug.print("drag: self drop into a second window: ok\n", .{});
    }
}

/// The source half against GTK: the peer script opens a window that takes text
/// and URIs and prints each drop; the rig drags into it with injected motion.
fn verifyDragToGtk(io: std.Io, allocator: std.mem.Allocator, backend: *win.x11.WindowManager, peer: *Peer, events: *EventLog, window: *win.Window) !void {
    // WAYLAND_DISPLAY is unset for an X11 run, but libwayland falls back to wayland-0 on its
    // own, so GTK is told which backend to use.
    var child = std.process.spawn(io, .{
        .argv = &.{ "env", "GDK_BACKEND=x11", "python3", "-c", gtk_peer_script },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print("drag: GTK peer could not start ({any}); source checks against GTK skipped\n", .{err});
        return;
    };
    var child_running = true;
    defer if (child_running) child.kill(io);
    var lines = LineLog{ .allocator = allocator };
    defer lines.deinit();
    var output = try io.concurrent(peerOutputLoop, .{ io, child.stdout.?, &lines });
    defer output.cancel(io);

    const ready = lines.next(io, 5000) orelse {
        std.debug.print("drag: GTK peer never said ready; source checks against GTK skipped\n", .{});
        return;
    };
    defer allocator.free(ready);
    if (!std.mem.startsWith(u8, ready, "ready ")) return error.GtkPeerUnexpectedOutput;
    const gtk_window = try std.fmt.parseInt(u32, ready["ready ".len..], 10);
    // The window manager maps it a moment after GTK asks.
    try io.sleep(std.Io.Duration.fromMilliseconds(500), .awake);
    peer.drain(io);
    const centre = try peer.centreOf(io, gtk_window);
    std.debug.print("drag: GTK window 0x{x} centred at {d}, {d}\n", .{ gtk_window, centre.x, centre.y });

    // Text.
    try window.startDrag(.{ .text = "text from mir" });
    try dragTo(io, backend, window, centre);
    try expectLine(io, allocator, &lines, "text: text from mir");
    var finished = try events.expect(io, .drag_finished, "text to GTK");
    if (!finished.drag_finished.accepted) return error.GtkDragRefused;
    std.debug.print("drag: text into GTK: ok\n", .{});

    // Files.
    try window.startDrag(.{ .files = &.{ "/tmp/mir one.txt", "/tmp/two" } });
    try dragTo(io, backend, window, centre);
    try expectLine(io, allocator, &lines, "files: /tmp/mir one.txt /tmp/two");
    finished = try events.expect(io, .drag_finished, "files to GTK");
    if (!finished.drag_finished.accepted) return error.GtkDragRefused;
    std.debug.print("drag: files into GTK: ok\n", .{});

    // Escape over GTK: the drag ends refused, GTK prints nothing, and the next drag works.
    if (findKeysym(backend, keysym_escape, 0)) |escape| {
        try window.startDrag(.{ .text = "cancelled" });
        try injectMotion(io, backend, window, centre);
        try io.sleep(std.Io.Duration.fromMilliseconds(100), .awake);
        try injectKey(io, backend, window, escape);
        finished = try events.expect(io, .drag_finished, "escape over GTK");
        if (finished.drag_finished.accepted) return error.EscapeAccepted;
        if (lines.next(io, 300)) |line| {
            defer allocator.free(line);
            std.debug.print("drag: GTK printed \"{s}\" after an escape\n", .{line});
            return error.GtkPeerMismatch;
        }
        std.debug.print("drag: escape over GTK: ok\n", .{});
    } else {
        std.debug.print("drag: no Escape in the keymap, cancel skipped\n", .{});
    }

    // A release over the root, where nothing takes drops.
    try window.startDrag(.{ .text = "nowhere" });
    try dragTo(io, backend, window, .{ .x = 5, .y = 600 });
    finished = try events.expect(io, .drag_finished, "release over the root");
    if (finished.drag_finished.accepted) return error.RootDropAccepted;
    std.debug.print("drag: release over the root refused: ok\n", .{});

    child.stdin.?.close(io);
    child.stdin = null;
    _ = try child.wait(io);
    child_running = false;
}

/// Move the (synthetic) pointer to `point` in two steps and release the button there.
fn dragTo(io: std.Io, backend: *win.x11.WindowManager, window: *win.Window, point: Point) !void {
    try injectMotion(io, backend, window, .{ .x = point.x - 1, .y = point.y });
    try io.sleep(std.Io.Duration.fromMilliseconds(50), .awake);
    try injectMotion(io, backend, window, point);
    try io.sleep(std.Io.Duration.fromMilliseconds(100), .awake);
    try injectRelease(io, backend, window, point);
}

/// A MotionNotify at our window in root coordinates, as the grab task would forward.
fn injectMotion(io: std.Io, backend: *win.x11.WindowManager, window: *win.Window, point: Point) !void {
    const event = x11.proto.MotionNotify{
        .detail = .Normal,
        .sequence_number = 0,
        .time = 0,
        .root_window = window.x11.root,
        .event_window = window.x11.window_id,
        .child_window = 0,
        .root_x = point.x,
        .root_y = point.y,
        .event_x = 0,
        .event_y = 0,
        .state = @intFromEnum(x11.proto.KeyButMask.Button1),
        .same_screen = 1,
        .pad = .{0},
    };
    try x11.send(io, backend.conn, x11.proto.SendEvent{ .destination = window.x11.window_id, .event_mask = 0, .event = std.mem.toBytes(event) });
}

/// A KeyPress at our window, as `expectTyped` sends them.
fn injectKey(io: std.Io, backend: *win.x11.WindowManager, window: *win.Window, press: Press) !void {
    const event = x11.proto.KeyPress{
        .keycode = press.keycode,
        .sequence_number = 0,
        .time = 0,
        .root_window = window.x11.root,
        .event_window = window.x11.window_id,
        .child_window = 0,
        .root_x = 0,
        .root_y = 0,
        .event_x = 0,
        .event_y = 0,
        .state = press.state,
        .same_screen = 1,
        .pad = .{0},
    };
    try x11.send(io, backend.conn, x11.proto.SendEvent{ .destination = window.x11.window_id, .event_mask = 0, .event = std.mem.toBytes(event) });
}

fn injectRelease(io: std.Io, backend: *win.x11.WindowManager, window: *win.Window, point: Point) !void {
    const event = x11.proto.ButtonRelease{
        .keycode = 1,
        .sequence_number = 0,
        .time = 0,
        .root_window = window.x11.root,
        .event_window = window.x11.window_id,
        .child_window = 0,
        .root_x = point.x,
        .root_y = point.y,
        .event_x = 0,
        .event_y = 0,
        .state = @intFromEnum(x11.proto.KeyButMask.Button1),
        .same_screen = 1,
        .pad = .{0},
    };
    try x11.send(io, backend.conn, x11.proto.SendEvent{ .destination = window.x11.window_id, .event_mask = 0, .event = std.mem.toBytes(event) });
}

const gtk_peer_script = @embedFile("verify_drop_target.py");

const Point = struct { x: i16, y: i16 };

const PeerDrop = struct {
    /// Up to three types in the enter; more go through XdndTypeList.
    types: []const u32,
    answer_target: u32,
    answer: []const u8,
};

/// One drop from the bare peer: enter (through the type list when there are
/// more than three types), one position, the status, the drop, the peer's
/// answer to our ConvertSelection, XdndFinished, and the payload taken here.
fn dropFromPeer(io: std.Io, allocator: std.mem.Allocator, peer: *Peer, events: *EventLog, window: *win.Window, centre: Point, drop: PeerDrop) !win.DropData {
    const window_id = window.x11.window_id;
    if (drop.types.len > 3) {
        try peer.setTypeList(io, drop.types);
        try peer.enterWithList(io, window_id, drop.types[0..3]);
    } else {
        var three: [3]u32 = .{ 0, 0, 0 };
        @memcpy(three[0..drop.types.len], drop.types);
        try peer.enter(io, window_id, &three);
    }
    try peer.position(io, window_id, centre);
    const status = try peer.awaitStatus(io, window_id);
    if (!status.accept) return error.DropRefused;
    const entered = try events.expect(io, .drag_enter, "peer drop");
    // The root centre of a 320x240 window is its (160, 120) once the origin is taken off.
    if (entered.drag_enter.x != 160 or entered.drag_enter.y != 120) {
        std.debug.print("drag: drag_enter at {d}, {d}, expected 160, 120\n", .{ entered.drag_enter.x, entered.drag_enter.y });
        return error.DropPositionWrong;
    }
    try peer.position(io, window_id, .{ .x = centre.x + 2, .y = centre.y + 3 });
    _ = try peer.awaitStatus(io, window_id);
    const moved = try events.expect(io, .drag_motion, "peer drop");
    if (moved.drag_motion.x != entered.drag_enter.x + 2 or moved.drag_motion.y != entered.drag_enter.y + 3) return error.DropPositionWrong;
    try peer.drop(io, window_id);
    const request = try peer.awaitSelectionRequest(io);
    if (request.target != drop.answer_target) {
        std.debug.print("drag: our target asked for atom {d}, expected {d}\n", .{ request.target, drop.answer_target });
        return error.DropTargetMismatch;
    }
    try peer.answer(io, request, drop.answer);
    const finished = try peer.awaitFinished(io, window_id, 3000);
    if (!finished.accepted) return error.DropNotAccepted;
    const dropped = try events.expect(io, .drop, "peer drop");
    if (dropped.drop.x != moved.drag_motion.x or dropped.drop.y != moved.drag_motion.y) return error.DropPositionWrong;
    return window.takeDrop(allocator);
}

fn expectFiles(dropped: win.DropData, expected: []const []const u8) !void {
    if (dropped != .files or dropped.files.len != expected.len) {
        std.debug.print("drag: expected {d} files, got {s} with {d} entries\n", .{ expected.len, @tagName(dropped), if (dropped == .files) dropped.files.len else 0 });
        return error.DropFilesMismatch;
    }
    for (dropped.files, expected) |path, want| {
        if (!std.mem.eql(u8, path, want)) {
            std.debug.print("drag: got path \"{s}\", expected \"{s}\"\n", .{ path, want });
            return error.DropFilesMismatch;
        }
    }
}

/// A bare XDND source on a connection of its own: a 1x1 window, the atoms, and
/// the messages a source sends and expects.
const Peer = struct {
    conn: std.Io.net.Stream,
    info: x11.Setup,
    window: u32,
    root: u32,
    atoms: Atoms,

    const Atoms = struct {
        atom: u32,
        xdnd_selection: u32,
        enter: u32,
        position: u32,
        status: u32,
        leave: u32,
        drop: u32,
        finished: u32,
        type_list: u32,
        action_copy: u32,
        uri_list: u32,
        mime_utf8: u32,
        utf8_string: u32,
        string: u32,
        text: u32,
    };

    fn init(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator) !Peer {
        const conn = try x11.connect(io, environ, .{});
        errdefer conn.close(io);
        const info = try x11.setup(io, environ, allocator, conn);
        errdefer info.deinit();
        var xid = x11.XID.init(info.resource_id_base, info.resource_id_mask);
        const peer_window = try xid.genID();
        const values = x11.proto.WindowValue{ .BackgroundPixel = 0 };
        try x11.sendWithValues(io, conn, x11.proto.CreateWindow{
            .window_id = peer_window,
            .parent_id = info.screens[0].root,
            .visual_id = info.screens[0].root_visual,
            .depth = info.screens[0].root_depth,
            .x = 0,
            .y = 0,
            .width = 1,
            .height = 1,
            .border_width = 0,
            .window_class = .InputOutput,
            .value_mask = x11.maskFromValues(x11.proto.WindowMask, values),
        }, values);
        const atoms = Atoms{
            .atom = try x11.internAtom(io, conn, "ATOM"),
            .xdnd_selection = try x11.internAtom(io, conn, x11.xdnd.Atom.selection),
            .enter = try x11.internAtom(io, conn, x11.xdnd.Atom.enter),
            .position = try x11.internAtom(io, conn, x11.xdnd.Atom.position),
            .status = try x11.internAtom(io, conn, x11.xdnd.Atom.status),
            .leave = try x11.internAtom(io, conn, x11.xdnd.Atom.leave),
            .drop = try x11.internAtom(io, conn, x11.xdnd.Atom.drop),
            .finished = try x11.internAtom(io, conn, x11.xdnd.Atom.finished),
            .type_list = try x11.internAtom(io, conn, x11.xdnd.Atom.type_list),
            .action_copy = try x11.internAtom(io, conn, x11.xdnd.Atom.action_copy),
            .uri_list = try x11.internAtom(io, conn, "text/uri-list"),
            .mime_utf8 = try x11.internAtom(io, conn, "text/plain;charset=utf-8"),
            .utf8_string = try x11.internAtom(io, conn, "UTF8_STRING"),
            .string = try x11.internAtom(io, conn, "STRING"),
            .text = try x11.internAtom(io, conn, "TEXT"),
        };
        try x11.send(io, conn, x11.proto.SetSelectionOwner{ .owner = peer_window, .selection = atoms.xdnd_selection });
        return .{ .conn = conn, .info = info, .window = peer_window, .root = info.screens[0].root, .atoms = atoms };
    }

    fn deinit(self: *Peer, io: std.Io) void {
        self.info.deinit();
        self.conn.close(io);
    }

    /// The centre of `window` in root coordinates, read with TranslateCoordinates
    /// and GetGeometry; nothing else may be pending on the connection.
    fn centreOf(self: *Peer, io: std.Io, window: u32) !Point {
        try x11.send(io, self.conn, x11.proto.GetGeometry{ .drawable = window });
        const geometry = (try x11.receiveReply(io, self.conn, x11.proto.GetGeometryReply)) orelse return error.PeerRequestFailed;
        try x11.send(io, self.conn, x11.proto.TranslateCoordinates{ .src_window = window, .dst_window = self.root, .src_x = 0, .src_y = 0 });
        const origin = (try x11.receiveReply(io, self.conn, x11.proto.TranslateCoordinatesReply)) orelse return error.PeerRequestFailed;
        return .{
            .x = @intCast(@as(i32, origin.dst_x) + @divTrunc(geometry.width, 2)),
            .y = @intCast(@as(i32, origin.dst_y) + @divTrunc(geometry.height, 2)),
        };
    }

    fn sendMessage(self: *Peer, io: std.Io, destination: u32, message_type: u32, data: [5]u32) !void {
        const event = x11.proto.ClientMessageEvent{ .window_id = destination, .message_type = message_type, .data = data };
        try x11.send(io, self.conn, x11.proto.SendEvent{ .destination = destination, .event_mask = 0, .event = std.mem.toBytes(event) });
    }

    fn enter(self: *Peer, io: std.Io, target: u32, types: *const [3]u32) !void {
        try self.sendMessage(io, target, self.atoms.enter, (x11.xdnd.Enter{ .source = self.window, .version = 5, .more_types = false, .types = types.* }).pack());
    }

    fn enterWithList(self: *Peer, io: std.Io, target: u32, first: []const u32) !void {
        var three: [3]u32 = .{ 0, 0, 0 };
        @memcpy(three[0..first.len], first);
        try self.sendMessage(io, target, self.atoms.enter, (x11.xdnd.Enter{ .source = self.window, .version = 5, .more_types = true, .types = three }).pack());
    }

    fn setTypeList(self: *Peer, io: std.Io, types: []const u32) !void {
        try x11.sendWithBytes(io, self.conn, x11.proto.ChangeProperty{
            .window_id = self.window,
            .property = self.atoms.type_list,
            .property_type = self.atoms.atom,
            .format = 32,
            .length_of_data = @intCast(types.len),
        }, std.mem.sliceAsBytes(types));
    }

    fn position(self: *Peer, io: std.Io, target: u32, point: Point) !void {
        try self.sendMessage(io, target, self.atoms.position, (x11.xdnd.Position{ .source = self.window, .root_x = point.x, .root_y = point.y, .time = 0, .action = self.atoms.action_copy }).pack());
    }

    fn leave(self: *Peer, io: std.Io, target: u32) !void {
        try self.sendMessage(io, target, self.atoms.leave, (x11.xdnd.Leave{ .source = self.window }).pack());
    }

    fn drop(self: *Peer, io: std.Io, target: u32) !void {
        try self.sendMessage(io, target, self.atoms.drop, (x11.xdnd.Drop{ .source = self.window, .time = 0 }).pack());
    }

    /// Write the answer to a SelectionRequest and notify the requestor.
    fn answer(self: *Peer, io: std.Io, request: x11.proto.SelectionRequest, bytes: []const u8) !void {
        const property = if (request.property != 0) request.property else request.target;
        try x11.sendWithBytes(io, self.conn, x11.proto.ChangeProperty{
            .window_id = request.requestor,
            .property = property,
            .property_type = request.target,
            .format = 8,
            .length_of_data = @intCast(bytes.len),
        }, bytes);
        const notify = x11.proto.SelectionNotify{
            .time = request.time,
            .requestor = request.requestor,
            .selection = request.selection,
            .target = request.target,
            .property = property,
        };
        try x11.send(io, self.conn, x11.proto.SendEvent{ .destination = request.requestor, .event_mask = 0, .event = std.mem.toBytes(notify) });
    }

    fn awaitStatus(self: *Peer, io: std.Io, target: u32) !x11.xdnd.Status {
        const status = x11.xdnd.Status.unpack(try self.awaitClientMessage(io, self.atoms.status, 3000));
        if (status.target != target) return error.StatusFromWrongWindow;
        return status;
    }

    fn awaitFinished(self: *Peer, io: std.Io, target: u32, timeout_ms: u32) !x11.xdnd.Finished {
        const finished = x11.xdnd.Finished.unpack(try self.awaitClientMessage(io, self.atoms.finished, timeout_ms));
        if (finished.target != target) return error.FinishedFromWrongWindow;
        return finished;
    }

    /// The next ClientMessage of `message_type`; everything else on the way is dropped.
    fn awaitClientMessage(self: *Peer, io: std.Io, message_type: u32, timeout_ms: u32) ![5]u32 {
        const deadline = deadlineIn(io, timeout_ms);
        while (true) {
            const message = try x11.receive(io, self.conn, .{ .deadline = deadline }) orelse return error.PeerTimeout;
            switch (message) {
                .ClientMessage => |client_message| {
                    if (client_message.data_Type == message_type and client_message.format == 32) return x11.clientMessageData(client_message).u32;
                },
                .Reply => |reply| try skipReply(io, self.conn, reply.extraLength()),
                .ErrorMessage => |failure| std.debug.print("drag: X11 error at the peer: {any}\n", .{failure.error_code}),
                else => {},
            }
        }
    }

    fn awaitSelectionRequest(self: *Peer, io: std.Io) !x11.proto.SelectionRequest {
        const deadline = deadlineIn(io, 3000);
        while (true) {
            const message = try x11.receive(io, self.conn, .{ .deadline = deadline }) orelse return error.PeerTimeout;
            switch (message) {
                .SelectionRequest => |request| return request,
                .Reply => |reply| try skipReply(io, self.conn, reply.extraLength()),
                else => {},
            }
        }
    }

    /// Read whatever is queued so a naive reply read is safe.
    fn drain(self: *Peer, io: std.Io) void {
        while (true) {
            const message = x11.receive(io, self.conn, .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } }) catch return;
            const received = message orelse return;
            if (received == .Reply) skipReply(io, self.conn, received.Reply.extraLength()) catch return;
        }
    }
};

fn deadlineIn(io: std.Io, milliseconds: u32) std.Io.Clock.Timestamp {
    return std.Io.Clock.now(.awake, io).addDuration(.fromMilliseconds(milliseconds)).withClock(.awake);
}

fn skipReply(io: std.Io, conn: std.Io.net.Stream, count: usize) !void {
    var scratch: [256]u8 = undefined;
    var left = count;
    while (left > 0) {
        const chunk = scratch[0..@min(left, scratch.len)];
        try x11.receiveBytes(io, conn, chunk);
        left -= chunk.len;
    }
}

/// Every event the reader task saw, for the main thread to inspect.
const EventLog = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    events: std.ArrayList(win.Event) = .empty,
    taken: usize = 0,

    fn deinit(self: *EventLog) void {
        self.events.deinit(self.allocator);
    }

    fn push(self: *EventLog, io: std.Io, event: win.Event) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.events.append(self.allocator, event) catch {};
    }

    /// The next drag event, waiting up to `timeout_ms`; other kinds are skipped.
    fn nextDragEvent(self: *EventLog, io: std.Io, timeout_ms: u32) ?win.Event {
        var waited: u32 = 0;
        while (true) {
            {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                while (self.taken < self.events.items.len) {
                    const event = self.events.items[self.taken];
                    self.taken += 1;
                    switch (event) {
                        .drag_enter, .drag_motion, .drag_leave, .drop, .drag_finished => return event,
                        else => {},
                    }
                }
            }
            if (waited >= timeout_ms) return null;
            io.sleep(std.Io.Duration.fromMilliseconds(20), .awake) catch return null;
            waited += 20;
        }
    }

    fn expect(self: *EventLog, io: std.Io, tag: std.meta.Tag(win.Event), what: []const u8) !win.Event {
        const event = self.nextDragEvent(io, 3000) orelse {
            std.debug.print("drag: {s}: no {s} event within 3 s\n", .{ what, @tagName(tag) });
            return error.DragEventMissing;
        };
        if (event != tag) {
            std.debug.print("drag: {s}: got {s}, expected {s}\n", .{ what, @tagName(event), @tagName(tag) });
            return error.DragEventMismatch;
        }
        return event;
    }

    fn expectNone(self: *EventLog, io: std.Io, what: []const u8) !void {
        if (self.nextDragEvent(io, 300)) |event| {
            std.debug.print("drag: {s}: unexpected {s} event\n", .{ what, @tagName(event) });
            return error.DragEventUnexpected;
        }
    }
};

fn dragReaderLoop(io: std.Io, wm: *win.WindowManager, events: *EventLog) void {
    while (true) {
        const event = wm.receiveIo(io) catch return;
        if (event) |received| events.push(io, received);
    }
}

/// Lines a child process printed, for the main thread to wait on.
const LineLog = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    lines: std.ArrayList([]u8) = .empty,

    fn deinit(self: *LineLog) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
    }

    fn push(self: *LineLog, io: std.Io, line: []const u8) void {
        const copy = self.allocator.dupe(u8, line) catch return;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.lines.append(self.allocator, copy) catch self.allocator.free(copy);
    }

    /// The oldest line not yet taken, owned by the caller, waiting up to `timeout_ms`.
    fn next(self: *LineLog, io: std.Io, timeout_ms: u32) ?[]u8 {
        var waited: u32 = 0;
        while (true) {
            {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                if (self.lines.items.len > 0) return self.lines.orderedRemove(0);
            }
            if (waited >= timeout_ms) return null;
            io.sleep(std.Io.Duration.fromMilliseconds(20), .awake) catch return null;
            waited += 20;
        }
    }
};

fn peerOutputLoop(io: std.Io, file: std.Io.File, lines: *LineLog) void {
    var pending: [4096]u8 = undefined;
    var pending_len: usize = 0;
    var chunk: [1024]u8 = undefined;
    while (true) {
        const count = file.readStreaming(io, &.{&chunk}) catch return;
        if (count == 0) return;
        for (chunk[0..count]) |byte| {
            if (byte == '\n') {
                lines.push(io, pending[0..pending_len]);
                pending_len = 0;
            } else if (pending_len < pending.len) {
                pending[pending_len] = byte;
                pending_len += 1;
            }
        }
    }
}

fn expectLine(io: std.Io, allocator: std.mem.Allocator, lines: *LineLog, expected: []const u8) !void {
    const line = lines.next(io, 5000) orelse {
        std.debug.print("drag: GTK printed nothing, expected \"{s}\"\n", .{expected});
        return error.GtkPeerSilent;
    };
    defer allocator.free(line);
    if (!std.mem.eql(u8, line, expected)) {
        std.debug.print("drag: GTK printed \"{s}\", expected \"{s}\"\n", .{ line, expected });
        return error.GtkPeerMismatch;
    }
}

/// The clipboard many ways: our text served to a foreign client (wl-paste or
/// xclip), a self round trip through the server so the serving path runs end
/// to end in one process, a foreign client's text pasted here, a copy made
/// after that foreign claim, (X11) an owner that never answers, which a paste
/// must time out on, then the same three transfers with a text far above one
/// X11 request (INCR both ways), and the primary selection. The reader runs
/// on a task meanwhile, as it does under recvloop: the serving side lives
/// there, the main thread must be free to block in child processes and in
/// the paste itself, and it counts the `clipboard_changed` events: none for
/// our own copies, one per foreign claim.
fn verifyClipboard(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator, wm: *win.WindowManager, window: *win.Window) !void {
    const tools: ClipboardTools = switch (wm.*) {
        .wayland => .{
            .paste = &.{ "wl-paste", "--no-newline" },
            .copy = &.{"wl-copy"},
            .paste_primary = &.{ "wl-paste", "--primary", "--no-newline" },
            .copy_primary = &.{ "wl-copy", "--primary" },
        },
        .x11 => .{
            .paste = &.{ "xclip", "-selection", "clipboard", "-o" },
            .copy = &.{ "xclip", "-selection", "clipboard", "-i" },
            .paste_primary = &.{ "xclip", "-selection", "primary", "-o" },
            .copy_primary = &.{ "xclip", "-selection", "primary", "-i" },
        },
    };

    // A Wayland copy needs an input serial; the compositor hands one over
    // with keyboard focus, which a fresh window normally gets. Give it a moment.
    if (wm.* == .wayland) {
        var polls: u32 = 0;
        while (wm.wayland.input_serial.load(.monotonic) == 0 and polls < 50) : (polls += 1) {
            _ = try pump(io, wm, window);
            try io.sleep(std.Io.Duration.fromMilliseconds(20), .awake);
        }
        if (wm.wayland.input_serial.load(.monotonic) == 0) {
            std.debug.print("clipboard: skipped (the window never got keyboard focus, so there is no input serial)\n", .{});
            return;
        }
    }

    var changes = std.atomic.Value(u32).init(0);
    var reader = try io.concurrent(readerLoop, .{ io, wm, &changes });
    defer reader.cancel(io);

    // Our own copies all come first: on Wayland a copy reuses the last input
    // serial, and once a foreign client has claimed the selection with a
    // newer one the compositor drops ours (step 4 shows it).

    // 1. Served: our text, fetched by a foreign client.
    const ours = try std.fmt.allocPrint(allocator, "mir clipboard {d}", .{nonce(io)});
    defer allocator.free(ours);
    try window.setClipboardText(ours);
    try expectServed(io, allocator, tools.paste, ours, "clipboard");
    try expectChanges(io, &changes, 0, "our own copy");

    // 2. Self, through the server: a paste never short-circuits to our own
    // text, so the reader task serves our own request here.
    const again = try std.fmt.allocPrint(allocator, "mir round trip {d}", .{nonce(io)});
    defer allocator.free(again);
    try window.setClipboardText(again);
    try expectPaste(io, allocator, window, .clipboard, again, "server round trip");
    std.debug.print("clipboard: round trip through the server: ok\n", .{});
    try expectChanges(io, &changes, 0, "our own copy and paste");

    // 3. A text far beyond one X11 request: served to the tool (INCR on
    // X11) and round-tripped through ourselves (INCR both sides on X11).
    // Wayland moves it through a pipe either way.
    const big = try largeText(allocator, nonce(io));
    defer allocator.free(big);
    try window.setClipboardText(big);
    try expectServed(io, allocator, tools.paste, big, "1 MiB clipboard");
    const big_again = try largeText(allocator, nonce(io));
    defer allocator.free(big_again);
    try window.setClipboardText(big_again);
    try expectPaste(io, allocator, window, .clipboard, big_again, "1 MiB server round trip");
    std.debug.print("clipboard: 1 MiB round trip through the server: ok\n", .{});
    try expectChanges(io, &changes, 0, "our own 1 MiB copies");

    // 4. The primary selection, served and round-tripped the same way, with
    // no clipboard_changed for either.
    const primary = try std.fmt.allocPrint(allocator, "mir primary {d}", .{nonce(io)});
    defer allocator.free(primary);
    const primary_supported = if (window.setPrimaryText(primary)) true else |err| switch (err) {
        error.ClipboardUnsupported => false,
        else => return err,
    };
    const primary_again = try std.fmt.allocPrint(allocator, "mir primary round trip {d}", .{nonce(io)});
    defer allocator.free(primary_again);
    if (primary_supported) {
        try expectServed(io, allocator, tools.paste_primary, primary, "primary");
        try window.setPrimaryText(primary_again);
        try expectPaste(io, allocator, window, .primary, primary_again, "primary server round trip");
        std.debug.print("primary: round trip through the server: ok\n", .{});
        try expectChanges(io, &changes, 0, "our own primary copies");
    } else {
        std.debug.print("primary: unsupported here, skipped\n", .{});
    }

    // 5. Foreign: a tool owns the selection, we paste it — and the reader
    // must have seen exactly one clipboard_changed for the claim.
    const theirs = try std.fmt.allocPrint(allocator, "from {s} {d}", .{ tools.copy[0], nonce(io) });
    defer allocator.free(theirs);
    allocator.free(try runTool(io, allocator, tools.copy, theirs, false));
    try expectPaste(io, allocator, window, .clipboard, theirs, "foreign owner");
    std.debug.print("clipboard: pasted from {s}: ok\n", .{tools.copy[0]});
    try expectChanges(io, &changes, 1, "a foreign copy");

    // 6. A copy with no new input since the foreign claim. X11 claims with
    // CurrentTime, so it must take. Wayland reuses the last input serial,
    // which is now older than the selection's; whether the compositor still
    // accepts it is its call, so that is reported rather than judged.
    const probe = try std.fmt.allocPrint(allocator, "mir after foreign {d}", .{nonce(io)});
    defer allocator.free(probe);
    try window.setClipboardText(probe);
    {
        const fetched = try runTool(io, allocator, tools.paste, null, true);
        defer allocator.free(fetched);
        const taken = std.mem.eql(u8, fetched, probe);
        switch (wm.*) {
            .x11 => {
                if (!taken) {
                    std.debug.print("clipboard: CurrentTime claim after a foreign owner got \"{s}\", expected \"{s}\"\n", .{ fetched, probe });
                    return error.ClipboardClaimDropped;
                }
                std.debug.print("clipboard: claim after a foreign owner: ok\n", .{});
            },
            .wayland => std.debug.print("clipboard: copy reusing an old serial after a foreign claim: {s} by the compositor\n", .{if (taken) "taken" else "dropped"}),
        }
    }
    try expectChanges(io, &changes, 1, "a second copy of our own");

    // 7. A 1 MiB text from the tool (xclip serves INCR above a quarter of
    // the request limit).
    const big_theirs = try largeText(allocator, nonce(io));
    defer allocator.free(big_theirs);
    allocator.free(try runTool(io, allocator, tools.copy, big_theirs, false));
    try expectPaste(io, allocator, window, .clipboard, big_theirs, "1 MiB foreign owner");
    std.debug.print("clipboard: 1 MiB pasted from {s}: ok\n", .{tools.copy[0]});
    try expectChanges(io, &changes, 2, "a foreign 1 MiB copy");

    // 8. A foreign primary claim, which must leave the clipboard alone and
    // raise nothing.
    if (primary_supported) {
        const primary_theirs = try std.fmt.allocPrint(allocator, "primary from {s} {d}", .{ tools.copy_primary[0], nonce(io) });
        defer allocator.free(primary_theirs);
        allocator.free(try runTool(io, allocator, tools.copy_primary, primary_theirs, false));
        try expectPaste(io, allocator, window, .primary, primary_theirs, "primary foreign owner");
        std.debug.print("primary: pasted from {s}: ok\n", .{tools.copy_primary[0]});
        try expectPaste(io, allocator, window, .clipboard, big_theirs, "clipboard after primary traffic");
        try expectChanges(io, &changes, 2, "a foreign primary copy");
    }

    // 5. An owner that never answers (X11 only: a bare connection that claims
    // CLIPBOARD and reads nothing). The paste must give up, and once the
    // silent owner is gone the next paste must come back at once.
    if (wm.* == .x11) {
        const silent = try x11.connect(io, environ, .{});
        var silent_open = true;
        defer if (silent_open) silent.close(io);
        const info = try x11.setup(io, environ, allocator, silent);
        defer info.deinit();
        var xid = x11.XID.init(info.resource_id_base, info.resource_id_mask);
        const owner = try xid.genID();
        const values = x11.proto.WindowValue{ .BackgroundPixel = 0 };
        try x11.sendWithValues(io, silent, x11.proto.CreateWindow{
            .window_id = owner,
            .parent_id = info.screens[0].root,
            .visual_id = info.screens[0].root_visual,
            .depth = info.screens[0].root_depth,
            .x = 0,
            .y = 0,
            .width = 1,
            .height = 1,
            .border_width = 0,
            .window_class = .InputOutput,
            .value_mask = x11.maskFromValues(x11.proto.WindowMask, values),
        }, values);
        const clipboard = try x11.internAtom(io, silent, "CLIPBOARD");
        try x11.send(io, silent, x11.proto.SetSelectionOwner{ .owner = owner, .selection = clipboard });
        // A reply-bearing request behind it proves the server has processed the claim.
        _ = try x11.internAtom(io, silent, "CLIPBOARD");

        const started = std.Io.Clock.now(.awake, io);
        if (window.getClipboardText(allocator)) |text| {
            allocator.free(text);
            std.debug.print("clipboard: a silent owner answered?\n", .{});
            return error.ClipboardTimeoutMissing;
        } else |err| switch (err) {
            error.ClipboardTimeout => {},
            else => return err,
        }
        const waited_ms = @divTrunc(started.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds, std.time.ns_per_ms);
        std.debug.print("clipboard: silent owner timed out after {d} ms: ok\n", .{waited_ms});
        try expectChanges(io, &changes, 3, "the silent owner's claim");

        silent.close(io);
        silent_open = false;
        // The server drops the selection with the connection; a paste now is
        // an immediate "nothing there".
        if (window.getClipboardText(allocator)) |text| {
            allocator.free(text);
            std.debug.print("clipboard: got text with no owner?\n", .{});
            return error.ClipboardNotEmpty;
        } else |err| switch (err) {
            error.ClipboardEmpty => {},
            else => return err,
        }
        std.debug.print("clipboard: empty after the owner left: ok\n", .{});
        // Only claims are subscribed to, so the loss itself raises nothing —
        // but a desktop's clipboard manager (klipper through kwin's XWayland
        // bridge) may claim the ownerless selection a moment later, which
        // is a change like any other. Reported, not judged.
        try io.sleep(std.Io.Duration.fromMilliseconds(200), .awake);
        const after_loss = changes.load(.monotonic);
        if (after_loss < 3) return error.ClipboardChangedMismatch;
        std.debug.print("clipboard_changed: {d} in all after the silent owner left ({s})\n", .{ after_loss, if (after_loss > 3) "a clipboard manager re-claimed it" else "nothing re-claimed it" });
    }
}

const ClipboardTools = struct {
    paste: []const []const u8,
    /// Takes the text on stdin. wl-copy would also take it as an argument, but
    /// a megabyte does not fit in one.
    copy: []const []const u8,
    paste_primary: []const []const u8,
    copy_primary: []const []const u8,
};

/// A megabyte: four times what one X11 request carries, so both sides of an
/// INCR transfer run several chunks.
const large_text_bytes = 1024 * 1024;

/// `large_text_bytes` of pseudo-random lowercase lines seeded by `seed`, so
/// two texts of the same size never compare equal by accident.
fn largeText(allocator: std.mem.Allocator, seed: u32) ![]u8 {
    const text = try allocator.alloc(u8, large_text_bytes);
    var state = seed;
    for (text, 0..) |*byte, index| {
        if (index % 64 == 63 and index + 1 != text.len) {
            byte.* = '\n';
            continue;
        }
        state = state *% 1664525 +% 1013904223;
        byte.* = 'a' + @as(u8, @intCast((state >> 24) % 26));
    }
    return text;
}

/// Fetch the selection with a foreign tool and check it is `expected`.
fn expectServed(io: std.Io, allocator: std.mem.Allocator, paste_tool: []const []const u8, expected: []const u8, what: []const u8) !void {
    const fetched = try runTool(io, allocator, paste_tool, null, true);
    defer allocator.free(fetched);
    if (!std.mem.eql(u8, fetched, expected)) {
        if (expected.len > 80) {
            std.debug.print("{s}: foreign paste got {d} bytes, expected {d}{s}\n", .{ what, fetched.len, expected.len, if (fetched.len == expected.len) " (same length, different bytes)" else "" });
        } else {
            std.debug.print("{s}: foreign paste got \"{s}\", expected \"{s}\"\n", .{ what, fetched, expected });
        }
        return error.ClipboardServeMismatch;
    }
    std.debug.print("{s}: served to {s} ({d} bytes): ok\n", .{ what, paste_tool[0], expected.len });
}

/// Wait for the reader to have counted `expected` clipboard_changed events in
/// all, then check no more came.
fn expectChanges(io: std.Io, changes: *std.atomic.Value(u32), expected: u32, what: []const u8) !void {
    var polls: u32 = 0;
    while (changes.load(.monotonic) < expected and polls < 50) : (polls += 1) {
        try io.sleep(std.Io.Duration.fromMilliseconds(20), .awake);
    }
    // A late extra one would show up here; give it a moment.
    try io.sleep(std.Io.Duration.fromMilliseconds(100), .awake);
    const got = changes.load(.monotonic);
    if (got != expected) {
        std.debug.print("clipboard_changed: {d} events in all after {s}, expected {d}\n", .{ got, what, expected });
        return error.ClipboardChangedMismatch;
    }
    std.debug.print("clipboard_changed: {d} in all after {s}: ok\n", .{ got, what });
}

/// Run a clipboard tool with `stdin_text` on its stdin (if any) and return
/// its stdout when `capture` is set. The copy tools fork a daemon that keeps
/// serving after the parent exits; waiting on the parent is enough, but the
/// daemon inherits the parent's streams, so they get no pipe to hold open.
fn runTool(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8, stdin_text: ?[]const u8, capture: bool) ![]u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (stdin_text != null) .pipe else .ignore,
        .stdout = if (capture) .pipe else .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(io);
    if (stdin_text) |text| {
        try child.stdin.?.writeStreamingAll(io, text);
        child.stdin.?.close(io);
        child.stdin = null;
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (capture) {
        const count = child.stdout.?.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) break;
        try output.appendSlice(allocator, chunk[0..count]);
    }
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("clipboard: {s} exited with {d}\n", .{ argv[0], code });
            return error.ClipboardToolFailed;
        },
        else => return error.ClipboardToolFailed,
    }
    return output.toOwnedSlice(allocator);
}

/// Paste until `expected` comes back. The server announces a changed
/// selection asynchronously, so until then a paste is empty or still returns
/// the previous owner's text.
fn expectPaste(io: std.Io, allocator: std.mem.Allocator, window: *win.Window, which: win.common.Selection, expected: []const u8, what: []const u8) !void {
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        const result = switch (which) {
            .clipboard => window.getClipboardText(allocator),
            .primary => window.getPrimaryText(allocator),
        };
        const pasted = result catch |err| switch (err) {
            error.ClipboardEmpty => if (tries < paste_tries) {
                try io.sleep(paste_retry, .awake);
                continue;
            } else return err,
            else => return err,
        };
        defer allocator.free(pasted);
        if (std.mem.eql(u8, pasted, expected)) return;
        if (tries < paste_tries) {
            try io.sleep(paste_retry, .awake);
            continue;
        }
        if (expected.len > 80) {
            std.debug.print("clipboard: {s} paste got {d} bytes, expected {d}{s}\n", .{ what, pasted.len, expected.len, if (pasted.len == expected.len) " (same length, different bytes)" else "" });
        } else {
            std.debug.print("clipboard: {s} paste got \"{s}\", expected \"{s}\"\n", .{ what, pasted, expected });
        }
        return error.ClipboardPasteMismatch;
    }
}

const paste_tries = 20;
const paste_retry = std.Io.Duration.fromMilliseconds(50);

/// A number unlikely to be on the clipboard already.
fn nonce(io: std.Io) u32 {
    const now = std.Io.Clock.now(.awake, io);
    return @truncate(@as(u96, @bitCast(now.nanoseconds)));
}

/// The reader task's loop while the clipboard check owns the main thread.
/// It counts `clipboard_changed` and drops everything else; the socket read
/// is the cancelation point.
fn readerLoop(io: std.Io, wm: *win.WindowManager, changes: *std.atomic.Value(u32)) void {
    while (true) {
        const event = wm.receiveIo(io) catch return;
        if (event) |received| {
            if (received == .clipboard_changed) _ = changes.fetchAdd(1, .monotonic);
        }
    }
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

/// A synthetic key press: the keycode and the state bits that select one of its columns.
const Press = struct {
    keycode: u8,
    state: u16,

    fn with(self: Press, bits: u16) Press {
        return .{ .keycode = self.keycode, .state = self.state | bits };
    }
};

const state_shift: u16 = 0x01;
const state_lock: u16 = 0x02;
const state_group_two: u16 = 1 << 13;
const keysym_euro: u32 = 0x20AC;
const keysym_kp_seven: u32 = 0xFFB7;
const keysym_dead_circumflex: u32 = 0xFE52;
const keysym_escape: u32 = 0xFF1B;

/// Drive the keyboard path with synthetic presses on X11. `SendEvent` delivers a KeyPress to our own window through the server, so mapping, levels, locks and compose run against the live keymap. Wayland has no client-side way to inject input, so only the keymap is printed there.
fn verifyKeys(io: std.Io, wm: *win.WindowManager, window: *win.Window) !void {
    const backend = switch (wm.*) {
        .x11 => |*x| x,
        .wayland => {
            std.debug.print("keys: not driven on Wayland (no input injection protocol)\n", .{});
            return;
        },
    };
    std.debug.print("keymap: {d} keysyms per keycode, level3 mask 0x{x}, num lock mask 0x{x}, mode switch mask 0x{x}\n", .{ backend.keysyms_per_keycode, backend.level3_mask, backend.num_lock_mask, backend.mode_switch_mask });

    const letter = findKeysym(backend, 'a', 0) orelse {
        std.debug.print("keys: no 'a' in the keymap, skipped\n", .{});
        return;
    };
    printColumns(backend, letter.keycode);
    try expectTyped(io, wm, window, &.{letter}, &.{'a'}, "plain letter");
    try expectTyped(io, wm, window, &.{letter.with(state_lock)}, &.{'A'}, "caps lock");
    try expectTyped(io, wm, window, &.{letter.with(state_shift)}, &.{'A'}, "shift");
    try expectTyped(io, wm, window, &.{letter.with(state_shift | state_lock)}, &.{'a'}, "shift under caps lock");

    if (backend.num_lock_mask != 0) {
        if (findKeysym(backend, keysym_kp_seven, 0)) |keypad| {
            try expectTyped(io, wm, window, &.{.{ .keycode = keypad.keycode, .state = backend.num_lock_mask }}, &.{'7'}, "keypad under num lock");
            try expectTyped(io, wm, window, &.{.{ .keycode = keypad.keycode, .state = 0 }}, &.{}, "keypad without num lock");
        }
    } else {
        std.debug.print("keys: Num_Lock is bound to no modifier, keypad skipped\n", .{});
    }

    if (findKeysym(backend, keysym_euro, 0)) |euro| {
        printColumns(backend, euro.keycode);
        try expectTyped(io, wm, window, &.{euro}, &.{keysym_euro}, "level 3 euro sign");
    } else {
        std.debug.print("keys: no EuroSign in the keymap, level 3 skipped\n", .{});
    }

    const hat = findKeysym(backend, keysym_dead_circumflex, 0) orelse {
        std.debug.print("keys: no dead_circumflex in the keymap, compose skipped\n", .{});
        return;
    };
    const group = hat.state & state_group_two;
    const letter_e = findKeysym(backend, 'e', group) orelse return error.NoLetterE;
    const letter_x = findKeysym(backend, 'x', group) orelse return error.NoLetterX;
    const escape = findKeysym(backend, keysym_escape, 0) orelse return error.NoEscape;
    printColumns(backend, hat.keycode);
    try expectTyped(io, wm, window, &.{ hat, letter_e }, &.{0xEA}, "dead circumflex then e");
    try expectTyped(io, wm, window, &.{ hat, letter_e.with(state_shift) }, &.{0xCA}, "dead circumflex then shift e");
    try expectTyped(io, wm, window, &.{ hat, hat }, &.{'^'}, "dead circumflex twice");
    try expectTyped(io, wm, window, &.{ hat, letter_x }, &.{ '^', 'x' }, "dead circumflex then x");
    try expectTyped(io, wm, window, &.{ hat, escape, letter_e }, &.{'e'}, "escape cancels a dead key");
}

/// A press that types `keysym`, preferring a column in the group `group_state` selects (0 for the first group).
fn findKeysym(backend: *win.x11.WindowManager, keysym: u32, group_state: u16) ?Press {
    var fallback: ?Press = null;
    var keycode: usize = backend.min_keycode;
    while (keycode <= backend.max_keycode) : (keycode += 1) {
        const columns = backend.keysymColumns(@intCast(keycode)) orelse continue;
        for (columns, 0..) |candidate, column| {
            if (candidate != keysym) continue;
            const press: Press = .{ .keycode = @intCast(keycode), .state = backend.stateForColumn(column) };
            // The column model has to read back what it predicts, or the press proves nothing.
            if (backend.lookupKeysym(press.keycode, press.state) != keysym) continue;
            if (press.state & state_group_two == group_state) return press;
            if (fallback == null) fallback = press;
        }
    }
    return fallback;
}

fn printColumns(backend: *win.x11.WindowManager, keycode: u8) void {
    std.debug.print("keycode {d}:", .{keycode});
    for (backend.keysymColumns(keycode) orelse &.{}) |keysym| std.debug.print(" 0x{x}", .{keysym});
    std.debug.print("\n", .{});
}

/// Send `presses` to our window through the server and check the characters that come back, from `key_pressed` codepoints and `text` events in order.
fn expectTyped(io: std.Io, wm: *win.WindowManager, window: *win.Window, presses: []const Press, expected: []const u21, what: []const u8) !void {
    const backend = &wm.x11;
    const window_id = window.x11.window_id;
    for (presses) |press| {
        const event = x11.proto.KeyPress{
            .keycode = press.keycode,
            .sequence_number = 0,
            .time = 0,
            .root_window = window.x11.root,
            .event_window = window_id,
            .child_window = 0,
            .root_x = 0,
            .root_y = 0,
            .event_x = 0,
            .event_y = 0,
            .state = press.state,
            .same_screen = 1,
            .pad = .{0},
        };
        try x11.send(io, backend.conn, x11.proto.SendEvent{ .destination = window_id, .event_mask = 0, .event = std.mem.toBytes(event) });
    }

    var typed: [16]u21 = undefined;
    var typed_len: usize = 0;
    var pressed: usize = 0;
    try window.redraw(.{});
    collect: while (try wm.receiveIo(io)) |event| {
        switch (event) {
            .draw => break :collect,
            .key_pressed => |press| {
                pressed += 1;
                if (press.codepoint) |codepoint| {
                    if (typed_len < typed.len) typed[typed_len] = codepoint;
                    typed_len += 1;
                }
            },
            .text => |text| {
                if (typed_len < typed.len) typed[typed_len] = text.codepoint;
                typed_len += 1;
            },
            .close => return error.WindowClosed,
            else => {},
        }
    }

    const got = typed[0..@min(typed_len, typed.len)];
    if (pressed != presses.len or !std.mem.eql(u21, got, expected)) {
        std.debug.print("keys: {s}: {d} presses came back as {d}, typed", .{ what, presses.len, pressed });
        for (got) |codepoint| std.debug.print(" U+{X:0>4}", .{codepoint});
        std.debug.print(", expected", .{});
        for (expected) |codepoint| std.debug.print(" U+{X:0>4}", .{codepoint});
        std.debug.print("\n", .{});
        return error.KeyMismatch;
    }
    std.debug.print("keys: {s}: ok\n", .{what});
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
const x11 = @import("x11");
const win = @import("anywindow");
