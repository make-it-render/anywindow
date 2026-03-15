pub const WindowManager = struct {
    allocator: std.mem.Allocator,

    instance: ?win.Instance,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        const instance = win.GetModuleHandleW(null);
        if (instance == null) {
            const e = win.GetLastError();
            log.err("Error getting instance {d}", .{e});
            return error.InitError;
        }
        _ = win.SetProcessDPIAware();

        return .{
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

    pub fn receive(_: *@This()) !?common.Event {
        return events.receive();
    }

    /// Unblock any thread waiting in receive() so it returns null.
    pub fn stop(_: *@This()) void {
        events.close();
    }

    pub fn flush(_: *@This()) !void {
        _ = win.DwmFlush();
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

    // fullscreen state
    is_fullscreen: bool = false,
    saved_style: isize = 0,
    saved_rect: win.Rect = .{},

    pub fn init(wm: *WindowManager, options: common.WindowOptions) !@This() {
        const count = class_count.fetchAdd(1, .monotonic);
        const class_name_n = try std.fmt.allocPrint(wm.allocator, "WindowClass_{d}", .{count});
        defer wm.allocator.free(class_name_n);

        const class_name = try win.W(wm.allocator, class_name_n);
        const cursor = win.LoadCursorW(null, .Arrow);
        const background = win.CreateSolidBrush(commonPixelToWinPixel(options.background));

        const window_class: win.WindowClass = .{
            .style = 0,
            .window_procedure = windowProc,
            .instance = wm.instance,
            .class_name = class_name,
            .cursor = cursor,
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

    pub fn createImage(self: *@This(), size: common.Size) !Image {
        return Image.init(self, size);
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
        self.window_dc = null;
        self.display = null;
        self.backbuffer = null;
    }
};

pub const Image = struct {
    window: *Window,
    size: common.Size,

    bitmap: win.Bitmap,
    pixels: [*]u8,

    pub fn init(window: *Window, size: common.Size) !@This() {
        var pixels: [*]u8 = undefined;
        const bitmap_info = win.BitmapInfo{
            .header = .{
                .width = size.width,
                .height = @as(i32, size.height) * -1,
            },
        };

        const bitmap = win.CreateDIBSection(
            null,
            &bitmap_info,
            .RGB_COLORS,
            &pixels,
            null,
            0,
        );
        if (bitmap == null) {
            const err = win.GetLastError();
            log.err("CreateDIBSection error: {any}", .{err});
            return error.ErrorCreatingImage;
        }

        return .{
            .bitmap = bitmap.?,
            .window = window,
            .size = size,
            .pixels = pixels,
        };
    }

    pub fn setPixels(self: @This(), pixels: []const u8) !void {
        const expected = @as(usize, self.size.width) * @as(usize, self.size.height) * 4;
        if (pixels.len < expected) return error.InsufficientPixelData;
        var i: usize = 0;
        while (i + 3 < pixels.len) : (i += 4) {
            // RGB to BGR
            self.pixels[i] = pixels[i + 2];
            self.pixels[i + 1] = pixels[i + 1];
            self.pixels[i + 2] = pixels[i];
            self.pixels[i + 3] = pixels[i + 3];
        }
    }

    pub fn draw(self: @This(), target: common.BBox) !void {
        _ = win.SelectObject(self.window.frame, self.bitmap);

        const bitBltResult = win.BitBlt(
            self.window.display,
            target.x,
            target.y,
            target.width,
            target.height,
            self.window.frame,
            0,
            0,
            .SRCCOPY,
        );

        if (!bitBltResult) {
            const err = win.GetLastError();
            log.err("BitBlt error: {any}", .{err});
            return error.ErrorBitBlt;
        }
    }

    pub fn deinit(self: @This()) void {
        _ = win.DeleteObject(self.bitmap);
    }
};

var class_count = std.atomic.Value(usize).init(0);
var events: queue.ThreadSafeQueue(common.Event) = .{};

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
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    ready: bool = false,

    /// create window, check DPI and start loop to receive messages
    fn run(self: *@This()) void {
        self.mutex.lock();

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
            self.cond.signal();
            self.mutex.unlock();
            return;
        }
        self.handle = handle;

        const frame = win.CreateCompatibleDC(null);
        if (frame == null) {
            self.init_err = true;
            self.ready = true;
            self.cond.signal();
            self.mutex.unlock();
            return;
        }
        self.frame = frame;

        const dpi = win.GetDpiForWindow(handle);
        self.scaling = @as(f32, @floatFromInt(dpi)) / 96.0;

        self.ready = true;
        self.cond.signal();
        self.mutex.unlock();

        // Message pump — blocks until WM_QUIT
        var msg: win.Message = undefined;
        while (win.GetMessageW(&msg, null, 0, 0) > 0) {
            _ = win.TranslateMessage(&msg);
            _ = win.DispatchMessageW(&msg);
        }
    }

    /// Wait for thread to finish window creation
    fn wait(self: *@This()) !void {
        self.mutex.lock();
        while (!self.ready) self.cond.wait(&self.mutex);
        self.mutex.unlock();

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

            events.push(.{
                .key_pressed = .{
                    .scancode = sc,
                    .key = key,
                    .modifiers = mods,
                    .window_id = window_id,
                },
            });
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
            return win.DefWindowProcW(window_handle, message_type, wparam, lparam);
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

const std = @import("std");
const win = @import("windows");
const common = @import("common.zig");
const queue = @import("queue.zig");
const keys = @import("keys.zig");

const log = std.log.scoped(.any_win32);
