pub const WindowManager = struct {
    io: std.Io,
    environ: std.process.Environ,
    allocator: std.mem.Allocator,

    conn: std.Io.net.Stream,
    atoms: Atoms,
    info: x11.Setup,
    xid: x11.XID,

    net_writer_buffer: []u8,
    net_writer: *std.Io.net.Stream.Writer,

    /// MIT-SHM, when the server offers it and is new enough to take a file descriptor.
    /// Null means every present goes through core PutImage — SHM is an acceleration, never a
    /// requirement, so nothing below may treat its absence as an error.
    shm: ?x11.Extension,
    /// Segments the server may still be reading, keyed by shmseg.
    ///
    /// Written from two tasks: the renderer adds a segment when it sends a ShmPutImage, and
    /// whichever task reads the connection removes it when the matching ShmCompletion arrives
    /// (see mapMessage). Keyed by XID rather than by pointer on purpose — a stale entry then only
    /// costs that image the fast path, where a stale pointer would be a use-after-free.
    in_flight: std.AutoHashMapUnmanaged(u32, void) = .empty,
    in_flight_mutex: std.Io.Mutex = .init,

    scaling: f32,

    cursor_font_id: u32 = 0,
    invisible_cursor_id: u32 = 0,
    system_cursors: [cursor_count]u32 = [_]u32{0} ** cursor_count,

    /// A message read while peeking past a KeyRelease for its auto-repeat
    /// press, handed back by the next `receiveIo`.
    held_message: ?x11.Message = null,

    /// A second connection for selection traffic: the reader task answers requests and reads
    /// paste replies here, so `conn` keeps its single writer and single reader. Null when the
    /// connect failed, which makes the clipboard unsupported.
    clipboard_conn: ?std.Io.net.Stream,
    /// Requests sent on `clipboard_conn` so far; replies and errors there quote it. Reader task only.
    clipboard_sequence: u16 = 0,
    /// XFixes, for the owner-change events behind `Event.clipboard_changed`. Null when the
    /// server lacks it, in which case the event is never sent.
    xfixes: ?x11.Extension,

    // Selection state, guarded by clipboard_mutex: callers and the reader task both touch it.
    /// CLIPBOARD, PRIMARY and XdndSelection, indexed by `SelectionIndex`: the payload we serve
    /// while one of our windows owns each, and that window.
    selections: [selection_count]OwnedSelection,
    /// The paste in flight; see `paste`. The reader task matches a SelectionNotify against the
    /// requestor, and delivers into the generation it matched, so a fetch started for a paste
    /// that timed out meanwhile is dropped instead of being taken for the next one.
    paste_pending: bool = false,
    paste_generation: u32 = 0,
    paste_requestor: u32 = 0,
    paste_result: ?[]u8 = null,
    paste_error: ?common.ClipboardError = null,
    /// Bumped by the reader task for every INCR chunk received, so a paste that is still
    /// making progress can outlive `paste_timeout`.
    paste_progress: u32 = 0,
    clipboard_mutex: std.Io.Mutex = .init,
    /// One paste at a time; held for the whole of `paste`.
    paste_mutex: std.Io.Mutex = .init,
    /// Set by the reader task once paste_result or paste_error is filled.
    paste_ready: std.Io.Event = .unset,
    /// An INCR transfer we are receiving: the owner appends chunks to the paste property one
    /// PropertyNotify at a time. Reader task only.
    incr_paste: ?IncrPaste = null,
    /// INCR transfers we are sending, each on a connection of its own; reaped as they finish,
    /// canceled in deinit. Reader task only.
    incr_sends: std.ArrayList(*IncrSend) = .empty,

    // Drag and drop; the state machines are described in x11_drag.zig.
    /// The kinds each window takes, written by `setDropTarget`. Under clipboard_mutex.
    drop_kinds: std.AutoHashMapUnmanaged(common.WindowID, common.DropKinds) = .empty,
    /// The drag over one of our windows. Reader task only.
    drop_target: ?x11_drag.DropTarget = null,
    /// The newest drop's payload until `takeDrop` moves it out. Under clipboard_mutex.
    pending_drop: ?common.DropData = null,
    /// Whether a drag of ours runs, from `startDrag` until `drag_finished`. Under clipboard_mutex.
    drag_active: bool = false,
    /// The drag `startDrag` set up, until the reader task takes it on the start message. Under clipboard_mutex.
    drag_request: ?x11_drag.DragSource = null,
    /// The running drag of ours. Reader task only.
    drag_source: ?x11_drag.DragSource = null,
    /// Timed waits on a silent peer, each on a connection of its own; reaped as they finish,
    /// canceled in deinit. Reader task only.
    drag_timers: std.ArrayList(*x11_drag.Timer) = .empty,
    /// Ties a timer's message to the wait that started it. Reader task only.
    timer_generation: u32 = 0,

    keysym_map: []u32,
    keysyms_per_keycode: u8,
    min_keycode: u8,
    max_keycode: u8,
    /// The state bits the server binds ISO_Level3_Shift to, from `GetModifierMapping`; Mod5 when it binds none.
    level3_mask: u16,
    /// The state bits the server binds Mode_switch to; zero when it binds none.
    mode_switch_mask: u16,
    /// The state bits the server binds Num_Lock to; zero when it binds none.
    num_lock_mask: u16,
    compose: Compose,
    /// Events a key press produced beyond its own `key_pressed`; `receiveIo` drains it before reading the socket.
    queued: EventQueue = .{},

    pub fn init(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator) !@This() {
        const conn = try x11.connect(io, environ, .{});

        const info = try x11.setup(io, environ, allocator, conn);
        errdefer info.deinit();

        var xid = x11.XID.init(info.resource_id_base, info.resource_id_mask);

        const atoms = Atoms{
            .atom = try x11.internAtom(io, conn, "ATOM"),
            .cardinal = try x11.internAtom(io, conn, "CARDINAL"),
            .string = try x11.internAtom(io, conn, "STRING"),
            .wm_name = try x11.internAtom(io, conn, "WM_NAME"),
            .wm_protocols = try x11.internAtom(io, conn, "WM_PROTOCOLS"),
            .wm_delete_window = try x11.internAtom(io, conn, "WM_DELETE_WINDOW"),
            .net_wm_state = try x11.internAtom(io, conn, "_NET_WM_STATE"),
            .net_wm_state_fullscreen = try x11.internAtom(io, conn, "_NET_WM_STATE_FULLSCREEN"),
            .net_wm_icon = try x11.internAtom(io, conn, "_NET_WM_ICON"),
            .clipboard = try x11.internAtom(io, conn, "CLIPBOARD"),
            .primary = try x11.internAtom(io, conn, "PRIMARY"),
            .utf8_string = try x11.internAtom(io, conn, "UTF8_STRING"),
            .targets = try x11.internAtom(io, conn, "TARGETS"),
            .text = try x11.internAtom(io, conn, "TEXT"),
            .incr = try x11.internAtom(io, conn, "INCR"),
            .mir_clipboard = try x11.internAtom(io, conn, "MIR_CLIPBOARD"),
            .xdnd_aware = try x11.internAtom(io, conn, x11.xdnd.Atom.aware),
            .xdnd_selection = try x11.internAtom(io, conn, x11.xdnd.Atom.selection),
            .xdnd_enter = try x11.internAtom(io, conn, x11.xdnd.Atom.enter),
            .xdnd_position = try x11.internAtom(io, conn, x11.xdnd.Atom.position),
            .xdnd_status = try x11.internAtom(io, conn, x11.xdnd.Atom.status),
            .xdnd_leave = try x11.internAtom(io, conn, x11.xdnd.Atom.leave),
            .xdnd_drop = try x11.internAtom(io, conn, x11.xdnd.Atom.drop),
            .xdnd_finished = try x11.internAtom(io, conn, x11.xdnd.Atom.finished),
            .xdnd_type_list = try x11.internAtom(io, conn, x11.xdnd.Atom.type_list),
            .xdnd_proxy = try x11.internAtom(io, conn, x11.xdnd.Atom.proxy),
            .xdnd_action_copy = try x11.internAtom(io, conn, x11.xdnd.Atom.action_copy),
            .mime_uri_list = try x11.internAtom(io, conn, "text/uri-list"),
            .mime_utf8 = try x11.internAtom(io, conn, "text/plain;charset=utf-8"),
            .mime_text_plain = try x11.internAtom(io, conn, "text/plain"),
            .mir_drop = try x11.internAtom(io, conn, "MIR_DROP"),
            .mir_drag_control = try x11.internAtom(io, conn, "MIR_DRAG_CONTROL"),
        };

        const clipboard_conn = openClipboardConnection(io, environ, allocator);
        errdefer if (clipboard_conn) |clipboard| clipboard.close(io);

        // Negotiate the extensions while replies are still safe to read naively — once the event
        // loop starts, its reader task owns the connection and would swallow any reply we waited for.
        const shm_extension = probeShm(io, conn, info);
        const xfixes_extension = probeXfixes(io, conn, info.screens[0].root, atoms.clipboard);

        const net_writer_buffer: []u8 = try allocator.alloc(u8, 4 * 1024);
        errdefer allocator.free(net_writer_buffer);
        const net_writer = try allocator.create(std.Io.net.Stream.Writer);
        errdefer allocator.destroy(net_writer);
        net_writer.* = conn.writer(io, net_writer_buffer);

        const scaling = getDesktopScaling(io, environ, allocator) catch 1.0;

        // Query keyboard mapping
        const min_kc = info.min_keycode;
        const max_kc = info.max_keycode;
        const kc_count = max_kc - min_kc + 1;

        try x11.send(io, conn, x11.proto.GetKeyboardMapping{
            .first_keycode = min_kc,
            .count = kc_count,
        });

        const kb_reply = try x11.receiveReply(io, conn, x11.proto.GetKeyboardMappingReply);

        var keysyms_per_keycode: u8 = 0;
        var keysym_map: []u32 = &[_]u32{};

        if (kb_reply) |r| {
            keysyms_per_keycode = r.keysyms_per_keycode;
            const total_keysyms: u32 = @as(u32, kc_count) * @as(u32, keysyms_per_keycode);
            keysym_map = try allocator.alloc(u32, total_keysyms);
            errdefer allocator.free(keysym_map);

            const keysym_bytes = std.mem.sliceAsBytes(keysym_map);
            try x11.receiveBytes(io, conn, keysym_bytes);
        }

        const modifier_masks = queryModifierMasks(io, conn, allocator, keysym_map, keysyms_per_keycode, min_kc) catch |err| blk: {
            log.debug("GetModifierMapping failed ({any}); level 3 assumed on Mod5", .{err});
            break :blk ModifierMasks{};
        };
        var compose = Compose.load(io, allocator, environ);
        errdefer compose.deinit();

        // Open the X11 "cursor" font for standard cursor shapes
        const cursor_font_id = try xid.genID();
        const cursor_font_name = "cursor";
        try x11.sendWithBytes(io, conn, x11.proto.OpenFont{
            .length = undefined, // sendWithBytes recalculates this
            .font_id = cursor_font_id,
            .name_length = cursor_font_name.len,
        }, cursor_font_name);

        // Create a 1x1 invisible cursor for hideCursor()
        const tmp_pixmap_id = try xid.genID();
        try x11.send(io, conn, x11.proto.CreatePixmap{
            .pixmap_id = tmp_pixmap_id,
            .drawable_id = info.screens[0].root,
            .width = 1,
            .height = 1,
            .depth = 1,
        });

        const invisible_cursor_id = try xid.genID();
        try x11.send(io, conn, x11.proto.CreateCursor{
            .cursor_id = invisible_cursor_id,
            .source_pixmap = tmp_pixmap_id,
            .mask_pixmap = tmp_pixmap_id,
            .fore_red = 0,
            .fore_green = 0,
            .fore_blue = 0,
            .back_red = 0,
            .back_green = 0,
            .back_blue = 0,
            .x_hotspot = 0,
            .y_hotspot = 0,
        });

        try x11.send(io, conn, x11.proto.FreePixmap{ .pixmap_id = tmp_pixmap_id });

        return .{
            .io = io,
            .environ = environ,
            .allocator = allocator,
            .conn = conn,
            .info = info,
            .xid = xid,
            .atoms = atoms,

            .net_writer_buffer = net_writer_buffer,
            .net_writer = net_writer,

            .shm = shm_extension,
            .clipboard_conn = clipboard_conn,
            .xfixes = xfixes_extension,
            .selections = .{
                .{ .atom = atoms.clipboard },
                .{ .atom = atoms.primary },
                .{ .atom = atoms.xdnd_selection },
            },

            .scaling = scaling,

            .cursor_font_id = cursor_font_id,
            .invisible_cursor_id = invisible_cursor_id,

            .keysym_map = keysym_map,
            .keysyms_per_keycode = keysyms_per_keycode,
            .min_keycode = min_kc,
            .max_keycode = max_kc,
            .level3_mask = modifier_masks.level3,
            .mode_switch_mask = modifier_masks.mode_switch,
            .num_lock_mask = modifier_masks.num_lock,
            .compose = compose,
        };
    }

    pub fn deinit(self: *@This()) void {
        // Free cursor resources
        for (self.system_cursors) |cursor_id| {
            if (cursor_id != 0) {
                x11.send(self.io, self.conn, x11.proto.FreeCursor{ .cursor_id = cursor_id }) catch {};
            }
        }
        if (self.invisible_cursor_id != 0) {
            x11.send(self.io, self.conn, x11.proto.FreeCursor{ .cursor_id = self.invisible_cursor_id }) catch {};
        }
        if (self.cursor_font_id != 0) {
            x11.send(self.io, self.conn, x11.proto.CloseFont{ .font_id = self.cursor_font_id }) catch {};
        }

        self.allocator.free(self.keysym_map);
        self.compose.deinit();
        self.in_flight.deinit(self.allocator);
        self.reapIncrSends(.cancel);
        self.incr_sends.deinit(self.allocator);
        self.reapTimers(.cancel);
        self.drag_timers.deinit(self.allocator);
        if (self.drag_source) |drag| self.releasePointerGrab(drag.grab);
        if (self.drag_request) |drag| self.releasePointerGrab(drag.grab);
        if (self.incr_paste) |*incr| incr.data.deinit(self.allocator);
        for (&self.selections) |*selection| {
            if (selection.payload) |payload| payload.deinit(self.allocator);
        }
        if (self.pending_drop) |drop| drop.deinit(self.allocator);
        self.drop_kinds.deinit(self.allocator);
        if (self.paste_result) |text| self.allocator.free(text);
        if (self.clipboard_conn) |clipboard| clipboard.close(self.io);
        self.conn.close(self.io);
        self.info.deinit();
        self.allocator.free(self.net_writer_buffer);
        self.allocator.destroy(self.net_writer);
    }

    /// Record that a ShmPutImage naming `shmseg` is on its way to the server, so nothing
    /// overwrites that segment before the server is done reading it.
    /// Returns false if the segment could not be tracked, in which case the caller must not use
    /// the SHM path — an untracked segment is one we could never prove safe to reuse.
    fn markSegmentInFlight(self: *@This(), shmseg: u32) bool {
        self.in_flight_mutex.lockUncancelable(self.io);
        defer self.in_flight_mutex.unlock(self.io);
        self.in_flight.put(self.allocator, shmseg, {}) catch return false;
        return true;
    }

    /// Whether the server may still be reading `shmseg`.
    fn isSegmentInFlight(self: *@This(), shmseg: u32) bool {
        self.in_flight_mutex.lockUncancelable(self.io);
        defer self.in_flight_mutex.unlock(self.io);
        return self.in_flight.contains(shmseg);
    }

    /// The server has finished with `shmseg`; it is safe to overwrite again.
    fn clearSegmentInFlight(self: *@This(), shmseg: u32) void {
        self.in_flight_mutex.lockUncancelable(self.io);
        defer self.in_flight_mutex.unlock(self.io);
        _ = self.in_flight.remove(shmseg);
    }

    pub fn createWindow(self: *@This(), options: common.WindowOptions) !Window {
        return try Window.init(self, options);
    }

    /// Event source for recvloop's io loop: reads events directly through `io`.
    /// The socket read is a cancelation point, so a task blocked here is
    /// interrupted by `io` cancelation (e.g. the loop's group cancel in `deinit`)
    /// and returns `error.Canceled`. Internal no-op messages are skipped.
    pub fn receiveIo(self: *@This(), io: std.Io) !?common.Event {
        while (true) {
            if (self.queued.pop()) |event| return event;
            const message = self.takeHeldMessage() orelse (try x11.receive(io, self.conn, .none) orelse continue);
            const event = switch (message) {
                .KeyRelease => |release| try self.mapKeyRelease(io, release),
                // Selection traffic is answered here and never surfaces as an event.
                .SelectionRequest => |request| blk: {
                    self.serveSelection(io, request) catch |err| log.warn("Failed to serve a selection request: {any}", .{err});
                    break :blk common.Event{ .nop = {} };
                },
                .SelectionClear => |clear| blk: {
                    if (self.selectionOf(clear.selection)) |which| self.dropSelection(io, clear.owner, which);
                    break :blk common.Event{ .nop = {} };
                },
                // A drop's payload arrives the way a paste does; the selection says which it is.
                .SelectionNotify => |notify| if (notify.selection == self.atoms.xdnd_selection) self.finishDrop(io, notify) else blk: {
                    self.finishPaste(io, notify);
                    break :blk common.Event{ .nop = {} };
                },
                // An INCR owner announces each chunk with a property change on our window.
                .PropertyNotify => |notify| self.continueIncrPaste(io, notify),
                // Nothing waits for replies on this connection once the loop owns it (GrabPointer's
                // is the one that arrives); drain the trailing data so the stream stays aligned.
                .Reply => |reply| blk: {
                    try skipBytes(io, self.conn, reply.extraLength());
                    break :blk common.Event{ .nop = {} };
                },
                else => self.mapMessage(io, message),
            };
            switch (event) {
                .nop => {}, // ignored message — keep reading
                else => return event,
            }
        }
    }

    fn takeHeldMessage(self: *@This()) ?x11.Message {
        const message = self.held_message orelse return null;
        self.held_message = null;
        return message;
    }

    /// Core X11 has no repeat flag: auto-repeat arrives as a KeyRelease
    /// immediately followed by a KeyPress with the same timestamp and
    /// keycode, in one server write. Peek briefly for that press and fold
    /// the pair into a single repeated `key_pressed`; anything else read
    /// while peeking is held for the next call.
    fn mapKeyRelease(self: *@This(), io: std.Io, release: x11.proto.KeyRelease) !common.Event {
        if (try x11.receive(io, self.conn, .{ .duration = .{ .raw = repeat_peek_window, .clock = .awake } })) |next| {
            if (isAutoRepeatPair(release, next)) return self.mapKeyPress(next.KeyPress, true);
            self.held_message = next;
        }
        return self.mapMessage(io, .{ .KeyRelease = release });
    }

    fn mapKeyPress(self: *@This(), key_press: x11.proto.KeyPress, repeat: bool) common.Event {
        const keysym = self.lookupKeysym(key_press.keycode, key_press.state);
        const window_id = key_press.event_window;
        // Auto-repeat stays out of sequences: a held dead key arms once, and a held letter after a composition types plainly.
        const step: Compose.Step = if (repeat) .ignored else self.compose.feed(keysym);
        const typed: ?u21 = switch (step) {
            .ignored => keys.keysymToCodepoint(keysym),
            .pending, .composed => null,
            .cancelled => |cancelled| if (cancelled.restarted) null else keys.keysymToCodepoint(keysym),
        };
        const pressed: common.Event = .{ .key_pressed = .{
            .scancode = keys.evdevToScancode(key_press.keycode -| 8),
            .key = keys.x11KeysymToKey(keysym),
            .modifiers = x11ModsFromState(key_press.state),
            .codepoint = typed,
            .repeat = repeat,
            .window_id = window_id,
        } };
        switch (step) {
            .composed => |text| self.queued.pushText(text.slice(), window_id),
            // The accents a broken sequence leaves behind were typed before this key.
            .cancelled => |cancelled| if (cancelled.text.len > 0) {
                self.queued.pushText(cancelled.text.slice(), window_id);
                self.queued.push(pressed);
                return self.queued.pop().?;
            },
            else => {},
        }
        return pressed;
    }

    /// Map a raw X11 message to a `common.Event` (`.nop` for messages we ignore).
    fn mapMessage(self: *@This(), io: std.Io, message: x11.Message) common.Event {
        {
            switch (message) {
                .Expose => |expose| {
                    return .{
                        .draw = .{
                            .window_id = expose.window_id,
                            .area = common.BBox{
                                .x = 0,
                                .y = 0,
                                .width = 0,
                                .height = 0,
                            },
                        },
                    };
                },
                .ClientMessage => |client_message| {
                    // Another client may send any format; only the five-long ones are ours to read.
                    if (client_message.format != 32) return .{ .nop = {} };
                    const data = x11.clientMessageData(client_message).u32;
                    const atoms = self.atoms;
                    const message_type = client_message.data_Type;
                    const window = client_message.window_id;
                    if (message_type == atoms.wm_protocols) {
                        if (data[0] == atoms.wm_delete_window) return .{ .close = window };
                    } else if (message_type == atoms.xdnd_enter) {
                        return self.xdndEnter(io, window, x11.xdnd.Enter.unpack(data));
                    } else if (message_type == atoms.xdnd_position) {
                        return self.xdndPosition(io, window, x11.xdnd.Position.unpack(data));
                    } else if (message_type == atoms.xdnd_leave) {
                        return self.xdndLeave(window, x11.xdnd.Leave.unpack(data));
                    } else if (message_type == atoms.xdnd_drop) {
                        return self.xdndDrop(io, window, x11.xdnd.Drop.unpack(data));
                    } else if (message_type == atoms.xdnd_status) {
                        return self.dragStatus(io, window, x11.xdnd.Status.unpack(data));
                    } else if (message_type == atoms.xdnd_finished) {
                        return self.dragFinished(io, window, x11.xdnd.Finished.unpack(data));
                    } else if (message_type == atoms.mir_drag_control) {
                        return self.dragControl(io, window, @enumFromInt(data[0]), data[1]);
                    }
                    return .{ .nop = {} };
                },
                // Our own window going away ends whatever drag it was part of.
                .DestroyNotify => |destroyed| {
                    if (self.drop_target) |target| {
                        if (target.window == destroyed.window_id) {
                            self.abandonDropIncr();
                            self.drop_target = null;
                        }
                    }
                    if (self.drag_source) |drag| {
                        if (drag.window == destroyed.window_id) return self.finishDrag(io, false);
                    }
                    return .{ .nop = {} };
                },
                .KeyRelease => |key_release| {
                    const evdev_code = key_release.keycode -| 8;
                    const sc = keys.evdevToScancode(evdev_code);
                    const keysym = self.lookupKeysym(key_release.keycode, key_release.state);
                    const key = keys.x11KeysymToKey(keysym);
                    const mods = x11ModsFromState(key_release.state);
                    return .{
                        .key_released = .{
                            .scancode = sc,
                            .key = key,
                            .modifiers = mods,
                            .window_id = key_release.event_window,
                        },
                    };
                },
                .KeyPress => |key_press| {
                    // Escape cancels a drag of ours; the key never reaches the application.
                    if (self.drag_source != null and self.lookupKeysym(key_press.keycode, key_press.state) == keysym_escape) {
                        return self.cancelDrag(io);
                    }
                    return self.mapKeyPress(key_press, false);
                },
                // Grab-driven focus changes (a window manager's alt-tab popup
                // taking the keyboard) are transient and not reported.
                .FocusIn => |focus| {
                    if (focus.mode == .Grab or focus.mode == .Ungrab) return .{ .nop = {} };
                    return .{ .focus_in = focus.event };
                },
                .FocusOut => |focus| {
                    self.compose.cancel();
                    if (focus.mode == .Grab or focus.mode == .Ungrab) return .{ .nop = {} };
                    return .{ .focus_out = focus.event };
                },
                .ButtonRelease => |button_release| {
                    // During a drag of ours the grab task forwards the release here; it ends the drag.
                    if (self.drag_source) |drag| {
                        if (drag.window == button_release.event_window) return self.dragRelease(io, button_release.time);
                    }
                    switch (button_release.keycode) {
                        4, 5, 6, 7 => return .{ .nop = {} },
                        else => return .{
                            .mouse_released = .{
                                .window_id = button_release.event_window,
                                .x = button_release.event_x,
                                .y = button_release.event_y,
                                .button = button_release.keycode,
                            },
                        },
                    }
                },
                .ButtonPress => |button_press| {
                    switch (button_press.keycode) {
                        4 => return .{
                            .mouse_scroll = .{
                                .x = button_press.event_x,
                                .y = button_press.event_y,
                                .scroll_x = 0,
                                .scroll_y = 1,
                                .window_id = button_press.event_window,
                            },
                        },
                        5 => return .{
                            .mouse_scroll = .{
                                .x = button_press.event_x,
                                .y = button_press.event_y,
                                .scroll_x = 0,
                                .scroll_y = -1,
                                .window_id = button_press.event_window,
                            },
                        },
                        6 => return .{
                            .mouse_scroll = .{
                                .x = button_press.event_x,
                                .y = button_press.event_y,
                                .scroll_x = -1,
                                .scroll_y = 0,
                                .window_id = button_press.event_window,
                            },
                        },
                        7 => return .{
                            .mouse_scroll = .{
                                .x = button_press.event_x,
                                .y = button_press.event_y,
                                .scroll_x = 1,
                                .scroll_y = 0,
                                .window_id = button_press.event_window,
                            },
                        },
                        else => return .{
                            .mouse_pressed = .{
                                .window_id = button_press.event_window,
                                .x = button_press.event_x,
                                .y = button_press.event_y,
                                .button = button_press.keycode,
                            },
                        },
                    }
                },
                .MotionNotify => |motion_notify| {
                    // During a drag of ours the pointer is grabbed and every motion is the drag's.
                    if (self.drag_source) |drag| {
                        if (drag.window == motion_notify.event_window) {
                            return self.dragMotion(io, .{ .root_x = motion_notify.root_x, .root_y = motion_notify.root_y, .time = motion_notify.time });
                        }
                    }
                    return .{
                        .mouse_moved = .{
                            .x = motion_notify.event_x,
                            .y = motion_notify.event_y,
                            .window_id = motion_notify.event_window,
                        },
                    };
                },
                .ConfigureNotify => |configure| {
                    // The window moved or resized: its root origin, which drag positions are converted with, is read again at the next position.
                    if (self.drop_target) |*target| {
                        if (target.window == configure.window_id) target.origin_valid = false;
                    }
                    return .{
                        .resize = .{
                            .width = configure.width,
                            .height = configure.height,
                            .window_id = configure.window_id,
                        },
                    };
                },
                .Generic => |generic| {
                    // Extension events have server-assigned codes, so they can only be identified
                    // by comparing against the bases we got at negotiation time.
                    if (self.shm) |ext| {
                        if (ext.isEvent(generic.code, x11.shm.Event.completion)) {
                            const completion = generic.as(x11.shm.Completion);
                            self.clearSegmentInFlight(completion.shmseg);
                        }
                    }
                    if (self.xfixes) |ext| {
                        if (ext.isEvent(generic.code, x11.xfixes.Event.selection_notify)) {
                            return self.mapSelectionOwnerChange(generic.as(x11.xfixes.SelectionNotify));
                        }
                    }
                    return .{ .nop = {} };
                },
                else => {
                    return .{ .nop = {} };
                },
            }
        }
    }

    pub fn flush(self: *@This()) !void {
        self.net_writer.interface.flush() catch |err| {
            if (self.net_writer.err) |net_err| {
                log.err("Net error: {any}", .{net_err});
                return net_err;
            } else {
                log.err("Writer error: {any}", .{err});
                return err;
            }
        };
    }

    /// The keysym a press of `keycode` types under `state`: the core protocol's rules with XKB's level-3 column. AltGr picks the level-3 pair, Shift the upper keysym, Caps Lock upper-cases letter pairs, Num Lock picks the keypad digit.
    pub fn lookupKeysym(self: *const @This(), keycode: u8, state: u16) u32 {
        const columns = self.keysymColumns(keycode) orelse return 0;
        const shift = state & state_shift != 0;
        const lock = state & state_lock != 0;
        const level3 = state & self.level3_mask != 0;
        const num_lock = state & self.num_lock_mask != 0;
        // An XKB server puts the effective group in bits 13-14; a core server switches groups with Mode_switch.
        var group: usize = (state >> 13) & 3;
        if (group == 0 and state & self.mode_switch_mask != 0) group = 1;

        const pair = keysymPair(columns, group, level3);
        const lower = pair[0];
        if (lower == 0) return if (shift) pair[1] else 0;
        const upper = if (pair[1] != 0) pair[1] else impliedUpper(lower);
        if (wl.xkb.keysym.isKeypad(lower) or wl.xkb.keysym.isKeypad(upper)) return if (num_lock != shift) upper else lower;
        if (wl.xkb.keysym.isAlphaPair(lower, upper)) return if (shift != lock) upper else lower;
        return if (shift) upper else lower;
    }

    /// The keysym columns of `keycode`, `keysyms_per_keycode` long; null off the keyboard's range.
    pub fn keysymColumns(self: *const @This(), keycode: u8) ?[]const u32 {
        if (keycode < self.min_keycode or keycode > self.max_keycode) return null;
        const per_keycode: usize = self.keysyms_per_keycode;
        const base = @as(usize, keycode - self.min_keycode) * per_keycode;
        if (base + per_keycode > self.keysym_map.len) return null;
        return self.keysym_map[base .. base + per_keycode];
    }

    /// The state under which `lookupKeysym` reads `column` of a key: Shift for odd columns, the second group for columns 2, 3 and 6 up, level 3 for columns 4 up.
    pub fn stateForColumn(self: *const @This(), column: usize) u16 {
        var state: u16 = 0;
        if (column % 2 == 1) state |= state_shift;
        if (column == 2 or column == 3 or column >= 6) state |= state_group_two;
        if (column >= 4) state |= self.level3_mask;
        return state;
    }

    /// The state of one selection.
    fn stateOf(self: *@This(), which: SelectionIndex) *OwnedSelection {
        return &self.selections[@intFromEnum(which)];
    }

    /// Which selection `atom` names, if one we handle.
    fn selectionOf(self: *const @This(), atom: u32) ?SelectionIndex {
        for (self.selections, 0..) |owned, index| {
            if (owned.atom == atom) return @enumFromInt(index);
        }
        return null;
    }

    /// Store `text` and claim `which` for `owner`; the reader task serves it to other clients
    /// from then on, until a SelectionClear says somebody else copied. Texts above one
    /// request's worth are served through INCR.
    pub fn copy(self: *@This(), owner: u32, text: []const u8, which: common.Selection) !void {
        if (self.clipboard_conn == null) return error.ClipboardUnsupported;
        if (text.len > std.math.maxInt(u32)) return error.ClipboardUnsupported;

        const copied = try self.allocator.dupe(u8, text);
        {
            self.clipboard_mutex.lockUncancelable(self.io);
            defer self.clipboard_mutex.unlock(self.io);
            const owned = self.stateOf(SelectionIndex.of(which));
            if (owned.payload) |old| old.deinit(self.allocator);
            owned.payload = .{ .bytes = copied, .kind = .text };
            owned.owner = owner;
        }

        // CurrentTime, as SDL and GLFW do. ICCCM prefers the triggering event's time, but the
        // server ignores a claim older than the current owner's without saying so, and a copy
        // that is not answering an input event would then leave us believing we own a selection
        // we do not. CurrentTime always takes.
        try x11.send(self.io, self.conn, x11.proto.SetSelectionOwner{
            .owner = owner,
            .selection = self.stateOf(SelectionIndex.of(which)).atom,
        });
    }

    /// Forget the payload we were serving for `which`. `owner` limits it to a loss by that
    /// window: a SelectionClear for a window that already gave the selection up, or a window
    /// being destroyed while another one owns it, must not drop the live text.
    fn dropSelection(self: *@This(), io: std.Io, owner: u32, which: SelectionIndex) void {
        self.clipboard_mutex.lockUncancelable(io);
        defer self.clipboard_mutex.unlock(io);
        const owned = self.stateOf(which);
        if (owned.owner != owner) return;
        if (owned.payload) |payload| payload.deinit(self.allocator);
        owned.payload = null;
        owned.owner = 0;
    }

    /// XFixes reported a new CLIPBOARD owner. Our own claims are not news: the claiming window
    /// is recorded before SetSelectionOwner goes out, so it is already the owner on record when
    /// the server's notification comes back.
    fn mapSelectionOwnerChange(self: *@This(), notify: x11.xfixes.SelectionNotify) common.Event {
        if (notify.selection != self.atoms.clipboard or notify.subtype != .set_selection_owner) return .{ .nop = {} };
        self.clipboard_mutex.lockUncancelable(self.io);
        defer self.clipboard_mutex.unlock(self.io);
        const owned = self.stateOf(.clipboard);
        if (owned.owner != 0 and owned.owner == notify.owner) return .{ .nop = {} };
        return .{ .clipboard_changed = {} };
    }

    /// The selection's text as UTF-8, owned by the caller. Asks the owner to convert `which`
    /// into a property on `requestor` and waits for the reader task to fetch it, at most
    /// `paste_timeout` without progress. Our own text takes the same route.
    pub fn paste(self: *@This(), allocator: std.mem.Allocator, requestor: u32, which: common.Selection) ![]u8 {
        if (self.clipboard_conn == null) return error.ClipboardUnsupported;

        self.paste_mutex.lockUncancelable(self.io);
        defer self.paste_mutex.unlock(self.io);

        // No short-circuit to our own text: the server reports a lost selection with a
        // SelectionClear the reader task may not have seen yet, so the owner on record lags the
        // truth by a moment. Asking the server costs one round trip through our own serving path.
        // UTF8_STRING first; owners from before it refuse, and are asked for STRING instead.
        const atom = self.stateOf(SelectionIndex.of(which)).atom;
        return self.convertSelection(allocator, requestor, atom, self.atoms.utf8_string) catch |err| switch (err) {
            error.ClipboardEmpty => self.convertSelection(allocator, requestor, atom, self.atoms.string),
            else => err,
        };
    }

    /// One ConvertSelection round trip; see `paste`.
    fn convertSelection(self: *@This(), allocator: std.mem.Allocator, requestor: u32, selection_atom: u32, target: u32) ![]u8 {
        {
            self.clipboard_mutex.lockUncancelable(self.io);
            defer self.clipboard_mutex.unlock(self.io);
            if (self.paste_result) |old| self.allocator.free(old);
            self.paste_result = null;
            self.paste_error = null;
            self.paste_pending = true;
            self.paste_generation +%= 1;
            self.paste_requestor = requestor;
            self.paste_progress = 0;
            // No wait is pending: paste_mutex serialized the previous one to completion.
            self.paste_ready.reset();
        }

        // CurrentTime again: an owner may refuse a request timed before its claim, and a stale
        // input time would be.
        try x11.send(self.io, self.conn, x11.proto.ConvertSelection{
            .requestor = requestor,
            .selection = selection_atom,
            .target = target,
            .property = self.atoms.mir_clipboard,
        });

        // An INCR owner delivers in chunks; the deadline restarts with each one, so a long text
        // from a responsive owner is not cut off at one second.
        var seen_progress: u32 = 0;
        while (true) {
            self.paste_ready.waitTimeout(self.io, paste_timeout) catch |err| switch (err) {
                error.Timeout => {
                    self.clipboard_mutex.lockUncancelable(self.io);
                    defer self.clipboard_mutex.unlock(self.io);
                    if (self.paste_progress != seen_progress) {
                        seen_progress = self.paste_progress;
                        continue;
                    }
                    self.paste_pending = false;
                    return error.ClipboardTimeout;
                },
                error.Canceled => return err,
            };
            break;
        }

        self.clipboard_mutex.lockUncancelable(self.io);
        defer self.clipboard_mutex.unlock(self.io);
        if (self.paste_error) |failure| return failure;
        const text = self.paste_result orelse return error.ClipboardEmpty;
        defer {
            self.allocator.free(text);
            self.paste_result = null;
        }
        return allocator.dupe(u8, text);
    }

    /// Send a request on `clipboard_conn` and return the sequence number its reply or error
    /// will quote. Reader task only.
    fn sendClipboard(self: *@This(), io: std.Io, request: anytype, extra_bytes: ?[]const u8) !u16 {
        const conn = self.clipboard_conn orelse return error.ClipboardUnsupported;
        if (extra_bytes) |bytes| {
            try x11.sendWithBytes(io, conn, request, bytes);
        } else {
            try x11.send(io, conn, request);
        }
        self.clipboard_sequence +%= 1;
        return self.clipboard_sequence;
    }

    /// Answer a client's request for one of our selections. Runs on the reader task; the
    /// property write and the notify go out on `clipboard_conn`, since the requestor's window
    /// belongs to another client and any connection may write to it. A text too long for one
    /// request is handed to an `IncrSend` task, which answers the request itself.
    fn serveSelection(self: *@This(), io: std.Io, request: x11.proto.SelectionRequest) !void {
        // A copy, so the lock is not held while writing to the socket.
        const served: ?x11_drag.Payload = blk: {
            self.clipboard_mutex.lockUncancelable(io);
            defer self.clipboard_mutex.unlock(io);
            const which = self.selectionOf(request.selection) orelse break :blk null;
            const owned = self.stateOf(which);
            if (owned.owner == 0) break :blk null;
            const payload = owned.payload orelse break :blk null;
            break :blk .{ .bytes = try self.allocator.dupe(u8, payload.bytes), .kind = payload.kind };
        };
        var served_owned = served != null;
        defer if (served_owned) served.?.deinit(self.allocator);

        // Pre-ICCCM requestors pass no property; the target names it then.
        var property: u32 = if (request.property != 0) request.property else request.target;
        const atoms = self.atoms;
        if (served) |payload| {
            if (request.target == atoms.targets) {
                var buffer: [7]u32 = undefined;
                const list = x11_drag.targetList(payload.kind, self.typeAtoms(), &buffer);
                _ = try self.sendClipboard(io, x11.proto.ChangeProperty{
                    .window_id = request.requestor,
                    .property = property,
                    .property_type = atoms.atom,
                    .format = 32,
                    .length_of_data = @intCast(list.len),
                }, std.mem.sliceAsBytes(list));
            } else if (x11_drag.servedType(payload.kind, request.target, self.typeAtoms())) |property_type| {
                // STRING is Latin-1 by the book, but every toolkit answers it with the UTF-8
                // bytes, and so do we.
                const text = payload.bytes;
                if (text.len > maxPropertyBytes(self.info)) {
                    if (self.startIncrSend(io, request, property, property_type, text)) {
                        served_owned = false; // the task owns the text now
                        return;
                    }
                    property = 0;
                } else {
                    _ = try self.sendClipboard(io, x11.proto.ChangeProperty{
                        .window_id = request.requestor,
                        .property = property,
                        .property_type = property_type,
                        .format = 8,
                        .length_of_data = @intCast(text.len),
                    }, text);
                }
            } else {
                property = 0;
            }
        } else {
            property = 0;
        }

        const notify = x11.proto.SelectionNotify{
            .time = request.time,
            .requestor = request.requestor,
            .selection = request.selection,
            .target = request.target,
            .property = property,
        };
        _ = try self.sendClipboard(io, x11.proto.SendEvent{
            .destination = request.requestor,
            .event_mask = 0,
            .event = std.mem.toBytes(notify),
        }, null);
    }

    /// Hand `text` to a task that transfers it to the requestor with INCR; returns false when
    /// no task could be started, in which case the caller still owns `text` and refuses the
    /// request. Reader task only.
    fn startIncrSend(self: *@This(), io: std.Io, request: x11.proto.SelectionRequest, property: u32, property_type: u32, text: []u8) bool {
        self.reapIncrSends(.finished);
        const task = self.allocator.create(IncrSend) catch return false;
        task.* = .{
            .environ = self.environ,
            .allocator = self.allocator,
            .request = request,
            .property = property,
            .property_type = property_type,
            .incr_atom = self.atoms.incr,
            .text = text,
        };
        task.future = io.concurrent(IncrSend.run, .{ task, io }) catch |err| {
            log.warn("INCR transfer task unavailable ({any}); refusing the request", .{err});
            self.allocator.destroy(task);
            return false;
        };
        self.incr_sends.append(self.allocator, task) catch {
            task.future.?.await(io);
            self.allocator.destroy(task);
        };
        return true;
    }

    /// Retire INCR send tasks: the finished ones, or all of them (canceling the rest) at
    /// deinit. Reader task only.
    fn reapIncrSends(self: *@This(), which: enum { finished, cancel }) void {
        var index = self.incr_sends.items.len;
        while (index > 0) {
            index -= 1;
            const task = self.incr_sends.items[index];
            switch (which) {
                .finished => if (!task.done.load(.acquire)) continue,
                .cancel => {},
            }
            if (task.future) |*future| {
                switch (which) {
                    .finished => future.await(self.io),
                    .cancel => future.cancel(self.io),
                }
            }
            _ = self.incr_sends.swapRemove(index);
            self.allocator.free(task.text);
            self.allocator.destroy(task);
        }
    }

    const PasteOutcome = union(enum) { text: []u8, failure: common.ClipboardError };

    /// The owner answered a ConvertSelection: fetch the property it wrote and hand the text to
    /// the waiting `paste`, or begin collecting an INCR transfer. Runs on the reader task.
    fn finishPaste(self: *@This(), io: std.Io, notify: x11.proto.SelectionNotify) void {
        const generation = blk: {
            self.clipboard_mutex.lockUncancelable(io);
            defer self.clipboard_mutex.unlock(io);
            // Not the paste we are waiting for: one that already timed out, or somebody else's.
            if (!self.paste_pending or notify.requestor != self.paste_requestor) return;
            if (notify.property != 0 and notify.property != self.atoms.mir_clipboard) return;
            break :blk self.paste_generation;
        };
        // A transfer left over from a paste that gave up has nothing to deliver to.
        self.dropIncrPaste();
        if (notify.property == 0) {
            self.deliverPaste(io, generation, .{ .failure = error.ClipboardEmpty });
            return;
        }
        const fetched = self.fetchPasteProperty(io, notify, generation) catch |err| blk: {
            log.warn("Failed to fetch the pasted property: {any}", .{err});
            break :blk PasteOutcome{ .failure = error.ClipboardEmpty };
        };
        const outcome = fetched orelse return; // an INCR transfer has begun
        self.deliverPaste(io, generation, outcome);
    }

    /// Read the property the owner wrote. An INCR property holds the total size of a transfer
    /// to come; deleting it tells the owner to start, and the chunks arrive through
    /// `continueIncrPaste`, so this returns null and leaves `incr_paste` waiting for them.
    fn fetchPasteProperty(self: *@This(), io: std.Io, notify: x11.proto.SelectionNotify, generation: u32) !?PasteOutcome {
        var property = try self.readProperty(io, notify.requestor, notify.property, true);
        defer property.value.deinit(self.allocator);

        if (property.property_type == self.atoms.incr) {
            self.incr_paste = .{
                .kind = .paste,
                .generation = generation,
                .requestor = notify.requestor,
                .property = notify.property,
                .string = false,
            };
            return null;
        }
        if (property.property_type == 0 or property.format != 8) return .{ .failure = error.ClipboardEmpty };

        const text = if (property.property_type == self.atoms.string)
            try latin1ToUtf8(self.allocator, property.value.items)
        else
            try property.value.toOwnedSlice(self.allocator);
        return .{ .text = text };
    }

    /// An INCR owner wrote the next chunk into the paste (or drop) property, or the empty one
    /// that ends the transfer. Runs on the reader task; a completed drop is the event.
    fn continueIncrPaste(self: *@This(), io: std.Io, notify: x11.proto.PropertyNotify) common.Event {
        if (self.incr_paste == null) return .{ .nop = {} };
        const incr = &self.incr_paste.?;
        if (notify.window_id != incr.requestor or notify.atom != incr.property or notify.state != .NewValue) return .{ .nop = {} };
        const generation = incr.generation;

        const stale = switch (incr.kind) {
            .paste => blk: {
                self.clipboard_mutex.lockUncancelable(io);
                defer self.clipboard_mutex.unlock(io);
                if (!self.paste_pending or self.paste_generation != generation) break :blk true;
                self.paste_progress +%= 1;
                break :blk false;
            },
            .drop => blk: {
                const target = &(self.drop_target orelse break :blk true);
                if (!target.awaiting_drop or target.timer_generation != generation) break :blk true;
                target.progress +%= 1;
                break :blk false;
            },
        };
        if (stale) {
            // The caller gave up; the owner will stop once we stop deleting the property.
            self.dropIncrPaste();
            return .{ .nop = {} };
        }

        const collected = self.collectIncrChunk(io, incr) catch |err| blk: {
            log.warn("Failed to collect an INCR chunk: {any}", .{err});
            break :blk PasteOutcome{ .failure = error.ClipboardEmpty };
        };
        const outcome = collected orelse return .{ .nop = {} }; // more chunks to come
        const kind = incr.kind;
        self.dropIncrPaste();
        switch (kind) {
            .paste => {
                self.deliverPaste(io, generation, outcome);
                return .{ .nop = {} };
            },
            .drop => switch (outcome) {
                .text => |bytes| {
                    defer self.allocator.free(bytes);
                    const data = self.decodeDrop(self.drop_target.?.chosen.?.kind, bytes) catch null;
                    return self.settleDrop(io, data);
                },
                .failure => return self.settleDrop(io, null),
            },
        }
    }

    /// Read the chunk the owner just wrote and append it; the empty chunk completes the text.
    fn collectIncrChunk(self: *@This(), io: std.Io, incr: *IncrPaste) !?PasteOutcome {
        var chunk = try self.readProperty(io, incr.requestor, incr.property, true);
        defer chunk.value.deinit(self.allocator);
        if (chunk.value.items.len == 0) {
            const text = if (incr.string)
                try latin1ToUtf8(self.allocator, incr.data.items)
            else
                try incr.data.toOwnedSlice(self.allocator);
            return .{ .text = text };
        }
        // The chunks name the text type; the INCR property itself did not.
        incr.string = chunk.property_type == self.atoms.string;
        try incr.data.appendSlice(self.allocator, chunk.value.items);
        return null;
    }

    fn dropIncrPaste(self: *@This()) void {
        if (self.incr_paste) |*incr| incr.data.deinit(self.allocator);
        self.incr_paste = null;
    }

    const Property = struct {
        property_type: u32,
        format: u8,
        value: std.ArrayList(u8),
    };

    /// GetProperty on `clipboard_conn`, the only connection a reply can be read on once the
    /// loop owns `conn`, in `property_read_bytes` pieces until the server has no more. With
    /// `delete` the property goes with the last piece: that is how a requestor tells an INCR
    /// owner it is ready for the next chunk, and every other owner just sees its property
    /// cleaned up. Another client's properties (a drag source's type list) are read intact.
    fn readProperty(self: *@This(), io: std.Io, window: u32, property: u32, delete: bool) !Property {
        const conn = self.clipboard_conn orelse return error.ClipboardUnsupported;
        var result: Property = .{ .property_type = 0, .format = 0, .value = .empty };
        errdefer result.value.deinit(self.allocator);

        var offset_units: u32 = 0;
        while (true) {
            const sequence = try self.sendClipboard(io, x11.proto.GetProperty{
                .window_id = window,
                .property = property,
                .property_type = 0, // AnyPropertyType
                .long_offset = offset_units,
                .long_length = property_read_bytes / 4,
                .delete = delete,
            }, null);
            const reply = try self.readClipboardReply(io, sequence);
            const header = reply.as(x11.proto.GetPropertyReply);

            const extra = try self.allocator.alloc(u8, reply.extraLength());
            defer self.allocator.free(extra);
            try x11.receiveBytes(io, conn, extra);

            result.property_type = header.property_type;
            result.format = header.format;
            if (header.property_type == 0) return result;
            const unit: usize = @max(1, @as(usize, header.format) / 8);
            const bytes = @min(@as(usize, header.value_len) * unit, extra.len);
            try result.value.appendSlice(self.allocator, extra[0..bytes]);
            if (header.bytes_after == 0) return result;
            offset_units += @intCast(bytes / 4);
        }
    }

    /// Read `clipboard_conn` until the reply to request `sequence`. Errors from earlier
    /// requests (a requestor that vanished mid-transfer) sit in the socket until now, since
    /// nothing reads this connection between pastes; they are logged and skipped.
    fn readClipboardReply(self: *@This(), io: std.Io, sequence: u16) !x11.proto.Reply {
        const conn = self.clipboard_conn orelse return error.ClipboardUnsupported;
        while (true) {
            const message = try x11.receive(io, conn, .none) orelse continue;
            switch (message) {
                .Reply => |reply| {
                    if (reply.sequence_number == sequence) return reply;
                    try skipBytes(io, conn, reply.extraLength());
                },
                .ErrorMessage => |failure| {
                    if (failure.sequence_number == sequence) return error.RequestFailed;
                    log.debug("Stale X11 error on the clipboard connection: {any}", .{failure.error_code});
                },
                // No windows on this connection, so no events are expected.
                else => {},
            }
        }
    }

    fn deliverPaste(self: *@This(), io: std.Io, generation: u32, outcome: PasteOutcome) void {
        self.clipboard_mutex.lockUncancelable(io);
        defer self.clipboard_mutex.unlock(io);
        if (!self.paste_pending or self.paste_generation != generation) {
            // The caller gave up while we were fetching.
            if (outcome == .text) self.allocator.free(outcome.text);
            return;
        }
        switch (outcome) {
            .text => |text| self.paste_result = text,
            .failure => |failure| self.paste_error = failure,
        }
        self.paste_pending = false;
        self.paste_ready.set(io);
    }

    // Drag and drop. Both state machines run on the reader task and send every XDND message
    // on the side connection, so the main one keeps its single writer; callers only set
    // properties, claim the selection and hand a drag over. See x11_drag.zig.

    fn typeAtoms(self: *const @This()) x11_drag.TypeAtoms {
        return .{
            .targets = self.atoms.targets,
            .uri_list = self.atoms.mime_uri_list,
            .mime_utf8 = self.atoms.mime_utf8,
            .utf8_string = self.atoms.utf8_string,
            .mime_text_plain = self.atoms.mime_text_plain,
            .text = self.atoms.text,
            .string = self.atoms.string,
        };
    }

    /// Take drops of `kinds` on `window`: XdndAware on the window is what sources look for
    /// when they walk down from the root, and the kinds decide what is accepted.
    pub fn setDropTarget(self: *@This(), window: u32, kinds: common.DropKinds) common.DragError!void {
        if (self.clipboard_conn == null) return error.DragUnsupported;
        {
            self.clipboard_mutex.lockUncancelable(self.io);
            defer self.clipboard_mutex.unlock(self.io);
            if (kinds.any()) {
                self.drop_kinds.put(self.allocator, window, kinds) catch return error.OutOfMemory;
            } else {
                _ = self.drop_kinds.remove(window);
            }
        }
        if (kinds.any()) {
            const version: u32 = x11.xdnd.version;
            x11.sendWithBytes(self.io, self.conn, x11.proto.ChangeProperty{
                .window_id = window,
                .property = self.atoms.xdnd_aware,
                .property_type = self.atoms.atom,
                .format = 32,
                .length_of_data = 1,
            }, std.mem.asBytes(&version)) catch return error.DragUnsupported;
        } else {
            x11.send(self.io, self.conn, x11.proto.DeleteProperty{
                .window_id = window,
                .property = self.atoms.xdnd_aware,
            }) catch return error.DragUnsupported;
        }
    }

    /// The newest drop's payload, copied into `allocator`; the stored one is freed.
    pub fn takeDrop(self: *@This(), allocator: std.mem.Allocator) (common.DropError || std.mem.Allocator.Error)!common.DropData {
        self.clipboard_mutex.lockUncancelable(self.io);
        defer self.clipboard_mutex.unlock(self.io);
        const stored = self.pending_drop orelse return error.NoDrop;
        self.pending_drop = null;
        defer stored.deinit(self.allocator);
        return stored.dupe(allocator);
    }

    fn dropKindsOf(self: *@This(), window: u32) common.DropKinds {
        self.clipboard_mutex.lockUncancelable(self.io);
        defer self.clipboard_mutex.unlock(self.io);
        return self.drop_kinds.get(window) orelse .{};
    }

    /// Start a drag of `data` from `window`, on the caller's thread: claim XdndSelection with
    /// the payload, publish the type list, hand the drag to the reader task with a control
    /// message on the main connection, and start the task that grabs the pointer. Everything
    /// after that happens on the reader task and ends in `drag_finished`.
    pub fn startDrag(self: *@This(), window: u32, data: common.DragData) common.DragError!void {
        if (self.clipboard_conn == null) return error.DragUnsupported;
        const kind: common.DropKind = data;
        const bytes: []u8 = switch (data) {
            .text => |text| self.allocator.dupe(u8, text),
            .files => |paths| uri_list.format(self.allocator, paths),
        } catch return error.OutOfMemory;
        var bytes_owned = true;
        defer if (bytes_owned) self.allocator.free(bytes);
        if (bytes.len > std.math.maxInt(u32)) return error.DragUnsupported;

        var types_buffer: [6]u32 = undefined;
        const types = x11_drag.offeredTypes(kind, self.typeAtoms(), &types_buffer);
        var request: x11_drag.DragSource = .{ .window = window, .kind = kind, .types = .{0} ** 6, .type_count = @intCast(types.len), .grab = null };
        @memcpy(request.types[0..types.len], types);
        {
            self.clipboard_mutex.lockUncancelable(self.io);
            defer self.clipboard_mutex.unlock(self.io);
            if (self.drag_active) return error.DragInProgress;
            self.drag_active = true;
            const owned = self.stateOf(.drag);
            if (owned.payload) |old| old.deinit(self.allocator);
            owned.payload = .{ .bytes = bytes, .kind = kind };
            owned.owner = window;
            bytes_owned = false;
            self.drag_request = request;
        }
        errdefer self.abandonDrag(window);

        const grab = self.allocator.create(x11_drag.PointerGrab) catch return error.OutOfMemory;
        grab.* = .{ .environ = self.environ, .allocator = self.allocator, .window = window, .control_atom = self.atoms.mir_drag_control };
        grab.future = self.io.concurrent(x11_drag.PointerGrab.run, .{ grab, self.io }) catch |err| {
            log.warn("Pointer grab task unavailable ({any}); no drag", .{err});
            self.allocator.destroy(grab);
            return error.DragUnsupported;
        };
        {
            // The reader task cannot have taken the request yet: the start message goes out below.
            self.clipboard_mutex.lockUncancelable(self.io);
            defer self.clipboard_mutex.unlock(self.io);
            self.drag_request.?.grab = grab;
        }

        // CurrentTime, as the clipboard claims.
        x11.send(self.io, self.conn, x11.proto.SetSelectionOwner{
            .owner = window,
            .selection = self.atoms.xdnd_selection,
        }) catch return error.DragUnsupported;
        x11.sendWithBytes(self.io, self.conn, x11.proto.ChangeProperty{
            .window_id = window,
            .property = self.atoms.xdnd_type_list,
            .property_type = self.atoms.atom,
            .format = 32,
            .length_of_data = @intCast(types.len),
        }, std.mem.sliceAsBytes(types)) catch return error.DragUnsupported;
        x11_drag.sendControl(self.io, self.conn, window, self.atoms.mir_drag_control, .started, 0) catch return error.DragUnsupported;
    }

    /// Undo a `startDrag` that failed partway, on the caller's thread.
    fn abandonDrag(self: *@This(), window: u32) void {
        const request = blk: {
            self.clipboard_mutex.lockUncancelable(self.io);
            defer self.clipboard_mutex.unlock(self.io);
            self.drag_active = false;
            const owned = self.stateOf(.drag);
            if (owned.owner == window) {
                if (owned.payload) |payload| payload.deinit(self.allocator);
                owned.payload = null;
                owned.owner = 0;
            }
            const request = self.drag_request;
            self.drag_request = null;
            break :blk request;
        };
        if (request) |taken| self.releasePointerGrab(taken.grab);
        x11.send(self.io, self.conn, x11.proto.SetSelectionOwner{ .owner = 0, .selection = self.atoms.xdnd_selection }) catch {};
    }

    /// End the grab task (which drops its connection, and with it the grab) and free it.
    fn releasePointerGrab(self: *@This(), task: ?*x11_drag.PointerGrab) void {
        const grab = task orelse return;
        if (grab.future) |*future| future.cancel(self.io);
        self.allocator.destroy(grab);
    }

    /// Send an XDND ClientMessage to `destination` from the side connection; with an empty mask
    /// it reaches the client that created the window, whoever that is.
    fn sendXdnd(self: *@This(), io: std.Io, destination: u32, message_type: u32, data: [5]u32) void {
        const event = x11.proto.ClientMessageEvent{ .window_id = destination, .message_type = message_type, .data = data };
        _ = self.sendClipboard(io, x11.proto.SendEvent{
            .destination = destination,
            .event_mask = 0,
            .event = std.mem.toBytes(event),
        }, null) catch |err| log.warn("Failed to send an XDND message: {any}", .{err});
    }

    /// TranslateCoordinates on the side connection.
    fn translate(self: *@This(), io: std.Io, source_window: u32, destination_window: u32, x: i16, y: i16) !x11.proto.TranslateCoordinatesReply {
        const sequence = try self.sendClipboard(io, x11.proto.TranslateCoordinates{ .src_window = source_window, .dst_window = destination_window, .src_x = x, .src_y = y }, null);
        const reply = try self.readClipboardReply(io, sequence);
        return reply.as(x11.proto.TranslateCoordinatesReply);
    }

    /// The first long of a 32-bit property on another client's window, or null when it has none
    /// (or the window is gone).
    fn readWindowProperty(self: *@This(), io: std.Io, window: u32, atom: u32) ?u32 {
        var property = self.readProperty(io, window, atom, false) catch return null;
        defer property.value.deinit(self.allocator);
        if (property.property_type == 0 or property.format != 32 or property.value.items.len < 4) return null;
        return std.mem.readInt(u32, property.value.items[0..4], native_endian);
    }

    /// A source's XdndTypeList, owned by the caller; null when it has none readable.
    fn readTypeList(self: *@This(), io: std.Io, source: u32) ?[]u32 {
        var property = self.readProperty(io, source, self.atoms.xdnd_type_list, false) catch |err| {
            log.debug("XdndTypeList of window 0x{x} could not be read: {any}", .{ source, err });
            return null;
        };
        defer property.value.deinit(self.allocator);
        if (property.property_type != self.atoms.atom or property.format != 32) return null;
        return atomsFromBytes(self.allocator, property.value.items) catch null;
    }

    /// Start a `Timer` that reports to `window` after `duration`; the generation it will carry.
    /// Reader task only.
    fn startTimer(self: *@This(), io: std.Io, window: u32, duration: std.Io.Duration) u32 {
        self.reapTimers(.finished);
        self.timer_generation +%= 1;
        const generation = self.timer_generation;
        const task = self.allocator.create(x11_drag.Timer) catch return generation;
        task.* = .{
            .environ = self.environ,
            .allocator = self.allocator,
            .window = window,
            .control_atom = self.atoms.mir_drag_control,
            .generation = generation,
            .duration = duration,
        };
        task.future = io.concurrent(x11_drag.Timer.run, .{ task, io }) catch |err| {
            log.warn("Drag timer task unavailable ({any}); this wait has no deadline", .{err});
            self.allocator.destroy(task);
            return generation;
        };
        self.drag_timers.append(self.allocator, task) catch {
            task.future.?.cancel(io);
            self.allocator.destroy(task);
        };
        return generation;
    }

    /// Retire timer tasks: the finished ones, or all of them (canceling the rest) at deinit.
    fn reapTimers(self: *@This(), which: enum { finished, cancel }) void {
        var index = self.drag_timers.items.len;
        while (index > 0) {
            index -= 1;
            const task = self.drag_timers.items[index];
            switch (which) {
                .finished => if (!task.done.load(.acquire)) continue,
                .cancel => {},
            }
            if (task.future) |*future| {
                switch (which) {
                    .finished => future.await(self.io),
                    .cancel => future.cancel(self.io),
                }
            }
            _ = self.drag_timers.swapRemove(index);
            self.allocator.destroy(task);
        }
    }

    /// Forget an INCR transfer that was a drop's; a paste's is left alone.
    fn abandonDropIncr(self: *@This()) void {
        const incr = self.incr_paste orelse return;
        if (incr.kind == .drop) self.dropIncrPaste();
    }

    // The drop target: a drag from another client (or our own) over one of our windows.

    /// XdndEnter: rank what the source offers against what the window takes. Nothing is
    /// emitted yet; the first position carries the pointer and becomes `drag_enter`.
    fn xdndEnter(self: *@This(), io: std.Io, window: u32, enter: x11.xdnd.Enter) common.Event {
        // Before version 3 there is no type list and no action.
        if (enter.version < 3) return .{ .nop = {} };
        // A drag already over one of our windows ends there first: its XdndLeave never came.
        if (self.drop_target) |old| {
            if (old.entered) self.queued.push(.{ .drag_leave = old.window });
            self.abandonDropIncr();
        }
        var target: x11_drag.DropTarget = .{
            .source = enter.source,
            .version = @min(x11.xdnd.version, enter.version),
            .window = window,
            .chosen = null,
        };
        const kinds = self.dropKindsOf(window);
        if (kinds.any()) {
            const atoms = self.typeAtoms();
            const list: ?[]u32 = if (enter.more_types) self.readTypeList(io, enter.source) else null;
            defer if (list) |owned| self.allocator.free(owned);
            target.chosen = x11_drag.rankTypes(list orelse &enter.types, kinds, atoms);
        }
        self.drop_target = target;
        return .{ .nop = {} };
    }

    /// XdndPosition: answer with XdndStatus and report the pointer. Every position is asked
    /// for (an empty rectangle) so `drag_motion` follows the pointer.
    fn xdndPosition(self: *@This(), io: std.Io, window: u32, position: x11.xdnd.Position) common.Event {
        const target = &(self.drop_target orelse return .{ .nop = {} });
        if (target.window != window or target.source != position.source or target.awaiting_drop) return .{ .nop = {} };
        if (!target.origin_valid) self.refreshOrigin(io, target);
        target.x = clampCoordinate(@as(i32, position.root_x) - target.origin_x);
        target.y = clampCoordinate(@as(i32, position.root_y) - target.origin_y);

        const accept = target.chosen != null;
        self.sendXdnd(io, target.source, self.atoms.xdnd_status, (x11.xdnd.Status{
            .target = window,
            .accept = accept,
            .send_every_position = true,
            .rect = .{},
            .action = if (accept) self.atoms.xdnd_action_copy else 0,
        }).pack());
        if (!accept) return .{ .nop = {} };
        if (!target.entered) {
            target.entered = true;
            return .{ .drag_enter = .{ .x = target.x, .y = target.y, .kind = target.chosen.?.kind, .window_id = window } };
        }
        return .{ .drag_motion = .{ .x = target.x, .y = target.y, .window_id = window } };
    }

    /// Our window's root origin, which turns the positions' root coordinates into window ones.
    fn refreshOrigin(self: *@This(), io: std.Io, target: *x11_drag.DropTarget) void {
        const reply = self.translate(io, target.window, self.info.screens[0].root, 0, 0) catch |err| {
            log.debug("The drop target's origin could not be read: {any}", .{err});
            return;
        };
        target.origin_x = reply.dst_x;
        target.origin_y = reply.dst_y;
        target.origin_valid = true;
    }

    fn xdndLeave(self: *@This(), window: u32, leave: x11.xdnd.Leave) common.Event {
        const target = self.drop_target orelse return .{ .nop = {} };
        if (target.window != window or target.source != leave.source) return .{ .nop = {} };
        // A leave after the drop is a confused source; the fetch decides the drop.
        if (target.awaiting_drop) return .{ .nop = {} };
        self.drop_target = null;
        return if (target.entered) .{ .drag_leave = window } else .{ .nop = {} };
    }

    /// XdndDrop: fetch the payload as the paste does, with a deadline on the source.
    fn xdndDrop(self: *@This(), io: std.Io, window: u32, drop: x11.xdnd.Drop) common.Event {
        const target = &(self.drop_target orelse return .{ .nop = {} });
        if (target.window != window or target.source != drop.source or target.awaiting_drop) return .{ .nop = {} };
        const chosen = target.chosen orelse return self.settleDrop(io, null);
        // From the side connection: with an owner, the answer is the owner's SendEvent to our
        // window, which reaches this task; without one, the server's answer goes to the
        // requesting connection, where it is dropped, and the timer refuses the drop.
        _ = self.sendClipboard(io, x11.proto.ConvertSelection{
            .requestor = window,
            .selection = self.atoms.xdnd_selection,
            .target = chosen.atom,
            .property = self.atoms.mir_drop,
            .time = drop.time,
        }, null) catch |err| {
            log.warn("ConvertSelection for a drop failed: {any}", .{err});
            return self.settleDrop(io, null);
        };
        target.awaiting_drop = true;
        target.progress = 0;
        target.progress_at_timer = 0;
        target.timer_generation = self.startTimer(io, window, drop_fetch_timeout);
        return .{ .nop = {} };
    }

    /// The source answered the ConvertSelection of a drop.
    fn finishDrop(self: *@This(), io: std.Io, notify: x11.proto.SelectionNotify) common.Event {
        const target = &(self.drop_target orelse return .{ .nop = {} });
        if (!target.awaiting_drop or notify.requestor != target.window) return .{ .nop = {} };
        if (notify.property != 0 and notify.property != self.atoms.mir_drop) return .{ .nop = {} };
        if (notify.property == 0) return self.settleDrop(io, null);
        const fetched = self.fetchDropProperty(io, target) catch |err| blk: {
            log.warn("Failed to fetch a drop's property: {any}", .{err});
            break :blk DropFetch{ .data = null };
        };
        return switch (fetched) {
            .incr => .{ .nop = {} },
            .data => |data| self.settleDrop(io, data),
        };
    }

    const DropFetch = union(enum) { incr, data: ?common.DropData };

    /// Read the drop's property: an INCR transfer begins and completes through
    /// `continueIncrPaste`; anything else decodes now.
    fn fetchDropProperty(self: *@This(), io: std.Io, target: *x11_drag.DropTarget) !DropFetch {
        var property = try self.readProperty(io, target.window, self.atoms.mir_drop, true);
        defer property.value.deinit(self.allocator);
        if (property.property_type == self.atoms.incr) {
            self.dropIncrPaste();
            self.incr_paste = .{
                .kind = .drop,
                .generation = target.timer_generation,
                .requestor = target.window,
                .property = self.atoms.mir_drop,
                .string = false,
            };
            return .incr;
        }
        if (property.property_type == 0 or property.format != 8) return .{ .data = null };
        const kind = target.chosen.?.kind;
        if (kind == .text and property.property_type == self.atoms.string) {
            return .{ .data = .{ .text = try latin1ToUtf8(self.allocator, property.value.items) } };
        }
        return .{ .data = try self.decodeDrop(kind, property.value.items) };
    }

    /// The payload UTF-8 `bytes` make as `kind`; null for a uri-list naming no local file.
    fn decodeDrop(self: *@This(), kind: common.DropKind, bytes: []const u8) std.mem.Allocator.Error!?common.DropData {
        switch (kind) {
            .text => return .{ .text = try self.allocator.dupe(u8, bytes) },
            .files => {
                const paths = try uri_list.parse(self.allocator, bytes);
                if (paths.len == 0) {
                    uri_list.free(self.allocator, paths);
                    return null;
                }
                return .{ .files = paths };
            },
        }
    }

    /// End the drop: XdndFinished to the source, and either the payload stored for `takeDrop`
    /// with a `drop` event, or a `drag_leave` when nothing usable came.
    fn settleDrop(self: *@This(), io: std.Io, data: ?common.DropData) common.Event {
        const target = self.drop_target.?;
        self.drop_target = null;
        self.abandonDropIncr();
        const accepted = data != null;
        self.sendXdnd(io, target.source, self.atoms.xdnd_finished, (x11.xdnd.Finished{
            .target = target.window,
            .accepted = accepted,
            .action = if (accepted) self.atoms.xdnd_action_copy else 0,
        }).pack());
        if (data) |payload| {
            self.clipboard_mutex.lockUncancelable(io);
            defer self.clipboard_mutex.unlock(io);
            if (self.pending_drop) |old| old.deinit(self.allocator);
            self.pending_drop = payload;
            return .{ .drop = .{ .x = target.x, .y = target.y, .kind = target.chosen.?.kind, .window_id = target.window } };
        }
        return if (target.entered) .{ .drag_leave = target.window } else .{ .nop = {} };
    }

    // The drag source: a drag of ours, from the start message until drag_finished.

    /// A MIR_DRAG_CONTROL message to one of our windows.
    fn dragControl(self: *@This(), io: std.Io, window: u32, code: x11_drag.Control, generation: u32) common.Event {
        switch (code) {
            .timeout => {
                if (self.drop_target) |*target| {
                    if (target.awaiting_drop and target.timer_generation == generation) {
                        // An INCR source still sending is not silent; wait once more.
                        if (target.progress != target.progress_at_timer) {
                            target.progress_at_timer = target.progress;
                            target.timer_generation = self.startTimer(io, window, drop_fetch_timeout);
                            return .{ .nop = {} };
                        }
                        _ = self.sendClipboard(io, x11.proto.DeleteProperty{ .window_id = window, .property = self.atoms.mir_drop }, null) catch {};
                        return self.settleDrop(io, null);
                    }
                }
                if (self.drag_source) |drag| {
                    if (drag.timer_generation == generation) return self.dragTimeout(io);
                }
                return .{ .nop = {} };
            },
            .grab_failed => {
                if (self.drag_source) |drag| {
                    if (drag.window == window) return self.finishDrag(io, false);
                }
                return .{ .nop = {} };
            },
            .started => return self.dragStarted(),
            _ => return .{ .nop = {} },
        }
    }

    /// Take the drag `startDrag` set up.
    fn dragStarted(self: *@This()) common.Event {
        self.clipboard_mutex.lockUncancelable(self.io);
        defer self.clipboard_mutex.unlock(self.io);
        const request = self.drag_request orelse return .{ .nop = {} };
        self.drag_request = null;
        self.drag_source = request;
        return .{ .nop = {} };
    }

    /// The pointer moved during a drag of ours (forwarded by the grab task, in root
    /// coordinates): find the target under it and send the position, one in flight at a time.
    fn dragMotion(self: *@This(), io: std.Io, position: x11_drag.Position) common.Event {
        const drag = &self.drag_source.?;
        if (drag.state != .dragging or drag.release != null) return .{ .nop = {} };
        self.locateTarget(io, drag, position.root_x, position.root_y);
        if (drag.target == null) return .{ .nop = {} };
        if (drag.gate.offer(position)) |now| self.sendPosition(io, drag, now);
        return .{ .nop = {} };
    }

    /// The XDND-aware window under the pointer. One round trip finds the toplevel; the walk
    /// down through it runs once per toplevel entered, the way GTK and Qt do it.
    fn locateTarget(self: *@This(), io: std.Io, drag: *x11_drag.DragSource, root_x: i16, root_y: i16) void {
        const root = self.info.screens[0].root;
        const translated = self.translate(io, root, root, root_x, root_y) catch |err| {
            log.debug("The toplevel under the pointer could not be found: {any}", .{err});
            self.changeTarget(io, drag, 0, null);
            return;
        };
        const frame = translated.child;
        if (drag.frame_valid and frame == drag.frame) return;
        const target = if (frame != 0) self.walkToAware(io, frame, root_x, root_y) else null;
        self.changeTarget(io, drag, frame, target);
    }

    /// Descend from `toplevel` to the window under the point that has XdndAware, honouring an
    /// XdndProxy on the way (the proxy gets the messages, and its XdndAware is the one that
    /// counts).
    fn walkToAware(self: *@This(), io: std.Io, toplevel: u32, root_x: i16, root_y: i16) ?x11_drag.DragSource.Target {
        const root = self.info.screens[0].root;
        var window = toplevel;
        // Bounded: no window tree is this deep, and a proxy loop must not hang the reader task.
        for (0..max_walk_depth) |_| {
            const aware_window = self.readWindowProperty(io, window, self.atoms.xdnd_proxy) orelse window;
            if (self.readWindowProperty(io, aware_window, self.atoms.xdnd_aware)) |version| {
                if (version >= 3) return .{ .window = aware_window, .version = @intCast(@min(x11.xdnd.version, version)) };
            }
            const translated = self.translate(io, root, window, root_x, root_y) catch return null;
            if (translated.child == 0) return null;
            window = translated.child;
        }
        return null;
    }

    /// Move the drag to `target` (or to nothing): XdndLeave to the old one, XdndEnter to the new.
    fn changeTarget(self: *@This(), io: std.Io, drag: *x11_drag.DragSource, frame: u32, target: ?x11_drag.DragSource.Target) void {
        drag.frame = frame;
        drag.frame_valid = true;
        const same = if (drag.target) |old| target != null and old.window == target.?.window else target == null;
        if (same) return;
        if (drag.target) |old| {
            self.sendXdnd(io, old.window, self.atoms.xdnd_leave, (x11.xdnd.Leave{ .source = drag.window }).pack());
        }
        drag.target = target;
        drag.gate.reset();
        drag.accepted = null;
        if (target) |entered| {
            self.sendXdnd(io, entered.window, self.atoms.xdnd_enter, (x11.xdnd.Enter{
                .source = drag.window,
                .version = entered.version,
                .more_types = true,
                .types = drag.enterTypes(),
            }).pack());
        }
    }

    fn sendPosition(self: *@This(), io: std.Io, drag: *x11_drag.DragSource, position: x11_drag.Position) void {
        const target = drag.target orelse return;
        self.sendXdnd(io, target.window, self.atoms.xdnd_position, (x11.xdnd.Position{
            .source = drag.window,
            .root_x = position.root_x,
            .root_y = position.root_y,
            .time = position.time,
            .action = self.atoms.xdnd_action_copy,
        }).pack());
    }

    /// XdndStatus from the current target: record the verdict, send the position that waited,
    /// and settle a release that was waiting on it.
    fn dragStatus(self: *@This(), io: std.Io, window: u32, status: x11.xdnd.Status) common.Event {
        const drag = &(self.drag_source orelse return .{ .nop = {} });
        if (drag.window != window) return .{ .nop = {} };
        const target = drag.target orelse return .{ .nop = {} };
        if (status.target != target.window) return .{ .nop = {} };
        drag.accepted = status.accept;
        if (drag.gate.statusArrived()) |pending| {
            self.sendPosition(io, drag, pending);
            return .{ .nop = {} };
        }
        if (drag.state == .dragging) {
            if (drag.release) |time| return self.settleRelease(io, drag, time);
        }
        return .{ .nop = {} };
    }

    /// The button came up: drop on a target that accepted, once no position is outstanding.
    fn dragRelease(self: *@This(), io: std.Io, time: u32) common.Event {
        const drag = &self.drag_source.?;
        if (drag.state != .dragging or drag.release != null) return .{ .nop = {} };
        drag.release = time;
        if (drag.target != null and drag.gate.outstanding) {
            // The target's verdict on the last position decides; a silent target is a refusal.
            drag.timer_generation = self.startTimer(io, drag.window, drag_status_timeout);
            return .{ .nop = {} };
        }
        return self.settleRelease(io, drag, time);
    }

    fn settleRelease(self: *@This(), io: std.Io, drag: *x11_drag.DragSource, time: u32) common.Event {
        if (drag.target) |target| {
            if (drag.accepted == true) {
                self.sendXdnd(io, target.window, self.atoms.xdnd_drop, (x11.xdnd.Drop{ .source = drag.window, .time = time }).pack());
                drag.state = .dropped;
                // The selection stays served until the target says it is done.
                drag.timer_generation = self.startTimer(io, drag.window, drag_finish_timeout);
                return .{ .nop = {} };
            }
            self.sendXdnd(io, target.window, self.atoms.xdnd_leave, (x11.xdnd.Leave{ .source = drag.window }).pack());
        }
        return self.finishDrag(io, false);
    }

    /// XdndFinished from the target we dropped on. Before version 5 it says nothing about
    /// the outcome, and a target that got this far took the drop.
    fn dragFinished(self: *@This(), io: std.Io, window: u32, finished: x11.xdnd.Finished) common.Event {
        const drag = &(self.drag_source orelse return .{ .nop = {} });
        if (drag.window != window or drag.state != .dropped) return .{ .nop = {} };
        const target = drag.target orelse return .{ .nop = {} };
        if (finished.target != target.window) return .{ .nop = {} };
        const accepted = if (target.version >= 5) finished.accepted else true;
        return self.finishDrag(io, accepted);
    }

    /// A timer of the drag ran out: the target never answered the last position, or never
    /// finished the drop.
    fn dragTimeout(self: *@This(), io: std.Io) common.Event {
        const drag = &self.drag_source.?;
        switch (drag.state) {
            .dragging => {
                drag.gate.reset();
                return self.settleRelease(io, drag, drag.release orelse 0);
            },
            .dropped => return self.finishDrag(io, false),
        }
    }

    /// Escape: leave the target, if any, and end the drag as refused.
    fn cancelDrag(self: *@This(), io: std.Io) common.Event {
        const drag = &self.drag_source.?;
        if (drag.state == .dragging) {
            if (drag.target) |target| {
                self.sendXdnd(io, target.window, self.atoms.xdnd_leave, (x11.xdnd.Leave{ .source = drag.window }).pack());
            }
        }
        return self.finishDrag(io, false);
    }

    /// End the drag: release the pointer and the selection, free the payload, and report.
    fn finishDrag(self: *@This(), io: std.Io, accepted: bool) common.Event {
        const drag = self.drag_source.?;
        self.drag_source = null;
        self.releasePointerGrab(drag.grab);
        _ = self.sendClipboard(io, x11.proto.SetSelectionOwner{ .owner = 0, .selection = self.atoms.xdnd_selection }, null) catch {};
        {
            self.clipboard_mutex.lockUncancelable(io);
            defer self.clipboard_mutex.unlock(io);
            const owned = self.stateOf(.drag);
            if (owned.owner == drag.window) {
                if (owned.payload) |payload| payload.deinit(self.allocator);
                owned.payload = null;
                owned.owner = 0;
            }
            self.drag_active = false;
        }
        return .{ .drag_finished = .{ .accepted = accepted, .window_id = drag.window } };
    }
};

/// How far `walkToAware` descends before giving up.
const max_walk_depth = 32;

fn clampCoordinate(value: i32) i16 {
    return @intCast(std.math.clamp(value, std.math.minInt(i16), std.math.maxInt(i16)));
}

/// How long a paste waits for the owner to answer, or to send the next INCR chunk. The server
/// answers an ownerless selection at once, so only an owner that is hung or gone runs this out.
const paste_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } };

/// How long an INCR transfer we are sending waits for the requestor to take each chunk.
const incr_step_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };

/// How much of a property one GetProperty asks for; longer values are read in several.
const property_read_bytes: u32 = 256 * 1024;

const selection_count = @typeInfo(SelectionIndex).@"enum".fields.len;

/// How long a drop target waits for the source to answer the ConvertSelection, restarted by
/// every INCR chunk.
const drop_fetch_timeout = std.Io.Duration.fromSeconds(1);
/// How long a drag source waits for the target's XdndStatus once the button is up.
const drag_status_timeout = std.Io.Duration.fromSeconds(1);
/// How long a drag source waits for the target's XdndFinished after the drop.
const drag_finish_timeout = std.Io.Duration.fromSeconds(5);

const keysym_escape: u32 = 0xFF1B;

/// The atoms of an XdndTypeList property: 32-bit values, whatever the alignment of the bytes read.
fn atomsFromBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u32 {
    const atoms = try allocator.alloc(u32, bytes.len / 4);
    for (atoms, 0..) |*atom, index| atom.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], native_endian);
    return atoms;
}

const native_endian = builtin.cpu.arch.endian();

/// The most text a single ChangeProperty can carry on this server, and so the INCR chunk size.
fn maxPropertyBytes(info: x11.Setup) usize {
    const request_limit = @as(usize, info.maximum_request_length) * 4;
    return (request_limit -| @sizeOf(x11.proto.ChangeProperty)) & ~@as(usize, 3);
}

/// One selection we may own: its atom, the payload served for it and the window that claimed it.
const OwnedSelection = struct {
    atom: u32,
    /// Null once another client took the selection.
    payload: ?x11_drag.Payload = null,
    /// 0 while we do not own it.
    owner: u32 = 0,
};

/// The selections this backend serves: the two public ones, and XdndSelection for a drag of ours.
const SelectionIndex = enum {
    clipboard,
    primary,
    drag,

    fn of(which: common.Selection) SelectionIndex {
        return switch (which) {
            .clipboard => .clipboard,
            .primary => .primary,
        };
    }
};

/// An INCR transfer being received: the owner appends chunks to `property` on `requestor`,
/// each announced by a PropertyNotify, until an empty one.
const IncrPaste = struct {
    /// Whether the text completes a paste or a drop; `generation` is the paste's, or the drop's timer generation.
    kind: enum { paste, drop },
    generation: u32,
    requestor: u32,
    property: u32,
    /// Whether the chunks came typed STRING (Latin-1) rather than UTF8_STRING.
    string: bool,
    data: std.ArrayList(u8) = .empty,
};

/// One INCR transfer of our text to a requestor, on a connection of its own so the reader task
/// never waits on the requestor. ICCCM 2.7.2: set an INCR property holding the total size,
/// select PropertyNotify on the requestor, send the SelectionNotify; then, each time the
/// requestor deletes the property, write the next chunk, and after the last chunk an empty one.
const IncrSend = struct {
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    request: x11.proto.SelectionRequest,
    property: u32,
    property_type: u32,
    incr_atom: u32,
    text: []u8,
    future: ?std.Io.Future(void) = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(task: *IncrSend, io: std.Io) void {
        defer task.done.store(true, .release);
        task.transfer(io) catch |err| log.warn("INCR transfer of {d} bytes to window 0x{x} failed: {any}", .{ task.text.len, task.request.requestor, err });
    }

    fn transfer(task: *IncrSend, io: std.Io) !void {
        const conn = try x11.connect(io, task.environ, .{});
        defer conn.close(io);
        const info = try x11.setup(io, task.environ, task.allocator, conn);
        defer info.deinit();
        const chunk_bytes = maxPropertyBytes(info);
        const requestor = task.request.requestor;

        // Every client keeps its own event mask on a window, so selecting PropertyNotify on the
        // requestor's window from here disturbs nobody.
        const values = x11.proto.WindowValue{ .EventMask = x11.mask(&[_]x11.proto.EventMask{.PropertyChange}) };
        try x11.sendWithValues(io, conn, x11.proto.ChangeWindowAttributes{
            .window_id = requestor,
            .value_mask = x11.maskFromValues(x11.proto.WindowMask, values),
        }, values);
        const total: u32 = @intCast(task.text.len);
        try x11.sendWithBytes(io, conn, x11.proto.ChangeProperty{
            .window_id = requestor,
            .property = task.property,
            .property_type = task.incr_atom,
            .format = 32,
            .length_of_data = 1,
        }, std.mem.asBytes(&total));
        const notify = x11.proto.SelectionNotify{
            .time = task.request.time,
            .requestor = requestor,
            .selection = task.request.selection,
            .target = task.request.target,
            .property = task.property,
        };
        try x11.send(io, conn, x11.proto.SendEvent{
            .destination = requestor,
            .event_mask = 0,
            .event = std.mem.toBytes(notify),
        });

        var offset: usize = 0;
        while (true) {
            // The first deletion is of the INCR property itself: the requestor is ready.
            try task.awaitDeletion(io, conn);
            const chunk = task.text[offset..@min(offset + chunk_bytes, task.text.len)];
            try x11.sendWithBytes(io, conn, x11.proto.ChangeProperty{
                .window_id = requestor,
                .property = task.property,
                .property_type = task.property_type,
                .format = 8,
                .length_of_data = @intCast(chunk.len),
            }, chunk);
            if (chunk.len == 0) return; // the empty property ends the transfer
            offset += chunk.len;
        }
    }

    /// Block until the requestor deletes the property, which is how it asks for more.
    fn awaitDeletion(task: *IncrSend, io: std.Io, conn: std.Io.net.Stream) !void {
        while (true) {
            const message = try x11.receive(io, conn, incr_step_timeout) orelse return error.IncrRequestorStalled;
            switch (message) {
                .PropertyNotify => |notify| {
                    if (notify.window_id == task.request.requestor and notify.atom == task.property and notify.state == .Deleted) return;
                },
                // The requestor's window went away mid-transfer.
                .ErrorMessage => |failure| {
                    log.debug("X11 error during an INCR transfer: {any}", .{failure.error_code});
                    return error.RequestFailed;
                },
                .Reply => |reply| try skipBytes(io, conn, reply.extraLength()),
                else => {},
            }
        }
    }
};

/// The reader task's own connection for selection traffic; see `WindowManager.clipboard_conn`.
fn openClipboardConnection(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator) ?std.Io.net.Stream {
    const conn = x11.connect(io, environ, .{}) catch |err| {
        log.warn("Clipboard connection failed ({any}); clipboard unsupported", .{err});
        return null;
    };
    const info = x11.setup(io, environ, allocator, conn) catch |err| {
        log.warn("Clipboard connection setup failed ({any}); clipboard unsupported", .{err});
        conn.close(io);
        return null;
    };
    info.deinit();
    return conn;
}

/// Negotiate XFixes and ask for CLIPBOARD owner changes, reported on `root` (a window of our
/// own is not needed: the events go to the client that asked). Null means no
/// `clipboard_changed` events, which is a degradation, never an error.
fn probeXfixes(io: std.Io, conn: std.Io.net.Stream, root: u32, clipboard: u32) ?x11.Extension {
    const extension = x11.xfixes.probe(io, conn) catch |err| {
        log.warn("XFixes probe failed ({any}); no clipboard_changed events", .{err});
        return null;
    } orelse return null;
    x11.xfixes.selectSelectionInput(io, conn, extension, root, clipboard, x11.xfixes.SelectionEventMask.set_selection_owner) catch |err| {
        log.warn("XFixes SelectSelectionInput failed ({any}); no clipboard_changed events", .{err});
        return null;
    };
    return extension;
}

/// Read and drop `count` bytes: the trailing data of a reply nobody decodes.
fn skipBytes(io: std.Io, conn: std.Io.net.Stream, count: usize) !void {
    var scratch: [256]u8 = undefined;
    var left = count;
    while (left > 0) {
        const chunk = scratch[0..@min(left, scratch.len)];
        try x11.receiveBytes(io, conn, chunk);
        left -= chunk.len;
    }
}

/// STRING properties are Latin-1: every byte one code point, the upper half two UTF-8 bytes.
fn latin1ToUtf8(allocator: std.mem.Allocator, latin1: []const u8) ![]u8 {
    var extra: usize = 0;
    for (latin1) |byte| {
        if (byte >= 0x80) extra += 1;
    }
    const utf8 = try allocator.alloc(u8, latin1.len + extra);
    var index: usize = 0;
    for (latin1) |byte| {
        if (byte < 0x80) {
            utf8[index] = byte;
            index += 1;
        } else {
            utf8[index] = 0xC0 | (byte >> 6);
            utf8[index + 1] = 0x80 | (byte & 0x3F);
            index += 2;
        }
    }
    return utf8;
}

test "latin1ToUtf8 keeps ASCII and expands the upper half" {
    const utf8 = try latin1ToUtf8(testing.allocator, "caf\xE9 \xA9");
    defer testing.allocator.free(utf8);
    try testing.expectEqualStrings("café ©", utf8);
}

pub const Window = struct {
    window_id: u32,
    wm: *WindowManager,

    scaling: f32,

    status: common.WindowStatus,

    depth: u8,
    root: u32,
    graphic_context_id: u32,

    cursor_visible: bool = true,
    current_cursor: u32 = 0,

    // to know if clear request comes after a redraw
    redrawn: bool = false,

    pub fn init(wm: *WindowManager, options: common.WindowOptions) !@This() {
        const window_id = try wm.xid.genID();
        const event_masks = [_]x11.proto.EventMask{
            .Exposure,
            .StructureNotify,
            .SubstructureNotify,
            .PropertyChange,
            .KeyPress,
            .KeyRelease,
            .ButtonPress,
            .ButtonRelease,
            .PointerMotion,
            .FocusChange,
        };
        const window_values = x11.proto.WindowValue{
            .BackgroundPixel = commonPixelToX11Pixel(options.background),
            .EventMask = x11.mask(&event_masks),
            .Colormap = wm.info.screens[0].colormap,
        };
        const create_window = x11.proto.CreateWindow{
            .window_id = window_id,

            .parent_id = wm.info.screens[0].root,
            .visual_id = wm.info.screens[0].root_visual,
            .depth = wm.info.screens[0].root_depth,

            .x = options.x orelse 10,
            .y = options.y orelse 10,
            .width = options.width orelse 640,
            .height = options.height orelse 480,
            .border_width = 0,
            .window_class = .InputOutput,

            .value_mask = x11.maskFromValues(x11.proto.WindowMask, window_values),
        };
        try x11.sendWithValues(wm.io, wm.conn, create_window, window_values);

        const set_name_req = x11.proto.ChangeProperty{
            .window_id = window_id,
            .property = wm.atoms.wm_name,
            .property_type = wm.atoms.string,
            .length_of_data = @intCast(options.title.len),
        };
        try x11.sendWithBytes(wm.io, wm.conn, set_name_req, options.title);

        const set_protocols = x11.proto.ChangeProperty{
            .window_id = window_id,
            .property = wm.atoms.wm_protocols,
            .property_type = wm.atoms.atom,
            .format = 32,
            .length_of_data = 1,
        };
        try x11.sendWithBytes(wm.io, wm.conn, set_protocols, &std.mem.toBytes(wm.atoms.wm_delete_window));

        const graphic_context_id = try wm.xid.genID();
        const graphic_context_values = x11.proto.GraphicContextValue{
            .Background = wm.info.screens[0].black_pixel,
            .Foreground = wm.info.screens[0].white_pixel,
        };

        const create_gc = x11.proto.CreateGraphicContext{
            .graphic_context_id = graphic_context_id,
            .drawable_id = window_id,
            .value_mask = x11.maskFromValues(x11.proto.GraphicContextMask, graphic_context_values),
        };
        try x11.sendWithValues(wm.io, wm.conn, create_gc, graphic_context_values);

        return .{
            .window_id = window_id,
            .wm = wm,
            .status = .open,

            .root = wm.info.screens[0].root,
            .depth = wm.info.screens[0].root_depth,
            .graphic_context_id = graphic_context_id,

            .scaling = wm.scaling,
        };
    }

    pub fn deinit(self: *@This()) void {
        // The server drops a destroyed window's selections without a SelectionClear; a drag of
        // this window's own ends on the DestroyNotify the reader task gets.
        self.wm.dropSelection(self.wm.io, self.window_id, .clipboard);
        self.wm.dropSelection(self.wm.io, self.window_id, .primary);
        {
            self.wm.clipboard_mutex.lockUncancelable(self.wm.io);
            defer self.wm.clipboard_mutex.unlock(self.wm.io);
            _ = self.wm.drop_kinds.remove(self.window_id);
        }
        x11.send(self.wm.io, self.wm.conn, x11.proto.DestroyWindow{ .window_id = self.window_id }) catch |err| {
            log.err("Error destroying window: {any}", .{err});
        };
    }

    /// Put `text` on the system clipboard, with this window as the selection owner.
    pub fn setClipboardText(self: *@This(), text: []const u8) !void {
        return self.wm.copy(self.window_id, text, .clipboard);
    }

    /// The clipboard's text as UTF-8, owned by the caller. Blocks until the owner answers, at
    /// most one second between chunks.
    pub fn getClipboardText(self: *@This(), allocator: std.mem.Allocator) ![]u8 {
        return self.wm.paste(allocator, self.window_id, .clipboard);
    }

    /// Put `text` on the primary selection (the one middle-click pastes), with this window as
    /// the owner.
    pub fn setPrimaryText(self: *@This(), text: []const u8) !void {
        return self.wm.copy(self.window_id, text, .primary);
    }

    /// The primary selection's text as UTF-8, owned by the caller; see `getClipboardText`.
    pub fn getPrimaryText(self: *@This(), allocator: std.mem.Allocator) ![]u8 {
        return self.wm.paste(allocator, self.window_id, .primary);
    }

    /// Take drops of the given kinds, which puts XdndAware on the window for sources to find;
    /// `.{}` takes it off again. `error.DragUnsupported` without the side connection.
    pub fn setDropTarget(self: *@This(), kinds: common.DropKinds) common.DragError!void {
        return self.wm.setDropTarget(self.window_id, kinds);
    }

    /// The newest drop's payload, copied into `allocator`; the stored one is freed.
    /// `error.NoDrop` when none is pending.
    pub fn takeDrop(self: *@This(), allocator: std.mem.Allocator) (common.DropError || std.mem.Allocator.Error)!common.DropData {
        return self.wm.takeDrop(allocator);
    }

    /// Start dragging `data` out of this window. Call it while a mouse button is held: the grab
    /// takes the pointer wherever it is, and the drag ends at the next button release, which
    /// `drag_finished` reports. Escape cancels while this window has the keyboard focus.
    pub fn startDrag(self: *@This(), data: common.DragData) common.DragError!void {
        return self.wm.startDrag(self.window_id, data);
    }

    pub fn close(self: *@This()) void {
        x11.send(self.wm.io, self.wm.conn, x11.proto.UnmapWindow{ .window_id = self.window_id }) catch |err| {
            log.err("Error unmapping window: {any}", .{err});
        };
        self.status = .closed;
    }

    /// Ask the event loop to close this window from the application side — a
    /// quit key. `close` only unmaps; it delivers no `.close` event for the
    /// loop to stop on. Send ourselves the WM_DELETE_WINDOW ClientMessage the
    /// window manager would send on a real close, which `receiveIo` already
    /// turns into `.close`, and which reaching the server wakes a blocked read.
    pub fn requestClose(self: *@This()) void {
        const msg = x11.proto.ClientMessageEvent{
            .window_id = self.window_id,
            .message_type = self.wm.atoms.wm_protocols,
            .data = .{ self.wm.atoms.wm_delete_window, 0, 0, 0, 0 },
        };
        const send_event = x11.proto.SendEvent{
            .destination = self.window_id,
            .event_mask = 0,
            .event = std.mem.toBytes(msg),
        };
        x11.send(self.wm.io, self.wm.conn, send_event) catch |err| {
            log.err("Error requesting close: {any}", .{err});
        };
    }

    pub fn show(self: *@This()) !void {
        const map_req = x11.proto.MapWindow{ .window_id = self.window_id };
        try x11.send(self.wm.io, self.wm.conn, map_req);
    }

    pub fn toggleFullscreen(self: *@This()) void {
        const msg = x11.proto.ClientMessageEvent{
            .window_id = self.window_id,
            .message_type = self.wm.atoms.net_wm_state,
            .data = .{ 2, self.wm.atoms.net_wm_state_fullscreen, 0, 0, 0 },
        };

        const send_event = x11.proto.SendEvent{
            .destination = self.root,
            .event_mask = x11.mask(&[_]x11.proto.EventMask{ .SubstructureNotify, .SubstructureRedirect }),
            .event = std.mem.toBytes(msg),
        };
        x11.send(self.wm.io, self.wm.conn, send_event) catch |err| {
            log.err("Error sending fullscreen toggle: {any}", .{err});
        };
    }

    pub fn setIcon(self: *@This(), icon: common.Icon) !void {
        // _NET_WM_ICON format: width (u32), height (u32), ARGB pixels (u32 each)
        const pixel_count = icon.width * icon.height;
        const data_len = 2 + pixel_count;

        const data = try self.wm.allocator.alloc(u32, data_len);
        defer self.wm.allocator.free(data);

        data[0] = icon.width;
        data[1] = icon.height;

        for (0..pixel_count) |i| {
            const off = i * 4;
            const a: u32 = icon.pixels[off + 3];
            const r: u32 = icon.pixels[off + 0];
            const g: u32 = icon.pixels[off + 1];
            const b: u32 = icon.pixels[off + 2];
            data[2 + i] = (a << 24) | (r << 16) | (g << 8) | b;
        }

        const set_icon_req = x11.proto.ChangeProperty{
            .window_id = self.window_id,
            .property = self.wm.atoms.net_wm_icon,
            .property_type = self.wm.atoms.cardinal,
            .format = 32,
            .length_of_data = @intCast(data_len),
        };
        try x11.sendWithBytes(self.wm.io, self.wm.conn, set_icon_req, std.mem.sliceAsBytes(data));
    }

    pub fn hideCursor(self: *@This()) void {
        self.cursor_visible = false;
        const values = x11.proto.WindowValue{ .Cursor = self.wm.invisible_cursor_id };
        x11.sendWithValues(self.wm.io, self.wm.conn, x11.proto.ChangeWindowAttributes{
            .window_id = self.window_id,
            .value_mask = x11.maskFromValues(x11.proto.WindowMask, values),
        }, values) catch {};
    }

    pub fn showCursor(self: *@This()) void {
        self.cursor_visible = true;
        const cursor_id = if (self.current_cursor != 0) self.current_cursor else @as(u32, 0);
        const values = x11.proto.WindowValue{ .Cursor = cursor_id };
        x11.sendWithValues(self.wm.io, self.wm.conn, x11.proto.ChangeWindowAttributes{
            .window_id = self.window_id,
            .value_mask = x11.maskFromValues(x11.proto.WindowMask, values),
        }, values) catch {};
    }

    pub fn setCursor(self: *@This(), cursor: common.Cursor) void {
        const index = @intFromEnum(cursor);
        if (self.wm.system_cursors[index] == 0) {
            const glyph = cursorGlyph(cursor);
            const cursor_id = self.wm.xid.genID() catch return;
            x11.send(self.wm.io, self.wm.conn, x11.proto.CreateGlyphCursor{
                .cursor_id = cursor_id,
                .source_font = self.wm.cursor_font_id,
                .mask_font = self.wm.cursor_font_id,
                .source_char = glyph,
                .mask_char = glyph + 1,
                .fore_red = 0,
                .fore_green = 0,
                .fore_blue = 0,
                .back_red = 0xFFFF,
                .back_green = 0xFFFF,
                .back_blue = 0xFFFF,
            }) catch return;
            self.wm.system_cursors[index] = cursor_id;
        }
        self.current_cursor = self.wm.system_cursors[index];
        if (self.cursor_visible) {
            const values = x11.proto.WindowValue{ .Cursor = self.current_cursor };
            x11.sendWithValues(self.wm.io, self.wm.conn, x11.proto.ChangeWindowAttributes{
                .window_id = self.window_id,
                .value_mask = x11.maskFromValues(x11.proto.WindowMask, values),
            }, values) catch {};
        }
    }

    pub fn grabCursor(self: *@This()) void {
        x11.send(self.wm.io, self.wm.conn, x11.proto.GrabPointer{
            .grab_window = self.window_id,
            .confine_to = self.window_id,
            .event_mask = @intCast(x11.mask(&[_]x11.proto.EventMask{ .ButtonPress, .ButtonRelease, .PointerMotion })),
        }) catch {};
    }

    pub fn releaseCursor(self: *@This()) void {
        x11.send(self.wm.io, self.wm.conn, x11.proto.UngrabPointer{}) catch {};
    }

    pub fn createImage(self: *@This(), allocator: std.mem.Allocator, size: common.Size) !Image {
        return Image.init(allocator, self, size);
    }

    pub fn destroyImage(_: *@This(), image: *Image) void {
        image.deinit();
    }

    pub fn clear(self: *@This(), area: common.BBox) !void {
        if (self.redrawn) return;
        self.redrawn = false;

        const clear_area = x11.proto.ClearArea{
            .window_id = self.window_id,
            .x = area.x,
            .y = area.y,
            .height = area.height,
            .width = area.width,
        };

        try x11.write(&self.wm.net_writer.interface, clear_area);
        //try x11.send(self.wm.io, self.wm.conn,clear_area);
    }

    /// Inject a synthetic `.draw` event through the server: ClearArea with
    /// exposures makes it send an Expose, which wakes the blocked receive
    /// and maps to `.draw`.
    pub fn redraw(self: *@This(), area: common.BBox) !void {
        const clear_area = x11.proto.ClearArea{
            .window_id = self.window_id,
            .x = area.x,
            .y = area.y,
            .height = area.height,
            .width = area.width,
            .exposures = true,
        };
        try x11.send(self.wm.io, self.wm.conn, clear_area);
    }

    pub fn beginDraw(_: *@This()) !void {}

    pub fn endDraw(self: *@This()) !void {
        try self.wm.flush();
    }

    /// z11 has no Present extension, so there is no vblank to pace on: this
    /// backend stays tick-paced and never emits `frame_done`.
    pub fn supportsFramePacing(_: *const @This()) bool {
        return false;
    }

    /// Physical pixels per logical unit, from Xft.dpi at connection time.
    pub fn scale(self: *@This()) f32 {
        return self.scaling;
    }

    /// No compositor frame callback on X11; nothing to arm.
    pub fn requestFrame(_: *@This()) void {}
};

pub const Image = struct {
    window: *Window,
    allocator: std.mem.Allocator,
    source_size: common.Size,
    pixels: []u8,
    pixmap_id: ?u32 = null,
    pixmap_size: common.Size = .{ .width = 0, .height = 0 },
    /// Shared buffer backing the SHM present path. Created on the first draw (the first point the
    /// scaled size is known) and recreated when that size changes. Null whenever the core PutImage
    /// path is in use, whether because the server has no MIT-SHM or because setup failed.
    segment: ?x11.shm.Segment = null,
    segment_size: common.Size = .{ .width = 0, .height = 0 },

    pub fn init(allocator: std.mem.Allocator, window: *Window, size: common.Size) !@This() {
        const len = @as(usize, size.width) * size.height * 4;
        const pixels = try allocator.alloc(u8, len);
        @memset(pixels, 0);
        return .{
            .window = window,
            .allocator = allocator,
            .source_size = size,
            .pixels = pixels,
        };
    }

    pub fn setPixels(self: *@This(), pixels: []const u8) void {
        const len = @as(usize, self.source_size.width) * self.source_size.height * 4;
        @memcpy(self.pixels, pixels[0..len]);
    }

    pub fn draw(self: *@This(), target: common.BBox) !void {
        const phys_width = scaleU16(target.width, self.window.scaling);
        const phys_height = scaleU16(target.height, self.window.scaling);
        const phys_target = common.BBox{
            .x = scaleI16(target.x, self.window.scaling),
            .y = scaleI16(target.y, self.window.scaling),
            .width = phys_width,
            .height = phys_height,
        };

        const needed_size = common.Size{ .width = phys_width, .height = phys_height };

        if (try self.drawShm(phys_target, needed_size)) return;
        try self.drawCore(phys_target, needed_size);
    }

    /// Present through shared memory: scale and swizzle straight into the segment, then hand the
    /// server a 40-byte request naming it. Nothing about the pixels crosses the socket.
    ///
    /// Returns false when this frame has to go the core route instead — no MIT-SHM, setup failed,
    /// or the server has not finished reading the segment yet. All three are normal, so the caller
    /// falls back rather than failing. Errors are reserved for a broken connection.
    fn drawShm(self: *@This(), target: common.BBox, needed_size: common.Size) !bool {
        const wm = self.window.wm;
        const ext = wm.shm orelse return false;
        if (needed_size.width == 0 or needed_size.height == 0) return false;

        if (self.segment != null and !std.meta.eql(self.segment_size, needed_size)) {
            self.releaseSegment();
        }

        if (self.segment == null) {
            const size = @as(usize, needed_size.width) * needed_size.height * 4;
            // The attach carries a descriptor, so it bypasses the buffered writer and goes
            // straight out. Flush first, or it overtakes requests queued earlier this frame.
            try wm.flush();
            self.segment = x11.shm.Segment.init(wm.io, wm.conn, ext, &wm.xid, size) catch |err| {
                log.warn("Failed to attach shm segment ({any}); using core PutImage", .{err});
                return false;
            };
            self.segment_size = needed_size;
        }
        const segment = &self.segment.?;

        // The server is still reading the last frame out of this buffer. Rather than stall the
        // render loop or double the memory, let this one frame take the core path.
        if (wm.isSegmentInFlight(segment.shmseg)) return false;

        nearestNeighborInto(
            segment.bytes,
            self.pixels,
            self.source_size.width,
            self.source_size.height,
            needed_size.width,
            needed_size.height,
        );
        const image_info = x11.getImageInfo(wm.info, self.window.root);
        try x11.rgbaToZPixmapInPlace(image_info, segment.bytes);

        // Track before sending: a segment we cannot prove idle must never be reused.
        if (!wm.markSegmentInFlight(segment.shmseg)) return false;
        errdefer wm.clearSegmentInFlight(segment.shmseg);

        // Buffered, so it stays ordered with ClearArea and the other drawing this frame.
        // One request replaces the pixmap, the strip loop and the CopyArea the core path needs.
        try x11.write(&wm.net_writer.interface, x11.shm.PutImage{
            .major_opcode = ext.major_opcode,
            .drawable_id = self.window.window_id,
            .graphic_context_id = self.window.graphic_context_id,
            .total_width = needed_size.width,
            .total_height = needed_size.height,
            .src_width = target.width,
            .src_height = target.height,
            .dst_x = target.x,
            .dst_y = target.y,
            .depth = self.window.depth,
            .shmseg = segment.shmseg,
            // Ask for the ShmCompletion that clears in_flight; without it we could never know
            // when this buffer is safe to overwrite.
            .send_event = 1,
        });
        return true;
    }

    /// Detach and unmap the segment. Safe to call whether or not the server is still reading it:
    /// the flush puts Detach behind any ShmPutImage already queued, and the server handles
    /// requests in order, so it is done with the buffer before it sees the Detach.
    fn releaseSegment(self: *@This()) void {
        if (self.segment == null) return;
        const segment = &self.segment.?;
        const wm = self.window.wm;

        wm.flush() catch |err| log.err("Failed to flush before detaching shm segment: {any}", .{err});
        if (wm.shm) |ext| segment.deinit(wm.io, wm.conn, ext);
        wm.clearSegmentInFlight(segment.shmseg);

        self.segment = null;
        self.segment_size = .{ .width = 0, .height = 0 };
    }

    /// Present through the core protocol: every pixel goes over the socket into a pixmap, in
    /// strips small enough for a request length, then a CopyArea onto the window.
    fn drawCore(self: *@This(), phys_target: common.BBox, needed_size: common.Size) !void {
        const phys_width = needed_size.width;
        const phys_height = needed_size.height;

        if (self.pixmap_id == null or
            !std.meta.eql(self.pixmap_size, needed_size))
        {
            if (self.pixmap_id) |pid| {
                x11.send(self.window.wm.io, self.window.wm.conn, x11.proto.FreePixmap{ .pixmap_id = pid }) catch |err| {
                    log.err("Failed to free image: {any}", .{err});
                };
            }
            const pixmap_id = try self.window.wm.xid.genID();
            try x11.write(&self.window.wm.net_writer.interface, x11.proto.CreatePixmap{
                .pixmap_id = pixmap_id,
                .drawable_id = self.window.window_id,
                .width = phys_width,
                .height = phys_height,
                .depth = self.window.depth,
            });
            self.pixmap_id = pixmap_id;
            self.pixmap_size = needed_size;
        }

        const scaled = try nearestNeighbor(
            self.allocator,
            self.pixels,
            self.source_size.width,
            self.source_size.height,
            phys_width,
            phys_height,
        );
        defer self.allocator.free(scaled);

        try self.uploadPixels(scaled);

        const copy_area_req = x11.proto.CopyArea{
            .src_drawable_id = self.pixmap_id.?,
            .dst_drawable_id = self.window.window_id,
            .graphic_context_id = self.window.graphic_context_id,
            .width = phys_target.width,
            .height = phys_target.height,
            .dst_x = phys_target.x,
            .dst_y = phys_target.y,
        };
        try x11.write(&self.window.wm.net_writer.interface, copy_area_req);
    }

    fn uploadPixels(self: @This(), pixels: []const u8) !void {
        const image_info = x11.getImageInfo(self.window.wm.info, self.window.root);
        const row_bytes: usize = @as(usize, self.pixmap_size.width) * 4;
        const max_rows: u16 = if (row_bytes == 0) self.pixmap_size.height else @intCast(@min(self.pixmap_size.height, 65535 / row_bytes));
        if (max_rows == 0) return;

        var y: u16 = 0;
        while (y < self.pixmap_size.height) {
            const strip_height: u16 = @intCast(@min(max_rows, self.pixmap_size.height - y));
            const strip_offset = @as(usize, y) * row_bytes;
            const strip_len = @as(usize, strip_height) * row_bytes;
            const strip_pixels = pixels[strip_offset..][0..strip_len];

            var reader = std.Io.Reader.fixed(strip_pixels);
            var pixmap_reader = x11.RgbaToZPixmapReader.init(image_info, &reader);

            const put_image_req = x11.proto.PutImage{
                .drawable_id = self.pixmap_id.?,
                .graphic_context_id = self.window.graphic_context_id,
                .width = self.pixmap_size.width,
                .height = strip_height,
                .x = 0,
                .y = @intCast(y),
                .depth = self.window.depth,
            };

            try x11.stream(
                &self.window.wm.net_writer.interface,
                put_image_req,
                (&pixmap_reader).interface(),
                strip_len,
            );

            y += strip_height;
        }
    }

    pub fn deinit(self: *@This()) void {
        self.releaseSegment();
        if (self.pixmap_id) |pid| {
            x11.send(self.window.wm.io, self.window.wm.conn, x11.proto.FreePixmap{ .pixmap_id = pid }) catch |err| {
                log.err("Failed to free image: {any}", .{err});
            };
        }
        self.allocator.free(self.pixels);
    }
};

/// Decide once, at startup, whether frames can go through shared memory. Null means the core
/// PutImage path handles everything — SHM is an acceleration, so every reason to decline it is
/// normal rather than an error.
fn probeShm(io: std.Io, conn: std.Io.net.Stream, info: x11.Setup) ?x11.Extension {
    const extension = x11.shm.probe(io, conn) catch |err| {
        log.warn("MIT-SHM probe failed ({any}); using core PutImage", .{err});
        return null;
    } orelse return null;

    // SHM only changes how pixels travel, not their layout: the same RGBA->ZPixmap conversion still
    // has to work for this visual. Settle that here rather than mid-frame, because unlike
    // RgbaToZPixmapReader (which converts blindly) the in-place conversion the SHM path needs
    // rejects formats it does not handle — and a present path must never fail where the core one
    // would have drawn something.
    const image_info = x11.getImageInfo(info, info.screens[0].root);
    var probe_pixel = [_]u8{ 0, 0, 0, 0 };
    x11.rgbaToZPixmapInPlace(image_info, &probe_pixel) catch |err| {
        log.warn("MIT-SHM present unsupported for this visual ({any}); using core PutImage", .{err});
        return null;
    };

    return extension;
}

fn scaleU16(v: u16, scaling: f32) u16 {
    if (scaling == 1.0) return v;
    return @intFromFloat(@as(f32, @floatFromInt(v)) * scaling);
}

fn scaleI16(v: i16, scaling: f32) i16 {
    if (scaling == 1.0) return v;
    return @intFromFloat(@as(f32, @floatFromInt(v)) * scaling);
}

fn nearestNeighbor(
    allocator: std.mem.Allocator,
    src: []const u8,
    src_width: common.Width,
    src_height: common.Height,
    dst_width: common.Width,
    dst_height: common.Height,
) ![]u8 {
    const dst_pixels = try allocator.alloc(u8, @as(usize, dst_width) * dst_height * 4);
    errdefer allocator.free(dst_pixels);
    nearestNeighborInto(dst_pixels, src, src_width, src_height, dst_width, dst_height);
    return dst_pixels;
}

/// Scale `src` into `dst_pixels`, which must hold exactly `dst_width * dst_height` RGBA pixels.
/// Writing into a caller's buffer is what lets the SHM path scale directly into shared memory
/// and skip the intermediate frame allocation entirely.
fn nearestNeighborInto(
    dst_pixels: []u8,
    src: []const u8,
    src_width: common.Width,
    src_height: common.Height,
    dst_width: common.Width,
    dst_height: common.Height,
) void {
    const src_w: usize = src_width;
    const src_h: usize = src_height;
    const dst_w: usize = dst_width;
    const dst_h: usize = dst_height;

    std.debug.assert(dst_pixels.len == dst_w * dst_h * 4);

    const y_ratio: f64 = @as(f64, @floatFromInt(src_height)) / @as(f64, @floatFromInt(dst_height));
    const x_ratio: f64 = @as(f64, @floatFromInt(src_width)) / @as(f64, @floatFromInt(dst_width));

    // Source column for a destination column. Computed on demand rather than precomputed into a
    // table, so this needs no allocation and can write straight into a shared-memory segment.
    const mapSrcX = struct {
        fn f(dst_x: usize, ratio: f64, limit: usize) usize {
            return @min(@as(usize, @intFromFloat(@as(f32, @floatFromInt(dst_x)) * ratio)), limit);
        }
    }.f;
    const max_src_x = src_w -| 1;

    for (0..dst_h) |dst_y| {
        const mapped_src_y = @min(@as(usize, @intFromFloat(@as(f32, @floatFromInt(dst_y)) * y_ratio)), src_h -| 1);
        const src_row_start: usize = mapped_src_y * src_w * 4;
        const dst_row_start: usize = dst_y * dst_w * 4;

        var dst_x: usize = 0;
        while (dst_x < dst_w) {
            const mapped_src_x = mapSrcX(dst_x, x_ratio, max_src_x);
            const src_pixel = src[src_row_start + mapped_src_x * 4 ..][0..4];

            // Find run of consecutive dst pixels mapping to the same src pixel
            var run_end = dst_x + 1;
            while (run_end < dst_w and mapSrcX(run_end, x_ratio, max_src_x) == mapped_src_x) : (run_end += 1) {}

            // Fill run with same pixel (LLVM auto-vectorizes to wide stores)
            for (dst_x..run_end) |col| {
                dst_pixels[dst_row_start + col * 4 ..][0..4].* = src_pixel.*;
            }

            dst_x = run_end;
        }
    }
}

test "nearestNeighbor 2x upscale" {
    const allocator = testing.allocator;

    // 2x2 source image: red, green, blue, white
    const src = [_]u8{
        255, 0, 0, 255, // red
        0, 255, 0, 255, // green
        0, 0, 255, 255, // blue
        255, 255, 255, 255, // white
    };

    // Scale 2x2 -> 4x4
    const result = try nearestNeighbor(allocator, &src, 2, 2, 4, 4);
    defer allocator.free(result);

    // 4x4 = 16 pixels * 4 bytes = 64 bytes
    try testing.expectEqual(@as(usize, 64), result.len);

    // Top-left quadrant should be red (first pixel repeated)
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, result[0..4]); // (0,0)
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, result[4..8]); // (1,0)
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, result[16..20]); // (0,1)
}

test "nearestNeighbor identity (no scaling)" {
    const allocator = testing.allocator;

    // 2x2 source
    const src = [_]u8{
        1,  2,  3,  4,
        5,  6,  7,  8,
        9,  10, 11, 12,
        13, 14, 15, 16,
    };

    // Same size: 2x2 -> 2x2
    const result = try nearestNeighbor(allocator, &src, 2, 2, 2, 2);
    defer allocator.free(result);

    try testing.expectEqualSlices(u8, &src, result);
}

test "nearestNeighbor 2x downscale" {
    const allocator = testing.allocator;

    // 4x4 source image
    const src = [_]u8{
        // Row 0
        255, 0, 0, 255, // red
        255, 0, 0, 255, // red
        0, 255, 0, 255, // green
        0, 255, 0, 255, // green
        // Row 1
        255, 0, 0, 255, // red
        255, 0, 0, 255, // red
        0, 255, 0, 255, // green
        0, 255, 0, 255, // green
        // Row 2
        0, 0, 255, 255, // blue
        0, 0, 255, 255, // blue
        255, 255, 255, 255, // white
        255, 255, 255, 255, // white
        // Row 3
        0, 0, 255, 255, // blue
        0, 0, 255, 255, // blue
        255, 255, 255, 255, // white
        255, 255, 255, 255, // white
    };

    // Scale 4x4 -> 2x2
    const result = try nearestNeighbor(allocator, &src, 4, 4, 2, 2);
    defer allocator.free(result);

    // 2x2 = 4 pixels * 4 bytes = 16 bytes
    try testing.expectEqual(@as(usize, 16), result.len);

    // Should sample corners: red, green, blue, white
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, result[0..4]); // red
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255 }, result[4..8]); // green
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, result[8..12]); // blue
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 255 }, result[12..16]); // white
}

test "nearestNeighbor single pixel upscale" {
    const allocator = testing.allocator;

    // 1x1 source
    const src = [_]u8{ 128, 64, 32, 255 };

    // Scale 1x1 -> 3x3
    const result = try nearestNeighbor(allocator, &src, 1, 1, 3, 3);
    defer allocator.free(result);

    // 3x3 = 9 pixels * 4 bytes = 36 bytes
    try testing.expectEqual(@as(usize, 36), result.len);

    // All pixels should be the same color
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        try testing.expectEqualSlices(u8, &src, result[i * 4 .. i * 4 + 4]);
    }
}

/// Glyph index in the X11 "cursor" font; the mask is the following glyph.
fn cursorGlyph(cursor: common.Cursor) u16 {
    return switch (cursor) {
        .default => 2,
        .hand => 58,
        .crosshair => 34,
        .text => 152,
        .not_allowed => 0,
        .resize_ns => 116,
        .resize_ew => 108,
        .move => 52,
        .wait => 150,
        .resize_nwse => 14, // bottom_right_corner
        .resize_nesw => 12, // bottom_left_corner
    };
}

const cursor_count = @typeInfo(common.Cursor).@"enum".fields.len;

/// How long to wait for the KeyPress half of an auto-repeat pair. The pair
/// leaves the server in one write, so a real repeat is already buffered.
const repeat_peek_window = std.Io.Duration.fromMilliseconds(2);

fn isAutoRepeatPair(release: x11.proto.KeyRelease, next: x11.Message) bool {
    return switch (next) {
        .KeyPress => |press| press.keycode == release.keycode and press.time == release.time,
        else => false,
    };
}

test "isAutoRepeatPair folds a same-time same-key release/press pair only" {
    var release = std.mem.zeroes(x11.proto.KeyRelease);
    release.keycode = 38;
    release.time = 1000;
    var press = std.mem.zeroes(x11.proto.KeyPress);
    press.keycode = 38;
    press.time = 1000;
    try testing.expect(isAutoRepeatPair(release, .{ .KeyPress = press }));

    press.time = 1001;
    try testing.expect(!isAutoRepeatPair(release, .{ .KeyPress = press }));
    press.time = 1000;
    press.keycode = 39;
    try testing.expect(!isAutoRepeatPair(release, .{ .KeyPress = press }));
    try testing.expect(!isAutoRepeatPair(release, .{ .MotionNotify = std.mem.zeroes(x11.proto.MotionNotify) }));
}

/// RGB to ABGR
fn commonPixelToX11Pixel(src: [3]u8) u32 {
    const dst: [4]u8 = [4]u8{ 1, src[2], src[1], src[0] };
    return std.mem.bytesToValue(u32, &dst);
}

fn getDesktopScaling(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator) !f32 {
    var scaling: f32 = 1.0;

    const conn = try x11.connect(io, environ, .{});
    defer conn.close(io);

    const info = try x11.setup(io, environ, allocator, conn);
    defer info.deinit();

    const string = try x11.internAtom(io, conn, "STRING");

    const resource_manager = try x11.internAtom(io, conn, "RESOURCE_MANAGER");
    try x11.send(io, conn, x11.proto.GetProperty{
        .window_id = info.screens[0].root,
        .property = resource_manager,
        .property_type = string,
        .long_length = 1024,
    });

    const resource_reply = try x11.receiveReply(io, conn, x11.proto.GetPropertyReply);

    if (resource_reply) |r| {
        if (r.value_len > 4096) {
            // Skip oversized response
            return scaling / 96;
        }
        const tmp = try allocator.alloc(u8, r.value_len);
        defer allocator.free(tmp);
        try x11.receiveBytes(io, conn, tmp);

        var reader: std.Io.Reader = .fixed(tmp);
        while (try reader.takeDelimiter('\n')) |line| {
            if (std.mem.startsWith(u8, line, "Xft.dpi:")) {
                var split = std.mem.splitScalar(u8, line, ':');
                _ = split.first();
                if (split.next()) |value| {
                    const trimmed = std.mem.trim(u8, value, " \t");
                    scaling = try std.fmt.parseFloat(f32, trimmed);
                    break;
                }
            }
        }
    }

    return scaling / 96;
}

const state_shift: u16 = 0x01;
const state_lock: u16 = 0x02;
/// XKB group 2 in the state's group bits.
const state_group_two: u16 = 1 << 13;
const keysym_level3_shift: u32 = 0xFE03;
const keysym_mode_switch: u32 = 0xFF7E;
const keysym_num_lock: u32 = 0xFF7F;

/// The (lower, upper) keysyms of a group and level as the core mapping lays them out: group 1's first two levels, group 2's, then each group's levels 3 and 4 in turn. The core protocol does not say how wide each group is. Group 2's level 3 is read at column 6 when that exists and at column 4 otherwise.
fn keysymPair(columns: []const u32, group: usize, level3: bool) [2]u32 {
    const second_group = group != 0 and (columnAt(columns, 2) != 0 or columnAt(columns, 3) != 0);
    var base: usize = if (second_group) 2 else 0;
    if (level3) {
        if (second_group and columnAt(columns, 6) != 0) {
            base = 6;
        } else if (columnAt(columns, 4) != 0) {
            base = 4;
        }
    }
    return .{ columnAt(columns, base), columnAt(columns, base + 1) };
}

fn columnAt(columns: []const u32, index: usize) u32 {
    return if (index < columns.len) columns[index] else 0;
}

/// A lone lowercase letter implies its uppercase, as the core protocol reads a single-keysym key.
fn impliedUpper(lower: u32) u32 {
    const candidate = lower -| 0x20;
    return if (wl.xkb.keysym.isAlphaPair(lower, candidate)) candidate else lower;
}

const ModifierMasks = struct {
    /// Mod5, where XKB keymaps bind ISO_Level3_Shift by default.
    level3: u16 = 0x80,
    mode_switch: u16 = 0,
    num_lock: u16 = 0,
};

/// Which modifier bits carry ISO_Level3_Shift, Mode_switch and Num_Lock: `GetModifierMapping` lists keycodes per modifier, and each keycode's first keysym says what it is. Only the first keysym counts, as in xmodmap: on a two-layout keyboard Alt_R can carry ISO_Level3_Shift in its second group without being a level-3 modifier.
fn queryModifierMasks(io: std.Io, conn: std.Io.net.Stream, allocator: std.mem.Allocator, keysym_map: []const u32, keysyms_per_keycode: u8, min_keycode: u8) !ModifierMasks {
    try x11.send(io, conn, x11.proto.GetModifierMapping{});
    const reply = (try x11.receiveReply(io, conn, x11.proto.GetModifierMappingReply)) orelse return error.NoModifierMapping;
    const keycodes = try allocator.alloc(u8, reply.keycodeBytes());
    defer allocator.free(keycodes);
    try x11.receiveBytes(io, conn, keycodes);

    var masks: ModifierMasks = .{};
    var level3_bound = false;
    const per_modifier: usize = reply.keycodes_per_modifier;
    const per_keycode: usize = keysyms_per_keycode;
    for (0..8) |modifier| {
        const bit: u16 = @as(u16, 1) << @intCast(modifier);
        for (keycodes[modifier * per_modifier .. (modifier + 1) * per_modifier]) |keycode| {
            if (keycode < min_keycode) continue;
            const base = @as(usize, keycode - min_keycode) * per_keycode;
            if (base + per_keycode > keysym_map.len or per_keycode == 0) continue;
            switch (keysym_map[base]) {
                keysym_level3_shift => {
                    masks.level3 = if (level3_bound) masks.level3 | bit else bit;
                    level3_bound = true;
                },
                keysym_mode_switch => masks.mode_switch |= bit,
                keysym_num_lock => masks.num_lock |= bit,
                else => {},
            }
        }
    }
    return masks;
}

fn x11ModsFromState(state: u16) common.Modifiers {
    return .{
        .shift = (state & 0x01) != 0, // ShiftMask
        .control = (state & 0x04) != 0, // ControlMask
        .alt = (state & 0x08) != 0, // Mod1Mask (typically Alt)
        .super = (state & 0x40) != 0, // Mod4Mask (typically Super)
        .caps_lock = (state & 0x02) != 0, // LockMask
        .num_lock = (state & 0x10) != 0, // Mod2Mask (typically NumLock)
    };
}

// Nothing in the test build calls the clipboard path; take the addresses so it is analyzed.
test "clipboard entry points compile" {
    _ = &WindowManager.copy;
    _ = &WindowManager.paste;
    _ = &WindowManager.receiveIo;
    _ = &WindowManager.deinit;
    _ = &Window.setClipboardText;
    _ = &Window.getClipboardText;
    _ = &Window.setPrimaryText;
    _ = &Window.getPrimaryText;
    _ = &Window.deinit;
    _ = &IncrSend.run;
    _ = &Window.setDropTarget;
    _ = &Window.takeDrop;
    _ = &Window.startDrag;
}

test "atomsFromBytes reads 32-bit atoms out of unaligned property bytes" {
    const bytes = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    const atoms = try atomsFromBytes(testing.allocator, bytes[1..]);
    defer testing.allocator.free(atoms);
    try testing.expectEqual(@as(usize, 2), atoms.len);
    try testing.expectEqual(std.mem.readInt(u32, bytes[1..5], native_endian), atoms[0]);
    try testing.expectEqual(std.mem.readInt(u32, bytes[5..9], native_endian), atoms[1]);
}

test "maxPropertyBytes leaves room for the request header and stays word-aligned" {
    var info: x11.Setup = undefined;
    info.maximum_request_length = 65535;
    try testing.expectEqual(@as(usize, 65535 * 4 - @sizeOf(x11.proto.ChangeProperty)), maxPropertyBytes(info));
    try testing.expectEqual(@as(usize, 0), maxPropertyBytes(info) % 4);
    info.maximum_request_length = 5;
    try testing.expectEqual(@as(usize, 0), maxPropertyBytes(info));
}

const Atoms = struct {
    atom: u32,
    cardinal: u32,
    string: u32,
    wm_name: u32,
    wm_protocols: u32,
    wm_delete_window: u32,
    net_wm_state: u32,
    net_wm_state_fullscreen: u32,
    net_wm_icon: u32,
    clipboard: u32,
    primary: u32,
    utf8_string: u32,
    targets: u32,
    text: u32,
    incr: u32,
    /// Where paste results land on the requesting window.
    mir_clipboard: u32,
    xdnd_aware: u32,
    xdnd_selection: u32,
    xdnd_enter: u32,
    xdnd_position: u32,
    xdnd_status: u32,
    xdnd_leave: u32,
    xdnd_drop: u32,
    xdnd_finished: u32,
    xdnd_type_list: u32,
    xdnd_proxy: u32,
    xdnd_action_copy: u32,
    mime_uri_list: u32,
    mime_utf8: u32,
    mime_text_plain: u32,
    /// Where a drop's payload lands on the target window.
    mir_drop: u32,
    /// Drag bookkeeping messages to our own windows: a timer running out, the grab task
    /// failing, the caller starting a drag; see `x11_drag.Control`.
    mir_drag_control: u32,
};

const std = @import("std");
const testing = std.testing;
const x11 = @import("x11");
const wl = @import("wayland");
const common = @import("common.zig");
const keys = @import("keys.zig");
const Compose = @import("compose.zig");
const EventQueue = @import("event_queue.zig");
const x11_drag = @import("x11_drag.zig");
const uri_list = @import("uri_list.zig");
const builtin = @import("builtin");

const log = std.log.scoped(.any_x11);
