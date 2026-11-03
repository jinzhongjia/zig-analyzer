# References, rename, document highlight, and workspace symbol

## How references are found

Find references, document highlight, and rename search in three steps: `FileIndex` coarsely filters files by name → the Bloom filter of `ItemNames` coarsely filters members → each occurrence is confirmed by precise resolution.

- The candidate files are the files that can reach the definition through an `@import` chain (the chain may pass through files outside the search scope, such as the standard library or a closed file), plus the files those reach: generic code can access the members of the file containing the definition through an `anytype` value or a comptime type parameter without importing that file, while a file that none of them reaches is never compiled together with the definition.
- Document highlight only checks whether its own file reaches the definition, and reports declarations and the targets of assignments (`x = v`, `x += v`, `a, b = v`) as writes and the other occurrences as reads.
- In files that do not import the file containing the definition, only code in generic functions and the root expression of a `.zon` file that has a result type are checked.
- Field names in initializers (`.{ .x = v }`) can refer only to fields, so they are not checked when searching for the references of other definitions.
- A member access through a namespace that a declaration chooses per build configuration (`const Impl = if (builtin.os.tag == .windows) @import("win.zig") else @import("posix.zig")`) refers to the member of every choice, and when the choices have different members, rename and the fixes are refused as for an ambiguous reference in a generic function.
- Likewise, a member access in a region inferred per iteration (a heterogeneous `inline for`, an `inline` switch prong; the same regions goto and hover resolve per iteration) refers to the member of every iteration, and rename and the fixes are refused when the iterations have different members.

## Search scope

- The search scope of find references, rename, the fixes that edit references, and workspace symbol: the project files in the module graph (excluding the standard library), the user's source files under the root directories, and open documents.
- The root directories are walked for `.zig` and `.zon` files whose origin is user code (see `docs/diagnostics.md`), without entering hidden directories (`.zig-cache`, `.git`), `zig-pkg`, `zig-out`, or the local caches and package directories of projects, so files in no build graph (single-file mode, build scripts and their helpers, examples) are searched too, opened or not.
- The walk runs in the background at startup, when root directories are added or removed, and when file events report a source file created that is not known yet, a known one deleted, or a directory created or deleted.
- Workspace symbol indexes the same files.
- Until a walk triggered this way has finished, and while a project is in its first load (which files belong to it and what its imports by name resolve to are not known yet), find references, rename, and the fixes that edit references fail with that reason instead of returning partial results; local names and declarations without `pub` (other than fields) are exempt, since only their own file can refer to them.

## Rename

- Rename modifies only the user's own code (by the file origin of `docs/diagnostics.md`): definitions in dependency libraries cannot be renamed, and a rename or fix whose references reach into a dependency library (generic code in a fetched package or the standard library that uses a member of the user's type) or a stale copy in `.zig-cache` / `zig-pkg` is refused rather than editing that file: a fetched package is restored from its hash elsewhere, and the Zig installation is shared.
- In a file outside the workspace folders, only local names and declarations without `pub` (other than fields) can be renamed or lose a parameter, since only that file can refer to them; the files that may use the rest are not known.
- Declarations that the standard library looks up by name through `@import("root")` (`main`, `panic`, `std_options` and the other `std_options_*`, the Windows and UEFI entry points, `debug` and `os` with the members it reads in them) cannot be renamed in a file that is the root source file of a compilation (the root of a compile step's root module, or a file in no module): std would silently fall back to its defaults or fail to find them, and it is never searched for such uses.

- Rename returns no edit, only the reason and its location, in the same cases as the naming fixes (see Naming checks in `docs/features/code-actions.md`):
  - a reference cannot be confirmed (ambiguous in a generic function, a member access of unknown type, incomplete instances, a file with syntax errors that mentions the name);
  - the new name conflicts with an existing one (a member of the same container, shadowing or being shadowed, a reference in the container that would become an ambiguous reference, and finally any new AstGen error in the declaration's file once renamed, such as an ambiguous reference);
  - the name of a container member appears as a string literal in a file that can access it (`@field`, `@hasDecl`, `@fieldParentPtr`, serialization keys).
- A tag of an enum constructed from the members of a container through `@typeInfo` (`std.meta.FieldEnum(T)`, as in `list.items(.id)`) refers to the member it is named after, so references list it and rename updates it.

## Labels and error names

- Labels and error names have references, document highlight, and rename too.
- A label is visible only inside the expression it labels: its references are the label and the `break :l` / `continue :l` that target it (the innermost enclosing block, loop, or switch with the label), and AstGen confirms the renamed file (redefining the label of an enclosing expression is an error).
- Error names are global: `error.X`, the `X` of `error{ X }`, and `E.X` on an error set type are one error in a compilation, whichever error set they are written in, so their references are searched in the files compiled together with the file at the cursor (the files that reach it through `@import` chains and the files those reach; error set members count as declarations), and a member access `x.X` whose left-hand side is unknown is uncertain.
- Renaming an error name is refused when a file that is not renamed uses it (the standard library outside its `test` blocks, a file outside the workspace), since its error would no longer be the same, when the new name is already an error name, since the two errors would become one, and when a string literal equals the name (`@errorName` comparisons).

## Workspace symbol

- The files of the search scope (see Search scope) are indexed in the background (ItemTree and `ItemSummaries`); names are matched against the ItemTree, and their positions come from `ItemSummaries` (small values that are never evicted), so queries need no parse results.
- While indexing runs, a request first waits (until canceled) for the index of the module graph as it was when the request started, rather than parsing the bulk of the files in one read transaction; it then searches every file of the scope, indexing in the request any file the background pass has not covered, and reads the state at the end of the wait.
- Symbols in dependency libraries are not listed by default; `workspace_symbol.dependencies` enables them.
- At most `workspace_symbol.limit` best matches are returned (default 256, 0 for no limit, the same as rust-analyzer's `workspace.symbol.search.limit`), plus every exact name match beyond them (same-named symbols tie, and no longer query could reach the dropped ones): LSP results have no "incomplete" flag;
- clients that query again as the user types are unaffected, while clients that query only once and filter on the client side (such as Neovim's `vim.lsp.buf.workspace_symbol`) need a higher limit or 0.
