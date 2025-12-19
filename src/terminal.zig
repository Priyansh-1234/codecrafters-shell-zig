const std = @import("std");
const posix = std.posix;

const historyManager = @import("history.zig").historyManager;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub const Terminal = struct {
    const Self = @This();

    original_state: posix.termios,
    state: posix.termios,
    reader: *Reader,
    writer: *Writer,
    history_manager: *historyManager,

    pub fn init(reader: *Reader, writer: *Writer, history_manger: *historyManager) !Self {
        const original: posix.termios = try posix.tcgetattr(posix.STDIN_FILENO);

        return .{
            .state = original,
            .original_state = original,
            .reader = reader,
            .writer = writer,
            .history_manager = history_manger,
        };
    }

    pub fn cooked(self: *const Self) !void {
        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.original_state);
    }

    pub fn raw(self: *Self) !void {
        self.state.lflag.ECHO = false;
        self.state.lflag.ICANON = false;
        self.state.lflag.ISIG = false;
        self.state.lflag.IEXTEN = false;

        self.state.cc[@intFromEnum(posix.V.MIN)] = 1;
        self.state.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.state);
    }
};
