# Code actions

## Quick fixes

Edits are built from the CST, anchored at the spans of compiler diagnostics.

### Discards

Unused parameters and similar errors are discarded; a `var`, an error set, or an error union is discarded by address, `_ = &x;`, since Sema rejects discarding errors and a discard does not count as mutating a `var`.

### `const` for a never-mutated `var`

A local `var` that is never mutated (`local variable is never mutated`) becomes `const` (`use 'const'`) by replacing only the keyword, and `comptime var` becomes `const` with the initializer wrapped in `comptime` (`comptime const` is invalid); destructuring with `comptime` is not offered.

Removing unused parameters, fixing unused captures, and naming fixes have their own sections below.

## String literal conversion

- Organize imports and string literal conversion look only at the syntax tree and the source text.
- String conversion uses `refactor.rewrite` and preserves the actual bytes, blank lines, and trailing newlines;
- a multiline string is decoded from its line tokens, excluding the indentation and CRLF line endings;
- the conversion to a multiline string is not offered when a regular string contains control bytes that cannot be written directly in the multiline form (including TAB and CR) or invalid UTF-8, nor where Zig requires a regular string literal (the operand of `@import`, the strings of a `build.zig.zon` manifest).
- When the file is already formatted with `zig fmt`, the edit is the difference between the original text and the text after the replacement, laid out by `zig fmt` (only lines near the replacement, such as the `;` after a multiline string returning to the statement's indentation, an initializer list changing to one element per line, or lines joined after converting back to a regular string), so the file is `zig fmt` output both before and after the conversion;
- when the file is not formatted, only the literal is replaced (leaving no trailing whitespace when it moves to the next line), and the layout elsewhere is left untouched.
- With the cursor on a string, each request formats the whole text twice: about 30–40 ms for a 20k-line file (ReleaseSafe).

## Organize imports (`source.organizeImports`, `ide_db/organize_imports.zig`)

### Blocks

- Consecutive top-level import declarations (`const x = @import("...")`, optionally followed by member accesses) and derived declarations (whose right-hand side is a member access, possibly several levels deep, starting with an import or derived declaration of the same file) form a block, with only blank lines between declarations;
- comments directly above a declaration and its trailing comment move with it, except comment lines that start the file (a header such as a license notice), which stay first.
- A comment separated by a blank line, or any other declaration, ends a block; each declaration must occupy whole lines by itself.
- A file can have several blocks, each organized in place; declarations are neither moved between blocks nor removed (unused ones are diagnosed by the compiler).
- Nothing is organized when there are syntax errors.

### Grouping and sorting

- Three groups, `std` / `builtin` / `root` (in this fixed order), dependency modules, and files, with a blank line between groups; grouping looks only at the `@import` string (strings ending in `.zig` / `.zon` are files).
- By default a derived declaration directly follows the declaration it depends on (`imports.derived = .with_import`), or derived declarations form a separate last group (`.separate`); a derived declaration whose dependency is in another block always goes in the last group.
- Within a group, entries are sorted by default by what they reference (`imports.sort = .path`): module names, file paths (fewer `../` first, then compared segment by segment), and for derived declarations the access path expanded up to the name of the import declaration; `.name` sorts by declaration name.
- Comparisons use rustfmt's version sort (numbers by numeric value, uppercase before lowercase, `_` before every other character), consistent with rust-analyzer.
- These two options are a style shared by the team and can be set in `zig-analyzer.zon`.

### When offered

- Always offered when the client requests this kind in `context.only` (`source` included), which is used for keybindings and organizing on save; for menu requests (no `only`), it is offered only when the requested range intersects a block.
- Applying it organizes all blocks; it is not offered when the imports are already organized, and organizing the result again changes nothing.
- Other code actions are filtered by `only` as well.

## Removing unused parameters (`ide/remove_param.zig`)

### Offering

- When AstGen reports `unused function parameter`, the code action "remove parameter `x`" is offered besides the discard (`_ = x;`, preferred), and it is not marked as preferred.
- The function must have a body and be in the user's code (as with rename);
- the action is not offered for `export` / `extern` functions, variadic functions, or the receivers of methods: the first parameter is a receiver when its type is the container the function is in or a single-item pointer to it;
- the type expression is first resolved by name (`@This()`, `Self`), and when that fails (the result of a type function), the inferred signature is used.
- When the client supports `codeAction/resolve`, call sites are searched only after the action is selected; otherwise the edit is computed in the request, and when the parameter cannot be removed, the reason is given in `disabled`; when the client does not support `disabled`, the action is not offered.

### Call sites

- References are searched in the same scope as for rename.
- Every reference must be the callee of a call (possibly parenthesized): `f(...)`, `S.f(...)`, `x.f(...)`, or the decl literal `.f(...)`; the names of decltests do not depend on the signature and are left unchanged.
- In `x.f(...)`, when `x` is a value, it is a method call and `x` is the first argument; when `x` is a type or a namespace, it is not.
- In a generic function, this is decided under all call-site instances, which must agree.
- The number of arguments (counting `x` in a method call) must equal the number of parameters.

### Refusal

- In the following cases no edit is returned, only the reason and the location:
  - the function is used other than in a call (passed as a value, its address taken, `@call`, `@TypeOf`);
  - a reference is ambiguous in a generic function, goes through a member access of unknown type, or appears in a file with syntax errors;
  - the function name appears as a string literal in a file that can access the function (for a `pub` function, the files that import the file containing it; otherwise, the file containing it), so it may be accessed by name through `@field` and the like;
  - a method call passes the value before `.` as the parameter being removed;
  - a removed argument has side effects: calls (except type function calls whose result is a type), assignments, `try` and control flow, builtins that have side effects or are not listed, inline assembly, and so on.
- If any one place cannot be updated, the whole fix is refused, with no partial edits.

### Validation

- For each modified file, the AstGen errors before and after the edit are compared (matched by position and message), and the fix is refused when new errors appear, for example when removing an argument leaves a local constant at a call site or a parameter of the caller unused.
- The exception is another parameter in the same parameter list that becomes unused as a result (after `x` is removed from `comptime T: type, x: T`, `T` is unused): it is equivalent to the original error and can be removed next.
- When a removed argument contains a call to the same function (the type function `Wrap(Wrap(u8, u16), u32)`), the edit of the inner call is dropped along with the argument.

### Layout

- An item on lines of its own (an item of a multiline list, together with its doc comment and trailing comment) is removed with those lines;
- an item that shares a line with other items is removed together with one comma (for the last item, the comma before it);
- next to a multiline string literal, the removal stops at the comma, keeping the line breaks before and after the multiline string;
- a `//` comment after the separator before the item (`(` or the previous comma) on the same line belongs to the previous item or to the call and is kept with its line break (for the last item, `)` then goes on the next line with the indentation of the line of `(`);
- when only whitespace remains between the parentheses after the removal, the parentheses are emptied, giving `f()`.

### Limits

For `pub` functions, only calls in the workspace are updated, not callers outside the workspace; when the client supports `documentChanges` and change annotations, the edit carries an annotation that needs confirmation and is applied only after the user confirms.

## Unused captures (`ide/unused_capture.zig`)

### Offering

- When AstGen reports `unused capture` or `unused switch tag capture`, the code action "remove capture `v`" is offered, or "rename `v` to `_`" where the capture cannot be removed.
- Only rewrites that keep the meaning are offered: which captures can be removed or renamed to `_` follows the rules of AstGen, and the fix is not offered when no such rewrite exists.
- When the body of the capture is a block, the fix is offered besides the discard (`_ = v;`, preferred) and is not marked as preferred; otherwise no discard can be inserted and the fix is preferred, except renaming the payload capture of a switch prong whose tag capture is unused too: the preferred fix of the tag removes it, and applying both would leave `|_|`.

### Removing

- An optional `if` / `while` (without `else |err|`) loses the capture, and its condition is compared with null (`if (x) |v|` → `if (x != null)`), wrapped in parentheses unless it is a suffix or primary expression (`if ((a orelse b) != null)`);
- `catch |err|` loses the capture (`catch |_|` is an error);
- a switch prong with only the payload capture loses the whole capture, and a tag capture is removed together with its comma, or the whole capture when the payload capture is `_` (`|_|` and `|p, _|` are errors);
- an unbounded for counter (`0..`; discarding it is an error) is removed together with its input.
- The start of that input must be a literal, a name, or a field access on a name, and a bounded input must remain; when the start contains a name, AstGen is run on the rewritten text and the fix is not offered if new errors appear, matched by position and message (a name used only there is no longer used, which may be another `unused capture`).

### Renaming to `_`

Both captures of an error union `if` / `while` (removing the payload capture requires a void payload, and removing `else |err|` turns it into an optional `if`), the other captures of a for, and the payload capture of a switch prong that also has a tag capture; a pointer capture is renamed together with its `*` (`|*_|` is an error).

### Layout

A removed capture is deleted together with the whitespace before it, or the whitespace after it when it starts a line; a removed for input is laid out as when removing parameters.

## Naming checks

Naming checks follow the Names section of the Zig 0.17.0 style guide. They are off by default and enabled by `naming.enable`.

Name style is classified by the declaration's type and comptime value, with results cached per member, and the fixes reuse the reference search:

### Classification

- The style of a name is decided by what the declaration actually represents, not by the `fn` / `const` / `var` keyword: types, type aliases, and callables that return `type` are TitleCase; other callables (functions, function aliases, function pointers) are camelCase; files without top-level fields (namespaces) and other values are snake_case; fields and enum members follow the type of the field.
- Acronyms are treated as ordinary words (`XMLParser` → `XmlParser`).
- Only inference results of the abstract instance are used; a conclusion drawn from the instance at one call site is not generalized into a rule for the source.

### Skipped

- Types that are unknown or depend on the generic instance;
- structs without fields (whether one is a namespace or a zero-size type to be instantiated depends on intent);
- fields holding types, and optional function pointers (the standard library uses both styles);
- extern / export declarations and extern containers;
- `@compileError` stubs (`noreturn`: they keep the name of the API they replace, so that its users get their message);
- top-level declarations whose names the standard library looks up in the root file (`DllMain`, `WinMain`, `std_options_cwd`, and the like; checked in every file);
- aliases re-exported under the same name (`const SDL_Window = c.SDL_Window;`, where the name is determined by the referenced declaration);
- names written as `@"..."`;
- names whose word split is ambiguous (no lowercase letters as in `ENOENT`, a `_` prefix or suffix, words of fewer than five letters split off from a run of uppercase letters as in `URLs` / `CIELChuv`, a single uppercase letter after a digit as in `Vec3D`).
- Files in dependency libraries, generated code (whose leading comment carries a marker such as `DO NOT EDIT` or `@generated`), and files in `naming.exclude` are not checked.

### Hints

- Published only for open files, with severity Hint, code `naming.<rule>`, and a link to the official rule; `naming.ignore` (names, with `*` wildcards) and `naming.rules` set exceptions, and these options can also be written in the project's `zig-analyzer.zon`.
- Results are cached per member (`naming.Query`, without positions or configuration); an edit recomputes only the changed members, scans no other files, and starts no compiler process.

### Fixes

- A code action "rename ... to ...", not marked as preferred and applied only after the user selects it; when the client supports `codeAction/resolve`, references are searched only after it is selected.
- In the following cases no edit is returned, only the reason:
  - a reference is ambiguous in a generic function, goes through a member access of unknown type, or appears in a file with syntax errors;
  - the new name duplicates a member of the same container, shadows or is shadowed, or makes a reference in the container ambiguous (a declaration in an inner container may share its name with one in an outer container, and Zig reports only the references that see both, as `ambiguous reference`);
  - the name appears as a string literal (`@field`, `@hasDecl`, serialization keys).
- Finally, AstGen is run on the renamed text of the file containing the declaration, and the rename is likewise refused if new errors appear: duplicate names and shadowing can only occur in this file, and references in it that were missed are reported as well.

### Limits

- For public names (`pub` declarations and fields), only references in the workspace are updated; users outside the workspace, symbols of external ABIs, and string names constructed at runtime or passed through variables (such as JSON serialization keyed by field names) are not.
- When the client supports `documentChanges` and change annotations, such renames carry an annotation that needs confirmation and are applied only after the user confirms.
