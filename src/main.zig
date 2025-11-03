const std = @import("std");
const builtin = @import("builtin");

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

const commandFn = *const fn (args: []const u8) anyerror!void;
var global_command_functions: *std.hash_map.HashMap([]const u8, *const fn ([]const u8) anyerror!void, std.hash_map.StringContext, 80) = undefined;

fn echoFn(args: []const u8) !void {
    try stdout.print("{s}\n", .{args});
}

fn exitFn(_: []const u8) !void {
    return error.TemplateFunction;
}

fn typeFn(args: []const u8) !void {
    if (global_command_functions.get(args)) |_| {
        try stdout.print("{s} is a shell builtin\n", .{args});
    } else {
        const path = try std.process.getEnvVarOwned(allocator, "PATH");
        var iter = std.mem.splitScalar(u8, path, std.fs.path.delimiter);

        while (iter.next()) |dir| {
            var directory = if (std.fs.path.isAbsolute(dir)) std.fs.openDirAbsolute(dir, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            } else continue;
            defer directory.close();

            const stat = directory.statFile(args) catch continue;
            if (stat.mode & (std.posix.S.IXUSR | std.posix.S.IXGRP | std.posix.S.IXOTH) != 0) {
                const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir, args });
                try stdout.print("{s} is {s}\n", .{ args, file_path });
                return;
            }
        } else {
            try stdout.print("{s}: not found\n", .{args});
        }
    }
}

var dba = std.heap.DebugAllocator(.{}){};
const allocator = dba.allocator();

pub fn main() !void {
    defer _ = dba.deinit();

    var command_functions = std.StringHashMap(commandFn).init(allocator);
    defer command_functions.deinit();

    global_command_functions = &command_functions;

    try command_functions.put("echo", &echoFn);
    try command_functions.put("exit", &exitFn);
    try command_functions.put("type", &typeFn);

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
