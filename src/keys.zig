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
