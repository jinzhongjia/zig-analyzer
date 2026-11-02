# Formatting

`std.zig.Ast.render`, byte-for-byte identical to `zig fmt`; deeply nested text is formatted on a dedicated thread (with a stack sized by the estimated depth, at most 8 GiB), and text whose estimated depth exceeds 147456 (36864 on 32-bit platforms) is rejected. The limit is calibrated on common nesting forms: `zig fmt` (46 MiB main-thread stack) can format up to 36864 levels (consecutive prefix operators can go deeper); on 64-bit platforms the limit is 4 times that

