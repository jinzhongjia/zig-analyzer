# Inlay hints

Inlay hints are based on inference results and name resolution. How types are shortened is described under Value display in `docs/features/navigation.md`.

## Options

| Option | Default | Effect |
|---|---|---|
| `inlay_hints.types` | on | Inferred types of local variables without an annotation; constants whose value is a type get none |
| `inlay_hints.field_types` | on | Field types in initializers; anonymous initializers without a result type get none |
| `inlay_hints.anonymous_containers` | off | Also show type hints containing an anonymous container |
| `inlay_hints.parameters` | on | Parameter names at calls |
| `inlay_hints.builtin_parameters` | on | Parameter names at builtin calls; hidden when `parameters` is off |
| `inlay_hints.exclude_single_argument` | on | No names for calls with one written argument, builtins included |
| `inlay_hints.hide_redundant_param_names` | on | No name when the argument already has it, builtins included |
| `inlay_hints.max_length` | 25 | Approximate limit on the length of a type hint, 0 for no limit (see `docs/features/navigation.md`) |

## Behavior

- **Generic bodies**: when a type cannot be inferred, a call-site instance is used, and the tooltip names the call.
- **Calls through function values** take names from the `fn (...)` type of the value's declaration or the function it is initialized with, the same as signature help.
- **Builtins**: a table in `inlay_hints.zig` decides each multi-parameter builtin, showing names only when they add information; a newly added one is a compile error until the table decides it. Single-parameter builtins show names, subject to the single-argument rule.
- **Redundant names** are decided on the HIR rather than the last token, after stripping wrappers that keep the value (`&x`, `x.*`, `x.?`, `try x`): `a + x` produces a new value and is annotated.
- **Refresh**: `workspace/inlayHint/refresh` is requested when an option changes and, coalesced, after changes the client cannot see, as for semantic tokens.
