//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const num_cast = @import("num_cast.zig");

test {
    std.testing.refAllDecls(@This());
}
