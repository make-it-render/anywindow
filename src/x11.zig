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
    system_cursors: [8]u32 = [_]u32{0} ** 8,

    keysym_map: []u32,
    keysyms_per_keycode: u8,
    min_keycode: u8,
    max_keycode: u8,

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
        };

        // Negotiate MIT-SHM while replies are still safe to read naively — once the event loop
        // starts, its reader task owns the connection and would swallow any reply we waited for.
        const shm_extension = probeShm(io, conn, info);

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

            .scaling = scaling,

            .cursor_font_id = cursor_font_id,
            .invisible_cursor_id = invisible_cursor_id,

            .keysym_map = keysym_map,
            .keysyms_per_keycode = keysyms_per_keycode,
            .min_keycode = min_kc,
            .max_keycode = max_kc,
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
        self.in_flight.deinit(self.allocator);
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
            const message = try x11.receive(io, self.conn, .none) orelse continue;
            switch (self.mapMessage(message)) {
                .nop => {}, // ignored message — keep reading
                else => |event| return event,
            }
        }
    }

    /// Map a raw X11 message to a `common.Event` (`.nop` for messages we ignore).
    fn mapMessage(self: *@This(), message: x11.Message) common.Event {
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
                    const client_message_data = x11.clientMessageData(client_message);
                    if (client_message_data.u32[0] == self.atoms.wm_delete_window) {
                        return .{ .close = client_message.window_id };
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
                    const evdev_code = key_press.keycode -| 8;
                    const sc = keys.evdevToScancode(evdev_code);
                    const keysym = self.lookupKeysym(key_press.keycode, key_press.state);
                    const key = keys.x11KeysymToKey(keysym);
                    const mods = x11ModsFromState(key_press.state);
                    return .{
                        .key_pressed = .{
                            .scancode = sc,
                            .key = key,
                            .modifiers = mods,
                            .window_id = key_press.event_window,
                        },
                    };
                },
                .ButtonRelease => |button_release| {
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
                    return .{
                        .mouse_moved = .{
                            .x = motion_notify.event_x,
                            .y = motion_notify.event_y,
                            .window_id = motion_notify.event_window,
                        },
                    };
                },
                .ConfigureNotify => |configure| {
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

    pub fn lookupKeysym(self: *@This(), keycode: u8, state: u16) u32 {
        if (keycode < self.min_keycode or keycode > self.max_keycode) return 0;
        const offset = keycode - self.min_keycode;
        const base: usize = @as(usize, offset) * @as(usize, self.keysyms_per_keycode);
        if (base >= self.keysym_map.len) return 0;

        // Column 0 = unshifted, column 1 = shifted
        const shifted = (state & 0x01) != 0; // Shift bit in KeyButMask
        const col: usize = if (shifted and self.keysyms_per_keycode > 1) 1 else 0;
        const idx = base + col;
        if (idx >= self.keysym_map.len) return 0;

        const sym = self.keysym_map[idx];
        // If shifted column is NoSymbol (0), fall back to unshifted
        if (sym == 0 and col == 1) return self.keysym_map[base];
        return sym;
    }
};

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
        x11.send(self.wm.io, self.wm.conn, x11.proto.DestroyWindow{ .window_id = self.window_id }) catch |err| {
            log.err("Error destroying window: {any}", .{err});
        };
    }

    pub fn close(self: *@This()) void {
        x11.send(self.wm.io, self.wm.conn, x11.proto.UnmapWindow{ .window_id = self.window_id }) catch |err| {
            log.err("Error unmapping window: {any}", .{err});
        };
        self.status = .closed;
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
    };
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
};

const std = @import("std");
const testing = std.testing;
const x11 = @import("x11");
const common = @import("common.zig");
const keys = @import("keys.zig");

const log = std.log.scoped(.any_x11);
