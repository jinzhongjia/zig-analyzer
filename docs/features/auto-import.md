# Auto-import

Auto-import completion offers declarations the current file has not imported yet and adds the import when needed. It is controlled by `completion.auto_import` and is on by default.

It uses the per-file declaration index `FileDecls` and the public export closure `Exports` (namespaces and aliases are evaluated by `Resolver`), binary-searched by name prefix (case-insensitive); modules, files, top-level declarations, and nested declarations share the same module reachability check.

## When it is offered

- Offered only after a non-empty prefix of a plain name expression, never in the context of a declaration name, member name, label, comment, string, or builtin; `enum` members and `union(enum)` tags are container fields without a colon and are likewise excluded as declaration names, while tuple fields of a `struct` (type expressions) can still be auto-imported.
  - For plain identifiers and closed escaped identifiers the whole token is replaced; an unclosed escaped identifier is replaced only up to the cursor, keeping the statements, semicolon, and newline after it.
- Before a name is typed in an expression (nothing typed yet, or only a primitive name or `_`), auto-import candidates and member paths of local values are not listed; when either could follow (auto-import is on, or there are local values to expand), the list is marked `isIncomplete` so that the client queries again once a prefix is typed.
- Only `.zig` files are indexed, and auto-import is offered only in `.zig` documents: a module root can be a data file (such as JSON added by `addAnonymousImport`), and inserting an import declaration into a `.zon` or similar file would break it.
  - When `completion.auto_import` is off, no index is built; a round already in progress stops before the next batch, and the values already built are kept until the end of the session.

## Matching and filtering

- Matching:
  - exports at most two segments below the visible namespaces (the namespace aliases visible at the cursor, such as `std` and `const mem = std.mem;`, file imports, and container types) and the module roots (`std`, `builtin`, named modules), kept in `ExportIndex.shallow`, are fuzzy-matched by their whole path: `memeql` matches `std.mem.eql`, and `mem` also offers the members of `std.mem`;
  - deeper exports, private chains in the same file, and declarations in project files are matched by name prefix (ignoring ASCII case).
  - The depth is fixed, with no truncation by time: the result depends only on the source, the input, and the ranking.
  - Names in the index are sorted case-insensitively first and then by bytes on ties, so names that start with the same prefix case-insensitively are contiguous, and exact lookup by name uses the same order.
- `filterText` is kept separate from the inserted expression: for an escaped identifier, the quotes and escape spelling the user has typed are kept as the filter prefix, so that the candidate survives both the plain and the fuzzy matching of native clients.
- `filterText`: the name for candidates whose name starts with the input (ignoring case), and the whole path (`std.mem.eql`) for those matched by path, so that clients that filter only by prefix also keep the candidates matched by name. Whether to filter by case is up to the client (Neovim, for example, follows `ignorecase`/`smartcase`).

## Ranking and limits

- Ranking follows the ordering of name completion (see Ordering of name completion in `docs/features/completion.md`): reusing an existing alias and access through a visible name rank before adding a new import; among equal matches, shallower candidates come first, and so do candidates whose case agrees with the input.
  - The candidates besides the names in scope (auto-import candidates and member paths of local values) total at most `completion.max_auto_imports` items (default 128, 0 for no limit, the same as clangd's `--limit-results`); truncation keeps the highest-scoring ones and uses `CompletionList.isIncomplete` to ask the client to query again as the prefix changes.
  - A short prefix can match over a thousand declarations: only the matching candidates are scored and sorted first, and then labels are built, visibility is checked, and import edits are generated in order until the limit is reached; whether an alias is shadowed is checked only when it is used.

## How a candidate is accessed

- Namespace aliases visible at the cursor are reused first (such as `Ast.Node.Index`), without inserting a duplicate import: top-level consts, consts of the containers enclosing the cursor, and local constants in scope in a function or test body (such as `const u = @import("util.zig");`, offering `u.addNumbers`); nested private declarations in the same file can be accessed through a qualified path.
  - A same-named binding in scope takes precedence, and no shadowed binding is generated.
- Direct aliases are reused by canonical declaration identity, covering types, scalar typedefs, functions, and values; when the target is already bound as `Renamed`, filtering by the target name is kept, while the replacement is the existing binding and no import is added.
  - Visible items with the same label merge their filter and replacement metadata, but same-named imports from different sources are not merged; when the alias and the target name share a prefix, `isIncomplete` makes the client query again as typing continues, so that the filter spelling is chosen again.
- Mutable global variables and runtime `extern const` declarations are accessed qualified by their namespace (such as `lib.counter`) instead of copying the stored value into a top-level constant's initializer; `extern const` keeps the read-only completion kind.
  - Before a new top-level binding is added, `BindingNames` is queried: container members (ItemTree), parameters of other functions, local variables, and captures.
  - Member accesses, initializer field names, labels, and type references are not declarations and do not count as conflicts (the current file's name index `FileIndex` is not used as a coarse filter first: when typing character by character, it always has to be recomputed after each edit);
  - when the leaf name conflicts, a namespace binding is used instead, and when the namespace name conflicts too, `@import("...").name` is inserted directly without adding a binding.

## Declarations and modules offered

- Declarations not offered: methods of structs and other containers (the type of the first parameter is the enclosing container, `@This()`, or a pointer to either, and they are called through an instance), and declarations in files used only by tests, as well as those files themselves.
  - Files used only by tests are computed by `TestOnlyFiles`:
    - reachable via imports from the roots of the modules, but not reachable when following only non-test imports;
    - imports inside test declarations, and imports inside non-pub top-level declarations that production code does not reference but tests do (such as `const World = @import("x_test.zig").World;` used only in tests), are used only for tests, while declarations never referenced at all are dead code and count as production code.
  - When the cursor is in a test declaration or in a file used only by tests, these files are offered as usual.
- Across files, imports follow only chains of public declarations; across modules, the named imports available to the current file are used, and no relative path crossing a module boundary is generated.
  - Modules are offered by their import names (`std`, `builtin`, the named modules, and `root`, the root module of the file's compilation, offered only as a module); a module root is never offered under its file name (such as `root` for a package rooted at `root.zig`).
  - A relative path within the same module must stay inside the subtree of the root directory of the highest-priority module the file belongs to, and the path separator is always `/`.
  - A file in no module (a single-file root, or a build script while the build graph lacks it because build.zig fails to configure) is the root of its own module (except for files of the standard library): the files it reaches through relative imports (outside test code, only through imports not used only by tests) are offered by their paths under its directory.

## Placing new imports

- New imports are placed by the rules of organize imports (see Organize imports in `docs/features/code-actions.md`):
  - when the block containing the last top-level import declaration is already organized, the import goes to its group and sorted position (a new group gets a blank line before and after it);
  - when the block is not organized, it is not reordered as a side effect, and the import goes after the last import declaration;
  - when there are no imports yet, it goes after the `//!` doc comments and the comment header (such as a license, separated from the code by a blank line) at the top of the file;
  - a comment directly above a declaration stays with it.
  - Same-line comments and regular comments before the doc comments are preserved.
  - When the file starts with a UTF-8 BOM, the BOM stays first and the import is inserted after it.
  - Identifiers and strings are each escaped by their own source rules, and the additional edit does not overlap the main edit.

## Selecting a candidate

- When a candidate is selected (`completionItem/resolve`), the signature of the definition it refers to (`detail`, the same as hover), its doc comment, and its location (`documentation`) are provided.
  - The location is the file and line of the definition: for the standard library, the path under `std/`; for a file the current file can import by path, the import path; for other modules, the module name the current file imports it by, plus the path under the module's root directory.
  - The completion item's `data` records the current file, the target file, and the declaration's `AstId`; the signature requires type inference, so it is computed only on selection and not in the completion run on every keystroke.

## Index

- Namespaces and the canonical targets of aliases are evaluated by `Resolver.namespaceOf` / `aliasTarget`, the same implementation that goto, hover, and other features use; when the initializer is in conditional form (`pub const X = if (cond) A else B;`, `switch`), its value is computed by inference, taking the branch selected at comptime:
  - `FileDecls`: the declarations accessible from the file root, derived from the ItemTree (nested under named consts whose value is the container itself), and the public paths within the same file (a public alias can point to a private container of the same file; other files are not expanded); it owns its names, paths, and docs, and is never evicted.
  - `FileLinks`: the namespace each declaration refers to, and the canonical targets of aliases.
  - `Exports`: the closure expanded along public members; each namespace keeps only one public path, the one with the fewest hops, which terminates alias cycles; names and docs reference the values of `FileDecls` directly and are compared for equality by pointer.
    - Each namespace used by completion (the roots of the modules, and the namespaces that the aliases of the current file point to) has its own closure; at most 1024 values and 16 MB are kept, and evicted ones are expanded again from `FileDecls` and `FileLinks`; the dependency metadata the engine keeps for each key does not count toward this limit.
- Indexing starts only on the first completion at a name that can be auto-imported, so sessions without completion (browsing, goto) do not pay for this memory and computation.
  - Background indexing has two steps:
    - first the workspace symbol index of the project files, usable as soon as it is built;
    - then the auto-import index: the public closures of the standard library, `builtin`, and each named module are indexed in batches along the files involved (evicting intermediate results such as parse trees between batches), then the `FileLinks` and `ImportSites` of the project files, and finally `TestOnlyFiles` is computed (reading only the `ImportSites` already computed for each file, without parsing all project files in one read transaction);
    - the index is marked usable only when all of this is built.
  - The namespace and alias target of each declaration are cached per declaration (`DeclNamespace`, `DeclTarget`, keyed by the declaration's AstId):
    - large standard library files have over a thousand declarations, so when an edit interrupts the indexing read transaction, declarations already computed need not be recomputed, and the index can still be completed during continuous typing;
    - declarations unchanged by an edit also hit the cache directly.
  - When evaluating a single declaration takes longer than the interval between two keystrokes (such as when the condition of `pub const X = if (slow()) A else B;` runs many comptime loops), an interruption means starting it over, so the index cannot be completed during continuous typing and is completed once typing stops.
  - Until the index has been built for the composition of the current module graph (the standard library, the roots and builtin of the modules, and the import tables of the modules), completion offers no auto-imports and is marked incomplete (the client requests again as the user types), and closures are not expanded synchronously within the request;
  - a module graph that only gained or lost files (generated files produced by the build, newly imported files) does not affect this, and the syntax indexes of those files are built on demand during completion.
  - When the previous round did not finish (an error, or the task failed to start) and no indexing is in progress, the next such completion starts it again.
  - The indexing task may run inline while completion holds a read transaction; when it runs inline, its read transaction and a waiting write transaction would wait for each other, so it is scheduled from another task.
- `BindingNames` depends on the current file's syntax tree independently, collecting only declaration sites (ItemTree members, parameters, local variables, captures) and never treating plain name references, member accesses, or labels as declarations; adding or removing a binding inside a function body updates the conflict check without widening the invalidation of `FileDecls` to function bodies.
