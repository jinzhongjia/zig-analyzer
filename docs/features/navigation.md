# Goto, hover, and signature help

Goto definition, goto declaration, goto type definition, hover, and signature help are based on inference results and name resolution. Builtins are described under Builtins in `docs/features/completion.md`.

## Goto and hover for `error.Foo`

The lookup searches `error{ ... }` declarations, preferring one whose members equal the expected error set, then one that is part of it, then any containing the name. It searches the current file, then files reachable via `@import`, and memoizes each file's sets (`ErrorSets`).

## Generic function bodies

A generic function body is inferred with the instance of a call site, and hover names the call (`inferred from the call at main.zig:4`). This includes an enum literal or an initializer field whose result type is a parameter (`return .empty` and `.{ .len = 3 }` in a function returning `T`), which name a declaration or field only under an instance.

A member name can refer to a different declaration under each instance. Goto lists the declaration under the selected instance first, then the one under every other instance; find references and document highlight cover all of them. Hover shows the declaration under the selected instance, followed by the others, each once and in goto order, as set by `hover.instances`:

- `"list"` (default): one line per other declaration, with its signature (without the value), its location, and the call that selects it.
- `"full"`: the complete hover of each other declaration (code, value, call, documentation), separated by rules.

A name that refers to the same declaration under every instance is shown as before. Finding the other declarations infers the body under every instance; its cost is described under Hover in generic function bodies in `docs/perf.md`.

## Type display

Hover, inlay hints, and completion details share `render.zig`.

- A container that is the value of a member is named after the member, also when an `if` / `switch` chooses among several (more readable than the compiler's `S__struct_1`).
- A `return`ed container is named after the function and its comptime arguments (`List(u8)`), and one named inside a generic instance is qualified as the compiler names it (`Outer(u8).Inner`).
- Containers without a name in the source are displayed by their contents; a self-reference is `struct {...}`, so expansion always ends.
- An enum displayed by its contents keeps what its declaration gives it: the tag type of `enum(T)`, the values written for members (as evaluated), and `_` when it is non-exhaustive (`enum(u8) { a = 1, b, _ }`). An enum constructed by `@Enum` shows its tag type and the value of every member.

## Value display

A declaration is displayed as `const x: T = v`. At a reference, `T` is the reference's own type, not its coerced result type. A tuple or anonymous struct with only comptime fields shows just the value.

A value of a non-exhaustive enum that no member has is shown as the compiler prints it, `@fromBackingInt(15)`; one a member has is that member (`.b`).

- **Hover and completion details** list types in full, without truncation. Values are cut at about 2000 characters (`render.max_value_length`), marked by `…` and the full size.
- **Layout**: completion details keep a value on one line. Hover breaks a value that does not fit in 80 columns, with each item of a `.{ ... }` list on its own line and broken the same way; lists of atoms such as numbers and strings fill their lines. Types stay on one line.
- **`@embedFile`**: a value directly from it is shown as the call, not its bytes. Hover adds the resolved file and size, and the text when it is short, valid text. Values computed from the content keep the cut display.
- **Inlay hints** are inline, with nested anonymous containers as `struct {...}`. A type hint is at most about `inlay_hints.max_length` characters (default 25, 0 for no limit), and may exceed that by one list item.

## Fields of `.zon` values

Goto on a field of a value imported from a `.zon` file reads the literal from the type of the value and goes to the name in the file, including through a copy, a parameter of a generic function (one target per instance), and the items of a tuple being iterated.
