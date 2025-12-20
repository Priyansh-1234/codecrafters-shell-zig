const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;

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

    pub fn readHistory(self: *Self, reader: *Reader) !void {
        while (reader.takeDelimiterExclusive('\n')) |line| {
            try self.pushHistory(line);
            reader.toss(1);
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
    }

    pub fn writeHistory(self: *Self, writer: *Writer) !void {
        for (self.history.items[0..]) |command| {
            _ = try writer.write(command);
            try writer.writeByte('\n');
        }
    }

    pub fn pushHistory(self: *Self, command: []const u8) Allocator.Error!void {
        const ownedCommand = try self.allocator.dupe(u8, command);
        try self.history.append(self.allocator, ownedCommand);
        self.index = self.history.items.len - 1;
    }

    pub fn getCommand(self: *Self, index: usize) []const u8 {
        if (index == 0 or index > self.history.items.len) return "";
        const his_index = self.history.items.len - index;
        return self.history.items[his_index];
    }

    pub fn printUsage(_: *const Self, stream: *Writer) Writer.Error!void {
        try stream.print("history: usage: history [n]\n", .{});
    }

    pub fn displayHistory(self: *const Self, limit_set: bool, limit: usize, outstream: *Writer) Writer.Error!void {
        var amount: usize = self.history.items.len;
        if (limit_set) {
            amount = @min(amount, limit);
        }
        const start = self.history.items.len - amount;
        for (self.history.items[start..], (start + 1)..) |command, i| {
            try outstream.print("\t{d} {s}\n", .{ i, command });
        }

        try outstream.flush();
    }
};
