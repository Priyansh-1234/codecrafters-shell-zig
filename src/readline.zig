const std = @import("std");

const Trie = @import("trie.zig").Trie;
const Terminal = @import("terminal.zig").Terminal;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const auto_comp_func_type = *const fn (trie: *const Trie, []const u8, Allocator) anyerror![]const u8;

pub const ReadLine = struct {
    const Self = @This();

    fn control_key(char: u8) u8 {
        return char & 0x1f;
    }
    const Key = union(enum) {
        char: u8,

        ARROW_UP,
        ARROW_DOWN,
        ARROW_LEFT,
        ARROW_RIGHT,

        HOME_KEY,
        END_KEY,

        BACKSPACE,
        DEL_KEY,
    };

    allocator: Allocator,
    terminal: *Terminal,
    buffer: ArrayList(u8),
    cursor: usize,
    auto_complete_function: auto_comp_func_type,
    trie: *const Trie,

    pub fn init(allocator: Allocator, terminal: *Terminal, auto_complete_function: auto_comp_func_type, trie: *const Trie) Self {
        return .{
            .allocator = allocator,
            .terminal = terminal,
            .buffer = .empty,
            .cursor = 0,
            .auto_complete_function = auto_complete_function,
            .trie = trie,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    fn readKey(self: *const Self) !Key {
        const byte = try self.terminal.reader.takeByte();

        if (byte == 127) return .BACKSPACE;

        if (byte == '\x1b') special_characters: {
            const seq_0 = try self.terminal.reader.takeByte();
            if (seq_0 != '[' and seq_0 != 'O') break :special_characters;

            const seq_1 = try self.terminal.reader.takeByte();
            if (seq_0 == '[' and seq_1 >= '0' and seq_1 <= '9') {
                const seq_2 = try self.terminal.reader.takeByte();
                if (seq_2 != '~') break :special_characters;

                switch (seq_1) {
                    '1', '7' => return .HOME_KEY,
                    '4', '8', '9' => return .END_KEY,
                    '3' => return .DEL_KEY,
                    '5' => return .ARROW_UP,
                    '6' => return .ARROW_DOWN,
                    else => break :special_characters,
                }
            } else if (seq_0 == '[') {
                switch (seq_1) {
                    'A' => return .ARROW_UP,
                    'B' => return .ARROW_DOWN,
                    'C' => return .ARROW_RIGHT,
                    'D' => return .ARROW_LEFT,
                    'H' => return .HOME_KEY,
                    'F' => return .END_KEY,
                    else => break :special_characters,
                }
            } else if (seq_0 == 'O') {
                switch (seq_1) {
                    'H' => return .HOME_KEY,
                    'F' => return .END_KEY,
                    else => break :special_characters,
                }
            }
        }

        return Key{ .char = byte };
    }

    fn refresh(self: *const Self, prefix: []const u8) !void {
        var writeBuffer: ArrayList(u8) = .empty;
        defer writeBuffer.deinit(self.allocator);

        try writeBuffer.appendSlice(self.allocator, "\x1b[2K");
        try writeBuffer.append(self.allocator, '\r');
        try writeBuffer.appendSlice(self.allocator, prefix);
        try writeBuffer.appendSlice(self.allocator, self.buffer.items);

        const cursor_position = try std.fmt.allocPrint(self.allocator, "\x1b[{d}G", .{self.cursor + 3});
        defer self.allocator.free(cursor_position);

        try writeBuffer.appendSlice(self.allocator, cursor_position);

        try self.terminal.writer.writeAll(writeBuffer.items);
    }

    fn moveCursor(self: *Self, key: Key) void {
        if (key == .ARROW_LEFT and self.cursor > 0) {
            self.cursor -= 1;
        }
        if (key == .ARROW_RIGHT and self.cursor < self.buffer.items.len) {
            self.cursor += 1;
        }
    }

    fn deleteCharacter(self: *Self, key: Key) void {
        if (key == .BACKSPACE and self.cursor > 0) {
            self.cursor -= 1;
            _ = self.buffer.orderedRemove(self.cursor);
        }
        if (key == .DEL_KEY and self.cursor < self.buffer.items.len) {
            _ = self.buffer.orderedRemove(self.cursor);
        }
    }

    fn changeCommand(_: *Self, _: Key) !void {
        return error.NotImplemented;
    }

    fn processKey(self: *Self) !?[]const u8 {
        const key = try self.readKey();

        switch (key) {
            .char => |ch| {
                switch (ch) {
                    control_key('c') => return error.SIGKILL,
                    control_key('a') => self.cursor = 0,
                    control_key('e') => self.cursor = self.buffer.items.len,
                    control_key('f') => self.moveCursor(.ARROW_RIGHT),
                    control_key('b') => self.moveCursor(.ARROW_LEFT),
                    control_key('d') => self.deleteCharacter(.DEL_KEY),

                    '\n' => {
                        return try self.buffer.toOwnedSlice(self.allocator);
                    },

                    '\t' => {
                        const line = try self.auto_complete_function(self.trie, self.buffer.items, self.allocator);
                        defer self.allocator.free(line);

                        self.buffer.clearAndFree(self.allocator);
                        try self.buffer.appendSlice(self.allocator, line);
                        self.cursor = line.len;
                    },

                    else => {
                        try self.buffer.append(self.allocator, ch);
                        self.cursor += 1;
                    },
                }
            },
            .ARROW_UP, .ARROW_DOWN => self.changeCommand(key) catch {},

            .ARROW_LEFT, .ARROW_RIGHT => self.moveCursor(key),

            .HOME_KEY => self.cursor = 0,

            .END_KEY => self.cursor = self.buffer.items.len,

            .BACKSPACE, .DEL_KEY => self.deleteCharacter(key),
        }

        return null;
    }

    pub fn readline(self: *Self, prefix: []const u8) !?[]const u8 {
        try self.terminal.raw();
        defer {
            self.terminal.cooked() catch {};
            self.buffer.clearAndFree(self.allocator);
            self.cursor = 0;
            self.terminal.writer.writeByte('\n') catch {};
        }

        while (true) {
            self.refresh(prefix) catch {};
            const value = self.processKey() catch |err| switch (err) {
                error.SIGKILL => return null,
                else => return err,
            };

            if (value) |line| return line;
        }
    }
};
