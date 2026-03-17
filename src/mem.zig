//! Useful allocators and memory utils.  These are mostly general-purpose
//! allocators that sit on top of fixed memory buffers, since that's the main
//! gap in the standard library.

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;

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

        fn markBlockAsUsed(self: *BlockTree, index: usize) void {
            assert(index < self.getSizeBits());
            // mark index and all parents as used
            var curr_index = index;
            while (curr_index >= 0) {
                self.setIndex(curr_index, .used);
                if (curr_index == 0) break;

                const parent_index = calcParentIndex(curr_index);
                assert(parent_index < curr_index);
                curr_index = parent_index;
            }
            // mark chilren as used
            var left_child_index = BlockTree.calcLeftChildIndex(index);
            assert(left_child_index > index);
            var right_child_index = BlockTree.calcRightChildIndex(index);
            assert(right_child_index > index);

            while (self.isIndexValid(left_child_index)) {
                assert(self.isIndexValid(right_child_index));
                assert(right_child_index > left_child_index);
                self.setRange(left_child_index, right_child_index + 1, .used);
                left_child_index = BlockTree.calcLeftChildIndex(left_child_index);
                right_child_index = BlockTree.calcRightChildIndex(right_child_index);
            }
        }

        fn markBlockAsFree(self: *BlockTree, index: usize) void {
            assert(index < self.getSizeBits());
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

    pub fn alloc(self: *BuddyAllocator, len: usize, alignment: std.mem.Alignment, ret_addr: usize) error{out_of_memory}![*]u8 {
        // pub fn alloc(self: *BuddyAllocator, _: usize, _: std.mem.Alignment, ret_addr: usize) error{out_of_memory}![*]u8 {
        _ = ret_addr;

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

        // TODO: move set block logic to block tree so that it can be reused in
        // free

        // mark found index and all parents as used
        const found_index = found_index_opt.?;
        var curr_index = found_index;
        while (curr_index >= 0) {
            block_tree.setIndex(curr_index, .used);
            if (curr_index == 0) break;

            const parent_index = BlockTree.calcParentIndex(curr_index);
            assert(parent_index < curr_index);
            curr_index = parent_index;
        }

        // mark all children of found index as used
        var left_child_index = BlockTree.calcLeftChildIndex(found_index);
        assert(left_child_index > found_index);
        var right_child_index = BlockTree.calcRightChildIndex(found_index);
        assert(right_child_index > found_index);

        while (block_tree.isIndexValid(left_child_index)) {
            assert(block_tree.isIndexValid(right_child_index));
            assert(right_child_index > left_child_index);
            block_tree.setRange(left_child_index, right_child_index + 1, .used);
            left_child_index = BlockTree.calcLeftChildIndex(left_child_index);
            right_child_index = BlockTree.calcRightChildIndex(right_child_index);
        }

        const found_offset = block_tree.getIndexOffset(found_index);
        return self.buffer.ptr + found_offset;
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

    pub fn free(
        self: *BuddyAllocator,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        _ = ret_addr;

        const size = @max(memory.len, alignment.toByteUnits());
        const depth = BlockTree.calcBlockDepth(size, self.min_block_size, self.buffer.len);
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
