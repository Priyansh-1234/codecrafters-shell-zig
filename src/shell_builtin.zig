const std = @import("std");
const utils = @import("utils.zig");

const posix = std.posix;

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const historyManager = @import("history.zig").historyManager;

const getExecutable = utils.getExecutable;

pub const shell_builtin = struct {
    const Self = @This();

    allocator: Allocator,
    shell_functions: []const []const u8,
    history_manager: *historyManager,

    pub fn init(allocator: Allocator, history_manager: *historyManager) Self {
        return .{
            .allocator = allocator,
            .shell_functions = &[_][]const u8{ "echo", "type", "exit", "cd", "pwd", "history" },
            .history_manager = history_manager,
        };
    }

    fn historyFn(self: *const Self, args: []const []const u8, outstream: *Writer, errstream: *Writer) !void {
        var i: usize = 0;

        var read_filename: []const u8 = "";
        var write_filename: []const u8 = "";
        var limit: usize = 0;
        var limit_set = false;
        var append = false;

        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, "-r", arg)) {
                if (i + 1 >= args.len) {
                    _ = try errstream.write("history: Invalid Usage\n");
                    try self.history_manager.printUsage(errstream);
                    return;
                }

                read_filename = args[i + 1];

                i += 1;
                continue;
            }

            if (std.mem.eql(u8, "-w", arg)) {
                if (i + 1 >= args.len) {
                    _ = try errstream.write("history: Invalid Usage\n");
                    try self.history_manager.printUsage(errstream);
                    return;
                }

                write_filename = args[i + 1];
                i += 1;
                continue;
            }

            if (std.mem.eql(u8, "-a", arg)) {
                if (i + 1 >= args.len) {
                    _ = try errstream.write("history: Invalid Usage\n");
                    try self.history_manager.printUsage(errstream);
                    return;
                }

                append = true;
                write_filename = args[i + 1];
                i += 1;
                continue;
            }

            if (!limit_set) {
                limit = std.fmt.parseInt(usize, arg, 10) catch {
                    _ = try errstream.write("history: Invalid Usage\n");
                    try self.history_manager.printUsage(errstream);
                    return;
                };
                limit_set = true;
            } else {
                _ = try errstream.write("history: Invalid Usage\n");
                try self.history_manager.printUsage(errstream);
                return;
            }
        }

        if (read_filename.len > 0) {
            const file = try utils.openFile(self.allocator, read_filename, .read_only, false);
            defer {
                file.close();
                self.allocator.destroy(file);
            }

            try self.history_manager.readHistory(file);
        }

        if (write_filename.len > 0) {
            const file = try utils.openFile(self.allocator, write_filename, .read_write, false);
            defer {
                file.close();
                self.allocator.destroy(file);
            }

            if (append) {
                try self.history_manager.appendHistory(file);
            } else {
                try self.history_manager.writeHistory(file);
            }
        }

        if (read_filename.len == 0 and write_filename.len == 0) {
            try self.history_manager.displayHistory(limit_set, limit, outstream);
        }
    }

    fn echoFn(self: *const Self, args: []const []const u8, outstream: *Writer) !void {
        const s = try std.mem.join(self.allocator, " ", args);
        defer self.allocator.free(s);

        try outstream.print("{s}\n", .{s});
    }

    fn exitFn(_: *const Self, _: []const []const u8, _: *Writer) !void {
        posix.exit(0);
    }

    fn typeFn(self: *const Self, args: []const []const u8, outstream: *Writer, errstream: *Writer) !void {
        for (args) |arg| {
            if (self.match(arg)) {
                try outstream.print("{s} is a shell builtin\n", .{arg});
                return;
            }

            if (try getExecutable(self.allocator, arg)) |file_path| {
                defer self.allocator.free(file_path);
                try outstream.print("{s} is {s}\n", .{ arg, file_path });
                return;
            }

            try errstream.print("{s}: not found\n", .{arg});
        }
    }

    fn pwdFn(_: *const Self, _: []const []const u8, outstream: *Writer) !void {
        var buffer: [1024]u8 = undefined;
        const cwd = try std.fs.cwd().realpath(".", &buffer);
        try outstream.print("{s}\n", .{cwd});
    }

    fn cdFn(self: *const Self, args: []const []const u8, outstream: *Writer, errstream: *Writer) !void {
        if (args.len > 1) {
            const s = try std.mem.join(self.allocator, " ", args);
            defer self.allocator.free(s);

            try errstream.print("cd: {s}: No such file or directory\n", .{s});
            return;
        }

        if (args.len == 0) return;
        const path = args[0];

        if (std.mem.eql(u8, "~", path)) {
            const home = try std.process.getEnvVarOwned(self.allocator, "HOME");
            defer self.allocator.free(home);

            var dir = try std.fs.openDirAbsolute(home, .{});
            try dir.setAsCwd();

            return;
        }

        const flag = std.fs.path.isAbsolute(path);

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
                    try errstream.print("cd: {s}: No such file or directory\n", .{path});
                    return;
                },
                else => return err,
            };

            try dir.setAsCwd();
        }
    }

    pub fn match(self: *const Self, function_name: []const u8) bool {
        for (self.shell_functions) |func_name| {
            if (std.mem.eql(u8, func_name, function_name)) return true;
        }
        return false;
    }

    pub fn call(self: *const Self, function_name: []const u8, argv: []const []const u8, outstream: *Writer, errstream: *Writer) !void {
        if (std.mem.eql(u8, "exit", function_name)) return self.exitFn(argv[1..], outstream);
        if (std.mem.eql(u8, "echo", function_name)) return self.echoFn(argv[1..], outstream);
        if (std.mem.eql(u8, "type", function_name)) return self.typeFn(argv[1..], outstream, errstream);
        if (std.mem.eql(u8, "pwd", function_name)) return self.pwdFn(argv[1..], outstream);
        if (std.mem.eql(u8, "cd", function_name)) return self.cdFn(argv[1..], outstream, errstream);
        if (std.mem.eql(u8, "history", function_name)) return self.historyFn(argv[1..], outstream, errstream);
        return error.NotBuiltinFuncion;
    }
};
