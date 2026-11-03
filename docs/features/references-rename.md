# References, rename, document highlight, and workspace symbol

## How references are found

`FileIndex` filters files by name → the Bloom filter of `ItemNames` filters members → each occurrence is confirmed by precise resolution.

The candidate files are those reaching the definition through an `@import` chain, plus the files those reach: generic code can access a definition's members through an `anytype` value or comptime type parameter without importing its file, while a file none of them reaches is never compiled with the definition. In files not importing the definition, only generic code and typed `.zon` roots are checked.

Document highlight checks only its own file and reports declarations and assignment targets as writes.

A member access through a namespace chosen by build configuration, or in a region inferred per iteration, refers to the member of every choice; rename and fixes are refused when the choices have different members.

## Search scope

The scope of references, rename, reference-editing fixes, and workspace symbol: project files in the module graph (excluding std), user source files under the root directories, and open documents. Root directories are walked in the background, skipping hidden directories, `zig-pkg`, `zig-out`, and project caches, so files in no build graph are searched too.

Until a walk finishes and during a project's first load, references, rename, and those fixes fail with that reason rather than returning partial results. Local names and non-`pub` declarations other than fields are exempt, since only their file can refer to them.

## Rename

Only user code is modified. A rename whose references reach a dependency library or a stale copy in `.zig-cache` / `zig-pkg` is refused: a fetched package is restored from its hash, and the Zig installation is shared.

- Outside the workspace folders, only local names and non-`pub` declarations other than fields can be renamed, since other users are unknown.
- Declarations std looks up through `@import("root")` (`main`, `panic`, `std_options`, and so on) cannot be renamed in a compilation's root file: std would silently fall back to its defaults.
- Tags of an enum built from a container's members (`std.meta.FieldEnum(T)`) refer to the member they are named after.

Rename and naming fixes return only a reason and location, with no edit, when:

- a reference cannot be confirmed (ambiguous in a generic function, a member access of unknown type, incomplete instances, a file with syntax errors that mentions the name);
- the new name conflicts (a member of the same container, shadowing, a newly ambiguous reference, or any new AstGen error in the declaration's file);
- a container member's name appears as a string literal in a file that can access it (`@field`, `@hasDecl`, serialization keys).

## Labels and error names

- A label is visible only inside the expression it labels; AstGen confirms the renamed file.
- Error names are global within a compilation, whichever set they are written in, so references are searched across files compiled together. Renaming is refused when a file not being renamed uses the name, when the new name is already an error, or when a string literal equals the name (`@errorName` comparisons).

## Workspace symbol

Files in the search scope are indexed in the background (ItemTree and `ItemSummaries`), so queries need no parse results. While indexing runs, a request waits for the index of the module graph it started with, then searches every file of the scope.

Dependency libraries are listed only with `workspace_symbol.dependencies`. At most `workspace_symbol.limit` best matches are returned (default 256, 0 for no limit), plus every exact name match. LSP results have no "incomplete" flag, so clients that query once and filter themselves (Neovim's `vim.lsp.buf.workspace_symbol`) need a higher limit or 0.
