pub const WindowManager = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    instance: ?win.Instance,

    pub fn init(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator) !@This() {
        _ = environ;
        const instance = win.GetModuleHandleW(null);
        if (instance == null) {
            const e = win.GetLastError();
            log.err("Error getting instance {d}", .{e});
            return error.InitError;
        }
        _ = win.SetProcessDPIAware();
        events = queue.ThreadSafeQueue(common.Event).init(io);

        return .{
            .io = io,
            .allocator = allocator,
            .instance = instance,
        };
    }

    pub fn deinit(_: *@This()) void {
        events.close();
    }

    pub fn createWindow(self: *@This(), options: common.WindowOptions) !Window {
        return try Window.init(self, options);
    }

    /// io-native event source: blocks on the event queue with an io-cancelable
    /// wait, so a task blocked here is interrupted by `io` cancelation. The
    /// WndProc still feeds the queue. Counterpart to the X11 backend's
    /// direct-read `receiveIo`; both back `any.WindowSource`.
    pub fn receiveIo(_: *@This(), io: std.Io) !?common.Event {
        return events.receiveCancelable(io);
    }

    pub fn flush(_: *@This()) !void {
        _ = win.DwmFlush();
        _ = win.GdiFlush();
    }
};

pub const Window = struct {
    wm: *WindowManager,
    handle: ?win.WindowHandle,
    frame: ?win.DeviceContext,
    class_name: [:0]u16,

    title: [:0]u16,

    status: common.WindowStatus,
    thread: ?std.Thread = null,
    thread_id: u32 = 0,

    display: ?win.DeviceContext = null,
    window_dc: ?win.DeviceContext = null,
    backbuffer: ?win.Bitmap = null,
    background: ?win.BrushHandler = null,

    scaling: f32 = 1.0,

    // Cursor state
    cursor_visible: bool = true,
    current_cursor: ?win.CursorHandler = null,

    // fullscreen state
    is_fullscreen: bool = false,
    saved_style: isize = 0,
    saved_rect: win.Rect = .{},

    pub fn init(wm: *WindowManager, options: common.WindowOptions) !@This() {
        const count = class_count.fetchAdd(1, .monotonic);
        const class_name_n = try std.fmt.allocPrint(wm.allocator, "WindowClass_{d}", .{count});
        defer wm.allocator.free(class_name_n);

        const class_name = try win.W(wm.allocator, class_name_n);
        const background = win.CreateSolidBrush(commonPixelToWinPixel(options.background));

        // Class cursor is null — we handle WM_SETCURSOR ourselves
        // so setCursor/hideCursor work reliably.
        const window_class: win.WindowClass = .{
            .style = 0,
            .window_procedure = windowProc,
            .instance = wm.instance,
            .class_name = class_name,
            .cursor = null,
            .background = background,
        };

        _ = win.RegisterClassExW(&window_class);

        const title = try win.W(wm.allocator, options.title);

        var ctx = WindowThread{
            .wm = wm,
            .options = options,
            .class_name = class_name,
            .title = title,
            .background = background,
        };

        // TODO: check for support in single_threaded build
        const thread = std.Thread.spawn(.{}, WindowThread.run, .{&ctx}) catch return error.ThreadSpawnError;
        try ctx.wait();

        return .{
            .wm = wm,
            .handle = ctx.handle,
            .frame = ctx.frame,
            .status = .open,
            .title = title,
            .class_name = class_name,
            .background = background,
            .scaling = ctx.scaling,
            .thread = thread,
            .thread_id = ctx.thread_id,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.thread_id != 0) {
            _ = win.PostThreadMessageW(self.thread_id, @intFromEnum(win.MessageType.WM_QUIT), 0, 0);
        }
        if (self.thread) |t| t.join();
        self.wm.allocator.free(self.title);
        self.wm.allocator.free(self.class_name);
    }

    pub fn close(self: *@This()) void {
        self.status = .closed;
    }

    pub fn show(self: *@This()) !void {
        _ = win.ShowWindow(self.handle, 1);
        while (win.ShowCursor(true) < 1) {}
    }

    pub fn toggleFullscreen(self: *@This()) void {
        if (!self.is_fullscreen) {
            // Save current style and window rect
            self.saved_style = win.GetWindowLongPtrW(self.handle, win.GWL_STYLE);
            _ = win.GetWindowRect(self.handle, &self.saved_rect);

            // Remove title bar and borders
            const new_style = self.saved_style & ~@as(isize, @intFromEnum(win.WindowStyle.OverlappedWindow));
            _ = win.SetWindowLongPtrW(self.handle, win.GWL_STYLE, new_style);

            // Get monitor dimensions
            var mi = win.MonitorInfo{};
            const monitor = win.MonitorFromWindow(self.handle, win.MONITOR_DEFAULTTOPRIMARY);
            _ = win.GetMonitorInfoW(monitor, &mi);

            // Resize to cover the monitor
            _ = win.SetWindowPos(
                self.handle,
                win.HWND_TOP,
                mi.rcMonitor.left,
                mi.rcMonitor.top,
                mi.rcMonitor.right - mi.rcMonitor.left,
                mi.rcMonitor.bottom - mi.rcMonitor.top,
                win.SWP_FRAMECHANGED | win.SWP_NOOWNERZORDER,
            );
            self.is_fullscreen = true;
        } else {
            // Restore style
            _ = win.SetWindowLongPtrW(self.handle, win.GWL_STYLE, self.saved_style);

            // Restore position and size
            _ = win.SetWindowPos(
                self.handle,
                win.HWND_TOP,
                self.saved_rect.left,
                self.saved_rect.top,
                self.saved_rect.right - self.saved_rect.left,
                self.saved_rect.bottom - self.saved_rect.top,
                win.SWP_FRAMECHANGED | win.SWP_NOOWNERZORDER | win.SWP_NOZORDER,
            );
            self.is_fullscreen = false;
        }
    }

    pub fn setIcon(self: *@This(), icon: common.Icon) !void {
        // Create color bitmap (top-down, 32bpp)
        var color_pixels: [*]u8 = undefined;
        const bitmap_info = win.BitmapInfo{
            .header = .{
                .width = @intCast(icon.width),
                .height = -@as(i32, @intCast(icon.height)),
            },
        };
        const color_bmp = win.CreateDIBSection(null, &bitmap_info, .RGB_COLORS, &color_pixels, null, 0);
        if (color_bmp == null) return error.CreateIconFailed;
        defer _ = win.DeleteObject(color_bmp);

        // Copy RGBA -> BGRA
        const pixel_count = std.math.mul(usize, @as(usize, icon.width), @as(usize, icon.height)) catch return error.IconTooLarge;
        for (0..pixel_count) |i| {
            const off = i * 4;
            color_pixels[off + 0] = icon.pixels[off + 2]; // B
            color_pixels[off + 1] = icon.pixels[off + 1]; // G
            color_pixels[off + 2] = icon.pixels[off + 0]; // R
            color_pixels[off + 3] = icon.pixels[off + 3]; // A
        }

        // Create mask bitmap (all zeros = fully visible)
        const mask_bmp = win.CreateBitmap(@intCast(icon.width), @intCast(icon.height), 1, 1, null);
        if (mask_bmp == null) return error.CreateIconFailed;
        defer _ = win.DeleteObject(mask_bmp);

        var icon_info = win.IconInfo{
            .hbmMask = mask_bmp,
            .hbmColor = color_bmp,
        };
        const hicon = win.CreateIconIndirect(&icon_info);
        if (hicon == null) return error.CreateIconFailed;

        _ = win.SendMessageW(self.handle, win.WM_SETICON, win.ICON_BIG, @intCast(@intFromPtr(hicon)));
        _ = win.SendMessageW(self.handle, win.WM_SETICON, win.ICON_SMALL, @intCast(@intFromPtr(hicon)));
    }

    pub fn createImage(self: *@This(), allocator: std.mem.Allocator, size: common.Size) !Image {
        return Image.init(allocator, self, size);
    }

    pub fn destroyImage(_: *@This(), image: *Image) void {
        image.deinit();
    }

    pub fn clear(self: *@This(), _: common.BBox) !void {
        if (self.display) |_| {
            var rect = win.Rect{};
            _ = win.GetClientRect(self.handle, &rect);
            _ = win.FillRect(self.display, &rect, self.background);
        }
    }

    pub fn redraw(self: *@This(), _: common.BBox) !void {
        //var rect: win.Rect = std.mem.zeroes(win.Rect);
        //_ = win.InvalidateRect(self.handle, null, false);
        //_ = win.UpdateWindow(self.handle);
        const window_id = @intFromPtr(self.handle);
        events.push(
            .{
                .draw = .{
                    .window_id = window_id,
                },
            },
        );
    }

    /// Ask the event loop to close this window from the application side — a
    /// quit key. The message pump turns a real `WM_CLOSE` into a `.close`; this
    /// queues the same event directly, since the app is not going through the
    /// window's message queue.
    pub fn requestClose(self: *@This()) void {
        events.push(.{ .close = @intFromPtr(self.handle) });
    }

    /// No vblank source is wired up here, so this backend is tick-paced and
    /// never emits `frame_done`.
    pub fn supportsFramePacing(_: *const @This()) bool {
        return false;
    }

    /// The window's current DPI scale, following the monitor it is on.
    pub fn scale(self: *@This()) f32 {
        const dpi = win.GetDpiForWindow(self.handle);
        if (dpi == 0) return self.scaling;
        return @as(f32, @floatFromInt(dpi)) / 96.0;
    }

    /// No frame callback wired up on Windows; nothing to arm.
    pub fn requestFrame(_: *@This()) void {}

    /// Put `text` on the system clipboard as CF_UNICODETEXT, with this window as the owner.
    /// Line endings become CRLF, the Windows text convention (SDL does the same).
    pub fn setClipboardText(self: *@This(), text: []const u8) !void {
        const units = try clipboardUnitsFromUtf8(self.wm.allocator, text);
        defer self.wm.allocator.free(units);

        try openClipboard(self.wm.io, self.handle);
        defer _ = win.CloseClipboard();
        if (win.EmptyClipboard() == 0) return error.ClipboardUnsupported;

        // The terminating NUL travels with the text.
        const bytes = (units.len + 1) * @sizeOf(u16);
        const block = win.GlobalAlloc(win.GMEM_MOVEABLE, bytes) orelse return error.OutOfMemory;
        {
            const memory = win.GlobalLock(block) orelse {
                _ = win.GlobalFree(block);
                return error.ClipboardUnsupported;
            };
            @memcpy(memory[0..bytes], std.mem.sliceAsBytes(units[0 .. units.len + 1]));
            _ = win.GlobalUnlock(block);
        }
        // On success the system owns the block; on failure it is still ours to free.
        if (win.SetClipboardData(win.CF_UNICODETEXT, block) == null) {
            _ = win.GlobalFree(block);
            return error.ClipboardUnsupported;
        }
    }

    /// The clipboard's text as UTF-8, owned by the caller, with CRLF folded back to LF.
    pub fn getClipboardText(self: *@This(), allocator: std.mem.Allocator) ![]u8 {
        try openClipboard(self.wm.io, self.handle);
        defer _ = win.CloseClipboard();
        if (win.IsClipboardFormatAvailable(win.CF_UNICODETEXT) == 0) return error.ClipboardEmpty;
        const block = win.GetClipboardData(win.CF_UNICODETEXT) orelse return error.ClipboardEmpty;
        const memory = win.GlobalLock(block) orelse return error.ClipboardEmpty;
        defer _ = win.GlobalUnlock(block);
        const size = win.GlobalSize(block);
        const units: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, memory[0 .. size - size % 2]));
        return utf8FromClipboardUnits(allocator, units);
    }

    pub fn beginDraw(self: *@This()) !void {
        const window_dc = win.GetDC(self.handle);
        self.window_dc = window_dc;

        var rect = win.Rect{};
        _ = win.GetClientRect(self.handle, &rect);
        const width = rect.right - rect.left;
        const height = rect.bottom - rect.top;

        if (width == 0 or height == 0) {
            // Minimized — fall back to drawing directly
            self.display = window_dc;
            return;
        }

        const mem_dc = win.CreateCompatibleDC(window_dc);
        const bitmap = win.CreateCompatibleBitmap(window_dc, width, height);
        _ = win.SelectObject(mem_dc, bitmap);

        self.display = mem_dc;
        self.backbuffer = bitmap;
    }

    pub fn hideCursor(self: *@This()) void {
        self.cursor_visible = false;
        cursor_hidden = true;
        saved_cursor = active_cursor;
        active_cursor = null;
        _ = win.SetCursor(null);
    }

    pub fn showCursor(self: *@This()) void {
        self.cursor_visible = true;
        cursor_hidden = false;
        active_cursor = saved_cursor;
        if (active_cursor) |c| _ = win.SetCursor(c);
    }

    pub fn setCursor(self: *@This(), cursor: common.Cursor) void {
        const cursor_name: win.CursorName = switch (cursor) {
            .default => .Arrow,
            .hand => .Hand,
            .crosshair => .Cross,
            .text => .Beam,
            .not_allowed => .No,
            .resize_ns => .SizeNS,
            .resize_ew => .SizeWE,
            .move => .SizeAll,
            .wait => .Wait,
            .resize_nwse => .SizeNWSE,
            .resize_nesw => .SizeNESW,
        };
        self.current_cursor = win.LoadCursorW(null, cursor_name);
        active_cursor = self.current_cursor;
        if (self.cursor_visible) {
            _ = win.SetCursor(self.current_cursor);
        }
    }

    pub fn grabCursor(self: *@This()) void {
        var rect = win.Rect{};
        _ = win.GetClientRect(self.handle, &rect);
        var top_left = win.Point{ .x = rect.left, .y = rect.top };
        var bottom_right = win.Point{ .x = rect.right, .y = rect.bottom };
        _ = win.ClientToScreen(self.handle, &top_left);
        _ = win.ClientToScreen(self.handle, &bottom_right);
        var screen_rect = win.Rect{
            .left = top_left.x,
            .top = top_left.y,
            .right = bottom_right.x,
            .bottom = bottom_right.y,
        };
        _ = win.ClipCursor(&screen_rect);
    }

    pub fn releaseCursor(_: *@This()) void {
        _ = win.ClipCursor(null);
    }

    pub fn endDraw(self: *@This()) !void {
        if (self.backbuffer) |bb| {
            var rect = win.Rect{};
            _ = win.GetClientRect(self.handle, &rect);
            const width = rect.right - rect.left;
            const height = rect.bottom - rect.top;

            _ = win.BitBlt(self.window_dc, 0, 0, width, height, self.display, 0, 0, .SRCCOPY);
            _ = win.DeleteDC(self.display);
            _ = win.DeleteObject(bb);
        }

        _ = win.ReleaseDC(self.handle, self.window_dc);
        _ = win.PostMessageW(self.handle, 0, 0, 0);

        self.window_dc = null;
        self.display = null;
        self.backbuffer = null;
    }
};

pub const Image = struct {
    window: *Window,
    allocator: std.mem.Allocator,
    source_size: common.Size,
    pixels: []u8,
    bitmap_info: win.BitmapInfo,

    pub fn init(allocator: std.mem.Allocator, window: *Window, size: common.Size) !@This() {
        const len = @as(usize, size.width) * size.height * 4;
        const pixels = try allocator.alloc(u8, len);
        @memset(pixels, 0);
        return .{
            .window = window,
            .allocator = allocator,
            .source_size = size,
            .pixels = pixels,
            .bitmap_info = .{
                .header = .{
                    .width = size.width,
                    .height = @as(i32, size.height) * -1,
                },
            },
        };
    }

    pub fn setPixels(self: *@This(), pixels: []const u8) void {
        const len = @as(usize, self.source_size.width) * self.source_size.height * 4;
        const src = pixels[0..len];
        var i: usize = 0;
        while (i + 3 < len) : (i += 4) {
            // RGBA to BGRA
            self.pixels[i] = src[i + 2];
            self.pixels[i + 1] = src[i + 1];
            self.pixels[i + 2] = src[i];
            self.pixels[i + 3] = src[i + 3];
        }
    }

    pub fn draw(self: *@This(), target: common.BBox) !void {
        const result = win.StretchDIBits(
            self.window.display,
            target.x,
            target.y,
            target.width,
            target.height,
            0,
            0,
            self.source_size.width,
            self.source_size.height,
            self.pixels.ptr,
            &self.bitmap_info,
            .RGB_COLORS,
            .SRCCOPY,
        );

        if (result == 0) {
            const err = win.GetLastError();
            log.err("StretchDIBits error: {any}", .{err});
            return error.ErrorStretchDIBits;
        }
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.pixels);
    }
};

var class_count = std.atomic.Value(usize).init(0);
var events: queue.ThreadSafeQueue(common.Event) = undefined;
var active_cursor: ?win.CursorHandler = null;
var saved_cursor: ?win.CursorHandler = null;
var cursor_hidden: bool = false;
var cursor_initialized: bool = false;

/// Each window get it's own thread.
/// WindowCreation and Message receiving must run on own thread.
const WindowThread = struct {
    wm: *WindowManager,
    options: common.WindowOptions,
    class_name: [:0]u16,
    title: [:0]u16,
    background: ?win.BrushHandler,

    // Output — written by thread before signaling ready
    handle: ?win.WindowHandle = null,
    frame: ?win.DeviceContext = null,
    scaling: f32 = 1.0,
    thread_id: u32 = 0,
    init_err: bool = false,

    // Sync
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    ready: bool = false,

    /// create window, check DPI and start loop to receive messages
    fn run(self: *@This()) void {
        self.mutex.lockUncancelable(self.wm.io);

        self.thread_id = win.GetCurrentThreadId();

        const handle = win.CreateWindowExW(
            win.ExtendedWindowStyle.OverlappedWindow,
            self.class_name,
            self.title,
            win.WindowStyle.OverlappedWindow,
            self.options.x orelse win.UseDefault,
            self.options.y orelse win.UseDefault,
            self.options.width orelse win.UseDefault,
            self.options.height orelse win.UseDefault,
            null,
            null,
            self.wm.instance,
            null,
        );
        if (handle == null) {
            self.init_err = true;
            self.ready = true;
            self.cond.signal(self.wm.io);
            self.mutex.unlock(self.wm.io);
            return;
        }
        self.handle = handle;

        const frame = win.CreateCompatibleDC(null);
        if (frame == null) {
            self.init_err = true;
            self.ready = true;
            self.cond.signal(self.wm.io);
            self.mutex.unlock(self.wm.io);
            return;
        }
        self.frame = frame;

        const dpi = win.GetDpiForWindow(handle);
        self.scaling = @as(f32, @floatFromInt(dpi)) / 96.0;

        self.ready = true;
        self.cond.signal(self.wm.io);
        self.mutex.unlock(self.wm.io);

        // Message pump — blocks until WM_QUIT
        var msg: win.Message = undefined;
        while (win.GetMessageW(&msg, null, 0, 0) > 0) {
            _ = win.TranslateMessage(&msg);
            _ = win.DispatchMessageW(&msg);
            if (msg.message == .WM_KEYDOWN or msg.message == .WM_SYSKEYDOWN) {
                takeCharacterMessages(msg.hwnd);
                flushPendingKey();
            }
        }
    }

    /// TranslateMessage queues the character a key down produces (WM_CHAR,
    /// WM_DEADCHAR or WM_UNICHAR) behind the key message. Dispatch it now,
    /// so the key_pressed carries its codepoint instead of waiting for
    /// whatever message comes next.
    fn takeCharacterMessages(window_handle: ?win.WindowHandle) void {
        var msg: win.Message = undefined;
        while (PeekMessageW(&msg, window_handle, @intFromEnum(win.MessageType.WM_CHAR), @intFromEnum(win.MessageType.WM_DEADCHAR), pm_remove) != 0) {
            _ = win.DispatchMessageW(&msg);
        }
        while (PeekMessageW(&msg, window_handle, wm_unichar_code, wm_unichar_code, pm_remove) != 0) {
            _ = win.DispatchMessageW(&msg);
        }
    }

    /// Wait for thread to finish window creation
    fn wait(self: *@This()) !void {
        self.mutex.lockUncancelable(self.wm.io);
        while (!self.ready) self.cond.waitUncancelable(self.wm.io, &self.mutex);
        self.mutex.unlock(self.wm.io);

        if (self.init_err) return error.CreateWindowError;
    }
};

pub fn windowProc(
    window_handle: win.WindowHandle,
    message_type: win.MessageType,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const window_id = @intFromPtr(window_handle);
    switch (message_type) {
        .WM_CLOSE => {
            events.push(.{ .close = window_id });
        },
        .WM_ERASEBKGND => {},
        .WM_PAINT => {
            events.push(.{
                .draw = .{
                    .window_id = window_id,
                    .area = .{},
                },
            });

            var paint = std.mem.zeroes(win.Paint);
            _ = win.BeginPaint(window_handle, &paint);
            _ = win.EndPaint(window_handle, &paint);
        },
        .WM_LBUTTONDOWN => {
            const x = win.loword(lparam);
            const y = win.hiword(lparam);

            events.push(.{
                .mouse_pressed = .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                    .button = 1,
                    .window_id = window_id,
                },
            });
        },
        .WM_LBUTTONUP => {
            const x = win.loword(lparam);
            const y = win.hiword(lparam);

            events.push(.{
                .mouse_released = .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                    .button = 1,
                    .window_id = window_id,
                },
            });
        },
        .WM_MBUTTONDOWN => {
            const x = win.loword(lparam);
            const y = win.hiword(lparam);

            events.push(.{
                .mouse_pressed = .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                    .button = 2,
                    .window_id = window_id,
                },
            });
        },
        .WM_MBUTTONUP => {
            const x = win.loword(lparam);
            const y = win.hiword(lparam);
            events.push(.{
                .mouse_released = .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                    .button = 2,
                    .window_id = window_id,
                },
            });
        },
        .WM_RBUTTONDOWN => {
            const x = win.loword(lparam);
            const y = win.hiword(lparam);

            events.push(.{
                .mouse_pressed = .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                    .button = 3,
                    .window_id = window_id,
                },
            });
        },
        .WM_RBUTTONUP => {
            const x = win.loword(lparam);
            const y = win.hiword(lparam);

            events.push(.{
                .mouse_released = .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                    .button = 3,
                    .window_id = window_id,
                },
            });
        },
        .WM_MOUSEMOVE => {
            const x = win.loword(lparam);
            const y = win.hiword(lparam);

            events.push(.{
                .mouse_moved = .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                    .window_id = window_id,
                },
            });
        },
        .WM_KEYDOWN => {
            const flags: win.KeystrokeFlags = @bitCast(lparam);
            const sc = keys.windowsScanToScancode(flags.scanCode, flags.extended == 1);
            const vk: u8 = @truncate(wparam);
            const key = keys.windowsVkToKey(vk);
            const mods = getWindowsModifiers();

            // Held until its WM_CHAR arrives (or does not); see the pump.
            flushPendingKey();
            pending_key = .{
                .scancode = sc,
                .key = key,
                .modifiers = mods,
                .repeat = flags.previousState == 1,
                .window_id = window_id,
            };
        },
        .WM_CHAR => {
            pushCharacterUtf16(window_id, @truncate(wparam));
        },
        wm_unichar => {
            // UNICODE_NOCHAR asks whether we take UTF-32 characters; yes.
            if (wparam == 0xFFFF) return 1;
            const codepoint = std.math.cast(u21, wparam) orelse return 0;
            pushCharacter(window_id, codepoint);
        },
        wm_setfocus => {
            events.push(.{ .focus_in = window_id });
            return 0;
        },
        wm_killfocus => {
            flushPendingKey();
            events.push(.{ .focus_out = window_id });
            return 0;
        },
        .WM_KEYUP => {
            const flags: win.KeystrokeFlags = @bitCast(lparam);
            const sc = keys.windowsScanToScancode(flags.scanCode, flags.extended == 1);
            const vk: u8 = @truncate(wparam);
            const key = keys.windowsVkToKey(vk);
            const mods = getWindowsModifiers();

            events.push(.{
                .key_released = .{
                    .scancode = sc,
                    .key = key,
                    .modifiers = mods,
                    .window_id = window_id,
                },
            });
        },
        .WM_CREATE => {
            return win.DefWindowProcW(window_handle, message_type, wparam, lparam);
        },
        .WM_DPICHANGED => {
            // wParam carries the new DPI (x in the low word), lParam the
            // rectangle Windows suggests so the window keeps its size on
            // the new monitor; a resize follows through WM_SIZE.
            const dpi: u32 = @intCast(wparam & 0xFFFF);
            events.push(.{ .scale_changed = .{
                .window_id = window_id,
                .scale = @as(f32, @floatFromInt(dpi)) / 96.0,
            } });
            const suggested: *const win.Rect = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = win.SetWindowPos(
                window_handle,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                win.SWP_NOZORDER,
            );
            return 0;
        },
        .WM_SETCURSOR => {
            if ((lparam & 0xFFFF) == win.HTCLIENT) {
                // Lazy-init default cursor on first WM_SETCURSOR
                if (!cursor_initialized) {
                    active_cursor = win.LoadCursorW(null, .Arrow);
                    saved_cursor = active_cursor;
                    cursor_initialized = true;
                }
                if (cursor_hidden) {
                    _ = win.SetCursor(null);
                    return 1;
                }
                if (active_cursor) |c| {
                    _ = win.SetCursor(c);
                    return 1;
                }
            }
            return win.DefWindowProcW(window_handle, message_type, wparam, lparam);
        },
        .WM_MOUSEWHEEL => {
            const delta_raw: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            const delta: f32 = @as(f32, @floatFromInt(delta_raw)) / @as(f32, @floatFromInt(win.WHEEL_DELTA));
            // WM_MOUSEWHEEL gives screen coords — convert to client
            var pt = win.Point{ .x = @as(i32, @bitCast(@as(u32, @truncate(@as(u64, @bitCast(lparam)))))), .y = @as(i32, @bitCast(@as(u32, @truncate(@as(u64, @bitCast(lparam)) >> 32)))) };
            _ = win.ScreenToClient(window_handle, &pt);
            events.push(.{ .mouse_scroll = .{
                .x = @intCast(std.math.clamp(pt.x, std.math.minInt(i16), std.math.maxInt(i16))),
                .y = @intCast(std.math.clamp(pt.y, std.math.minInt(i16), std.math.maxInt(i16))),
                .scroll_x = 0,
                .scroll_y = delta,
                .window_id = window_id,
            } });
        },
        .WM_MOUSEHWHEEL => {
            const delta_raw: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            const delta: f32 = @as(f32, @floatFromInt(delta_raw)) / @as(f32, @floatFromInt(win.WHEEL_DELTA));
            var pt = win.Point{ .x = @as(i32, @bitCast(@as(u32, @truncate(@as(u64, @bitCast(lparam)))))), .y = @as(i32, @bitCast(@as(u32, @truncate(@as(u64, @bitCast(lparam)) >> 32)))) };
            _ = win.ScreenToClient(window_handle, &pt);
            events.push(.{ .mouse_scroll = .{
                .x = @intCast(std.math.clamp(pt.x, std.math.minInt(i16), std.math.maxInt(i16))),
                .y = @intCast(std.math.clamp(pt.y, std.math.minInt(i16), std.math.maxInt(i16))),
                .scroll_x = delta,
                .scroll_y = 0,
                .window_id = window_id,
            } });
        },
        .WM_SIZE => {
            const width = win.loword(lparam);
            const height = win.hiword(lparam);
            events.push(.{
                .resize = .{
                    .width = width,
                    .height = height,
                    .window_id = window_id,
                },
            });
        },
        else => {
            return win.DefWindowProcW(window_handle, message_type, wparam, lparam);
        },
    }
    return 1;
}

// Message codes windowz does not name; MessageType is non-exhaustive.
const wm_setfocus: win.MessageType = @enumFromInt(0x0007);
const wm_killfocus: win.MessageType = @enumFromInt(0x0008);
const wm_unichar_code: u32 = 0x0109;
const wm_unichar: win.MessageType = @enumFromInt(wm_unichar_code);
const pm_remove: u32 = 0x0001;

extern "user32" fn PeekMessageW(
    message: *win.Message,
    window_handle: ?win.WindowHandle,
    filter_min: u32,
    filter_max: u32,
    remove: u32,
) callconv(.winapi) c_int;

/// A key down waiting for the character message that follows it. Each window
/// runs its own message thread, so this is per thread.
const PendingKey = struct {
    scancode: common.Scancode,
    key: common.Key,
    modifiers: common.Modifiers,
    repeat: bool,
    window_id: common.WindowID,
};

threadlocal var pending_key: ?PendingKey = null;
threadlocal var pending_high_surrogate: ?u16 = null;

/// Emit the waiting key down with no character.
fn flushPendingKey() void {
    const pending = pending_key orelse return;
    pending_key = null;
    events.push(.{ .key_pressed = .{
        .scancode = pending.scancode,
        .key = pending.key,
        .modifiers = pending.modifiers,
        .codepoint = null,
        .repeat = pending.repeat,
        .window_id = pending.window_id,
    } });
}

/// One WM_CHAR code unit: surrogate pairs arrive as two messages.
fn pushCharacterUtf16(window_id: common.WindowID, unit: u16) void {
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        pending_high_surrogate = unit;
        return;
    }
    var codepoint: u21 = unit;
    if (unit >= 0xDC00 and unit <= 0xDFFF) {
        const high = pending_high_surrogate orelse return;
        pending_high_surrogate = null;
        codepoint = 0x10000 + ((@as(u21, high) - 0xD800) << 10) + (unit - 0xDC00);
    }
    pushCharacter(window_id, codepoint);
}

/// Attach a character to the waiting key down, or — when it arrives on its
/// own (an IME, Alt+numpad) — report it as a press of no particular key.
/// Control characters (Enter, Backspace, Ctrl combinations) are not text.
fn pushCharacter(window_id: common.WindowID, codepoint: u21) void {
    const text: ?u21 = if (codepoint < 0x20 or codepoint == 0x7F) null else codepoint;
    if (pending_key) |pending| {
        pending_key = null;
        events.push(.{ .key_pressed = .{
            .scancode = pending.scancode,
            .key = pending.key,
            .modifiers = pending.modifiers,
            .codepoint = text,
            .repeat = pending.repeat,
            .window_id = pending.window_id,
        } });
        return;
    }
    const character = text orelse return;
    events.push(.{ .key_pressed = .{
        .scancode = .unknown,
        .key = .unknown,
        .modifiers = getWindowsModifiers(),
        .codepoint = character,
        .repeat = false,
        .window_id = window_id,
    } });
}

/// Another process may hold the clipboard open for a moment; retry briefly before giving up.
fn openClipboard(io: std.Io, owner: ?win.WindowHandle) !void {
    for (0..clipboard_open_attempts) |_| {
        if (win.OpenClipboard(owner) != 0) return;
        io.sleep(clipboard_open_retry, .awake) catch return error.ClipboardUnsupported;
    }
    return error.ClipboardUnsupported;
}

const clipboard_open_attempts = 10;
const clipboard_open_retry = std.Io.Duration.fromMilliseconds(10);

/// UTF-8 to the NUL-terminated UTF-16 CF_UNICODETEXT wants, with every bare LF turned into
/// CRLF on the way.
fn clipboardUnitsFromUtf8(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    var crlf: std.ArrayList(u8) = .empty;
    defer crlf.deinit(allocator);
    try crlf.ensureTotalCapacity(allocator, text.len + 1);
    var previous: u8 = 0;
    for (text) |byte| {
        if (byte == '\n' and previous != '\r') try crlf.append(allocator, '\r');
        try crlf.append(allocator, byte);
        previous = byte;
    }
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, crlf.items) catch |err| switch (err) {
        error.InvalidUtf8 => return error.ClipboardUnsupported,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// CF_UNICODETEXT (up to its NUL) to UTF-8, with CRLF folded back to LF.
fn utf8FromClipboardUnits(allocator: std.mem.Allocator, units: []const u16) ![]u8 {
    const terminated = std.mem.sliceTo(units, 0);
    const utf8 = std.unicode.utf16LeToUtf8Alloc(allocator, terminated) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ClipboardUnsupported,
    };
    // Fold in place: the result only ever shrinks.
    var write: usize = 0;
    for (utf8, 0..) |byte, read| {
        if (byte == '\r' and read + 1 < utf8.len and utf8[read + 1] == '\n') continue;
        utf8[write] = byte;
        write += 1;
    }
    if (write == utf8.len) return utf8;
    return allocator.realloc(utf8, write) catch utf8[0..write];
}

test "clipboard text goes out as CRLF UTF-16 and comes back as LF UTF-8" {
    const units = try clipboardUnitsFromUtf8(testing.allocator, "a\nb\r\nc é");
    defer testing.allocator.free(units);
    const expected = std.unicode.utf8ToUtf16LeStringLiteral("a\r\nb\r\nc é");
    try testing.expectEqualSlices(u16, expected, units);

    const with_nul = [_]u16{ 'x', '\r', '\n', 'y', 0, 'z' };
    const back = try utf8FromClipboardUnits(testing.allocator, &with_nul);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("x\ny", back);
}

/// RGB to ABGR
fn commonPixelToWinPixel(src: [3]u8) u32 {
    const dst: [4]u8 = [4]u8{ 0, src[2], src[1], src[0] };
    return std.mem.bytesToValue(u32, &dst);
}

fn getWindowsModifiers() common.Modifiers {
    return .{
        .shift = win.GetKeyState(0x10) < 0,
        .control = win.GetKeyState(0x11) < 0,
        .alt = win.GetKeyState(0x12) < 0,
        .super = (win.GetKeyState(0x5B) < 0) or (win.GetKeyState(0x5C) < 0),
        .caps_lock = (win.GetKeyState(0x14) & 1) != 0,
        .num_lock = (win.GetKeyState(0x90) & 1) != 0,
    };
}

// Nothing in the test build calls the clipboard methods; take their addresses on Windows so
// they are analyzed (on other targets that would drag in user32 at link time).
test "clipboard entry points compile" {
    if (builtin.os.tag == .windows) {
        _ = &Window.setClipboardText;
        _ = &Window.getClipboardText;
    }
}

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const win = @import("windows");
const common = @import("common.zig");
const queue = @import("queue.zig");
const keys = @import("keys.zig");

const log = std.log.scoped(.any_win32);
