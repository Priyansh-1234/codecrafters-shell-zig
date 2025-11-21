const std = @import("std");
const isExecutable = @import("utils.zig").isExecutable;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const shell_builtin = struct {
    const Self = @This();

    allocator: Allocator,
    shell_functions: []const []const u8,
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .shell_functions = &[_][]const u8{ "echo", "type", "exit", "cd", "pwd" },
        };
    }

    fn echoFn(self: *const Self, args: []const []const u8, outstream: *Writer) !void {
        const s = try std.mem.join(self.allocator, " ", args);
        defer self.allocator.free(s);

        try outstream.print("{s}\n", .{s});
    }

    fn exitFn(_: *const Self, _: []const []const u8, _: *Writer) !void {
        return error.TemplateFunction;
    }

    fn typeFn(self: *const Self, args: []const []const u8, outstream: *Writer) !void {
        for (args) |arg| {
            if (self.match(arg)) {
                try outstream.print("{s} is a shell builtin\n", .{arg});
                return;
            }

            if (try isExecutable(self.allocator, arg)) |file_path| {
                defer self.allocator.free(file_path);
                try outstream.print("{s} is {s}\n", .{ arg, file_path });
                return;
            }

            try outstream.print("{s}: not found\n", .{arg});
        }
    }

    fn pwdFn(_: *const Self, _: []const []const u8, outstream: *Writer) !void {
        var buffer: [1024]u8 = undefined;
        const cwd = try std.fs.cwd().realpath(".", &buffer);
        try outstream.print("{s}\n", .{cwd});
    }

    fn cdFn(self: *const Self, args: []const []const u8, outstream: *Writer) !void {
        if (args.len > 1) {
            const s = try std.mem.join(self.allocator, " ", args);
            defer self.allocator.free(s);

            try outstream.print("cd: {s}: No such file or directory\n", .{s});
            return;
        }

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
                    try outstream.print("cd: {s}: No such file or directory\n", .{path});
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

    pub fn call(self: *const Self, function_name: []const u8, argv: []const []const u8, outstream: *Writer) anyerror!void {
        if (std.mem.eql(u8, "exit", function_name)) return self.exitFn(argv[1..], outstream);
        if (std.mem.eql(u8, "echo", function_name)) return self.echoFn(argv[1..], outstream);
        if (std.mem.eql(u8, "type", function_name)) return self.typeFn(argv[1..], outstream);
        if (std.mem.eql(u8, "pwd", function_name)) return self.pwdFn(argv[1..], outstream);
        if (std.mem.eql(u8, "cd", function_name)) return self.cdFn(argv[1..], outstream);
        return error.NotBuiltinFuncion;
    }
};
