const std = @import("std");
const utils = @import("utils.zig");

const Trie = @import("trie.zig").Trie;
const Terminal = @import("terminal.zig").Terminal;
const historyManager = @import("history.zig").historyManager;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;

const auto_comp_func_type = *const fn (trie: *const Trie, []const u8, Allocator) anyerror!utils.autofillSuggestion;

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
    auto_complete_function: auto_comp_func_type,
    history_manager: *historyManager,
    trie: *const Trie,

    display_buffer: ArrayList(u8),
    command_buffer: ArrayList(u8),
    cursor: usize,
    history_cursor: usize,

    pub fn init(allocator: Allocator, terminal: *Terminal, auto_complete_function: auto_comp_func_type, trie: *const Trie, history_manager: *historyManager) Self {
        return .{
            .allocator = allocator,
            .terminal = terminal,
            .display_buffer = .empty,
            .command_buffer = .empty,
            .cursor = 0,
            .auto_complete_function = auto_complete_function,
            .trie = trie,
            .history_manager = history_manager,
            .history_cursor = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.display_buffer.deinit(self.allocator);
        self.command_buffer.deinit(self.allocator);
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
        try writeBuffer.appendSlice(self.allocator, self.display_buffer.items);

        const cursor_position = try std.fmt.allocPrint(self.allocator, "\x1b[{d}G", .{self.cursor + 3});
        defer self.allocator.free(cursor_position);

        try writeBuffer.appendSlice(self.allocator, cursor_position);

        try self.terminal.writer.writeAll(writeBuffer.items);
    }

    fn moveCursor(self: *Self, key: Key) void {
        if (key == .ARROW_LEFT and self.cursor > 0) {
            self.cursor -= 1;
        }
        if (key == .ARROW_RIGHT and self.cursor < self.display_buffer.items.len) {
            self.cursor += 1;
        }
    }

    fn deleteCharacter(self: *Self, key: Key) void {
        if (key == .BACKSPACE and self.cursor > 0) {
            self.cursor -= 1;
            _ = self.display_buffer.orderedRemove(self.cursor);

            if (self.history_cursor == 0) {
                _ = self.command_buffer.orderedRemove(self.cursor);
            }
        }
        if (key == .DEL_KEY and self.cursor < self.display_buffer.items.len) {
            _ = self.display_buffer.orderedRemove(self.cursor);

            if (self.history_cursor == 0) {
                _ = self.command_buffer.orderedRemove(self.cursor);
            }
        }
    }

    fn changeDisplayBuffer(self: *Self, command: []const u8) Allocator.Error!void {
        if (std.mem.eql(u8, command[0..], self.display_buffer.items[0..])) return;

        self.display_buffer.clearAndFree(self.allocator);
        try self.display_buffer.appendSlice(self.allocator, command);
    }

    fn changeCommand(self: *Self, key: Key) !void {
        if (key == .ARROW_UP) {
            if (self.history_cursor < self.history_manager.history.items.len) {
                self.history_cursor += 1;
            }
        }
        if (key == .ARROW_DOWN) {
            if (self.history_cursor > 0) {
                self.history_cursor -= 1;
            }
        }
        if (self.history_cursor == 0) {
            try self.changeDisplayBuffer(self.command_buffer.items[0..]);
            return;
        }

        const index: isize = -@as(isize, @intCast(self.history_cursor));
        const command = self.history_manager.getCommand(index);
        try self.changeDisplayBuffer(command);
    }

    fn getWord(self: *Self) ?struct { word: []const u8, index: usize } {
        if (self.display_buffer.items.len == 0) return null;

        var i: usize = 0;
        while (i > 0 and self.display_buffer.items[i - 1] != ' ') : (i -= 1) {}

        return .{
            .word = self.display_buffer.items[i..],
            .index = i,
        };
    }

    fn displaySuggestions(self: *const Self, suggestions: []const []const u8) !void {
        try self.terminal.writer.writeByte('\n');
        for (suggestions[0..]) |suggestion| {
            _ = try self.terminal.writer.write(suggestion);
            _ = try self.terminal.writer.write("  ");
        }

        try self.terminal.writer.writeByte('\n');
    }

    fn handleKey(self: *Self, key: Key) !?[]const u8 {
        switch (key) {
            .char => |ch| {
                switch (ch) {
                    control_key('c') => return error.SIGKILL,
                    control_key('a') => self.cursor = 0,
                    control_key('e') => self.cursor = self.display_buffer.items.len,
                    control_key('f') => self.moveCursor(.ARROW_RIGHT),
                    control_key('b') => self.moveCursor(.ARROW_LEFT),
                    control_key('d') => self.deleteCharacter(.DEL_KEY),

                    '\n' => {
                        self.command_buffer.clearAndFree(self.allocator);
                        return try self.display_buffer.toOwnedSlice(self.allocator);
                    },

                    '\t' => {
                        const wordResult = self.getWord();
                        if (wordResult == null) {
                            try self.terminal.writer.writeByte('\x07');
                            return null;
                        }
                        defer self.cursor = self.display_buffer.items.len;

                        const word = wordResult.?.word;
                        const index = wordResult.?.index;

                        const suggestionResult = self.auto_complete_function(self.trie, word, self.allocator) catch |err| switch (err) {
                            error.InvalidComplete => {
                                try self.terminal.writer.writeByte('\x07');
                                return null;
                            },
                            else => return err,
                        };
                        defer {
                            for (suggestionResult.suggestions[0..]) |suggestion| {
                                self.allocator.free(suggestion);
                            }
                            self.allocator.free(suggestionResult.suggestions);

                            self.allocator.free(suggestionResult.autofill);
                        }

                        if (!std.mem.eql(u8, suggestionResult.autofill, word)) {
                            try self.display_buffer.replaceRange(self.allocator, index, word.len, suggestionResult.autofill);

                            if (self.history_cursor == 0) {
                                try self.command_buffer.replaceRange(self.allocator, index, word.len, suggestionResult.autofill);
                            }

                            return null;
                        }

                        try self.terminal.writer.writeByte('\x07');

                        const newKey = try self.readKey();
                        if (newKey != .char or newKey.char != '\t') {
                            return self.handleKey(newKey);
                        }

                        try self.displaySuggestions(suggestionResult.suggestions);
                    },

                    else => {
                        try self.display_buffer.append(self.allocator, ch);
                        if (self.history_cursor == 0) {
                            try self.command_buffer.append(self.allocator, ch);
                        }
                        self.cursor += 1;
                    },
                }
            },
            .ARROW_UP, .ARROW_DOWN => try self.changeCommand(key),

            .ARROW_LEFT, .ARROW_RIGHT => self.moveCursor(key),

            .HOME_KEY => self.cursor = 0,

            .END_KEY => self.cursor = self.display_buffer.items.len,

            .BACKSPACE, .DEL_KEY => self.deleteCharacter(key),
        }
        self.cursor = @min(self.cursor, self.display_buffer.items.len);

        return null;
    }

    fn processKey(self: *Self) !?[]const u8 {
        const key = try self.readKey();
        return self.handleKey(key);
    }

    pub fn readline(self: *Self, prefix: []const u8) !?[]const u8 {
        try self.terminal.raw();
        defer {
            self.terminal.cooked() catch {};
            self.display_buffer.clearAndFree(self.allocator);
            self.cursor = 0;
            self.terminal.writer.writeByte('\n') catch {};
        }

        while (true) {
            self.refresh(prefix) catch {};
            const value = self.processKey() catch |err| switch (err) {
                error.SIGKILL => return null,
                else => return err,
            };

            if (value) |line| {
                try self.history_manager.pushHistory(line);
                return line;
            }
        }
    }
};
