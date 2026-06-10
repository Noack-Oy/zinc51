# zinc51

**Z**ig **IN**tel-51 **C**ross-assembler — a two-pass assembler for the Intel
MCS-51 (8051) instruction set, written in Zig (0.16). Produces Intel HEX,
flat binary images, and listing files.

## About the name

* **Z**ig **IN**tel-51 **C**ross-assembler
* `INC` is an actual 8051 instruction — "one more", in the proud *yet
  another assembler* tradition
* zinc is the metal you galvanize with to keep rust away; this project is
  written in Zig

## Building

```
zig build              # builds zig-out/bin/zinc51
zig build test         # runs the test suite
zig build run -- examples/blink.asm
```

## Usage

```
zinc51 <input.asm> [options]

  -o <file>         Intel HEX output path (default: <input>.hex)
  -b, --bin <file>  also write a flat binary image (gaps filled with 0xFF)
  -l, --lst <file>  also write a listing file
  -h, --help        show this help
```

Example:

```
zinc51 examples/blink.asm -l blink.lst
zinc51: 25 byte(s) at 0x0000..0x0045 -> examples/blink.hex
```

Errors are reported as `file:line: error: message`; exit code is non-zero and
no output is written when the source has errors.

## Assembler dialect

Everything is **case-insensitive**. A line has the classic form:

```
label:  mnemonic operand, operand   ; comment
```

### Instructions

The complete MCS-51 instruction set (all 255 opcodes) with standard operand
syntax: `A`, `AB`, `C`, `DPTR`, `R0`–`R7`, `@R0`, `@R1`, `@DPTR`, `@A+DPTR`,
`@A+PC`, `#immediate`, direct addresses, bit addresses, and `/bit` (inverted
bit for `ANL C,/bit` / `ORL C,/bit`). `JMP addr` and `CALL addr` assemble as
`LJMP`/`LCALL`. `AJMP`/`ACALL` verify that the target lies in the same 2 KB
page; relative branches verify the −128…+127 range.

### Directives

| Directive | Meaning |
|---|---|
| `ORG expr` | set the location counter |
| `name EQU expr` | define a constant (also `DATA`, `IDATA`, `XDATA`, `CODE`) |
| `name SET expr` | like `EQU`, but redefinable |
| `name BIT expr` | define a bit-address symbol, e.g. `LED BIT P1.0` |
| `DB item, ...` | emit bytes; items are expressions or strings (`'…'` or `"…"`) |
| `DW item, ...` | emit 16-bit words, high byte first |
| `DS expr` | reserve space (no bytes emitted) |
| `END` | stop assembling |

Lines starting with `$` (assembler controls such as `$MOD51`) are ignored.

### Expressions

* Numbers: `255`, `0FFh`, `0xFF`, `11111111b`, `0b1010`, `17o`/`17q` (octal),
  `99d`, character literals `'A'` (escapes: `\n \r \t \0 \\ \' \"`)
* `$` is the address of the current statement
* Operators by precedence: `byte.bit` (bit addressing), unary `- + ~ NOT HIGH
  LOW`, `* / % MOD`, `+ -`, `<< >> SHL SHR`, `& AND`, `^ XOR`, `| OR`,
  parentheses
* `byte.bit` maps onto the 8051 bit space: bytes `20h`–`2Fh` map to bits
  `00h`–`7Fh`; SFRs at addresses divisible by 8 map to `byte+bit` (e.g.
  `P1.3` = `93h`). Other addresses are rejected as not bit-addressable.

### Predefined symbols

All standard 8051 SFRs (`P0`–`P3`, `SP`, `DPL`, `DPH`, `PCON`, `TCON`, `TMOD`,
`TL0/1`, `TH0/1`, `SCON`, `SBUF`, `IE`, `IP`, `PSW`, `ACC`, `B`) and SFR bits
(`TR0/1`, `TF0/1`, `TI`, `RI`, `EA`, `CY`, `OV`, …) are predefined.

## Library use

The core is exposed as a Zig module (`zinc51`):

```zig
const zinc51 = @import("zinc51");

var arena = std.heap.ArenaAllocator.init(gpa);
defer arena.deinit();
const result = try zinc51.assemble(arena.allocator(), source);
if (!result.ok()) {
    for (result.errors) |e| ... // e.line, e.msg
}
for (result.chunks) |c| ... // c.addr, c.data
const hex = try zinc51.output.renderIhex(arena.allocator(), result.chunks);
```

## Layout

* [src/assembler.zig](src/assembler.zig) — parser, expression evaluator,
  two-pass driver, instruction encoder
* [src/output.zig](src/output.zig) — Intel HEX / binary / listing renderers
* [src/main.zig](src/main.zig) — CLI
* [examples/](examples) — sample programs
