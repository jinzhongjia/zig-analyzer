# Completion

Completion is based on inference results and name resolution. Auto-import candidates are described in `docs/features/auto-import.md`.

## Ordering of name completion

As a name is typed, each candidate's score is its match score multiplied by its source weight; the server gives `sortText` from the highest score down, keeping collection order among ties. Names in scope that do not match score 0, sort last, and are filtered by the client.

Match scores come from `ide_db/fuzzy.zig`, ported from gopls's `internal/fuzzy` (license in `tools/gopls/LICENSE`), with no limit on lengths. An all-lowercase input ignores case when scoring, and names whose case agrees come first among ties.

| Source | Weight |
|---|---|
| Local names | 1.0 |
| Parameters | 0.98 |
| Members of the enclosing container | 0.94 (0.02 less per outer level, at least 0.86) |
| Member paths of local values | 0.9 |
| Auto-import through a visible name | 0.85 |
| Keywords, primitives, statement and declaration snippets | 0.8 |
| Auto-import needing a new import | 0.75 |

Member paths and auto-import candidates are also multiplied by a depth factor that drops 0.05 per extra path segment (at least 0.5).

## Expected type

When the name at the cursor has an expected type, the scores of candidates that fit are multiplied by 1.25. This only reorders: the limit truncates by the unboosted scores, so it never changes which candidates are kept.

With nothing typed at the cursor, the empty slot is found from the token before it (`=` of a declaration, field default, or assignment; `return`; `(` or `,` in an argument list; `.f =` in an initializer; `else`; `orelse`; `catch`; `=>` of a switch prong; a comparison; `comptime`; `break :label`; the second argument of `@as`), and the same source rules give its expected type. Candidates that fit get `sortText` `0` and all others get `1`: two tiers only, with the client's order kept within each. No candidate is filtered, and no sort text is set when there is no expected type.

- **Source**: the parent expression and the inference result at the cursor, such as a call parameter, an annotation, a return type, an initializer field, an assignment target, or the other side of a comparison. Branches of `if`, `switch`, `orelse`, and `catch` take the type of the expression they produce. Only concrete types count: anytype parameters and parameters depending on comptime parameters give none.
- **Trust**: it is not computed when the statement at the cursor contains a syntax error (the parse error of the missing expression at an empty slot itself does not count), the previous item is an error node, or the call or initializer at the cursor is unclosed, since error recovery can produce a wrong structure. A missing `;` on the previous statement does not count.
- **Fitting** counts only what can be decided exactly, following the compiler's coercions: the same type, `T` for `?T` or `E!T`, error sets within `E`, `*T` as `*const T`, arrays as slices, compatible pointer attributes, and functions whose return value fits when they complete as a call. Function types must match, including the calling convention. Integer widening, `comptime_int`, and other conversions do not count.

## Keywords

Keywords are offered in `.zig` files, with or without snippets, only where the syntax admits them:

- **Container members**: `pub`, `const`, `var`, `fn`, `test`, `comptime`, `extern`, `export`, `inline`, `noinline`, `threadlocal`; after `pub` not `pub`, `test`, and `comptime`, after a doc comment not `test` and `comptime`, and none between fields.
- **Statements**: `const`, `var`, `if`, `for`, `while`, `switch`, `defer`, `errdefer`, `try`, `comptime`, `inline`, `unreachable`.
- **Expressions**: `if`, `switch`, `for`, `while`, `inline`, `try`, `comptime`, `unreachable`, and those that start a type (`struct`, `enum`, `union`, `opaque`, `error`, `fn`, `packed`, `extern`).
- **Types** (annotations, return types, children of `?`, `!`, pointer, slice and array types, tag types of enums and unions): `struct`, `enum`, `union`, `opaque`, `error`, `fn`, `packed`, `extern`, `comptime`, `if`, `switch`; after `*` or `[]` also the pointer attributes not written yet (`const`, `volatile`, `allowzero`, `align`, `addrspace`); as a parameter type also `anytype`.
- **Parameters**: `comptime` and `noalias` before the name; a parameter of a function type may be a type alone.
- **Switch cases**: `else` as the only item of a case.

Primitive values (`true`, `false`, `null`, `undefined`) and the common primitive types (`bool`, `void`, `type`, `noreturn`, `anyerror`, `anyopaque`, `comptime_int`, `comptime_float`, `usize`, `isize`, the integers of 8 to 128 bits, the floats, and the C types) are offered with the keywords: values and types in expressions, types alone in type positions, and none at the start of a statement or a member. Their types are known, so they rank by the expected type: `true` and `false` fit `bool`, `null` fits an optional, the types fit `type`; `undefined` fits anything and is never ranked first.

In statements and expressions, `return` is offered only in the body of a function or test, `break` only in a loop or a labeled block or switch, and `continue` only in a loop or a labeled switch; none of them inside `defer` or `errdefer`, which control cannot leave, except for the loops and labels inside it.

An empty word, or one that is already a keyword, has no node of its own in the syntax tree after error recovery, so the member at the cursor is parsed again with a name in place of the word, and the position is that of the name. The same classification decides whether names in scope are offered: only where the syntax admits a name reference (expressions, types, decltest names, inline-assembly output variables, and tuple struct fields), never in declaration, capture, label, error-set, parameter, or field names, non-tuple container member positions, numbers, operators, comments, or strings. No keywords are offered in declaration, capture, and label names, after `.` or `@`, or inside numbers, operators, comments, and strings.

## Member completion

After `.` on a value (a single-item pointer is dereferenced once), completion lists its fields and the functions callable on it as methods; those in other files must be `pub`. As the compiler requires, a non-const pointer receiver needs a value that can be modified, by the same rule that infers `&x`. A first parameter that is `anytype` or cannot be computed counts as receiving the value.

## Postfix completion

After `.` on a value, completions by its type follow its members (sort text `~`):

- `.*` on a single-item pointer that is not a function pointer, and `.?` on an optional; the detail is the type they give.
- With snippets, on an error union: `.try` replaces `.word` with nothing and inserts `try ` before the left-hand side (an additional edit, so a left-hand side spanning lines works), offered in the body of a function or test, not inside `defer` or `errdefer`, and, when the function at the cursor declares its error set, only if the errors fit in it. `.catch` replaces `.word` with `catch |err| switch (err) { ... }`, with a prong per error of a known error set, or an `else` prong for `anyerror` or a set that cannot be computed; it is not offered where the access is an operand of a prefix or binary operator or of another `catch`, since `catch` would take the whole expression as its operand. Their filter text includes the `.` (`.try`, `.catch`).

A word that is already a keyword (`f().try`) is not a field access after error recovery, so these are found while it is still a prefix (`f().tr`).

## Member paths of local values

After a non-empty prefix of a plain name expression, members of visible local values are candidates too, labeled and inserted by whole path (`gpa` → `sema.gpa`). In enclosing functions, only values known at comptime are expanded, since a nested container cannot access runtime values.

- Depth is at most 2: fields, and results of methods taking only self and returning a container or single-item pointer. `?T`, `E!T`, pointers to pointers, and many-item pointers are not expanded.
- The whole path is fuzzy-matched, only matches are returned, and they share `completion.max_auto_imports` with auto-import candidates.

## Completion item kinds

`CompletionItemKind` shares `ide_db/symbol_kind.zig` with semantic tokens and comes from the declaration's kind and inferred type, never guessed from the name. Auto-import candidates first use results recorded when the index is built, which avoids parsing their files; the rest are inferred when the candidate is built, with a cache. Tests ensure both give the same result.

## Snippets

Controlled by `completion.snippets` (on by default), used only with `completionItem.snippetSupport` and in `.zig` documents; otherwise items insert only the name.

- **Calls**: functions and builtins complete as calls (`add(${1:a}, ${2:b})`), skipping the receiver of a method called through a value. With `completion.argument_placeholders` off, only the parentheses are inserted. With `completion.call_snippets` off, they insert their name alone, and signature help (triggered by `(` and `,`) shows the parameters once `(` is typed; the other snippets are unaffected.
- **Name only**: where `(` already follows the cursor, where the position expects a function value, and in declaration positions. A function value is expected by `&f`, the callee of `@call`, typed positions whose type is a function or pointer to one, and `anytype` parameters that the callee calls or forwards, followed through every call of the chain (`std.Thread.spawn`).
- **Statements and declarations**: keyword snippets at the start of statements and container members. Statements: `if` (plain, `else`, optional capture, error union with `else |err|`), `for` (plain, with an index, a `0..` range, `inline`), `while` (plain, optional capture, continue expression), `switch`, `defer`, `errdefer`, `try`, and `const`/`var` declarations. Members: functions, tests, `const`, structs (plain, `packed`, `extern`), enums (plain and with a tag type), unions (plain and `union(enum)`), error sets, imports, and `comptime` blocks. Snippets that use `std` (printing, assertions, logging, and `std.testing` checks) are offered only when `std` is the standard library; `std`, `builtin`, `main`, and `format` only when not declared yet.
- **Ranges** are converted within the cursor's line (`offsets.Line`), and ranges outside it with the file's cached line table (`LineStarts`). With `insertReplaceSupport`, items carry both ranges.
- **Cost**: the response is larger, and client latency is about 2-3 times that without snippets on large member lists.

## completionItem/resolve

The completion list carries no signatures, because they need inference: a signature is computed only on selection. `detail` is the signature, the same as hover and shown as written in the source; `documentation` holds the doc comment and the definition's location, given as a path under `std/`, an importable path, or the module name plus a path under its root. A constant whose value is a file also gets that file's `//!` doc. An alias without its own doc comment (`pub const Foo = @import("foo.zig").Foo;`, `pub const f = g;`) takes the first doc comment along its alias chain; hover and signature help use the same doc.

## Fields and paths of `build.zig.zon`

When no import site gives a result type, completion uses the built-in schema (`ide/manifest.zig`); with one, it works as for other `.zon` files. Fields not given yet are completed; a dependency is either fetched (`url`, `hash`) or at a `path`, so one kind is not offered once the other is given, as in the compiler.

## Settings of `zig-analyzer.zon`

When no import site gives a result type, `ide/project_config.zig` handles the file: what can be set comes from `Config.project_schema`, derived from the settings and their types. Completion offers the settings at the cursor that are not given yet, the names of an enum after `.`, and `true` and `false`; settings only the editor can set are not offered. Completion and hover show the comment above the setting in `zig-analyzer.default.zon`, which is embedded in the binary, so the text users read in that file is the only copy: its description, the description of each value of an enum, its default when that is a single value, and an example. Enum values have their own description, in completion and on hover. A test requires every setting to have a description and an example, every enum value to have a description, and every example to be accepted by the project configuration parser.

## Enum literals in `.zon` files

Only an enum's names and the tags of a union without a payload are offered, also through a pointer, which ZON parses as the pointee. Declarations are not: the compiler rejects decl literals in ZON.

`.paths` and a dependency's `.path` complete relative to the build root, without `.`-prefixed entries, `zig-out`, and `zig-pkg`. Positions come from the syntax tree, so unclosed strings work too. Goto on such a path opens the file without interning it.

## Builtins (completion, hover, and signature help)

Signatures and descriptions are generated from the official language reference of the pinned Zig version, with compiler-verified corrections for entries where the reference contradicts the compiler, and name the user's supported version in their links and notes (the texts of the supported versions are otherwise identical); hover also keeps the inference result. `zig build gen` produces `src/ide/builtin_data.zig` and `src/ide/manifest_data.zig` offline, verifying the input hashes recorded in `tools/zig/metadata.json`; at run time only the static tables are read. Builtins the sources do not document say so, without invented signatures.
