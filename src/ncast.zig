//! casting utilities
const std = @import("std");

const ArgsTuple = std.meta.ArgsTuple;
const assert = std.debug.assert;

/// cast between numeric types.
///
/// This function aims to convert between numeric types using the appropriate
/// function that feels intuitive and obvious to the author.  This generally
/// works out to roughly resemble the rules of implicit numeric conversion in
/// C.
///
/// does not accept pointers, as their casting path is often ambiguous.
pub fn ncast(T: type, value: anytype) T {
    const I = @TypeOf(value);
    const in_info = @typeInfo(I);
    const out_info = @typeInfo(T);
    const comp_err = "cannot ncast types: " ++ @typeName(I) ++ " -> " ++ @typeName(T);

    return switch (out_info) {
        .int => switch (in_info) {
            .float, .comptime_float => @intFromFloat(value),
            .bool => @intFromBool(value),
            .@"enum" => @intFromEnum(value),
            .error_set, .error_union => @intFromError(value),
            .int, .comptime_int => @intCast(value),
            else => @compileError(comp_err),
        },
        .float => switch (in_info) {
            .int, .comptime_int => @floatFromInt(value),
            .float, .comptime_float => @floatCast(value),
            .bool => @floatFromInt(@intFromBool(value)),
            .@"enum" => @floatFromInt(@intFromEnum(value)),
            else => @compileError(comp_err),
        },
        else => @compileError(comp_err),
    };
}

/// Call a function after converting numeric arguments
pub fn ncast_call(func: anytype, args: anytype) ret_type(func) {
    const F = @TypeOf(func);
    comptime {
        const finfo = @typeInfo(F);
        assert(finfo == .@"fn");
    }

    const outer_args = args;
    comptime {
        const OuterArgs = @TypeOf(args);
        const outer_args_tinfo = @typeInfo(OuterArgs);
        assert(outer_args_tinfo == .@"struct");
        assert(outer_args_tinfo.@"struct".is_tuple);
    }

    const InnerArgs = ArgsTuple(F);
    var inner_args: InnerArgs = undefined;
    comptime {
        const inner_args_tinfo = @typeInfo(InnerArgs);
        assert(inner_args_tinfo == .@"struct");
        assert(inner_args_tinfo.@"struct".is_tuple);
        assert(args.len == inner_args.len);
    }

    inline for (outer_args, inner_args, 0..) |outer_arg, inner_arg, i| {
        inner_args[i] =
            if (@TypeOf(outer_arg) == @TypeOf(inner_arg))
                outer_arg
            else
                ncast(@TypeOf(inner_arg), outer_arg);
    }

    return @call(.auto, func, inner_args);
}

fn ret_type(func: anytype) type {
    const F = @TypeOf(func);
    const finfo = @typeInfo(F);
    comptime {
        assert(finfo == .@"fn");
    }
    return finfo.@"fn".return_type orelse void;
}

test ncast {
    const t = std.testing;

    // Float to int
    try t.expectEqual(@as(i32, 3), ncast(i32, 3.14));

    // Int to float
    try t.expectEqual(@as(f32, 42.0), ncast(f32, 42));

    // Bool to int
    try t.expectEqual(@as(i32, 1), ncast(i32, true));
    try t.expectEqual(@as(i32, 0), ncast(i32, false));

    // bool to float
    try t.expectEqual(@as(f32, 1.0), ncast(f32, true));

    // Enum to int
    const Color = enum(u8) { red = 1, green = 2, blue = 3 };
    try t.expectEqual(@as(i32, 2), ncast(i32, Color.green));

    // enum to float
    try t.expectEqual(@as(f32, 2.0), ncast(f32, Color.green));
}

test ncast_call {
    const t = std.testing;

    const context = struct {
        fn add(x: f32, y: f32) f32 {
            return x + y;
        }
    };

    const x: i32 = 2;
    const y: usize = 40;
    const res = ncast_call(context.add, .{ x, y });
    try t.expectEqual(@as(f32, 42), res);
}
