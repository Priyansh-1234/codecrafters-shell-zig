const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;

pub const historyManager = struct {
    const Self = @This();

    allocator: Allocator,
    history: ArrayList([]const u8),
    index: usize,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .history = .empty,
            .index = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.history.items[0..]) |command| {
            self.allocator.free(command);
        }

        self.history.deinit(self.allocator);
    }

    pub fn pushHistory(self: *Self, command: []const u8) Allocator.Error!void {
        const ownedCommand = try self.allocator.dupe(u8, command);
        try self.history.append(self.allocator, ownedCommand);
        self.index = self.history.items.len - 1;
    }

    pub fn getCommand(self: *Self, index: isize) []const u8 {
        if (index >= self.history.items.len or -index > self.history.items.len) return "";
        const his_index: usize = if (index >= 0) @intCast(index) else self.history.items.len - @as(usize, @intCast(-index));
        return self.history.items[his_index];
    }

    pub fn printUsage(_: *const Self, stream: *Writer) Writer.Error!void {
        try stream.print("history: usage: history [n]\n", .{});
    }

    pub fn displayHistory(self: *const Self, number: []const u8, outstream: *Writer, errstream: *Writer) Writer.Error!void {
        var num: usize = self.history.items.len;
        if (number.len != 0) {
            num = std.fmt.parseInt(usize, number, 10) catch {
                try errstream.print("history: invalid usage\n", .{});
                try self.printUsage(errstream);
                try errstream.flush();
                return;
            };
        }

        const amount = @min(num, self.history.items.len);
        const start = self.history.items.len - amount;
        for (self.history.items[start..], (start + 1)..) |command, i| {
            try outstream.print("\t{d} {s}\n", .{ i, command });
        }

        try outstream.flush();
    }
};
