//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const ncast = @import("ncast.zig");
pub const mem = @import("mem.zig");

test {
    std.testing.refAllDeclsRecursive(@This());
}
