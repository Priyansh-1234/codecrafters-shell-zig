const std = @import("std");
const parseArgs = @import("parser.zig").parseArgs;

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var outstream: *std.Io.Writer = stdout;
var errstream: *std.Io.Writer = stdout;

var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

const commandFn = *const fn (args: []const []const u8) anyerror!void;
var global_command_functions: *std.hash_map.HashMap([]const u8, commandFn, std.hash_map.StringContext, 80) = undefined;

fn echoFn(args: []const []const u8) !void {
    const s = try std.mem.join(global_allocator, " ", args);
    defer global_allocator.free(s);

    try outstream.print("{s}\n", .{s});
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
            try outstream.print("{s} is a shell builtin\n", .{arg});
            return;
        }

        if (try isExecutable(global_allocator, arg)) |file_path| {
            defer global_allocator.free(file_path);
            try outstream.print("{s} is {s}\n", .{ arg, file_path });
            return;
        }

        try outstream.print("{s}: not found\n", .{arg});
    }
}

fn pwdFn(_: []const []const u8) !void {
    var buffer: [1024]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &buffer);
    try outstream.print("{s}\n", .{cwd});
}

fn isPathAbsolute(path: []const u8) !bool {
    return std.fs.path.isAbsolute(path);
}

fn cdFn(args: []const []const u8) !void {
    if (args.len > 1) {
        const s = try std.mem.join(global_allocator, " ", args);
        defer global_allocator.free(s);

        try outstream.print("cd: {s}: No such file or directory\n", .{s});
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
                try outstream.print("cd: {s}: No such file or directory\n", .{path});
                return;
            },
            else => return err,
        };

        try dir.setAsCwd();
    } else {
        var dir = std.fs.cwd().openDir(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try outstream.print("cd: {s}: No such file or directory\n", .{path});
                return;
            },
            else => return err,
        };

        try dir.setAsCwd();
    }
}

fn get_streams(allocator: std.mem.Allocator, args: []const []const u8) !struct { outfile_ptr: ?*std.fs.File, errfile_ptr: ?*std.fs.File, index: usize } {
    var outfile_name: []const u8 = undefined;
    var outfile_present: bool = false;
    var errfile_name: []const u8 = undefined;
    var errfile_present: bool = false;

    var idx1: usize = args.len;
    var idx2: usize = args.len;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, ">") or std.mem.eql(u8, arg, "1>")) {
            outfile_name = args[i + 1];
            outfile_present = true;
            idx1 = i;
            i += 1;
        }
        if (std.mem.eql(u8, "2>", arg)) {
            errfile_name = args[i + 1];
            errfile_present = true;
            idx2 = i;
            i += 1;
        }
    }

    i = @min(@min(i, idx1), idx2);

    var outfile_ptr: ?*std.fs.File = null;
    var errfile_ptr: ?*std.fs.File = null;

    if (outfile_present) {
        outfile_ptr = try allocator.create(std.fs.File);
    }
    if (errfile_present) {
        errfile_ptr = try allocator.create(std.fs.File);
    }

    if (outfile_ptr) |outfile| {
        if (std.fs.path.isAbsolute(outfile_name)) {
            outfile.* = try std.fs.createFileAbsolute(outfile_name, .{});
        } else {
            outfile.* = try std.fs.cwd().createFile(outfile_name, .{});
        }
    }

    if (errfile_ptr) |errfile| {
        if (std.fs.path.isAbsolute(errfile_name)) {
            errfile.* = try std.fs.createFileAbsolute(errfile_name, .{});
        } else {
            errfile.* = try std.fs.cwd().createFile(errfile_name, .{});
        }
    }

    return .{
        .outfile_ptr = outfile_ptr,
        .errfile_ptr = errfile_ptr,
        .index = i,
    };
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
        try outstream.print("$ ", .{});

        var command_input = try stdin.takeDelimiterInclusive('\n');
        if (command_input[command_input.len - 1] == '\n') {
            command_input = command_input[0 .. command_input.len - 1];
        }

        var args = parseArgs(global_allocator, command_input) catch |err| switch (err) {
            error.NotValidLine => {
                try errstream.print("Not Valid Line\n", .{});
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

        const result = try get_streams(global_allocator, args.items[0..]);
        defer {
            outstream = stdout;
            errstream = stdout;
            if (result.outfile_ptr) |file| {
                file.close();
                global_allocator.destroy(file);
            }
            if (result.errfile_ptr) |file| {
                file.close();
                global_allocator.destroy(file);
            }
        }

        if (result.outfile_ptr) |file| {
            var file_writer = file.writerStreaming(&.{});
            outstream = &file_writer.interface;
        }
        if (result.errfile_ptr) |file| {
            var file_writer = file.writerStreaming(&.{});
            errstream = &file_writer.interface;
        }

        const command = args.items[0];
        const rest = args.items[1..result.index];

        if (std.mem.eql(u8, "exit", command)) break;

        if (command_functions.get(command)) |func| {
            try func(rest);
        } else {
            const file_path = try isExecutable(global_allocator, command);
            if (file_path) |file_exe| {
                defer global_allocator.free(file_exe);

                const argv = args.items[0..result.index];

                var process = std.process.Child.init(argv, global_allocator);

                process.stdin_behavior = .Ignore;
                process.stdout_behavior = .Pipe;
                process.stderr_behavior = .Pipe;

                try process.spawn();

                var stdout_buffer: [1024]u8 = undefined;
                var process_stdout_reader = process.stdout.?.readerStreaming(&stdout_buffer);
                const process_stdout = &process_stdout_reader.interface;

                var stderr_buffer: [1024]u8 = undefined;
                var process_stderr_reader = process.stderr.?.readerStreaming(&stderr_buffer);
                const process_stderr = &process_stderr_reader.interface;

                while (process_stdout.takeDelimiterInclusive('\n')) |line| {
                    try outstream.print("{s}", .{line});
                } else |err| {
                    if (err != error.EndOfStream) return err;
                }

                while (process_stderr.takeDelimiterInclusive('\n')) |line| {
                    try errstream.print("{s}", .{line});
                } else |err| {
                    if (err != error.EndOfStream) return err;
                }

                _ = try process.wait();
            } else {
                try outstream.print("{s}: command not found\n", .{command});
            }
        }
    }
}
