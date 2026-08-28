pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const environ = init.minimal.environ;

    var wm = try win.WindowManager.init(io, environ, allocator);
    defer wm.deinit();

    var window = try wm.createWindow(
        .{
            .title = "hello, world.",
        },
    );
    defer window.deinit();
    try window.show();

    // Let's make a little yellow triangle
    const y = [4]u8{ 255, 150, 0, 1 };
    const b = [4]u8{ 0, 0, 0, 0 };
    const yellow_block: [5 * 5][4]u8 = [_][4]u8{
        b, b, y, b, b,
        b, y, y, y, b,
        b, y, y, y, b,
        y, y, y, y, y,
        y, y, y, y, y,
    };
    const pixels = std.mem.toBytes(yellow_block);

    var image = try window.createImage(allocator, .{ .width = 5, .height = 5 });
    defer window.destroyImage(&image);
    image.setPixels(&pixels);

    try window.redraw(.{});
    var running = true;
    while (running) {
        const event = try wm.receiveIo(io) orelse break;
        switch (event) {
            .close => {
                window.close();
                running = false;
            },
            .draw => {
                try window.beginDraw();

                try image.draw(.{ .x = 100, .y = 100, .width = 50, .height = 50 });

                try window.endDraw();
            },
            .key_pressed => |kp| {
                switch (kp.key) {
                    .@"1" => {
                        window.setCursor(.default);
                        log.info("cursor: default", .{});
                    },
                    .@"2" => {
                        window.setCursor(.hand);
                        log.info("cursor: hand", .{});
                    },
                    .@"3" => {
                        window.setCursor(.crosshair);
                        log.info("cursor: crosshair", .{});
                    },
                    .@"4" => {
                        window.setCursor(.text);
                        log.info("cursor: text", .{});
                    },
                    .@"5" => {
                        window.setCursor(.not_allowed);
                        log.info("cursor: not_allowed", .{});
                    },
                    .@"6" => {
                        window.setCursor(.resize_ns);
                        log.info("cursor: resize_ns", .{});
                    },
                    .@"7" => {
                        window.setCursor(.resize_ew);
                        log.info("cursor: resize_ew", .{});
                    },
                    .@"8" => {
                        window.setCursor(.move);
                        log.info("cursor: move", .{});
                    },
                    .h => {
                        window.hideCursor();
                        log.info("cursor: hidden", .{});
                    },
                    .s => {
                        window.showCursor();
                        log.info("cursor: shown", .{});
                    },
                    .g => {
                        window.grabCursor();
                        log.info("cursor: grabbed", .{});
                    },
                    .r => {
                        window.releaseCursor();
                        log.info("cursor: released", .{});
                    },
                    else => {},
                }
                try window.redraw(.{});
            },
            .mouse_pressed, .mouse_released, .key_released => {
                try window.redraw(.{});
            },
            else => {},
        }
    }
}

const std = @import("std");
const win = @import("anywindow");

const log = std.log.scoped(.demo);

pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .x11, .level = .warn },
    },
};
