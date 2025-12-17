const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Command = struct {
    argv: []const []const u8,
};

const ParseError = error{
    InvalidLine,
    InvalidPipe,
};

pub fn validateString(arg_str: []const u8) bool {
    var in_single_quotes = false;
    var in_double_quotes = false;

    var i: usize = 0;
    while (i < arg_str.len) : (i += 1) {
        const c = arg_str[i];
        switch (c) {
            '\\' => {
                if (i < arg_str.len - 1) {
                    const nc = arg_str[i + 1];
                    switch (nc) {
                        '"', '\\' => {
                            i += 1;
                        },
                        else => continue,
                    }
                }
            },
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

pub fn parseArgs(allocator: std.mem.Allocator, arg_str: []const u8) (Allocator.Error || ParseError)![][]const u8 {
    if (!validateString(arg_str)) {
        return error.InvalidLine;
    }

    var result: std.ArrayList([]const u8) = .empty;
    defer result.deinit(allocator);

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
                    defer i += 1;

                    try stringBuilder.append(allocator, nc);
                } else if (in_double_quotes and i < arg_str.len - 1) {
                    const nc = arg_str[i + 1];

                    switch (nc) {
                        '"' => {
                            try stringBuilder.append(allocator, '"');
                            i += 1;
                        },
                        '\\' => {
                            try stringBuilder.append(allocator, '\\');
                            i += 1;
                        },
                        else => {
                            try stringBuilder.append(allocator, c);
                        },
                    }
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
            '|' => {
                if (in_single_quotes or in_double_quotes) {
                    try stringBuilder.append(allocator, c);
                } else {
                    if (stringBuilder.items.len != 0) {
                        const arg = try stringBuilder.toOwnedSlice(allocator);
                        try result.append(allocator, arg);
                    }

                    try result.append(allocator, try allocator.dupe(u8, "|"));
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

    return try result.toOwnedSlice(allocator);
}

pub fn parseCommands(allocator: Allocator, args: []const []const u8) (Allocator.Error || ParseError)![]Command {
    var result: std.ArrayList(Command) = .empty;
    defer result.deinit(allocator);

    var commandBuilder: std.ArrayList([]const u8) = .empty;
    defer commandBuilder.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.containsAtLeastScalar(u8, arg, 1, '>')) {
            i += 1;
            continue;
        }

        if (std.mem.eql(u8, arg, "|")) {
            if (commandBuilder.items.len == 0) {
                return error.InvalidPipe;
            }

            try result.append(
                allocator,
                Command{ .argv = try commandBuilder.toOwnedSlice(allocator) },
            );
        } else {
            try commandBuilder.append(allocator, arg);
        }
    }
    if (commandBuilder.items.len == 0) {
        return error.InvalidPipe;
    }
    try result.append(allocator, Command{ .argv = try commandBuilder.toOwnedSlice(allocator) });

    return try result.toOwnedSlice(allocator);
}
