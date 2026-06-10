//! zinc51 command line interface.

const std = @import("std");
const zinc51 = @import("zinc51");

const usage =
    \\usage: zinc51 <input.asm> [options]
    \\
    \\options:
    \\  -o <file>        Intel HEX output path (default: <input>.hex)
    \\  -b, --bin <file> also write a flat binary image (gaps filled with 0xFF)
    \\  -l, --lst <file> also write a listing file
    \\  -h, --help       show this help
    \\
;

fn cliError(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("zinc51: " ++ fmt ++ "\n", args);
    return 2;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    const argv = try init.minimal.args.toSlice(arena);
    var input: ?[]const u8 = null;
    var hex_path: ?[]const u8 = null;
    var bin_path: ?[]const u8 = null;
    var lst_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= argv.len) return cliError("option '-o' needs an argument", .{});
            hex_path = argv[i];
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--bin")) {
            i += 1;
            if (i >= argv.len) return cliError("option '{s}' needs an argument", .{arg});
            bin_path = argv[i];
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--lst")) {
            i += 1;
            if (i >= argv.len) return cliError("option '{s}' needs an argument", .{arg});
            lst_path = argv[i];
        } else if (arg.len > 0 and arg[0] == '-') {
            return cliError("unknown option '{s}'\n{s}", .{ arg, usage });
        } else {
            if (input != null) return cliError("more than one input file given", .{});
            input = arg;
        }
    }
    const in_path = input orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };

    const src = std.Io.Dir.cwd().readFileAlloc(io, in_path, arena, .limited(16 << 20)) catch |err| {
        std.debug.print("zinc51: cannot read '{s}': {t}\n", .{ in_path, err });
        return 1;
    };

    const res = try zinc51.assemble(arena, src);
    if (res.errors.len != 0) {
        for (res.errors) |e| std.debug.print("{s}:{d}: error: {s}\n", .{ in_path, e.line, e.msg });
        std.debug.print("zinc51: {d} error(s), no output written\n", .{res.errors.len});
        return 1;
    }

    const out_hex = hex_path orelse try replaceExt(arena, in_path, ".hex");
    try writeOut(io, out_hex, try zinc51.output.renderIhex(arena, res.chunks));
    if (bin_path) |p| try writeOut(io, p, try zinc51.output.renderBin(arena, res.chunks));
    if (lst_path) |p| try writeOut(io, p, try zinc51.output.renderListing(arena, res.listing));

    var total: usize = 0;
    for (res.chunks) |c| total += c.data.len;

    var obuf: [512]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &obuf);
    const w = &fw.interface;
    if (res.chunks.len == 0) {
        try w.print("zinc51: no code generated; wrote {s}\n", .{out_hex});
    } else {
        const first = res.chunks[0];
        const last = res.chunks[res.chunks.len - 1];
        const hi = last.addr + @as(u32, @intCast(last.data.len)) - 1;
        try w.print("zinc51: {d} byte(s) at 0x{X:0>4}..0x{X:0>4} -> {s}\n", .{ total, first.addr, hi, out_hex });
    }
    try w.flush();
    return 0;
}

fn writeOut(io: std.Io, path: []const u8, data: []const u8) !void {
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |err| {
        std.debug.print("zinc51: cannot write '{s}': {t}\n", .{ path, err });
        return err;
    };
}

/// Replace the file extension of `path` with `ext` (which includes the dot).
fn replaceExt(arena: std.mem.Allocator, path: []const u8, ext: []const u8) ![]u8 {
    const name_start = if (std.mem.lastIndexOfAny(u8, path, "/\\")) |s| s + 1 else 0;
    const stem = if (std.mem.lastIndexOfScalar(u8, path[name_start..], '.')) |d|
        path[0 .. name_start + d]
    else
        path;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ stem, ext });
}
