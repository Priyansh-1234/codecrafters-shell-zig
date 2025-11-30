const std = @import("std");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;
const HashMap = std.AutoHashMap;
const ArrayList = std.ArrayList;

const assert = std.debug.assert;

pub const Trie = struct {
    const Self = @This();

    root: *Node,
    allocator: Allocator,

    const Node = struct {
        children: HashMap(u8, *Node),
        is_end: bool,

        pub fn init(allocator: Allocator) !*Node {
            const self = try allocator.create(Node);
            self.* = .{
                .children = HashMap(u8, *Node).init(allocator),
                .is_end = false,
            };

            return self;
        }

        pub fn deinit(self: *Node, allocator: Allocator) void {
            var it = self.children.iterator();
            while (it.next()) |entry| {
                const child = entry.value_ptr.*;
                child.deinit(allocator);
                allocator.destroy(child);
            }
            self.children.deinit();
        }
    };

    pub fn init(allocator: Allocator) !Self {
        return .{
            .allocator = allocator,
            .root = try Node.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.root.deinit(self.allocator);
        self.allocator.destroy(self.root);
    }

    pub fn insert(self: *Self, key: []const u8) !void {
        var current = self.root;

        for (key[0..]) |ch| {
            if (current.children.get(ch)) |child| {
                current = child;
            } else {
                const new = try Node.init(self.allocator);
                try current.children.put(ch, new);
                current = new;
            }
        }

        current.is_end = true;
    }

    pub fn contains(self: *const Self, key: []const u8) bool {
        var current = self.root;

        for (key[0..]) |ch| {
            const child = current.children.get(ch) orelse return false;
            current = child;
        }

        return current.is_end;
    }

    pub fn startsWith(self: *const Self, prefix: []const u8) bool {
        var current = self.root;
        for (prefix[0..]) |ch| {
            const child = current.children.get(ch) orelse return false;
            current = child;
        }
        return true;
    }

    pub fn complete(self: *const Self, prefix: []const u8, allocator: Allocator) !?utils.autofillSuggestion {
        var current = self.root;
        for (prefix) |ch| {
            const child = current.children.get(ch) orelse return null;
            current = child;
        }

        var result: ArrayList([]u8) = .empty;
        defer result.deinit(allocator);

        var buffer: ArrayList(u8) = .empty;
        defer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, prefix[0..]);
        if (current.is_end) {
            try result.append(allocator, try allocator.dupe(u8, buffer.items));
        }

        while (current.children.count() == 1) {
            var keyIter = current.children.keyIterator();
            const key = keyIter.next() orelse unreachable;
            const child = current.children.get(key.*) orelse unreachable;

            try buffer.append(allocator, key.*);
            current = child;

            if (child.is_end) break;
        }

        if (current.children.count() > 1) {
            try self.trieDFS(current, &buffer, &result, allocator);
        }

        if (current.children.count() == 0) {
            try buffer.append(allocator, ' ');
        }

        return .{
            .suggestions = try result.toOwnedSlice(allocator),
            .autofill = try buffer.toOwnedSlice(allocator),
        };
    }
    fn trieDFS(self: *const Self, node: *Node, buffer: *ArrayList(u8), result: *ArrayList([]u8), allocator: Allocator) !void {
        if (node.children.count() == 0) {
            try result.append(allocator, try allocator.dupe(u8, buffer.items));
            return;
        }

        var keys: ArrayList(u8) = .empty;
        defer keys.deinit(allocator);

        var iter = node.children.keyIterator();
        while (iter.next()) |key| {
            try keys.append(allocator, key.*);
        }

        std.mem.sort(u8, keys.items[0..], {}, std.sort.asc(u8));

        for (keys.items[0..]) |key| {
            const child = node.children.get(key) orelse unreachable;

            try buffer.append(allocator, key);

            if (child.is_end and child.children.count() > 0) {
                try result.append(allocator, try allocator.dupe(u8, buffer.items));
            }

            try self.trieDFS(child, buffer, result, allocator);

            _ = buffer.pop();
        }
    }
};
