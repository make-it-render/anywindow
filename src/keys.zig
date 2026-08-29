//! Keyboard scancode and key mappings across platforms.

/// Logical key identity. Printable characters use their ASCII code point.
/// Non-printable keys use values in the 0x100+ range.
pub const Key = enum(u16) {
    unknown = 0,

    // Printable ASCII (matching code points)
    space = 0x20,
    apostrophe = 0x27,
    comma = 0x2C,
    minus = 0x2D,
    period = 0x2E,
    slash = 0x2F,

    @"0" = 0x30,
    @"1" = 0x31,
    @"2" = 0x32,
    @"3" = 0x33,
    @"4" = 0x34,
    @"5" = 0x35,
    @"6" = 0x36,
    @"7" = 0x37,
    @"8" = 0x38,
    @"9" = 0x39,

    semicolon = 0x3B,
    equal = 0x3D,

    a = 0x41,
    b = 0x42,
    c = 0x43,
    d = 0x44,
    e = 0x45,
    f = 0x46,
    g = 0x47,
    h = 0x48,
    i = 0x49,
    j = 0x4A,
    k = 0x4B,
    l = 0x4C,
    m = 0x4D,
    n = 0x4E,
    o = 0x4F,
    p = 0x50,
    q = 0x51,
    r = 0x52,
    s = 0x53,
    t = 0x54,
    u = 0x55,
    v = 0x56,
    w = 0x57,
    x = 0x58,
    y = 0x59,
    z = 0x5A,

    left_bracket = 0x5B,
    backslash = 0x5C,
    right_bracket = 0x5D,
    grave = 0x60,

    // Non-printable keys (0x100+)
    escape = 0x100,
    enter = 0x101,
    tab = 0x102,
    backspace = 0x103,
    insert = 0x104,
    delete = 0x105,
    right = 0x106,
    left = 0x107,
    down = 0x108,
    up = 0x109,
    page_up = 0x10A,
    page_down = 0x10B,
    home = 0x10C,
    end = 0x10D,
    caps_lock = 0x10E,
    scroll_lock = 0x10F,
    num_lock = 0x110,
    print_screen = 0x111,
    pause = 0x112,

    // Function keys
    f1 = 0x120,
    f2 = 0x121,
    f3 = 0x122,
    f4 = 0x123,
    f5 = 0x124,
    f6 = 0x125,
    f7 = 0x126,
    f8 = 0x127,
    f9 = 0x128,
    f10 = 0x129,
    f11 = 0x12A,
    f12 = 0x12B,

    // Numpad
    kp_0 = 0x140,
    kp_1 = 0x141,
    kp_2 = 0x142,
    kp_3 = 0x143,
    kp_4 = 0x144,
    kp_5 = 0x145,
    kp_6 = 0x146,
    kp_7 = 0x147,
    kp_8 = 0x148,
    kp_9 = 0x149,
    kp_period = 0x14A,
    kp_divide = 0x14B,
    kp_multiply = 0x14C,
    kp_minus = 0x14D,
    kp_plus = 0x14E,
    kp_enter = 0x14F,

    // Modifiers
    left_shift = 0x160,
    left_control = 0x161,
    left_alt = 0x162,
    left_super = 0x163,
    right_shift = 0x164,
    right_control = 0x165,
    right_alt = 0x166,
    right_super = 0x167,

    menu = 0x168,

    _,
};

/// Windows scan code to common Scancode
pub fn windowsScanToScancode(scan: u8, extended: bool) Scancode {
    if (extended) {
        return switch (scan) {
            0x1C => .kp_enter,
            0x1D => .right_control,
            0x35 => .kp_divide,
            0x38 => .right_alt,
            0x47 => .home,
            0x48 => .up,
            0x49 => .page_up,
            0x4B => .left,
            0x4D => .right,
            0x4F => .end,
            0x50 => .down,
            0x51 => .page_down,
            0x52 => .insert,
            0x53 => .delete,
            0x5B => .left_super,
            0x5C => .right_super,
            0x5D => .application,
            else => .unknown,
        };
    }
    return switch (scan) {
        0x01 => .escape,
        0x02 => .@"1",
        0x03 => .@"2",
        0x04 => .@"3",
        0x05 => .@"4",
        0x06 => .@"5",
        0x07 => .@"6",
        0x08 => .@"7",
        0x09 => .@"8",
        0x0A => .@"9",
        0x0B => .@"0",
        0x0C => .minus,
        0x0D => .equal,
        0x0E => .backspace,
        0x0F => .tab,
        0x10 => .q,
        0x11 => .w,
        0x12 => .e,
        0x13 => .r,
        0x14 => .t,
        0x15 => .y,
        0x16 => .u,
        0x17 => .i,
        0x18 => .o,
        0x19 => .p,
        0x1A => .left_bracket,
        0x1B => .right_bracket,
        0x1C => .enter,
        0x1D => .left_control,
        0x1E => .a,
        0x1F => .s,
        0x20 => .d,
        0x21 => .f,
        0x22 => .g,
        0x23 => .h,
        0x24 => .j,
        0x25 => .k,
        0x26 => .l,
        0x27 => .semicolon,
        0x28 => .apostrophe,
        0x29 => .grave,
        0x2A => .left_shift,
        0x2B => .backslash,
        0x2C => .z,
        0x2D => .x,
        0x2E => .c,
        0x2F => .v,
        0x30 => .b,
        0x31 => .n,
        0x32 => .m,
        0x33 => .comma,
        0x34 => .period,
        0x35 => .slash,
        0x36 => .right_shift,
        0x37 => .kp_multiply,
        0x38 => .left_alt,
        0x39 => .space,
        0x3A => .caps_lock,
        0x3B => .f1,
        0x3C => .f2,
        0x3D => .f3,
        0x3E => .f4,
        0x3F => .f5,
        0x40 => .f6,
        0x41 => .f7,
        0x42 => .f8,
        0x43 => .f9,
        0x44 => .f10,
        0x45 => .num_lock,
        0x46 => .scroll_lock,
        0x47 => .kp_7,
        0x48 => .kp_8,
        0x49 => .kp_9,
        0x4A => .kp_minus,
        0x4B => .kp_4,
        0x4C => .kp_5,
        0x4D => .kp_6,
        0x4E => .kp_plus,
        0x4F => .kp_1,
        0x50 => .kp_2,
        0x51 => .kp_3,
        0x52 => .kp_0,
        0x53 => .kp_period,
        0x56 => .non_us_backslash,
        0x57 => .f11,
        0x58 => .f12,
        else => .unknown,
    };
}

// ============================================================
// Evdev code -> Scancode (Linux)
// ============================================================

/// Maps evdev key codes (keycode - 8) to USB HID scancodes.
/// Evdev codes are dense so a lookup table is efficient.
pub fn evdevToScancode(evdev: u8) Scancode {
    return evdev_to_scancode_table[evdev];
}

const evdev_to_scancode_table: [256]Scancode = init: {
    var table: [256]Scancode = @splat(.unknown);
    // Row 0: Escape and number row
    table[1] = .escape;
    table[2] = .@"1";
    table[3] = .@"2";
    table[4] = .@"3";
    table[5] = .@"4";
    table[6] = .@"5";
    table[7] = .@"6";
    table[8] = .@"7";
    table[9] = .@"8";
    table[10] = .@"9";
    table[11] = .@"0";
    table[12] = .minus;
    table[13] = .equal;
    table[14] = .backspace;
    // Row 1: Tab and QWERTY
    table[15] = .tab;
    table[16] = .q;
    table[17] = .w;
    table[18] = .e;
    table[19] = .r;
    table[20] = .t;
    table[21] = .y;
    table[22] = .u;
    table[23] = .i;
    table[24] = .o;
    table[25] = .p;
    table[26] = .left_bracket;
    table[27] = .right_bracket;
    table[28] = .enter;
    // Row 2: Caps, home row
    table[29] = .left_control;
    table[30] = .a;
    table[31] = .s;
    table[32] = .d;
    table[33] = .f;
    table[34] = .g;
    table[35] = .h;
    table[36] = .j;
    table[37] = .k;
    table[38] = .l;
    table[39] = .semicolon;
    table[40] = .apostrophe;
    table[41] = .grave;
    // Row 3: Shift, bottom row
    table[42] = .left_shift;
    table[43] = .backslash;
    table[44] = .z;
    table[45] = .x;
    table[46] = .c;
    table[47] = .v;
    table[48] = .b;
    table[49] = .n;
    table[50] = .m;
    table[51] = .comma;
    table[52] = .period;
    table[53] = .slash;
    table[54] = .right_shift;
    // Numpad and misc
    table[55] = .kp_multiply;
    table[56] = .left_alt;
    table[57] = .space;
    table[58] = .caps_lock;
    // Function keys
    table[59] = .f1;
    table[60] = .f2;
    table[61] = .f3;
    table[62] = .f4;
    table[63] = .f5;
    table[64] = .f6;
    table[65] = .f7;
    table[66] = .f8;
    table[67] = .f9;
    table[68] = .f10;
    // Num/scroll lock
    table[69] = .num_lock;
    table[70] = .scroll_lock;
    // Numpad digits
    table[71] = .kp_7;
    table[72] = .kp_8;
    table[73] = .kp_9;
    table[74] = .kp_minus;
    table[75] = .kp_4;
    table[76] = .kp_5;
    table[77] = .kp_6;
    table[78] = .kp_plus;
    table[79] = .kp_1;
    table[80] = .kp_2;
    table[81] = .kp_3;
    table[82] = .kp_0;
    table[83] = .kp_period;
    // Extra keys
    table[86] = .non_us_backslash;
    table[87] = .f11;
    table[88] = .f12;
    // Extended keys
    table[96] = .kp_enter;
    table[97] = .right_control;
    table[98] = .kp_divide;
    table[99] = .print_screen;
    table[100] = .right_alt;
    table[102] = .home;
    table[103] = .up;
    table[104] = .page_up;
    table[105] = .left;
    table[106] = .right;
    table[107] = .end;
    table[108] = .down;
    table[109] = .page_down;
    table[110] = .insert;
    table[111] = .delete;
    table[119] = .pause;
    table[125] = .left_super;
    table[126] = .right_super;
    table[127] = .application;
    break :init table;
};

/// Scancode to logical Key assuming a US layout. Used by backends that get
/// positional codes but don't resolve the real keymap (Wayland v1 skips XKB
/// parsing; Wayland keycodes are raw evdev codes).
pub fn scancodeToKey(scancode: Scancode) Key {
    return switch (scancode) {
        .a => .a,
        .b => .b,
        .c => .c,
        .d => .d,
        .e => .e,
        .f => .f,
        .g => .g,
        .h => .h,
        .i => .i,
        .j => .j,
        .k => .k,
        .l => .l,
        .m => .m,
        .n => .n,
        .o => .o,
        .p => .p,
        .q => .q,
        .r => .r,
        .s => .s,
        .t => .t,
        .u => .u,
        .v => .v,
        .w => .w,
        .x => .x,
        .y => .y,
        .z => .z,
        .@"1" => .@"1",
        .@"2" => .@"2",
        .@"3" => .@"3",
        .@"4" => .@"4",
        .@"5" => .@"5",
        .@"6" => .@"6",
        .@"7" => .@"7",
        .@"8" => .@"8",
        .@"9" => .@"9",
        .@"0" => .@"0",
        .enter => .enter,
        .escape => .escape,
        .backspace => .backspace,
        .tab => .tab,
        .space => .space,
        .minus => .minus,
        .equal => .equal,
        .left_bracket => .left_bracket,
        .right_bracket => .right_bracket,
        .backslash => .backslash,
        .non_us_backslash => .backslash,
        .semicolon => .semicolon,
        .apostrophe => .apostrophe,
        .grave => .grave,
        .comma => .comma,
        .period => .period,
        .slash => .slash,
        .caps_lock => .caps_lock,
        .f1 => .f1,
        .f2 => .f2,
        .f3 => .f3,
        .f4 => .f4,
        .f5 => .f5,
        .f6 => .f6,
        .f7 => .f7,
        .f8 => .f8,
        .f9 => .f9,
        .f10 => .f10,
        .f11 => .f11,
        .f12 => .f12,
        .print_screen => .print_screen,
        .scroll_lock => .scroll_lock,
        .pause => .pause,
        .insert => .insert,
        .home => .home,
        .page_up => .page_up,
        .delete => .delete,
        .end => .end,
        .page_down => .page_down,
        .right => .right,
        .left => .left,
        .down => .down,
        .up => .up,
        .num_lock => .num_lock,
        .kp_divide => .kp_divide,
        .kp_multiply => .kp_multiply,
        .kp_minus => .kp_minus,
        .kp_plus => .kp_plus,
        .kp_enter => .kp_enter,
        .kp_1 => .kp_1,
        .kp_2 => .kp_2,
        .kp_3 => .kp_3,
        .kp_4 => .kp_4,
        .kp_5 => .kp_5,
        .kp_6 => .kp_6,
        .kp_7 => .kp_7,
        .kp_8 => .kp_8,
        .kp_9 => .kp_9,
        .kp_0 => .kp_0,
        .kp_period => .kp_period,
        .left_control => .left_control,
        .left_shift => .left_shift,
        .left_alt => .left_alt,
        .left_super => .left_super,
        .right_control => .right_control,
        .right_shift => .right_shift,
        .right_alt => .right_alt,
        .right_super => .right_super,
        .application => .menu,
        else => .unknown,
    };
}

/// Windows VK code to common Key
pub fn windowsVkToKey(vk: u8) Key {
    return switch (vk) {
        0x08 => .backspace,
        0x09 => .tab,
        0x0D => .enter,
        0x10 => .left_shift,
        0x11 => .left_control,
        0x12 => .left_alt,
        0x13 => .pause,
        0x14 => .caps_lock,
        0x1B => .escape,
        0x20 => .space,
        0x21 => .page_up,
        0x22 => .page_down,
        0x23 => .end,
        0x24 => .home,
        0x25 => .left,
        0x26 => .up,
        0x27 => .right,
        0x28 => .down,
        0x2C => .print_screen,
        0x2D => .insert,
        0x2E => .delete,
        // Digits 0-9
        0x30 => .@"0",
        0x31 => .@"1",
        0x32 => .@"2",
        0x33 => .@"3",
        0x34 => .@"4",
        0x35 => .@"5",
        0x36 => .@"6",
        0x37 => .@"7",
        0x38 => .@"8",
        0x39 => .@"9",
        // Letters A-Z
        0x41 => .a,
        0x42 => .b,
        0x43 => .c,
        0x44 => .d,
        0x45 => .e,
        0x46 => .f,
        0x47 => .g,
        0x48 => .h,
        0x49 => .i,
        0x4A => .j,
        0x4B => .k,
        0x4C => .l,
        0x4D => .m,
        0x4E => .n,
        0x4F => .o,
        0x50 => .p,
        0x51 => .q,
        0x52 => .r,
        0x53 => .s,
        0x54 => .t,
        0x55 => .u,
        0x56 => .v,
        0x57 => .w,
        0x58 => .x,
        0x59 => .y,
        0x5A => .z,
        // Windows keys
        0x5B => .left_super,
        0x5C => .right_super,
        0x5D => .menu,
        // Numpad
        0x60 => .kp_0,
        0x61 => .kp_1,
        0x62 => .kp_2,
        0x63 => .kp_3,
        0x64 => .kp_4,
        0x65 => .kp_5,
        0x66 => .kp_6,
        0x67 => .kp_7,
        0x68 => .kp_8,
        0x69 => .kp_9,
        0x6A => .kp_multiply,
        0x6B => .kp_plus,
        0x6D => .kp_minus,
        0x6E => .kp_period,
        0x6F => .kp_divide,
        // Function keys
        0x70 => .f1,
        0x71 => .f2,
        0x72 => .f3,
        0x73 => .f4,
        0x74 => .f5,
        0x75 => .f6,
        0x76 => .f7,
        0x77 => .f8,
        0x78 => .f9,
        0x79 => .f10,
        0x7A => .f11,
        0x7B => .f12,
        0x90 => .num_lock,
        0x91 => .scroll_lock,
        // Left/right specific modifiers
        0xA0 => .left_shift,
        0xA1 => .right_shift,
        0xA2 => .left_control,
        0xA3 => .right_control,
        0xA4 => .left_alt,
        0xA5 => .right_alt,
        // OEM keys (US layout)
        0xBA => .semicolon,
        0xBB => .equal,
        0xBC => .comma,
        0xBD => .minus,
        0xBE => .period,
        0xBF => .slash,
        0xC0 => .grave,
        0xDB => .left_bracket,
        0xDC => .backslash,
        0xDD => .right_bracket,
        0xDE => .apostrophe,
        else => .unknown,
    };
}

/// X11 keysym to common Key
pub fn x11KeysymToKey(keysym: u32) Key {
    return switch (keysym) {
        // Latin-1: printable ASCII range
        0x0020 => .space,
        0x0027 => .apostrophe,
        0x002C => .comma,
        0x002D => .minus,
        0x002E => .period,
        0x002F => .slash,
        0x0030 => .@"0",
        0x0031 => .@"1",
        0x0032 => .@"2",
        0x0033 => .@"3",
        0x0034 => .@"4",
        0x0035 => .@"5",
        0x0036 => .@"6",
        0x0037 => .@"7",
        0x0038 => .@"8",
        0x0039 => .@"9",
        0x003B => .semicolon,
        0x003D => .equal,
        // Lowercase a-z
        0x0041...0x005A => |v| @enumFromInt(v),
        0x005B => .left_bracket,
        0x005C => .backslash,
        0x005D => .right_bracket,
        0x0060 => .grave,
        0x0061...0x007A => |v| @enumFromInt(v - 0x20), // map lowercase to uppercase Key values
        // Function keys (XK_F1 = 0xFFBE)
        0xFFBE => .f1,
        0xFFBF => .f2,
        0xFFC0 => .f3,
        0xFFC1 => .f4,
        0xFFC2 => .f5,
        0xFFC3 => .f6,
        0xFFC4 => .f7,
        0xFFC5 => .f8,
        0xFFC6 => .f9,
        0xFFC7 => .f10,
        0xFFC8 => .f11,
        0xFFC9 => .f12,
        // Misc function keys
        0xFF08 => .backspace,
        0xFF09 => .tab,
        0xFF0D => .enter,
        0xFF13 => .pause,
        0xFF14 => .scroll_lock,
        0xFF1B => .escape,
        // Navigation
        0xFF50 => .home,
        0xFF51 => .left,
        0xFF52 => .up,
        0xFF53 => .right,
        0xFF54 => .down,
        0xFF55 => .page_up,
        0xFF56 => .page_down,
        0xFF57 => .end,
        // Editing
        0xFF61 => .print_screen,
        0xFF63 => .insert,
        0xFFFF => .delete,
        // Modifiers
        0xFFE1 => .left_shift,
        0xFFE2 => .right_shift,
        0xFFE3 => .left_control,
        0xFFE4 => .right_control,
        0xFFE5 => .caps_lock,
        0xFFE9 => .left_alt,
        0xFFEA => .right_alt,
        0xFE03 => .right_alt, // ISO_Level3_Shift: AltGr on European layouts
        0xFFEB => .left_super,
        0xFFEC => .right_super,
        // Numpad
        0xFF7F => .num_lock,
        0xFF8D => .kp_enter,
        0xFFAA => .kp_multiply,
        0xFFAB => .kp_plus,
        0xFFAD => .kp_minus,
        0xFFAE => .kp_period,
        0xFFAF => .kp_divide,
        0xFFB0 => .kp_0,
        0xFFB1 => .kp_1,
        0xFFB2 => .kp_2,
        0xFFB3 => .kp_3,
        0xFFB4 => .kp_4,
        0xFFB5 => .kp_5,
        0xFFB6 => .kp_6,
        0xFFB7 => .kp_7,
        0xFFB8 => .kp_8,
        0xFFB9 => .kp_9,
        // Menu
        0xFF67 => .menu,
        else => .unknown,
    };
}
/// The character an X11/XKB keysym types, or null for keysyms that type
/// nothing: function, navigation, modifier and dead keys, and control
/// characters. Latin-1 keysyms are their own code point, `0x01000000 | code
/// point` keysyms strip the prefix, keypad keysyms give their digit or
/// operator, and the legacy blocks go through the keysym2ucs mapping.
pub fn keysymToCodepoint(keysym: u32) ?u21 {
    switch (keysym) {
        0x0020...0x007E, 0x00A0...0x00FF => return @intCast(keysym),
        0x01000000...0x0110FFFF => {
            const codepoint: u21 = @intCast(keysym & 0x00FFFFFF);
            if (codepoint < 0x20 or (codepoint >= 0x7F and codepoint < 0xA0)) return null;
            return codepoint;
        },
        // Keypad: KP_Space, then KP_Multiply..KP_Divide are '*' '+' ',' '-' '.' '/', digits, KP_Equal.
        0xFF80 => return ' ',
        0xFFAA...0xFFAF => return @intCast('*' + (keysym - 0xFFAA)),
        0xFFB0...0xFFB9 => return @intCast('0' + (keysym - 0xFFB0)),
        0xFFBD => return '=',
        // Currency keysyms coincide with their code points.
        0x20A0...0x20AC => return @intCast(keysym),
        // Cyrillic follows KOI8 order; capitals sit 0x20 above their small letters in Unicode.
        0x06C0...0x06DF => return cyrillic_small[keysym - 0x06C0],
        0x06E0...0x06FF => return cyrillic_small[keysym - 0x06E0] - 0x20,
        // Greek letters are a fixed offset, except sigma: keysym 0x07D2 is
        // capital sigma (U+03A2 is unassigned) and 0x07F3 the final small sigma.
        0x07C1...0x07D1, 0x07D4...0x07D9, 0x07E1...0x07F1, 0x07F4...0x07F9 => return @intCast(keysym - 0x0430),
        0x07D2 => return 0x03A3,
        0x07F2 => return 0x03C3,
        0x07F3 => return 0x03C2,
        // Arabic, Hebrew and Thai keysyms are their ISO 8859 / TIS-620 bytes.
        0x05AC...0x05F2 => return @intCast(keysym + 0x60),
        0x0CE0...0x0CFA => return @intCast(keysym - 0x0CE0 + 0x05D0),
        0x0DA1...0x0DFB => return @intCast(keysym + 0x60),
        else => {},
    }

    var low: usize = 0;
    var high: usize = keysym_table.len;
    while (low < high) {
        const middle = (low + high) / 2;
        if (keysym_table[middle][0] < keysym) low = middle + 1 else high = middle;
    }
    if (low < keysym_table.len and keysym_table[low][0] == keysym) return @intCast(keysym_table[low][1]);
    return null;
}

/// A US-layout guess at the character a key types, for a backend with no
/// keymap: letters follow shift and caps lock, every other printable key
/// gives its unshifted character.
pub fn keyToCodepoint(key: Key, modifiers: Modifiers) ?u21 {
    const value = @intFromEnum(key);
    if (value < 0x20 or value > 0x7E) return null;
    if (value >= 'A' and value <= 'Z') {
        const upper = modifiers.shift != modifiers.caps_lock;
        return if (upper) value else value + 0x20;
    }
    return value;
}

/// Whether holding the key auto-repeats it. Modifier and lock keys do not.
pub fn repeats(key: Key) bool {
    return switch (key) {
        .left_shift, .left_control, .left_alt, .left_super, .right_shift, .right_control, .right_alt, .right_super, .caps_lock, .num_lock, .scroll_lock => false,
        else => true,
    };
}

/// Keysyms 0x06C0..0x06DF (small Cyrillic letters, KOI8 order).
const cyrillic_small = [32]u21{
    0x044E, 0x0430, 0x0431, 0x0446, 0x0434, 0x0435, 0x0444, 0x0433,
    0x0445, 0x0438, 0x0439, 0x043A, 0x043B, 0x043C, 0x043D, 0x043E,
    0x043F, 0x044F, 0x0440, 0x0441, 0x0442, 0x0443, 0x0436, 0x0432,
    0x044C, 0x044B, 0x0437, 0x0448, 0x044D, 0x0449, 0x0447, 0x044A,
};

/// keysym2ucs pairs (keysym, code point) for the legacy blocks that are not
/// a plain offset: Latin-2/3/4/8/9, the Cyrillic and Greek extras,
/// technical, special, publishing and APL symbols. Sorted by keysym.
const keysym_table = [_][2]u32{
    .{ 0x01A1, 0x0104 }, .{ 0x01A2, 0x02D8 }, .{ 0x01A3, 0x0141 }, .{ 0x01A5, 0x013D }, .{ 0x01A6, 0x015A },
    .{ 0x01A9, 0x0160 }, .{ 0x01AA, 0x015E }, .{ 0x01AB, 0x0164 }, .{ 0x01AC, 0x0179 }, .{ 0x01AE, 0x017D },
    .{ 0x01AF, 0x017B }, .{ 0x01B1, 0x0105 }, .{ 0x01B2, 0x02DB }, .{ 0x01B3, 0x0142 }, .{ 0x01B5, 0x013E },
    .{ 0x01B6, 0x015B }, .{ 0x01B7, 0x02C7 }, .{ 0x01B9, 0x0161 }, .{ 0x01BA, 0x015F }, .{ 0x01BB, 0x0165 },
    .{ 0x01BC, 0x017A }, .{ 0x01BD, 0x02DD }, .{ 0x01BE, 0x017E }, .{ 0x01BF, 0x017C }, .{ 0x01C0, 0x0154 },
    .{ 0x01C3, 0x0102 }, .{ 0x01C5, 0x0139 }, .{ 0x01C6, 0x0106 }, .{ 0x01C8, 0x010C }, .{ 0x01CA, 0x0118 },
    .{ 0x01CC, 0x011A }, .{ 0x01CF, 0x010E }, .{ 0x01D0, 0x0110 }, .{ 0x01D1, 0x0143 }, .{ 0x01D2, 0x0147 },
    .{ 0x01D5, 0x0150 }, .{ 0x01D8, 0x0158 }, .{ 0x01D9, 0x016E }, .{ 0x01DB, 0x0170 }, .{ 0x01DE, 0x0162 },
    .{ 0x01E0, 0x0155 }, .{ 0x01E3, 0x0103 }, .{ 0x01E5, 0x013A }, .{ 0x01E6, 0x0107 }, .{ 0x01E8, 0x010D },
    .{ 0x01EA, 0x0119 }, .{ 0x01EC, 0x011B }, .{ 0x01EF, 0x010F }, .{ 0x01F0, 0x0111 }, .{ 0x01F1, 0x0144 },
    .{ 0x01F2, 0x0148 }, .{ 0x01F5, 0x0151 }, .{ 0x01F8, 0x0159 }, .{ 0x01F9, 0x016F }, .{ 0x01FB, 0x0171 },
    .{ 0x01FE, 0x0163 }, .{ 0x01FF, 0x02D9 },
    .{ 0x02A1, 0x0126 }, .{ 0x02A6, 0x0124 }, .{ 0x02A9, 0x0130 }, .{ 0x02AB, 0x011E }, .{ 0x02AC, 0x0134 },
    .{ 0x02B1, 0x0127 }, .{ 0x02B6, 0x0125 }, .{ 0x02B9, 0x0131 }, .{ 0x02BB, 0x011F }, .{ 0x02BC, 0x0135 },
    .{ 0x02C5, 0x010A }, .{ 0x02C6, 0x0108 }, .{ 0x02D5, 0x0120 }, .{ 0x02D8, 0x011C }, .{ 0x02DD, 0x016C },
    .{ 0x02DE, 0x015C }, .{ 0x02E5, 0x010B }, .{ 0x02E6, 0x0109 }, .{ 0x02F5, 0x0121 }, .{ 0x02F8, 0x011D },
    .{ 0x02FD, 0x016D }, .{ 0x02FE, 0x015D },
    .{ 0x03A2, 0x0138 }, .{ 0x03A3, 0x0156 }, .{ 0x03A5, 0x0128 }, .{ 0x03A6, 0x013B }, .{ 0x03AA, 0x0112 },
    .{ 0x03AB, 0x0122 }, .{ 0x03AC, 0x0166 }, .{ 0x03B3, 0x0157 }, .{ 0x03B5, 0x0129 }, .{ 0x03B6, 0x013C },
    .{ 0x03BA, 0x0113 }, .{ 0x03BB, 0x0123 }, .{ 0x03BC, 0x0167 }, .{ 0x03BD, 0x014A }, .{ 0x03BF, 0x014B },
    .{ 0x03C0, 0x0100 }, .{ 0x03C7, 0x012E }, .{ 0x03CC, 0x0116 }, .{ 0x03CF, 0x012A }, .{ 0x03D1, 0x0145 },
    .{ 0x03D2, 0x014C }, .{ 0x03D3, 0x0136 }, .{ 0x03D9, 0x0172 }, .{ 0x03DD, 0x0168 }, .{ 0x03DE, 0x016A },
    .{ 0x03E0, 0x0101 }, .{ 0x03E7, 0x012F }, .{ 0x03EC, 0x0117 }, .{ 0x03EF, 0x012B }, .{ 0x03F1, 0x0146 },
    .{ 0x03F2, 0x014D }, .{ 0x03F3, 0x0137 }, .{ 0x03F9, 0x0173 }, .{ 0x03FD, 0x0169 }, .{ 0x03FE, 0x016B },
    .{ 0x06A1, 0x0452 }, .{ 0x06A2, 0x0453 }, .{ 0x06A3, 0x0451 }, .{ 0x06A4, 0x0454 }, .{ 0x06A5, 0x0455 },
    .{ 0x06A6, 0x0456 }, .{ 0x06A7, 0x0457 }, .{ 0x06A8, 0x0458 }, .{ 0x06A9, 0x0459 }, .{ 0x06AA, 0x045A },
    .{ 0x06AB, 0x045B }, .{ 0x06AC, 0x045C }, .{ 0x06AD, 0x0491 }, .{ 0x06AE, 0x045E }, .{ 0x06AF, 0x045F },
    .{ 0x06B0, 0x2116 }, .{ 0x06B1, 0x0402 }, .{ 0x06B2, 0x0403 }, .{ 0x06B3, 0x0401 }, .{ 0x06B4, 0x0404 },
    .{ 0x06B5, 0x0405 }, .{ 0x06B6, 0x0406 }, .{ 0x06B7, 0x0407 }, .{ 0x06B8, 0x0408 }, .{ 0x06B9, 0x0409 },
    .{ 0x06BA, 0x040A }, .{ 0x06BB, 0x040B }, .{ 0x06BC, 0x040C }, .{ 0x06BD, 0x0490 }, .{ 0x06BE, 0x040E },
    .{ 0x06BF, 0x040F },
    .{ 0x07A1, 0x0386 }, .{ 0x07A2, 0x0388 }, .{ 0x07A3, 0x0389 }, .{ 0x07A4, 0x038A }, .{ 0x07A5, 0x03AA },
    .{ 0x07A7, 0x038C }, .{ 0x07A8, 0x038E }, .{ 0x07A9, 0x03AB }, .{ 0x07AB, 0x038F }, .{ 0x07AE, 0x0385 },
    .{ 0x07AF, 0x2015 }, .{ 0x07B1, 0x03AC }, .{ 0x07B2, 0x03AD }, .{ 0x07B3, 0x03AE }, .{ 0x07B4, 0x03AF },
    .{ 0x07B5, 0x03CA }, .{ 0x07B6, 0x0390 }, .{ 0x07B7, 0x03CC }, .{ 0x07B8, 0x03CD }, .{ 0x07B9, 0x03CB },
    .{ 0x07BA, 0x03B0 }, .{ 0x07BB, 0x03CE },
    .{ 0x08A1, 0x23B7 }, .{ 0x08A2, 0x250C }, .{ 0x08A3, 0x2500 }, .{ 0x08A4, 0x2320 }, .{ 0x08A5, 0x2321 },
    .{ 0x08A6, 0x2502 }, .{ 0x08A7, 0x23A1 }, .{ 0x08A8, 0x23A3 }, .{ 0x08A9, 0x23A4 }, .{ 0x08AA, 0x23A6 },
    .{ 0x08AB, 0x239B }, .{ 0x08AC, 0x239D }, .{ 0x08AD, 0x239E }, .{ 0x08AE, 0x23A0 }, .{ 0x08AF, 0x23A8 },
    .{ 0x08B0, 0x23AC }, .{ 0x08BC, 0x2264 }, .{ 0x08BD, 0x2260 }, .{ 0x08BE, 0x2265 }, .{ 0x08BF, 0x222B },
    .{ 0x08C0, 0x2234 }, .{ 0x08C1, 0x221D }, .{ 0x08C2, 0x221E }, .{ 0x08C5, 0x2207 }, .{ 0x08C8, 0x223C },
    .{ 0x08C9, 0x2243 }, .{ 0x08CD, 0x21D4 }, .{ 0x08CE, 0x21D2 }, .{ 0x08CF, 0x2261 }, .{ 0x08D6, 0x221A },
    .{ 0x08DA, 0x2282 }, .{ 0x08DB, 0x2283 }, .{ 0x08DC, 0x2229 }, .{ 0x08DD, 0x222A }, .{ 0x08DE, 0x2227 },
    .{ 0x08DF, 0x2228 }, .{ 0x08EF, 0x2202 }, .{ 0x08F6, 0x0192 }, .{ 0x08FB, 0x2190 }, .{ 0x08FC, 0x2191 },
    .{ 0x08FD, 0x2192 }, .{ 0x08FE, 0x2193 },
    .{ 0x09E0, 0x25C6 }, .{ 0x09E1, 0x2592 }, .{ 0x09E2, 0x2409 }, .{ 0x09E3, 0x240C }, .{ 0x09E4, 0x240D },
    .{ 0x09E5, 0x240A }, .{ 0x09E8, 0x2424 }, .{ 0x09E9, 0x240B }, .{ 0x09EA, 0x2518 }, .{ 0x09EB, 0x2510 },
    .{ 0x09EC, 0x250C }, .{ 0x09ED, 0x2514 }, .{ 0x09EE, 0x253C }, .{ 0x09EF, 0x23BA }, .{ 0x09F0, 0x23BB },
    .{ 0x09F1, 0x2500 }, .{ 0x09F2, 0x23BC }, .{ 0x09F3, 0x23BD }, .{ 0x09F4, 0x251C }, .{ 0x09F5, 0x2524 },
    .{ 0x09F6, 0x2534 }, .{ 0x09F7, 0x252C }, .{ 0x09F8, 0x2502 },
    .{ 0x0AA1, 0x2003 }, .{ 0x0AA2, 0x2002 }, .{ 0x0AA3, 0x2004 }, .{ 0x0AA4, 0x2005 }, .{ 0x0AA5, 0x2007 },
    .{ 0x0AA6, 0x2008 }, .{ 0x0AA7, 0x2009 }, .{ 0x0AA8, 0x200A }, .{ 0x0AA9, 0x2014 }, .{ 0x0AAA, 0x2013 },
    .{ 0x0AAC, 0x2423 }, .{ 0x0AAE, 0x2026 }, .{ 0x0AAF, 0x2025 }, .{ 0x0AB0, 0x2153 }, .{ 0x0AB1, 0x2154 },
    .{ 0x0AB2, 0x2155 }, .{ 0x0AB3, 0x2156 }, .{ 0x0AB4, 0x2157 }, .{ 0x0AB5, 0x2158 }, .{ 0x0AB6, 0x2159 },
    .{ 0x0AB7, 0x215A }, .{ 0x0AB8, 0x2105 }, .{ 0x0ABB, 0x2012 }, .{ 0x0ABC, 0x27E8 }, .{ 0x0ABD, 0x002E },
    .{ 0x0ABE, 0x27E9 }, .{ 0x0AC3, 0x215B }, .{ 0x0AC4, 0x215C }, .{ 0x0AC5, 0x215D }, .{ 0x0AC6, 0x215E },
    .{ 0x0AC9, 0x2122 }, .{ 0x0ACA, 0x2613 }, .{ 0x0ACC, 0x25C1 }, .{ 0x0ACD, 0x25B7 }, .{ 0x0ACE, 0x25CB },
    .{ 0x0ACF, 0x25AF }, .{ 0x0AD0, 0x2018 }, .{ 0x0AD1, 0x2019 }, .{ 0x0AD2, 0x201C }, .{ 0x0AD3, 0x201D },
    .{ 0x0AD4, 0x211E }, .{ 0x0AD5, 0x2030 }, .{ 0x0AD6, 0x2032 }, .{ 0x0AD7, 0x2033 }, .{ 0x0AD9, 0x271D },
    .{ 0x0ADB, 0x25AC }, .{ 0x0ADC, 0x25C0 }, .{ 0x0ADD, 0x25B6 }, .{ 0x0ADE, 0x25CF }, .{ 0x0ADF, 0x25AE },
    .{ 0x0AE0, 0x25E6 }, .{ 0x0AE1, 0x25AB }, .{ 0x0AE2, 0x25AD }, .{ 0x0AE3, 0x25B3 }, .{ 0x0AE4, 0x25BD },
    .{ 0x0AE5, 0x2606 }, .{ 0x0AE6, 0x2022 }, .{ 0x0AE7, 0x25AA }, .{ 0x0AE8, 0x25B2 }, .{ 0x0AE9, 0x25BC },
    .{ 0x0AEA, 0x261C }, .{ 0x0AEB, 0x261E }, .{ 0x0AEC, 0x2663 }, .{ 0x0AED, 0x2666 }, .{ 0x0AEE, 0x2665 },
    .{ 0x0AF0, 0x2720 }, .{ 0x0AF1, 0x2020 }, .{ 0x0AF2, 0x2021 }, .{ 0x0AF3, 0x2713 }, .{ 0x0AF4, 0x2717 },
    .{ 0x0AF5, 0x266F }, .{ 0x0AF6, 0x266D }, .{ 0x0AF7, 0x2642 }, .{ 0x0AF8, 0x2640 }, .{ 0x0AF9, 0x260E },
    .{ 0x0AFA, 0x2315 }, .{ 0x0AFB, 0x2117 }, .{ 0x0AFC, 0x2038 }, .{ 0x0AFD, 0x201A }, .{ 0x0AFE, 0x201E },
    .{ 0x0BA3, 0x003C }, .{ 0x0BA6, 0x003E }, .{ 0x0BA8, 0x2228 }, .{ 0x0BA9, 0x2227 }, .{ 0x0BC0, 0x00AF },
    .{ 0x0BC2, 0x22A4 }, .{ 0x0BC3, 0x2229 }, .{ 0x0BC4, 0x230A }, .{ 0x0BC6, 0x005F }, .{ 0x0BCA, 0x2218 },
    .{ 0x0BCC, 0x2395 }, .{ 0x0BCE, 0x22A5 }, .{ 0x0BCF, 0x25CB }, .{ 0x0BD3, 0x2308 }, .{ 0x0BD6, 0x222A },
    .{ 0x0BD8, 0x2283 }, .{ 0x0BDA, 0x2282 }, .{ 0x0BDC, 0x22A3 }, .{ 0x0BFC, 0x22A2 },
    .{ 0x12A1, 0x1E02 }, .{ 0x12A2, 0x1E03 }, .{ 0x12A6, 0x1E0A }, .{ 0x12A8, 0x1E80 }, .{ 0x12AA, 0x1E82 },
    .{ 0x12AB, 0x1E0B }, .{ 0x12AC, 0x1EF2 }, .{ 0x12B0, 0x1E1E }, .{ 0x12B1, 0x1E1F }, .{ 0x12B4, 0x1E40 },
    .{ 0x12B5, 0x1E41 }, .{ 0x12B7, 0x1E56 }, .{ 0x12B8, 0x1E81 }, .{ 0x12B9, 0x1E57 }, .{ 0x12BA, 0x1E83 },
    .{ 0x12BB, 0x1E60 }, .{ 0x12BC, 0x1EF3 }, .{ 0x12BD, 0x1E84 }, .{ 0x12BE, 0x1E85 }, .{ 0x12BF, 0x1E61 },
    .{ 0x12D0, 0x0174 }, .{ 0x12D7, 0x1E6A }, .{ 0x12DE, 0x0176 }, .{ 0x12F0, 0x0175 }, .{ 0x12F7, 0x1E6B },
    .{ 0x12FE, 0x0177 },
    .{ 0x13BC, 0x0152 }, .{ 0x13BD, 0x0153 }, .{ 0x13BE, 0x0178 },
};

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _padding: u2 = 0,
};
/// Physical key identity based on USB HID usage page 0x07.
/// These values are position-based and layout-independent.
pub const Scancode = enum(u16) {
    unknown = 0x00,

    // Letters (0x04 - 0x1D)
    a = 0x04,
    b = 0x05,
    c = 0x06,
    d = 0x07,
    e = 0x08,
    f = 0x09,
    g = 0x0A,
    h = 0x0B,
    i = 0x0C,
    j = 0x0D,
    k = 0x0E,
    l = 0x0F,
    m = 0x10,
    n = 0x11,
    o = 0x12,
    p = 0x13,
    q = 0x14,
    r = 0x15,
    s = 0x16,
    t = 0x17,
    u = 0x18,
    v = 0x19,
    w = 0x1A,
    x = 0x1B,
    y = 0x1C,
    z = 0x1D,

    // Digits (0x1E - 0x27)
    @"1" = 0x1E,
    @"2" = 0x1F,
    @"3" = 0x20,
    @"4" = 0x21,
    @"5" = 0x22,
    @"6" = 0x23,
    @"7" = 0x24,
    @"8" = 0x25,
    @"9" = 0x26,
    @"0" = 0x27,

    // Control keys
    enter = 0x28,
    escape = 0x29,
    backspace = 0x2A,
    tab = 0x2B,
    space = 0x2C,

    // Punctuation / symbols
    minus = 0x2D,
    equal = 0x2E,
    left_bracket = 0x2F,
    right_bracket = 0x30,
    backslash = 0x31,
    non_us_hash = 0x32,
    semicolon = 0x33,
    apostrophe = 0x34,
    grave = 0x35,
    comma = 0x36,
    period = 0x37,
    slash = 0x38,

    caps_lock = 0x39,

    // Function keys
    f1 = 0x3A,
    f2 = 0x3B,
    f3 = 0x3C,
    f4 = 0x3D,
    f5 = 0x3E,
    f6 = 0x3F,
    f7 = 0x40,
    f8 = 0x41,
    f9 = 0x42,
    f10 = 0x43,
    f11 = 0x44,
    f12 = 0x45,

    // Navigation / editing
    print_screen = 0x46,
    scroll_lock = 0x47,
    pause = 0x48,
    insert = 0x49,
    home = 0x4A,
    page_up = 0x4B,
    delete = 0x4C,
    end = 0x4D,
    page_down = 0x4E,
    right = 0x4F,
    left = 0x50,
    down = 0x51,
    up = 0x52,

    // Numpad
    num_lock = 0x53,
    kp_divide = 0x54,
    kp_multiply = 0x55,
    kp_minus = 0x56,
    kp_plus = 0x57,
    kp_enter = 0x58,
    kp_1 = 0x59,
    kp_2 = 0x5A,
    kp_3 = 0x5B,
    kp_4 = 0x5C,
    kp_5 = 0x5D,
    kp_6 = 0x5E,
    kp_7 = 0x5F,
    kp_8 = 0x60,
    kp_9 = 0x61,
    kp_0 = 0x62,
    kp_period = 0x63,

    non_us_backslash = 0x64,
    application = 0x65,

    // Modifiers (0xE0 - 0xE7)
    left_control = 0xE0,
    left_shift = 0xE1,
    left_alt = 0xE2,
    left_super = 0xE3,
    right_control = 0xE4,
    right_shift = 0xE5,
    right_alt = 0xE6,
    right_super = 0xE7,

    _,
};

const testing = @import("std").testing;

test "keysymToCodepoint maps text keysyms and rejects non-text ones" {
    try testing.expectEqual(@as(?u21, 0xE9), keysymToCodepoint(0x00E9)); // é
    try testing.expectEqual(@as(?u21, 0x20AC), keysymToCodepoint(0x20AC)); // €
    try testing.expectEqual(@as(?u21, 'a'), keysymToCodepoint(0x0061));
    try testing.expectEqual(@as(?u21, null), keysymToCodepoint(0xFF0D)); // Return
    try testing.expectEqual(@as(?u21, null), keysymToCodepoint(0xFFBE)); // F1
    try testing.expectEqual(@as(?u21, null), keysymToCodepoint(0xFF51)); // Left
    try testing.expectEqual(@as(?u21, null), keysymToCodepoint(0xFE51)); // dead_acute
    try testing.expectEqual(@as(?u21, null), keysymToCodepoint(0xFFE1)); // Shift_L
    try testing.expectEqual(@as(?u21, 0x0141), keysymToCodepoint(0x01A3)); // Ł (Latin-2)
    try testing.expectEqual(@as(?u21, 0x0454), keysymToCodepoint(0x01000454)); // є as a Unicode keysym
    try testing.expectEqual(@as(?u21, 0x0416), keysymToCodepoint(0x06F6)); // Ж
    try testing.expectEqual(@as(?u21, 0x03A9), keysymToCodepoint(0x07D9)); // Ω
    try testing.expectEqual(@as(?u21, 0x03C2), keysymToCodepoint(0x07F3)); // ς
    try testing.expectEqual(@as(?u21, '5'), keysymToCodepoint(0xFFB5)); // KP_5
    try testing.expectEqual(@as(?u21, '/'), keysymToCodepoint(0xFFAF)); // KP_Divide
    try testing.expectEqual(@as(?u21, 0x0153), keysymToCodepoint(0x13BD)); // œ
}

test "keysym table is sorted so the binary search is valid" {
    for (keysym_table[1..], keysym_table[0 .. keysym_table.len - 1]) |entry, previous| {
        try testing.expect(previous[0] < entry[0]);
    }
}

test "keyToCodepoint follows shift and caps lock on letters only" {
    try testing.expectEqual(@as(?u21, 'a'), keyToCodepoint(.a, .{}));
    try testing.expectEqual(@as(?u21, 'A'), keyToCodepoint(.a, .{ .shift = true }));
    try testing.expectEqual(@as(?u21, 'A'), keyToCodepoint(.a, .{ .caps_lock = true }));
    try testing.expectEqual(@as(?u21, 'a'), keyToCodepoint(.a, .{ .shift = true, .caps_lock = true }));
    try testing.expectEqual(@as(?u21, '1'), keyToCodepoint(.@"1", .{ .shift = true }));
    try testing.expectEqual(@as(?u21, null), keyToCodepoint(.enter, .{}));
}

test "repeats excludes modifiers and locks" {
    try testing.expect(repeats(.a));
    try testing.expect(repeats(.backspace));
    try testing.expect(!repeats(.left_shift));
    try testing.expect(!repeats(.caps_lock));
}
