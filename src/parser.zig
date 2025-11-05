const std = @import("std");

pub fn validateString(arg_str: []const u8) bool {
    var in_single_quotes = false;
    var in_double_quotes = false;

    for (arg_str[0..]) |c| {
        switch (c) {
            '\'' => {
                if (in_double_quotes) continue;
                in_single_quotes = !in_single_quotes;
            },
            '"' => {
                if (in_single_quotes) continue;
                in_double_quotes = !in_double_quotes;
            },
            else => continue,
        }
    }

    return !in_single_quotes and !in_double_quotes;
}

pub fn parseArgs(allocator: std.mem.Allocator, arg_str: []const u8) !std.ArrayList([]const u8) {
    if (!validateString(arg_str)) {
        return error.NotValidLine;
    }

    var result: std.ArrayList([]const u8) = .empty;
    var stringBuilder: std.ArrayList(u8) = .empty;
    defer stringBuilder.deinit(allocator);

    var in_single_quotes: bool = false;
    var in_double_quotes: bool = false;

    var i: usize = 0;
    while (i < arg_str.len) : (i += 1) {
        const c = arg_str[i];
        switch (c) {
            '\\' => {
                if (!in_single_quotes and !in_double_quotes and i < arg_str.len - 1) {
                    const nc = arg_str[i + 1];
                    try stringBuilder.append(allocator, nc);

                    i += 1;
                } else {
                    try stringBuilder.append(allocator, c);
                }
            },
            '\'' => {
                if (in_double_quotes) {
                    try stringBuilder.append(allocator, '\'');
                } else {
                    in_single_quotes = !in_single_quotes;
                }
            },
            '"' => {
                if (in_single_quotes) {
                    try stringBuilder.append(allocator, '"');
                } else {
                    in_double_quotes = !in_double_quotes;
                }
            },
            ' ', '\t'...'\r' => {
                if (in_single_quotes or in_double_quotes) {
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
