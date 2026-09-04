//! The `text/uri-list` format (RFC 2483) as drag and drop uses it: one `file://` URI per line, CRLF-terminated, `#` lines being comments. Only local files are paths; other schemes are skipped, so a drop of web links parses to nothing.

/// The local paths in `bytes`, each percent-decoded, in order. Lines with a scheme other than `file`, a host other than empty or `localhost`, or no path are skipped.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]const []u8 {
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r \t");
        if (line.len == 0 or line[0] == '#') continue;
        const encoded = localPath(line) orelse continue;
        const path = try decode(allocator, encoded);
        errdefer allocator.free(path);
        if (path.len == 0) {
            allocator.free(path);
            continue;
        }
        try paths.append(allocator, path);
    }
    return paths.toOwnedSlice(allocator);
}

/// Free what `parse` returned.
pub fn free(allocator: std.mem.Allocator, paths: []const []u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

/// The still-encoded path of a `file` URI naming this machine, or null for anything else. Absolute paths are kept absolute; `file:relative` has no authority and is taken as written.
fn localPath(uri: []const u8) ?[]const u8 {
    const scheme = "file:";
    if (uri.len < scheme.len or !std.ascii.eqlIgnoreCase(uri[0..scheme.len], scheme)) return null;
    const rest = uri[scheme.len..];
    if (!std.mem.startsWith(u8, rest, "//")) return rest;
    const after_authority = rest[2..];
    const slash = std.mem.indexOfScalar(u8, after_authority, '/') orelse return null;
    const host = after_authority[0..slash];
    if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return null;
    const path = after_authority[slash..];
    // A query or fragment is not part of a file name.
    const end = std.mem.indexOfAny(u8, path, "?#") orelse path.len;
    return path[0..end];
}

/// Percent-decode `encoded`; a malformed escape is kept as its literal characters.
fn decode(allocator: std.mem.Allocator, encoded: []const u8) std.mem.Allocator.Error![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, encoded.len);
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < encoded.len) : (index += 1) {
        const byte = encoded[index];
        if (byte == '%' and index + 2 < encoded.len) {
            if (hexPair(encoded[index + 1], encoded[index + 2])) |value| {
                out.appendAssumeCapacity(value);
                index += 2;
                continue;
            }
        }
        out.appendAssumeCapacity(byte);
    }
    return out.toOwnedSlice(allocator);
}

/// The byte two hex digits spell, or null when either is not one.
fn hexPair(high: u8, low: u8) ?u8 {
    const high_digit = std.fmt.charToDigit(high, 16) catch return null;
    const low_digit = std.fmt.charToDigit(low, 16) catch return null;
    return high_digit * 16 + low_digit;
}

/// `paths` as a `text/uri-list`: `file://` plus each path, one per line, CRLF-terminated, with every byte percent-encoded except RFC 3986's unreserved set, `/` and `:`. The colon is kept so a Windows drive path given as `/C:/dir/file` reads `file:///C:/dir/file`, the spelling GTK writes there. Paths are expected absolute; one without a leading `/` would read as a host.
pub fn format(allocator: std.mem.Allocator, paths: []const []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (paths) |path| {
        try out.appendSlice(allocator, "file://");
        for (path) |byte| {
            if (isUnreserved(byte) or byte == '/' or byte == ':') {
                try out.append(allocator, byte);
            } else {
                try out.appendSlice(allocator, &.{ '%', hex_digits[byte >> 4], hex_digits[byte & 0xF] });
            }
        }
        try out.appendSlice(allocator, "\r\n");
    }
    return out.toOwnedSlice(allocator);
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

const hex_digits = "0123456789ABCDEF";

const std = @import("std");
const testing = std.testing;

test "parse takes local file URIs and skips the rest" {
    const list = "# a comment\r\nfile:///home/u/a%20b.txt\r\nfile://localhost/tmp/c\nhttps://example.com/\r\nfile://otherhost/d\r\n\r\nfile:///caf%C3%A9\r\n";
    const paths = try parse(testing.allocator, list);
    defer free(testing.allocator, paths);
    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expectEqualStrings("/home/u/a b.txt", paths[0]);
    try testing.expectEqualStrings("/tmp/c", paths[1]);
    try testing.expectEqualStrings("/café", paths[2]);
}

test "parse of nothing local is empty, and bad escapes stay literal" {
    const none = try parse(testing.allocator, "https://a/\r\nmailto:x@y\r\n");
    defer free(testing.allocator, none);
    try testing.expectEqual(@as(usize, 0), none.len);

    // A sign is not a hex digit, whatever integer parsers accept.
    const odd = try parse(testing.allocator, "file:///x%zz%4%+1%-f\r\n");
    defer free(testing.allocator, odd);
    try testing.expectEqualStrings("/x%zz%4%+1%-f", odd[0]);
}

test "parse drops a query or fragment and a host-only URI" {
    const paths = try parse(testing.allocator, "file:///a/b?x=1#frag\r\nfile://localhost\r\n");
    defer free(testing.allocator, paths);
    try testing.expectEqual(@as(usize, 1), paths.len);
    try testing.expectEqualStrings("/a/b", paths[0]);
}

test "format encodes and parse round-trips" {
    const paths = [_][]const u8{ "/home/u/a b.txt", "/tmp/café#1", "/plain", "/C:/Users/x y" };
    const list = try format(testing.allocator, &paths);
    defer testing.allocator.free(list);
    try testing.expectEqualStrings("file:///home/u/a%20b.txt\r\nfile:///tmp/caf%C3%A9%231\r\nfile:///plain\r\nfile:///C:/Users/x%20y\r\n", list);

    const back = try parse(testing.allocator, list);
    defer free(testing.allocator, back);
    try testing.expectEqual(paths.len, back.len);
    for (paths, back) |expected, actual| try testing.expectEqualStrings(expected, actual);
}
