# Code actions

## Quick fixes

Edits are built from the CST, anchored at the spans of compiler diagnostics.

- **Discards**: a `var`, an error set, or an error union is discarded by address (`_ = &x;`), since Sema rejects discarding errors and a discard does not count as mutating a `var`.
- **`const`**: a never-mutated local `var` becomes `const` by replacing only the keyword; `comptime var` also wraps the initializer in `comptime`.

## String literal conversion

String conversion (`refactor.rewrite`) looks only at the syntax tree and source text, and preserves the actual bytes. Converting to a multiline string is not offered when a string has bytes the form cannot hold, nor where Zig requires a regular literal (`@import`, `build.zig.zon` manifests).

In a file already formatted with `zig fmt`, the edit is laid out by `zig fmt`, so the file stays formatted; otherwise only the literal is replaced.

## Organize imports (`source.organizeImports`, `ide_db/organize_imports.zig`)

- **Blocks**: consecutive top-level imports and declarations derived from them, with only blank lines between, are organized in place. Attached comments move with their declaration, and a file header stays first. Declarations are never moved between blocks or removed, and nothing is organized with syntax errors.
- **Order**: `std` / `builtin` / `root`, dependency modules, then files, with a blank line between groups. `imports.derived` and `imports.sort` set the style and can be shared through `zig-analyzer.zon`. Comparisons use rustfmt's version sort, as rust-analyzer does.
- **When offered**: always when requested through `context.only`, which keybindings and organize on save use; in menus, only when the range intersects a block. It is not offered when already organized, and applying it twice changes nothing.

## Removing unused parameters (`ide/remove_param.zig`)

Offered on AstGen's `unused function parameter`, besides the preferred discard, for functions with a body in the user's code. Not offered for `export` / `extern` or variadic functions, or receivers of methods.

- **Call sites**: searched in the same scope as rename. Every reference must be the callee of a call with a matching argument count, and in a generic function all instances must agree on whether `x.f(...)` passes `x`.
- **Refusal**: no partial edits. A fix is refused with a reason when any place cannot be updated: the function is used other than in a call, a reference cannot be confirmed, its name appears as a string literal in a file that can access it, a method call passes the receiver as the removed parameter, or a removed argument may have side effects.
- **Validation**: AstGen errors before and after are compared per file, and new errors refuse the fix. The exception is another parameter of the same list that becomes unused, which can be removed next.
- **Limits**: only calls in the workspace are updated for `pub` functions, so with change annotation support the edit needs user confirmation.

## Unused captures (`ide/unused_capture.zig`)

Offered on AstGen's `unused capture` or `unused switch tag capture`, as "remove capture" or "rename to `_`". Only rewrites that keep the meaning are offered, following AstGen's rules. It is preferred only when no discard can be inserted.

- **Removing**: an optional `if` / `while` compares its condition with null (`if (x != null)`), and `catch |err|`, switch captures, and unbounded for counters drop the capture. AstGen checks a rewritten for input that contains a name.
- **Renaming**: used where removal would change the meaning, such as both captures of an error union `if`; a pointer capture loses its `*`.

## Naming checks

These follow the Names section of the Zig 0.17.1 style guide, are off by default, and are enabled by `naming.enable`.

- **Classification**: style follows what a declaration actually represents, not its keyword: types and functions returning `type` are TitleCase, other callables camelCase, and namespaces and other values snake_case. Only abstract-instance results are used, so one call site's instance is never generalized.
- **Skipped**: whatever is unknown or instance-dependent, or where a style is not decidable: extern and export declarations, `@compileError` stubs, root declarations std looks up by name, same-name re-exports, `@"..."` names, and names with an ambiguous word split. Dependency libraries, generated code, and `naming.exclude` are not checked.
- **Hints**: published for open files only, with code `naming.<rule>` and a link to the rule. `naming.ignore` and `naming.rules` set exceptions. Results are cached per member, so an edit recomputes only changed members, reads no other files, and starts no compiler.
- **Fixes**: refused in the same cases as rename (see `docs/features/references-rename.md`), with a final AstGen check of the renamed file. Only workspace references of public names are updated, so with change annotation support the edit needs confirmation.
