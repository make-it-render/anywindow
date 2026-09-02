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

    // Last: it runs the reader on a task, and canceling that mid-message would
    // confuse the synchronous pumps above.
    try verifyClipboard(io, environ, allocator, &wm, &window);

    std.debug.print("verify: ok\n", .{});
}

/// The clipboard five ways: our text served to a foreign client (wl-paste or
/// xclip), a self round trip through the server so the serving path runs end
/// to end in one process, a foreign client's text pasted here, a copy made
/// after that foreign claim, and (X11) an owner that never answers, which a
/// paste must time out on. The reader runs on a task meanwhile, as it does
/// under recvloop: the serving side lives there, and the main thread must be
/// free to block in child processes and in the paste itself.
fn verifyClipboard(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator, wm: *win.WindowManager, window: *win.Window) !void {
    const tools: ClipboardTools = switch (wm.*) {
        .wayland => .{ .paste = &.{ "wl-paste", "--no-newline" }, .copy = &.{"wl-copy"}, .copy_from_stdin = false },
        .x11 => .{ .paste = &.{ "xclip", "-selection", "clipboard", "-o" }, .copy = &.{ "xclip", "-selection", "clipboard", "-i" }, .copy_from_stdin = true },
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

    var reader = try io.concurrent(readerLoop, .{ io, wm });
    defer reader.cancel(io);

    // 1. Served: our text, fetched by a foreign client.
    const ours = try std.fmt.allocPrint(allocator, "mir clipboard {d}", .{nonce(io)});
    defer allocator.free(ours);
    try window.setClipboardText(ours);
    {
        const fetched = try runTool(io, allocator, tools.paste, null, true);
        defer allocator.free(fetched);
        if (!std.mem.eql(u8, fetched, ours)) {
            std.debug.print("clipboard: foreign paste got \"{s}\", expected \"{s}\"\n", .{ fetched, ours });
            return error.ClipboardServeMismatch;
        }
    }
    std.debug.print("clipboard: served to {s}: ok\n", .{tools.paste[0]});

    // 2. Self, through the server: a paste never short-circuits to our own
    // text, so the reader task serves our own request here.
    const again = try std.fmt.allocPrint(allocator, "mir round trip {d}", .{nonce(io)});
    defer allocator.free(again);
    try window.setClipboardText(again);
    try expectPaste(io, allocator, window, again, "server round trip");
    std.debug.print("clipboard: round trip through the server: ok\n", .{});

    // 3. Foreign: a tool owns the selection, we paste it.
    const theirs = try std.fmt.allocPrint(allocator, "from {s} {d}", .{ tools.copy[0], nonce(io) });
    defer allocator.free(theirs);
    if (tools.copy_from_stdin) {
        allocator.free(try runTool(io, allocator, tools.copy, theirs, false));
    } else {
        const argv = [_][]const u8{ tools.copy[0], theirs };
        allocator.free(try runTool(io, allocator, &argv, null, false));
    }
    try expectPaste(io, allocator, window, theirs, "foreign owner");
    std.debug.print("clipboard: pasted from {s}: ok\n", .{tools.copy[0]});

    // 4. A copy with no new input since the foreign claim. X11 claims with
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
    }
}

const ClipboardTools = struct {
    paste: []const []const u8,
    copy: []const []const u8,
    /// xclip takes the text on stdin; wl-copy takes it as an argument.
    copy_from_stdin: bool,
};

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
fn expectPaste(io: std.Io, allocator: std.mem.Allocator, window: *win.Window, expected: []const u8, what: []const u8) !void {
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        const pasted = window.getClipboardText(allocator) catch |err| switch (err) {
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
        std.debug.print("clipboard: {s} paste got \"{s}\", expected \"{s}\"\n", .{ what, pasted, expected });
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
/// Events are dropped; the socket read is the cancelation point.
fn readerLoop(io: std.Io, wm: *win.WindowManager) void {
    while (true) {
        _ = wm.receiveIo(io) catch return;
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
