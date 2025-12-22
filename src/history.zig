const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;

pub const HistoryManager = struct {
    const Self = @This();

    allocator: Allocator,
    history: ArrayList([]const u8),
    index: usize,
    last_written: usize,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .history = .empty,
            .index = 0,
            .last_written = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.history.items[0..]) |command| {
            self.allocator.free(command);
        }

        self.history.deinit(self.allocator);
    }

    pub fn readHistory(self: *Self, file: *std.fs.File) !void {
        var buffer: [1024]u8 = undefined;
        var file_reader = file.reader(&buffer);
        const reader = &file_reader.interface;

        while (reader.takeDelimiterExclusive('\n')) |command| {
            if (command.len != 0) {
                try self.pushHistory(command);
            }
            reader.toss(1);
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
    }

    pub fn writeHistory(self: *Self, file: *std.fs.File) !void {
        var file_writer = file.writerStreaming(&.{});
        const writer = &file_writer.interface;

        for (self.history.items[0..]) |command| {
            _ = try writer.write(command);
            try writer.writeByte('\n');
        }

        self.last_written = self.history.items.len;
        try writer.flush();
    }

    pub fn appendHistory(self: *Self, file: *std.fs.File) !void {
        try file.seekFromEnd(0);

        var file_writer = file.writerStreaming(&.{});
        const writer = &file_writer.interface;

        for (self.history.items[self.last_written..]) |command| {
            _ = try writer.write(command);
            try writer.writeByte('\n');
        }

        self.last_written = self.history.items.len;
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
