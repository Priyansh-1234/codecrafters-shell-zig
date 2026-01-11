const std = @import("std");

const posix = std.posix;

const HistoryManager = @import("history.zig").HistoryManager;
const Command = @import("parser.zig").Command;
const Trie = @import("trie.zig").Trie;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const Allocator = std.mem.Allocator;

const shell_builtin = @import("shell_builtin.zig").ShellBuiltins;

pub const autofillSuggestion = struct {
    suggestions: [][]u8,
    autofill: []u8,
};

pub fn readDefaultHistory(allocator: Allocator, history_manager: *HistoryManager) !void {
    const hist_filename = std.process.getEnvVarOwned(allocator, "HISTFILE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);

            break :blk try std.fs.path.join(allocator, &.{ home, ".shell_history" });
        },
        else => return err,
    };
    defer allocator.free(hist_filename);

    var hist_file = try openFile(allocator, hist_filename, .read_only, false);
    defer {
        hist_file.close();
        allocator.destroy(hist_file);
    }

    history_manager.readHistory(hist_file) catch {};
}
pub fn writeDefaultHistory(allocator: Allocator, history_manager: *HistoryManager) !void {
    const hist_filename = std.process.getEnvVarOwned(allocator, "HISTFILE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);

            break :blk try std.fs.path.join(allocator, &.{ home, ".shell_history" });
        },
        else => return err,
    };
    defer allocator.free(hist_filename);

    var hist_file = try openFile(allocator, hist_filename, .write_only, false);
    defer {
        hist_file.close();
        allocator.destroy(hist_file);
    }

    history_manager.writeHistory(hist_file) catch {};
}

pub fn getExecutable(allocator: Allocator, filename: []const u8) !?[]const u8 {
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
            if (args.len <= i + 1) return error.InvalidLine;
            outfile_name = args[i + 1];
            outfile_present = true;
            idx1 = i;
            i += 1;
        } else if (std.mem.eql(u8, "2>", arg)) {
            if (args.len <= i + 1) return error.InvalidLine;
            errfile_name = args[i + 1];
            errfile_present = true;
            idx2 = i;
            i += 1;
        } else if (std.mem.eql(u8, arg, ">>") or std.mem.eql(u8, arg, "1>>")) {
            if (args.len <= i + 1) return error.InvalidLine;
            outfile_name = args[i + 1];
            outfile_present = true;
            outfile_append = true;
            idx1 = i;
            i += 1;
        } else if (std.mem.eql(u8, arg, "2>>")) {
            if (args.len <= i + 1) return error.InvalidLine;
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

    if (outfile_ptr) |*outfile| {
        outfile.* = try openFile(allocator, outfile_name, .read_write, outfile_append);
    }

    if (errfile_ptr) |*errfile| {
        errfile.* = try openFile(allocator, errfile_name, .read_write, errfile_append);
    }

    return .{
        .outfile_ptr = outfile_ptr,
        .errfile_ptr = errfile_ptr,
        .index = i,
    };
}

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

fn openFileAbsolute(allocator: Allocator, filename: []const u8, mode: std.fs.File.OpenMode, append: bool) !*std.fs.File {
    const file = try allocator.create(std.fs.File);
    errdefer allocator.destroy(file);

    if (!std.fs.path.isAbsolute(filename)) return error.NotAbsolutePath;

    if (append) {
        file.* = try std.fs.createFileAbsolute(filename, .{ .truncate = false });
        try file.seekFromEnd(0);
    } else {
        file.* = std.fs.openFileAbsolute(filename, .{ .mode = mode }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.createFileAbsolute(filename, .{ .truncate = true }),
            else => return err,
        };
    }

    return file;
}

fn openFileCwd(allocator: Allocator, filename: []const u8, mode: std.fs.File.OpenMode, append: bool) !*std.fs.File {
    const file = try allocator.create(std.fs.File);
    errdefer allocator.destroy(file);

    if (append) {
        file.* = try std.fs.cwd().createFile(filename, .{ .truncate = false });
        try file.seekFromEnd(0);
    } else {
        file.* = std.fs.cwd().openFile(filename, .{ .mode = mode }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.cwd().createFile(filename, .{ .truncate = true }),
            else => return err,
        };
    }

    return file;
}

pub fn openFile(allocator: Allocator, filename: []const u8, mode: std.fs.File.OpenMode, append: bool) !*std.fs.File {
    if (std.fs.path.isAbsolute(filename)) {
        return openFileAbsolute(allocator, filename, mode, append);
    } else {
        return openFileCwd(allocator, filename, mode, append);
    }
}
