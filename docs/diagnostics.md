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

- Live diagnostics are published for the files that can be compiled with a project: the files reachable through `@import` from the root modules of its compile steps (the diagnostics steps and the others, such as tests), the files under the directory of a module's root file (a relative `@import` cannot leave it; files not imported yet get their syntax and AstGen errors while they are written), and the build scripts (`build.zig` and `build.zig.zon` in the root directory, plus the files reachable from `build.zig` through `@import` by relative path, computed from the current text of the files when the project instance starts). Other files under the root directory, outside every module directory, get none. When a file belongs to several projects, they are published as long as one of those projects includes it.
- The official parser and AstGen recurse level by level (about 16 KB of stack per level in Debug builds). An upper bound on the nesting depth is first estimated from the tokens: up to 256, the work runs on the current thread; up to 409600 (102400 on 32-bit platforms), on a dedicated thread whose stack is sized by the estimated depth (at most 8 GiB, 2 GiB on 32-bit platforms; on 64-bit platforms it only takes address space); deeper files get no AstGen and no live diagnostics. The limit is calibrated on common nesting forms (else-if chains, if-expression chains, parentheses, calls, initializers, operator chains): `zig ast-check` (46 MiB main-thread stack) can check up to 102400 levels, and on 64-bit platforms the limit is 4 times that.

## Notes, reference traces, and compile log output

- Notes and reference traces are mapped to `relatedInformation`: the reference trace entries come after the notes; an entry with a location points to the referencing site, with the message `referenced by: <name>`; the hidden-count entry is at the start of the error, with the same message as in `zig build`. A note or message that the compiler counts several times ends with ` (N times)`, as in `zig build`. The `@compileLog` output, as `Compile Log Output:` followed by its lines, is appended to the message of the `found compile log statement` error; when the same compilation has other errors but not this one (the compiler then ties the output to no error), it is appended to the first error in a file under the build root (the compiler sorts the standard library and dependencies first), or to the first error when there is none. When unsaved changes hide the error that carries the output, the output is published on its own (severity Information) at the error's start, or at the start of the modified region that hides it.

## Validation of error bundles

- Before use, every `ErrorBundle` sent back by a child process (`bsp_step_completed`, `bsp_configuration_failed`, and single-file compile results) has all its indices and strings validated: the message list, each message and its notes at every level, and each source location with the reference trace that follows it lie within `extra`; string indices point to 0-terminated strings; and the counts in hidden markers of reference traces are not treated as strings. Nesting depth and the total amount read are bounded, and self-references and cycles are rejected. When a length given in the header exceeds the message body, the whole message is treated as malformed, and no memory is allocated for that length. An invalid bundle is discarded and logged, and the compilation is treated as having no errors; the generated files and the files read in the same message are used as usual. A path that is not absolute after resolution (on Windows, a path relative to another drive, such as `D:a.zig`) is not treated as a file: in an error bundle, it is treated as no location; in `file_system_inputs`, it is skipped. Numeric values such as lines, columns, and ranges are not validated: a range whose end precedes its start becomes an empty range at the start, and diagnostics that fall out of range after being shifted for edits are not published.

## File origin

- The origin of a file (`server/origin.zig`) is checked in this order:
  - Fetched dependency packages: packages fetched by hash that contain modules (the `<hash>` subdirectories of the package directory; the package directory defaults to `<build root>/zig-pkg` and changes with `--pkg-dir` and `--system`);
  - Generated files: the global cache and the local cache of each project;
  - User code: files under a workspace root directory, excluding the `.zig-cache` and `zig-pkg` in it (when the Zig installation directory is under a root directory, Zig itself is being developed, so it is user code as well; a root directory inside the Zig installation, such as its `std` opened as a workspace folder, does not count);
  - The Zig installation directory (the standard library, `lib/compiler`, etc.);
  - User code: modules outside the root directories that belong to some project (modules added by path, packages specified with `--fork`).
  - Other files outside the root directories, in no project, are the user's files outside the workspace (opened without a workspace folder, or from outside the folders) once the location of the Zig installation is known; which other files use them is not known.
  - Fetched dependency packages, generated files, and the Zig installation directory are collectively called dependency libraries. The compile context, the durability levels (Query engine in `docs/design.md`), the scopes of rename and workspace symbol (`docs/features/references-rename.md`), and server-side watching (Server and concurrency in `docs/design.md`) are all derived from this one classification.

## Compile context

- The compile context of a file is checked in this order (compile entry points come only from projects and detached files; opening a file does not by itself create a compile entry point):
  - Dependency library;
  - Project: in some project's module graph (the compile set, or reachable from the other compile steps), including modules outside the build root added by path;
  - Project directory: files under a root directory with `build.zig` that are not in the module graph;
  - Unloaded project: `.zig` files with a `build.zig` in an ancestor directory whose project is not loaded (files in another project outside the workspace, or, when the root directory has no `build.zig`, files in projects above or below the root directory). Imports by name can only be resolved by that project's build, so these files are not compiled on their own; as rust-analyzer does for files that belong to no crate, opening one only gives a Hint suggesting that the project directory be added to the workspace. The search through ancestor directories stops at `.zig-cache` and `zig-pkg` (they hold caches and fetched dependency packages, not source code of an enclosing project). The hint is published only after startup has finished and projects have finished their first load, for the same reason that single-file mode defers compiles;
  - Other `.zig` files are detached files, each compiled as a root of its own (single-file mode). With build integration disabled, there are no projects, project directories, or unloaded projects.

## File identity and aliasing

- Paths are only normalized lexically, without resolving symbolic links; prefix comparisons use the same case rules as file identity. File identity folds the case of ASCII letters only on case-insensitive volumes: always on Windows, never on Linux, and on macOS according to each volume (`pathconf(_PC_CASE_SENSITIVE)`, asked once per directory; a path that does not exist follows its nearest existing ancestor), so `Parser.zig` and `parser.zig` on a case-sensitive APFS volume are two files, as they are for the compiler. `zig build` is given the build script by its path under the root directory (`--build-file`): it would otherwise take the build root from its current directory, which the operating system reports with symbolic links resolved, and report the files of the project and of its path dependencies under paths the client does not use.
- Tools and the client may still spell one file differently: `zig env` locates the Zig installation from the real path of the zig executable (Homebrew's `/opt/homebrew/lib/zig` is reported under its `Cellar`), and FSEvents reports names in the Unicode form stored on disk (decomposed names for the client's composed ones). Two spellings name the same file when their real paths (symbolic links resolved, names as stored on disk) are equal, and the other spelling becomes an alias of the file the server already knows, which keeps its path, origin, and module; only paths the server does not know under that spelling are resolved on disk:
  - A document the client opens under an unknown path whose real path differs is the file at the real path when the server knows that file or it is in a dependency library (the standard library opened through a link keeps the library's origin and module); otherwise the document's own path is used. The origin rules are known only after startup: a library file opened through a link before that remains a file of its own.
  - A path in compiler and build results that the server does not know is the open document with the same real path, if any (the real paths of open documents are cached until a document is opened or closed or a file is created or deleted).
  - Server-side watching: a name in a notification that is not a file of interest is the file of interest in the same directory with the same real path, if any (cached until the files of interest are recomputed or the name is created or deleted).
  - Diagnostics, goto, and hover of such a file use the URI the client opened it with.
- A file the client opens under several URIs at once (spellings that differ only in case on a case-insensitive volume) is one file, with the text of the document opened or changed last. Each document keeps the client's text of it while several are open: an edit applies to the text of its own document, the file's diagnostics are published to each of its documents, and closing one leaves the file open with the text of another (the closed URI's diagnostics are cleared); the disk contents apply once the last one is closed. Changes to a URI that is not open are ignored.

## Compiler diagnostics

- Compiler diagnostics come from the latest build of each project that contains the file; single-file compile results are used for dependency libraries, detached files, and other files that belong to no project, but not for files in projects, project directories, or unloaded projects (when a detached file imports them by relative path, they are in a different module, where imports by name differ from those in the project). Multiple results are merged: the text read by the most recent compilation is authoritative; from results with a different text, only non-AstGen errors are taken, shifted according to the diff; of errors with the same range, message and notes (the reference trace is not compared), only one is kept, while errors that differ only in their notes (such as one per inline call site) are all kept. Each note is shifted from the text of its file read by the compilation it comes from to the current text of that file.
- The ranges of compiler diagnostics refer to the text the compiler read; files are read from disk once the build finishes. The compiler gives most locations together with the source line they are on, and a file whose text does not have that line at a reported location changed during the build: its locations are discarded (its errors, and notes and references into it) until a later build reads it again.
- When a file is saved or modified on disk, every project containing it is rebuilt (for a build script, the project is restarted); if the file itself is a detached file, it is recompiled, and so are the roots whose last compilation read it (the compiler's `file_system_inputs`, limited to the directory of the root file) or reported errors in it.

## Single-file mode

- Single-file mode:
  - Errors in imported files in the results are published on those files (including the standard library), whether they are open or not.
  - Compiles are deferred before startup finishes (the zig environment is ready and projects have started loading) and while some project is still in its first load (before it has read the build graph and computed the compile set): at that point it is not yet known whether files outside the root directories belong to projects.
  - Single-file mode is reconciled whenever the context of files may have changed (the zig environment becomes ready, a project finishes loading, a compile set changes, a new instance replaces an old one, projects or root directories are added or removed, build integration or compiler diagnostics are toggled): roots that are no longer detached files drop their results; deferred compiles are run, and open detached files that have never been compiled are compiled.
  - When a root file is not on disk (it is found deleted when recompiling or closing), its results are dropped.

## Unsaved changes

- With unsaved changes: live diagnostics are based on the buffer; compiler diagnostics are based on the saved contents, with positions shifted by the incremental edits. Lines that differ only in their terminator (`\r\n` or `\n`) count as unchanged.

## Inactive code

Branches known at comptime not to execute; statements after a statement known at comptime to be noreturn (an `if (...) return ...;` whose condition is known at comptime to hold, a selected `@compileError`); the right-hand side of an `and` / `or` whose left-hand side is known at comptime and decides the result

