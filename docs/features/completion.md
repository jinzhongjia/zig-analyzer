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
| Statement and declaration snippets | 0.8 |
| Auto-import needing a new import | 0.75 |

Member paths and auto-import candidates are also multiplied by a depth factor that drops 0.05 per extra path segment (at least 0.5).

## Expected type

When the name at the cursor has an expected type, the scores of candidates that fit are multiplied by 1.25. This only reorders: the limit truncates by the unboosted scores, so it never changes which candidates are kept.

- **Source**: the parent expression and the inference result at the cursor, such as a call parameter, an annotation, a return type, an initializer field, an assignment target, or the other side of a comparison. Branches of `if`, `switch`, `orelse`, and `catch` take the type of the expression they produce. Only concrete types count: anytype parameters and parameters depending on comptime parameters give none.
- **Trust**: it is not computed when the statement at the cursor contains a syntax error, the previous item is an error node, or the call or initializer at the cursor is unclosed, since error recovery can produce a wrong structure. A missing `;` on the previous statement does not count.
- **Fitting** counts only what can be decided exactly, following the compiler's coercions: the same type, `T` for `?T` or `E!T`, error sets within `E`, `*T` as `*const T`, arrays as slices, compatible pointer attributes, and functions whose return value fits when they complete as a call. Function types must match, including the calling convention. Integer widening, `comptime_int`, and other conversions do not count.

## Member completion

After `.` on a value (a single-item pointer is dereferenced once), completion lists its fields and the functions callable on it as methods; those in other files must be `pub`. As the compiler requires, a non-const pointer receiver needs a value that can be modified, by the same rule that infers `&x`. A first parameter that is `anytype` or cannot be computed counts as receiving the value.

## Member paths of local values

After a non-empty prefix of a plain name expression, members of visible local values are candidates too, labeled and inserted by whole path (`gpa` → `sema.gpa`). In enclosing functions, only values known at comptime are expanded, since a nested container cannot access runtime values.

- Depth is at most 2: fields, and results of methods taking only self and returning a container or single-item pointer. `?T`, `E!T`, pointers to pointers, and many-item pointers are not expanded.
- The whole path is fuzzy-matched, only matches are returned, and they share `completion.max_auto_imports` with auto-import candidates.

## Completion item kinds

`CompletionItemKind` shares `ide_db/symbol_kind.zig` with semantic tokens and comes from the declaration's kind and inferred type, never guessed from the name. Auto-import candidates first use results recorded when the index is built, which avoids parsing their files; the rest are inferred when the candidate is built, with a cache. Tests ensure both give the same result.

## Snippets

Controlled by `completion.snippets` (on by default), used only with `completionItem.snippetSupport` and in `.zig` documents; otherwise items insert only the name.

- **Calls**: functions and builtins complete as calls (`add(${1:a}, ${2:b})`), skipping the receiver of a method called through a value. With `completion.argument_placeholders` off, only the parentheses are inserted.
- **Name only**: where `(` already follows the cursor, where the position expects a function value, and in declaration positions. A function value is expected by `&f`, the callee of `@call`, typed positions whose type is a function or pointer to one, and `anytype` parameters that the callee calls or forwards, followed through every call of the chain (`std.Thread.spawn`).
- **Statements and declarations**: keyword snippets at the start of statements and container members; those depending on `std` are offered only when `std` is the standard library.
- **Ranges** are converted within the cursor's line (`offsets.Line`), and ranges outside it with the file's cached line table (`LineStarts`). With `insertReplaceSupport`, items carry both ranges.
- **Cost**: the response is larger, and client latency is about 2-3 times that without snippets on large member lists.

## completionItem/resolve

The completion list carries no signatures, because they need inference: a signature is computed only on selection. `detail` is the signature, the same as hover and shown as written in the source; `documentation` holds the doc comment and the definition's location, given as a path under `std/`, an importable path, or the module name plus a path under its root. A constant whose value is a file also gets that file's `//!` doc.

## Fields and paths of `build.zig.zon`

When no import site gives a result type, completion uses the built-in schema (`ide/manifest.zig`); with one, it works as for other `.zon` files. Fields not given yet are completed; a dependency is either fetched (`url`, `hash`) or at a `path`, so one kind is not offered once the other is given, as in the compiler.

## Settings of `zig-analyzer.zon`

When no import site gives a result type, `ide/project_config.zig` handles the file: what can be set comes from `Config.project_schema`, derived from the settings and their types. Completion offers the settings at the cursor that are not given yet, the names of an enum after `.`, and `true` and `false`; settings only the editor can set are not offered. Completion and hover show the comment above the setting in `zig-analyzer.default.zon`, which is embedded in the binary, so the text users read in that file is the only copy: its description, the description of each value of an enum, its default when that is a single value, and an example. Enum values have their own description, in completion and on hover. A test requires every setting to have a description and an example, every enum value to have a description, and every example to be accepted by the project configuration parser.

## Enum literals in `.zon` files

Only an enum's names and the tags of a union without a payload are offered, also through a pointer, which ZON parses as the pointee. Declarations are not: the compiler rejects decl literals in ZON.

`.paths` and a dependency's `.path` complete relative to the build root, without `.`-prefixed entries, `zig-out`, and `zig-pkg`. Positions come from the syntax tree, so unclosed strings work too. Goto on such a path opens the file without interning it.

## Builtins (completion, hover, and signature help)

Signatures and descriptions are generated from the official language reference of the pinned Zig version, and name the user's supported version in their links and notes (the texts of the supported versions are otherwise identical); hover also keeps the inference result. `zig build gen` produces `src/ide/builtin_data.zig` and `src/ide/manifest_data.zig` offline, verifying the input hashes recorded in `tools/zig/metadata.json`; at run time only the static tables are read. Builtins the sources do not document say so, without invented signatures.
