//! zinc51 — the Zig INtel-51 Cross-assembler, an assembler for the
//! Intel MCS-51 (8051) instruction set.

pub const assembler = @import("assembler.zig");
pub const output = @import("output.zig");

pub const assemble = assembler.assemble;
pub const Result = assembler.Result;
pub const Chunk = assembler.Chunk;
pub const Error = assembler.Error;
pub const ListEntry = assembler.ListEntry;

test {
    _ = assembler;
    _ = output;
}
