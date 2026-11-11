# References, rename, document highlight, and workspace symbol

## How references are found

`FileIndex` filters files by name → the Bloom filter of `ItemNames` filters members → each occurrence is confirmed by precise resolution.

The candidate files are those reaching the definition through an `@import` chain, plus the files those reach: generic code can access a definition's members through an `anytype` value or comptime type parameter without importing its file, while a file none of them reaches is never compiled with the definition. In files not importing the definition, only generic code and typed `.zon` roots are checked.

Document highlight checks only its own file and reports declarations and assignment targets as writes.

A member access through a namespace chosen by build configuration, or in a region inferred per iteration, refers to the member of every choice; rename and fixes are refused when the choices have different members.

On a member name in a generic function that refers to a different declaration under each instance (a member of a comptime type parameter or of an `anytype` value), references and document highlight cover the references of each declaration it refers to under the instances whose code at the cursor compiles: the declarations goto lists. Code after a guard such as `if (!@hasDecl(T, "x")) @compileError(...)` does not compile under the instances the guard rejects, so their declarations are not included there. Rename works on one declaration and is refused when its uses also refer to others.

## Search scope

The scope of references, rename, reference-editing fixes, and workspace symbol: project files in the module graph (excluding std), user source files under the root directories, and open documents. Root directories are walked in the background, skipping hidden directories, `zig-pkg`, `zig-out`, and project caches, so files in no build graph are searched too. They are walked again when a source file under them is created or deleted, when a directory the walk enters (or a root) is created or removed, and when notifications are lost; directories the walk skips, such as those every build creates in `.zig-cache` and `zig-out`, do not start a walk. When the server watches the root directories itself, it watches every directory a walk enters, so a source file created later in a new or empty directory is found too (see "New source files in the workspace folders" in `design.md`).

References, rename, and those fixes that meet a walk scheduled or in progress wait until the walks scheduled up to then have finished and then answer, so a change on disk just before the request does not make them fail. Walks scheduled during the wait are for changes noticed after the request and are not waited for, so the wait ends even while source files keep being created. Before the first walk is scheduled and during a project's first load, they fail with that reason rather than returning partial results. Local names and non-`pub` declarations other than fields are exempt, since only their file can refer to them.

## Rename

Only user code is modified. A rename whose references reach a dependency library or a stale copy in `.zig-cache` / `zig-pkg` is refused: a fetched package is restored from its hash, and the Zig installation is shared.

- Outside the workspace folders, only local names and non-`pub` declarations other than fields can be renamed or lose a parameter, since other users are unknown. This holds for files a project's module graph includes too (modules added by path, such as a library that a workspace folder depends on by `.path`): the library's own tests and other dependents are not in the workspace. Opening the library's directory as a workspace folder makes its declarations renamable.
- Declarations std looks up through `@import("root")` (`main`, `panic`, `std_options`, and so on) cannot be renamed in a compilation's root file: std would silently fall back to its defaults.
- Tags of an enum built from a container's members (`std.meta.FieldEnum(T)`) refer to the member they are named after.

Rename and naming fixes return only a reason and location, with no edit, when:

- a reference cannot be confirmed (ambiguous in a generic function, a member access of unknown type, incomplete instances, a file with syntax errors that mentions the name);
- the new name conflicts (a member of the same container, shadowing, a newly ambiguous reference, or any new AstGen error in the declaration's file);
- a container member's name appears as a string literal in a file that can access it (`@field`, `@hasDecl`, serialization keys). Test names (`test "name" {}`) do not count: they only describe the test.

## Labels and error names

- A label is visible only inside the expression it labels; AstGen confirms the renamed file.
- Error names are global within a compilation, whichever set they are written in, so references are searched across files compiled together. Renaming is refused when a file not being renamed uses the name, when the new name is already an error, or when a string literal equals the name (`@errorName` comparisons).

## Workspace symbol

Files in the search scope are indexed in the background (ItemTree and `ItemSummaries`), so queries need no parse results. While indexing runs, a request waits for the index of the module graph it started with, then searches every file of the scope.

Dependency libraries are listed only with `workspace_symbol.dependencies`. At most `workspace_symbol.limit` best matches are returned (default 256, 0 for no limit), plus every exact name match. LSP results have no "incomplete" flag, so clients that query once and filter themselves (Neovim's `vim.lsp.buf.workspace_symbol`) need a higher limit or 0.

## Fields of `.zon` files

- A field of a literal in a file without a result type is a symbol of its own (`search.ZonField`), identified by the type of the literal. References and rename find field accesses on values of that type and the field names of initializers of it, in the files that can reach the `.zon` file and the files those reach, under each instance and iteration where the abstract inference does not determine the type. Rename is refused when a use also refers to another literal, a string may name the field, the new name is taken in the literal, or the file is a `build.zig.zon` handled by the schema, whose names are fixed.
- An import site without a result type uses the value through the anonymous type of its literal; when the file has a result type, a field access on that type refers to the declaration the field in the file refers to, so references and rename follow it.
- When the sites give several result types, or a generic one, references find the names that refer to the declaration under any of them, including each instance of a generic function: the root expression is inferred again with that type (`InferKey.zon_type`). Rename is refused when it would change such a name, since the sites of the other types would break, or when a site's type cannot be determined and the file mentions the name.
