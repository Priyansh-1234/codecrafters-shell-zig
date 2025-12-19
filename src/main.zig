// --- File Imports --- //
const std = @import("std");
const utils = @import("utils.zig");
const Parser = @import("parser.zig");

const posix = std.posix;

const shell_builtins = @import("shell_builtin.zig").shell_builtin;
const Trie = @import("trie.zig").Trie;
const ReadLine = @import("readline.zig").ReadLine;
const Terminal = @import("terminal.zig").Terminal;
const historyManger = @import("history.zig").historyManager;
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

pub fn main() !void {
    var dba = std.heap.DebugAllocator(.{}){};
    defer assert(dba.deinit() == .ok);
    const allocator = dba.allocator();

    // --- Setting up the standard out and standard in and standard err --- //
    var stdout = std.fs.File.stdout();
    var stdout_writer = stdout.writerStreaming(&.{});
    const stdout_stream = &stdout_writer.interface;

    var stderr = std.fs.File.stderr();
    var stderr_writer = std.fs.File.stderr().writerStreaming(&.{});
    const stderr_stream = &stderr_writer.interface;

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    // --- The output streams which can change upon redirection --- //
    var outstream: *std.Io.Writer = stdout_stream;
    var errstream: *std.Io.Writer = stderr_stream;

    var history_manager = historyManger.init(allocator);
    defer history_manager.deinit();

    const builtins = shell_builtins.init(allocator, &history_manager);

    const path = try std.process.getEnvVarOwned(allocator, "PATH");
    defer allocator.free(path);

    var trie = try Trie.init(allocator);
    defer trie.deinit();

    try utils.buildTrie(builtins.shell_functions, &trie, path);

    var terminal = try Terminal.init(stdin, stdout_stream, &history_manager);
    var rl = ReadLine.init(allocator, &terminal, &utils.auto_complete_function, &trie, &history_manager);
    defer rl.deinit();

    var commandRunner = utils.CommandRunner.init(allocator, &stdout, &stderr, builtins);

    while (true) {
        const command_input = try rl.readline("$ ") orelse continue;
        defer allocator.free(command_input);

        if (command_input.len == 0) break;

        var args = Parser.parseArgs(allocator, command_input) catch |err| switch (err) {
            error.InvalidLine => {
                try errstream.print("Not Valid Line\n", .{});
                continue;
            },
            else => return err,
        };
        defer {
            for (args[0..]) |arg| {
                allocator.free(arg);
            }
            allocator.free(args);
        }

        const commands = Parser.parseCommands(allocator, args) catch |err| switch (err) {
            error.InvalidPipe => {
                try errstream.print("Invalid Pipe\n", .{});
                continue;
            },
            else => return err,
        };
        defer {
            for (commands[0..]) |cmd| {
                allocator.free(cmd.argv);
            }
            allocator.free(commands);
        }

        const result = try utils.getStreams(allocator, args[0..]);
        defer {
            outstream = stdout_stream;
            errstream = stderr_stream;

            commandRunner.setOutFile(&stdout);
            commandRunner.setErrFile(&stderr);

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
            commandRunner.setOutFile(file);

            var file_writer = file.writerStreaming(&.{});
            outstream = &file_writer.interface;
        }
        if (result.errfile_ptr) |file| {
            commandRunner.setErrFile(file);

            var file_writer = file.writerStreaming(&.{});
            errstream = &file_writer.interface;
        }

        if (commands.len == 1 and std.mem.eql(u8, commands[0].argv[0], "exit")) {
            break;
        }

        try commandRunner.runCommands(commands);
    }
}
