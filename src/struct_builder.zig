//! playing around with the idea of comptime builder patterns.  This is a bit
//! of a silly thing to create, but it's meant as a tracer bullet to prove out
//! techniques that could be used to construct more sophisticated classes (e.g.
//! an AppBuilder or some such)

const std = @import("std");
const Type = std.builtin.Type;

pub const StructBuilder = struct {
    struct_spec: Type.Struct = @typeInfo(struct {}).@"struct",

    pub fn add_field(
        self: *StructBuilder,
        name: [:0]const u8,
        FieldType: type,
        default_value: ?FieldType,
    ) void {
        var default_value_ptr: ?*const FieldType = null;
        if (default_value != null) {
            const Memo = struct {
                const value: FieldType = default_value.?;
            };
            default_value_ptr = &Memo.value;
        }
        const field_spec = Type.StructField{
            .name = name,
            .type = FieldType,
            .default_value_ptr = @ptrCast(default_value_ptr),
            .is_comptime = false,
            .alignment = @alignOf(FieldType),
        };

        self.struct_spec.fields = self.struct_spec.fields ++ &[_]Type.StructField{field_spec};
    }

    test add_field {
        const t = std.testing;
        const ResultStruct = comptime blk: {
            var builder = StructBuilder{};
            builder.add_field("foo", u8, 42);
            builder.add_field("bar", []const u8, "baz");
            break :blk builder.build();
        };
        try t.expect(@hasField(ResultStruct, "foo"));
        try t.expect(@hasField(ResultStruct, "bar"));
        const result_value = ResultStruct{};
        try t.expectEqual(42, result_value.foo);
        try t.expectEqual("baz", result_value.bar);
    }

    pub fn build(self: StructBuilder) type {
        return @Type(.{ .@"struct" = self.struct_spec });
    }

    test build {
        const t = std.testing;
        const ResultStruct = comptime blk: {
            const builder = StructBuilder{
                .struct_spec = @typeInfo(struct { x: u8 = 42 }).@"struct",
            };
            break :blk builder.build();
        };
        try t.expect(@hasField(ResultStruct, "x"));
        const result_value = ResultStruct{};
        try t.expectEqual(42, result_value.x);
    }
};
