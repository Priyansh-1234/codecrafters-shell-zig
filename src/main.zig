// --- File Imports --- //
const std = @import("std");
const utils = @import("utils.zig");
const parseArgs = @import("parser.zig").parseArgs;
const shell_builtins = @import("shell_builtin.zig").shell_builtin;
const Trie = @import("trie.zig").Trie;

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

fn buildTrie(builtins: shell_builtins, trie: *Trie) !void {
    for (builtins.shell_functions[0..]) |shell_function| {
        try trie.insert(shell_function);
    }
}

pub fn main() !void {
    var dba = std.heap.DebugAllocator(.{}){};
    defer assert(dba.deinit() == .ok);
    const allocator = dba.allocator();

    const builtins = shell_builtins.init(allocator);

    var trie = try Trie.init(allocator);
    defer trie.deinit();

    try buildTrie(builtins, &trie);

    const read_utils = try utils.readUtils.init(allocator, &trie);

    while (true) {
        const command_input = read_utils.readline(allocator, stdin) catch |err| switch (err) {
            error.CloseTerminal => break,
            else => return err,
        };
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
