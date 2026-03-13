const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;

const StringInternPool = struct {
    string_index: std.StringHashMapUnmanaged(StringId),
    string_data: std.ArrayListUnmanaged(u8),

    pub const StringId = usize;
    const Self = @This();

    pub fn intern(self: *Self, gpa: Allocator, string: []const u8) !StringId {
        // if the string is already stored, return it
        if (self.string_index.get(string)) |existing_id| return existing_id;
    }
};
