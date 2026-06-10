//! Two-pass assembler for the Intel MCS-51 (8051) instruction set.
//!
//! Pass 1 parses every line, sizes each statement (instruction sizes depend
//! only on operand *shapes*, never on symbol values) and defines all symbols.
//! Pass 2 evaluates expressions with the complete symbol table and emits code.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = struct {
    file: []const u8,
    line: u32,
    msg: []const u8,
    /// Statement ordinal, used to report errors in source order.
    seq: u32 = 0,
};

pub const Chunk = struct {
    addr: u32,
    data: []const u8,
};

pub const ListEntry = struct {
    file: []const u8,
    line_no: u32,
    addr: u32,
    bytes: []const u8,
    src: []const u8,
};

pub const LoadedFile = struct {
    source: []const u8,
    /// Name used in error messages and listings (e.g. the resolved path).
    name: []const u8,
};

/// Resolves INCLUDE directives. `path` is the operand as written; `from_file`
/// is the file containing the directive. Returns null if the file cannot be
/// loaded; both result slices must outlive the assembly (allocate from `arena`).
pub const FileLoader = struct {
    ctx: *anyopaque,
    load: *const fn (ctx: *anyopaque, arena: Allocator, path: []const u8, from_file: []const u8) ?LoadedFile,
};

pub const Options = struct {
    /// Name of the top-level source, used in error messages and listings.
    file_name: []const u8 = "<input>",
    /// Without a loader, INCLUDE directives are reported as errors.
    loader: ?FileLoader = null,
};

const max_include_depth = 16;

pub const Result = struct {
    chunks: []const Chunk,
    errors: []const Error,
    listing: []const ListEntry,

    pub fn ok(self: Result) bool {
        return self.errors.len == 0;
    }
};

/// Assemble `source`. All result memory is allocated from `arena`; the caller
/// frees everything by resetting/deiniting the arena.
pub fn assemble(arena: Allocator, source: []const u8) Allocator.Error!Result {
    return assembleOpts(arena, source, .{});
}

pub fn assembleOpts(arena: Allocator, source: []const u8, opts: Options) Allocator.Error!Result {
    var a = Assembler{
        .arena = arena,
        .loader = opts.loader,
        .image = try arena.alloc(u8, 0x10000),
        .used = try arena.alloc(bool, 0x10000),
    };
    @memset(a.used, false);
    @memset(a.image, 0);
    try a.definePredefined();
    try a.parseSource(source, opts.file_name, 0);
    try a.pass1();
    try a.pass2();
    // Pass-1 and pass-2 errors interleave; report them in source order.
    std.sort.insertion(Error, a.errors.items, {}, struct {
        fn lessThan(_: void, x: Error, y: Error) bool {
            return x.seq < y.seq;
        }
    }.lessThan);
    return .{
        .chunks = try a.collectChunks(),
        .errors = a.errors.items,
        .listing = a.listing.items,
    };
}

const Mnemonic = enum {
    nop, ajmp, ljmp, sjmp, jmp, acall, lcall, call, ret, reti,
    rr, rrc, rl, rlc, swap, da,
    inc, dec, add, addc, subb, mul, div,
    orl, anl, xrl, clr, cpl, setb,
    mov, movc, movx, xch, xchd, push, pop,
    jc, jnc, jz, jnz, jb, jnb, jbc, cjne, djnz,
};

const mnemonics = std.static_string_map.StaticStringMap(Mnemonic).initComptime(.{
    .{ "NOP", .nop },     .{ "AJMP", .ajmp },   .{ "LJMP", .ljmp },   .{ "SJMP", .sjmp },
    .{ "JMP", .jmp },     .{ "ACALL", .acall }, .{ "LCALL", .lcall }, .{ "CALL", .call },
    .{ "RET", .ret },     .{ "RETI", .reti },   .{ "RR", .rr },       .{ "RRC", .rrc },
    .{ "RL", .rl },       .{ "RLC", .rlc },     .{ "SWAP", .swap },   .{ "DA", .da },
    .{ "INC", .inc },     .{ "DEC", .dec },     .{ "ADD", .add },     .{ "ADDC", .addc },
    .{ "SUBB", .subb },   .{ "MUL", .mul },     .{ "DIV", .div },     .{ "ORL", .orl },
    .{ "ANL", .anl },     .{ "XRL", .xrl },     .{ "CLR", .clr },     .{ "CPL", .cpl },
    .{ "SETB", .setb },   .{ "MOV", .mov },     .{ "MOVC", .movc },   .{ "MOVX", .movx },
    .{ "XCH", .xch },     .{ "XCHD", .xchd },   .{ "PUSH", .push },   .{ "POP", .pop },
    .{ "JC", .jc },       .{ "JNC", .jnc },     .{ "JZ", .jz },       .{ "JNZ", .jnz },
    .{ "JB", .jb },       .{ "JNB", .jnb },     .{ "JBC", .jbc },     .{ "CJNE", .cjne },
    .{ "DJNZ", .djnz },
});

const Directive = enum { org, db, dw, ds, end, equ, set, bit, data, idata, xdata, code, include };

const directives = std.static_string_map.StaticStringMap(Directive).initComptime(.{
    .{ "ORG", .org },   .{ "DB", .db },       .{ "DW", .dw },     .{ "DS", .ds },
    .{ "END", .end },   .{ "EQU", .equ },     .{ "SET", .set },   .{ "BIT", .bit },
    .{ "DATA", .data }, .{ "IDATA", .idata }, .{ "XDATA", .xdata }, .{ "CODE", .code },
    .{ "INCLUDE", .include },
});

fn isSymDefDirective(d: Directive) bool {
    return switch (d) {
        .equ, .set, .bit, .data, .idata, .xdata, .code => true,
        else => false,
    };
}

const Operand = struct {
    kind: Kind,
    reg: u8 = 0, // register number for .reg, indirect register for .at_reg
    text: []const u8 = "", // expression text for .imm / .not_bit / .expr

    const Kind = enum { acc, ab, carry, dptr, at_dptr, at_a_dptr, at_a_pc, reg, at_reg, imm, not_bit, expr };
};

const Instr = struct {
    mn: Mnemonic,
    ops: []const Operand,
};

const Item = union(enum) {
    str: []const u8, // already unescaped bytes
    expr: []const u8,
};

const SymDef = struct {
    name: []const u8, // uppercased
    expr: []const u8,
    redefinable: bool,
};

const Stmt = union(enum) {
    none,
    instr: Instr,
    org: []const u8,
    symdef: SymDef,
    db: []const Item,
    dw: []const Item,
    ds: []const u8,
    end,
};

const SrcLine = struct {
    file: []const u8,
    no: u32,
    text: []const u8,
    labels: []const []const u8, // uppercased
    stmt: Stmt,
    addr: u32 = 0, // location counter at start of line (pass 1)
    val: u32 = 0, // org target / ds size / symbol value (pass 1)
};

const Sym = struct {
    value: i64,
    redefinable: bool,
};

const EvalErr = error{Fail};

const Assembler = struct {
    arena: Allocator,
    lines: std.ArrayList(SrcLine) = .empty,
    syms: std.StringHashMapUnmanaged(Sym) = .empty,
    errors: std.ArrayList(Error) = .empty,
    listing: std.ArrayList(ListEntry) = .empty,
    image: []u8,
    used: []bool,
    loader: ?FileLoader = null,
    pc: u32 = 0,
    dollar: u32 = 0,
    cur_file: []const u8 = "",
    cur_line: u32 = 0,
    cur_seq: u32 = 0,
    overflow_reported: bool = false,

    fn errf(a: *Assembler, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(a.arena, fmt, args) catch return;
        a.errors.append(a.arena, .{
            .file = a.cur_file,
            .line = a.cur_line,
            .msg = msg,
            .seq = a.cur_seq,
        }) catch {};
    }

    // ------------------------------------------------------------------
    // Predefined SFR byte and bit symbols (standard 8051)
    // ------------------------------------------------------------------

    fn definePredefined(a: *Assembler) Allocator.Error!void {
        const defs = [_]struct { []const u8, i64 }{
            // SFR byte addresses
            .{ "P0", 0x80 },   .{ "SP", 0x81 },   .{ "DPL", 0x82 },  .{ "DPH", 0x83 },
            .{ "PCON", 0x87 }, .{ "TCON", 0x88 }, .{ "TMOD", 0x89 }, .{ "TL0", 0x8A },
            .{ "TL1", 0x8B },  .{ "TH0", 0x8C },  .{ "TH1", 0x8D },  .{ "P1", 0x90 },
            .{ "SCON", 0x98 }, .{ "SBUF", 0x99 }, .{ "P2", 0xA0 },   .{ "IE", 0xA8 },
            .{ "P3", 0xB0 },   .{ "IP", 0xB8 },   .{ "PSW", 0xD0 },  .{ "ACC", 0xE0 },
            .{ "B", 0xF0 },
            // TCON bits
            .{ "IT0", 0x88 }, .{ "IE0", 0x89 }, .{ "IT1", 0x8A }, .{ "IE1", 0x8B },
            .{ "TR0", 0x8C }, .{ "TF0", 0x8D }, .{ "TR1", 0x8E }, .{ "TF1", 0x8F },
            // SCON bits
            .{ "RI", 0x98 },  .{ "TI", 0x99 },  .{ "RB8", 0x9A }, .{ "TB8", 0x9B },
            .{ "REN", 0x9C }, .{ "SM2", 0x9D }, .{ "SM1", 0x9E }, .{ "SM0", 0x9F },
            // IE bits
            .{ "EX0", 0xA8 }, .{ "ET0", 0xA9 }, .{ "EX1", 0xAA }, .{ "ET1", 0xAB },
            .{ "ES", 0xAC },  .{ "EA", 0xAF },
            // P3 bits
            .{ "RXD", 0xB0 },  .{ "TXD", 0xB1 }, .{ "INT0", 0xB2 }, .{ "INT1", 0xB3 },
            .{ "T0", 0xB4 },   .{ "T1", 0xB5 },  .{ "WR", 0xB6 },   .{ "RD", 0xB7 },
            // IP bits
            .{ "PX0", 0xB8 }, .{ "PT0", 0xB9 }, .{ "PX1", 0xBA }, .{ "PT1", 0xBB },
            .{ "PS", 0xBC },
            // PSW bits
            .{ "P", 0xD0 },   .{ "OV", 0xD2 },  .{ "RS0", 0xD3 }, .{ "RS1", 0xD4 },
            .{ "F0", 0xD5 },  .{ "AC", 0xD6 },  .{ "CY", 0xD7 },
        };
        for (defs) |d| try a.syms.put(a.arena, d[0], .{ .value = d[1], .redefinable = false });
    }

    fn defineSymbol(a: *Assembler, name: []const u8, value: i64, redefinable: bool) void {
        const gop = a.syms.getOrPut(a.arena, name) catch return;
        if (gop.found_existing) {
            if (redefinable and gop.value_ptr.redefinable) {
                gop.value_ptr.value = value;
                return;
            }
            a.errf("duplicate symbol '{s}'", .{name});
            return;
        }
        gop.value_ptr.* = .{ .value = value, .redefinable = redefinable };
    }

    // ------------------------------------------------------------------
    // Parsing
    // ------------------------------------------------------------------

    fn parseSource(a: *Assembler, source: []const u8, file: []const u8, depth: u32) Allocator.Error!void {
        var it = std.mem.splitScalar(u8, source, '\n');
        var no: u32 = 0;
        while (it.next()) |raw| {
            no += 1;
            var line = raw;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            a.cur_file = file;
            a.cur_line = no;
            a.cur_seq = @intCast(a.lines.items.len);
            try a.parseLine(line, no, depth);
        }
    }

    /// Load and splice in an included file. `raw_arg` is the operand as
    /// written: a bare path or one quoted with '...' or "..." (taken verbatim,
    /// no escape processing — Windows paths contain backslashes).
    fn handleInclude(a: *Assembler, raw_arg: []const u8, depth: u32) Allocator.Error!void {
        var path = std.mem.trim(u8, raw_arg, " \t");
        if (path.len >= 2 and (path[0] == '"' or path[0] == '\'') and path[path.len - 1] == path[0])
            path = path[1 .. path.len - 1];
        if (path.len == 0) {
            a.errf("INCLUDE requires a file path", .{});
            return;
        }
        if (depth >= max_include_depth) {
            a.errf("includes nested deeper than {d} levels (circular include?)", .{max_include_depth});
            return;
        }
        const loader = a.loader orelse {
            a.errf("INCLUDE is not available here (no file loader configured)", .{});
            return;
        };
        const sub = loader.load(loader.ctx, a.arena, path, a.cur_file) orelse {
            a.errf("cannot open include file '{s}'", .{path});
            return;
        };
        try a.parseSource(sub.source, sub.name, depth + 1);
    }

    fn parseLine(a: *Assembler, full_text: []const u8, no: u32, depth: u32) Allocator.Error!void {
        var line = SrcLine{ .file = a.cur_file, .no = no, .text = full_text, .labels = &.{}, .stmt = .none };
        var rest = std.mem.trim(u8, stripComment(full_text), " \t");

        // Assembler control lines: $INCLUDE(file) is honored, the rest
        // ($MOD51, $TITLE, ...) are ignored.
        if (rest.len > 0 and rest[0] == '$') {
            try a.lines.append(a.arena, line);
            const ctl = rest[1..];
            const n = identLen(ctl);
            if (n > 0 and std.ascii.eqlIgnoreCase(ctl[0..n], "INCLUDE")) {
                const arg = std.mem.trim(u8, ctl[n..], " \t");
                if (arg.len >= 2 and arg[0] == '(' and arg[arg.len - 1] == ')') {
                    try a.handleInclude(arg[1 .. arg.len - 1], depth);
                } else {
                    a.errf("$INCLUDE expects a parenthesized file name: $INCLUDE(file)", .{});
                }
            }
            return;
        }

        // Leading labels: `name:` (repeatable).
        var labels: std.ArrayList([]const u8) = .empty;
        while (true) {
            const id = identLen(rest);
            if (id == 0) break;
            var j = id;
            while (j < rest.len and (rest[j] == ' ' or rest[j] == '\t')) j += 1;
            if (j < rest.len and rest[j] == ':') {
                try labels.append(a.arena, try a.upperDup(rest[0..id]));
                rest = std.mem.trim(u8, rest[j + 1 ..], " \t");
                continue;
            }
            break;
        }
        line.labels = labels.items;

        if (rest.len == 0) {
            try a.lines.append(a.arena, line);
            return;
        }

        // Directives may be written with a leading dot (.org, .include, ...).
        var dotted = false;
        if (rest[0] == '.') {
            dotted = true;
            rest = std.mem.trim(u8, rest[1..], " \t");
        }

        const t1_len = identLen(rest);
        if (t1_len == 0) {
            a.errf("expected instruction or directive", .{});
            try a.lines.append(a.arena, line);
            return;
        }
        const t1 = rest[0..t1_len];
        const after_t1 = std.mem.trim(u8, rest[t1_len..], " \t");

        // `name EQU expr` style symbol definitions (second token is the
        // directive, optionally dotted).
        if (!dotted) {
            var t2src = after_t1;
            if (t2src.len > 0 and t2src[0] == '.') t2src = std.mem.trim(u8, t2src[1..], " \t");
            const t2_len = identLen(t2src);
            if (t2_len > 0) {
                var ubuf: [16]u8 = undefined;
                if (upperTo(&ubuf, t2src[0..t2_len])) |t2u| {
                    if (directives.get(t2u)) |d| {
                        if (isSymDefDirective(d)) {
                            if (line.labels.len > 0)
                                a.errf("'{s}' takes a plain name, not a label with ':'", .{t2u});
                            line.stmt = .{ .symdef = .{
                                .name = try a.upperDup(t1),
                                .expr = std.mem.trim(u8, t2src[t2_len..], " \t"),
                                .redefinable = d == .set,
                            } };
                            try a.lines.append(a.arena, line);
                            return;
                        }
                    }
                }
            }
        }

        var ubuf: [16]u8 = undefined;
        const t1u = upperTo(&ubuf, t1) orelse {
            a.errf("unknown instruction or directive '{s}'", .{t1});
            try a.lines.append(a.arena, line);
            return;
        };

        if (directives.get(t1u)) |d| {
            switch (d) {
                .org => line.stmt = .{ .org = after_t1 },
                .ds => line.stmt = .{ .ds = after_t1 },
                .end => line.stmt = .end,
                .db => line.stmt = .{ .db = try a.parseItems(after_t1) },
                .dw => line.stmt = .{ .dw = try a.parseItems(after_t1) },
                .include => {
                    try a.lines.append(a.arena, line);
                    try a.handleInclude(after_t1, depth);
                    return;
                },
                .equ, .set, .bit, .data, .idata, .xdata, .code => {
                    a.errf("'{s}' requires a name: NAME {s} expression", .{ t1u, t1u });
                },
            }
            try a.lines.append(a.arena, line);
            return;
        }

        if (dotted) {
            a.errf("unknown directive '.{s}'", .{t1});
            try a.lines.append(a.arena, line);
            return;
        }

        if (mnemonics.get(t1u)) |mn| {
            var ops: std.ArrayList(Operand) = .empty;
            if (after_t1.len > 0) {
                const parts = try splitTopLevel(a.arena, after_t1);
                for (parts) |p| {
                    const trimmed = std.mem.trim(u8, p, " \t");
                    if (trimmed.len == 0) {
                        a.errf("empty operand", .{});
                        continue;
                    }
                    try ops.append(a.arena, try a.classify(trimmed));
                }
            }
            line.stmt = .{ .instr = .{ .mn = mn, .ops = ops.items } };
            try a.lines.append(a.arena, line);
            return;
        }

        a.errf("unknown instruction or directive '{s}'", .{t1});
        try a.lines.append(a.arena, line);
    }

    /// Parse DB/DW item list; strings are unescaped here so pass 1 knows sizes.
    fn parseItems(a: *Assembler, s: []const u8) Allocator.Error![]const Item {
        var items: std.ArrayList(Item) = .empty;
        if (std.mem.trim(u8, s, " \t").len == 0) {
            a.errf("expected at least one value", .{});
            return items.items;
        }
        const parts = try splitTopLevel(a.arena, s);
        for (parts) |p| {
            const t = std.mem.trim(u8, p, " \t");
            if (t.len == 0) {
                a.errf("empty value in list", .{});
                continue;
            }
            if ((t[0] == '\'' or t[0] == '"') and isWholeString(t)) {
                if (try a.decodeString(t)) |bytes| {
                    try items.append(a.arena, .{ .str = bytes });
                }
                continue;
            }
            try items.append(a.arena, .{ .expr = t });
        }
        return items.items;
    }

    fn decodeString(a: *Assembler, t: []const u8) Allocator.Error!?[]const u8 {
        const body = t[1 .. t.len - 1];
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            var c = body[i];
            if (c == '\\') {
                i += 1;
                if (i >= body.len) {
                    a.errf("dangling '\\' in string", .{});
                    return null;
                }
                c = unescape(body[i]) orelse {
                    a.errf("unknown escape '\\{c}'", .{body[i]});
                    return null;
                };
            }
            try out.append(a.arena, c);
        }
        return out.items;
    }

    fn classify(a: *Assembler, text: []const u8) Allocator.Error!Operand {
        if (text[0] == '#')
            return .{ .kind = .imm, .text = std.mem.trim(u8, text[1..], " \t") };
        if (text[0] == '/')
            return .{ .kind = .not_bit, .text = std.mem.trim(u8, text[1..], " \t") };

        // Normalize (uppercase, strip blanks) for fixed-form operands.
        var buf: [12]u8 = undefined;
        var n: usize = 0;
        const norm: ?[]const u8 = blk: {
            for (text) |c| {
                if (c == ' ' or c == '\t') continue;
                if (n >= buf.len) break :blk null;
                buf[n] = std.ascii.toUpper(c);
                n += 1;
            }
            break :blk buf[0..n];
        };
        if (norm) |nm| {
            if (std.mem.eql(u8, nm, "A")) return .{ .kind = .acc };
            if (std.mem.eql(u8, nm, "AB")) return .{ .kind = .ab };
            if (std.mem.eql(u8, nm, "C")) return .{ .kind = .carry };
            if (std.mem.eql(u8, nm, "DPTR")) return .{ .kind = .dptr };
            if (std.mem.eql(u8, nm, "@DPTR")) return .{ .kind = .at_dptr };
            if (std.mem.eql(u8, nm, "@A+DPTR")) return .{ .kind = .at_a_dptr };
            if (std.mem.eql(u8, nm, "@A+PC")) return .{ .kind = .at_a_pc };
            if (nm.len == 2 and nm[0] == 'R' and nm[1] >= '0' and nm[1] <= '7')
                return .{ .kind = .reg, .reg = nm[1] - '0' };
            if (nm.len == 3 and nm[0] == '@' and nm[1] == 'R' and (nm[2] == '0' or nm[2] == '1'))
                return .{ .kind = .at_reg, .reg = nm[2] - '0' };
            if (nm.len > 0 and nm[0] == '@') {
                a.errf("invalid indirect operand '{s}'", .{text});
                return .{ .kind = .expr, .text = text };
            }
        }
        return .{ .kind = .expr, .text = text };
    }

    fn upperDup(a: *Assembler, s: []const u8) Allocator.Error![]const u8 {
        const out = try a.arena.alloc(u8, s.len);
        for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
        return out;
    }

    // ------------------------------------------------------------------
    // Pass 1: assign addresses, define symbols, size everything
    // ------------------------------------------------------------------

    fn pass1(a: *Assembler) Allocator.Error!void {
        a.pc = 0;
        for (a.lines.items, 0..) |*line, idx| {
            a.cur_file = line.file;
            a.cur_line = line.no;
            a.cur_seq = @intCast(idx);
            a.dollar = a.pc;
            line.addr = a.pc;
            for (line.labels) |name| a.defineSymbol(name, a.pc, false);
            switch (line.stmt) {
                .none => {},
                .org => |expr| {
                    const v = a.evalText(expr, true);
                    if (v < 0 or v > 0xFFFF) {
                        a.errf("ORG address out of range: {d}", .{v});
                    } else {
                        a.pc = @intCast(v);
                    }
                    line.val = a.pc;
                },
                .symdef => |sd| {
                    const v = a.evalText(sd.expr, true);
                    a.defineSymbol(sd.name, v, sd.redefinable);
                    line.val = @truncate(@as(u64, @bitCast(v)));
                },
                .ds => |expr| {
                    const v = a.evalText(expr, true);
                    if (v < 0 or a.pc + @as(u64, @intCast(@max(v, 0))) > 0x10000) {
                        a.errf("DS size out of range: {d}", .{v});
                    } else {
                        line.val = @intCast(v);
                        a.advance(@intCast(v));
                    }
                },
                .db => |items| {
                    var size: u32 = 0;
                    for (items) |item| size += switch (item) {
                        .str => |bytes| @as(u32, @intCast(bytes.len)),
                        .expr => 1,
                    };
                    a.advance(size);
                },
                .dw => |items| a.advance(@intCast(2 * items.len)),
                .instr => |ins| {
                    var buf: [8]u8 = undefined;
                    const n = a.encodeInstr(ins, false, &buf);
                    a.advance(@intCast(n));
                },
                .end => return,
            }
        }
    }

    fn advance(a: *Assembler, n: u32) void {
        a.pc += n;
        if (a.pc > 0x10000 and !a.overflow_reported) {
            a.overflow_reported = true;
            a.errf("location counter exceeds 64KB code space", .{});
        }
    }

    // ------------------------------------------------------------------
    // Pass 2: evaluate and emit
    // ------------------------------------------------------------------

    fn pass2(a: *Assembler) Allocator.Error!void {
        a.pc = 0;
        for (a.lines.items, 0..) |*line, idx| {
            a.cur_file = line.file;
            a.cur_line = line.no;
            a.cur_seq = @intCast(idx);
            a.dollar = a.pc;
            var entry = ListEntry{
                .file = line.file,
                .line_no = line.no,
                .addr = a.pc,
                .bytes = &.{},
                .src = line.text,
            };
            switch (line.stmt) {
                .none => {},
                .org => {
                    a.pc = line.val;
                    entry.addr = a.pc;
                },
                .symdef => entry.addr = line.val,
                .ds => a.pc += line.val,
                .db => |items| {
                    var bytes: std.ArrayList(u8) = .empty;
                    for (items) |item| switch (item) {
                        .str => |s| try bytes.appendSlice(a.arena, s),
                        .expr => |t| {
                            const v = a.evalText(t, true);
                            if (v < -128 or v > 255) a.errf("byte value out of range: {d}", .{v});
                            try bytes.append(a.arena, @intCast(@mod(v, 256)));
                        },
                    };
                    entry.bytes = bytes.items;
                    a.emit(bytes.items);
                },
                .dw => |items| {
                    var bytes: std.ArrayList(u8) = .empty;
                    for (items) |item| switch (item) {
                        // Allow 'A' and 'AB' style character words like ASM51 does.
                        .str => |s| switch (s.len) {
                            1 => {
                                try bytes.append(a.arena, 0);
                                try bytes.append(a.arena, s[0]);
                            },
                            2 => try bytes.appendSlice(a.arena, s),
                            else => a.errf("DW strings must be 1 or 2 characters", .{}),
                        },
                        .expr => |t| {
                            const v = a.evalText(t, true);
                            if (v < -32768 or v > 65535) a.errf("word value out of range: {d}", .{v});
                            const w: u16 = @intCast(@mod(v, 65536));
                            try bytes.append(a.arena, @intCast(w >> 8));
                            try bytes.append(a.arena, @intCast(w & 0xFF));
                        },
                    };
                    entry.bytes = bytes.items;
                    a.emit(bytes.items);
                },
                .instr => |ins| {
                    var buf: [8]u8 = undefined;
                    const n = a.encodeInstr(ins, true, &buf);
                    const bytes = try a.arena.dupe(u8, buf[0..n]);
                    entry.bytes = bytes;
                    a.emit(bytes);
                },
                .end => {
                    try a.listing.append(a.arena, entry);
                    return;
                },
            }
            try a.listing.append(a.arena, entry);
        }
    }

    fn emit(a: *Assembler, bytes: []const u8) void {
        for (bytes) |b| {
            if (a.pc > 0xFFFF) return; // overflow already reported in pass 1
            if (a.used[a.pc]) {
                a.errf("overlapping code at address 0x{X:0>4}", .{a.pc});
            } else {
                a.image[a.pc] = b;
                a.used[a.pc] = true;
            }
            a.pc += 1;
        }
    }

    fn collectChunks(a: *Assembler) Allocator.Error![]const Chunk {
        var chunks: std.ArrayList(Chunk) = .empty;
        var i: usize = 0;
        while (i < 0x10000) {
            if (!a.used[i]) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < 0x10000 and a.used[i]) i += 1;
            try chunks.append(a.arena, .{ .addr = @intCast(start), .data = a.image[start..i] });
        }
        return chunks.items;
    }

    // ------------------------------------------------------------------
    // Operand value helpers (strict=false swallows value errors; sizes are
    // shape-determined so pass 1 still gets correct instruction lengths)
    // ------------------------------------------------------------------

    fn evalText(a: *Assembler, text: []const u8, strict: bool) i64 {
        var ev = Ev{ .a = a, .s = text, .strict = strict };
        const v = ev.parseOr() catch return 0;
        ev.skipWs();
        if (ev.i < ev.s.len) {
            if (strict) a.errf("unexpected '{c}' in expression", .{ev.s[ev.i]});
            return 0;
        }
        return v;
    }

    fn vDirect(a: *Assembler, text: []const u8, strict: bool) u8 {
        const v = a.evalText(text, strict);
        if (v < 0 or v > 0xFF) {
            if (strict) a.errf("direct address out of range: {d}", .{v});
            return 0;
        }
        return @intCast(v);
    }

    fn vBit(a: *Assembler, text: []const u8, strict: bool) u8 {
        const v = a.evalText(text, strict);
        if (v < 0 or v > 0xFF) {
            if (strict) a.errf("bit address out of range: {d}", .{v});
            return 0;
        }
        return @intCast(v);
    }

    fn vImm8(a: *Assembler, text: []const u8, strict: bool) u8 {
        const v = a.evalText(text, strict);
        if (v < -128 or v > 255) {
            if (strict) a.errf("immediate value out of range: {d}", .{v});
            return 0;
        }
        return @intCast(@mod(v, 256));
    }

    fn vImm16(a: *Assembler, text: []const u8, strict: bool) u16 {
        const v = a.evalText(text, strict);
        if (v < -32768 or v > 65535) {
            if (strict) a.errf("16-bit immediate out of range: {d}", .{v});
            return 0;
        }
        return @intCast(@mod(v, 65536));
    }

    fn vAddr16(a: *Assembler, text: []const u8, strict: bool) u16 {
        const v = a.evalText(text, strict);
        if (v < 0 or v > 0xFFFF) {
            if (strict) a.errf("address out of range: {d}", .{v});
            return 0;
        }
        return @intCast(v);
    }

    fn vRel(a: *Assembler, text: []const u8, next: u32, strict: bool) u8 {
        const target = a.evalText(text, strict);
        const d = target - @as(i64, next);
        if (d < -128 or d > 127) {
            if (strict) a.errf("branch target out of range (offset {d}, must be -128..127)", .{d});
            return 0;
        }
        return @intCast(@mod(d, 256));
    }

    fn vAddr11(a: *Assembler, text: []const u8, next: u32, strict: bool) struct { hi: u8, lo: u8 } {
        const v = a.evalText(text, strict);
        if (v < 0 or v > 0xFFFF) {
            if (strict) a.errf("address out of range: {d}", .{v});
            return .{ .hi = 0, .lo = 0 };
        }
        const t: u32 = @intCast(v);
        if ((t >> 11) != (next >> 11)) {
            if (strict) a.errf("AJMP/ACALL target 0x{X:0>4} not in the same 2KB page as 0x{X:0>4}", .{ t, next });
            return .{ .hi = 0, .lo = 0 };
        }
        return .{ .hi = @intCast((t >> 8) & 7), .lo = @intCast(t & 0xFF) };
    }

    // ------------------------------------------------------------------
    // Instruction encoder. Returns the instruction length; in non-strict
    // (sizing) mode all value errors are suppressed.
    // ------------------------------------------------------------------

    fn encodeInstr(a: *Assembler, ins: Instr, strict: bool, buf: *[8]u8) usize {
        var e = Enc{ .buf = buf };
        const ops = ins.ops;
        ok: {
            switch (ins.mn) {
                .nop => if (ops.len == 0) {
                    e.b(0x00);
                    break :ok;
                },
                .ret => if (ops.len == 0) {
                    e.b(0x22);
                    break :ok;
                },
                .reti => if (ops.len == 0) {
                    e.b(0x32);
                    break :ok;
                },
                .rr => if (k1(ops, .acc)) {
                    e.b(0x03);
                    break :ok;
                },
                .rrc => if (k1(ops, .acc)) {
                    e.b(0x13);
                    break :ok;
                },
                .rl => if (k1(ops, .acc)) {
                    e.b(0x23);
                    break :ok;
                },
                .rlc => if (k1(ops, .acc)) {
                    e.b(0x33);
                    break :ok;
                },
                .swap => if (k1(ops, .acc)) {
                    e.b(0xC4);
                    break :ok;
                },
                .da => if (k1(ops, .acc)) {
                    e.b(0xD4);
                    break :ok;
                },
                .mul => if (k1(ops, .ab)) {
                    e.b(0xA4);
                    break :ok;
                },
                .div => if (k1(ops, .ab)) {
                    e.b(0x84);
                    break :ok;
                },
                .ljmp, .call, .lcall => if (k1(ops, .expr)) {
                    const op: u8 = if (ins.mn == .ljmp) 0x02 else 0x12;
                    const t = a.vAddr16(ops[0].text, strict);
                    e.b(op);
                    e.b(@intCast(t >> 8));
                    e.b(@intCast(t & 0xFF));
                    break :ok;
                },
                .jmp => {
                    if (k1(ops, .at_a_dptr)) {
                        e.b(0x73);
                        break :ok;
                    }
                    if (k1(ops, .expr)) {
                        const t = a.vAddr16(ops[0].text, strict);
                        e.b(0x02);
                        e.b(@intCast(t >> 8));
                        e.b(@intCast(t & 0xFF));
                        break :ok;
                    }
                },
                .ajmp, .acall => if (k1(ops, .expr)) {
                    const base: u8 = if (ins.mn == .ajmp) 0x01 else 0x11;
                    const t = a.vAddr11(ops[0].text, a.dollar + 2, strict);
                    e.b(base | (t.hi << 5));
                    e.b(t.lo);
                    break :ok;
                },
                .sjmp, .jc, .jnc, .jz, .jnz => if (k1(ops, .expr)) {
                    const op: u8 = switch (ins.mn) {
                        .sjmp => 0x80,
                        .jc => 0x40,
                        .jnc => 0x50,
                        .jz => 0x60,
                        .jnz => 0x70,
                        else => unreachable,
                    };
                    e.b(op);
                    e.b(a.vRel(ops[0].text, a.dollar + 2, strict));
                    break :ok;
                },
                .jb, .jnb, .jbc => if (k2(ops, .expr, .expr)) {
                    const op: u8 = switch (ins.mn) {
                        .jb => 0x20,
                        .jnb => 0x30,
                        .jbc => 0x10,
                        else => unreachable,
                    };
                    e.b(op);
                    e.b(a.vBit(ops[0].text, strict));
                    e.b(a.vRel(ops[1].text, a.dollar + 3, strict));
                    break :ok;
                },
                .push, .pop => if (k1(ops, .expr)) {
                    e.b(if (ins.mn == .push) 0xC0 else 0xD0);
                    e.b(a.vDirect(ops[0].text, strict));
                    break :ok;
                },
                .inc => {
                    if (k1(ops, .acc)) {
                        e.b(0x04);
                        break :ok;
                    }
                    if (k1(ops, .reg)) {
                        e.b(0x08 + ops[0].reg);
                        break :ok;
                    }
                    if (k1(ops, .at_reg)) {
                        e.b(0x06 + ops[0].reg);
                        break :ok;
                    }
                    if (k1(ops, .dptr)) {
                        e.b(0xA3);
                        break :ok;
                    }
                    if (k1(ops, .expr)) {
                        e.b(0x05);
                        e.b(a.vDirect(ops[0].text, strict));
                        break :ok;
                    }
                },
                .dec => {
                    if (k1(ops, .acc)) {
                        e.b(0x14);
                        break :ok;
                    }
                    if (k1(ops, .reg)) {
                        e.b(0x18 + ops[0].reg);
                        break :ok;
                    }
                    if (k1(ops, .at_reg)) {
                        e.b(0x16 + ops[0].reg);
                        break :ok;
                    }
                    if (k1(ops, .expr)) {
                        e.b(0x15);
                        e.b(a.vDirect(ops[0].text, strict));
                        break :ok;
                    }
                },
                .add, .addc, .subb => {
                    const base: u8 = switch (ins.mn) {
                        .add => 0x20,
                        .addc => 0x30,
                        .subb => 0x90,
                        else => unreachable,
                    };
                    if (k2(ops, .acc, .imm)) {
                        e.b(base + 0x4);
                        e.b(a.vImm8(ops[1].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .acc, .expr)) {
                        e.b(base + 0x5);
                        e.b(a.vDirect(ops[1].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .acc, .at_reg)) {
                        e.b(base + 0x6 + ops[1].reg);
                        break :ok;
                    }
                    if (k2(ops, .acc, .reg)) {
                        e.b(base + 0x8 + ops[1].reg);
                        break :ok;
                    }
                },
                .orl, .anl, .xrl => {
                    const base: u8 = switch (ins.mn) {
                        .orl => 0x40,
                        .anl => 0x50,
                        .xrl => 0x60,
                        else => unreachable,
                    };
                    if (k2(ops, .acc, .imm)) {
                        e.b(base + 0x4);
                        e.b(a.vImm8(ops[1].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .acc, .expr)) {
                        e.b(base + 0x5);
                        e.b(a.vDirect(ops[1].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .acc, .at_reg)) {
                        e.b(base + 0x6 + ops[1].reg);
                        break :ok;
                    }
                    if (k2(ops, .acc, .reg)) {
                        e.b(base + 0x8 + ops[1].reg);
                        break :ok;
                    }
                    if (k2(ops, .expr, .acc)) {
                        e.b(base + 0x2);
                        e.b(a.vDirect(ops[0].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .expr, .imm)) {
                        e.b(base + 0x3);
                        e.b(a.vDirect(ops[0].text, strict));
                        e.b(a.vImm8(ops[1].text, strict));
                        break :ok;
                    }
                    if (ins.mn != .xrl and k2(ops, .carry, .expr)) {
                        e.b(if (ins.mn == .orl) 0x72 else 0x82);
                        e.b(a.vBit(ops[1].text, strict));
                        break :ok;
                    }
                    if (ins.mn != .xrl and k2(ops, .carry, .not_bit)) {
                        e.b(if (ins.mn == .orl) 0xA0 else 0xB0);
                        e.b(a.vBit(ops[1].text, strict));
                        break :ok;
                    }
                },
                .clr => {
                    if (k1(ops, .acc)) {
                        e.b(0xE4);
                        break :ok;
                    }
                    if (k1(ops, .carry)) {
                        e.b(0xC3);
                        break :ok;
                    }
                    if (k1(ops, .expr)) {
                        e.b(0xC2);
                        e.b(a.vBit(ops[0].text, strict));
                        break :ok;
                    }
                },
                .cpl => {
                    if (k1(ops, .acc)) {
                        e.b(0xF4);
                        break :ok;
                    }
                    if (k1(ops, .carry)) {
                        e.b(0xB3);
                        break :ok;
                    }
                    if (k1(ops, .expr)) {
                        e.b(0xB2);
                        e.b(a.vBit(ops[0].text, strict));
                        break :ok;
                    }
                },
                .setb => {
                    if (k1(ops, .carry)) {
                        e.b(0xD3);
                        break :ok;
                    }
                    if (k1(ops, .expr)) {
                        e.b(0xD2);
                        e.b(a.vBit(ops[0].text, strict));
                        break :ok;
                    }
                },
                .xch => {
                    if (k2(ops, .acc, .expr)) {
                        e.b(0xC5);
                        e.b(a.vDirect(ops[1].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .acc, .at_reg)) {
                        e.b(0xC6 + ops[1].reg);
                        break :ok;
                    }
                    if (k2(ops, .acc, .reg)) {
                        e.b(0xC8 + ops[1].reg);
                        break :ok;
                    }
                },
                .xchd => if (k2(ops, .acc, .at_reg)) {
                    e.b(0xD6 + ops[1].reg);
                    break :ok;
                },
                .djnz => {
                    if (k2(ops, .reg, .expr)) {
                        e.b(0xD8 + ops[0].reg);
                        e.b(a.vRel(ops[1].text, a.dollar + 2, strict));
                        break :ok;
                    }
                    if (k2(ops, .expr, .expr)) {
                        e.b(0xD5);
                        e.b(a.vDirect(ops[0].text, strict));
                        e.b(a.vRel(ops[1].text, a.dollar + 3, strict));
                        break :ok;
                    }
                },
                .cjne => {
                    if (k3(ops, .acc, .imm, .expr)) {
                        e.b(0xB4);
                        e.b(a.vImm8(ops[1].text, strict));
                        e.b(a.vRel(ops[2].text, a.dollar + 3, strict));
                        break :ok;
                    }
                    if (k3(ops, .acc, .expr, .expr)) {
                        e.b(0xB5);
                        e.b(a.vDirect(ops[1].text, strict));
                        e.b(a.vRel(ops[2].text, a.dollar + 3, strict));
                        break :ok;
                    }
                    if (k3(ops, .at_reg, .imm, .expr)) {
                        e.b(0xB6 + ops[0].reg);
                        e.b(a.vImm8(ops[1].text, strict));
                        e.b(a.vRel(ops[2].text, a.dollar + 3, strict));
                        break :ok;
                    }
                    if (k3(ops, .reg, .imm, .expr)) {
                        e.b(0xB8 + ops[0].reg);
                        e.b(a.vImm8(ops[1].text, strict));
                        e.b(a.vRel(ops[2].text, a.dollar + 3, strict));
                        break :ok;
                    }
                },
                .movc => {
                    if (k2(ops, .acc, .at_a_dptr)) {
                        e.b(0x93);
                        break :ok;
                    }
                    if (k2(ops, .acc, .at_a_pc)) {
                        e.b(0x83);
                        break :ok;
                    }
                },
                .movx => {
                    if (k2(ops, .acc, .at_dptr)) {
                        e.b(0xE0);
                        break :ok;
                    }
                    if (k2(ops, .acc, .at_reg)) {
                        e.b(0xE2 + ops[1].reg);
                        break :ok;
                    }
                    if (k2(ops, .at_dptr, .acc)) {
                        e.b(0xF0);
                        break :ok;
                    }
                    if (k2(ops, .at_reg, .acc)) {
                        e.b(0xF2 + ops[0].reg);
                        break :ok;
                    }
                },
                .mov => {
                    if (k2(ops, .acc, .imm)) {
                        e.b(0x74);
                        e.b(a.vImm8(ops[1].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .acc, .reg)) {
                        e.b(0xE8 + ops[1].reg);
                        break :ok;
                    }
                    if (k2(ops, .acc, .at_reg)) {
                        e.b(0xE6 + ops[1].reg);
                        break :ok;
                    }
                    if (k2(ops, .acc, .expr)) {
                        e.b(0xE5);
                        e.b(a.vDirect(ops[1].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .reg, .acc)) {
                        e.b(0xF8 + ops[0].reg);
                        break :ok;
                    }
                    if (k2(ops, .reg, .imm)) {
                        e.b(0x78 + ops[0].reg);
                        e.b(a.vImm8(ops[1].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .reg, .expr)) {
                        e.b(0xA8 + ops[0].reg);
                        e.b(a.vDirect(ops[1].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .at_reg, .acc)) {
                        e.b(0xF6 + ops[0].reg);
                        break :ok;
                    }
                    if (k2(ops, .at_reg, .imm)) {
                        e.b(0x76 + ops[0].reg);
                        e.b(a.vImm8(ops[1].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .at_reg, .expr)) {
                        e.b(0xA6 + ops[0].reg);
                        e.b(a.vDirect(ops[1].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .dptr, .imm)) {
                        const v = a.vImm16(ops[1].text, strict);
                        e.b(0x90);
                        e.b(@intCast(v >> 8));
                        e.b(@intCast(v & 0xFF));
                        break :ok;
                    }
                    if (k2(ops, .carry, .expr)) {
                        e.b(0xA2);
                        e.b(a.vBit(ops[1].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .expr, .carry)) {
                        e.b(0x92);
                        e.b(a.vBit(ops[0].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .expr, .acc)) {
                        e.b(0xF5);
                        e.b(a.vDirect(ops[0].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .expr, .reg)) {
                        e.b(0x88 + ops[1].reg);
                        e.b(a.vDirect(ops[0].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .expr, .at_reg)) {
                        e.b(0x86 + ops[1].reg);
                        e.b(a.vDirect(ops[0].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .expr, .imm)) {
                        e.b(0x75);
                        e.b(a.vDirect(ops[0].text, strict));
                        e.b(a.vImm8(ops[1].text, strict));
                        break :ok;
                    }
                    if (k2(ops, .expr, .expr)) {
                        // MOV direct,direct encodes the *source* byte first.
                        e.b(0x85);
                        e.b(a.vDirect(ops[1].text, strict));
                        e.b(a.vDirect(ops[0].text, strict));
                        break :ok;
                    }
                },
            }
            if (!strict) a.errf("invalid operand(s) for '{s}'", .{@tagName(ins.mn)});
            return 0;
        }
        return e.n;
    }
};

const Enc = struct {
    buf: *[8]u8,
    n: usize = 0,

    fn b(e: *Enc, byte: u8) void {
        e.buf[e.n] = byte;
        e.n += 1;
    }
};

fn k1(ops: []const Operand, a: Operand.Kind) bool {
    return ops.len == 1 and ops[0].kind == a;
}

fn k2(ops: []const Operand, a: Operand.Kind, b: Operand.Kind) bool {
    return ops.len == 2 and ops[0].kind == a and ops[1].kind == b;
}

fn k3(ops: []const Operand, a: Operand.Kind, b: Operand.Kind, c: Operand.Kind) bool {
    return ops.len == 3 and ops[0].kind == a and ops[1].kind == b and ops[2].kind == c;
}

// ----------------------------------------------------------------------
// Expression evaluator
//
// Grammar (loosest to tightest binding):
//   |  OR     ^  XOR     &  AND     <<  >>  SHL  SHR     +  -
//   *  /  %  MOD     unary -  +  ~  NOT  HIGH  LOW     byte.bit
// Numbers: 123, 0x1F, 1Fh, 1010b, 0b1010, 17o/17q, 99d, 'A', $
// ----------------------------------------------------------------------

const Ev = struct {
    a: *Assembler,
    s: []const u8,
    i: usize = 0,
    strict: bool,

    fn fail(ev: *Ev, comptime fmt: []const u8, args: anytype) EvalErr {
        if (ev.strict) ev.a.errf(fmt, args);
        return error.Fail;
    }

    fn skipWs(ev: *Ev) void {
        while (ev.i < ev.s.len and (ev.s[ev.i] == ' ' or ev.s[ev.i] == '\t')) ev.i += 1;
    }

    fn match(ev: *Ev, lit: []const u8) bool {
        if (std.mem.startsWith(u8, ev.s[ev.i..], lit)) {
            ev.i += lit.len;
            return true;
        }
        return false;
    }

    /// Match a keyword operator (whole identifier, case-insensitive).
    fn matchKw(ev: *Ev, kw: []const u8) bool {
        const n = identLen(ev.s[ev.i..]);
        if (n != kw.len) return false;
        if (!std.ascii.eqlIgnoreCase(ev.s[ev.i .. ev.i + n], kw)) return false;
        ev.i += n;
        return true;
    }

    fn parseOr(ev: *Ev) EvalErr!i64 {
        var v = try ev.parseXor();
        while (true) {
            ev.skipWs();
            if (ev.match("|") or ev.matchKw("OR")) {
                v |= try ev.parseXor();
            } else break;
        }
        return v;
    }

    fn parseXor(ev: *Ev) EvalErr!i64 {
        var v = try ev.parseAnd();
        while (true) {
            ev.skipWs();
            if (ev.match("^") or ev.matchKw("XOR")) {
                v ^= try ev.parseAnd();
            } else break;
        }
        return v;
    }

    fn parseAnd(ev: *Ev) EvalErr!i64 {
        var v = try ev.parseShift();
        while (true) {
            ev.skipWs();
            if (ev.match("&") or ev.matchKw("AND")) {
                v &= try ev.parseShift();
            } else break;
        }
        return v;
    }

    fn parseShift(ev: *Ev) EvalErr!i64 {
        var v = try ev.parseAdd();
        while (true) {
            ev.skipWs();
            if (ev.match("<<") or ev.matchKw("SHL")) {
                v = try ev.shift(v, try ev.parseAdd(), .left);
            } else if (ev.match(">>") or ev.matchKw("SHR")) {
                v = try ev.shift(v, try ev.parseAdd(), .right);
            } else break;
        }
        return v;
    }

    fn shift(ev: *Ev, v: i64, by: i64, dir: enum { left, right }) EvalErr!i64 {
        if (by < 0 or by > 63) return ev.fail("shift count out of range: {d}", .{by});
        const u: u64 = @bitCast(v);
        const sh: u6 = @intCast(by);
        return @bitCast(switch (dir) {
            .left => u << sh,
            .right => u >> sh,
        });
    }

    fn parseAdd(ev: *Ev) EvalErr!i64 {
        var v = try ev.parseMul();
        while (true) {
            ev.skipWs();
            if (ev.match("+")) {
                v +%= try ev.parseMul();
            } else if (ev.match("-")) {
                v -%= try ev.parseMul();
            } else break;
        }
        return v;
    }

    fn parseMul(ev: *Ev) EvalErr!i64 {
        var v = try ev.parseUnary();
        while (true) {
            ev.skipWs();
            if (ev.match("*")) {
                v *%= try ev.parseUnary();
            } else if (ev.match("/")) {
                const d = try ev.parseUnary();
                if (d == 0) return ev.fail("division by zero", .{});
                v = @divTrunc(v, d);
            } else if (ev.match("%") or ev.matchKw("MOD")) {
                const d = try ev.parseUnary();
                if (d == 0) return ev.fail("division by zero", .{});
                v = @rem(v, d);
            } else break;
        }
        return v;
    }

    fn parseUnary(ev: *Ev) EvalErr!i64 {
        ev.skipWs();
        if (ev.match("-")) return -%(try ev.parseUnary());
        if (ev.match("+")) return ev.parseUnary();
        if (ev.match("~") or ev.matchKw("NOT")) return ~(try ev.parseUnary());
        if (ev.matchKw("HIGH")) return ((try ev.parseUnary()) >> 8) & 0xFF;
        if (ev.matchKw("LOW")) return (try ev.parseUnary()) & 0xFF;
        return ev.parsePostfix();
    }

    fn parsePostfix(ev: *Ev) EvalErr!i64 {
        var v = try ev.parsePrimary();
        while (true) {
            ev.skipWs();
            if (ev.match(".")) {
                ev.skipWs();
                const bitn = try ev.parsePrimary();
                v = try ev.bitMap(v, bitn);
            } else break;
        }
        return v;
    }

    /// Map `byte.bit` notation onto the 8051 bit address space.
    fn bitMap(ev: *Ev, byte: i64, bitn: i64) EvalErr!i64 {
        if (bitn < 0 or bitn > 7) return ev.fail("bit number must be 0..7, got {d}", .{bitn});
        if (byte >= 0x20 and byte <= 0x2F) return (byte - 0x20) * 8 + bitn;
        if (byte >= 0x80 and byte <= 0xF8 and @mod(byte, 8) == 0) return byte + bitn;
        return ev.fail("address 0x{X} is not bit-addressable", .{byte});
    }

    fn parsePrimary(ev: *Ev) EvalErr!i64 {
        ev.skipWs();
        if (ev.i >= ev.s.len) return ev.fail("expected expression", .{});
        const c = ev.s[ev.i];
        if (c == '(') {
            ev.i += 1;
            const v = try ev.parseOr();
            ev.skipWs();
            if (!ev.match(")")) return ev.fail("missing ')'", .{});
            return v;
        }
        if (c == '$') {
            ev.i += 1;
            return ev.a.dollar;
        }
        if (c == '\'') return ev.parseChar();
        if (std.ascii.isDigit(c)) return ev.parseNumber();
        if (isIdentStart(c)) {
            const n = identLen(ev.s[ev.i..]);
            const tok = ev.s[ev.i .. ev.i + n];
            ev.i += n;
            var buf: [64]u8 = undefined;
            if (upperTo(&buf, tok)) |up| {
                if (ev.a.syms.get(up)) |sym| return sym.value;
            }
            return ev.fail("undefined symbol '{s}'", .{tok});
        }
        return ev.fail("unexpected character '{c}' in expression", .{c});
    }

    fn parseChar(ev: *Ev) EvalErr!i64 {
        ev.i += 1; // opening quote
        if (ev.i >= ev.s.len) return ev.fail("unterminated character literal", .{});
        var c = ev.s[ev.i];
        if (c == '\'') return ev.fail("empty character literal", .{});
        ev.i += 1;
        if (c == '\\') {
            if (ev.i >= ev.s.len) return ev.fail("unterminated character literal", .{});
            c = unescape(ev.s[ev.i]) orelse return ev.fail("unknown escape '\\{c}'", .{ev.s[ev.i]});
            ev.i += 1;
        }
        if (ev.i >= ev.s.len or ev.s[ev.i] != '\'') return ev.fail("unterminated character literal", .{});
        ev.i += 1;
        return c;
    }

    fn parseNumber(ev: *Ev) EvalErr!i64 {
        const start = ev.i;
        while (ev.i < ev.s.len and std.ascii.isAlphanumeric(ev.s[ev.i])) ev.i += 1;
        const tok = ev.s[start..ev.i];
        return decodeNumber(tok) orelse ev.fail("invalid number '{s}'", .{tok});
    }
};

fn decodeNumber(tok: []const u8) ?i64 {
    if (tok.len == 0) return null;
    if (tok.len > 2 and tok[0] == '0' and (tok[1] == 'x' or tok[1] == 'X'))
        return std.fmt.parseInt(i64, tok[2..], 16) catch null;
    if (tok.len > 2 and tok[0] == '0' and (tok[1] == 'b' or tok[1] == 'B') and allBinary(tok[2..]))
        return std.fmt.parseInt(i64, tok[2..], 2) catch null;
    const last = std.ascii.toUpper(tok[tok.len - 1]);
    const head = tok[0 .. tok.len - 1];
    switch (last) {
        'H' => return std.fmt.parseInt(i64, head, 16) catch null,
        'B' => if (allBinary(head)) return std.fmt.parseInt(i64, head, 2) catch null else return null,
        'O', 'Q' => return std.fmt.parseInt(i64, head, 8) catch null,
        'D' => return std.fmt.parseInt(i64, head, 10) catch null,
        else => return std.fmt.parseInt(i64, tok, 10) catch null,
    }
}

fn allBinary(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c != '0' and c != '1') return false;
    return true;
}

fn unescape(c: u8) ?u8 {
    return switch (c) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        '0' => 0,
        '\\' => '\\',
        '\'' => '\'',
        '"' => '"',
        else => null,
    };
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '?';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '?';
}

/// Length of the identifier at the start of `s`, or 0.
fn identLen(s: []const u8) usize {
    if (s.len == 0 or !isIdentStart(s[0])) return 0;
    var i: usize = 1;
    while (i < s.len and isIdentChar(s[i])) i += 1;
    return i;
}

/// Uppercase `s` into `buf`; null if it does not fit.
fn upperTo(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return buf[0..s.len];
}

/// Remove a trailing `; comment`, respecting quoted strings.
fn stripComment(s: []const u8) []const u8 {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (c == '\\') {
                i += 1;
            } else if (c == quote) {
                quote = 0;
            }
        } else if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == ';') {
            return s[0..i];
        }
    }
    return s;
}

/// Split on top-level commas (outside parentheses and quotes).
fn splitTopLevel(arena: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var quote: u8 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (c == '\\') {
                i += 1;
            } else if (c == quote) {
                quote = 0;
            }
        } else switch (c) {
            '\'', '"' => quote = c,
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            ',' => if (depth == 0) {
                try parts.append(arena, s[start..i]);
                start = i + 1;
            },
            else => {},
        }
    }
    try parts.append(arena, s[start..]);
    return parts.items;
}

/// True if `t` (starting with a quote) is one complete string literal,
/// i.e. its matching close quote is the final character.
fn isWholeString(t: []const u8) bool {
    if (t.len < 2) return false;
    const q = t[0];
    var i: usize = 1;
    while (i < t.len) : (i += 1) {
        if (t[i] == '\\') {
            i += 1;
            continue;
        }
        if (t[i] == q) return i == t.len - 1;
    }
    return false;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

fn expectProgram(src: []const u8, addr: u32, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const res = try assemble(arena_state.allocator(), src);
    for (res.errors) |e| std.debug.print("line {d}: {s}\n", .{ e.line, e.msg });
    try testing.expectEqual(@as(usize, 0), res.errors.len);
    try testing.expectEqual(@as(usize, 1), res.chunks.len);
    try testing.expectEqual(addr, res.chunks[0].addr);
    try testing.expectEqualSlices(u8, expected, res.chunks[0].data);
}

fn expectError(src: []const u8, needle: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const res = try assemble(arena_state.allocator(), src);
    for (res.errors) |e| {
        if (std.mem.indexOf(u8, e.msg, needle) != null) return;
    }
    std.debug.print("expected error containing \"{s}\", got {d} error(s):\n", .{ needle, res.errors.len });
    for (res.errors) |e| std.debug.print("  line {d}: {s}\n", .{ e.line, e.msg });
    return error.TestExpectedError;
}

test "data transfer instructions" {
    try expectProgram(
        \\  mov a, #5
        \\  mov a, 40h
        \\  mov a, @r0
        \\  mov a, @r1
        \\  mov a, r0
        \\  mov a, r7
        \\  mov 40h, a
        \\  mov 40h, #0AAh
        \\  mov 41h, 40h
        \\  mov 40h, @r1
        \\  mov 40h, r2
        \\  mov @r0, a
        \\  mov @r1, #1
        \\  mov @r0, 40h
        \\  mov r5, a
        \\  mov r3, #7
        \\  mov r2, 40h
        \\  mov dptr, #1234h
        \\  mov c, p1.0
        \\  mov p1.1, c
        \\  xch a, 40h
        \\  xch a, @r0
        \\  xch a, r1
        \\  xchd a, @r1
        \\  push acc
        \\  pop psw
        \\  movx a, @dptr
        \\  movx a, @r0
        \\  movx @dptr, a
        \\  movx @r1, a
        \\  movc a, @a+dptr
        \\  movc a, @a+pc
    , 0, &.{
        0x74, 0x05, 0xE5, 0x40, 0xE6, 0xE7, 0xE8, 0xEF,
        0xF5, 0x40, 0x75, 0x40, 0xAA, 0x85, 0x40, 0x41,
        0x87, 0x40, 0x8A, 0x40, 0xF6, 0x77, 0x01, 0xA6,
        0x40, 0xFD, 0x7B, 0x07, 0xAA, 0x40, 0x90, 0x12,
        0x34, 0xA2, 0x90, 0x92, 0x91, 0xC5, 0x40, 0xC6,
        0xC9, 0xD7, 0xC0, 0xE0, 0xD0, 0xD0, 0xE0, 0xE2,
        0xF0, 0xF3, 0x93, 0x83,
    });
}

test "arithmetic and logic instructions" {
    try expectProgram(
        \\  add a, #1
        \\  add a, 40h
        \\  add a, @r0
        \\  add a, r1
        \\  addc a, #1
        \\  addc a, 40h
        \\  addc a, @r1
        \\  addc a, r2
        \\  subb a, #1
        \\  subb a, 40h
        \\  subb a, @r0
        \\  subb a, r3
        \\  inc a
        \\  inc 40h
        \\  inc @r0
        \\  inc r4
        \\  inc dptr
        \\  dec a
        \\  dec 40h
        \\  dec @r1
        \\  dec r5
        \\  orl a, #1
        \\  orl a, 40h
        \\  orl a, @r0
        \\  orl a, r6
        \\  orl 40h, a
        \\  orl 40h, #1
        \\  orl c, 20h.1
        \\  orl c, /20h.1
        \\  anl a, #1
        \\  anl a, 40h
        \\  anl a, @r1
        \\  anl a, r7
        \\  anl 40h, a
        \\  anl 40h, #1
        \\  anl c, ACC.7
        \\  anl c, /ACC.7
        \\  xrl a, #1
        \\  xrl a, 40h
        \\  xrl a, @r0
        \\  xrl a, r0
        \\  xrl 40h, a
        \\  xrl 40h, #1
        \\  clr a
        \\  clr c
        \\  clr P1.2
        \\  cpl a
        \\  cpl c
        \\  cpl P1.2
        \\  setb c
        \\  setb P1.2
        \\  rl a
        \\  rlc a
        \\  rr a
        \\  rrc a
        \\  swap a
        \\  da a
        \\  mul ab
        \\  div ab
        \\  jmp @a+dptr
        \\  ret
        \\  reti
        \\  nop
    , 0, &.{
        0x24, 0x01, 0x25, 0x40, 0x26, 0x29, 0x34, 0x01,
        0x35, 0x40, 0x37, 0x3A, 0x94, 0x01, 0x95, 0x40,
        0x96, 0x9B, 0x04, 0x05, 0x40, 0x06, 0x0C, 0xA3,
        0x14, 0x15, 0x40, 0x17, 0x1D, 0x44, 0x01, 0x45,
        0x40, 0x46, 0x4E, 0x42, 0x40, 0x43, 0x40, 0x01,
        0x72, 0x01, 0xA0, 0x01, 0x54, 0x01, 0x55, 0x40,
        0x57, 0x5F, 0x52, 0x40, 0x53, 0x40, 0x01, 0x82,
        0xE7, 0xB0, 0xE7, 0x64, 0x01, 0x65, 0x40, 0x66,
        0x68, 0x62, 0x40, 0x63, 0x40, 0x01, 0xE4, 0xC3,
        0xC2, 0x92, 0xF4, 0xB3, 0xB2, 0x92, 0xD3, 0xD2,
        0x92, 0x23, 0x33, 0x03, 0x13, 0xC4, 0xD4, 0xA4,
        0x84, 0x73, 0x22, 0x32, 0x00,
    });
}

test "branches, calls and relative offsets" {
    try expectProgram(
        \\        org 100h
        \\top:    sjmp top
        \\        jc top
        \\        jnc top
        \\        jz top
        \\        jnz top
        \\        jb p1.0, top
        \\        jnb p1.0, top
        \\        jbc p1.0, top
        \\        cjne a, #5, top
        \\        cjne a, 40h, top
        \\        cjne @r0, #5, top
        \\        cjne r7, #5, top
        \\        djnz 40h, top
        \\        djnz r2, top
        \\        acall sub1
        \\        ajmp sub1
        \\        lcall sub1
        \\        ljmp sub1
        \\        sjmp $
        \\        org 130h
        \\sub1:   ret
    , 0x100, &.{
        0x80, 0xFE, 0x40, 0xFC, 0x50, 0xFA, 0x60, 0xF8,
        0x70, 0xF6, 0x20, 0x90, 0xF3, 0x30, 0x90, 0xF0,
        0x10, 0x90, 0xED, 0xB4, 0x05, 0xEA, 0xB5, 0x40,
        0xE7, 0xB6, 0x05, 0xE4, 0xBF, 0x05, 0xE1, 0xD5,
        0x40, 0xDE, 0xDA, 0xDC, 0x31, 0x30, 0x21, 0x30,
        0x12, 0x01, 0x30, 0x02, 0x01, 0x30, 0x80, 0xFE,
        0x22,
    });
}

test "directives, expressions and number formats" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const res = try assemble(arena_state.allocator(),
        \\val   equ 30h
        \\cnt   set 2
        \\cnt   set cnt+1
        \\flag  bit 2Ch.3
        \\      org 200h
        \\tab:  db 1, 2, 'A', "hi", 0FFh, low(tab), high(tab), -1
        \\      dw 1234h, tab, 'A'
        \\      ds 4
        \\after: mov a, #val
        \\      setb flag
        \\      mov a, #cnt
        \\      db $ - tab
        \\      end
    );
    for (res.errors) |e| std.debug.print("line {d}: {s}\n", .{ e.line, e.msg });
    try testing.expectEqual(@as(usize, 0), res.errors.len);
    try testing.expectEqual(@as(usize, 2), res.chunks.len);
    try testing.expectEqual(@as(u32, 0x200), res.chunks[0].addr);
    try testing.expectEqualSlices(u8, &.{
        0x01, 0x02, 0x41, 0x68, 0x69, 0xFF, 0x00, 0x02,
        0xFF, 0x12, 0x34, 0x02, 0x00, 0x00, 0x41,
    }, res.chunks[0].data);
    try testing.expectEqual(@as(u32, 0x213), res.chunks[1].addr);
    try testing.expectEqualSlices(u8, &.{ 0x74, 0x30, 0xD2, 0x63, 0x74, 0x03, 0x19 }, res.chunks[1].data);
}

test "number formats" {
    try expectProgram(
        \\ db 255, 0FFh, 0xFF, 11111111b, 0b1010, 1010b, 17o, 17q, 65d, 'A', '\n', '\0'
        \\ db 1+2*3, (1+2)*3, 10 mod 3, 10 % 3, 1 shl 4, 1 << 4, 0F0h shr 4
        \\ db 0FH and 3, 1 or 2, 5 xor 1, not 0 and 0FFh, low(1234h), high(1234h)
        \\ db -1, ~0 & 0ffh
    , 0, &.{
        0xFF, 0xFF, 0xFF, 0xFF, 0x0A, 0x0A, 0x0F, 0x0F, 0x41, 0x41, 0x0A, 0x00,
        0x07, 0x09, 0x01, 0x01, 0x10, 0x10, 0x0F,
        0x03, 0x03, 0x04, 0xFF, 0x34, 0x12,
        0xFF, 0xFF,
    });
}

test "labels, case insensitivity and $ symbol" {
    try expectProgram(
        \\Start: NOP
        \\loop:  SJMP LOOP
        \\here:  sjmp $
        \\       LJMP Start
    , 0, &.{ 0x00, 0x80, 0xFE, 0x80, 0xFE, 0x02, 0x00, 0x00 });
}

test "forward references" {
    try expectProgram(
        \\  ljmp fwd
        \\  mov a, #low(fwd)
        \\  sjmp fwd
        \\fwd: nop
    , 0, &.{ 0x02, 0x00, 0x07, 0x74, 0x07, 0x80, 0x00, 0x00 });
}

test "errors" {
    try expectError("  sjmp nowhere\n", "undefined symbol 'nowhere'");
    try expectError("x equ 1\nx equ 2\n", "duplicate symbol 'X'");
    try expectError("a: nop\na: nop\n", "duplicate symbol 'A'");
    try expectError("  org 0\n  sjmp far\n  org 300h\nfar: nop\n", "branch target out of range");
    try expectError("  org 0\n  ajmp far\n  org 0F00h\nfar: nop\n", "not in the same 2KB page");
    try expectError("  mov a, #300h\n", "immediate value out of range");
    try expectError("  mov a, 100h\n", "direct address out of range");
    try expectError("  setb 81h.0\n", "not bit-addressable");
    try expectError("  setb p1.8\n", "bit number must be 0..7");
    try expectError("  frobnicate a\n", "unknown instruction");
    try expectError("  mul a\n", "invalid operand(s) for 'mul'");
    try expectError("  org 0\n  nop\n  org 0\n  nop\n", "overlapping code");
    try expectError("  db 1/0\n", "division by zero");
    try expectError("  db 'unterminated\n", "unterminated");
}

/// In-memory file system for include tests.
const TestFs = struct {
    files: []const [2][]const u8,

    fn load(ctx: *anyopaque, arena: Allocator, path: []const u8, from_file: []const u8) ?LoadedFile {
        _ = arena;
        _ = from_file;
        const self: *TestFs = @ptrCast(@alignCast(ctx));
        for (self.files) |f| {
            if (std.mem.eql(u8, f[0], path)) return .{ .source = f[1], .name = f[0] };
        }
        return null;
    }

    fn loader(self: *TestFs) FileLoader {
        return .{ .ctx = self, .load = TestFs.load };
    }
};

test "include splices files and shares symbols" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fs = TestFs{ .files = &.{
        .{ "defs.inc", "LED bit P1.0\nSTART_VAL equ 42\n" },
        .{ "util.asm", "blink: cpl LED\n ret\n" },
    } };
    const res = try assembleOpts(arena_state.allocator(),
        \\ .include "defs.inc"
        \\ mov a, #START_VAL
        \\ acall blink
        \\ include util.asm
    , .{ .file_name = "main.asm", .loader = fs.loader() });
    for (res.errors) |e| std.debug.print("{s}:{d}: {s}\n", .{ e.file, e.line, e.msg });
    try testing.expectEqual(@as(usize, 0), res.errors.len);
    try testing.expectEqual(@as(usize, 1), res.chunks.len);
    try testing.expectEqualSlices(u8, &.{ 0x74, 0x2A, 0x11, 0x04, 0xB2, 0x90, 0x22 }, res.chunks[0].data);
}

test "nested includes and the $INCLUDE control form" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fs = TestFs{ .files = &.{
        .{ "a.inc", " db 1\n .include \"b.inc\"\n db 3\n" },
        .{ "b.inc", " db 2\n" },
    } };
    const res = try assembleOpts(arena_state.allocator(),
        \\$include(a.inc)
        \\ db 4
    , .{ .file_name = "main.asm", .loader = fs.loader() });
    for (res.errors) |e| std.debug.print("{s}:{d}: {s}\n", .{ e.file, e.line, e.msg });
    try testing.expectEqual(@as(usize, 0), res.errors.len);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, res.chunks[0].data);
}

test "errors are attributed to the included file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fs = TestFs{ .files = &.{
        .{ "bad.inc", " nop\n mov a, 300h\n" },
    } };
    const res = try assembleOpts(arena_state.allocator(), " .include \"bad.inc\"\n", .{
        .file_name = "main.asm",
        .loader = fs.loader(),
    });
    try testing.expectEqual(@as(usize, 1), res.errors.len);
    try testing.expectEqualStrings("bad.inc", res.errors[0].file);
    try testing.expectEqual(@as(u32, 2), res.errors[0].line);
}

test "include error cases" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fs = TestFs{ .files = &.{
        .{ "loop.inc", " .include \"loop.inc\"\n" },
    } };
    const res = try assembleOpts(arena_state.allocator(),
        \\ .include "loop.inc"
        \\ .include "missing.inc"
        \\ .include
    , .{ .file_name = "main.asm", .loader = fs.loader() });
    var found_circular = false;
    var found_missing = false;
    var found_no_path = false;
    for (res.errors) |e| {
        if (std.mem.indexOf(u8, e.msg, "circular") != null) found_circular = true;
        if (std.mem.indexOf(u8, e.msg, "cannot open include file 'missing.inc'") != null) found_missing = true;
        if (std.mem.indexOf(u8, e.msg, "requires a file path") != null) found_no_path = true;
    }
    try testing.expect(found_circular);
    try testing.expect(found_missing);
    try testing.expect(found_no_path);

    // Without a loader, INCLUDE is an error rather than silently ignored.
    try expectError("  .include \"x.inc\"\n", "no file loader");
}

test "dotted directives" {
    try expectProgram(
        \\    .org 10h
        \\    .db 1, 2
        \\val .equ 3
        \\    .db val
    , 0x10, &.{ 1, 2, 3 });
    try expectError("  .frobnicate 1\n", "unknown directive");
}

test "ds leaves gaps and org reorders" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const res = try assemble(arena_state.allocator(),
        \\ org 10h
        \\ nop
        \\ ds 2
        \\ nop
    );
    try testing.expectEqual(@as(usize, 0), res.errors.len);
    try testing.expectEqual(@as(usize, 2), res.chunks.len);
    try testing.expectEqual(@as(u32, 0x10), res.chunks[0].addr);
    try testing.expectEqual(@as(u32, 0x13), res.chunks[1].addr);
}
