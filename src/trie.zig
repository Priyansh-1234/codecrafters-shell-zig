const std = @import("std");
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

    pub fn complete(self: *const Self, prefix: []const u8) !?[]const u8 {
        var current = self.root;
        for (prefix) |ch| {
            const child = current.children.get(ch) orelse return null;
            current = child;
        }

        var result: ArrayList(u8) = .empty;
        defer result.deinit(self.allocator);

        try result.appendSlice(self.allocator, prefix);

        if (current.is_end) {
            return try result.toOwnedSlice(self.allocator);
        }

        if (try self.dfsFirst(current, &result)) {
            return try result.toOwnedSlice(self.allocator);
        }

        return null;
    }

    fn dfsFirst(self: *const Self, node: *Node, buffer: *ArrayList(u8)) !bool {
        var keys: ArrayList(u8) = .empty;
        defer keys.deinit(self.allocator);

        var it = node.children.keyIterator();
        while (it.next()) |key| {
            try keys.append(self.allocator, key.*);
        }

        std.mem.sort(u8, keys.items[0..], {}, std.sort.asc(u8));

        for (keys.items[0..]) |key| {
            const child = node.children.get(key) orelse unreachable;

            try buffer.append(self.allocator, key);

            if (child.is_end) {
                return true;
            }

            if (try self.dfsFirst(child, buffer)) {
                return true;
            }

            _ = buffer.pop();
        }

        return false;
    }
};
