# Diagnostic consistency with the compiler

This document defines the consistency the published diagnostics guarantee against the compiler, and the file model (origin, compile context, file identity) that the other documents refer to.

---

## The definition of consistency

For **the same disk contents, the same Zig version, and the same build step and build arguments**, the published diagnostics equal the output of `zig build <step>` entry by entry:

- the file and the start and end positions (the ErrorBundle span) are exactly the same;
- the severity and the message text are identical verbatim, and notes and reference traces correspond one to one (mapped to `relatedInformation`);
- nothing extra is reported (generic function bodies that are not analyzed, files not in the compile set, except for the live diagnostics of the files in module directories described below), and nothing is missing (including link errors).

| Source | Trigger | Implementation |
|---|---|---|
| `live` | edit (50 ms debounce) | in-process `std.zig.Ast` + AstGen; falls back to `zig ast-check` when the user's zig version differs from the built-in standard library |
| `compiler` | save | `ErrorBundle` sent back over the build system protocol; `zig build-obj -fno-emit-bin --listen=-` without `build.zig` |

## Live diagnostics

Published for the files that can be compiled with a project:

- files reachable through `@import` from the root modules of its compile steps;
- files under the directory of a module's root file, so files not imported yet get their syntax and AstGen errors while they are written;
- the build scripts.

Other files under the root directory, outside every module directory, get none, except open `.zon` files: whether a file is valid ZON does not depend on any build. `zig-analyzer.zon` also gets the problems in its settings once its syntax is valid: an unknown setting or a wrong type is an error (the whole file is ignored), and a setting only the editor can set is a warning (only that setting is ignored).

The official parser and AstGen recurse per level, so deep files run on a dedicated thread with a stack sized by the estimated depth. Past 409600 levels (102400 on 32-bit), 4 times what `zig ast-check` handles on 64-bit, a file gets no live diagnostics.

## Notes, reference traces, and compile log output

Notes and reference traces map to `relatedInformation`, with messages as in `zig build`. The `@compileLog` output is appended to the `found compile log statement` error, or, when the compiler ties it to no error, to the first error under the build root. When unsaved changes hide that error, the output is published on its own with severity Information.

## Validation of error bundles

Every `ErrorBundle` from a child process has its indices and strings validated before use, with depth and total reads bounded and cycles rejected. An invalid bundle is discarded and logged, and the compilation is treated as having no errors. A path that is not absolute after resolution is not treated as a file. Numeric values are not validated: an inverted range becomes empty, and diagnostics falling out of range after shifting are not published.

## File origin

Checked in this order (`server/origin.zig`):

1. Fetched dependency packages: packages fetched by hash that contain modules (`<hash>` subdirectories of the package directory).
2. Generated files: the global cache and each project's local cache.
3. User code: files under a workspace root, excluding its `.zig-cache` and `zig-pkg`, and excluding the Zig installation in use when it lies under the root (a package manager's prefix such as Homebrew's is a git repository, which editors take as the root). The exception is Zig's own source tree, recognized by a `build.zig` next to the lib directory: there the lib directory is the code being developed. A root inside the installation, such as its `std` opened as a folder, does not count either.
4. The Zig installation directory.
5. User code: modules outside the roots that belong to some project (added by path, `--fork`).
6. Other files outside the roots, in no project, are the user's files outside the workspace once the Zig installation's location is known; which other files use them is not known. Stale copies in a root's `.zig-cache` or `zig-pkg` are neither user code nor files outside the workspace.

Fetched packages, generated files, and the Zig installation are **dependency libraries**. Their locations come only from the zig in use (`zig env`, `zig.lib_path`) and the projects' build graphs, never from the layout of directories, and inside a root they take precedence over it; rust-analyzer does the same with the sysroot `rustc` reports and the dependencies `cargo metadata` reports. Another Zig installation is therefore not a library. The compile context, durability levels, rename and workspace symbol scopes, and server-side watching all derive from this classification.

## Compile context

Opening a file does not by itself create a compile entry point. Checked in this order:

1. Dependency library.
2. Project: in some project's module graph.
3. Project directory: under a root with `build.zig`, not in the module graph. Opening a file of a sub-project (see "Sub-projects" in `design.md`) starts its project, which then usually has the file in its module graph.
4. Unloaded project: `.zig` files with a `build.zig` in an ancestor whose project is not loaded, and files of sub-projects while `build.sub_projects` is off. Named imports need that project's build, so these are not compiled alone; as in rust-analyzer, a Hint suggests adding the directory to the workspace (or turning the setting on), published only after first loads finish. The search stops at `.zig-cache` and `zig-pkg`.
5. The Zig lib directory in use, where it is user code (Zig's own source tree outside the projects, such as with build integration off). Zig compiles its files as parts of its own modules (`std`, and the build runner and the other roots in `lib/compiler`), so they are never compiled on their own: compiled alone, a file of `std` is in two modules ("file exists in modules 'std' and ...").
6. Other `.zig` files are detached files, each compiled as its own root (single-file mode).

## File identity and aliasing

- Paths are normalized lexically, without resolving symbolic links. ASCII case folds only on case-insensitive volumes: always on Windows, never on Linux, and per volume on macOS, so `Parser.zig` and `parser.zig` on case-sensitive APFS are two files, as for the compiler.
- `zig build` gets the build script by its root-relative path (`--build-file`): otherwise it reports paths with symbolic links resolved, which the client does not use.
- Tools may still spell one file differently: `zig env` reports the real path of Homebrew's Zig, and FSEvents reports names in on-disk Unicode form. Two spellings are one file when their real paths are equal, and an unknown spelling becomes an alias of the known file, which keeps its path, origin, and module. Diagnostics, goto, and hover use the URI the client opened.
- A file opened under several URIs at once is one file, with the text of the document changed last. Its diagnostics go to each document, and disk contents apply once the last closes.

## Compiler diagnostics

- They come from the latest build of each project containing the file. Single-file results are used for dependency libraries and detached files, but not files in projects: a detached file importing them is a different module, where named imports differ.
- Multiple results merge: the most recently read text is authoritative, results from other text contribute only non-AstGen errors shifted by the diff, and duplicates with the same range, message, and notes collapse. Errors differing only in notes (one per inline call site) are all kept.
- Ranges refer to the text the compiler read. A file lacking the reported source line changed during the build, so its locations are discarded until a later build reads it.
- A save or disk change rebuilds every project containing the file (restarting for a build script), and recompiles a detached file and the roots that read it or reported errors in it.

## Single-file mode

- Errors in imported files are published on those files, open or not.
- The compile's local cache is the global cache, as zig chooses when no directory above the file has a `build.zig`. zig would otherwise look for one, which on case-insensitive file systems (macOS, Windows) also matches the standard library's `Build.zig`, and write a `.zig-cache` there. A `ZIG_LOCAL_CACHE_DIR` set by the user is left to zig.
- Compiles are deferred until startup and first loads finish, since until then it is not known whether a file belongs to a project.
- Whenever file context may have changed, roots that are no longer detached drop their results, and deferred compiles run.
- A root missing from disk drops its results.

## Unsaved changes

Live diagnostics use the buffer. Compiler diagnostics use the saved contents, with positions shifted by the incremental edits; lines differing only in terminator count as unchanged.

## Inactive code

Off by default and enabled by `diagnostics.inactive_code`. It covers:

- branches known at comptime not to execute;
- statements after a statement known at comptime to be noreturn, including a loop whose condition is comptime true and that no `break` leaves;
- the right-hand side of an `and` / `or` whose left-hand side decides the result.

## Analyzer-owned diagnostics

Hints that are not compiler output have `source = "zig-analyzer"` and a code. They never stand in for an error and never change the compiler's diagnostics: the consistency definition above applies to `source = "zig"` alone.

| Code | What it marks | Enabled by |
|---|---|---|
| `naming.<rule>` | a name that does not follow the Names section of the style guide | `naming.enable` |
| `unused.declaration` | a private `fn`, `const` or `var` that no code in its file reaches | `unused.enable` |
| `lint.redundant_cast` | `@as`, `@intCast`, `@truncate` or `@floatCast` whose operand already has the type | `lint.enable`, `lint.rules` |
| `lint.constant_comparison` | a comparison that the range of a fixed-width integer type decides | `lint.enable`, `lint.rules` |
| `lint.dead_errdefer` | an `errdefer` that never runs | `lint.enable`, `lint.rules` |
| `inactive` | code that is not compiled under the current build configuration | `diagnostics.inactive_code` |

Hints are published for open files of user code (or files outside the workspace), not for dependency libraries, generated files, or the Zig installation; `naming.exclude` applies to the naming check. Hints on unused declarations, inactive code, redundant casts and dead `errdefer` statements are tagged `Unnecessary`, which editors show faded; a constant comparison is a warning, since it is most likely a bug (such as a loop that never ends).

### Unused declarations

A declaration without `pub`, `export` or `extern` is visible only in the file that declares it: the compiler rejects `S.x` and `@field(S, "x")` from another file, also when the container is a type returned by a generic function. `@hasDecl` and `std.meta.declarations` see only `pub` declarations, and `@typeInfo` does not list declarations. The check therefore searches references in the file only.

Hints follow reachability, not just direct references: a private helper used only by another unused declaration is reported too. Live declarations are the file-scope declarations that code outside the file or the compiler can reach (`pub`, `export`, `extern`, tests, `comptime` blocks, fields) and, through the declaration that defines a nested container, the members of that container's interface (fields, `pub`/`export`/`extern` declarations, tests, `comptime` blocks). A `@field` with a string literal is treated as a reference to the declaration of that name, since its first operand may be a type; a `@hasDecl` with a string literal is treated the same way, although it only sees `pub` declarations. A `@field` whose name is computed disables the check for the file, since it could name any declaration. Files with syntax errors get no hint, and names starting with `_` or written as `@"..."` are left out.

### Lint

A lint hint must hold under every build configuration and every instance, not only the analyzed one, so a type counts only when the source writes it as a primitive type name: an alias may name another type on another target or with other build options (`std.posix.mode_t`, `if (options.wide) u64 else u32`), while the same primitive name is the same type everywhere. Inference results confirm that the types are known and equal. Generic functions and members of the types they return are not checked (a cast redundant for one instance may be needed for another), and neither are inactive code and files with syntax errors.

- **Redundant cast**: `@as(T, x)` where `x` is a name or a field access whose declaration writes the type `T`: a parameter or variable with that annotation, a field, or `.len` of a slice or an array (`usize`). `@intCast(x)`, `@truncate(x)` and `@floatCast(x)` likewise, when the result type is written as `T`: by `@as`, a variable annotation, the return type (also the payload of `!T`, `E!T` and `?T`), or the annotated variable an `=` assigns to. The fix replaces the cast with its operand. A literal operand is a `comptime_int` and is never reported.
- **Constant comparison**: `==`, `!=`, `<`, `<=`, `>`, `>=` between an integer literal (or its negation) and a name or field access of a fixed-width integer type (`u8`, `i32`), where the literal decides the result for every value of that type: outside its range, or at an end of it (`x <= 255`, `x >= 0` for a `u8`). `usize`, `isize` and the C integer types have a different range on each target and are not checked.
- **Dead `errdefer`**: an `errdefer` in a function whose return type is a primitive type name other than `anyerror` (so it cannot return an error), or one followed in its block by no `try` and no `return` whose operand may be an error. A `return` of a literal, an initializer, an enum literal, or a name or field access whose type is not an error union or error set cannot give an error; any other operand may. Code in the rest of the block counts even when it is inactive under the current build configuration. A `break` out of the block, also with an error value, runs only `defer` statements, so it does not keep an `errdefer` alive. `errdefer unreachable` and `errdefer comptime unreachable` assert that no error follows, and are not reported.

### Suppression comments

A comment suppresses analyzer hints by code, without turning a rule off for the file:

| Comment | Effect |
|---|---|
| `// zig-analyzer-disable-next-line` | Every analyzer hint on the next line with code |
| `// zig-analyzer-disable-next-line: naming, unused` | The named hints on that line |
| `// zig-analyzer-disable` | Every analyzer hint until `enable` or the end of the file |
| `// zig-analyzer-disable: naming.type` | The named hints until `enable` or the end of the file |
| `// zig-analyzer-enable` | Ends every range |
| `// zig-analyzer-enable: naming.type` | Ends the ranges of the named hints |

- A code names itself and its family: `naming` covers `naming.type`, but `naming.t` names neither `naming.type` nor `naming.type_function`.
- A directive applies when it falls anywhere in the range of a diagnostic, so a `disable-next-line` inside inactive code covers the whole inactive range.
- `disable-next-line` applies to the next line that contains code (a token that is not whitespace or a comment), skipping blank lines, plain comments, and doc comments.
- Directives are read from line-comment tokens, so text inside a string does not count. A repeated `disable` keeps the first start; an `enable` without codes ends the ranges of every code.
- Compiler diagnostics (`source = "zig"`) and diagnostics without a code, such as the problems of `zig-analyzer.zon` and the unloaded-project hint, are never suppressed.
