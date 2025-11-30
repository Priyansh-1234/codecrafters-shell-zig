// --- File Imports --- //
const std = @import("std");
const utils = @import("utils.zig");

const shell_builtins = @import("shell_builtin.zig").shell_builtin;
const Trie = @import("trie.zig").Trie;
const ReadLine = @import("readline.zig").ReadLine;
const Terminal = @import("terminal.zig").Terminal;
const Allocator = std.mem.Allocator;

const parseArgs = @import("parser.zig").parseArgs;
const assert = std.debug.assert;

// --- Setting up the standard out and standard in and standard err --- //
var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

var stderr_writer = std.fs.File.stderr().writerStreaming(&.{});
const stderr = &stderr_writer.interface;

var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

// --- The output streams which can change upon redirection --- //
var outstream: *std.Io.Writer = stdout;
var errstream: *std.Io.Writer = stderr;

fn buildTrie(builtins: shell_builtins, trie: *Trie, path: []const u8) !void {
    for (builtins.shell_functions[0..]) |shell_function| {
        try trie.insert(shell_function);
    }

    var iter = std.mem.splitScalar(u8, path, std.fs.path.delimiter);

    while (iter.next()) |dir| {
        var directory = if (std.fs.path.isAbsolute(dir)) std.fs.openDirAbsolute(dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        } else continue;
        defer directory.close();

        var iterator = directory.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            const stat = directory.statFile(entry.name) catch continue;
            if (stat.mode & (std.posix.S.IXUSR | std.posix.S.IXGRP | std.posix.S.IXOTH) != 0) {
                try trie.insert(entry.name);
            }
        }
    }
}

fn auto_complete_function(trie: *const Trie, word: []const u8, allocator: Allocator) !utils.autofillSuggestion {
    const result = try trie.complete(word, allocator);

    if (result == null) {
        return error.InvalidComplete;
    }

    return result orelse unreachable;
}
pub fn main() !void {
    var dba = std.heap.DebugAllocator(.{}){};
    defer assert(dba.deinit() == .ok);
    const allocator = dba.allocator();

    const builtins = shell_builtins.init(allocator);
    const path = try std.process.getEnvVarOwned(allocator, "PATH");
    defer allocator.free(path);

    var trie = try Trie.init(allocator);
    defer trie.deinit();

    try buildTrie(builtins, &trie, path);

    var terminal = try Terminal.init(stdin, stdout);
    var rl = ReadLine.init(allocator, &terminal, &auto_complete_function, &trie);
    defer rl.deinit();

    while (true) {
        const command_input = try rl.readline("$ ") orelse continue;
        defer allocator.free(command_input);

        if (command_input.len == 0) continue;

        var args = parseArgs(allocator, command_input) catch |err| switch (err) {
            error.NotValidLine => {
                try errstream.print("Not Valid Line\n", .{});
                continue;
            },
            else => return err,
        };
        defer {
            for (args.items[0..]) |arg| {
                allocator.free(arg);
            }
            args.deinit(allocator);
        }

        const result = try utils.getStreams(allocator, args.items[0..]);
        defer {
            outstream = stdout;
            errstream = stderr;
            if (result.outfile_ptr) |file| {
                file.close();
                allocator.destroy(file);
            }
            if (result.errfile_ptr) |file| {
                file.close();
                allocator.destroy(file);
            }
        }

        // If the command had any redirection, accordingly handle the output stream
        if (result.outfile_ptr) |file| {
            var file_writer = file.writerStreaming(&.{});
            outstream = &file_writer.interface;
        }
        if (result.errfile_ptr) |file| {
            var file_writer = file.writerStreaming(&.{});
            errstream = &file_writer.interface;
        }

        const command = args.items[0];
        const argv = args.items[0..result.index];

        if (std.mem.eql(u8, "exit", command)) break;

        if (builtins.match(command)) {
            try builtins.call(command, argv, outstream);
        } else {
            const file_path = try utils.isExecutable(allocator, command);
            if (file_path) |file_exe| {
                defer allocator.free(file_exe);

                try utils.runChildProcess(allocator, argv, outstream, errstream);
            } else {
                try outstream.print("{s}: command not found\n", .{command});
            }
        }
    }
}
