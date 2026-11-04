# Formatting

Formatting runs in process, with the renderer of the user's Zig version. `src/ide/render/` holds the complete `std.zig.Ast.Render` of Zig 0.17.0 and 0.17.1 (MIT license, in `LICENSE` there); the only change is how each imports `std`. When zig is not found or its version is not supported, the renderer of the Zig that zig-analyzer was built with is used.

The renderers differ in array and tuple initializers: which blank lines are kept, whether elements on one line are split, and how columns are aligned.

The parser is not copied: text is parsed by `std.zig.Ast.parse` of the Zig that zig-analyzer was built with. The result is byte-for-byte identical to `zig fmt` of the user's version, except where the parsers of the two versions accept different text, which only matters when the two versions differ:

| Text | 0.17.0 | 0.17.1 | Built with 0.17.1, user's zig 0.17.0 | Built with 0.17.0, user's zig 0.17.1 |
|---|---|---|---|---|
| `/// doc` before the variadic marker `...` | accepts | rejects | not formatted | formatted, though `zig fmt` refuses |
| `[*c` directly followed by a comment | rejects | accepts | formatted, though `zig fmt` refuses | not formatted |

These differences are accepted: such text is rare, and copying the parser as well would keep a second parser for it.

Deeply nested text is formatted on a dedicated thread (with a stack sized by the estimated depth, at most 8 GiB), and text whose estimated depth exceeds 147456 (36864 on 32-bit platforms) is rejected.

The limit is calibrated on common nesting forms: `zig fmt` (46 MiB main-thread stack) can format up to 36864 levels (consecutive prefix operators can go deeper); on 64-bit platforms the limit is 4 times that.
