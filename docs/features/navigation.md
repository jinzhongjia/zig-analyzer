# Goto, hover, and signature help

Goto definition, goto declaration, goto type definition, hover, and signature help are based on inference results and name resolution. Builtins are described under Builtins in `docs/features/completion.md`.

## Goto and hover for `error.Foo`

The lookup searches `error{ ... }` declarations, preferring one whose members equal the expected error set, then one that is part of it, then any containing the name. It searches the current file, then files reachable via `@import`, and memoizes each file's sets (`ErrorSets`).

## Type display

Hover, inlay hints, and completion details share `render.zig`.

- A container that is the value of a member is named after the member, also when an `if` / `switch` chooses among several (more readable than the compiler's `S__struct_1`).
- A `return`ed container is named after the function and its comptime arguments (`List(u8)`), and one named inside a generic instance is qualified as the compiler names it (`Outer(u8).Inner`).
- Containers without a name in the source are displayed by their contents; a self-reference is `struct {...}`, so expansion always ends.

## Value display

A declaration is displayed as `const x: T = v`. At a reference, `T` is the reference's own type, not its coerced result type. A tuple or anonymous struct with only comptime fields shows just the value.

- **Hover and completion details** list types in full, without truncation. Values are cut at about 2000 characters (`render.max_value_length`), marked by `…` and the full size.
- **`@embedFile`**: a value directly from it is shown as the call, not its bytes. Hover adds the resolved file and size, and the text when it is short, valid text. Values computed from the content keep the cut display.
- **Inlay hints** are inline, with nested anonymous containers as `struct {...}`. A type hint is at most about `inlay_hints.max_length` characters (default 25, 0 for no limit), and may exceed that by one list item.
