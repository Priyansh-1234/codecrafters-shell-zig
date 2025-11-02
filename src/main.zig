const std = @import("std");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

const commandFn = *const fn (args: []const u8) anyerror!void;

fn echoFn(args: []const u8) !void {
    try stdout.print("{s}\n", .{args});
}

pub fn main() !void {
    var dba = std.heap.DebugAllocator(.{}){};
    defer _ = dba.deinit();
    const allocator = dba.allocator();

    var command_functions = std.StringHashMap(commandFn).init(allocator);
    defer command_functions.deinit();

    try command_functions.put("echo", &echoFn);

    while (true) {
        try stdout.print("$ ", .{});

        var command_input = try stdin.takeDelimiterInclusive('\n');
        if (command_input[command_input.len - 1] == '\n') {
            command_input = command_input[0 .. command_input.len - 1];
        }

        var arguments = std.mem.splitScalar(u8, command_input, ' ');
        const command = arguments.first();
        const args = arguments.rest();

        if (std.mem.eql(u8, "exit", command)) break;

        if (command_functions.get(command)) |func| {
            try func(args);
        } else {
            try stdout.print("{s}: command not found\n", .{command});
        }
    }
}
