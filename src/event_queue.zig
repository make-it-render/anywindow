//! A few events waiting to be returned, for the moments one input message maps to more than one event. Events are copied in and out by value; nothing here allocates. Only the receive task touches the queue.

events: [capacity]common.Event = undefined,
head: u8 = 0,
len: u8 = 0,

pub const capacity = 8;

/// Append `event`. A full queue drops it, which only happens when a caller stops draining between messages.
pub fn push(self: *@This(), event: common.Event) void {
    if (self.len == capacity) {
        log.debug("Dropping a queued {s} event", .{@tagName(event)});
        return;
    }
    self.events[(self.head + self.len) % capacity] = event;
    self.len += 1;
}

/// One `text` event per code point, in order.
pub fn pushText(self: *@This(), codepoints: []const u21, window_id: common.WindowID) void {
    for (codepoints) |codepoint| self.push(.{ .text = .{ .codepoint = codepoint, .window_id = window_id } });
}

pub fn pop(self: *@This()) ?common.Event {
    if (self.len == 0) return null;
    const event = self.events[self.head];
    self.head = (self.head + 1) % capacity;
    self.len -= 1;
    return event;
}

const std = @import("std");
const common = @import("common.zig");
const log = std.log.scoped(.anywindow);

test "events come back in push order and text expands per code point" {
    var queue: @This() = .{};
    try std.testing.expectEqual(@as(?common.Event, null), queue.pop());
    queue.push(.{ .focus_in = 7 });
    queue.pushText(&.{ 'a', 0xEA }, 7);
    try std.testing.expectEqual(common.Event{ .focus_in = 7 }, queue.pop().?);
    try std.testing.expectEqual(@as(u21, 'a'), queue.pop().?.text.codepoint);
    try std.testing.expectEqual(@as(u21, 0xEA), queue.pop().?.text.codepoint);
    try std.testing.expectEqual(@as(?common.Event, null), queue.pop());
}

test "a full queue drops the newest event" {
    var queue: @This() = .{};
    for (0..capacity + 2) |index| queue.push(.{ .focus_in = index });
    try std.testing.expectEqual(@as(u8, capacity), queue.len);
    try std.testing.expectEqual(@as(usize, 0), queue.pop().?.focus_in);
}
