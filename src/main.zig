const std = @import("std");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

pub fn main() !void {
    while (true) {
        try stdout.print("$ ", .{});
        var command = try stdin.takeDelimiterInclusive('\n');
        command = if (command[command.len - 1] == '\n') command[0 .. command.len - 1] else command;
        try stdout.print("{s}: command not found\n", .{command});
    }
}
