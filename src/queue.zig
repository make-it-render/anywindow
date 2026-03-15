/// Thread-safe fixed-size queue.
/// Uses Mutex + Condition for blocking receive.
pub fn ThreadSafeQueue(Type: type) type {
    return struct {
        data: [256]?Type = [_]?Type{null} ** 256,
        head: u8 = 0,
        tail: u8 = 0,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        closed: bool = false,

        const Self = @This();

        pub fn push(self: *Self, item: Type) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.tail +% 1 == self.head) {
                log.warn("Event queue full, dropping oldest event", .{});
            }
            self.data[self.tail] = item;
            self.tail = self.tail +% 1;

            self.cond.signal();
        }

        /// Non-blocking pull. Returns null if empty.
        pub fn pull(self: *Self) ?Type {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.pullUnlocked();
        }

        /// Blocking receive. Waits until an item is available or the queue is closed.
        /// Returns null when closed and empty (shutdown signal).
        pub fn receive(self: *Self) ?Type {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (true) {
                if (self.pullUnlocked()) |item| {
                    return item;
                }
                if (self.closed) return null;
                self.cond.wait(&self.mutex);
            }
        }

        /// Signal shutdown: wake all waiters so they can exit.
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.closed = true;
            self.cond.broadcast();
        }

        fn pullUnlocked(self: *Self) ?Type {
            if (self.data[self.head]) |item| {
                self.data[self.head] = null;
                self.head = self.head +% 1;
                return item;
            }
            return null;
        }
    };
}

const std = @import("std");
const log = std.log.scoped(.anywindow);
