//! Output renderers: Intel HEX, raw binary image, and a listing file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assembler = @import("assembler.zig");

fn appendf(
    arena: Allocator,
    out: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    const s = try std.fmt.allocPrint(arena, fmt, args);
    try out.appendSlice(arena, s);
}

/// Render code chunks as Intel HEX (16 data bytes per record, I8HEX).
pub fn renderIhex(arena: Allocator, chunks: []const assembler.Chunk) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (chunks) |c| {
        var off: usize = 0;
        while (off < c.data.len) {
            const n = @min(@as(usize, 16), c.data.len - off);
            const addr: u32 = c.addr + @as(u32, @intCast(off));
            var sum: u8 = @truncate(n);
            sum +%= @truncate(addr >> 8);
            sum +%= @truncate(addr);
            try appendf(arena, &out, ":{X:0>2}{X:0>4}00", .{ n, addr & 0xFFFF });
            for (c.data[off..][0..n]) |byte| {
                sum +%= byte;
                try appendf(arena, &out, "{X:0>2}", .{byte});
            }
            try appendf(arena, &out, "{X:0>2}\n", .{~sum +% 1});
            off += n;
        }
    }
    try out.appendSlice(arena, ":00000001FF\n");
    return out.items;
}

/// Render code chunks as one flat binary image starting at address 0.
/// Gaps are filled with `0xFF` (erased-flash value).
pub fn renderBin(arena: Allocator, chunks: []const assembler.Chunk) Allocator.Error![]u8 {
    if (chunks.len == 0) return try arena.alloc(u8, 0);
    const last = chunks[chunks.len - 1];
    const end: usize = last.addr + last.data.len;
    const buf = try arena.alloc(u8, end);
    @memset(buf, 0xFF);
    for (chunks) |c| @memcpy(buf[c.addr..][0..c.data.len], c.data);
    return buf;
}

/// Render a human-readable listing (address, object code, source).
pub fn renderListing(arena: Allocator, listing: []const assembler.ListEntry) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "ADDR  CODE               LINE  SOURCE\n");
    var cur_file: ?[]const u8 = null;
    for (listing) |ent| {
        if (cur_file == null) {
            cur_file = ent.file;
        } else if (!std.mem.eql(u8, cur_file.?, ent.file)) {
            cur_file = ent.file;
            try appendf(arena, &out, "                         ; ==== {s} ====\n", .{ent.file});
        }
        const rows = if (ent.bytes.len == 0) 1 else (ent.bytes.len + 5) / 6;
        var r: usize = 0;
        while (r < rows) : (r += 1) {
            const o = r * 6;
            const slice = ent.bytes[o..@min(o + 6, ent.bytes.len)];
            try appendf(arena, &out, "{X:0>4}  ", .{(ent.addr + o) & 0xFFFF});
            var col: usize = 0;
            for (slice, 0..) |byte, bi| {
                if (bi > 0) {
                    try out.append(arena, ' ');
                    col += 1;
                }
                try appendf(arena, &out, "{X:0>2}", .{byte});
                col += 2;
            }
            if (r == 0) {
                while (col < 17) : (col += 1) try out.append(arena, ' ');
                try appendf(arena, &out, "  {d:>4}  {s}", .{ ent.line_no, ent.src });
            }
            try out.append(arena, '\n');
        }
    }
    return out.items;
}

const testing = std.testing;

test "intel hex output" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try assembler.assemble(arena,
        \\ mov a, #1
        \\ sjmp $
    );
    try testing.expectEqual(@as(usize, 0), res.errors.len);
    const hex = try renderIhex(arena, res.chunks);
    const expected = ":04000000" ++ "740180FE" ++ "09" ++ "\n" ++ ":00000001FF\n";
    try testing.expectEqualStrings(expected, hex);
}

test "intel hex splits records at 16 bytes and at chunk gaps" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try assembler.assemble(arena,
        \\ db 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17
        \\ org 100h
        \\ db 0AAh
    );
    try testing.expectEqual(@as(usize, 0), res.errors.len);
    const hex = try renderIhex(arena, res.chunks);
    const expected =
        ":10000000" ++ "000102030405060708090A0B0C0D0E0F" ++ "78" ++ "\n" ++
        ":02001000" ++ "1011" ++ "CD" ++ "\n" ++
        ":01010000" ++ "AA" ++ "54" ++ "\n" ++
        ":00000001FF\n";
    try testing.expectEqualStrings(expected, hex);
}

test "binary output fills gaps with 0xFF" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try assembler.assemble(arena,
        \\ nop
        \\ org 4
        \\ db 12h
    );
    try testing.expectEqual(@as(usize, 0), res.errors.len);
    const bin = try renderBin(arena, res.chunks);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xFF, 0xFF, 0xFF, 0x12 }, bin);
}
