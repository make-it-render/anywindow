pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    var wm = try win.WindowManager.init(allocator);
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

    var image = try win.Image.init(allocator, &window, .{ .width = 5, .height = 5 });
    defer image.deinit();
    image.setPixels(&pixels);

    var timer = try std.time.Timer.start();

    try window.redraw(.{});
    while (window.status == .open) {
        const event = try wm.receive() orelse break;
        switch (event) {
            .close => {
                window.close();
            },
            .draw => {
                timer.reset();

                try window.beginDraw();

                try image.draw(.{ .x = 100, .y = 100, .width = 50, .height = 50 });

                try window.endDraw();

                log.info("Time to draw: {d}ms", .{timer.lap() / std.time.ns_per_ms});
            },
            .mouse_pressed, .mouse_released, .key_pressed, .key_released => {
                log.debug("{any}", .{event});
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
