//! OLE drag and drop for the Win32 backend: the `IDropTarget` a window registers, and the `IDataObject` and `IDropSource` a drag of ours hands to `DoDragDrop`, all implemented here and called by OLE on the window's thread. `win32.zig` owns the thread, the registration and the message that starts a drag.
//!
//! Each object embeds its COM half as `com`: a vtable pointer first, as COM requires, then the reference count. OLE holds references of its own (the registration, the drag), so an object dies when the last `release` says so, not when the backend lets go of it.

/// The IUnknown half of a COM object of ours. `Parent` embeds one as `com` and provides `destroy`, which runs when the last reference goes. `iid` is the one interface besides IUnknown the object answers to.
pub fn Object(comptime Parent: type, comptime Interface: type, comptime iid: *const ole.Guid) type {
    return extern struct {
        vtable: *const Interface.VTable,
        refcount: std.atomic.Value(u32) = .init(1),

        const Self = @This();

        /// The pointer COM sees.
        pub fn interface(self: *Self) *Interface {
            return @ptrCast(self);
        }

        pub fn release(self: *Self) void {
            _ = releaseInterface(self.interface());
        }

        pub const unknown: ole.UnknownMethods(Interface) = .{
            .queryInterface = queryInterface,
            .addRef = addRef,
            .release = releaseInterface,
        };

        fn parent(iface: *Interface) *Parent {
            const self: *Self = @ptrCast(@alignCast(iface));
            return @fieldParentPtr("com", self);
        }

        fn queryInterface(iface: *Interface, asked: *const ole.Guid, out: *?*anyopaque) callconv(.winapi) HResult {
            if (ole.guidEql(asked, &ole.IID_IUnknown) or ole.guidEql(asked, iid)) {
                _ = addRef(iface);
                out.* = iface;
                return ole.S_OK;
            }
            out.* = null;
            return ole.E_NOINTERFACE;
        }

        fn addRef(iface: *Interface) callconv(.winapi) u32 {
            const self: *Self = @ptrCast(@alignCast(iface));
            return self.refcount.fetchAdd(1, .monotonic) + 1;
        }

        fn releaseInterface(iface: *Interface) callconv(.winapi) u32 {
            const self: *Self = @ptrCast(@alignCast(iface));
            const left = self.refcount.fetchSub(1, .acq_rel) - 1;
            if (left == 0) parent(iface).destroy();
            return left;
        }
    };
}

/// The drop target of one window, alive from before its thread starts until after it ends: OLE calls the four drag methods on that thread, the window's own methods run on the caller's. Registration is unconditional; the kinds gate what is accepted, and a window taking nothing shows the shell its "no drop" cursor.
pub const Target = struct {
    // The vtable is bound in `create`, not as a default, so the type resolves on hosts that cannot link the functions in it.
    com: Com,
    allocator: std.mem.Allocator,
    io: std.Io,
    events: *queue.ThreadSafeQueue(common.Event),
    /// Set by the window thread before it registers.
    handle: ?win.WindowHandle = null,
    window_id: common.WindowID = 0,
    /// OLE is up on the window thread and the window is registered; without it `setDropTarget` and `startDrag` refuse.
    ready: std.atomic.Value(bool) = .init(false),
    /// `common.DropKinds` as its bits; written by `setDropTarget`, read at every enter.
    kinds_bits: std.atomic.Value(u8) = .init(0),
    /// A drag from this window is posted or running.
    dragging: std.atomic.Value(bool) = .init(false),
    /// The hover: the format chosen at enter, 0 while refused. Window thread only.
    format: u16 = 0,
    kind: common.DropKind = .text,
    /// The newest drop's payload until `takeDrop` moves it out. Under `pending_mutex`.
    pending: ?common.DropData = null,
    pending_mutex: std.Io.Mutex = .init,

    const Com = Object(Target, ole.IDropTarget, &ole.IID_IDropTarget);

    pub fn create(allocator: std.mem.Allocator, io: std.Io, events: *queue.ThreadSafeQueue(common.Event)) !*Target {
        const self = try allocator.create(Target);
        self.* = .{ .com = .{ .vtable = &target_vtable }, .allocator = allocator, .io = io, .events = events };
        return self;
    }

    fn destroy(self: *Target) void {
        if (self.pending) |data| data.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn setKinds(self: *Target, kinds: common.DropKinds) void {
        self.kinds_bits.store(@as(u2, @bitCast(kinds)), .release);
    }

    fn wantedKinds(self: *Target) common.DropKinds {
        return @bitCast(@as(u2, @truncate(self.kinds_bits.load(.acquire))));
    }

    /// The newest drop, copied into `allocator`; the stored one is freed either way.
    pub fn takeDrop(self: *Target, allocator: std.mem.Allocator) (common.DropError || std.mem.Allocator.Error)!common.DropData {
        const stored = self.swapPending(null) orelse return error.NoDrop;
        defer stored.deinit(self.allocator);
        return stored.dupe(allocator);
    }

    fn swapPending(self: *Target, data: ?common.DropData) ?common.DropData {
        self.pending_mutex.lockUncancelable(self.io);
        defer self.pending_mutex.unlock(self.io);
        const previous = self.pending;
        self.pending = data;
        return previous;
    }

    /// The point OLE reports, in this window's client area, clamped to what an event carries.
    fn clientPoint(self: *Target, point: ole.PointL) common.Position {
        var converted = win.Point{ .x = point.x, .y = point.y };
        if (self.handle) |handle| _ = win.ScreenToClient(handle, &converted);
        return .{
            .x = @intCast(std.math.clamp(converted.x, std.math.minInt(common.X), std.math.maxInt(common.X))),
            .y = @intCast(std.math.clamp(converted.y, std.math.minInt(common.Y), std.math.maxInt(common.Y))),
        };
    }

    /// What this drag will deliver: files as `CF_HDROP` when the window takes them and the source has them, else text as `CF_UNICODETEXT`; 0 when nothing fits.
    fn chooseFormat(self: *Target, data: *ole.IDataObject) u16 {
        const wanted = self.wantedKinds();
        if (wanted.files and data.hasFormat(ole.CF_HDROP)) {
            self.kind = .files;
            return ole.CF_HDROP;
        }
        if (wanted.text and data.hasFormat(ole.CF_UNICODETEXT)) {
            self.kind = .text;
            return ole.CF_UNICODETEXT;
        }
        return 0;
    }

    /// Copy when a format was chosen and the source allows it; `effect` comes in as the effects the source allows.
    fn answer(self: *Target, effect: *u32) bool {
        const accept = self.format != 0 and (effect.* & ole.DROPEFFECT_COPY) != 0;
        effect.* = if (accept) ole.DROPEFFECT_COPY else ole.DROPEFFECT_NONE;
        return accept;
    }

    fn dragEnter(iface: *ole.IDropTarget, data: *ole.IDataObject, key_state: u32, point: ole.PointL, effect: *u32) callconv(.winapi) HResult {
        _ = key_state;
        const self = Com.parent(iface);
        self.format = self.chooseFormat(data);
        if (self.answer(effect)) {
            const position = self.clientPoint(point);
            self.events.push(.{ .drag_enter = .{ .x = position.x, .y = position.y, .kind = self.kind, .window_id = self.window_id } });
        } else {
            self.format = 0;
        }
        return ole.S_OK;
    }

    fn dragOver(iface: *ole.IDropTarget, key_state: u32, point: ole.PointL, effect: *u32) callconv(.winapi) HResult {
        _ = key_state;
        const self = Com.parent(iface);
        if (self.answer(effect)) {
            const position = self.clientPoint(point);
            self.events.push(.{ .drag_motion = .{ .x = position.x, .y = position.y, .window_id = self.window_id } });
        }
        return ole.S_OK;
    }

    fn dragLeave(iface: *ole.IDropTarget) callconv(.winapi) HResult {
        const self = Com.parent(iface);
        if (self.format != 0) self.events.push(.{ .drag_leave = self.window_id });
        self.format = 0;
        return ole.S_OK;
    }

    /// The source is committed: fetch the payload now, so `drop` goes out with it in hand. OLE sends no `dragLeave` after this.
    fn drop(iface: *ole.IDropTarget, data: *ole.IDataObject, key_state: u32, point: ole.PointL, effect: *u32) callconv(.winapi) HResult {
        _ = key_state;
        const self = Com.parent(iface);
        defer self.format = 0;
        if (!self.answer(effect)) return ole.S_OK;

        const payload = self.fetch(data) catch |err| {
            log.debug("Drop payload could not be read: {t}", .{err});
            effect.* = ole.DROPEFFECT_NONE;
            self.events.push(.{ .drag_leave = self.window_id });
            return ole.S_OK;
        };
        if (self.swapPending(payload)) |untaken| untaken.deinit(self.allocator);
        const position = self.clientPoint(point);
        self.events.push(.{ .drop = .{ .x = position.x, .y = position.y, .kind = self.kind, .window_id = self.window_id } });
        return ole.S_OK;
    }

    /// The chosen format rendered by the source into a global block, decoded into a payload of ours.
    fn fetch(self: *Target, data: *ole.IDataObject) !common.DropData {
        var medium = try data.getGlobal(self.format);
        defer ole.ReleaseStgMedium(&medium);
        const block = medium.handle.?;
        switch (self.kind) {
            .files => return .{ .files = try readDropFiles(self.allocator, block) },
            .text => {
                const memory = win.GlobalLock(block) orelse return error.LockFailed;
                defer _ = win.GlobalUnlock(block);
                const size = win.GlobalSize(block);
                const units: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, memory[0 .. size - size % 2]));
                return .{ .text = try win32.utf8FromClipboardUnits(self.allocator, units) };
            },
        }
    }
};

const target_vtable: ole.IDropTarget.VTable = .{
    .unknown = Target.Com.unknown,
    .dragEnter = Target.dragEnter,
    .dragOver = Target.dragOver,
    .dragLeave = Target.dragLeave,
    .drop = Target.drop,
};

/// The `DragQueryFileW` index that asks for the number of paths rather than one of them.
const drag_query_count: u32 = 0xFFFFFFFF;

/// The paths in a `CF_HDROP` block, through the shell so an ANSI block is read as well as a wide one. An empty list is a refused drop.
fn readDropFiles(allocator: std.mem.Allocator, block: *anyopaque) ![]const []u8 {
    const count = ole.DragQueryFileW(block, drag_query_count, null, 0);
    if (count == 0) return error.NoFiles;
    const paths = try allocator.alloc([]u8, count);
    var filled: usize = 0;
    errdefer {
        for (paths[0..filled]) |path| allocator.free(path);
        allocator.free(paths);
    }
    for (0..count) |index| {
        const length = ole.DragQueryFileW(block, @intCast(index), null, 0);
        const units = try allocator.alloc(u16, length + 1);
        defer allocator.free(units);
        const copied = ole.DragQueryFileW(block, @intCast(index), units.ptr, @intCast(units.len));
        paths[filled] = try std.unicode.utf16LeToUtf8Alloc(allocator, units[0..copied]);
        filled += 1;
    }
    return paths;
}

/// What a drag of ours carries, rendered once on the caller's thread: `CF_UNICODETEXT` for text, and for files `CF_HDROP` plus the `text/uri-list` as `CF_UNICODETEXT`. OLE hands the object to every target the pointer crosses.
pub const Data = struct {
    com: Com,
    allocator: std.mem.Allocator,
    formats: [2]ole.FormatEtc,
    format_count: u32,
    /// NUL-terminated UTF-16 with CRLF line ends, as `CF_UNICODETEXT` wants.
    text: [:0]u16,
    /// The `DROPFILES` block; empty for a text drag.
    drop_files: []u8,

    const Com = Object(Data, ole.IDataObject, &ole.IID_IDataObject);

    pub fn create(allocator: std.mem.Allocator, data: common.DragData) !*Data {
        const self = try allocator.create(Data);
        errdefer allocator.destroy(self);
        switch (data) {
            .text => |text| {
                const units = try win32.clipboardUnitsFromUtf8(allocator, text);
                self.* = .{
                    .com = .{ .vtable = &data_vtable },
                    .allocator = allocator,
                    .formats = .{ .{ .format = ole.CF_UNICODETEXT }, undefined },
                    .format_count = 1,
                    .text = units,
                    .drop_files = &.{},
                };
            },
            .files => |paths| {
                const block = try dropFilesBlock(allocator, paths);
                errdefer allocator.free(block);
                const list = try uriListOfWindowsPaths(allocator, paths);
                defer allocator.free(list);
                const units = try win32.clipboardUnitsFromUtf8(allocator, list);
                self.* = .{
                    .com = .{ .vtable = &data_vtable },
                    .allocator = allocator,
                    .formats = .{ .{ .format = ole.CF_HDROP }, .{ .format = ole.CF_UNICODETEXT } },
                    .format_count = 2,
                    .text = units,
                    .drop_files = block,
                };
            },
        }
        return self;
    }

    fn destroy(self: *Data) void {
        self.allocator.free(self.text);
        self.allocator.free(self.drop_files);
        self.allocator.destroy(self);
    }

    /// The bytes behind `format`, NUL included for the text, or null when the object never offered it.
    fn bytesFor(self: *Data, format: u16) ?[]const u8 {
        for (self.formats[0..self.format_count]) |offered| {
            if (offered.format != format) continue;
            return if (format == ole.CF_HDROP) self.drop_files else std.mem.sliceAsBytes(self.text[0 .. self.text.len + 1]);
        }
        return null;
    }

    /// Whether `asked` names something this object renders: a known format, as content, in a global block.
    fn accepts(self: *Data, asked: *const ole.FormatEtc) HResult {
        if (self.bytesFor(asked.format) == null) return ole.DV_E_FORMATETC;
        if ((asked.aspect & ole.DVASPECT_CONTENT) == 0) return ole.DV_E_DVASPECT;
        if ((asked.medium & ole.TYMED_HGLOBAL) == 0) return ole.DV_E_TYMED;
        return ole.S_OK;
    }

    fn getData(iface: *ole.IDataObject, asked: *const ole.FormatEtc, medium: *ole.StgMedium) callconv(.winapi) HResult {
        const self = Com.parent(iface);
        const verdict = self.accepts(asked);
        if (verdict != ole.S_OK) return verdict;
        const bytes = self.bytesFor(asked.format).?;
        // OLE frees the block once the target is done with it, since `release` is null.
        const block = win.GlobalAlloc(win.GMEM_MOVEABLE, bytes.len) orelse return ole.E_OUTOFMEMORY;
        const memory = win.GlobalLock(block) orelse {
            _ = win.GlobalFree(block);
            return ole.E_OUTOFMEMORY;
        };
        @memcpy(memory[0..bytes.len], bytes);
        _ = win.GlobalUnlock(block);
        medium.* = .{ .medium = ole.TYMED_HGLOBAL, .handle = block, .release = null };
        return ole.S_OK;
    }

    fn getDataHere(_: *ole.IDataObject, _: *const ole.FormatEtc, _: *ole.StgMedium) callconv(.winapi) HResult {
        return ole.E_NOTIMPL;
    }

    fn queryGetData(iface: *ole.IDataObject, asked: *const ole.FormatEtc) callconv(.winapi) HResult {
        const self = Com.parent(iface);
        return self.accepts(asked);
    }

    fn getCanonicalFormatEtc(_: *ole.IDataObject, asked: *const ole.FormatEtc, out: *ole.FormatEtc) callconv(.winapi) HResult {
        out.* = asked.*;
        out.target_device = null;
        return ole.DATA_S_SAMEFORMATETC;
    }

    fn setData(_: *ole.IDataObject, _: *const ole.FormatEtc, _: *ole.StgMedium, _: i32) callconv(.winapi) HResult {
        return ole.E_NOTIMPL;
    }

    /// The shell's own enumerator over the format list, so no fourth interface is needed.
    fn enumFormatEtc(iface: *ole.IDataObject, direction: u32, out: *?*anyopaque) callconv(.winapi) HResult {
        const self = Com.parent(iface);
        if (direction != ole.DATADIR_GET) {
            out.* = null;
            return ole.E_NOTIMPL;
        }
        return ole.SHCreateStdEnumFmtEtc(self.format_count, &self.formats, out);
    }

    fn dAdvise(_: *ole.IDataObject, _: *const ole.FormatEtc, _: u32, _: ?*anyopaque, _: *u32) callconv(.winapi) HResult {
        return ole.OLE_E_ADVISENOTSUPPORTED;
    }

    fn dUnadvise(_: *ole.IDataObject, _: u32) callconv(.winapi) HResult {
        return ole.OLE_E_ADVISENOTSUPPORTED;
    }

    fn enumDAdvise(_: *ole.IDataObject, out: *?*anyopaque) callconv(.winapi) HResult {
        out.* = null;
        return ole.OLE_E_ADVISENOTSUPPORTED;
    }
};

const data_vtable: ole.IDataObject.VTable = .{
    .unknown = Data.Com.unknown,
    .getData = Data.getData,
    .getDataHere = Data.getDataHere,
    .queryGetData = Data.queryGetData,
    .getCanonicalFormatEtc = Data.getCanonicalFormatEtc,
    .setData = Data.setData,
    .enumFormatEtc = Data.enumFormatEtc,
    .dAdvise = Data.dAdvise,
    .dUnadvise = Data.dUnadvise,
    .enumDAdvise = Data.enumDAdvise,
};

/// The `text/uri-list` for Windows paths: each becomes the URI path `/C:/dir/file` (a leading slash, separators forward) before the codec, which knows POSIX paths, encodes it.
fn uriListOfWindowsPaths(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    const uri_paths = try allocator.alloc([]u8, paths.len);
    var converted: usize = 0;
    defer {
        for (uri_paths[0..converted]) |path| allocator.free(path);
        allocator.free(uri_paths);
    }
    for (paths) |path| {
        const rooted = std.mem.startsWith(u8, path, "\\") or std.mem.startsWith(u8, path, "/");
        const uri_path = try allocator.alloc(u8, path.len + @intFromBool(!rooted));
        if (!rooted) uri_path[0] = '/';
        for (path, uri_path[uri_path.len - path.len ..]) |byte, *out| out.* = if (byte == '\\') '/' else byte;
        uri_paths[converted] = uri_path;
        converted += 1;
    }
    return uri_list.format(allocator, uri_paths);
}

/// A `CF_HDROP` block: the `DROPFILES` header, then each path as NUL-terminated UTF-16, then an empty string closing the list.
fn dropFilesBlock(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const header: ole.DropFiles = .{};
    try out.appendSlice(allocator, std.mem.asBytes(&header));
    for (paths) |path| {
        const units = try std.unicode.utf8ToUtf16LeAlloc(allocator, path);
        defer allocator.free(units);
        try out.appendSlice(allocator, std.mem.sliceAsBytes(units));
        try out.appendSlice(allocator, &.{ 0, 0 });
    }
    try out.appendSlice(allocator, &.{ 0, 0 });
    return out.toOwnedSlice(allocator);
}

/// What `DoDragDrop` asks after every input change: the drag goes on while a button stays down, drops when the one that was down is released, and is cancelled by Escape or by starting with no button down at all (the caller ignored the "while held" rule).
pub const Source = struct {
    com: Com,
    allocator: std.mem.Allocator,
    seen_button: bool = false,

    const Com = Object(Source, ole.IDropSource, &ole.IID_IDropSource);

    pub fn create(allocator: std.mem.Allocator) !*Source {
        const self = try allocator.create(Source);
        self.* = .{ .com = .{ .vtable = &source_vtable }, .allocator = allocator };
        return self;
    }

    fn destroy(self: *Source) void {
        self.allocator.destroy(self);
    }

    fn queryContinueDrag(iface: *ole.IDropSource, escape_pressed: i32, key_state: u32) callconv(.winapi) HResult {
        const self = Com.parent(iface);
        if (escape_pressed != 0) return ole.DRAGDROP_S_CANCEL;
        if ((key_state & (ole.MK_LBUTTON | ole.MK_MBUTTON | ole.MK_RBUTTON)) == 0) {
            return if (self.seen_button) ole.DRAGDROP_S_DROP else ole.DRAGDROP_S_CANCEL;
        }
        self.seen_button = true;
        return ole.S_OK;
    }

    fn giveFeedback(_: *ole.IDropSource, _: u32) callconv(.winapi) HResult {
        return ole.DRAGDROP_S_USEDEFAULTCURSORS;
    }
};

const source_vtable: ole.IDropSource.VTable = .{
    .unknown = Source.Com.unknown,
    .queryContinueDrag = Source.queryContinueDrag,
    .giveFeedback = Source.giveFeedback,
};

/// Whether a mouse button is down right now, anywhere: what a drag needs to hang on.
pub fn buttonHeld() bool {
    return win.GetAsyncKeyState(win.VK_LBUTTON) < 0 or win.GetAsyncKeyState(win.VK_RBUTTON) < 0 or win.GetAsyncKeyState(win.VK_MBUTTON) < 0;
}

/// Run a drag to its end on the calling thread, which must own the window it was posted to: `DoDragDrop` runs a modal loop that keeps dispatching the thread's messages. Both objects are released after. True when a target took the data.
pub fn runDrag(data: *Data, source: *Source) bool {
    defer data.com.release();
    defer source.com.release();
    var effect: u32 = ole.DROPEFFECT_NONE;
    const result = ole.DoDragDrop(data.com.interface(), source.com.interface(), ole.DROPEFFECT_COPY, &effect);
    if (result != ole.DRAGDROP_S_DROP and result != ole.DRAGDROP_S_CANCEL) {
        log.debug("DoDragDrop returned {x}", .{@as(u32, @bitCast(@intFromEnum(result)))});
    }
    return result == ole.DRAGDROP_S_DROP and effect != ole.DROPEFFECT_NONE;
}

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const win = @import("windows");
const ole = win.ole;
const HResult = win.HResult;
const common = @import("common.zig");
const queue = @import("queue.zig");
const uri_list = @import("uri_list.zig");
const win32 = @import("win32.zig");

const log = std.log.scoped(.any_win32);

test "a DROPFILES block is the header, wide paths and a double NUL" {
    const block = try dropFilesBlock(testing.allocator, &.{ "C:\\a b.txt", "D:\\é" });
    defer testing.allocator.free(block);
    const expected_units = std.unicode.utf8ToUtf16LeStringLiteral("C:\\a b.txt\x00D:\\é\x00\x00");
    try testing.expectEqual(20 + expected_units.len * 2, block.len);
    try testing.expectEqual(@as(u32, 20), std.mem.readInt(u32, block[0..4], .little));
    try testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, block[16..20], .little));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected_units), block[20..]);

    const empty = try dropFilesBlock(testing.allocator, &.{});
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 22), empty.len);
}

test "Windows paths become rooted forward-slash URI paths in the text fallback" {
    const list = try uriListOfWindowsPaths(testing.allocator, &.{ "C:\\Users\\a b.txt", "\\\\server\\share\\x", "/already/rooted" });
    defer testing.allocator.free(list);
    try testing.expectEqualStrings("file:///C:/Users/a%20b.txt\r\nfile:////server/share/x\r\nfile:///already/rooted\r\n", list);
}

test "the COM head sits first in each object" {
    // The pointer OLE gets must point at a vtable pointer; the count follows it. (The tables themselves are only built on Windows: their functions call into user32 and ole32.)
    try testing.expectEqual(@as(usize, 0), @offsetOf(Target, "com"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Data, "com"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Source, "com"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(@FieldType(Target, "com"), "vtable"));
    try testing.expectEqual(@as(usize, @sizeOf(usize)), @offsetOf(@FieldType(Target, "com"), "refcount"));
    try testing.expectEqual(@as(usize, 2 * @sizeOf(usize)), @sizeOf(@FieldType(Data, "com")));
}

// The data object through its own vtable, as a target would use it: what it offers, how it renders a global block, and the reference count freeing it. Runs under Wine.
test "the data object renders its formats into global blocks and dies with its last reference" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const data = try Data.create(testing.allocator, .{ .files = &.{ "C:\\one.txt", "C:\\two dir\\x" } });
    const iface = data.com.interface();

    var other: ?*anyopaque = null;
    try testing.expectEqual(ole.S_OK, iface.vtable.unknown.queryInterface(iface, &ole.IID_IDataObject, &other));
    try testing.expectEqual(@as(?*anyopaque, iface), other);
    try testing.expectEqual(ole.E_NOINTERFACE, iface.vtable.unknown.queryInterface(iface, &ole.IID_IDropTarget, &other));
    try testing.expectEqual(@as(?*anyopaque, null), other);
    try testing.expectEqual(@as(u32, 1), iface.vtable.unknown.release(iface));

    try testing.expect(iface.hasFormat(ole.CF_HDROP));
    try testing.expect(iface.hasFormat(ole.CF_UNICODETEXT));
    try testing.expect(!iface.hasFormat(1));
    const on_a_stream: ole.FormatEtc = .{ .format = ole.CF_HDROP, .medium = 4 };
    try testing.expectEqual(ole.DV_E_TYMED, iface.vtable.queryGetData(iface, &on_a_stream));

    var medium = try iface.getGlobal(ole.CF_HDROP);
    const paths = try readDropFiles(testing.allocator, medium.handle.?);
    defer uri_list.free(testing.allocator, paths);
    ole.ReleaseStgMedium(&medium);
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings("C:\\two dir\\x", paths[1]);

    var text_medium = try iface.getGlobal(ole.CF_UNICODETEXT);
    const memory = win.GlobalLock(text_medium.handle.?) orelse return error.LockFailed;
    const size = win.GlobalSize(text_medium.handle.?);
    const units: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, memory[0 .. size - size % 2]));
    const list = try win32.utf8FromClipboardUnits(testing.allocator, units);
    defer testing.allocator.free(list);
    _ = win.GlobalUnlock(text_medium.handle.?);
    ole.ReleaseStgMedium(&text_medium);
    try testing.expectEqualStrings("file:///C:/one.txt\nfile:///C:/two%20dir/x\n", list);

    var enumerator: ?*anyopaque = null;
    try testing.expectEqual(ole.S_OK, iface.vtable.enumFormatEtc(iface, ole.DATADIR_GET, &enumerator));
    try testing.expect(enumerator != null);
    // Every COM interface starts with IUnknown's three slots, so the enumerator is released through any interface's table.
    const unknown: *ole.IDataObject = @ptrCast(@alignCast(enumerator.?));
    _ = unknown.vtable.unknown.release(unknown);

    // The last release frees the object; the testing allocator would report anything left.
    try testing.expectEqual(@as(u32, 0), iface.vtable.unknown.release(iface));
}

test "the drop source drops on the release of a button it saw and cancels otherwise" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source = try Source.create(testing.allocator);
    defer source.com.release();
    const iface = source.com.interface();
    try testing.expectEqual(ole.DRAGDROP_S_CANCEL, iface.vtable.queryContinueDrag(iface, 0, 0));
    try testing.expectEqual(ole.S_OK, iface.vtable.queryContinueDrag(iface, 0, ole.MK_LBUTTON));
    try testing.expectEqual(ole.DRAGDROP_S_CANCEL, iface.vtable.queryContinueDrag(iface, 1, ole.MK_LBUTTON));
    try testing.expectEqual(ole.DRAGDROP_S_DROP, iface.vtable.queryContinueDrag(iface, 0, 0));
    try testing.expectEqual(ole.DRAGDROP_S_USEDEFAULTCURSORS, iface.vtable.giveFeedback(iface, ole.DROPEFFECT_COPY));
}
