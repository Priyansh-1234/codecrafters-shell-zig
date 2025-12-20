const std = @import("std");
const posix = std.posix;

const Trie = @import("trie.zig").Trie;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const Allocator = std.mem.Allocator;
const Command = @import("parser.zig").Command;

const shell_builtin = @import("shell_builtin.zig").shell_builtin;

pub const autofillSuggestion = struct {
    suggestions: [][]u8,
    autofill: []u8,
};

pub const isExecutableError = (std.process.GetEnvVarOwnedError || std.fs.File.OpenError || Allocator.Error || std.fs.Dir.RealPathAllocError);

pub fn getExecutable(allocator: Allocator, filename: []const u8) isExecutableError!?[]const u8 {
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

pub fn isExecutable(allocator: Allocator, filename: []const u8, shell_functions: []const []const u8) !bool {
    for (shell_functions) |func| {
        if (std.mem.eql(u8, filename, func)) return true;
    }
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
            return true;
        }
    }

    const stat = std.fs.cwd().statFile(filename) catch return false;
    if (stat.mode & (std.posix.S.IXUSR | std.posix.S.IXGRP | std.posix.S.IXOTH) != 0) {
        return true;
    }

    return false;
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
        if (outfile_append) {
            if (std.fs.path.isAbsolute(outfile_name)) {
                outfile.* = std.fs.openFileAbsolute(outfile_name, .{ .mode = .read_write }) catch |err| switch (err) {
                    error.FileNotFound => try std.fs.createFileAbsolute(outfile_name, .{ .truncate = !outfile_append }),
                    else => return err,
                };
            } else {
                outfile.* = std.fs.cwd().openFile(outfile_name, .{ .mode = .read_write }) catch |err| switch (err) {
                    error.FileNotFound => try std.fs.cwd().createFile(outfile_name, .{ .truncate = !outfile_append }),
                    else => return err,
                };
            }
            try outfile.seekFromEnd(0);
        } else {
            if (std.fs.path.isAbsolute(outfile_name)) {
                outfile.* = try std.fs.createFileAbsolute(outfile_name, .{ .truncate = !outfile_append });
            } else {
                outfile.* = try std.fs.cwd().createFile(outfile_name, .{ .truncate = !outfile_append });
            }
        }
    }

    if (errfile_ptr) |errfile| {
        if (errfile_append) {
            if (std.fs.path.isAbsolute(errfile_name)) {
                errfile.* = std.fs.openFileAbsolute(errfile_name, .{ .mode = .read_write }) catch |err| switch (err) {
                    error.FileNotFound => try std.fs.createFileAbsolute(errfile_name, .{ .truncate = !errfile_append }),
                    else => return err,
                };
            } else {
                errfile.* = std.fs.cwd().openFile(errfile_name, .{ .mode = .read_write }) catch |err| switch (err) {
                    error.FileNotFound => try std.fs.cwd().createFile(errfile_name, .{ .truncate = !errfile_append }),
                    else => return err,
                };
            }
            try errfile.seekFromEnd(0);
        } else {
            if (std.fs.path.isAbsolute(errfile_name)) {
                errfile.* = try std.fs.createFileAbsolute(errfile_name, .{ .truncate = !errfile_append });
            } else {
                errfile.* = try std.fs.cwd().createFile(errfile_name, .{ .truncate = !errfile_append });
            }
        }
    }

    return .{
        .outfile_ptr = outfile_ptr,
        .errfile_ptr = errfile_ptr,
        .index = i,
    };
}

//pub fn runChildProcess(
//    allocator: Allocator,
//    argv: []const []const u8,
//    outstream: *Writer,
//    errstream: *Writer,
//) (std.process.Child.SpawnError || Writer.Error || Reader.DelimiterError || std.process.Child.WaitError)!void {
//    var process = std.process.Child.init(argv, allocator);
//
//    process.stdin_behavior = .Ignore;
//    process.stdout_behavior = .Pipe;
//    process.stderr_behavior = .Pipe;
//
//    try process.spawn();
//
//    var stdout_buffer: [1024]u8 = undefined;
//    var process_stdout_reader = process.stdout.?.readerStreaming(&stdout_buffer);
//    const process_stdout = &process_stdout_reader.interface;
//
//    var stderr_buffer: [1024]u8 = undefined;
//    var process_stderr_reader = process.stderr.?.readerStreaming(&stderr_buffer);
//    const process_stderr = &process_stderr_reader.interface;
//
//    while (process_stdout.takeDelimiterInclusive('\n')) |line| {
//        try outstream.print("{s}", .{line});
//    } else |err| {
//        if (err != error.EndOfStream) return err;
//    }
//
//    while (process_stderr.takeDelimiterInclusive('\n')) |line| {
//        try errstream.print("{s}", .{line});
//    } else |err| {
//        if (err != error.EndOfStream) return err;
//    }
//
//    _ = try process.wait();
//}

pub fn buildTrie(shell_functions: []const []const u8, trie: *Trie, path: []const u8) !void {
    for (shell_functions[0..]) |shell_function| {
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

pub fn auto_complete_function(trie: *const Trie, word: []const u8, allocator: Allocator) !autofillSuggestion {
    const result = try trie.complete(word, allocator);

    if (result == null) {
        return error.InvalidComplete;
    }

    return result orelse unreachable;
}

pub fn openFile(allocator: Allocator, filename: []const u8, mode: std.fs.File.OpenMode, append: bool) !*std.fs.File {
    const file = try allocator.create(std.fs.File);
    errdefer allocator.destroy(file);

    if (append) {
        if (std.fs.path.isAbsolute(filename)) {
            file.* = try std.fs.createFileAbsolute(filename, .{ .truncate = false });
        } else {
            file.* = try std.fs.cwd().createFile(filename, .{ .truncate = false });
        }

        try file.seekFromEnd(0);
    } else {
        if (std.fs.path.isAbsolute(filename)) {
            file.* = std.fs.openFileAbsolute(filename, .{ .mode = mode }) catch
                try std.fs.createFileAbsolute(filename, .{ .truncate = true });
        } else {
            file.* = std.fs.cwd().openFile(filename, .{ .mode = mode }) catch
                try std.fs.cwd().createFile(filename, .{ .truncate = true });
        }
    }

    return file;
}

pub const CommandRunner = struct {
    const Self = @This();

    out_file: *std.fs.File,
    err_file: *std.fs.File,
    shell_builtins: shell_builtin,
    allocator: Allocator,

    pub fn init(allocator: Allocator, outfile: *std.fs.File, errfile: *std.fs.File, builtin: shell_builtin) CommandRunner {
        return .{
            .out_file = outfile,
            .err_file = errfile,
            .shell_builtins = builtin,
            .allocator = allocator,
        };
    }

    fn runCommandSimple(self: *const Self, command: Command) !void {
        if (self.shell_builtins.match(command.argv[0])) {
            var outFile_writer = self.out_file.writerStreaming(&.{});
            const outstream = &outFile_writer.interface;

            var errFile_writer = self.err_file.writerStreaming(&.{});
            const errstream = &errFile_writer.interface;

            self.shell_builtins.call(command.argv[0], command.argv[0..], outstream, errstream) catch |err| {
                try outstream.flush();
                try errstream.flush();

                return err;
            };

            try outstream.flush();
            try errstream.flush();

            return;
        }

        if (!try isExecutable(self.allocator, command.argv[0], self.shell_builtins.shell_functions)) {
            _ = try posix.write(self.err_file.handle, command.argv[0]);
            _ = try posix.write(self.err_file.handle, ": command not found\n");
            return;
        }

        const pid = try posix.fork();
        if (pid == 0) {
            try posix.dup2(self.out_file.handle, posix.STDOUT_FILENO);
            try posix.dup2(self.err_file.handle, posix.STDERR_FILENO);

            self.execCommand(command) catch return posix.exit(1);
            posix.exit(0);
        } else {
            _ = posix.waitpid(pid, 0);
        }
    }

    pub fn setOutFile(self: *Self, out_file: *std.fs.File) void {
        self.out_file = out_file;
    }

    pub fn setErrFile(self: *Self, err_file: *std.fs.File) void {
        self.err_file = err_file;
    }

    pub fn runCommands(self: *const Self, commands: []const Command) !void {
        if (commands.len == 0) return;

        if (commands.len == 1) {
            return self.runCommandSimple(commands[0]);
        }

        const num_pipes = commands.len - 1;
        const pipes = try self.allocator.alloc([2]posix.fd_t, num_pipes);
        defer self.allocator.free(pipes);

        for (pipes) |*pipe| {
            pipe.* = try posix.pipe();
        }

        var i: usize = 0;
        while (i < commands.len) : (i += 1) {
            const pid = try posix.fork();
            if (pid == 0) {
                try self.setupChildPipes(i, commands.len, pipes);
                if (!try isExecutable(self.allocator, commands[i].argv[0], self.shell_builtins.shell_functions)) {
                    _ = try posix.write(self.err_file.handle, commands[i].argv[0]);
                    _ = try posix.write(self.err_file.handle, ": command not found\n");
                } else {
                    self.execCommand(commands[i]) catch posix.exit(1);
                }
                posix.exit(0);
            }
        }

        for (pipes) |pipe_fd| {
            posix.close(pipe_fd[0]);
            posix.close(pipe_fd[1]);
        }

        i = 0;
        while (i < commands.len) : (i += 1) {
            _ = posix.waitpid(-1, 0);
        }
    }

    fn setupChildPipes(self: *const Self, cmd_index: usize, total_cmds: usize, pipes: [][2]posix.fd_t) !void {
        try posix.dup2(self.err_file.handle, posix.STDERR_FILENO);

        if (cmd_index > 0) {
            try posix.dup2(pipes[cmd_index - 1][0], posix.STDIN_FILENO);
        }

        if (cmd_index < total_cmds - 1) {
            try posix.dup2(pipes[cmd_index][1], posix.STDOUT_FILENO);
        }
        if (cmd_index == total_cmds - 1) {
            try posix.dup2(self.out_file.handle, posix.STDOUT_FILENO);
        }

        for (pipes) |pipe_fd| {
            posix.close(pipe_fd[0]);
            posix.close(pipe_fd[1]);
        }
    }

    fn execCommand(self: *const Self, command: Command) !void {
        if (self.shell_builtins.match(command.argv[0])) {
            var outFile_writer = self.out_file.writerStreaming(&.{});
            const outstream = &outFile_writer.interface;

            var errFile_writer = self.err_file.writerStreaming(&.{});
            const errstream = &errFile_writer.interface;

            self.shell_builtins.call(command.argv[0], command.argv[0..], outstream, errstream) catch |err| {
                try outstream.flush();
                try errstream.flush();

                return err;
            };

            try outstream.flush();
            try errstream.flush();

            return;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();

        const argv = try allocator.allocSentinel(?[*:0]const u8, command.argv.len, null);

        for (command.argv[0..], 0..) |arg, i| {
            argv[i] = try allocator.dupeZ(u8, arg);
        }

        const envp: [*:null]?[*:0]const u8 = @ptrCast(std.os.environ.ptr);

        return posix.execvpeZ(argv[0].?, argv.ptr, envp);
    }
};
