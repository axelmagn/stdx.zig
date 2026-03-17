//! Useful allocators and memory utils.  These are mostly general-purpose
//! allocators that sit on top of fixed memory buffers, since that's the main
//! gap in the standard library.

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;

const test_buddy_allocator_memory_size = (1 << 20) * @sizeOf(u64);
var test_buddy_allocator_memory: [test_buddy_allocator_memory_size]u8 align(test_buddy_allocator_memory_size) = undefined;

pub const BuddyAllocatorOptions = struct {
    // by default, align to CPU cache
    block_size: usize = std.atomic.cache_line,
};

pub const BuddyAllocator = struct {
    buffer: []u8,
    min_block_size: usize,

    pub const InitError = error{
        invalid_buffer_size,
        invalid_buffer_align,
        invalid_min_block_size,
    };

    const BlockState = enum(u1) {
        free = 0,
        used = 1,

        fn asBool(self: BlockState) bool {
            return @intFromEnum(self) > 0;
        }
    };

    /// usage tracker for blocks in the allocator
    /// TODO: replace with max tree
    const BlockTree = struct {
        bits: std.DynamicBitSetUnmanaged,
        min_block_size: usize,
        max_block_size: usize,

        /// create a block tree view for a buffer, overlapping the start of the
        /// buffer.
        fn viewFromBuffer(buffer: []u8, min_block_size: usize) BlockTree {
            assert(std.math.isPowerOfTwo(buffer.len));
            assert(std.math.isPowerOfTwo(min_block_size));
            assert(std.mem.isAligned(@intFromPtr(buffer.ptr), min_block_size));
            var bits = std.DynamicBitSetUnmanaged{};
            assert(std.mem.isAligned(
                @intFromPtr(buffer.ptr),
                @alignOf(std.DynamicBitSetUnmanaged.MaskInt),
            ));
            bits.masks = @ptrCast(@alignCast(buffer.ptr));
            bits.bit_length = calcTotalSize(calcTotalDepth(min_block_size, buffer.len));
            const self = BlockTree{
                .bits = bits,
                .min_block_size = min_block_size,
                .max_block_size = buffer.len,
            };
            assert(self.getSizeBytes() <= buffer.len);
            return self;
        }

        test viewFromBuffer {
            const t = std.testing;
            // var buf align(64) = [_]u8{0} ** 1024;
            var buf: [1024]u8 align(64) = undefined;
            // std.debug.print("type of buf: {s}\n", .{@typeName(@TypeOf(buf))});
            const block_tree = viewFromBuffer(&buf, 64);
            try t.expectEqual(@intFromPtr(&buf), @intFromPtr(block_tree.bits.masks));
            try t.expectEqual(31, block_tree.bits.bit_length);
        }

        fn isIndexValid(self: *const BlockTree, index: usize) bool {
            return index < self.getSizeBits();
        }

        /// check if an index is marked as free
        fn isFree(self: *const BlockTree, index: usize) bool {
            return !self.bits.isSet(index);
        }

        /// set the free value for an index
        fn setIndex(self: *BlockTree, index: usize, value: BlockState) void {
            self.bits.setValue(index, value.asBool());
        }

        /// set the free value for a range
        fn setRange(self: *BlockTree, start_index: usize, end_index: usize, value: BlockState) void {
            const range = std.bit_set.Range{ .start = start_index, .end = end_index };
            self.bits.setRangeValue(range, value.asBool());
        }

        /// set the free value for all bits
        fn setAll(self: *BlockTree, value: BlockState) void {
            if (value.asBool()) {
                self.bits.setAll();
            } else {
                self.bits.unsetAll();
            }
        }

        fn getSizeBits(self: *const BlockTree) usize {
            return self.bits.bit_length;
        }

        fn getSizeBytes(self: *const BlockTree) usize {
            var bytes = @divTrunc(self.bits.bit_length, 8);
            const rem = @mod(self.bits.bit_length, 8);
            if (rem > 0) {
                bytes += 1;
            }
            return bytes;
        }

        fn getTotalDepth(self: *const BlockTree) usize {
            return calcTotalDepth(self.min_block_size, self.max_block_size);
        }

        fn getIndexOffset(self: *const BlockTree, index: usize) usize {
            return BlockTree.calcIndexOffset(index, self.max_block_size);
        }

        fn getOffsetIndex(self: *const BlockTree, offset: usize, size: usize) usize {
            return BlockTree.calcOffsetIndex(
                offset,
                size,
                self.min_block_size,
                self.max_block_size,
            );
        }

        fn markBlockAsUsed(self: *BlockTree, index: usize) void {
            assert(self.isIndexValid(index));
            // mark index and all parents as used
            var curr_index: usize = index;
            while (true) {
                // stop early for parents already in use
                if (!self.isFree(curr_index)) break;
                self.setIndex(curr_index, .used);
                if (curr_index == 0) break;

                const parent_index = calcParentIndex(curr_index);
                assert(parent_index < curr_index);
                curr_index = parent_index;
            }
            // mark chilren as used
            var left_child_index = calcLeftChildIndex(index);
            assert(left_child_index > index);
            var right_child_index = calcRightChildIndex(index);
            assert(right_child_index > index);

            while (self.isIndexValid(left_child_index)) {
                assert(self.isIndexValid(right_child_index));
                assert(right_child_index > left_child_index);
                self.setRange(left_child_index, right_child_index + 1, .used);
                left_child_index = calcLeftChildIndex(left_child_index);
                right_child_index = calcRightChildIndex(right_child_index);
            }
        }

        fn markBlockAsFree(self: *BlockTree, index: usize) void {
            assert(self.isIndexValid(index));

            // mark index as free
            self.setIndex(index, .free);

            // mark chilren as free
            var left_child_index = calcLeftChildIndex(index);
            assert(left_child_index > index);
            var right_child_index = calcRightChildIndex(index);
            assert(right_child_index > index);

            while (self.isIndexValid(left_child_index)) {
                assert(self.isIndexValid(right_child_index));
                assert(right_child_index > left_child_index);
                self.setRange(left_child_index, right_child_index + 1, .free);
                left_child_index = calcLeftChildIndex(left_child_index);
                right_child_index = calcRightChildIndex(right_child_index);
            }

            // mark index and parents as free
            if (index == 0) return;
            var curr_index = calcParentIndex(index);
            assert(self.isIndexValid(curr_index));
            while (true) : (curr_index = calcParentIndex(curr_index)) {
                left_child_index = calcLeftChildIndex(curr_index);
                assert(self.isIndexValid(left_child_index));
                right_child_index = calcRightChildIndex(curr_index);
                assert(self.isIndexValid(right_child_index));
                if (!self.isFree(left_child_index) or
                    !self.isFree(right_child_index)) break;
                self.setIndex(curr_index, .free);
                if (curr_index == 0) break;
            }
        }

        test "markBlockAsUsed and markBlockAsFree" {
            const t = std.testing;
            var buf: [1024]u8 align(64) = [_]u8{0} ** 1024;
            var block_tree = viewFromBuffer(&buf, 64);

            try t.expect(block_tree.isFree(3));

            block_tree.markBlockAsUsed(3);

            try t.expect(!block_tree.isFree(0));

            try t.expect(!block_tree.isFree(1));
            try t.expect(block_tree.isFree(2));

            try t.expect(!block_tree.isFree(3));
            try t.expect(block_tree.isFree(4));
            try t.expect(block_tree.isFree(5));
            try t.expect(block_tree.isFree(6));

            try t.expect(!block_tree.isFree(7));
            try t.expect(!block_tree.isFree(8));
            try t.expect(block_tree.isFree(9));
            try t.expect(block_tree.isFree(10));

            block_tree.markBlockAsUsed(5);

            try t.expect(!block_tree.isFree(0));

            try t.expect(!block_tree.isFree(1));
            try t.expect(!block_tree.isFree(2));

            try t.expect(!block_tree.isFree(3));
            try t.expect(block_tree.isFree(4));
            try t.expect(!block_tree.isFree(5));
            try t.expect(block_tree.isFree(6));

            try t.expect(!block_tree.isFree(7));
            try t.expect(!block_tree.isFree(8));
            try t.expect(block_tree.isFree(9));
            try t.expect(block_tree.isFree(10));

            block_tree.markBlockAsFree(3);

            try t.expect(!block_tree.isFree(0));

            try t.expect(block_tree.isFree(1));
            try t.expect(!block_tree.isFree(2));

            try t.expect(block_tree.isFree(3));
            try t.expect(block_tree.isFree(4));
            try t.expect(!block_tree.isFree(5));
            try t.expect(block_tree.isFree(6));

            try t.expect(block_tree.isFree(7));
            try t.expect(block_tree.isFree(8));
            try t.expect(block_tree.isFree(9));
            try t.expect(block_tree.isFree(10));
        }

        // ------------------------------------------------------------
        // tree math
        // ------------------------------------------------------------

        /// calculate the total depth of the tree
        fn calcTotalDepth(min_block_size: usize, max_block_size: usize) usize {
            assert(min_block_size > 0);
            assert(max_block_size >= min_block_size);
            assert(std.math.isPowerOfTwo(min_block_size));
            assert(std.math.isPowerOfTwo(max_block_size));

            const minblock_lzero = @clz(min_block_size);
            const maxblock_lzero = @clz(max_block_size);
            assert(minblock_lzero >= maxblock_lzero);
            return minblock_lzero - maxblock_lzero + 1;
        }

        test calcTotalDepth {
            const t = std.testing;
            try t.expectEqual(1, calcTotalDepth(1024, 1024));
            try t.expectEqual(2, calcTotalDepth(512, 1024));
            try t.expectEqual(3, calcTotalDepth(256, 1024));
            try t.expectEqual(4, calcTotalDepth(128, 1024));
        }

        /// calculate the total size of the tree in bits
        fn calcTotalSize(depth: usize) usize {
            return std.math.shl(usize, 1, depth) - 1;
        }

        test calcTotalSize {
            const t = std.testing;
            try t.expectEqual(1, calcTotalSize(1));
            try t.expectEqual(3, calcTotalSize(2));
            try t.expectEqual(7, calcTotalSize(3));
            try t.expectEqual(15, calcTotalSize(4));
            try t.expectEqual(31, calcTotalSize(5));
            try t.expectEqual(63, calcTotalSize(6));
            try t.expectEqual(31, calcTotalSize(calcTotalDepth(64, 1024)));
        }

        fn calcBlockSize(requested_size: usize, min_block_size: usize) usize {
            assert(requested_size >= 0);
            assert(min_block_size > 0);
            return std.math.ceilPowerOfTwo(
                usize,
                @max(requested_size, min_block_size),
            ) catch |err| {
                panic("unexpected error: {}", .{err});
            };
        }

        test calcBlockSize {
            const t = std.testing;
            try t.expectEqual(64, calcBlockSize(32, 64));
            try t.expectEqual(64, calcBlockSize(61, 64));
            try t.expectEqual(128, calcBlockSize(90, 64));
            try t.expectEqual(128, calcBlockSize(128, 64));
            try t.expectEqual(256, calcBlockSize(200, 64));
            try t.expectEqual(256, calcBlockSize(256, 64));
            try t.expectEqual(512, calcBlockSize(400, 64));
            try t.expectEqual(512, calcBlockSize(512, 64));
        }

        /// calculate the block depth for a requested size
        fn calcBlockDepth(
            requested_size: usize,
            min_block_size: usize,
            max_block_size: usize,
        ) usize {
            assert(requested_size >= 0);
            assert(min_block_size > 0);
            assert(max_block_size >= min_block_size);
            const block_size = calcBlockSize(requested_size, min_block_size);
            assert(block_size >= min_block_size);
            assert(block_size <= max_block_size);

            return calcTotalDepth(block_size, max_block_size) - 1;
        }

        test calcBlockDepth {
            const t = std.testing;
            try t.expectEqual(0, calcBlockDepth(1024, 64, 1024));
            try t.expectEqual(0, calcBlockDepth(1000, 64, 1024));
            try t.expectEqual(0, calcBlockDepth(800, 64, 1024));
            try t.expectEqual(1, calcBlockDepth(512, 64, 1024));
            try t.expectEqual(1, calcBlockDepth(500, 64, 1024));
            try t.expectEqual(1, calcBlockDepth(400, 64, 1024));
            try t.expectEqual(2, calcBlockDepth(256, 64, 1024));
            try t.expectEqual(2, calcBlockDepth(200, 64, 1024));
            try t.expectEqual(2, calcBlockDepth(150, 64, 1024));
            try t.expectEqual(3, calcBlockDepth(128, 64, 1024));
            try t.expectEqual(3, calcBlockDepth(100, 64, 1024));
            try t.expectEqual(4, calcBlockDepth(64, 64, 1024));
            try t.expectEqual(4, calcBlockDepth(32, 64, 1024));
            try t.expectEqual(4, calcBlockDepth(16, 64, 1024));
            // try t.expectEqual(4, calcBlockDepth(8, 64, 1024));
            try t.expectEqual(4, calcBlockDepth(9, 64, 1024));
        }

        fn calcDepthSize(depth: usize, max_block_size: usize) usize {
            return std.math.shr(usize, max_block_size, depth);
        }

        test calcDepthSize {
            const t = std.testing;
            try t.expectEqual(1024, calcDepthSize(0, 1024));
            try t.expectEqual(512, calcDepthSize(1, 1024));
            try t.expectEqual(256, calcDepthSize(2, 1024));
            try t.expectEqual(128, calcDepthSize(3, 1024));
        }

        fn calcDepthStartIndex(depth: usize) usize {
            return std.math.shl(usize, 1, depth) - 1;
        }

        test calcDepthStartIndex {
            const t = std.testing;
            try t.expectEqual(0, calcDepthStartIndex(0));
            try t.expectEqual(1, calcDepthStartIndex(1));
            try t.expectEqual(3, calcDepthStartIndex(2));
            try t.expectEqual(7, calcDepthStartIndex(3));
            try t.expectEqual(15, calcDepthStartIndex(4));
        }

        fn calcDepthEndIndex(depth: usize) usize {
            return std.math.shl(usize, 1, depth + 1) - 1;
        }

        test calcDepthEndIndex {
            const t = std.testing;
            try t.expectEqual(1, calcDepthEndIndex(0));
            try t.expectEqual(3, calcDepthEndIndex(1));
            try t.expectEqual(7, calcDepthEndIndex(2));
            try t.expectEqual(15, calcDepthEndIndex(3));
            try t.expectEqual(31, calcDepthEndIndex(4));
        }

        fn calcParentIndex(index: usize) usize {
            assert(index > 0);
            return @divTrunc(index - 1, 2);
        }

        test calcParentIndex {
            const t = std.testing;

            try t.expectEqual(0, calcParentIndex(1));
            try t.expectEqual(0, calcParentIndex(2));

            try t.expectEqual(1, calcParentIndex(3));
            try t.expectEqual(1, calcParentIndex(4));
            try t.expectEqual(2, calcParentIndex(5));
            try t.expectEqual(2, calcParentIndex(6));

            try t.expectEqual(3, calcParentIndex(7));
            try t.expectEqual(3, calcParentIndex(8));
            try t.expectEqual(4, calcParentIndex(9));
            try t.expectEqual(4, calcParentIndex(10));
        }

        fn calcLeftChildIndex(index: usize) usize {
            return (index << 1) + 1;
        }

        test calcLeftChildIndex {
            const t = std.testing;
            try t.expectEqual(1, calcLeftChildIndex(0));
            try t.expectEqual(3, calcLeftChildIndex(1));
            try t.expectEqual(5, calcLeftChildIndex(2));
            try t.expectEqual(7, calcLeftChildIndex(3));
            try t.expectEqual(9, calcLeftChildIndex(4));
        }

        fn calcRightChildIndex(index: usize) usize {
            return (index << 1) + 2;
        }

        test calcRightChildIndex {
            const t = std.testing;
            try t.expectEqual(2, calcRightChildIndex(0));
            try t.expectEqual(4, calcRightChildIndex(1));
            try t.expectEqual(6, calcRightChildIndex(2));
            try t.expectEqual(8, calcRightChildIndex(3));
            try t.expectEqual(10, calcRightChildIndex(4));
        }

        fn calcIndexDepth(index: usize) usize {
            if (index == 0) return 0;
            return @bitSizeOf(usize) - 1 - @clz(index + 1);
        }

        test calcIndexDepth {
            const t = std.testing;

            try t.expectEqual(0, calcIndexDepth(0));

            try t.expectEqual(1, calcIndexDepth(1));
            try t.expectEqual(1, calcIndexDepth(2));

            try t.expectEqual(2, calcIndexDepth(3));
            try t.expectEqual(2, calcIndexDepth(4));
            try t.expectEqual(2, calcIndexDepth(5));
            try t.expectEqual(2, calcIndexDepth(6));

            try t.expectEqual(3, calcIndexDepth(7));
            try t.expectEqual(3, calcIndexDepth(8));
            try t.expectEqual(3, calcIndexDepth(9));
            try t.expectEqual(3, calcIndexDepth(10));
            try t.expectEqual(3, calcIndexDepth(11));
            try t.expectEqual(3, calcIndexDepth(12));
            try t.expectEqual(3, calcIndexDepth(13));
            try t.expectEqual(3, calcIndexDepth(14));
        }

        fn calcIndexOffset(index: usize, max_block_size: usize) usize {
            const depth = calcIndexDepth(index);
            const depth_start_index = calcDepthStartIndex(depth);
            assert(depth_start_index <= index);
            const local_index = index - depth_start_index;
            assert(std.math.isPowerOfTwo(max_block_size));
            const block_size = std.math.shr(usize, max_block_size, depth);
            assert(block_size <= max_block_size);
            return local_index * block_size;
        }

        test calcIndexOffset {
            const t = std.testing;

            try t.expectEqual(0, calcIndexOffset(0, 1024));

            try t.expectEqual(0, calcIndexOffset(1, 1024));
            try t.expectEqual(512, calcIndexOffset(2, 1024));

            try t.expectEqual(0, calcIndexOffset(3, 1024));
            try t.expectEqual(256, calcIndexOffset(4, 1024));
            try t.expectEqual(512, calcIndexOffset(5, 1024));
            try t.expectEqual(768, calcIndexOffset(6, 1024));
        }

        fn calcOffsetIndex(
            offset: usize,
            size: usize,
            min_block_size: usize,
            max_block_size: usize,
        ) usize {
            const block_size = calcBlockSize(size, min_block_size);
            assert(std.math.isPowerOfTwo(block_size));
            const depth = calcBlockDepth(size, min_block_size, max_block_size);
            const start_index = calcDepthStartIndex(depth);
            const index_offset = @divExact(offset, block_size);
            return start_index + index_offset;
        }
    };

    // ------------------------------------------------------------
    // Public API
    // ------------------------------------------------------------

    /// Initialize the allocator.
    ///
    /// Buffer must have a size that is a power of 2, and be aligned to
    /// options.min_block_size.
    pub fn init(buffer: []u8, options: BuddyAllocatorOptions) InitError!BuddyAllocator {
        // buffer size is power of 2
        if (!std.math.isPowerOfTwo(buffer.len)) return error.invalid_buffer_size;
        // min block size is power of 2
        if (!std.math.isPowerOfTwo(options.block_size)) return error.invalid_min_block_size;
        // buffer is aligned to block size
        if (!std.mem.isAligned(@intFromPtr(buffer.ptr), options.block_size)) return error.invalid_buffer_align;

        var out = BuddyAllocator{
            .buffer = buffer,
            .min_block_size = options.block_size,
        };

        // initialize the block tree
        var block_tree = out.getBlockTree();
        block_tree.setAll(.free);

        // alloc the block tree post-hoc
        const block_tree_ptr = out.alloc(
            block_tree.getSizeBytes(),
            .fromByteUnits(options.block_size),
            @returnAddress(),
        ) catch |err| panic("unexpected error: {any}", .{err});
        assert(@intFromPtr(block_tree_ptr) == @intFromPtr(block_tree.bits.masks));

        return out;
    }

    test init {
        const t = std.testing;
        var buf: [1024]u8 align(64) = undefined;
        const buddy = try BuddyAllocator.init(&buf, .{ .block_size = 64 });
        try t.expectEqual(&buf, buddy.buffer.ptr);
        try t.expectEqual(64, buddy.min_block_size);
    }

    pub fn allocator(self: *BuddyAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocOpaque,
                .resize = resizeOpaque,
                .remap = remapOpaque,
                .free = freeOpaque,
            },
        };
    }

    test allocator {
        var buddy = std.mem.validationWrap(
            try BuddyAllocator.init(test_buddy_allocator_memory[0..], .{}),
        );
        const a = buddy.allocator();

        try std.heap.testAllocator(a);
        try std.heap.testAllocatorAligned(a);
        try std.heap.testAllocatorLargeAlignment(a);
        try std.heap.testAllocatorAlignedShrink(a);
    }

    pub fn allocOpaque(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *BuddyAllocator = @ptrCast(@alignCast(ctx));
        return self.alloc(len, alignment, ret_addr) catch null;
    }

    pub fn alloc(self: *BuddyAllocator, len: usize, alignment: std.mem.Alignment, ret_addr: usize) error{out_of_memory}![*]u8 {
        // pub fn alloc(self: *BuddyAllocator, _: usize, _: std.mem.Alignment, ret_addr: usize) error{out_of_memory}![*]u8 {
        _ = ret_addr;

        assert(std.math.isPowerOfTwo(alignment.toByteUnits()));

        const size = @max(len, alignment.toByteUnits());
        const target_depth = BlockTree.calcBlockDepth(size, self.min_block_size, self.buffer.len);

        const start_index = BlockTree.calcDepthStartIndex(target_depth);
        const end_index = BlockTree.calcDepthEndIndex(target_depth);

        var block_tree = self.getBlockTree();

        var found_index_opt: ?usize = null;
        for (start_index..end_index) |i| {
            if (block_tree.isFree(i)) {
                found_index_opt = i;
                break;
            }
        }
        if (found_index_opt == null) return error.out_of_memory;

        // mark found index as used
        const found_index = found_index_opt.?;
        block_tree.markBlockAsUsed(found_index);
        const found_offset = block_tree.getIndexOffset(found_index);
        const out = self.buffer.ptr + found_offset;
        // DEBUG
        if (!alignment.check(@intFromPtr(out))) {
            std.debug.print("alignment: {d}\n", .{alignment.toByteUnits()});
            std.debug.print("block_size: {d}\n", .{BlockTree.calcDepthSize(target_depth, self.buffer.len)});
            std.debug.print("out: {d}\n", .{@intFromPtr(out)});
            std.debug.print("out % alignment: {d}\n", .{@mod(@intFromPtr(out), alignment.toByteUnits())});
        }
        assert(alignment.check(@intFromPtr(out)));
        return out;
    }

    test alloc {
        const t = std.testing;
        var buf: [1024]u8 align(64) = undefined;
        const buf_start = @intFromPtr(&buf);
        var buddy = try BuddyAllocator.init(&buf, .{ .block_size = 64 });
        const p1 = try buddy.alloc(8, .fromByteUnits(8), @returnAddress());
        try t.expectEqual(64, @intFromPtr(p1) - buf_start);
        const p2 = try buddy.alloc(168, .fromByteUnits(4), @returnAddress());
        try t.expectEqual(256, @intFromPtr(p2) - buf_start);
        const p3 = try buddy.alloc(64, .fromByteUnits(4), @returnAddress());
        try t.expectEqual(128, @intFromPtr(p3) - buf_start);
    }

    pub fn resizeOpaque(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *BuddyAllocator = @ptrCast(@alignCast(ctx));
        return self.resize(memory, alignment, new_len, ret_addr);
    }

    pub fn resize(
        self: *BuddyAllocator,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        _ = ret_addr;
        // TODO: fail assertions gracefully and check for other invalid input
        assert(@intFromPtr(self.buffer.ptr) <= @intFromPtr(memory.ptr));
        const offset: usize = memory.ptr - self.buffer.ptr;
        const curr_size = @max(memory.len, alignment.toByteUnits());
        const curr_block_size = BlockTree.calcBlockSize(curr_size, self.min_block_size);
        const new_size = @max(new_len, alignment.toByteUnits());
        const new_block_size = BlockTree.calcBlockSize(new_size, self.min_block_size);
        if (curr_block_size == new_block_size) return true;
        if (curr_block_size < new_block_size) {
            return self.resizeGrow(offset, curr_block_size, new_block_size);
        } else {
            assert(curr_block_size > new_block_size);
            return self.resizeShrink(offset, curr_block_size, new_block_size);
        }
    }

    test resize {
        const t = std.testing;
        var buf: [1024]u8 align(64) = undefined;
        const buf_start = @intFromPtr(&buf);
        var buddy = try BuddyAllocator.init(&buf, .{ .block_size = 64 });
        const align_ = std.mem.Alignment.fromByteUnits(8);

        var p1 = try buddy.alloc(58, align_, 0);
        var b1: []u8 = p1[0..58];
        try t.expectEqual(64, @intFromPtr(b1.ptr) - buf_start);
        var p2 = try buddy.alloc(46, align_, 0);
        var b2: []u8 = p2[0..46];
        try t.expectEqual(128, @intFromPtr(b2.ptr) - buf_start);

        try t.expect(buddy.resize(b1, align_, 15, 0));
        b1.len = 15;
        try t.expect(buddy.resize(b1, align_, 30, 0));
        b1.len = 30;
        try t.expect(buddy.resize(b2, align_, 200, 0));
        b2.len = 200;
        try t.expect(!buddy.resize(b1, align_, 100, 0));
    }

    fn resizeGrow(
        self: *BuddyAllocator,
        offset: usize,
        curr_block_size: usize,
        new_block_size: usize,
    ) bool {
        assert(new_block_size > curr_block_size);
        assert(std.math.isPowerOfTwo(curr_block_size));
        assert(std.math.isPowerOfTwo(new_block_size));

        var block_tree = self.getBlockTree();
        const strides = @divExact(new_block_size, curr_block_size);
        const index = block_tree.getOffsetIndex(offset, curr_block_size);
        assert(block_tree.isIndexValid(index));
        const depth = BlockTree.calcIndexDepth(index);
        const depth_end_index = BlockTree.calcDepthEndIndex(depth);
        if (index + strides > depth_end_index) return false;

        // check if we can grow
        for (1..strides) |i| {
            const curr_index = index + i;
            assert(block_tree.isIndexValid(curr_index));
            if (!block_tree.isFree(curr_index)) return false;
        }

        // if so, mark all necessary blocks as used
        for (1..strides) |i| {
            const curr_index = index + i;
            assert(block_tree.isIndexValid(curr_index));
            assert(block_tree.isFree(curr_index));
            block_tree.markBlockAsUsed(curr_index);
        }

        return true;
    }

    fn resizeShrink(
        self: *BuddyAllocator,
        offset: usize,
        curr_block_size: usize,
        new_block_size: usize,
    ) bool {
        assert(new_block_size < curr_block_size);
        assert(std.math.isPowerOfTwo(curr_block_size));
        assert(std.math.isPowerOfTwo(new_block_size));

        var block_tree = self.getBlockTree();
        var block_size = curr_block_size;
        var index = block_tree.getOffsetIndex(offset, block_size);
        assert(block_tree.isIndexValid(index));

        // free right children until appropriately sized
        while (block_size > new_block_size) {
            const left_child_index = BlockTree.calcLeftChildIndex(index);
            assert(block_tree.isIndexValid(left_child_index));
            const right_child_index = BlockTree.calcRightChildIndex(index);
            assert(block_tree.isIndexValid(right_child_index));

            block_tree.markBlockAsFree(right_child_index);

            block_size >>= 1;
            index = left_child_index;
        }
        return true;
    }

    fn remapOpaque(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *BuddyAllocator = @ptrCast(@alignCast(ctx));
        return self.remap(memory, alignment, new_len, ret_addr);
    }

    pub fn remap(
        self: *BuddyAllocator,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        if (self.resize(memory, alignment, new_len, ret_addr)) {
            return memory.ptr;
        }
        return null;
    }

    pub fn freeOpaque(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *BuddyAllocator = @ptrCast(@alignCast(ctx));
        self.free(memory, alignment, ret_addr);
    }

    pub fn free(
        self: *BuddyAllocator,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        _ = ret_addr;

        // NOTE: by convention, free functions fail silently on invalid input
        // TODO: fail assertions silently
        assert(@intFromPtr(self.buffer.ptr) <= @intFromPtr(memory.ptr));
        const offset: usize = memory.ptr - self.buffer.ptr;

        var block_tree = self.getBlockTree();
        const size = @max(memory.len, alignment.toByteUnits());
        const index = block_tree.getOffsetIndex(offset, size);
        assert(block_tree.isIndexValid(index));
        block_tree.markBlockAsFree(index);
    }

    test free {
        const t = std.testing;
        var buf: [1024]u8 align(64) = undefined;
        const buf_start = @intFromPtr(&buf);
        var buddy = try BuddyAllocator.init(&buf, .{ .block_size = 64 });

        const p1 = try buddy.alloc(8, .fromByteUnits(8), @returnAddress());
        try t.expectEqual(64, @intFromPtr(p1) - buf_start);
        const p2 = try buddy.alloc(168, .fromByteUnits(4), @returnAddress());
        try t.expectEqual(256, @intFromPtr(p2) - buf_start);
        const p3 = try buddy.alloc(64, .fromByteUnits(4), @returnAddress());
        try t.expectEqual(128, @intFromPtr(p3) - buf_start);

        buddy.free(p1[0..8], .fromByteUnits(8), @returnAddress());

        const p4 = try buddy.alloc(8, .fromByteUnits(8), @returnAddress());
        try t.expectEqual(64, @intFromPtr(p4) - buf_start);
    }

    // ------------------------------------------------------------
    // TODO: section name
    // ------------------------------------------------------------

    fn getBlockTree(self: *const BuddyAllocator) BlockTree {
        return .viewFromBuffer(self.buffer, self.min_block_size);
    }
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(BuddyAllocator.BlockTree);
}
