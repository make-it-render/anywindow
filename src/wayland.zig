//! Wayland backend adapter: maps mir-wayland's raw protocol onto the
//! anywindow WindowManager/Window/Image contract, mirroring how x11.zig
//! wraps z11.
//!
//! Rendering model: every window keeps a CPU "shadow" framebuffer (XRGB
//! bytes) that clear() and Image.draw() paint into; endDraw() copies it into
//! a free wl_shm buffer and commits. Buffers the compositor still holds are
//! never written (no tearing); when none is free a new one is added, so
//! presentation never blocks on wl_buffer.release and the ring settles at
//! two buffers.
//!
//! HiDPI model: apps see physical pixels (like the X11 and Win32 backends) —
//! sizes in .resize events, mouse coordinates, and Image targets are all
//! buffer pixels. The compositor speaks logical units, so the adapter keeps
//! both sizes per window and renders crisp at scale: fractionally through a
//! viewport (fractional-scale-v1 + viewporter), else integrally through
//! set_buffer_scale, driven by whichever preference signal the compositor
//! offers (fractional preferred_scale > surface preferred_buffer_scale >
//! entered output's scale).
//!
//! Threading: one task calls receiveIo() (the recvloop source); any thread
//! may draw. `state_mutex` guards the window map and per-window shared
//! state. Lock order: state_mutex may be held while taking the display
//! writer lock, never the reverse.

pub const WindowManager = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    display: wl.Display,

    compositor: u32 = 0,
    compositor_version: u32 = 1,
    shm: u32 = 0,
    wm_base: u32 = 0,
    seat: u32 = 0,
    decoration_manager: u32 = 0,
    cursor_shape_manager: u32 = 0,
    viewporter: u32 = 0,
    fractional_scale_manager: u32 = 0,
    pointer_constraints: u32 = 0,
    icon_manager: u32 = 0,
    pointer: u32 = 0,
    keyboard: u32 = 0,
    cursor_device: u32 = 0,

    scaling: f32 = 1.0,

    // Input-mapping state touched only by the receive task.
    pointer_x: common.X = 0,
    pointer_y: common.Y = 0,
    pointer_scale120: u32 = 120,
    keyboard_focus: common.WindowID = 0,
    modifiers: common.Modifiers = .{},
    /// Parsed wl_keyboard.keymap; null falls back to the built-in US table.
    keymap: ?wl.xkb.Keymap = null,
    /// XKB modifier/group state for keysym lookup (depressed|latched|locked
    /// real bits, effective layout group).
    xkb_mods: u8 = 0,
    xkb_group: u32 = 0,

    // Shared with drawing threads — guarded by state_mutex.
    pointer_focus: common.WindowID = 0,
    pointer_serial: u32 = 0,
    cursor_visible: bool = true,
    cursor_shape: proto.cursor_shape.Shape = .default,

    state_mutex: std.Io.Mutex = .init,
    window_objects: std.AutoHashMapUnmanaged(u32, *WindowShared) = .empty,
    redraw_callbacks: std.AutoHashMapUnmanaged(u32, common.WindowID) = .empty,
    /// wl_surface.frame callback id -> the window that asked, so its
    /// `callback_done` becomes a `frame_done` rather than a `draw`.
    frame_callbacks: std.AutoHashMapUnmanaged(u32, common.WindowID) = .empty,
    /// Bound wl_output id -> integer scale. Only outputs present at init are
    /// tracked (hotplugged ones fall back to the per-surface scale signals).
    outputs: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Highest output scale seen, in 120ths — the guess for windows that
    /// have no per-surface scale signal yet.
    default_scale120: u32 = 120,
    /// Windows whose buffers changed size (resize or rescale), waiting to be
    /// surfaced as .resize events by step().
    pending_resizes: std.ArrayList(u32) = .empty,

    pub fn init(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator) !@This() {
        var self: @This() = .{
            .io = io,
            .allocator = allocator,
            .display = try wl.Display.init(io, environ, allocator),
        };
        errdefer self.display.deinit();

        try self.display.discoverGlobals(io);

        // Compositor version matters: 3 adds set_buffer_scale, 4 adds
        // damage_buffer, 6 adds the per-surface preferred_buffer_scale event.
        const compositor_global = self.display.findGlobal("wl_compositor") orelse {
            log.err("Compositor is missing required global wl_compositor", .{});
            return error.MissingWaylandGlobal;
        };
        self.compositor_version = @min(6, compositor_global.version);
        self.compositor = try self.display.bind(compositor_global, .compositor, self.compositor_version);
        self.shm = try self.bindRequired("wl_shm", .shm, 1);
        self.wm_base = try self.bindRequired("xdg_wm_base", .wm_base, 1);

        // Optional globals — every feature they back degrades gracefully.
        if (self.display.findGlobal("wl_seat")) |global| {
            self.seat = try self.display.bind(global, .seat, 5);
        }
        if (self.display.findGlobal("zxdg_decoration_manager_v1")) |global| {
            self.decoration_manager = try self.display.bind(global, .decoration_manager, 1);
        }
        if (self.display.findGlobal("wp_cursor_shape_manager_v1")) |global| {
            self.cursor_shape_manager = try self.display.bind(global, .cursor_shape_manager, 1);
        }
        // Fractional scaling can only be expressed through a viewport, so
        // the pair is all or nothing.
        if (self.display.findGlobal("wp_viewporter")) |viewporter_global| {
            if (self.display.findGlobal("wp_fractional_scale_manager_v1")) |fractional_global| {
                self.viewporter = try self.display.bind(viewporter_global, .viewporter, 1);
                self.fractional_scale_manager = try self.display.bind(fractional_global, .fractional_scale_manager, 1);
            }
        }
        if (self.display.findGlobal("zwp_pointer_constraints_v1")) |global| {
            self.pointer_constraints = try self.display.bind(global, .pointer_constraints, 1);
        }
        if (self.display.findGlobal("xdg_toplevel_icon_manager_v1")) |global| {
            self.icon_manager = try self.display.bind(global, .icon_manager, 1);
        }
        // wl_output integer scale is the HiDPI fallback for compositors
        // without the per-surface signals; the scale event needs version 2.
        for (self.display.globals.items) |global| {
            if (std.mem.eql(u8, global.interface, "wl_output")) {
                const output = try self.display.bind(global, .output, 2);
                try self.outputs.put(allocator, output, 1);
            }
        }

        // Roundtrip so the seat announces its capabilities and the outputs
        // their scales, binding pointer and keyboard as they appear. The
        // keymap follows get_keyboard immediately, so it lands here too.
        const done_callback = try self.display.sync(io);
        while (true) {
            const event = try self.display.receive(io) orelse continue;
            switch (event) {
                .callback_done => |done| if (done.callback_id == done_callback) break,
                .seat_capabilities => |capabilities| try self.bindSeatDevices(capabilities.capabilities),
                .output_scale => |scale| self.recordOutputScale(scale.output, scale.factor),
                .keyboard_keymap => |keymap| self.loadKeymap(keymap),
                else => {},
            }
        }
        try self.display.flush();
        self.scaling = @as(f32, @floatFromInt(self.default_scale120)) / 120.0;

        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.display.deinit();
        self.window_objects.deinit(self.allocator);
        self.redraw_callbacks.deinit(self.allocator);
        self.frame_callbacks.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
        self.pending_resizes.deinit(self.allocator);
        if (self.keymap) |*keymap| keymap.deinit();
    }

    /// Parse a wl_keyboard.keymap payload, replacing the active keymap.
    /// Failures keep the previous keymap (or the US fallback) — a layout
    /// this parser cannot handle should not take the keyboard down with it.
    /// Receive-task only.
    fn loadKeymap(self: *@This(), keymap_event: @FieldType(wl.Event, "keyboard_keymap")) void {
        defer _ = std.os.linux.close(keymap_event.fd);
        if (keymap_event.format != 1 or keymap_event.size == 0) {
            log.warn("Ignoring keymap format {d}", .{keymap_event.format});
            return;
        }
        const data = std.posix.mmap(null, keymap_event.size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, keymap_event.fd, 0) catch |err| {
            log.warn("Failed to map keymap fd: {any}", .{err});
            return;
        };
        defer std.posix.munmap(data);

        // The advertised size includes a terminating NUL.
        const text = std.mem.sliceTo(data, 0);
        const parsed = wl.xkb.Keymap.parse(self.allocator, text) catch |err| {
            log.warn("Failed to parse keymap ({any}); keeping previous layout", .{err});
            return;
        };
        if (self.keymap) |*old| old.deinit();
        self.keymap = parsed;
        log.debug("Keymap loaded: {d} types, {d} group(s)", .{ parsed.types.len, parsed.group_names.len });
    }

    pub fn createWindow(self: *@This(), options: common.WindowOptions) !Window {
        return try Window.init(self, options);
    }

    /// Event source for recvloop's io loop. The socket read blocks through
    /// `io`, so a task parked here is interrupted by group cancelation.
    pub fn receiveIo(self: *@This(), io: std.Io) !?common.Event {
        while (true) {
            if (try self.step(io)) |event| return event;
        }
    }

    pub fn flush(self: *@This()) !void {
        try self.display.flush();
    }

    fn bindRequired(self: *@This(), name: []const u8, interface: wl.Interface, version: u32) !u32 {
        const global = self.display.findGlobal(name) orelse {
            log.err("Compositor is missing required global {s}", .{name});
            return error.MissingWaylandGlobal;
        };
        return try self.display.bind(global, interface, version);
    }

    fn bindSeatDevices(self: *@This(), capabilities: u32) !void {
        if (self.pointer == 0 and capabilities & proto.wayland.seat_capability_pointer != 0) {
            self.pointer = try self.display.newId(.pointer);
            {
                const writer = self.display.acquire();
                defer self.display.release();
                try proto.wayland.seat.getPointer(writer, self.seat, self.pointer);
            }
            if (self.cursor_shape_manager != 0) {
                self.cursor_device = try self.display.newId(.cursor_shape_device);
                const writer = self.display.acquire();
                defer self.display.release();
                try proto.cursor_shape.manager.getPointer(writer, self.cursor_shape_manager, self.cursor_device, self.pointer);
            }
        }
        if (self.keyboard == 0 and capabilities & proto.wayland.seat_capability_keyboard != 0) {
            self.keyboard = try self.display.newId(.keyboard);
            const writer = self.display.acquire();
            defer self.display.release();
            try proto.wayland.seat.getKeyboard(writer, self.seat, self.keyboard);
        }
    }

    /// Read one Wayland event and map it to a `common.Event`. Returns null
    /// when the event was protocol bookkeeping or input state with nothing
    /// to surface.
    fn step(self: *@This(), io: std.Io) !?common.Event {
        if (try self.takePendingResize(io)) |event| return event;
        const event = try self.display.receive(io) orelse return null;
        switch (event) {
            .wm_base_ping => |serial| {
                {
                    const writer = self.display.acquire();
                    defer self.display.release();
                    try proto.xdg_shell.wm_base.pong(writer, self.wm_base, serial);
                }
                try self.display.flush();
                return null;
            },
            .seat_capabilities => |capabilities| {
                try self.bindSeatDevices(capabilities.capabilities);
                try self.display.flush();
                return null;
            },
            .toplevel_configure => |configure| {
                self.state_mutex.lockUncancelable(io);
                defer self.state_mutex.unlock(io);
                const shared = self.window_objects.get(configure.toplevel) orelse return null;
                if (configure.width > 0 and configure.height > 0) {
                    shared.pending_width = std.math.cast(u16, configure.width) orelse shared.pending_width;
                    shared.pending_height = std.math.cast(u16, configure.height) orelse shared.pending_height;
                }
                shared.fullscreen = configure.fullscreen;
                return null;
            },
            .xdg_surface_configure => |configure| {
                try self.handleConfigure(io, configure.xdg_surface, configure.serial);
                return try self.takePendingResize(io);
            },
            .surface_enter => |enter| {
                self.state_mutex.lockUncancelable(io);
                defer self.state_mutex.unlock(io);
                const shared = self.window_objects.get(enter.surface) orelse return null;
                shared.output = enter.output;
                try self.applyScaleLocked(shared);
                return null;
            },
            .surface_preferred_buffer_scale => |preferred| {
                self.state_mutex.lockUncancelable(io);
                defer self.state_mutex.unlock(io);
                const shared = self.window_objects.get(preferred.surface) orelse return null;
                shared.preferred_buffer_scale = if (preferred.factor > 0) @intCast(preferred.factor) else 0;
                try self.applyScaleLocked(shared);
                return null;
            },
            .fractional_scale_preferred => |preferred| {
                self.state_mutex.lockUncancelable(io);
                defer self.state_mutex.unlock(io);
                const shared = self.window_objects.get(preferred.fractional_scale) orelse return null;
                shared.fractional_scale120 = preferred.scale120;
                try self.applyScaleLocked(shared);
                return null;
            },
            .output_scale => |scale| {
                self.state_mutex.lockUncancelable(io);
                defer self.state_mutex.unlock(io);
                self.recordOutputScale(scale.output, scale.factor);
                // Collect first: applying a scale retires buffer slots,
                // which mutates window_objects mid-iteration otherwise.
                var affected: std.ArrayList(*WindowShared) = .empty;
                defer affected.deinit(self.allocator);
                var iterator = self.window_objects.iterator();
                while (iterator.next()) |entry| {
                    const shared = entry.value_ptr.*;
                    if (entry.key_ptr.* != shared.surface) continue;
                    if (shared.output != scale.output) continue;
                    try affected.append(self.allocator, shared);
                }
                for (affected.items) |shared| {
                    try self.applyScaleLocked(shared);
                }
                return null;
            },
            .toplevel_close => |toplevel_id| {
                self.state_mutex.lockUncancelable(io);
                defer self.state_mutex.unlock(io);
                const shared = self.window_objects.get(toplevel_id) orelse return null;
                return .{ .close = shared.surface };
            },
            .buffer_release => |buffer_id| {
                self.state_mutex.lockUncancelable(io);
                defer self.state_mutex.unlock(io);
                const shared = self.window_objects.get(buffer_id) orelse return null;
                for (shared.slots.items, 0..) |slot, index| {
                    if (slot.buffer != buffer_id) continue;
                    if (slot.stale) {
                        self.destroySlotLocked(shared, index);
                    } else {
                        slot.busy = false;
                    }
                    break;
                }
                return null;
            },
            .callback_done => |done| {
                self.state_mutex.lockUncancelable(io);
                defer self.state_mutex.unlock(io);
                if (self.redraw_callbacks.fetchRemove(done.callback_id)) |entry| {
                    return .{ .draw = .{ .window_id = entry.value } };
                }
                if (self.frame_callbacks.fetchRemove(done.callback_id)) |entry| {
                    return .{ .frame_done = entry.value };
                }
                return null;
            },
            .pointer_enter => |enter| {
                self.state_mutex.lockUncancelable(io);
                defer self.state_mutex.unlock(io);
                // Pointer coordinates arrive in logical (surface) units;
                // apps speak buffer pixels, so scale by the window's factor.
                self.pointer_scale120 = if (self.window_objects.get(enter.surface)) |shared| shared.scale120 else 120;
                self.pointer_x = coordinate(enter.x, self.pointer_scale120);
                self.pointer_y = coordinate(enter.y, self.pointer_scale120);
                self.pointer_focus = enter.surface;
                self.pointer_serial = enter.serial;
                // The compositor resets the cursor on every enter.
                self.applyCursorLocked();
                return .{ .mouse_moved = .{ .x = self.pointer_x, .y = self.pointer_y, .window_id = enter.surface } };
            },
            .pointer_leave => |leave| {
                self.state_mutex.lockUncancelable(io);
                defer self.state_mutex.unlock(io);
                if (self.pointer_focus == leave.surface) self.pointer_focus = 0;
                return null;
            },
            .pointer_motion => |motion| {
                self.pointer_x = coordinate(motion.x, self.pointer_scale120);
                self.pointer_y = coordinate(motion.y, self.pointer_scale120);
                const focus = self.pointerFocus() orelse return null;
                return .{ .mouse_moved = .{ .x = self.pointer_x, .y = self.pointer_y, .window_id = focus } };
            },
            .pointer_button => |button| {
                const focus = self.pointerFocus() orelse return null;
                const mapped = buttonFromEvdev(button.button);
                if (button.state == proto.wayland.state_pressed) {
                    return .{ .mouse_pressed = .{ .x = self.pointer_x, .y = self.pointer_y, .button = mapped, .window_id = focus } };
                }
                return .{ .mouse_released = .{ .x = self.pointer_x, .y = self.pointer_y, .button = mapped, .window_id = focus } };
            },
            .pointer_axis => |axis| {
                const focus = self.pointerFocus() orelse return null;
                // One wheel notch is 15 logical units; anywindow's x11
                // backend reports +1 per notch scrolling up, so vertical
                // flips sign.
                const amount = wl.wire.fixedToFloat(axis.value) / 15.0;
                return .{ .mouse_scroll = .{
                    .x = self.pointer_x,
                    .y = self.pointer_y,
                    .scroll_x = if (axis.axis == proto.wayland.axis_horizontal) amount else 0,
                    .scroll_y = if (axis.axis == proto.wayland.axis_vertical) -amount else 0,
                    .window_id = focus,
                } };
            },
            .keyboard_enter => |enter| {
                self.keyboard_focus = enter.surface;
                return null;
            },
            .keyboard_leave => |leave| {
                if (self.keyboard_focus == leave.surface) self.keyboard_focus = 0;
                return null;
            },
            .keyboard_keymap => |keymap| {
                self.loadKeymap(keymap);
                return null;
            },
            .keyboard_modifiers => |mods| {
                // Held modifiers are depressed|latched; the lock states
                // report separately. Mask positions come from the keymap's
                // virtual modifiers, falling back to the standard pc layout
                // (Mod1 Alt, Mod2 Num, Mod4 Super) — the same bit layout
                // X11's state field uses.
                const held = mods.depressed | mods.latched;
                const alt_mask: u32 = if (self.keymap) |keymap| keymap.alt_mask else 0x08;
                const super_mask: u32 = if (self.keymap) |keymap| keymap.super_mask else 0x40;
                const num_lock_mask: u32 = if (self.keymap) |keymap| keymap.num_lock_mask else 0x10;
                self.modifiers = .{
                    .shift = held & 0x01 != 0,
                    .control = held & 0x04 != 0,
                    .alt = held & alt_mask != 0,
                    .super = held & super_mask != 0,
                    .caps_lock = mods.locked & 0x02 != 0,
                    .num_lock = mods.locked & num_lock_mask != 0,
                };
                // Level selection uses all components, locks included —
                // that is how caps and num lock reach the key types.
                self.xkb_mods = @truncate(mods.depressed | mods.latched | mods.locked);
                self.xkb_group = mods.group;
                return null;
            },
            .keyboard_key => |key| {
                if (self.keyboard_focus == 0) return null;
                // Wayland keyboard codes are raw evdev codes; the scancode
                // stays positional while the Key follows the active layout
                // when a keymap is available (XKB keycode = evdev + 8).
                const scancode = if (std.math.cast(u8, key.key)) |evdev| keys.evdevToScancode(evdev) else .unknown;
                const mapped_key: keys.Key = if (self.keymap) |*keymap|
                    keys.x11KeysymToKey(keymap.keysym(key.key + 8, self.xkb_mods, self.xkb_group))
                else
                    keys.scancodeToKey(scancode);
                if (key.state == proto.wayland.state_pressed) {
                    return .{ .key_pressed = .{
                        .scancode = scancode,
                        .key = mapped_key,
                        .modifiers = self.modifiers,
                        .window_id = self.keyboard_focus,
                    } };
                }
                return .{ .key_released = .{
                    .scancode = scancode,
                    .key = mapped_key,
                    .modifiers = self.modifiers,
                    .window_id = self.keyboard_focus,
                } };
            },
            else => return null,
        }
    }

    fn handleConfigure(self: *@This(), io: std.Io, xdg_surface_id: u32, serial: u32) !void {
        // Ack first — mandatory before the next commit.
        {
            const writer = self.display.acquire();
            defer self.display.release();
            try proto.xdg_shell.xdg_surface.ackConfigure(writer, xdg_surface_id, serial);
        }
        try self.display.flush();

        self.state_mutex.lockUncancelable(io);
        defer self.state_mutex.unlock(io);
        const shared = self.window_objects.get(xdg_surface_id) orelse return;
        shared.configured = true;
        if (shared.pending_width != 0) {
            shared.logical_width = shared.pending_width;
            shared.logical_height = shared.pending_height;
        }
        try self.applyScaleLocked(shared);
    }

    /// Recompute a window's effective scale and physical buffer size. When
    /// either changed: realloc the shadow, retire wrong-size buffers, and
    /// queue a .resize event. Requires state_mutex.
    fn applyScaleLocked(self: *@This(), shared: *WindowShared) !void {
        const scale120 = self.windowScale120Locked(shared);
        const width = physicalLength(shared.logical_width, scale120);
        const height = physicalLength(shared.logical_height, scale120);
        if (scale120 == shared.scale120 and width == shared.width and height == shared.height) return;

        shared.scale120 = scale120;
        shared.width = width;
        shared.height = height;
        if (self.pointer_focus == shared.surface) self.pointer_scale120 = scale120;

        const shadow = try self.allocator.alloc(u8, @as(usize, width) * height * 4);
        self.allocator.free(shared.shadow);
        shared.shadow = shadow;
        fillRect(shared.shadow, width, height, .{}, shared.background);

        // Old-size buffers can't be reused; drop them (deferred while the
        // compositor still holds one).
        var index = shared.slots.items.len;
        while (index > 0) {
            index -= 1;
            const slot = shared.slots.items[index];
            if (slot.busy) {
                slot.stale = true;
            } else {
                self.destroySlotLocked(shared, index);
            }
        }

        for (self.pending_resizes.items) |queued| {
            if (queued == shared.surface) return;
        }
        try self.pending_resizes.append(self.allocator, shared.surface);
    }

    /// A window's preferred scale in 120ths, constrained to what the
    /// connection can express: any fraction through a viewport, whole
    /// integers through set_buffer_scale (compositor >= 3), otherwise 1x.
    /// The preference signals in precedence order: fractional-scale, the
    /// compositor-v6 per-surface integer, the entered output's scale, the
    /// highest scale of any output. Requires state_mutex.
    fn windowScale120Locked(self: *@This(), shared: *WindowShared) u32 {
        const preferred: u32 = blk: {
            if (shared.fractional_scale120 != 0) break :blk shared.fractional_scale120;
            if (shared.preferred_buffer_scale != 0) break :blk shared.preferred_buffer_scale * 120;
            if (shared.output != 0) {
                if (self.outputs.get(shared.output)) |scale| break :blk scale * 120;
            }
            break :blk self.default_scale120;
        };
        if (shared.viewport != 0) return preferred;
        if (self.compositor_version >= 3 and preferred % 120 == 0) return preferred;
        return 120;
    }

    /// Record an output's integer scale and refresh the default for windows
    /// without a per-surface signal. Requires state_mutex (or init, before
    /// any other task exists).
    fn recordOutputScale(self: *@This(), output: u32, factor: i32) void {
        const scale: u32 = if (factor > 0) @intCast(factor) else 1;
        if (self.outputs.getPtr(output)) |entry| entry.* = scale;
        var best: u32 = 120;
        var values = self.outputs.valueIterator();
        while (values.next()) |value| best = @max(best, value.* * 120);
        self.default_scale120 = best;
    }

    /// Pop one queued .resize, skipping windows that were destroyed since.
    fn takePendingResize(self: *@This(), io: std.Io) !?common.Event {
        self.state_mutex.lockUncancelable(io);
        defer self.state_mutex.unlock(io);
        while (self.pending_resizes.pop()) |window_id| {
            const shared = self.window_objects.get(window_id) orelse continue;
            return .{ .resize = .{ .width = shared.width, .height = shared.height, .window_id = shared.surface } };
        }
        return null;
    }

    /// Pointer focus read for event mapping (reader task); locked because
    /// setCursor on a drawing thread reads it too.
    fn pointerFocus(self: *@This()) ?common.WindowID {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.pointer_focus == 0) return null;
        return self.pointer_focus;
    }

    /// Re-assert cursor visibility/shape using the latest enter serial.
    /// Requires state_mutex held.
    fn applyCursorLocked(self: *@This()) void {
        if (self.pointer == 0) return;
        if (!self.cursor_visible) {
            const writer = self.display.acquire();
            defer self.display.release();
            proto.wayland.pointer.setCursor(writer, self.pointer, self.pointer_serial, 0, 0, 0) catch {};
        } else if (self.cursor_device != 0) {
            const writer = self.display.acquire();
            defer self.display.release();
            proto.cursor_shape.device.setShape(writer, self.cursor_device, self.pointer_serial, self.cursor_shape) catch {};
        }
        // No cursor-shape protocol: visible means the compositor default —
        // nothing to send.
        self.display.flush() catch {};
    }

    fn destroySlotLocked(self: *@This(), shared: *WindowShared, index: usize) void {
        const slot = shared.slots.swapRemove(index);
        {
            const writer = self.display.acquire();
            defer self.display.release();
            proto.wayland.buffer.destroy(writer, slot.buffer) catch {};
            proto.wayland.shm_pool.destroy(writer, slot.pool) catch {};
        }
        _ = self.window_objects.remove(slot.buffer);
        slot.shm.deinit();
        self.allocator.destroy(slot);
    }
};

/// Per-window state both the receive task and drawing threads reach, so it
/// lives on the heap behind WindowManager.state_mutex (Window structs are
/// moved around by value by callers).
const WindowShared = struct {
    surface: u32,
    xdg_surface: u32,
    toplevel: u32,
    decoration: u32 = 0,
    viewport: u32 = 0,
    fractional_scale: u32 = 0,
    confined_pointer: u32 = 0,
    background: [3]u8,

    /// Surface size in the compositor's logical coordinates.
    logical_width: u16,
    logical_height: u16,
    /// Buffer size in physical pixels — the space apps see and draw in.
    width: u16,
    height: u16,
    /// Effective scale in 120ths (fractional-scale units); 120 = 1x.
    scale120: u32 = 120,
    /// Scale preference signals, in precedence order. Zero = not received.
    fractional_scale120: u32 = 0,
    preferred_buffer_scale: u32 = 0,
    output: u32 = 0,

    /// Logical size from the last toplevel_configure.
    pending_width: u16 = 0,
    pending_height: u16 = 0,
    configured: bool = false,
    fullscreen: bool = false,
    closed: bool = false,
    /// Set by `requestFrame`, cleared when the next `present` asks the
    /// compositor for a frame callback. One-shot, as the Wayland callback is.
    frame_requested: bool = false,

    /// XRGB shadow framebuffer all drawing lands in; width*height*4.
    shadow: []u8,
    slots: std.ArrayList(*Slot) = .empty,
};

/// One wl_shm pool + wl_buffer the compositor can hold independently.
const Slot = struct {
    shm: wl.SharedMemory,
    pool: u32 = 0,
    buffer: u32 = 0,
    width: u16,
    height: u16,
    busy: bool = false,
    stale: bool = false,
};

pub const Window = struct {
    wm: *WindowManager,
    shared: *WindowShared,
    window_id: common.WindowID,
    scaling: f32,
    status: common.WindowStatus = .open,

    /// `options.x`/`options.y` are ignored: Wayland clients cannot position
    /// themselves.
    pub fn init(wm: *WindowManager, options: common.WindowOptions) !@This() {
        const surface = try wm.display.newId(.surface);
        const xdg_surface = try wm.display.newId(.xdg_surface);
        const toplevel = try wm.display.newId(.toplevel);

        // Option sizes are physical pixels (matching the other backends);
        // the surface speaks logical units. Until the compositor sends a
        // per-surface scale, the best guess is the highest output scale.
        const scale120: u32 = blk: {
            wm.state_mutex.lockUncancelable(wm.io);
            defer wm.state_mutex.unlock(wm.io);
            if (wm.viewporter != 0 or wm.compositor_version >= 3) break :blk wm.default_scale120;
            break :blk 120;
        };
        const logical_width = logicalLength(options.width orelse 640, scale120);
        const logical_height = logicalLength(options.height orelse 480, scale120);
        const width = physicalLength(logical_width, scale120);
        const height = physicalLength(logical_height, scale120);

        const shared = try wm.allocator.create(WindowShared);
        errdefer wm.allocator.destroy(shared);
        shared.* = .{
            .surface = surface,
            .xdg_surface = xdg_surface,
            .toplevel = toplevel,
            .background = options.background,
            .logical_width = logical_width,
            .logical_height = logical_height,
            .width = width,
            .height = height,
            .scale120 = scale120,
            .shadow = try wm.allocator.alloc(u8, @as(usize, width) * height * 4),
        };
        errdefer wm.allocator.free(shared.shadow);
        fillRect(shared.shadow, width, height, .{}, options.background);

        {
            const writer = wm.display.acquire();
            defer wm.display.release();
            try proto.wayland.compositor.createSurface(writer, wm.compositor, surface);
            try proto.xdg_shell.wm_base.getXdgSurface(writer, wm.wm_base, xdg_surface, surface);
            try proto.xdg_shell.xdg_surface.getToplevel(writer, xdg_surface, toplevel);
            const title = if (options.title.len > 0) options.title else "make-it-render";
            try proto.xdg_shell.toplevel.setTitle(writer, toplevel, title);
            // Wayland has no core per-window icon; compositors match app_id
            // against a .desktop file. The title is the best identity we
            // have from WindowOptions. (setIcon adds xdg-toplevel-icon on
            // compositors that offer it.)
            try proto.xdg_shell.toplevel.setAppId(writer, toplevel, title);
        }
        if (wm.decoration_manager != 0) {
            shared.decoration = try wm.display.newId(.toplevel_decoration);
            const writer = wm.display.acquire();
            defer wm.display.release();
            try proto.decoration.manager.getToplevelDecoration(writer, wm.decoration_manager, shared.decoration, toplevel);
            try proto.decoration.toplevel_decoration.setMode(writer, shared.decoration, proto.decoration.mode_server_side);
        }
        if (wm.viewporter != 0) {
            shared.viewport = try wm.display.newId(.viewport);
            const writer = wm.display.acquire();
            defer wm.display.release();
            try proto.viewporter.manager.getViewport(writer, wm.viewporter, shared.viewport, surface);
        }
        if (wm.fractional_scale_manager != 0) {
            shared.fractional_scale = try wm.display.newId(.fractional_scale);
            const writer = wm.display.acquire();
            defer wm.display.release();
            try proto.fractional_scale.manager.getFractionalScale(writer, wm.fractional_scale_manager, shared.fractional_scale, surface);
        }
        {
            const writer = wm.display.acquire();
            defer wm.display.release();
            try proto.wayland.surface.commit(writer, surface);
        }
        try wm.display.flush();

        wm.state_mutex.lockUncancelable(wm.io);
        defer wm.state_mutex.unlock(wm.io);
        try wm.window_objects.put(wm.allocator, surface, shared);
        try wm.window_objects.put(wm.allocator, xdg_surface, shared);
        try wm.window_objects.put(wm.allocator, toplevel, shared);
        if (shared.fractional_scale != 0) {
            try wm.window_objects.put(wm.allocator, shared.fractional_scale, shared);
        }

        return .{
            .wm = wm,
            .shared = shared,
            .window_id = surface,
            .scaling = wm.scaling,
        };
    }

    pub fn deinit(self: *@This()) void {
        const wm = self.wm;
        self.close();

        wm.state_mutex.lockUncancelable(wm.io);
        defer wm.state_mutex.unlock(wm.io);
        const shared = self.shared;

        var index = shared.slots.items.len;
        while (index > 0) {
            index -= 1;
            wm.destroySlotLocked(shared, index);
        }
        {
            const writer = wm.display.acquire();
            defer wm.display.release();
            if (shared.fractional_scale != 0) {
                proto.fractional_scale.fractional_scale.destroy(writer, shared.fractional_scale) catch {};
            }
            if (shared.viewport != 0) {
                proto.viewporter.viewport.destroy(writer, shared.viewport) catch {};
            }
            proto.wayland.surface.destroy(writer, shared.surface) catch {};
        }
        wm.display.flush() catch {};

        _ = wm.window_objects.remove(shared.surface);
        if (shared.fractional_scale != 0) _ = wm.window_objects.remove(shared.fractional_scale);
        shared.slots.deinit(wm.allocator);
        wm.allocator.free(shared.shadow);
        wm.allocator.destroy(shared);
    }

    /// Tear down the xdg role — the window disappears. Idempotent.
    pub fn close(self: *@This()) void {
        if (self.status == .closed) return;
        self.status = .closed;

        const wm = self.wm;
        wm.state_mutex.lockUncancelable(wm.io);
        defer wm.state_mutex.unlock(wm.io);
        const shared = self.shared;
        shared.closed = true;
        {
            const writer = wm.display.acquire();
            defer wm.display.release();
            if (shared.confined_pointer != 0) {
                proto.pointer_constraints.confined_pointer.destroy(writer, shared.confined_pointer) catch {};
                shared.confined_pointer = 0;
            }
            if (shared.decoration != 0) {
                proto.decoration.toplevel_decoration.destroy(writer, shared.decoration) catch {};
            }
            proto.xdg_shell.toplevel.destroy(writer, shared.toplevel) catch {};
            proto.xdg_shell.xdg_surface.destroy(writer, shared.xdg_surface) catch {};
        }
        wm.display.flush() catch {};
        _ = wm.window_objects.remove(shared.toplevel);
        _ = wm.window_objects.remove(shared.xdg_surface);
        shared.decoration = 0;
    }

    /// Block until the compositor's first configure, then present the
    /// background. Call before the event loop starts (setup events arriving
    /// during the wait are handled; input events are not expected yet).
    pub fn show(self: *@This()) !void {
        const wm = self.wm;
        while (true) {
            {
                wm.state_mutex.lockUncancelable(wm.io);
                defer wm.state_mutex.unlock(wm.io);
                if (self.shared.configured) break;
            }
            _ = try wm.step(wm.io);
        }
        try self.present();
    }

    pub fn toggleFullscreen(self: *@This()) void {
        const wm = self.wm;
        wm.state_mutex.lockUncancelable(wm.io);
        const fullscreen = self.shared.fullscreen;
        wm.state_mutex.unlock(wm.io);
        {
            const writer = wm.display.acquire();
            defer wm.display.release();
            if (fullscreen) {
                proto.xdg_shell.toplevel.unsetFullscreen(writer, self.shared.toplevel) catch {};
            } else {
                proto.xdg_shell.toplevel.setFullscreen(writer, self.shared.toplevel, 0) catch {};
            }
        }
        wm.display.flush() catch {};
    }

    /// Best-effort per-window icon through xdg-toplevel-icon-v1 (KDE offers
    /// it; GNOME does not). The durable Wayland mechanism remains a .desktop
    /// file matched by app_id. The protocol wants square buffers, so
    /// non-square icons are centered on a transparent square canvas.
    pub fn setIcon(self: *@This(), icon: common.Icon) !void {
        const wm = self.wm;
        if (wm.icon_manager == 0) {
            log.debug("Compositor lacks xdg_toplevel_icon_manager_v1; ship a .desktop file matching the app_id", .{});
            return;
        }
        if (icon.width == 0 or icon.height == 0) return;
        const side: u32 = @max(icon.width, icon.height);
        const size = @as(usize, side) * side * 4;

        var pixels = try wl.SharedMemory.init(size);
        defer pixels.deinit();
        @memset(pixels.data[0..size], 0);
        const offset_x = (side - icon.width) / 2;
        const offset_y = (side - icon.height) / 2;
        for (0..icon.height) |y| {
            for (0..icon.width) |x| {
                const source = icon.pixels[(y * icon.width + x) * 4 ..][0..4];
                const target = pixels.data[((y + offset_y) * side + (x + offset_x)) * 4 ..][0..4];
                // wl_shm ARGB8888 is premultiplied, bytes B,G,R,A in memory.
                const alpha: u32 = source[3];
                target[0] = @intCast(@as(u32, source[2]) * alpha / 255);
                target[1] = @intCast(@as(u32, source[1]) * alpha / 255);
                target[2] = @intCast(@as(u32, source[0]) * alpha / 255);
                target[3] = source[3];
            }
        }

        wm.state_mutex.lockUncancelable(wm.io);
        defer wm.state_mutex.unlock(wm.io);
        const shared = self.shared;
        if (shared.closed) return;

        const pool = try wm.display.newId(.shm_pool);
        const create_pool = proto.wayland.shm.createPoolMessage(wm.shm, pool, @intCast(size));
        try wm.display.sendWithFd(&create_pool, pixels.fd);

        const buffer = try wm.display.newId(.buffer);
        const icon_id = try wm.display.newId(.icon);
        {
            const writer = wm.display.acquire();
            defer wm.display.release();
            try proto.wayland.shm_pool.createBuffer(writer, pool, buffer, 0, @intCast(side), @intCast(side), @intCast(side * 4), proto.wayland.format_argb8888);
            try proto.toplevel_icon.manager.createIcon(writer, wm.icon_manager, icon_id);
            try proto.toplevel_icon.icon.addBuffer(writer, icon_id, buffer, 1);
            try proto.toplevel_icon.manager.setIcon(writer, wm.icon_manager, shared.toplevel, icon_id);
            // The compositor copies the pixels at set_icon; everything can go.
            try proto.toplevel_icon.icon.destroy(writer, icon_id);
            try proto.wayland.buffer.destroy(writer, buffer);
            try proto.wayland.shm_pool.destroy(writer, pool);
            // set_icon is double-buffered toplevel state — commit applies it.
            try proto.wayland.surface.commit(writer, shared.surface);
        }
        try wm.display.flush();
    }

    pub fn hideCursor(self: *@This()) void {
        const wm = self.wm;
        wm.state_mutex.lockUncancelable(wm.io);
        defer wm.state_mutex.unlock(wm.io);
        wm.cursor_visible = false;
        if (wm.pointer_focus == self.window_id) wm.applyCursorLocked();
    }

    pub fn showCursor(self: *@This()) void {
        const wm = self.wm;
        wm.state_mutex.lockUncancelable(wm.io);
        defer wm.state_mutex.unlock(wm.io);
        wm.cursor_visible = true;
        if (wm.pointer_focus == self.window_id) wm.applyCursorLocked();
    }

    pub fn setCursor(self: *@This(), cursor: common.Cursor) void {
        const wm = self.wm;
        wm.state_mutex.lockUncancelable(wm.io);
        defer wm.state_mutex.unlock(wm.io);
        wm.cursor_shape = shapeFromCursor(cursor);
        if (wm.cursor_visible and wm.pointer_focus == self.window_id) wm.applyCursorLocked();
    }

    /// Confine the pointer to this window — the X11 backend's GrabPointer
    /// confine_to semantics: absolute motion keeps flowing, bounded to the
    /// surface. (FPS-style lock + relative motion would need an anywindow
    /// relative-motion event first.) No-op without pointer-constraints.
    pub fn grabCursor(self: *@This()) void {
        const wm = self.wm;
        wm.state_mutex.lockUncancelable(wm.io);
        defer wm.state_mutex.unlock(wm.io);
        if (wm.pointer_constraints == 0 or wm.pointer == 0) {
            log.debug("grabCursor needs zwp_pointer_constraints_v1 and a seat pointer; not confining", .{});
            return;
        }
        const shared = self.shared;
        // One constraint per surface+pointer pair, or the compositor
        // protocol-errors with already_constrained.
        if (shared.closed or shared.confined_pointer != 0) return;
        const confined = wm.display.newId(.confined_pointer) catch return;
        {
            const writer = wm.display.acquire();
            defer wm.display.release();
            proto.pointer_constraints.constraints.confinePointer(
                writer,
                wm.pointer_constraints,
                confined,
                shared.surface,
                wm.pointer,
                0, // null region: the whole surface
                proto.pointer_constraints.lifetime_persistent,
            ) catch {};
        }
        shared.confined_pointer = confined;
        wm.display.flush() catch {};
    }

    pub fn releaseCursor(self: *@This()) void {
        const wm = self.wm;
        wm.state_mutex.lockUncancelable(wm.io);
        defer wm.state_mutex.unlock(wm.io);
        const shared = self.shared;
        if (shared.confined_pointer == 0) return;
        {
            const writer = wm.display.acquire();
            defer wm.display.release();
            proto.pointer_constraints.confined_pointer.destroy(writer, shared.confined_pointer) catch {};
        }
        shared.confined_pointer = 0;
        wm.display.flush() catch {};
    }

    pub fn createImage(self: *@This(), allocator: std.mem.Allocator, size: common.Size) !Image {
        return Image.init(allocator, self, size);
    }

    pub fn destroyImage(_: *@This(), image: *Image) void {
        image.deinit();
    }

    /// Fill a region of the shadow with the background color. Zero extent
    /// extends to the far edge (X11 ClearArea semantics).
    pub fn clear(self: *@This(), area: common.BBox) !void {
        const wm = self.wm;
        wm.state_mutex.lockUncancelable(wm.io);
        defer wm.state_mutex.unlock(wm.io);
        const shared = self.shared;
        fillRect(shared.shadow, shared.width, shared.height, area, shared.background);
    }

    /// Inject a synthetic `.draw` event through the server: a sync callback
    /// wakes the blocked receive task and maps back to this window — the
    /// Wayland analog of x11's ClearArea-with-exposures trick.
    pub fn redraw(self: *@This(), area: common.BBox) !void {
        _ = area;
        const wm = self.wm;
        const callback_id = try wm.display.newId(.callback);
        {
            wm.state_mutex.lockUncancelable(wm.io);
            defer wm.state_mutex.unlock(wm.io);
            try wm.redraw_callbacks.put(wm.allocator, callback_id, self.window_id);
        }
        {
            const writer = wm.display.acquire();
            defer wm.display.release();
            try proto.wayland.display.sync(writer, callback_id);
        }
        try wm.display.flush();
    }

    pub fn beginDraw(_: *@This()) !void {}

    pub fn endDraw(self: *@This()) !void {
        try self.present();
    }

    /// The Wayland backend paces frames on the compositor's own refresh.
    pub fn supportsFramePacing(_: *const @This()) bool {
        return true;
    }

    /// Ask for a `frame_done` event when the compositor is next about to
    /// repaint, so a render can land on a display refresh. One-shot: call it
    /// again from each `frame_done` to keep a steady loop. The callback is
    /// requested at the next `present`, and the compositor only fires it while
    /// the surface is visible — so a hidden or unmapped window is not woken.
    pub fn requestFrame(self: *@This()) void {
        const wm = self.wm;
        wm.state_mutex.lockUncancelable(wm.io);
        defer wm.state_mutex.unlock(wm.io);
        self.shared.frame_requested = true;
    }

    fn present(self: *@This()) !void {
        const wm = self.wm;
        wm.state_mutex.lockUncancelable(wm.io);
        defer wm.state_mutex.unlock(wm.io);
        const shared = self.shared;
        if (shared.closed or !shared.configured) return;

        const slot = try acquireSlotLocked(wm, shared);
        @memcpy(slot.shm.data[0..shared.shadow.len], shared.shadow);
        slot.busy = true;

        // A frame callback must be requested before the commit it belongs to,
        // so the compositor ties it to this presentation. Register the id
        // before sending, so a callback_done cannot arrive to an empty map.
        var frame_id: ?u32 = null;
        if (shared.frame_requested) {
            const id = try wm.display.newId(.callback);
            try wm.frame_callbacks.put(wm.allocator, id, self.window_id);
            shared.frame_requested = false;
            frame_id = id;
        }
        {
            const writer = wm.display.acquire();
            defer wm.display.release();
            if (frame_id) |id| try proto.wayland.surface.frame(writer, shared.surface, id);
            try proto.wayland.surface.attach(writer, shared.surface, slot.buffer, 0, 0);
            // Tell the compositor how the physical buffer maps onto the
            // logical surface. Sent every commit — a few words, and it keeps
            // scale state and buffer size changing atomically together.
            if (shared.viewport != 0) {
                try proto.viewporter.viewport.setDestination(writer, shared.viewport, shared.logical_width, shared.logical_height);
            } else if (wm.compositor_version >= 3) {
                try proto.wayland.surface.setBufferScale(writer, shared.surface, @intCast(shared.scale120 / 120));
            }
            if (wm.compositor_version >= 4) {
                try proto.wayland.surface.damageBuffer(writer, shared.surface, 0, 0, shared.width, shared.height);
            } else {
                try proto.wayland.surface.damage(writer, shared.surface, 0, 0, shared.logical_width, shared.logical_height);
            }
            try proto.wayland.surface.commit(writer, shared.surface);
        }
        try wm.display.flush();
    }

    /// Find a free right-sized buffer or add one. Requires state_mutex held.
    fn acquireSlotLocked(wm: *WindowManager, shared: *WindowShared) !*Slot {
        for (shared.slots.items) |slot| {
            if (!slot.busy and !slot.stale and slot.width == shared.width and slot.height == shared.height) {
                return slot;
            }
        }

        const size = @as(usize, shared.width) * shared.height * 4;
        const slot = try wm.allocator.create(Slot);
        errdefer wm.allocator.destroy(slot);
        slot.* = .{
            .shm = try wl.SharedMemory.init(size),
            .width = shared.width,
            .height = shared.height,
        };
        errdefer slot.shm.deinit();

        slot.pool = try wm.display.newId(.shm_pool);
        const create_pool = proto.wayland.shm.createPoolMessage(wm.shm, slot.pool, @intCast(size));
        try wm.display.sendWithFd(&create_pool, slot.shm.fd);

        slot.buffer = try wm.display.newId(.buffer);
        {
            const writer = wm.display.acquire();
            defer wm.display.release();
            try proto.wayland.shm_pool.createBuffer(
                writer,
                slot.pool,
                slot.buffer,
                0,
                shared.width,
                shared.height,
                @as(i32, shared.width) * 4,
                proto.wayland.format_xrgb8888,
            );
        }

        try shared.slots.append(wm.allocator, slot);
        try wm.window_objects.put(wm.allocator, slot.buffer, shared);
        return slot;
    }
};

pub const Image = struct {
    window: *Window,
    allocator: std.mem.Allocator,
    source_size: common.Size,
    pixels: []u8,

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

    /// Blit (nearest-neighbor scaled, RGBA -> XRGB) into the window shadow.
    pub fn draw(self: *@This(), target: common.BBox) !void {
        const wm = self.window.wm;
        wm.state_mutex.lockUncancelable(wm.io);
        defer wm.state_mutex.unlock(wm.io);
        const shared = self.window.shared;
        blitScaled(
            shared.shadow,
            shared.width,
            shared.height,
            self.pixels,
            self.source_size.width,
            self.source_size.height,
            target,
        );
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.pixels);
    }
};

/// Logical 24.8 fixed-point to physical pixels at the given scale.
fn coordinate(value: wl.wire.Fixed, scale120: u32) i16 {
    const pixels = @divTrunc(@as(i64, value) * scale120, 120 * 256);
    return @intCast(std.math.clamp(pixels, std.math.minInt(i16), std.math.maxInt(i16)));
}

/// Logical length to physical pixels: round(logical * scale), half up, per
/// the fractional-scale spec. Never zero.
fn physicalLength(logical: u16, scale120: u32) u16 {
    const scaled = (@as(u64, logical) * scale120 + 60) / 120;
    return @intCast(std.math.clamp(scaled, 1, std.math.maxInt(u16)));
}

/// Requested physical pixels to logical length at the given scale.
fn logicalLength(physical: u16, scale120: u32) u16 {
    const scaled = (@as(u64, physical) * 120 + scale120 / 2) / scale120;
    return @intCast(std.math.clamp(scaled, 1, std.math.maxInt(u16)));
}

/// Evdev button codes to anywindow's X11-style numbering.
fn buttonFromEvdev(code: u32) common.MouseButton {
    return switch (code) {
        0x110 => 1, // BTN_LEFT
        0x111 => 3, // BTN_RIGHT
        0x112 => 2, // BTN_MIDDLE
        0x113 => 8, // BTN_SIDE
        0x114 => 9, // BTN_EXTRA
        else => 0,
    };
}

fn shapeFromCursor(cursor: common.Cursor) proto.cursor_shape.Shape {
    return switch (cursor) {
        .default => .default,
        .hand => .pointer,
        .crosshair => .crosshair,
        .text => .text,
        .not_allowed => .not_allowed,
        .resize_ns => .ns_resize,
        .resize_ew => .ew_resize,
        .move => .move,
    };
}

/// Fill an XRGB region with an RGB color. Zero extent extends to the far
/// edge, matching X11 ClearArea.
fn fillRect(dst: []u8, dst_width: u16, dst_height: u16, area: common.BBox, rgb: [3]u8) void {
    const x0: usize = @intCast(std.math.clamp(@as(i32, area.x), 0, dst_width));
    const y0: usize = @intCast(std.math.clamp(@as(i32, area.y), 0, dst_height));
    const x1: usize = if (area.width == 0) dst_width else @intCast(std.math.clamp(@as(i32, area.x) + area.width, 0, dst_width));
    const y1: usize = if (area.height == 0) dst_height else @intCast(std.math.clamp(@as(i32, area.y) + area.height, 0, dst_height));
    if (x1 <= x0 or y1 <= y0) return;

    const pixel = [4]u8{ rgb[2], rgb[1], rgb[0], 255 };
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = dst[(y * dst_width + x0) * 4 ..][0 .. (x1 - x0) * 4];
        var x: usize = 0;
        while (x < row.len) : (x += 4) {
            row[x..][0..4].* = pixel;
        }
    }
}

/// Nearest-neighbor blit of RGBA source pixels into the XRGB shadow at
/// `target`, clipped to the shadow. Zero target extent means source size.
fn blitScaled(dst: []u8, dst_width: u16, dst_height: u16, src: []const u8, src_width: u16, src_height: u16, target: common.BBox) void {
    if (src_width == 0 or src_height == 0) return;
    const target_width: usize = if (target.width == 0) src_width else target.width;
    const target_height: usize = if (target.height == 0) src_height else target.height;

    var row: usize = 0;
    while (row < target_height) : (row += 1) {
        const y = @as(i32, target.y) + @as(i32, @intCast(row));
        if (y < 0) continue;
        if (y >= dst_height) break;
        const source_y = row * src_height / target_height;
        const source_row = src[source_y * @as(usize, src_width) * 4 ..];
        const dst_row = dst[@as(usize, @intCast(y)) * dst_width * 4 ..];

        var column: usize = 0;
        while (column < target_width) : (column += 1) {
            const x = @as(i32, target.x) + @as(i32, @intCast(column));
            if (x < 0) continue;
            if (x >= dst_width) break;
            const source_x = column * src_width / target_width;
            const source_pixel = source_row[source_x * 4 ..][0..4];
            const dst_pixel = dst_row[@as(usize, @intCast(x)) * 4 ..][0..4];
            dst_pixel[0] = source_pixel[2];
            dst_pixel[1] = source_pixel[1];
            dst_pixel[2] = source_pixel[0];
            dst_pixel[3] = 255;
        }
    }
}

test "fillRect clips and honors zero-extent" {
    var shadow: [4 * 4 * 4]u8 = @splat(9);
    // Zero extent fills everything.
    fillRect(&shadow, 4, 4, .{}, .{ 1, 2, 3 });
    try testing.expectEqual([4]u8{ 3, 2, 1, 255 }, shadow[0..4].*);
    try testing.expectEqual([4]u8{ 3, 2, 1, 255 }, shadow[60..64].*);

    // Partial fill with out-of-bounds extent clips.
    fillRect(&shadow, 4, 4, .{ .x = 2, .y = 2, .width = 10, .height = 10 }, .{ 10, 20, 30 });
    try testing.expectEqual([4]u8{ 3, 2, 1, 255 }, shadow[0..4].*); // untouched
    try testing.expectEqual([4]u8{ 30, 20, 10, 255 }, shadow[(2 * 4 + 2) * 4 ..][0..4].*);
    try testing.expectEqual([4]u8{ 30, 20, 10, 255 }, shadow[(3 * 4 + 3) * 4 ..][0..4].*);
}

test "blitScaled swizzles RGBA to XRGB bytes" {
    var shadow: [2 * 2 * 4]u8 = @splat(0);
    const src = [4]u8{ 10, 20, 30, 255 }; // one RGBA pixel
    blitScaled(&shadow, 2, 2, &src, 1, 1, .{ .x = 1, .y = 1, .width = 1, .height = 1 });
    // B,G,R,X order in memory.
    try testing.expectEqual([4]u8{ 30, 20, 10, 255 }, shadow[(1 * 2 + 1) * 4 ..][0..4].*);
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, shadow[0..4].*);
}

test "physicalLength rounds half up and never returns zero" {
    try testing.expectEqual(@as(u16, 640), physicalLength(640, 120));
    try testing.expectEqual(@as(u16, 1280), physicalLength(640, 240));
    try testing.expectEqual(@as(u16, 800), physicalLength(640, 150)); // 1.25x
    try testing.expectEqual(@as(u16, 960), physicalLength(640, 180)); // 1.5x
    try testing.expectEqual(@as(u16, 799), physicalLength(639, 150)); // 798.75 rounds up
    try testing.expectEqual(@as(u16, 1), physicalLength(1, 60)); // floor is 1
}

test "logicalLength inverts physicalLength at integer scales" {
    try testing.expectEqual(@as(u16, 320), logicalLength(640, 240));
    try testing.expectEqual(@as(u16, 640), logicalLength(640, 120));
    try testing.expectEqual(@as(u16, 1280), physicalLength(logicalLength(1280, 240), 240));
}

test "coordinate scales logical fixed-point to physical pixels" {
    // 100.0 logical at 2x -> 200 physical.
    try testing.expectEqual(@as(i16, 200), coordinate(100 * 256, 240));
    // 100.5 logical at 1x truncates to 100.
    try testing.expectEqual(@as(i16, 100), coordinate(100 * 256 + 128, 120));
    // 100.5 logical at 1.5x -> 150.75 -> 150.
    try testing.expectEqual(@as(i16, 150), coordinate(100 * 256 + 128, 180));
    // Negative coordinates stay negative.
    try testing.expectEqual(@as(i16, -20), coordinate(-10 * 256, 240));
}

test "blitScaled scales 1x1 source across the target box" {
    var shadow: [4 * 4 * 4]u8 = @splat(0);
    const src = [4]u8{ 255, 0, 0, 255 };
    blitScaled(&shadow, 4, 4, &src, 1, 1, .{ .width = 4, .height = 4 });
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, shadow[0..4].*);
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, shadow[60..64].*);
}

const std = @import("std");
const testing = std.testing;
const wl = @import("wayland");
const proto = wl.proto;
const common = @import("common.zig");
const keys = @import("keys.zig");

const log = std.log.scoped(.any_wayland);
