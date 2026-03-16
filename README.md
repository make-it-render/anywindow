# mir-anywindow

Cross-platform window management abstraction for Zig.

Provides a unified API over platform-specific backends using comptime dispatch.

**Supported platforms:** Linux (X11), Windows (Win32)

## Features

- Window creation, resizing, positioning, fullscreen, and icon setting
- Keyboard and mouse event handling with scancodes and modifiers
- Image drawing with automatic DPI scaling (nearest-neighbor)
- Thread-safe event queue

## Usage

### Install

```sh
zig fetch --save git+https://github.com/make-it-render/mir-anywindow
```

### build.zig

```zig
const anywindow_dep = b.dependency("anywindow", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("anywindow", anywindow_dep.module("anywindow"));
```

### Example

```zig
const win = @import("anywindow");

var wm = try win.WindowManager.init(allocator);
defer wm.deinit();

var window = try wm.createWindow(.{ .title = "Hello" });
defer window.deinit();
try window.show();

while (window.status == .open) {
    const event = try wm.receive() orelse break;
    switch (event) {
        .close => window.close(),
        .draw => {
            try window.beginDraw();
            // draw here
            try window.endDraw();
        },
        .key_pressed => |e| { ... },
        else => {},
    }
}
```

For a complete working example with image drawing, see [src/demo.zig](src/demo.zig).

## API

### Window options

```zig
wm.createWindow(.{
    .title = "My Window",       // window title (default: "")
    .width = 800,               // optional width
    .height = 600,              // optional height
    .x = 100,                   // optional x position
    .y = 100,                   // optional y position
    .background = .{ 30, 30, 30 }, // RGB background color (default: black)
});
```

Windows also support `toggleFullscreen()` and `setIcon()`.

### Events

Events are delivered via `wm.receive()`, which blocks until an event is available.

| Event | Payload | Description |
|-------|---------|-------------|
| `.close` | `WindowID` | Window close requested |
| `.draw` | `window_id`, `area` | Window needs redrawing |
| `.resize` | `width`, `height`, `window_id` | Window was resized |
| `.key_pressed` | `scancode`, `key`, `modifiers`, `window_id` | Key pressed |
| `.key_released` | `scancode`, `key`, `modifiers`, `window_id` | Key released |
| `.mouse_pressed` | `x`, `y`, `button`, `window_id` | Mouse button pressed |
| `.mouse_released` | `x`, `y`, `button`, `window_id` | Mouse button released |
| `.mouse_moved` | `x`, `y`, `window_id` | Mouse moved |

Keyboard events provide both a `Scancode` (physical key position, USB HID based) and a `Key` (logical key identity).

### Image

`Image` manages RGBA pixel data and draws it scaled to any target rectangle. DPI scaling is applied automatically based on the window's display scaling factor.

```zig
// Create a 5x5 image
var image = try win.Image.init(allocator, &window, .{ .width = 5, .height = 5 });
defer image.deinit();

// Set RGBA pixel data (4 bytes per pixel)
image.setPixels(&pixels);

// Draw scaled to a 50x50 area at position (100, 100)
try image.draw(.{ .x = 100, .y = 100, .width = 50, .height = 50 });
```

## License

MIT License

Copyright (c) Diogo Souza da Silva
