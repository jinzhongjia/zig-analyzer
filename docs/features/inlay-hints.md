# Inlay hints

Inlay hints are based on inference results and name resolution. How types are shortened is described under Value display in `docs/features/navigation.md`.

## Local variable types (`inlay_hints.types`)

Local variables without a type annotation show their inferred type; when the type cannot be inferred inside a generic function body, the instance from a call site is used, and the tooltip names the call it is based on. Constants whose value is a type get no hint.

## Field types (`inlay_hints.field_types`)

- In initializers (`T{ ... }`, `.{ ... }`), the type of each field is shown after the field name.
- The initializer's type is the same as in inference: the written type, or the result type with error union and optional stripped (the type recorded for the expression has already been converted to the result type and cannot be used directly); generic containers use the types in the instance.
- Anonymous initializers without a result type get no hints: their field types are just the types of the values.

## Anonymous containers (`inlay_hints.anonymous_containers`, off by default)

When a type contains an anonymous container displayed by its contents, neither local variable type hints nor field type hints are shown; turning the option on shows them. Hover and completion details are unaffected and always show such types.

## Parameter names (`inlay_hints.parameters`)

- Ordinary calls take the parameter names from the function declaration, and method calls skip the receiver;
- calls through a value of function type (function pointers, vtable fields, callback parameters and captures) take them from the `fn (...)` type expression the value's declaration is typed with (through pointers, optionals, and type aliases), or from the function declaration it is initialized with (`const f = &add;`), the same as signature help.
- For builtins (`inlay_hints.builtin_parameters`; also hidden when `parameters` is off), parameter names come from the parameters in the official documentation, with the `comptime` / `noalias` prefixes removed.
- Whether a multi-parameter builtin shows them is decided by a table in `inlay_hints.zig` that covers every multi-parameter builtin: they are shown only when the names add information the arguments do not reveal (arguments of the same type in an unconventional order, configuration passed by position to type constructors, an unusual parameter order), and a newly added multi-parameter builtin is a compile error until the table decides it.
- Single-parameter builtins all show names, subject to the single-argument rule; variadic builtins and builtins without parameters have no names to show.

## Single-argument calls (`inlay_hints.exclude_single_argument`, on by default)

Calls with only one argument show no parameter names, counting the arguments as written: a method call left with one argument after the receiver is removed counts too. This also applies to builtins.

## Redundant parameter names (`inlay_hints.hide_redundant_param_names`, on by default)

- No name is shown when the argument, after stripping wrappers that do not change the value it refers to (`&x`, `x.*`, `x.?`, `try x`, possibly nested), is a variable with the same name as the parameter, or a field access whose last segment has the parameter's name.
- This is decided on the HIR rather than by comparing the last token of the argument: `a + x`, `-%x`, and `x orelse y` produce new values and are annotated as usual.
- This also applies to builtins.

## Refresh

When any of these options changes, a refresh is requested (`workspace/inlayHint/refresh`) if the client supports it; like the semantic tokens refresh, it is also requested (coalesced until the client responds) after changes the client cannot see: another document edited, opened or closed, files changed on disk, and the standard library or module graph loaded.
