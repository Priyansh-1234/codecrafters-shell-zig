const std = @import("std");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

pub fn main() !void {
    try stdout.print("$ ", .{});

    var reader_buffer: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().readerStreaming(&reader_buffer);
    const stdin = &stdin_reader.interface;

    var buffer: [1024]u8 = undefined;
    var buffer_writer: std.Io.Writer = .fixed(&buffer);
    const n = try stdin.streamDelimiter(&buffer_writer, '\n');

    try stdout.print("{s}: command not found\n", .{buffer[0..n]});
}
