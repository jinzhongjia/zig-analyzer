# Auto-import

Auto-import completion offers declarations the current file has not imported yet and adds the import when needed. It is controlled by `completion.auto_import` and is on by default.

## When it is offered

- After a non-empty prefix of a plain name expression, never for a declaration name, member name, label, comment, string, or builtin. Before a prefix is typed, the list is marked `isIncomplete` so the client queries again.
- Only in `.zig` documents: inserting an import into a `.zon` file would break it, and a module root can be a data file.

## Matching and ranking

- Exports at most two segments below the visible namespaces and module roots are fuzzy-matched by whole path: `memeql` matches `std.mem.eql`. Deeper exports and project declarations match by name prefix. The depth is fixed, with no truncation by time, so the result depends only on the source, the input, and the ranking.
- `filterText` is the name for candidates whose name starts with the input and the whole path otherwise, so clients filtering by prefix keep them. For escaped identifiers it keeps the spelling the user typed.
- Ranking follows Ordering of name completion in `docs/features/completion.md`: reusing a visible name ranks before adding an import, then shallower candidates, then those whose case agrees.
- Candidates beyond names in scope total at most `completion.max_auto_imports` (default 128, 0 for no limit); truncation keeps the highest scores and sets `isIncomplete`. Only matches are scored first; labels, visibility, and edits are built afterwards in order.

## What is offered

- **Not offered**: methods of containers, and declarations in files used only by tests (`TestOnlyFiles`), unless the cursor is in test code.
- **Across files**, imports follow only chains of public declarations. **Across modules**, the current file's named imports are used, never a relative path crossing a module boundary. A file in no module is the root of its own module.

## How a candidate is accessed

- Visible namespace aliases are reused first (`Ast.Node.Index`), without a duplicate import, and direct aliases are reused by canonical declaration identity. A same-named binding in scope takes precedence, so no shadowed binding is generated.
- Mutable globals and runtime `extern const` stay qualified (`lib.counter`) instead of copying the stored value into a constant.
- Before adding a binding, `BindingNames` checks for conflicts with actual declaration sites: on a leaf-name conflict a namespace binding is used, and if that conflicts too, `@import("...").name` is inserted directly.

## Placing new imports

New imports follow Organize imports in `docs/features/code-actions.md`:

- When the block with the last top-level import is organized, the import goes to its sorted position; when it is not, the import goes after the last import, without reordering as a side effect.
- With no imports, it goes after the `//!` comments and file header, and after a UTF-8 BOM.
- The additional edit never overlaps the main edit.

## Selecting a candidate

`completionItem/resolve` provides the signature (the same as hover), doc comment, and location. The signature requires inference, so it is computed only on selection, not on every keystroke.

## Index

- `FileDecls`: the declarations accessible from a file root, derived from the ItemTree; never evicted.
- `FileLinks`: each declaration's namespace and canonical alias target, evaluated by `Resolver`, the same implementation goto and hover use.
- `Exports`: the public closure of a namespace, keeping the fewest-hops path, which terminates alias cycles; bounded at 1024 values and 16 MB, and expanded again when evicted.

Indexing starts at the first completion that could auto-import, so sessions without completion do not pay for it. It runs in batches in the background, and the index is usable only once complete; until then, completion offers no auto-imports and is marked incomplete rather than expanding synchronously.

`DeclNamespace` and `DeclTarget` cache per declaration, so an edit interrupting indexing does not lose progress and indexing completes during continuous typing. A single evaluation longer than the keystroke interval restarts when interrupted, so that index completes once typing stops. The indexing task is scheduled from another task, because when run inline its read transaction and a waiting write transaction would wait for each other.
