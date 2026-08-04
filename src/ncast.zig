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
            .error_set => @intFromError(value),
            .int, .comptime_int => @intCast(value),
            else => @compileError(comp_err),
        },
        .float => switch (in_info) {
            .int, .comptime_int => @floatFromInt(value),
            .float, .comptime_float => @floatCast(value),
            .bool => @floatFromInt(@intFromBool(value)),
            .@"enum" => @floatFromInt(@intFromEnum(value)),
            .error_set => @floatFromInt(@intFromError(value)),
            else => @compileError(comp_err),
        },
        .@"enum" => switch (in_info) {
            .enum_literal => @as(T, value),
            .int, .comptime_int, .float, .comptime_float, .bool, .@"enum" => @enumFromInt(ncast(out_info.@"enum".tag_type, value)),
            else => @compileError(comp_err),
        },
        .bool => switch (in_info) {
            .bool => value,
            .int, .comptime_int => value != 0,
            .float, .comptime_float => value != 0.0,
            .@"enum" => @intFromEnum(value) != 0,
            else => @compileError(comp_err),
        },
        .error_set => switch (in_info) {
            .int, .comptime_int, .@"enum" => @errorCast(@errorFromInt(ncast(u16, value))),
            .error_set => @errorCast(value),
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

    // Bool to int and float
    try t.expectEqual(@as(i32, 1), ncast(i32, true));
    try t.expectEqual(@as(i32, 0), ncast(i32, false));
    try t.expectEqual(@as(f32, 1.0), ncast(f32, true));

    // Enum to int and float
    const Color = enum(u8) { red = 1, green = 2, blue = 3 };
    try t.expectEqual(@as(i32, 2), ncast(i32, Color.green));
    try t.expectEqual(@as(f32, 2.0), ncast(f32, Color.green));

    // Int, float, bool, enum, enum_literal to Enum
    const OtherColor = enum(u8) { red = 1, green = 2, blue = 3 };
    try t.expectEqual(Color.green, ncast(Color, @as(i32, 2)));
    try t.expectEqual(Color.green, ncast(Color, @as(f32, 2.0)));
    try t.expectEqual(Color.red, ncast(Color, true));
    try t.expectEqual(Color.green, ncast(Color, OtherColor.green));
    try t.expectEqual(Color.green, ncast(Color, .green));

    // Numeric and Enum to Bool
    try t.expectEqual(true, ncast(bool, @as(i32, 42)));
    try t.expectEqual(false, ncast(bool, @as(i32, 0)));
    try t.expectEqual(true, ncast(bool, @as(f32, 3.14)));
    try t.expectEqual(false, ncast(bool, @as(f32, 0.0)));
    try t.expectEqual(true, ncast(bool, Color.green));

    // ErrorSet conversions
    const TestError = error{ BadValue, OutOfMemory };
    const err_int = @intFromError(TestError.BadValue);
    try t.expectEqual(TestError.BadValue, ncast(TestError, err_int));
    try t.expectEqual(err_int, ncast(usize, TestError.BadValue));
    try t.expectEqual(@as(f32, @floatFromInt(err_int)), ncast(f32, TestError.BadValue));
}

test ncast_call {
    const t = std.testing;

    const Color = enum(u8) { red = 1, green = 2, blue = 3 };

    const context = struct {
        fn add(x: f32, y: f32) f32 {
            return x + y;
        }
        fn describe(color: Color, enabled: bool) u8 {
            return if (enabled) @intFromEnum(color) else 0;
        }
    };

    const x: i32 = 2;
    const y: usize = 40;
    const res = ncast_call(context.add, .{ x, y });
    try t.expectEqual(@as(f32, 42), res);

    try t.expectEqual(@as(u8, 2), ncast_call(context.describe, .{ .green, @as(i32, 1) }));
    try t.expectEqual(@as(u8, 0), ncast_call(context.describe, .{ Color.blue, false }));
}
