const std = @import("std");

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

fn isExecutable(allocator: std.mem.Allocator, filename: []const u8) !?[]const u8 {
    const path = try std.process.getEnvVarOwned(allocator, "PATH");
    defer allocator.free(path);
    var iter = std.mem.splitScalar(u8, path, std.fs.path.delimiter);

    while (iter.next()) |dir| {
        var directory = if (std.fs.path.isAbsolute(dir)) std.fs.openDirAbsolute(dir, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        } else continue;
        defer directory.close();

        const stat = directory.statFile(filename) catch continue;

        if (stat.mode & (std.posix.S.IXUSR | std.posix.S.IXGRP | std.posix.S.IXOTH) != 0) {
            const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir, filename });
            return file_path;
        }
    }

    return null;
}

fn typeFn(args: []const u8) !void {
    if (global_command_functions.get(args)) |_| {
        try stdout.print("{s} is a shell builtin\n", .{args});
        return;
    }

    if (try isExecutable(global_allocator, args)) |file_path| {
        defer global_allocator.free(file_path);
        try stdout.print("{s} is {s}\n", .{ args, file_path });
        return;
    }

    try stdout.print("{s}: not found\n", .{args});
}

fn pwdFn(_: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &buffer);
    try stdout.print("{s}\n", .{cwd});
}

fn isPathAbsolute(path: []const u8) !bool {
    return std.fs.path.isAbsolute(path);
}

fn cdFn(args: []const u8) !void {
    if (std.mem.eql(u8, "~", args)) {
        const home = try std.process.getEnvVarOwned(global_allocator, "HOME");
        defer global_allocator.free(home);

        var dir = try std.fs.openDirAbsolute(home, .{});
        try dir.setAsCwd();

        return;
    }
    const flag = try isPathAbsolute(args);
    if (flag) {
        var dir = std.fs.openDirAbsolute(args, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try stdout.print("cd: {s}: No such file or directory\n", .{args});
                return;
            },
            else => return err,
        };

        try dir.setAsCwd();
    } else {
        var dir = std.fs.cwd().openDir(args, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try stdout.print("cd: {s}: No such file or directory\n", .{args});
                return;
            },
            else => return err,
        };

        try dir.setAsCwd();
    }
}

fn parseArgs(allocator: std.mem.Allocator, args_iter: *std.mem.TokenIterator(u8, std.mem.DelimiterType.scalar)) !std.ArrayList([]const u8) {
    var argv: std.ArrayList([]const u8) = .empty;
    args_iter.reset();
    while (args_iter.next()) |arg| {
        try argv.append(allocator, arg);
    }

    return argv;
}

var dba = std.heap.DebugAllocator(.{}){};
const global_allocator = dba.allocator();

pub fn main() !void {
    defer std.debug.assert(dba.deinit() == .ok);

    var command_functions = std.StringHashMap(commandFn).init(global_allocator);
    defer command_functions.deinit();

    global_command_functions = &command_functions;

    try command_functions.put("echo", &echoFn);
    try command_functions.put("exit", &exitFn);
    try command_functions.put("type", &typeFn);
    try command_functions.put("pwd", &pwdFn);
    try command_functions.put("cd", &cdFn);

    while (true) {
        try stdout.print("$ ", .{});

        var command_input = try stdin.takeDelimiterInclusive('\n');
        if (command_input[command_input.len - 1] == '\n') {
            command_input = command_input[0 .. command_input.len - 1];
        }

        var arguments = std.mem.tokenizeScalar(u8, command_input, ' ');
        const command = arguments.next() orelse unreachable;
        const rest = arguments.rest();

        arguments.reset();

        if (std.mem.eql(u8, "exit", command)) break;

        if (command_functions.get(command)) |func| {
            try func(rest);
        } else {
            const file_path = try isExecutable(global_allocator, command);
            if (file_path) |file_exe| {
                defer global_allocator.free(file_exe);

                var args = try parseArgs(global_allocator, &arguments);
                defer args.deinit(global_allocator);

                const argv = args.items[0..];

                var process = std.process.Child.init(argv, global_allocator);

                process.stdin_behavior = .Ignore;
                process.stdout_behavior = .Pipe;
                process.stderr_behavior = .Pipe;

                try process.spawn();

                var buffer: [1024]u8 = undefined;
                var process_reader = process.stdout.?.readerStreaming(&buffer);
                const process_stdout = &process_reader.interface;

                while (process_stdout.takeDelimiterInclusive('\n')) |line| {
                    try stdout.print("{s}", .{line});
                } else |err| {
                    if (err != error.EndOfStream) return err;
                }

                _ = try process.wait();
            } else {
                try stdout.print("{s}: command not found\n", .{command});
            }
        }
    }
}
