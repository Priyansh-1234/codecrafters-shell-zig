const std = @import("std");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

pub fn main() !void {
    while (true) {
        try stdout.print("$ ", .{});
        var arguments = try stdin.takeDelimiterInclusive('\n');
        arguments = if (arguments[arguments.len - 1] == '\n') arguments[0 .. arguments.len - 1] else arguments;
        var commands = std.mem.splitScalar(u8, arguments, ' ');
        const command = commands.next();
        if (command) |cmd| {
            if (std.mem.eql(u8, "exit", cmd)) {
                break;
            }
            try stdout.print("{s}: command not found\n", .{cmd});
        }
    }
}
