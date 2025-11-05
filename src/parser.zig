const std = @import("std");

pub fn validateString(arg_str: []const u8) bool {
    const count = std.mem.count(u8, arg_str, "'");
    return count % 2 == 0;
}

pub fn parseArgs(allocator: std.mem.Allocator, arg_str: []const u8) !std.ArrayList([]const u8) {
    if (!validateString(arg_str)) {
        return error.NotValidLine;
    }

    var result: std.ArrayList([]const u8) = .empty;
    var stringBuilder: std.ArrayList(u8) = .empty;
    defer stringBuilder.deinit(allocator);

    var in_quotes: bool = false;

    for (arg_str[0..]) |c| {
        switch (c) {
            '\'' => {
                in_quotes = !in_quotes;
            },
            ' ', '\t'...'\r' => {
                if (in_quotes) {
                    try stringBuilder.append(allocator, c);
                } else {
                    if (stringBuilder.items.len == 0) continue;

                    const arg = try stringBuilder.toOwnedSlice(allocator);
                    try result.append(allocator, arg);

                    stringBuilder.clearAndFree(allocator);
                }
            },
            else => {
                try stringBuilder.append(allocator, c);
            },
        }
    }

    if (stringBuilder.items.len > 0) {
        const arg = try stringBuilder.toOwnedSlice(allocator);
        try result.append(allocator, arg);
    }

    return result;
}
