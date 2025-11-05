const std = @import("std");
const parseArgs = @import("parser.zig").parseArgs;

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

const commandFn = *const fn (args: []const []const u8) anyerror!void;
var global_command_functions: *std.hash_map.HashMap([]const u8, *const fn ([]const []const u8) anyerror!void, std.hash_map.StringContext, 80) = undefined;

fn echoFn(args: []const []const u8) !void {
    const s = try std.mem.join(global_allocator, " ", args);
    defer global_allocator.free(s);

    try stdout.print("{s}\n", .{s});
}

fn exitFn(_: []const []const u8) !void {
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

fn typeFn(args: []const []const u8) !void {
    for (args) |arg| {
        if (global_command_functions.get(arg)) |_| {
            try stdout.print("{s} is a shell builtin\n", .{arg});
            return;
        }

        if (try isExecutable(global_allocator, arg)) |file_path| {
            defer global_allocator.free(file_path);
            try stdout.print("{s} is {s}\n", .{ arg, file_path });
            return;
        }

        try stdout.print("{s}: not found\n", .{arg});
    }
}

fn pwdFn(_: []const []const u8) !void {
    var buffer: [1024]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &buffer);
    try stdout.print("{s}\n", .{cwd});
}

fn isPathAbsolute(path: []const u8) !bool {
    return std.fs.path.isAbsolute(path);
}

fn cdFn(args: []const []const u8) !void {
    if (args.len > 1) {
        const s = try std.mem.join(global_allocator, " ", args);
        defer global_allocator.free(s);

        try stdout.print("cd: {s}: No such file or directory\n", .{s});
        return;
    }

    const path = args[0];

    if (std.mem.eql(u8, "~", path)) {
        const home = try std.process.getEnvVarOwned(global_allocator, "HOME");
        defer global_allocator.free(home);

        var dir = try std.fs.openDirAbsolute(home, .{});
        try dir.setAsCwd();

        return;
    }

    const flag = try isPathAbsolute(path);

    if (flag) {
        var dir = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try stdout.print("cd: {s}: No such file or directory\n", .{path});
                return;
            },
            else => return err,
        };

        try dir.setAsCwd();
    } else {
        var dir = std.fs.cwd().openDir(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try stdout.print("cd: {s}: No such file or directory\n", .{path});
                return;
            },
            else => return err,
        };

        try dir.setAsCwd();
    }
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

        var args = parseArgs(global_allocator, command_input) catch |err| switch (err) {
            error.NotValidLine => {
                try stdout.print("Not Valid Line\n", .{});
                continue;
            },
            else => return err,
        };
        defer {
            for (args.items[0..]) |arg| {
                global_allocator.free(arg);
            }
            args.deinit(global_allocator);
        }

        const command = args.items[0];
        const rest = args.items[1..];

        if (std.mem.eql(u8, "exit", command)) break;

        if (command_functions.get(command)) |func| {
            try func(rest);
        } else {
            const file_path = try isExecutable(global_allocator, command);
            if (file_path) |file_exe| {
                defer global_allocator.free(file_exe);

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
