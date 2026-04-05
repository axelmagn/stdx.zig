//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const ncast = @import("ncast.zig");
// BROKEN - needs rewrite?
pub const mem = @import("mem.zig");
pub const struct_builder = @import("struct_builder.zig");

test {
    std.testing.refAllDeclsRecursive(@This());
}
