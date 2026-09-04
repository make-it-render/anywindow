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

    /// The OLE drop target registered on the window thread; outlives the thread, and holds the drop payload and the drag flag.
    drop_target: *win32_drag.Target,

    pub fn init(wm: *WindowManager, options: common.WindowOptions) !@This() {
        const count = class_count.fetchAdd(1, .monotonic);
        const class_name_n = try std.fmt.allocPrint(wm.allocator, "WindowClass_{d}", .{count});
        defer wm.allocator.free(class_name_n);

        const class_name = try win.W(wm.allocator, class_name_n);
        const background = win.CreateSolidBrush(commonPixelToWinPixel(options.background));
        // Heap-allocated: the thread registers it after `init` has returned, and OLE holds it until the thread revokes it.
        const drop_target = try win32_drag.Target.create(wm.allocator, wm.io, &events);
        errdefer drop_target.com.release();

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
            .drop_target = drop_target,
        };

        // TODO: check for support in single_threaded build
        const thread = std.Thread.spawn(.{}, WindowThread.run, .{&ctx}) catch return error.ThreadSpawnError;
        ctx.wait() catch |err| {
            thread.join();
            return err;
        };

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
            .drop_target = drop_target,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.thread_id != 0) {
            _ = win.PostThreadMessageW(self.thread_id, @intFromEnum(win.MessageType.WM_QUIT), 0, 0);
        }
        if (self.thread) |t| t.join();
        // The thread revoked the registration before ending, so this is the last reference.
        self.drop_target.com.release();
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
        // Our own change is not news: the WM_CLIPBOARDUPDATE it raises (on CloseClipboard,
        // below) quotes this sequence number and is dropped as already reported.
        reported_clipboard_sequence.store(win.GetClipboardSequenceNumber(), .monotonic);
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

    /// Windows has no primary selection (nothing middle-click pastes), so there is nowhere
    /// to put the text: a no-op that succeeds.
    pub fn setPrimaryText(_: *@This(), text: []const u8) !void {
        _ = text;
    }

    /// Windows has no primary selection, so it is always empty: `error.ClipboardEmpty`.
    pub fn getPrimaryText(_: *@This(), allocator: std.mem.Allocator) ![]u8 {
        _ = allocator;
        return error.ClipboardEmpty;
    }

    /// Take drops of the given kinds; `.{}` turns them off again. The window was registered with OLE when its thread started, so this only records what to accept; `error.DragUnsupported` when that registration failed (OLE refused, or the thread was already in the multithreaded apartment).
    pub fn setDropTarget(self: *@This(), kinds: common.DropKinds) common.DragError!void {
        if (!self.drop_target.ready.load(.acquire)) return error.DragUnsupported;
        self.drop_target.setKinds(kinds);
    }

    /// The newest drop's payload, copied into `allocator`; the stored one is freed. `error.NoDrop` when none is pending.
    pub fn takeDrop(self: *@This(), allocator: std.mem.Allocator) (common.DropError || std.mem.Allocator.Error)!common.DropData {
        return self.drop_target.takeDrop(allocator);
    }

    /// Start dragging `data` out of this window: the payload is rendered here, and the drag itself (`DoDragDrop`, a modal loop) runs on the window thread from a posted message, ending in `drag_finished`. Needs a mouse button down (`error.DragNoButton`), one drag at a time per window (`error.DragInProgress`), and OLE on the window thread (`error.DragUnsupported`, also the answer for a payload that is not UTF-8).
    pub fn startDrag(self: *@This(), data: common.DragData) common.DragError!void {
        const target = self.drop_target;
        if (!target.ready.load(.acquire)) return error.DragUnsupported;
        if (!win32_drag.buttonHeld()) return error.DragNoButton;
        if (target.dragging.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return error.DragInProgress;
        errdefer target.dragging.store(false, .release);

        const object = win32_drag.Data.create(self.wm.allocator, data) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.debug("Drag payload could not be rendered: {t}", .{err});
                return error.DragUnsupported;
            },
        };
        errdefer object.com.release();
        const source = win32_drag.Source.create(self.wm.allocator) catch return error.OutOfMemory;
        errdefer source.com.release();
        if (win.PostMessageW(self.handle, wm_start_drag_code, @intFromPtr(object), @bitCast(@intFromPtr(source))) == .not_ok) {
            return error.DragUnsupported;
        }
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
/// The clipboard sequence number of the last change surfaced as `clipboard_changed` (or made
/// by `setClipboardText`). Every window's thread gets its own WM_CLIPBOARDUPDATE for one
/// change; this makes it one event, and none for our own copies.
var reported_clipboard_sequence = std.atomic.Value(u32).init(0);
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
    drop_target: *win32_drag.Target,

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

        // OLE goes up before the window, since the registration below belongs to this thread's apartment, and comes down after the pump. A thread already in the multithreaded apartment is refused (RPC_E_CHANGED_MODE), which leaves the window without drag and drop rather than without a window.
        const ole_result = ole.OleInitialize(null);
        const ole_ready = ole.succeeded(ole_result);
        if (!ole_ready) log.debug("OleInitialize failed ({x}); no drag and drop", .{@as(u32, @bitCast(@intFromEnum(ole_result)))});
        defer if (ole_ready) ole.OleUninitialize();
        const drop_target = self.drop_target;
        defer revokeDropTarget(drop_target);

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
        // Clipboard changes arrive as WM_CLIPBOARDUPDATE on this thread's pump; the system
        // unregisters the window when it is destroyed.
        if (win.AddClipboardFormatListener(handle.?) == 0) {
            log.debug("AddClipboardFormatListener failed ({d}); no clipboard_changed events", .{win.GetLastError()});
        }

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

        // The drop target is registered unconditionally; the kinds decide what it accepts. The window procedure reaches it through the window's user data for the drag message.
        drop_target.handle = handle;
        drop_target.window_id = @intFromPtr(handle.?);
        _ = win.SetWindowLongPtrW(handle, win.GWLP_USERDATA, @bitCast(@intFromPtr(drop_target)));
        if (ole_ready) {
            const registered = ole.RegisterDragDrop(handle.?, drop_target.com.interface());
            if (ole.succeeded(registered)) {
                drop_target.ready.store(true, .release);
            } else {
                log.debug("RegisterDragDrop failed ({x}); no drag and drop", .{@as(u32, @bitCast(@intFromEnum(registered)))});
            }
        }

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

    /// Undo the registration, on the thread that made it, before OLE goes down with it.
    fn revokeDropTarget(drop_target: *win32_drag.Target) void {
        if (!drop_target.ready.load(.acquire)) return;
        drop_target.ready.store(false, .release);
        _ = ole.RevokeDragDrop(drop_target.handle.?);
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
        .WM_CLIPBOARDUPDATE => {
            if (noteClipboardSequence(win.GetClipboardSequenceNumber())) {
                events.push(.{ .clipboard_changed = {} });
            }
            return 0;
        },
        wm_start_drag => {
            // Posted by `startDrag` with the two objects it built; the drag runs to its end here, on the thread that owns the window, and the objects go with it.
            const data: *win32_drag.Data = @ptrFromInt(wparam);
            const source: *win32_drag.Source = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const accepted = win32_drag.runDrag(data, source);
            events.push(.{ .drag_finished = .{ .accepted = accepted, .window_id = window_id } });
            if (dropTargetOf(window_handle)) |target| target.dragging.store(false, .release);
            return 0;
        },
        else => {
            return win.DefWindowProcW(window_handle, message_type, wparam, lparam);
        },
    }
    return 1;
}

/// The window's drop target, kept in its user data by the window thread.
fn dropTargetOf(window_handle: win.WindowHandle) ?*win32_drag.Target {
    const stored = win.GetWindowLongPtrW(window_handle, win.GWLP_USERDATA);
    if (stored == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(stored)));
}

/// Whether a WM_CLIPBOARDUPDATE quoting `sequence` is a change nobody has reported yet; see
/// `reported_clipboard_sequence`. The swap makes the first of several windows the reporter.
fn noteClipboardSequence(sequence: u32) bool {
    const previous = reported_clipboard_sequence.swap(sequence, .monotonic);
    return previous != sequence;
}

test "noteClipboardSequence reports each sequence number once" {
    reported_clipboard_sequence.store(0, .monotonic);
    try testing.expect(noteClipboardSequence(7));
    try testing.expect(!noteClipboardSequence(7));
    try testing.expect(noteClipboardSequence(8));
    // A copy of our own records its number first, so its update is not reported.
    reported_clipboard_sequence.store(9, .monotonic);
    try testing.expect(!noteClipboardSequence(9));
}

// Message codes windowz does not name; MessageType is non-exhaustive.
const wm_setfocus: win.MessageType = @enumFromInt(0x0007);
const wm_killfocus: win.MessageType = @enumFromInt(0x0008);
const wm_unichar_code: u32 = 0x0109;
const wm_unichar: win.MessageType = @enumFromInt(wm_unichar_code);
/// `startDrag`'s message to the window thread: wParam the data object, lParam the drop source.
const wm_start_drag_code: u32 = win.WM_USER + 1;
const wm_start_drag: win.MessageType = @enumFromInt(wm_start_drag_code);
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
pub fn clipboardUnitsFromUtf8(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
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
pub fn utf8FromClipboardUnits(allocator: std.mem.Allocator, units: []const u16) ![]u8 {
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
        _ = &Window.setPrimaryText;
        _ = &Window.getPrimaryText;
        _ = &Window.setDropTarget;
        _ = &Window.takeDrop;
        _ = &Window.startDrag;
        _ = &windowProc;
    }
}

// A drag from one of our windows onto itself, through OLE's own loop: the pointer is warped into the client area and a button pressed with synthetic input, the drag is started, then the button released; the window must see the hover, the drop with the payload, and the finish. Runs under Wine, whose `DoDragDrop` loops over its own message queue.
test "a drag from the window onto itself delivers text and files through OLE" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var wm = try WindowManager.init(testing.io, .empty, testing.allocator);
    defer wm.deinit();
    var window = try wm.createWindow(.{ .title = "mir drop", .x = 100, .y = 100, .width = 320, .height = 240 });
    defer window.deinit();
    try window.show();
    // The window manager may still be placing the window; the pointer must land where it ends up.
    try testing.io.sleep(settle, .awake);
    try window.setDropTarget(.{ .text = true, .files = true });
    try testing.expectError(error.NoDrop, window.takeDrop(testing.allocator));

    // No button is down, so there is nothing to hang a drag on.
    try testing.expectError(error.DragNoButton, window.startDrag(.{ .text = "x" }));

    try dragOntoSelf(&window, .{ .text = "hello\ndrop é" }, .text);
    const text = try window.takeDrop(testing.allocator);
    defer text.deinit(testing.allocator);
    try testing.expectEqualStrings("hello\ndrop é", text.text);
    try testing.expectError(error.NoDrop, window.takeDrop(testing.allocator));

    try dragOntoSelf(&window, .{ .files = &.{ "C:\\Users\\mir\\a b.txt", "D:\\y.png" } }, .files);
    const files = try window.takeDrop(testing.allocator);
    defer files.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), files.files.len);
    try testing.expectEqualStrings("C:\\Users\\mir\\a b.txt", files.files[0]);
    try testing.expectEqualStrings("D:\\y.png", files.files[1]);

    // A window taking nothing refuses the hover: no events, and the drag ends unaccepted.
    try window.setDropTarget(.{});
    try pressInside(&window);
    try window.startDrag(.{ .text = "refused" });
    try testing.expectError(error.DragInProgress, window.startDrag(.{ .text = "again" }));
    try testing.io.sleep(settle, .awake);
    sendMouse(win.MOUSEEVENTF_MOVE);
    sendMouse(win.MOUSEEVENTF_MOVE);
    sendMouse(win.MOUSEEVENTF_LEFTUP);
    const refused = try awaitEvent(.drag_finished, &.{ .drag_enter, .drag_motion, .drop });
    try testing.expect(!refused.drag_finished.accepted);
    try testing.expectError(error.NoDrop, window.takeDrop(testing.allocator));
}

const settle = std.Io.Duration.fromMilliseconds(300);
const poll_interval = std.Io.Duration.fromMilliseconds(10);
/// Five seconds of `poll_interval`, the most a drag step is waited for.
const await_polls = 500;
const nudge_limit = 100;
const polls_per_nudge = 5;

/// Press the left button in the middle of the client area and wait for the window to see it.
fn pressInside(window: *Window) !void {
    var origin = win.Point{ .x = 0, .y = 0 };
    _ = win.ClientToScreen(window.handle, &origin);
    _ = win.SetCursorPos(origin.x + 100, origin.y + 80);
    sendMouse(win.MOUSEEVENTF_LEFTDOWN);
    _ = try awaitEvent(.mouse_pressed, &.{});
}

/// A whole drag of `data` onto the window: the hover must arrive as `kind`, then the drop, then the finish saying it was taken.
fn dragOntoSelf(window: *Window, data: common.DragData, kind: common.DropKind) !void {
    try pressInside(window);
    try window.startDrag(data);
    // OLE reports the hover on the next mouse message, so nudge the pointer until it does.
    const enter = try nudgeUntil(.drag_enter, &.{ .drop, .drag_finished });
    try testing.expectEqual(kind, enter.drag_enter.kind);
    sendMouse(win.MOUSEEVENTF_MOVE);
    sendMouse(win.MOUSEEVENTF_LEFTUP);
    const dropped = try awaitEvent(.drop, &.{.drag_finished});
    try testing.expectEqual(kind, dropped.drop.kind);
    try testing.expect(dropped.drop.x > 0 and dropped.drop.y > 0);
    const finished = try awaitEvent(.drag_finished, &.{});
    try testing.expect(finished.drag_finished.accepted);
}

/// Move the pointer a pixel at a time until `wanted` arrives; a `forbidden` event fails.
fn nudgeUntil(comptime wanted: std.meta.Tag(common.Event), comptime forbidden: []const std.meta.Tag(common.Event)) !common.Event {
    var nudges: u32 = 0;
    while (nudges < nudge_limit) : (nudges += 1) {
        sendMouse(win.MOUSEEVENTF_MOVE);
        var polls: u32 = 0;
        while (polls < polls_per_nudge) : (polls += 1) {
            if (events.pull()) |event| {
                inline for (forbidden) |tag| if (event == tag) return error.UnexpectedEvent;
                if (event == wanted) return event;
                continue;
            }
            try testing.io.sleep(poll_interval, .awake);
        }
    }
    return error.EventTimeout;
}

/// The next `wanted` event within `await_polls`, skipping the rest; a `forbidden` one fails.
fn awaitEvent(comptime wanted: std.meta.Tag(common.Event), comptime forbidden: []const std.meta.Tag(common.Event)) !common.Event {
    var polls: u32 = 0;
    while (polls < await_polls) : (polls += 1) {
        if (events.pull()) |event| {
            inline for (forbidden) |tag| if (event == tag) return error.UnexpectedEvent;
            if (event == wanted) return event;
            continue;
        }
        try testing.io.sleep(poll_interval, .awake);
    }
    return error.EventTimeout;
}

fn sendMouse(flags: u32) void {
    const move = flags == win.MOUSEEVENTF_MOVE;
    const inputs = [_]win.Input{.{ .mouse = .{ .dx = if (move) 1 else 0, .dy = 0, .flags = flags } }};
    _ = win.SendInput(inputs.len, &inputs, @sizeOf(win.Input));
}

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const win = @import("windows");
const ole = win.ole;
const common = @import("common.zig");
const queue = @import("queue.zig");
const keys = @import("keys.zig");
const win32_drag = @import("win32_drag.zig");

const log = std.log.scoped(.any_win32);
