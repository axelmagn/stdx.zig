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

    const BlockTree = struct {
        bits: std.DynamicBitSetUnmanaged,
        min_block_size: usize,
        max_block_size: usize,

        fn isIndexFree(self: *BlockTree, index: usize) bool {
            return self.bits.isSet(index);
        }

        fn setIndexFreeValue(self: *BlockTree, index: usize, value: bool) void {
            return self.bits.setValue(index, value);
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

        const out = BuddyAllocator{
            .buffer = buffer,
            .min_block_size = options.block_size,
        };

        var free_list = out.getFreeList();
        assert(@intFromPtr(free_list.masks) == @intFromPtr(buffer.ptr));
        free_list.setAll();

        // TODO: allocate the block of the free list

        return out;
    }

    pub fn alloc(self: *BuddyAllocator, len: usize, alignment: std.mem.Alignment, ret_addr: usize) error{out_of_memory}![*]u8 {
        _ = ret_addr;

        const size = @max(len, alignment.toByteUnits());
        const target_level = getLevelForSize(size, self.min_block_size, self.buffer.len);

        // find the start and end indices for this level
        const one: usize = 1;
        const start_index = std.math.shl(usize, one, target_level) - one;
        const end_index = std.math.shl(usize, one, target_level + one) - one;
        var found_index_opt: ?usize = null;
        for (start_index..end_index) |i| {
            if (self.isFreeBit(i)) {
                found_index_opt = i;
                break;
            }
        }
        if (found_index_opt == null) return error.out_of_memory;

        // mark found index and all parents as used
        const found_index = found_index_opt.?;
        var curr_index = found_index;
        while (curr_index >= 0) {
            self.setFreeBit(curr_index, false);
            curr_index = @divTrunc(curr_index - 1, 2);
        }

        // TODO:mark all children of found index as used
        // const max_level = getLevelForSize(self.block_size, self.block_size, self.buffer.len);
        // const curr_level = target_level;
        // const child_start_index = found_index;
        // const child_end_index = found_index + 1;

        // TODO: return ptr
    }

    // ------------------------------------------------------------
    // block tree functions
    // ------------------------------------------------------------

    /// Get the free bitset at the start of the buffer.
    fn getFreeList(self: *const BuddyAllocator) std.DynamicBitSetUnmanaged {
        // TODO: caching
        var free_set = std.DynamicBitSetUnmanaged{};
        free_set.masks = @ptrCast(@alignCast(self.buffer.ptr));
        free_set.bit_length = getFreeListBitLength(self.buffer.len, self.min_block_size);
        return free_set;
    }

    test getFreeList {
        const t = std.testing;
        var buf: [1024]u8 = undefined;
        const buddy = BuddyAllocator{
            .buffer = &buf,
            .min_block_size = 64,
        };
        const free_list = buddy.getFreeList();
        try t.expectEqual(@intFromPtr(&buf), @intFromPtr(free_list.masks));
        try t.expectEqual(31, free_list.bit_length);
    }

    /// calculate the size of the free list in bits
    fn getFreeListBitLength(len: usize, min_block_size: usize) usize {
        var block_size = len;
        var bits_needed: usize = 0;
        while (block_size >= min_block_size) {
            bits_needed += @divExact(len, block_size);
            // divide by 2
            block_size >>= 1;
        }
        return bits_needed;
    }

    test getFreeListBitLength {
        const t = std.testing;
        try t.expectEqual(31, getFreeListBitLength(1024, 64));
    }

    fn getRequiredBlockSize(requested_size: usize, min_block_size: usize) usize {
        var block_size = min_block_size;
        while (block_size < requested_size) {
            block_size <<= 1;
        }
        return block_size;
    }

    test getRequiredBlockSize {
        const t = std.testing;
        try t.expectEqual(64, getRequiredBlockSize(31, 64));
        try t.expectEqual(64, getRequiredBlockSize(64, 64));
        try t.expectEqual(128, getRequiredBlockSize(78, 64));
        try t.expectEqual(256, getRequiredBlockSize(129, 64));
    }

    fn getLevelForSize(requested_size: usize, min_block_size: usize, max_block_size: usize) usize {
        // TODO: replace O(n) loops with clz and bsr instructions
        assert(min_block_size > 0);
        assert(max_block_size >= min_block_size);
        const block_size = getRequiredBlockSize(requested_size, min_block_size);
        assert(block_size >= min_block_size);

        var current_size = max_block_size;
        var level: usize = 0;

        while (current_size > block_size) {
            current_size >>= 1;
            level += 1;
        }

        assert(current_size == block_size);

        return level;
    }

    test getLevelForSize {
        const t = std.testing;
        try t.expectEqual(0, getLevelForSize(1024, 64, 1024));
        try t.expectEqual(0, getLevelForSize(1000, 64, 1024));
        try t.expectEqual(0, getLevelForSize(800, 64, 1024));
        try t.expectEqual(1, getLevelForSize(512, 64, 1024));
        try t.expectEqual(1, getLevelForSize(500, 64, 1024));
        try t.expectEqual(1, getLevelForSize(400, 64, 1024));
        try t.expectEqual(2, getLevelForSize(256, 64, 1024));
        try t.expectEqual(2, getLevelForSize(200, 64, 1024));
        try t.expectEqual(2, getLevelForSize(150, 64, 1024));
        try t.expectEqual(3, getLevelForSize(128, 64, 1024));
        try t.expectEqual(3, getLevelForSize(100, 64, 1024));
        try t.expectEqual(4, getLevelForSize(64, 64, 1024));
        try t.expectEqual(4, getLevelForSize(32, 64, 1024));
        try t.expectEqual(4, getLevelForSize(16, 64, 1024));
        try t.expectEqual(4, getLevelForSize(8, 64, 1024));
    }

    fn getSizeForLevel(level: usize, max_block_size: usize) usize {
        return std.math.shr(usize, max_block_size, level);
    }

    test getSizeForLevel {
        const t = std.testing;
        try t.expectEqual(1024, getSizeForLevel(0, 1024));
        try t.expectEqual(512, getSizeForLevel(1, 1024));
        try t.expectEqual(256, getSizeForLevel(2, 1024));
        try t.expectEqual(128, getSizeForLevel(3, 1024));
    }

    fn isFreeBit(self: *BuddyAllocator, index: usize) bool {
        return self.getFreeList().isSet(index);
    }

    fn setFreeBit(self: *BuddyAllocator, index: usize, is_free: bool) void {
        var free_list = self.getFreeList();
        free_list.setValue(index, is_free);
    }
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(BuddyAllocator.BlockTree);
}
