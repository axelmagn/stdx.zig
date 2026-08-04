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
pub fn numCast(T: type, value: anytype) T {
    const I = @TypeOf(value);
    const in_info = @typeInfo(I);
    const out_info = @typeInfo(T);
    const comp_err = "cannot numCast types: " ++ @typeName(I) ++ " -> " ++ @typeName(T);

    return switch (out_info) {
        .int => switch (in_info) {
            .float, .comptime_float => @intFromFloat(value),
            .bool => @intFromBool(value),
            .@"enum" => @intCast(@intFromEnum(value)),
            .error_set => @intCast(@intFromError(value)),
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
            .int, .comptime_int, .float, .comptime_float, .bool, .@"enum" => @enumFromInt(numCast(out_info.@"enum".tag_type, value)),
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
            .int, .comptime_int, .@"enum" => @errorCast(@errorFromInt(numCast(u16, value))),
            .error_set => @errorCast(value),
            else => @compileError(comp_err),
        },
        else => @compileError(comp_err),
    };
}

/// Call a function after converting numeric arguments
pub fn numCastCall(func: anytype, args: anytype) ret_type(func) {
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
                numCast(@TypeOf(inner_arg), outer_arg);
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

test numCast {
    const t = std.testing;

    // Float to int
    try t.expectEqual(@as(i32, 3), numCast(i32, 3.14));

    // Int to float
    try t.expectEqual(@as(f32, 42.0), numCast(f32, 42));

    // Bool to int and float
    try t.expectEqual(@as(i32, 1), numCast(i32, true));
    try t.expectEqual(@as(i32, 0), numCast(i32, false));
    try t.expectEqual(@as(f32, 1.0), numCast(f32, true));

    // Enum to int and float
    const Color = enum(u8) { red = 1, green = 2, blue = 3 };
    try t.expectEqual(@as(i32, 2), numCast(i32, Color.green));
    try t.expectEqual(@as(f32, 2.0), numCast(f32, Color.green));

    // Int, float, bool, enum, enum_literal to Enum
    const OtherColor = enum(u8) { red = 1, green = 2, blue = 3 };
    try t.expectEqual(Color.green, numCast(Color, @as(i32, 2)));
    try t.expectEqual(Color.green, numCast(Color, @as(f32, 2.0)));
    try t.expectEqual(Color.red, numCast(Color, true));
    try t.expectEqual(Color.green, numCast(Color, OtherColor.green));
    try t.expectEqual(Color.green, numCast(Color, .green));

    // Numeric and Enum to Bool
    try t.expectEqual(true, numCast(bool, @as(i32, 42)));
    try t.expectEqual(false, numCast(bool, @as(i32, 0)));
    try t.expectEqual(true, numCast(bool, @as(f32, 3.14)));
    try t.expectEqual(false, numCast(bool, @as(f32, 0.0)));
    try t.expectEqual(true, numCast(bool, Color.green));

    // ErrorSet conversions
    const TestError = error{ BadValue, OutOfMemory };
    const err_int = @intFromError(TestError.BadValue);
    try t.expectEqual(TestError.BadValue, numCast(TestError, err_int));
    try t.expectEqual(err_int, numCast(usize, TestError.BadValue));
    try t.expectEqual(@as(f32, @floatFromInt(err_int)), numCast(f32, TestError.BadValue));
}

test numCastCall {
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
    const res = numCastCall(context.add, .{ x, y });
    try t.expectEqual(@as(f32, 42), res);

    try t.expectEqual(@as(u8, 2), numCastCall(context.describe, .{ .green, @as(i32, 1) }));
    try t.expectEqual(@as(u8, 0), numCastCall(context.describe, .{ Color.blue, false }));
}

test "numCast type matrix cross-testing" {
    @setEvalBranchQuota(10_000);
    const t = std.testing;

    const IntTypes = .{ u8, u16, u32, u64, i8, i16, i32, i64, usize, isize };
    const FloatTypes = .{ f16, f32, f64 };
    const E1 = enum(u8) { alpha = 1, beta = 2 };
    const E2 = enum(i32) { neg = -10, pos = 20 };
    const Err1 = error{ Failure, OutOfMemory };
    const Err2 = error{ InvalidParam, Timeout };

    // Consolidated test value datasets
    const int_test_values = .{ 0, 1, 42, 100, 127, -1, -50, -128 };
    const float_test_values = .{ 0.0, 1.0, 2.5, 3.14, 100.5, -1.0, -42.25 };
    const bool_test_values = .{ true, false };
    const enum_test_values = .{ E1.alpha, E1.beta, E2.neg, E2.pos };
    const error_test_values = .{ Err1.Failure, Err1.OutOfMemory, Err2.InvalidParam, Err2.Timeout };

    // Int <-> Int cross conversion matrix
    inline for (IntTypes) |InT| {
        inline for (IntTypes) |OutT| {
            inline for (int_test_values) |v| {
                if (v >= std.math.minInt(InT) and v <= std.math.maxInt(InT) and
                    v >= std.math.minInt(OutT) and v <= std.math.maxInt(OutT))
                {
                    const in_val: InT = @intCast(v);
                    const out_val: OutT = @intCast(v);
                    try t.expectEqual(out_val, numCast(OutT, in_val));
                }
            }
        }
    }

    // Int <-> Float cross conversion matrix
    inline for (IntTypes) |InT| {
        inline for (FloatTypes) |OutF| {
            inline for (int_test_values) |v| {
                if (v >= std.math.minInt(InT) and v <= std.math.maxInt(InT)) {
                    const in_val: InT = @intCast(v);
                    const res_f = numCast(OutF, in_val);
                    try t.expectEqual(@as(OutF, @floatFromInt(v)), res_f);
                    const res_back = numCast(InT, res_f);
                    try t.expectEqual(in_val, res_back);
                }
            }
        }
    }

    // Float <-> Float cross conversion matrix
    inline for (FloatTypes) |InF| {
        inline for (FloatTypes) |OutF| {
            inline for (float_test_values) |v| {
                const in_val: InF = v;
                const res = numCast(OutF, in_val);
                try t.expectEqual(@as(OutF, @floatCast(in_val)), res);
            }
        }
    }

    // Int/Float -> Bool matrix
    inline for (IntTypes) |InT| {
        inline for (int_test_values) |v| {
            if (v >= std.math.minInt(InT) and v <= std.math.maxInt(InT)) {
                const in_val: InT = @intCast(v);
                try t.expectEqual(v != 0, numCast(bool, in_val));
            }
        }
    }
    inline for (FloatTypes) |InF| {
        inline for (float_test_values) |v| {
            const in_val: InF = v;
            try t.expectEqual(v != 0.0, numCast(bool, in_val));
        }
    }

    // Bool -> Int / Float matrix
    inline for (bool_test_values) |b| {
        inline for (IntTypes) |OutInt| {
            const expected: OutInt = if (b) 1 else 0;
            try t.expectEqual(expected, numCast(OutInt, b));
        }
        inline for (FloatTypes) |OutFloat| {
            const expected: OutFloat = if (b) 1.0 else 0.0;
            try t.expectEqual(expected, numCast(OutFloat, b));
        }
    }

    // Enum <-> Int / Float / Bool matrix across all enum fields
    inline for (enum_test_values) |val| {
        const ET = @TypeOf(val);
        const tag = @intFromEnum(val);

        inline for (IntTypes) |OutInt| {
            if (tag >= std.math.minInt(OutInt) and tag <= std.math.maxInt(OutInt)) {
                try t.expectEqual(numCast(OutInt, tag), numCast(OutInt, val));
                try t.expectEqual(val, numCast(ET, numCast(OutInt, val)));
            }
        }
        inline for (FloatTypes) |OutFloat| {
            try t.expectEqual(numCast(OutFloat, tag), numCast(OutFloat, val));
            try t.expectEqual(val, numCast(ET, numCast(OutFloat, val)));
        }
        try t.expectEqual(tag != 0, numCast(bool, val));
    }

    // ErrorSet <-> Int / Float / ErrorSet matrix across all error fields
    inline for (error_test_values) |err_val| {
        const ErrT = @TypeOf(err_val);
        const err_code = @intFromError(err_val);

        inline for (IntTypes) |OutInt| {
            if (err_code >= std.math.minInt(OutInt) and err_code <= std.math.maxInt(OutInt)) {
                try t.expectEqual(numCast(OutInt, err_code), numCast(OutInt, err_val));
                try t.expectEqual(err_val, numCast(ErrT, numCast(OutInt, err_val)));
            }
        }
        inline for (FloatTypes) |OutFloat| {
            try t.expectEqual(numCast(OutFloat, err_code), numCast(OutFloat, err_val));
        }
    }
}

test "numCast algebraic property invariants" {
    const t = std.testing;

    const IntTypes = .{ u8, u16, u32, u64, i8, i16, i32, i64, usize, isize };
    const FloatTypes = .{ f16, f32, f64 };

    const Status = enum(u8) { ok = 0, warn = 1, err = 2 };
    const Command = enum(i32) { start = -100, stop = 200 };
    const AppError = error{ OutOfMemory, InvalidValue, Timeout };

    // 1. Identity Property across all types
    inline for (IntTypes) |T| {
        const val: T = 7;
        try t.expectEqual(val, numCast(T, val));
    }
    inline for (FloatTypes) |T| {
        const val: T = 3.5;
        try t.expectEqual(val, numCast(T, val));
    }
    try t.expectEqual(Status.warn, numCast(Status, Status.warn));
    try t.expectEqual(true, numCast(bool, true));
    try t.expectEqual(false, numCast(bool, false));
    try t.expectEqual(AppError.Timeout, numCast(AppError, AppError.Timeout));

    // 2. Enum tag equivalence & Enum literal coercion
    try t.expectEqual(@as(u8, 1), numCast(u8, Status.warn));
    try t.expectEqual(Status.warn, numCast(Status, @as(u8, 1)));
    try t.expectEqual(Status.warn, numCast(Status, .warn));
    try t.expectEqual(Command.start, numCast(Command, @as(i32, -100)));
    try t.expectEqual(Command.start, numCast(Command, .start));

    // 3. Error set integer roundtrip
    const err = AppError.InvalidValue;
    const err_code = numCast(u16, err);
    try t.expectEqual(err, numCast(AppError, err_code));
    try t.expectEqual(err, numCast(anyerror, err_code));

    // 4. Lossless transitivity: u8 -> u32 -> u64
    const original: u8 = 200;
    const step1 = numCast(u32, original);
    const step2 = numCast(u64, step1);
    const direct = numCast(u64, original);
    try t.expectEqual(direct, step2);
}

test "numCast randomized fuzzing" {
    const t = std.testing;
    var prng = std.Random.DefaultPrng.init(0xDECAFBAD);
    const random = prng.random();

    const Color = enum(u8) { red = 1, green = 2, blue = 3 };
    const FuzzError = error{ OutOfMemory, InvalidValue, Timeout };

    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const val_u8 = random.int(u8);

        // Int -> Float -> Int roundtrip
        const flt = numCast(f32, val_u8);
        const back = numCast(u8, flt);
        try t.expectEqual(val_u8, back);

        // Int -> Bool non-zero invariant
        const b = numCast(bool, val_u8);
        try t.expectEqual(val_u8 != 0, b);

        // Int widening & narrowing preservation
        const val_u32 = numCast(u32, val_u8);
        const val_i64 = numCast(i64, val_u32);
        const back_u8 = numCast(u8, val_i64);
        try t.expectEqual(val_u8, back_u8);

        // Enum roundtrip fuzzing
        const tag = random.uintLessThan(u8, 3) + 1;
        const color = numCast(Color, tag);
        try t.expectEqual(tag, numCast(u8, color));

        // Error set roundtrip fuzzing
        const err_sample: FuzzError = if (val_u8 % 2 == 0) FuzzError.OutOfMemory else FuzzError.Timeout;
        const err_num = numCast(usize, err_sample);
        try t.expectEqual(err_sample, numCast(FuzzError, err_num));
    }
}
