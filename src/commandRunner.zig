const std = @import("std");
const utils = @import("utils.zig");

const posix = std.posix;

const Allocator = std.mem.Allocator;
const Command = @import("parser.zig").Command;
const ShellBuiltins = @import("shell_builtin.zig").ShellBuiltins;

pub const CommandRunner = struct {
    const Self = @This();

    out_file: *std.fs.File,
    err_file: *std.fs.File,
    ShellBuiltinss: ShellBuiltins,
    allocator: Allocator,

    pub fn init(allocator: Allocator, outfile: *std.fs.File, errfile: *std.fs.File, builtin: ShellBuiltins) CommandRunner {
        return .{
            .out_file = outfile,
            .err_file = errfile,
            .ShellBuiltinss = builtin,
            .allocator = allocator,
        };
    }

    fn runCommandSimple(self: *const Self, command: Command) !void {
        if (self.ShellBuiltinss.match(command.argv[0])) {
            var outFile_writer = self.out_file.writerStreaming(&.{});
            const outstream = &outFile_writer.interface;

            var errFile_writer = self.err_file.writerStreaming(&.{});
            const errstream = &errFile_writer.interface;

            self.ShellBuiltinss.call(command.argv[0], command.argv[0..], outstream, errstream) catch |err| {
                try outstream.flush();
                try errstream.flush();

                return err;
            };

            try outstream.flush();
            try errstream.flush();

            return;
        }

        if (!try utils.isExecutable(self.allocator, command.argv[0], self.ShellBuiltinss.shell_functions)) {
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
                if (!try utils.isExecutable(self.allocator, commands[i].argv[0], self.ShellBuiltinss.shell_functions)) {
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
        if (self.ShellBuiltinss.match(command.argv[0])) {
            var outFile_writer = self.out_file.writerStreaming(&.{});
            const outstream = &outFile_writer.interface;

            var errFile_writer = self.err_file.writerStreaming(&.{});
            const errstream = &errFile_writer.interface;

            self.ShellBuiltinss.call(command.argv[0], command.argv[0..], outstream, errstream) catch |err| {
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
