//! Dead-key and Multi_key composition: the sequence table from the X11 Compose files and the sequence in progress. `feed` takes each keysym a key press produced and says what that key types.
//!
//! The table is read the way libxkbcommon reads it: `$XCOMPOSEFILE`, else `~/.XCompose`, else the locale's file under `/usr/share/X11/locale`. `include` lines are followed. A system without those files gets a built-in table of the common dead-key pairs.

allocator: std.mem.Allocator,
/// Complete sequences and what they type.
sequences: std.AutoHashMapUnmanaged(Sequence, Text) = .empty,
/// Every proper prefix of a sequence, so a partial sequence can be told from a broken one.
prefixes: std.AutoHashMapUnmanaged(Sequence, void) = .empty,
/// The keysyms fed since the last completion or cancellation.
pending: Sequence = .{},
/// Compose file lines the parser could not use: an unresolvable keysym name, a modifier prefix, or a sequence or result past the limits.
skipped_lines: usize = 0,

/// The most keysyms one sequence takes; longer lines are skipped.
pub const max_sequence = 8;
/// The most code points one sequence types; longer lines are skipped.
pub const max_text = 4;
pub const locale_dir = "/usr/share/X11/locale";
/// The locale whose file is read when the environment names none, or names `C` or `POSIX`, whose own file is Latin-1.
pub const default_locale = "en_US.UTF-8";

const max_include_depth = 4;
const max_file_bytes = 8 << 20;
const multi_key: u32 = 0xFF20;
const escape: u32 = 0xFF1B;
const backspace: u32 = 0xFF08;
const space: u32 = 0x20;

pub const Sequence = struct {
    keysyms: [max_sequence]u32 = @splat(0),
    len: u8 = 0,

    fn appended(self: Sequence, keysym: u32) ?Sequence {
        if (self.len == max_sequence) return null;
        var next = self;
        next.keysyms[next.len] = keysym;
        next.len += 1;
        return next;
    }

    fn single(keysym: u32) Sequence {
        return (Sequence{}).appended(keysym).?;
    }
};

/// What a sequence types.
pub const Text = struct {
    codepoints: [max_text]u21 = @splat(0),
    len: u8 = 0,

    pub fn slice(self: *const Text) []const u21 {
        return self.codepoints[0..self.len];
    }

    fn append(self: *Text, codepoint: u21) bool {
        if (self.len == max_text) return false;
        self.codepoints[self.len] = codepoint;
        self.len += 1;
        return true;
    }
};

pub const Cancelled = struct {
    /// The spacing accent of each dead key that was pending, typed before the key is handled as usual. Empty after Multi_key, Escape or BackSpace.
    text: Text = .{},
    /// The key started a sequence of its own, so it types nothing.
    restarted: bool = false,
};

pub const Step = union(enum) {
    /// The keysym belongs to no sequence and none was pending: the key types as usual.
    ignored,
    /// The keysym started or continued a sequence: the key types nothing.
    pending,
    /// The keysym completed a sequence: the key types nothing, and this text follows.
    composed: Text,
    /// The keysym ended the pending sequence without completing it.
    cancelled: Cancelled,
};

pub fn init(allocator: std.mem.Allocator) @This() {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *@This()) void {
    self.sequences.deinit(self.allocator);
    self.prefixes.deinit(self.allocator);
}

/// The table for this environment: the user's or the locale's Compose file, or the built-in table when neither can be read.
pub fn load(io: std.Io, allocator: std.mem.Allocator, environ: std.process.Environ) @This() {
    var self = init(allocator);
    self.loadFiles(io, environ) catch |err| log.debug("Compose files not read ({any})", .{err});
    if (self.sequences.count() == 0) {
        self.addText(builtin_table) catch |err| log.warn("Built-in compose table not loaded: {any}", .{err});
        log.debug("Compose: using the built-in table, {d} sequences", .{self.sequences.count()});
    } else {
        log.debug("Compose: {d} sequences, {d} lines skipped", .{ self.sequences.count(), self.skipped_lines });
    }
    return self;
}

/// Add the sequences in Compose file text. `include` lines are skipped; `load` follows them.
pub fn addText(self: *@This(), text: []const u8) !void {
    try self.parseText(text, null);
}

/// What the key that produced `keysym` types. Modifier keysyms never touch a sequence.
pub fn feed(self: *@This(), keysym: u32) Step {
    if (keysym == 0 or isModifier(keysym)) return .ignored;
    if (keysym == escape or keysym == backspace) {
        if (self.pending.len == 0) return .ignored;
        self.pending = .{};
        return .{ .cancelled = .{} };
    }
    if (self.pending.appended(keysym)) |candidate| {
        if (self.sequences.get(candidate)) |text| {
            self.pending = .{};
            return .{ .composed = text };
        }
        if (self.prefixes.contains(candidate)) {
            self.pending = candidate;
            return .pending;
        }
    }
    if (self.pending.len == 0) return .ignored;

    // A broken sequence types its dead keys as spacing accents, so nothing the user typed is lost; a dead key that broke it opens a new one.
    var cancelled: Cancelled = .{ .text = self.spacingAccents() };
    self.pending = .{};
    const fresh = Sequence.single(keysym);
    if (self.prefixes.contains(fresh)) {
        self.pending = fresh;
        cancelled.restarted = true;
    }
    return .{ .cancelled = cancelled };
}

/// Drop the pending sequence, typing nothing.
pub fn cancel(self: *@This()) void {
    self.pending = .{};
}

pub fn isPending(self: @This()) bool {
    return self.pending.len != 0;
}

/// The spacing accent of each pending dead key, as its `<dead_x> <space>` sequence defines it.
fn spacingAccents(self: @This()) Text {
    var text: Text = .{};
    for (self.pending.keysyms[0..self.pending.len]) |keysym| {
        if (!isDeadKey(keysym)) continue;
        const spacing = self.sequences.get(Sequence.single(keysym).appended(space).?) orelse continue;
        for (spacing.slice()) |codepoint| {
            if (!text.append(codepoint)) return text;
        }
    }
    return text;
}

fn isDeadKey(keysym: u32) bool {
    return keysym >= 0xFE50 and keysym <= 0xFE93;
}

fn isModifier(keysym: u32) bool {
    return switch (keysym) {
        0xFFE1...0xFFEE, 0xFE01...0xFE13, 0xFF7E, 0xFF7F => true,
        else => false,
    };
}

// Loading

const Includes = struct {
    io: std.Io,
    locale_file: ?[]const u8,
    home: ?[]const u8,
    depth: u8,
};

fn loadFiles(self: *@This(), io: std.Io, environ: std.process.Environ) !void {
    const locale_file = try localeFile(io, self.allocator, environ);
    defer if (locale_file) |path| self.allocator.free(path);
    const home: ?[]const u8 = environ.getPosix("HOME");

    if (environ.getPosix("XCOMPOSEFILE")) |path| {
        if (try self.addFile(path, .{ .io = io, .locale_file = locale_file, .home = home, .depth = 0 })) return;
    }
    if (home) |dir| {
        const path = try std.fs.path.join(self.allocator, &.{ dir, ".XCompose" });
        defer self.allocator.free(path);
        if (try self.addFile(path, .{ .io = io, .locale_file = locale_file, .home = home, .depth = 0 })) return;
    }
    if (locale_file) |path| {
        _ = try self.addFile(path, .{ .io = io, .locale_file = locale_file, .home = home, .depth = 0 });
    }
}

/// What reading and parsing a Compose file can fail with. Named because `include` recurses into `addFile`.
const FileError = std.Io.Dir.ReadFileAllocError;

/// Parse the file at `path`; false when there is no such file or the include depth is spent.
fn addFile(self: *@This(), path: []const u8, includes: Includes) FileError!bool {
    if (includes.depth > max_include_depth) return false;
    const text = std.Io.Dir.cwd().readFileAlloc(includes.io, path, self.allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer self.allocator.free(text);
    try self.parseText(text, includes);
    return true;
}

/// The Compose file `compose.dir` assigns to the environment's locale, resolving `locale.alias` spellings. Caller frees.
fn localeFile(io: std.Io, allocator: std.mem.Allocator, environ: std.process.Environ) !?[]u8 {
    const requested = environ.getPosix("LC_ALL") orelse environ.getPosix("LC_CTYPE") orelse environ.getPosix("LANG") orelse default_locale;
    const locale: []const u8 = if (std.mem.eql(u8, requested, "C") or std.mem.eql(u8, requested, "POSIX") or requested.len == 0) default_locale else requested;

    const compose_dir = std.Io.Dir.cwd().readFileAlloc(io, locale_dir ++ "/compose.dir", allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(compose_dir);
    if (findDirEntry(compose_dir, locale)) |file| return try std.fs.path.join(allocator, &.{ locale_dir, file });

    const aliases = std.Io.Dir.cwd().readFileAlloc(io, locale_dir ++ "/locale.alias", allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(aliases);
    const canonical = findDirEntry(aliases, locale) orelse return null;
    const file = findDirEntry(compose_dir, canonical) orelse return null;
    return try std.fs.path.join(allocator, &.{ locale_dir, file });
}

/// The first column of the line whose second column is `key`, in the `value key` and `value: key` layouts `compose.dir` and `locale.alias` use.
fn findDirEntry(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, trimmed, " \t");
        const value = std.mem.trimEnd(u8, fields.next() orelse continue, ":");
        const name = fields.next() orelse continue;
        if (std.mem.eql(u8, name, key)) return value;
    }
    return null;
}

fn parseText(self: *@This(), text: []const u8, includes: ?Includes) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try self.parseLine(line, includes);
}

fn parseLine(self: *@This(), line: []const u8, includes: ?Includes) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return;
    if (std.mem.startsWith(u8, trimmed, "include")) {
        const context = includes orelse {
            self.skipped_lines += 1;
            return;
        };
        try self.include(trimmed["include".len..], context);
        return;
    }

    var sequence: Sequence = .{};
    var rest = trimmed;
    while (true) {
        rest = std.mem.trimStart(u8, rest, " \t");
        if (rest.len == 0) return self.skip();
        if (rest[0] == ':') {
            rest = rest[1..];
            break;
        }
        // A modifier prefix (`~Ctrl <a>`) is a rule this table does not model.
        if (rest[0] != '<') return self.skip();
        const close = std.mem.indexOfScalar(u8, rest, '>') orelse return self.skip();
        const keysym = wl.xkb.keysym.fromName(rest[1..close]) orelse return self.skip();
        sequence = sequence.appended(keysym) orelse return self.skip();
        rest = rest[close + 1 ..];
    }
    if (sequence.len == 0) return self.skip();

    rest = std.mem.trimStart(u8, rest, " \t");
    var text: Text = .{};
    var decoded = false;
    if (rest.len > 0 and rest[0] == '"') {
        var bytes: [64]u8 = undefined;
        var count: usize = 0;
        var index: usize = 1;
        while (index < rest.len and rest[index] != '"') : (index += 1) {
            var byte = rest[index];
            if (byte == '\\' and index + 1 < rest.len) {
                index += 1;
                switch (rest[index]) {
                    'x' => {
                        const end = @min(index + 3, rest.len);
                        byte = std.fmt.parseInt(u8, rest[index + 1 .. end], 16) catch return self.skip();
                        index = end - 1;
                    },
                    '0'...'7' => {
                        var end = index;
                        while (end < rest.len and end < index + 3 and rest[end] >= '0' and rest[end] <= '7') end += 1;
                        byte = std.fmt.parseInt(u8, rest[index..end], 8) catch return self.skip();
                        index = end - 1;
                    },
                    else => byte = rest[index],
                }
            }
            if (count == bytes.len) return self.skip();
            bytes[count] = byte;
            count += 1;
        }
        if (index >= rest.len) return self.skip();
        rest = rest[index + 1 ..];
        decoded = decodeUtf8(bytes[0..count], &text);
    }
    if (!decoded) {
        // No string, or a string in the locale's own charset (the Latin-1 files): the result keysym name says what it is.
        rest = std.mem.trimStart(u8, rest, " \t");
        var end: usize = 0;
        while (end < rest.len and rest[end] != ' ' and rest[end] != '\t' and rest[end] != '#') end += 1;
        const keysym = wl.xkb.keysym.fromName(rest[0..end]) orelse return self.skip();
        const codepoint = keys.keysymToCodepoint(keysym) orelse return self.skip();
        text = .{};
        _ = text.append(codepoint);
    }
    try self.add(sequence, text);
}

fn skip(self: *@This()) void {
    self.skipped_lines += 1;
}

fn decodeUtf8(bytes: []const u8, text: *Text) bool {
    if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) return false;
    var view = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (view.nextCodepoint()) |codepoint| {
        if (!text.append(codepoint)) return false;
    }
    return true;
}

/// Record a sequence and every proper prefix of it. A later line replaces an earlier one, which is how `~/.XCompose` overrides the locale's file.
fn add(self: *@This(), sequence: Sequence, text: Text) !void {
    try self.sequences.put(self.allocator, sequence, text);
    var prefix: Sequence = .{};
    for (sequence.keysyms[0 .. sequence.len - 1]) |keysym| {
        prefix = prefix.appended(keysym).?;
        try self.prefixes.put(self.allocator, prefix, {});
    }
}

/// An `include "path"` line: `%L` is the locale's file, `%H` the home directory, `%S` the system locale directory.
fn include(self: *@This(), argument: []const u8, includes: Includes) !void {
    const quoted = std.mem.trim(u8, argument, " \t");
    if (quoted.len < 2 or quoted[0] != '"' or quoted[quoted.len - 1] != '"') return self.skip();
    const pattern = quoted[1 .. quoted.len - 1];

    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(self.allocator);
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] != '%' or index + 1 == pattern.len) {
            try path.append(self.allocator, pattern[index]);
            continue;
        }
        index += 1;
        const expansion: []const u8 = switch (pattern[index]) {
            'L' => includes.locale_file orelse return self.skip(),
            'H' => includes.home orelse return self.skip(),
            'S' => locale_dir,
            '%' => "%",
            else => return self.skip(),
        };
        try path.appendSlice(self.allocator, expansion);
    }
    var nested = includes;
    nested.depth += 1;
    if (!try self.addFile(path.items, nested)) self.skip();
}

/// The common dead-key pairs, for a system without Compose files.
const builtin_table =
    \\<dead_grave> <space> : "`"
    \\<dead_grave> <dead_grave> : "`"
    \\<dead_grave> <A> : "À"
    \\<dead_grave> <E> : "È"
    \\<dead_grave> <I> : "Ì"
    \\<dead_grave> <O> : "Ò"
    \\<dead_grave> <U> : "Ù"
    \\<dead_grave> <a> : "à"
    \\<dead_grave> <e> : "è"
    \\<dead_grave> <i> : "ì"
    \\<dead_grave> <o> : "ò"
    \\<dead_grave> <u> : "ù"
    \\<dead_acute> <space> : "'"
    \\<dead_acute> <dead_acute> : "´"
    \\<dead_acute> <A> : "Á"
    \\<dead_acute> <C> : "Ć"
    \\<dead_acute> <E> : "É"
    \\<dead_acute> <I> : "Í"
    \\<dead_acute> <L> : "Ĺ"
    \\<dead_acute> <N> : "Ń"
    \\<dead_acute> <O> : "Ó"
    \\<dead_acute> <S> : "Ś"
    \\<dead_acute> <U> : "Ú"
    \\<dead_acute> <Y> : "Ý"
    \\<dead_acute> <Z> : "Ź"
    \\<dead_acute> <a> : "á"
    \\<dead_acute> <c> : "ć"
    \\<dead_acute> <e> : "é"
    \\<dead_acute> <i> : "í"
    \\<dead_acute> <l> : "ĺ"
    \\<dead_acute> <n> : "ń"
    \\<dead_acute> <o> : "ó"
    \\<dead_acute> <s> : "ś"
    \\<dead_acute> <u> : "ú"
    \\<dead_acute> <y> : "ý"
    \\<dead_acute> <z> : "ź"
    \\<dead_circumflex> <space> : "^"
    \\<dead_circumflex> <dead_circumflex> : "^"
    \\<dead_circumflex> <A> : "Â"
    \\<dead_circumflex> <E> : "Ê"
    \\<dead_circumflex> <I> : "Î"
    \\<dead_circumflex> <O> : "Ô"
    \\<dead_circumflex> <U> : "Û"
    \\<dead_circumflex> <a> : "â"
    \\<dead_circumflex> <e> : "ê"
    \\<dead_circumflex> <i> : "î"
    \\<dead_circumflex> <o> : "ô"
    \\<dead_circumflex> <u> : "û"
    \\<dead_tilde> <space> : "~"
    \\<dead_tilde> <dead_tilde> : "~"
    \\<dead_tilde> <A> : "Ã"
    \\<dead_tilde> <I> : "Ĩ"
    \\<dead_tilde> <N> : "Ñ"
    \\<dead_tilde> <O> : "Õ"
    \\<dead_tilde> <U> : "Ũ"
    \\<dead_tilde> <a> : "ã"
    \\<dead_tilde> <i> : "ĩ"
    \\<dead_tilde> <n> : "ñ"
    \\<dead_tilde> <o> : "õ"
    \\<dead_tilde> <u> : "ũ"
    \\<dead_diaeresis> <space> : "¨"
    \\<dead_diaeresis> <dead_diaeresis> : "¨"
    \\<dead_diaeresis> <A> : "Ä"
    \\<dead_diaeresis> <E> : "Ë"
    \\<dead_diaeresis> <I> : "Ï"
    \\<dead_diaeresis> <O> : "Ö"
    \\<dead_diaeresis> <U> : "Ü"
    \\<dead_diaeresis> <Y> : "Ÿ"
    \\<dead_diaeresis> <a> : "ä"
    \\<dead_diaeresis> <e> : "ë"
    \\<dead_diaeresis> <i> : "ï"
    \\<dead_diaeresis> <o> : "ö"
    \\<dead_diaeresis> <u> : "ü"
    \\<dead_diaeresis> <y> : "ÿ"
    \\<dead_cedilla> <space> : "¸"
    \\<dead_cedilla> <dead_cedilla> : "¸"
    \\<dead_cedilla> <C> : "Ç"
    \\<dead_cedilla> <G> : "Ģ"
    \\<dead_cedilla> <S> : "Ş"
    \\<dead_cedilla> <T> : "Ţ"
    \\<dead_cedilla> <c> : "ç"
    \\<dead_cedilla> <g> : "ģ"
    \\<dead_cedilla> <s> : "ş"
    \\<dead_cedilla> <t> : "ţ"
    \\<dead_abovering> <space> : "°"
    \\<dead_abovering> <dead_abovering> : "°"
    \\<dead_abovering> <A> : "Å"
    \\<dead_abovering> <U> : "Ů"
    \\<dead_abovering> <a> : "å"
    \\<dead_abovering> <u> : "ů"
    \\<dead_caron> <space> : "ˇ"
    \\<dead_caron> <dead_caron> : "ˇ"
    \\<dead_caron> <C> : "Č"
    \\<dead_caron> <D> : "Ď"
    \\<dead_caron> <E> : "Ě"
    \\<dead_caron> <N> : "Ň"
    \\<dead_caron> <R> : "Ř"
    \\<dead_caron> <S> : "Š"
    \\<dead_caron> <T> : "Ť"
    \\<dead_caron> <Z> : "Ž"
    \\<dead_caron> <c> : "č"
    \\<dead_caron> <d> : "ď"
    \\<dead_caron> <e> : "ě"
    \\<dead_caron> <n> : "ň"
    \\<dead_caron> <r> : "ř"
    \\<dead_caron> <s> : "š"
    \\<dead_caron> <t> : "ť"
    \\<dead_caron> <z> : "ž"
    \\<dead_ogonek> <space> : "˛"
    \\<dead_ogonek> <dead_ogonek> : "˛"
    \\<dead_ogonek> <A> : "Ą"
    \\<dead_ogonek> <E> : "Ę"
    \\<dead_ogonek> <I> : "Į"
    \\<dead_ogonek> <U> : "Ų"
    \\<dead_ogonek> <a> : "ą"
    \\<dead_ogonek> <e> : "ę"
    \\<dead_ogonek> <i> : "į"
    \\<dead_ogonek> <u> : "ų"
    \\<dead_doubleacute> <space> : "˝"
    \\<dead_doubleacute> <dead_doubleacute> : "˝"
    \\<dead_doubleacute> <O> : "Ő"
    \\<dead_doubleacute> <U> : "Ű"
    \\<dead_doubleacute> <o> : "ő"
    \\<dead_doubleacute> <u> : "ű"
    \\<dead_macron> <space> : "¯"
    \\<dead_macron> <dead_macron> : "¯"
    \\<dead_macron> <A> : "Ā"
    \\<dead_macron> <E> : "Ē"
    \\<dead_macron> <I> : "Ī"
    \\<dead_macron> <O> : "Ō"
    \\<dead_macron> <U> : "Ū"
    \\<dead_macron> <a> : "ā"
    \\<dead_macron> <e> : "ē"
    \\<dead_macron> <i> : "ī"
    \\<dead_macron> <o> : "ō"
    \\<dead_macron> <u> : "ū"
    \\<dead_breve> <space> : "˘"
    \\<dead_breve> <dead_breve> : "˘"
    \\<dead_breve> <A> : "Ă"
    \\<dead_breve> <G> : "Ğ"
    \\<dead_breve> <U> : "Ŭ"
    \\<dead_breve> <a> : "ă"
    \\<dead_breve> <g> : "ğ"
    \\<dead_breve> <u> : "ŭ"
    \\<dead_abovedot> <space> : "˙"
    \\<dead_abovedot> <dead_abovedot> : "˙"
    \\<dead_abovedot> <C> : "Ċ"
    \\<dead_abovedot> <E> : "Ė"
    \\<dead_abovedot> <G> : "Ġ"
    \\<dead_abovedot> <I> : "İ"
    \\<dead_abovedot> <Z> : "Ż"
    \\<dead_abovedot> <c> : "ċ"
    \\<dead_abovedot> <e> : "ė"
    \\<dead_abovedot> <g> : "ġ"
    \\<dead_abovedot> <z> : "ż"
    \\<dead_stroke> <space> : "/"
    \\<dead_stroke> <D> : "Đ"
    \\<dead_stroke> <H> : "Ħ"
    \\<dead_stroke> <L> : "Ł"
    \\<dead_stroke> <O> : "Ø"
    \\<dead_stroke> <d> : "đ"
    \\<dead_stroke> <h> : "ħ"
    \\<dead_stroke> <l> : "ł"
    \\<dead_stroke> <o> : "ø"
    \\
;

const std = @import("std");
const wl = @import("wayland");
const keys = @import("keys.zig");
const testing = std.testing;
const log = std.log.scoped(.anywindow);

const dead_acute: u32 = 0xFE51;
const dead_circumflex: u32 = 0xFE52;
const dead_grave: u32 = 0xFE50;

fn expectComposed(step: Step, expected: []const u21) !void {
    const text: Text = switch (step) {
        .composed => |text| text,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualSlices(u21, expected, text.slice());
}

test "the built-in table composes accented letters and their spacing forms" {
    var compose = init(testing.allocator);
    defer compose.deinit();
    try compose.addText(builtin_table);
    try testing.expectEqual(@as(usize, 0), compose.skipped_lines);

    try testing.expectEqual(Step.pending, compose.feed(dead_circumflex));
    try testing.expect(compose.isPending());
    try expectComposed(compose.feed('e'), &.{0xEA});
    try testing.expect(!compose.isPending());

    try testing.expectEqual(Step.pending, compose.feed(dead_acute));
    try expectComposed(compose.feed(dead_acute), &.{0xB4});

    // A letter outside any sequence is ignored.
    try testing.expectEqual(Step.ignored, compose.feed('e'));
}

test "a broken sequence types the spacing accent and lets the key start over" {
    var compose = init(testing.allocator);
    defer compose.deinit();
    try compose.addText(builtin_table);

    _ = compose.feed(dead_circumflex);
    const broken = compose.feed('x');
    try testing.expectEqualSlices(u21, &.{'^'}, broken.cancelled.text.slice());
    try testing.expect(!broken.cancelled.restarted);
    try testing.expect(!compose.isPending());

    // The breaking key is a dead key itself: its accent is pending now.
    _ = compose.feed(dead_circumflex);
    const restarted = compose.feed(dead_grave);
    try testing.expectEqualSlices(u21, &.{'^'}, restarted.cancelled.text.slice());
    try testing.expect(restarted.cancelled.restarted);
    try expectComposed(compose.feed('a'), &.{0xE0});
}

test "escape, backspace and cancel drop the sequence silently; modifiers pass through" {
    var compose = init(testing.allocator);
    defer compose.deinit();
    try compose.addText(builtin_table);

    _ = compose.feed(dead_acute);
    try testing.expectEqual(Step.ignored, compose.feed(0xFFE1));
    try testing.expect(compose.isPending());
    const escaped = compose.feed(escape);
    try testing.expectEqual(@as(u8, 0), escaped.cancelled.text.len);
    try testing.expect(!compose.isPending());
    try testing.expectEqual(Step.ignored, compose.feed(escape));

    _ = compose.feed(dead_acute);
    try testing.expectEqual(@as(u8, 0), compose.feed(backspace).cancelled.text.len);

    _ = compose.feed(dead_acute);
    compose.cancel();
    try testing.expectEqual(Step.ignored, compose.feed('e'));
}

test "Compose file syntax: Multi_key sequences, escapes, comments, overrides, result keysyms" {
    var compose = init(testing.allocator);
    defer compose.deinit();
    // Tabs and spaces both separate fields, as in the files X ships.
    try compose.addText("# UTF-8 (Unicode) compose sequences\n" ++
        "<Multi_key> <minus> <minus> <period>\t: \"‐\"\tU2010 # HYPHEN\n" ++
        "<Multi_key> <quotedbl> <backslash> \t: \"〝\" U301d\t# REVERSED DOUBLE PRIME QUOTATION MARK\n" ++
        "<dead_acute> <c>\t: \"c\"\tccedilla\n" ++
        "<dead_acute> <c>\t: \"ç\"\tccedilla\n" ++
        "<dead_grave> <a>\t: \"\\\"\\\\\"\n" ++
        "<dead_grave> <e> : \"\\303\\250\"\n" ++
        "<dead_grave> <i> : \"\\xC3\\xAC\"\n" ++
        "<dead_grave> <o>\t: \"\\362\"\tograve\n" ++
        "<dead_grave> <u>\t:\tugrave\n" ++
        "<U17fe>\t: \"ោះ\"\t# KHMER VOWEL SIGN OO plus KHMER SIGN REAHMUK\n" ++
        "~Ctrl <a> : \"x\"\n" ++
        "<Greek_alpha> <a> : \"x\"\n" ++
        "include \"%L\"\n");
    try testing.expectEqual(@as(usize, 3), compose.skipped_lines);

    try testing.expectEqual(Step.pending, compose.feed(multi_key));
    try testing.expectEqual(Step.pending, compose.feed('-'));
    try testing.expectEqual(Step.pending, compose.feed('-'));
    try expectComposed(compose.feed('.'), &.{0x2010});
    _ = compose.feed(multi_key);
    _ = compose.feed('"');
    try expectComposed(compose.feed('\\'), &.{0x301D});
    // A broken Multi_key sequence types nothing for the Multi_key.
    _ = compose.feed(multi_key);
    try testing.expectEqual(@as(u8, 0), compose.feed('z').cancelled.text.len);

    _ = compose.feed(dead_acute);
    try expectComposed(compose.feed('c'), &.{0xE7});
    _ = compose.feed(dead_grave);
    try expectComposed(compose.feed('a'), &.{ '"', '\\' });
    _ = compose.feed(dead_grave);
    try expectComposed(compose.feed('e'), &.{0xE8});
    _ = compose.feed(dead_grave);
    try expectComposed(compose.feed('i'), &.{0xEC});
    // Latin-1 bytes are not UTF-8, so the result keysym decides.
    _ = compose.feed(dead_grave);
    try expectComposed(compose.feed('o'), &.{0xF2});
    _ = compose.feed(dead_grave);
    try expectComposed(compose.feed('u'), &.{0xF9});
    // A one-keysym sequence with a two-code-point result.
    try expectComposed(compose.feed(0x0100_17FE), &.{ 0x17C4, 0x17C7 });
}

test "directory lookups read both column layouts and skip comments" {
    const compose_dir = "# comment\niso8859-1/Compose\t\tC\nen_US.UTF-8/Compose\t\ten_US.UTF-8\nen_US.UTF-8/Compose:\t\tfr_FR.UTF-8\n";
    try testing.expectEqualStrings("en_US.UTF-8/Compose", findDirEntry(compose_dir, "en_US.UTF-8").?);
    try testing.expectEqualStrings("en_US.UTF-8/Compose", findDirEntry(compose_dir, "fr_FR.UTF-8").?);
    try testing.expectEqualStrings("iso8859-1/Compose", findDirEntry(compose_dir, "C").?);
    try testing.expectEqual(@as(?[]const u8, null), findDirEntry(compose_dir, "xx_XX"));
}

test "include expands the locale, home and system placeholders" {
    var compose = init(testing.allocator);
    defer compose.deinit();
    // Nothing at these paths, so every include is counted as skipped rather than read.
    const includes: Includes = .{ .io = testing.io, .locale_file = "/nonexistent/Compose", .home = "/nonexistent", .depth = 0 };
    try compose.include(" \"%L\"", includes);
    try compose.include("\"%H/.XCompose\"", includes);
    try compose.include("\"%S/nonexistent/Compose\"", includes);
    try compose.include("\"%Q\"", includes);
    try compose.include("no quotes", includes);
    try testing.expectEqual(@as(usize, 5), compose.skipped_lines);
    try testing.expectEqual(@as(usize, 0), compose.sequences.count());
}
