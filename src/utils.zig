const std = @import("std");
const Trie = @import("trie.zig").Trie;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("readline/readline.h");
    @cInclude("readline/history.h");
});

pub fn isExecutable(allocator: Allocator, filename: []const u8) !?[]const u8 {
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

    const stat = std.fs.cwd().statFile(filename) catch return null;
    if (stat.mode & (std.posix.S.IXUSR | std.posix.S.IXGRP | std.posix.S.IXOTH) != 0) {
        const file_path = try std.fs.cwd().realpathAlloc(allocator, filename);
        return file_path;
    }

    return null;
}

pub fn getStreams(allocator: std.mem.Allocator, args: []const []const u8) !struct { outfile_ptr: ?*std.fs.File, errfile_ptr: ?*std.fs.File, index: usize } {
    var outfile_name: []const u8 = undefined;
    var outfile_present: bool = false;
    var outfile_append: bool = false;

    var errfile_name: []const u8 = undefined;
    var errfile_present: bool = false;
    var errfile_append: bool = false;

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
        } else if (std.mem.eql(u8, "2>", arg)) {
            errfile_name = args[i + 1];
            errfile_present = true;
            idx2 = i;
            i += 1;
        } else if (std.mem.eql(u8, arg, ">>") or std.mem.eql(u8, arg, "1>>")) {
            outfile_name = args[i + 1];
            outfile_present = true;
            outfile_append = true;
            idx1 = i;
            i += 1;
        } else if (std.mem.eql(u8, arg, "2>>")) {
            errfile_name = args[i + 1];
            errfile_present = true;
            errfile_append = true;
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
            outfile.* = try std.fs.createFileAbsolute(outfile_name, .{ .truncate = !outfile_append });
        } else {
            outfile.* = try std.fs.cwd().createFile(outfile_name, .{ .truncate = !outfile_append });
        }
        if (outfile_append) {
            try outfile.seekFromEnd(0);
        }
    }

    if (errfile_ptr) |errfile| {
        if (std.fs.path.isAbsolute(errfile_name)) {
            errfile.* = try std.fs.createFileAbsolute(errfile_name, .{ .truncate = !errfile_append });
        } else {
            errfile.* = try std.fs.cwd().createFile(errfile_name, .{ .truncate = !errfile_append });
        }
        if (errfile_append) {
            try errfile.seekFromEnd(0);
        }
    }

    return .{
        .outfile_ptr = outfile_ptr,
        .errfile_ptr = errfile_ptr,
        .index = i,
    };
}

pub fn runChildProcess(allocator: Allocator, argv: []const []const u8, outstream: *Writer, errstream: *Writer) !void {
    var process = std.process.Child.init(argv, allocator);

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
}

threadlocal var completion_context: ?*const readUtils = null;

pub const readUtils = struct {
    trie: *Trie,
    allocator: Allocator,

    pub fn init(allocator: Allocator, trie: *Trie) !readUtils {
        return .{
            .trie = trie,
            .allocator = allocator,
        };
    }

    fn completionGenerator(text: [*c]const u8, state: c_int) callconv(.c) [*c]u8 {
        if (completion_context) |ctx| {
            if (state == 0) {
                const prefix = std.mem.span(text);
                const result = ctx.autoComplete(prefix);
                defer ctx.allocator.free(result.result);

                if (result.success) {
                    const completion = std.c.malloc(result.result.len + 1) orelse return null;
                    const completion_slice: [*]u8 = @ptrCast(completion);

                    @memcpy(completion_slice[0..result.result.len], result.result[0..]);
                    completion_slice[result.result.len] = 0;

                    return @ptrCast(completion);
                }
            }
        }

        return null;
    }

    fn completionFunction(text: [*c]const u8, start: c_int, end: c_int) callconv(.c) [*c][*c]u8 {
        _ = start;
        _ = end;
        if (text == null or text[0] == 0) return null;

        return c.rl_completion_matches(text, &completionGenerator);
    }

    fn autoComplete(self: *const readUtils, prefix: []const u8) struct { success: bool, result: []const u8 } {
        const value = self.trie.complete(prefix) catch null orelse return .{
            .success = false,
            .result = "",
        };
        return .{
            .success = true,
            .result = value,
        };
    }

    pub fn readline(self: *const readUtils, allocator: Allocator, reader: *Reader) ![]const u8 {
        _ = reader;

        completion_context = self;
        c.rl_attempted_completion_function = &completionFunction;

        const input = c.readline("$ ");
        defer std.c.free(input);

        if (input == null) return error.CloseTerminal;
        if (input[0] != 0) _ = c.add_history(input);

        const command_input = try allocator.dupe(u8, std.mem.span(input));
        return command_input;
    }
};
