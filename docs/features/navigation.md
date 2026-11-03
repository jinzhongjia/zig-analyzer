# Goto, hover, and signature help

Goto definition, goto declaration, goto type definition, hover, and signature help are based on inference results and name resolution. Builtins are described under Builtins in `docs/features/completion.md`.

## Goto and hover for `error.Foo`

- The lookup searches `error{ ... }` declarations:
  - one whose members are exactly the expected error set ranks first, then one that is part of the expected error set (`A` in `A || B`), then any one that contains the name;
  - the current file is searched first, then the files reachable via `@import` (filtered by name with `FileIndex`), until one that cannot be superseded is found (the first one when there is no expected error set);
  - the error set declarations of each file are memoized per file (`ErrorSets`), so repeated lookups do not parse the files again.

## Type display

- Hover, inlay hints, and completion details share the type display (`render.zig`):
  - a container that is the value of a member is named after the member: `const S = struct {...}` is `S`;
  - in a function body it is named after the local constant;
  - a `return`ed container is named after the function and its comptime arguments (`List(u8)`);
  - only that returned type carries the arguments, and a container named inside a generic instance is qualified by the named container or function, as the compiler names it (`Outer(u8).Inner`, `Outer(u8).Gen(u16)`, and `List.S` for a local constant of a generic function, without the arguments);
  - when the value is an `if` / `switch` choosing among several containers, it is likewise named after the member (the compiler names it `S__struct_1` here; naming it after the member is more readable).
- Containers in type annotations of fields and variables, in arguments, in `?struct {...}`, and the like have no name in the source and are displayed by their contents:
  - `packed struct { x: u8 }` and `union(enum) { a: u32, b: void }` list the fields and their types (enums list only the names);
  - anonymous containers nested inside them are expanded the same way, and a self-reference (`?*const @This()`) is displayed as `struct {...}`, so the expansion is never infinite.

## Value display

- A declaration is displayed as `const x: T = v`, with the comptime-known value written after the type; at a reference, `T` is the type of the reference itself, not the type its result type coerces it to (`a: u8` passed to a `?u8` parameter is shown as `u8`).
- The type of a tuple or anonymous struct whose fields are all comptime fields is fully determined by its value (the type of `.{ A, B }` is `struct { comptime type = A, comptime type = B }`, the same as in the compiler), so only the value is shown: `const qs = .{ A, B }`.
- Hover and completion details list the full contents of types, without truncation (`@typeName` instead gives the compiler's fully qualified name, such as `main.S.Inner` or `array_list.Aligned(u8,null)`, and has no value when that name cannot be determined exactly, e.g. for containers the compiler names after a global counter);
- a value in hover and completion details is cut at about 2000 characters (`render.max_value_length`), and the cut is marked by `…` followed by the full number of items or bytes (`.{ 7, 7, … (3000 total) }`, `"ab…" (1048576 bytes total)`).
- A value that is directly the result of `@embedFile` (a constant initialized with the call, also with a type annotation the content coerces to such as `[]const u8`; a variable initialized with it whose value is known at comptime; the call expression itself) is shown as the call instead of its bytes, with the type unchanged: `const blob: *const [1048576:0]u8 = @embedFile("blob.bin")`, at the declaration, at references and in completion details.
- Hover adds the file the path resolves to, relative to the workspace folder containing it (otherwise absolute), and its size (``Embedded file `assets/blob.bin`: 1048576 bytes``);
- when the content is text (valid UTF-8 without control characters other than tab, line feed and carriage return) of at most `render.max_value_length` characters, the text follows in a `text` fenced block whose fence is longer than any run of backticks in it.
- Values computed from the content (a slice, a concatenation) keep the cut display.
- Inlay hints are shown inline, with nested anonymous containers displayed as `struct {...}`;
- a type hint is at most about `inlay_hints.max_length` characters (25 by default, 0 for no limit, the same as rust-analyzer's `inlayHints.maxLength`): if the output is already full before the next item of a list (fields, elements, arguments, parameters) is written, `…` is written and output stops, so a hint may exceed the limit by one item;
- strings are written only up to the limit.
