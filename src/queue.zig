/// Thread-safe fixed-size queue.
/// Uses Mutex + Condition for blocking receive.
pub fn ThreadSafeQueue(Type: type) type {
    return struct {
        io: std.Io,
        data: [256]?Type = [_]?Type{null} ** 256,
        head: u8 = 0,
        tail: u8 = 0,
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        closed: bool = false,

        const Self = @This();

        pub fn init(io: std.Io) Self {
            return .{ .io = io };
        }

        pub fn push(self: *Self, item: Type) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.tail +% 1 == self.head) {
                log.warn("Event queue full, dropping oldest event", .{});
            }
            self.data[self.tail] = item;
            self.tail = self.tail +% 1;

            self.cond.signal(self.io);
        }

        /// Non-blocking pull. Returns null if empty.
        pub fn pull(self: *Self) ?Type {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            return self.pullUnlocked();
        }

        /// Blocking receive. Waits until an item is available or the queue is closed.
        /// Returns null when closed and empty (shutdown signal).
        pub fn receive(self: *Self) ?Type {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            while (true) {
                if (self.pullUnlocked()) |item| {
                    return item;
                }
                if (self.closed) return null;
                self.cond.waitUncancelable(self.io, &self.mutex);
            }
        }

        /// io-cancelable blocking receive. Like `receive`, but the wait is a
        /// cancelation point: returns `error.Canceled` if the calling task is
        /// canceled, and null when closed and empty. Used by the io-native
        /// source path (`WindowManager.receiveIo`).
        pub fn receiveCancelable(self: *Self, io: std.Io) std.Io.Cancelable!?Type {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            while (true) {
                if (self.pullUnlocked()) |item| {
                    return item;
                }
                if (self.closed) return null;
                // `cond.wait` re-acquires the mutex before returning, even on
                // `error.Canceled`, so the `defer unlock` above stays correct.
                try self.cond.wait(io, &self.mutex);
            }
        }

        /// Signal shutdown: wake all waiters so they can exit.
        pub fn close(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.closed = true;
            self.cond.broadcast(self.io);
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
