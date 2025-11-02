const std = @import("std");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

pub fn main() !void {
    while (true) {
        try stdout.print("$ ", .{});
        const command = try stdin.takeDelimiterExclusive('\n');
        if (command.len == 0) continue;
        try stdout.print("{s}: command not found\n", .{command});
    }
}
