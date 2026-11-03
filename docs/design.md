# zig-analyzer design

zig-analyzer is a language server (LSP) for Zig 0.17. Current stage: feature-complete and entering large-scale pre-production validation on real projects.

## Related documents

- `docs/diagnostics.md`: the definition of diagnostic consistency with the compiler, the file model (origin, compile context, file identity), and the live and compiler diagnostic pipelines.
- `docs/perf.md`: performance targets and current status (latest data only), benchmark tooling, and current acceptance results.
- `docs/features/completion.md` and `docs/features/auto-import.md`: completion, including builtin completion, item kinds, ordering, member paths, snippets, and expected types.
- `docs/features/navigation.md`: goto, hover, signature help, and type / value display.
- `docs/features/references-rename.md`: find references, rename, document highlight, and workspace symbol.
- `docs/features/code-actions.md`: code actions, organize imports, removing unused parameters, unused captures, and naming checks.
- `docs/features/inlay-hints.md`, `docs/features/semantic-tokens.md`, `docs/features/document-structure.md` (folding, selection ranges, document symbols), and `docs/features/formatting.md`.

---

## Design goals

1. **Incremental**: a query-based engine (dependency tracking + early cutoff) reuses results across requests; editing only a function body does not invalidate the analysis of other functions.
2. **Error-tolerant**: any input (including half-written code) yields a lossless syntax tree and as much semantic information as possible; results that cannot be inferred are `unknown`, which propagates without reporting errors or guessing.
3. **Semantic correctness first**: generics and type construction use real comptime evaluation, not pattern matching; inside a generic function body without a concrete instance, inference uses the instances from the call sites.
4. **Low latency**: edits are not blocked by read requests, and outdated requests can be canceled.
5. **Diagnostics 100% consistent with the compiler**: diagnostics come only from the official Zig implementation; zig-analyzer's own semantic analysis serves only IDE features and never publishes error diagnostics (see `docs/diagnostics.md` for the definition).
6. **Build integration**: the project model is obtained through the official build system protocol (`zig build --listen=-`), without maintaining a custom build runner; without `build.zig`, it falls back to single-file mode and remains usable.

### Non-goals

- Persisting analysis results to disk (the cold-start budget is already met; see `docs/perf.md`).
- Non-LSP features such as a debugger or a test runner.

### Design principles

1. **Everything is a query**: apart from inputs, all derived data are pure-function queries, cached and invalidated by the engine.
2. **Signatures separate from function bodies**: the declaration skeleton (ItemTree) contains no function bodies and is the most important early cutoff point.
3. **Stable IDs**: cache keys do not depend on indices that shift with edits (AstId and relative positions within a member are used instead).
4. **Unknown is a first-class citizen**: any problem in user code is data (`ERROR` nodes, `unknown`), not an error, and is not turned into a diagnostic either.
5. **Reuse the official implementation**: formatting, parse errors, and AstGen use `std.zig` directly; semantic errors are produced by the compiler process.

---

## Layers

```
server/       LSP main loop, scheduling, cancellation, workspace and project management, configuration
ide/          hover · completion · goto · refs · rename · inlay hints · code actions …
ide_db/       reference search · call-site seeds
sema/         InternPool · type inference · comptime interpreter · type rendering
names/        module graph · import / name resolution
hir/          function body IR lowering · local scopes
syntax/       error-tolerant lossless CST · local reparse · ItemTree · AstId · typed AST layer · file indexes (FileIndex, ErrorSets)
diagnostics/  live (official parser + AstGen) · compiler (ErrorBundle) · compile sets
project/      build system protocol client · child-process ErrorBundle validation · zig env · builtin.zig generation
base/         Vfs · URI · inputs · ProjectModel
db/           query engine
util/         helpers shared by all layers: LSP position conversion, structural comparison, memory statistics, logging
lsp/          types generated from metaModel.json · JSON-RPC · transport
```

- Each layer depends only on the layers below it; tests may reference higher layers to drive end-to-end scenarios.
- All queries are registered in `database.zig` to form a single `Db` type. The names layer and the layers above it obtain `Db.Ctx` and the queries of the lower layers through it.

---

## Query engine (`db/`)

### Red-green verification + early cutoff

A memo records `verified_at` / `changed_at` and its dependencies; after an input changes, the dependencies are verified one by one, and when a recomputation produces an equal value, the old `changed_at` is kept and nothing downstream is recomputed.

### Durability

- Set according to the file's origin (see `docs/diagnostics.md`) when file contents are written: high for the Zig installation directory and fetched dependency packages, medium for generated files, and low for everything else; verification skips unchanged levels as a whole.
- Files that are not written but read from disk on demand during queries (such as the standard library in single-file mode) are low.
- A memo that passes verification takes the current lowest durability of its dependencies (when an input's durability is lowered but the value stays the same through early cutoff, downstream memos must not keep skipping verification based on the high durability).

### Incremental computation

A query may declare `computeIncremental(ctx, key, prev)` to receive the previous value when it is recomputed (used for local reparse).

### Cycles and depth

- Each thread maintains an active query stack, and on a cycle the query's `cycleFallback` is called; when the active query stack is very deep, cycles are detected through an index on the keys, so the cost does not grow quadratically with the depth.
- When the native stack used by nested computations exceeds a limit, they fall back the same way: the limit is 48 MiB on the server's worker threads (64 MiB stacks; on Windows they are reserved through the executable's stack reserve and committed only as they grow, so a pool worker is charged only for the stack it has used) and 4 MiB on the main thread and other threads.
- When a top-level read is interrupted this way, the interruption point is first computed from the bottom of the stack and the read is then recomputed, so deep chains complete in segments; each top-level read is segmented at most 16 times, so that even infinite recursion terminates.
- A result in a cycle is not written to a memo, and its reader does not record it as a dependency either: the dependencies it read are handed directly to the nearest frame on the stack that is not in a cycle.
  - The memo of the cycle's entry therefore depends directly on the queries and inputs read by every member of the cycle, memos form no cycles among themselves, and early cutoff on a member's old memo cannot mask a change seen by the entry.
- On a stack depth fallback, none of the queries on the stack writes a memo, and dependencies in cycles are no longer passed on to them either, so the fallback in deep recursion keeps a linear cost.
- During verification, a memo whose dependencies lead through a cycle back to a query on the stack is treated as unverifiable until that query is popped: reading it recomputes it directly, and verifying other memos treats it as changed. Each memo in a cycle is verified only once, so recomputation costs about as much as the first computation.

### Cancellation

- `pending_write` is the number of write transactions waiting for the exclusive lock; while it is nonzero, read queries return `error.Canceled` on entry to `get`, and canceled computations do not write memos; read requests are answered with `ContentModified`.
- A write transaction decrements it only after acquiring the lock, so overlapping write transactions do not clear each other's registration.
- A write transaction may declare the inputs it changes (`beginWriteOf`), and a read transaction the inputs its results may depend on (through its `Mark`): a write cancels only the reads whose inputs it may change (the counters are kept per input as well), and the others finish before it acquires the lock.

### Concurrent reads

- Read transactions run concurrently, and those that need the same memo brought up to date (computed, verified, or restored after eviction) do it once: the first one claims the memo, and the others wait until it releases the claim, then use the memo it wrote, or claim the memo themselves when none was written (its computation was canceled, or its result is in a cycle or cut short by the depth limit).
- A waiting read is canceled like a running one: a write transaction wakes the waiting reads when it registers, and the cancellation flag of a request is checked every 10 ms.
- A wait that would close a cycle of read transactions waiting for each other is not taken: such a cycle means that the queries form a cycle across their stacks, and the read computes the memo on its own stack instead, where the cycle falls back as in a single read transaction.
- Each table has its own lock, taken once per read of a memo that is already up to date.

### Memory reclamation

- A query may declare `lru` (a count) and `lru_bytes` (a byte count); eviction deletes only the value and keeps the dependencies.
- The declared values are default capacities, which can be changed with the settings `cache.capacity` (number of syntax trees) and `cache.queries` (count and MB, set per query), corresponding to rust-analyzer's `lru.capacity` and `lru.query.capacities`.
- `resetQueries` clears the type-related queries a whole generation at a time (together with `InternPool.reset`).

### Allocator

- Release builds use `PagedAllocator`, one heap shared by all threads: cached values are allocated on worker threads but freed on the threads that sweep and run write transactions, so a block freed by any thread must be reusable by any thread.
- `std.heap.smp_allocator` is not used: its free lists are split by thread slot, so the allocating side cannot get the freed blocks back, and resident memory keeps growing over a session (on the Zig compiler source, 4.5 GB after 720 rounds and still growing).
- Blocks of up to 32 KiB come from 64 KiB pages carved from 4 MiB segments; a page holds one size class (multiples of 8 up to 64 B, then four classes per power of two, so rounding wastes at most 20% of a block) and has its own free list and count of blocks in use.
- A size class allocates from the page that most recently got room, so that recently freed blocks, likely still cached, are reused first; but pages with less than an eighth of their blocks in use get new blocks only when no other page has room.
- After the transient peaks below, about 40% of the pages keep less than an eighth of their blocks, most of them long-lived (the 192 B and 224 B classes hold 40 MB of pages for 2.7 MB of blocks in the long session); sparing them lets the ones whose blocks are freed become empty, which lowers the pages assigned to classes from 0.46 GB to 0.43 GB over rounds 120-240 of the long session at the same session time.
- Taking each block from the fullest page instead saves 0.01 GB more but reuses cold holes rather than recently freed blocks, which makes allocation-heavy work with 16 threads about 10% slower.
- A page that becomes empty goes to a pool shared by all size classes, which keeps 256 empty pages committed and returns the others to the system: `madvise(MADV_DONTNEED)` on Linux; on macOS a new mapping replaces the page, since `madvise` leaves the resident size unchanged there; on Windows segments are only reserved, and pages are committed when the pool hands them out and decommitted when it takes them back.
- On Linux, segments are excluded from transparent huge pages (`MADV_NOHUGEPAGE`): with THP set to `always`, the first touch of a page would back the whole 2 MiB around it, and the first round of the long session would peak at 5.6 GB instead of 2.9 GB.
- The analyzer's memory has transient peaks of 10-12 GB (the rounds of the long session that compute the largest type graphs), so memory that is never returned, or kept for one size class, would stay near the peak;
- the cost is that each peak is returned to the system and faulted in again by the next one, which takes system time: the long session takes about 3% longer on macOS (240 rounds) and about 5% longer on Windows (40 rounds), and about 2% less on Linux (240 rounds), where user time drops by more than system time grows.
- With 40 files requested at once (`BENCH_CONCURRENT=40`), Windows answers about 8% sooner.
- Each size class has its own lock, and the pool's lock is not held during the system calls that return or commit pages.
- Larger allocations are mapped directly and returned to the system when freed.

### Errors and result values

Only two kinds of errors propagate within the engine, `Canceled` and `OutOfMemory`; query results are self-contained immutable values that store only IDs, never pointers to other memos.

---

## Syntax layer (`syntax/`)

`std.zig.Ast` is not used directly as the IDE syntax tree: its recovery from half-written expressions such as `foo.` is coarse-grained, it does not preserve trivia structure, and its node indices shift globally, which makes local reparse impossible. `std.zig.Ast` is used only for formatting and AstGen diagnostics.

### Red-green tree CST

Hand-written recursive descent that follows the official PEG grammar and never fails; where an error leaves no structure to recover, an `ERROR` node is produced, and concatenating the text of the tree always yields the original source.

### Local reparse

When an edit falls inside a brace-balanced `block` / `container_decl`, only that node is reparsed and all other green nodes are reused; the result must be exactly the same as a full parse (ensured by corpus tests and random-edit tests).

### ZON mode

- The root `source_file` of a `.zon` file (decided by path, `Parse.modeOf`) holds a single expression, parsed as a Zig expression; tokens before it that cannot start an expression (such as doc comments) and extra tokens after it go into `ERROR` nodes.
- Whether the file stays within the ZON subset is still diagnosed by `zig ast-check --zon`.
- Reparsing keeps the mode; ZON files are usually small and are always parsed in full.

### Nesting depth

- Neither the parser nor the syntax tree limits the depth; deeply nested code takes full part in name resolution, inference, and every IDE feature.
- Parsing and the layers that recurse along the tree (HIR lowering, inference, semantic tokens, etc.) are limited only by the thread stack: requests are handled on the worker threads of `Io.Threaded`, whose stacks are 64 MiB.
- As measured in ReleaseSafe, 35000 levels of nested parentheses, calls, `+` chains, field access chains, `!`, and `?`, and 20000 levels of nested blocks and else-if chains are all handled correctly; in Debug, 5000 levels.
- Deeper nesting overflows the stack and crashes the process, which the client then restarts.
- The deepest file in the standard library and `lib/compiler` is 319 levels deep.
- Responses that return nested structures limit the depth: `std.json.Stringify` panics in builds with safety checks when nesting exceeds 256 levels.
  - Selection ranges keep the innermost 200 levels, and document symbols list only the symbols within 100 levels.
  - Some results echo client values (completion and code action `data`, command arguments, the client's diagnostics), so requests whose params nest more than 128 levels are answered with `InvalidParams`.

### ItemTree

- The declaration skeleton of a file (names, kinds, flags, signature hashes), without function bodies; when only function bodies change, its value stays the same, so neither the name layer nor signature inference is invalidated.
- A ZON file has a single member: its root expression (kind `zon`, without a name).
- It is the BodyOwner that infers the root expression, not a declaration: it takes no part in the outline, symbol search, naming checks, or name resolution (a `.zon` file is not a namespace).

### AstId

Derived from the parent AstId + kind + name + ordinal among same-named nodes, and stable across edits; nodes inside function bodies are located by their HIR `ExprId`.

### Position-independent summaries

`ItemNames` stores a Bloom filter of member names, and `ContainerRels` stores the positions of containers relative to their owner; absolute positions stay in `ItemSummaries` / `FileAstIdMap`, so that merely moving source code does not invalidate semantic search.

### Typed AST layer (`ast.zig`)

Hand-written; it centralizes the knowledge of "which child node holds which information", and its accessors return optionals.

### Incomplete names

An unterminated quoted identifier is recovered as a name in syntactic decisions; the CST keeps the original `invalid` token and the diagnostic, and still distinguishes reference, declaration, member, and label positions; HIR lowers a reference that lacks a valid name to an unknown expression, which does not take part in name resolution.

---

## Name layer and HIR (`names/`, `hir/`)

### Module graph

- Comes from the build graph, plus `std`, `builtin`, and `root`:
  - `std`: `std/std.zig` of the compile step's `zig_lib_dir`, or of the zig environment when the step sets none.
  - `builtin`: generated by running `zig --show-builtin` with the module's options in the compilation that reaches it first.
    - Options the module does not set are inherited from the module the compiler reaches it from, as the compiler does, and the options of the whole compilation, such as the output mode, `is_test`, the link mode, and libc, come from the compile step.
    - It is kept in the global cache and found again by the zig version, the native target detected on this host, and the options: options without `-target` describe the host, so a host change such as an OS update generates it again.
- As in the maker's configure program, the `build.zig` of the project and of each dependency package with a `build.zig` (see Build integration) is a module of its own, importing the `build.zig` modules of its package's dependencies by the names `build.zig.zon` gives them; the files reachable from it along relative imports belong to it, after the memberships from compile sets.
- The modules a file belongs to come from the compile sets of the compile steps. A file can belong to several modules (e.g. an exe and a test each create their own module but share the root file); an import by name is looked up in the import tables of these modules in turn.
- Compile sets follow the `@import`s in the syntax tree, not those recorded in ZIR: a file with a parse error or a duplicate member name has no ZIR, but the files imported through it keep their modules while it is being edited.
  - A relative `@import` that leaves the directory of its module's root file is not followed: the compiler reports `import of file outside module path` and compiles nothing from it.
- Compile sets are computed when the build graph is read and after each build, and recomputed whenever the imports of a file they reached change (after an edit's debounce, or when the file is opened, closed, or changed on disk), without waiting for a build: a file reached through a new `@import` joins the module at once, also with `diagnostics.compiler` off, when no build runs.
- When several modules import different targets under the same name, name resolution (members, hover, completion, etc.) uses the highest-priority module: the diagnostics steps come first, native-target ones first among them, and the other compile steps follow in build graph order (changeable with `diagnostics.step`).
  - Position makes no difference: inside a test block, the test module's import of the same name is not used instead.
  - With the cursor on an `@import` or its string, goto (definition / declaration) returns all targets, ordered by the same priority; uses of an alias still jump to the `const x = @import(...)` declaration.
  - A member reached through such an import (`cfg.value`, the field `.fast` of `cfg.Mode`, a type `cfg.Mode`) corresponds to the member at the same path of names in each other target (`Resolver.moduleAlternatives`): goto (definition / declaration / type definition) lists them after it in the same priority order, and the use is a reference of each of them, recorded as ambiguous (renaming it would break the other modules);
  - the files that import a definition in any of their modules are searched for its references.
  - `@import("root")` and `builtin` follow the highest-priority membership.
  - In a test compilation `@import("root")` is the test runner (the default one in the lib directory, or the one the compile step sets), which the compiler makes the root module.
- Files that belong to no module (single-file mode, files in no compile set, files during project loading) and the build scripts are in a compilation of their own (`ModuleGraph.none`): they import std of the zig environment, their `builtin` is for the native target in Debug mode, and so is their type layout (`build.zig` is compiled for the host by the build runner, and other files by `zig build-obj` without `-target`).
  - `@import("root")` is `unknown`: such a file may be imported by another file through a relative path, or compiled by `zig test` (where the root file is the test runner); values read through `@hasDecl(root, ...)` (`std.options`, etc.) are therefore `unknown` and produce no inactive code, while files in a compile step keep the root of theirs.
  - Navigation (goto, references, rename) takes as its targets the files that may be compiled as the root (`Resolver.singleFileRoots`): the files outside the module graph that reach the file through relative imports and that no such file imports, as single-file mode compiles a file on its own as the root module; `root.marker` goes to `marker` there and is one of its references.

### Compilations

- A compilation (`ModuleGraph.Compile`) determines `@import("std")`, `@import("root")`, the `builtin` of the standard library and of each module, and the type layout (the target of its root module's builtin; see Semantic layer); compile steps with the same root, standard library, and builtin are one compilation.
- Each file has its own compilation (`ModuleGraph.home`): the one that reaches it first in the priority order above, or the compilation of files in no compile step.
- Code is analyzed in the compilation of the code that reaches it, as the compiler compiles a shared file once per compilation: a Windows exe and the host tool that generates its sources read the standard library with their own `builtin` and `std_options`, `build.zig` reads it with the host's, and two workspace folders never read each other's `root`.
- The compilation is part of the instance context (`inst`) of the sema queries (`Infer`, `DeclType`, `LocalValue`, `ErrorSetOf`, `CallEval`) and of the identity of the values they produce (container types, function values, inferred error sets, generic instances): where code outside every generic function is analyzed in a compilation other than its file's own, `inst` is a `context` key of the InternPool instead of null, and the instances created there end their `parent` chain with it.
  - It travels like an instance: code of another file reached from compilation C (through `@import`, a member access, a call) takes C, normalized to null when C is that file's own compilation, so a project with one compilation analyzes every file once with the same keys as without compilations.
  - A computation runs entirely in one compilation, as the compiler never mixes them: `enterContext` derives it from the key, the `Resolver` resolves std, builtin, and root in it (`ContextImports`), and value computations use its target.
- Only the analysis is per compilation: files, syntax trees, HIR, indexes, and every location the IDE features return are the real files, and declarations (`Def`, `OwnerKey`) have no compilation, so references, rename, document highlight, and workspace symbol see each position once.
  - A request in a file analyzes the file in its own compilation; instances found at call sites carry the compilation of their caller.
- A shared file is analyzed lazily, once per distinct compilation that reaches it, and only for the members that compilation uses; the cost is measured in `docs/perf.md` (Analysis per compilation).

### Name resolution

Local scopes → the chain of lexically enclosing containers; `a.b.c` resolves namespaces along `@import`, container definitions, `@This()`, and alias chains. A `.zon` file imported with `@import` is a value (see the semantic layer), not a namespace.

### HIR

- Function bodies, initializer expressions, comptime / test blocks, and field types and default values are all BodyOwners; they are lowered to an error-tolerant expression IR (not ZIR, which is not generated when there are syntax errors), and local scopes are computed at the same time; when a member's source is unchanged, the previous Body is reused.
- The root expression of a ZON file is a BodyOwner too; `inf` and `nan` in it (decided by the source text of the identifier, as ZonGen does) are lowered to float literals: they are inferred as `comptime_float` and highlighted as numbers.

---

## Semantic layer (`sema/`)

### InternPool

- The unique representation of types and comptime values; the same Key yields the same Index.
- When it exceeds `sema.max_intern_pool_mb`, it is reclaimed as a whole generation once no read transaction is in progress (the reclaim changes no result, so it does not cancel requests), after which results are inferred again on demand.
- The reclaim also waits until the type information is twice the most that one request or diagnostics publish has added: reclaiming what a single request needs would make every later request that needs it infer it all again and exceed the limit once more (call-site seeding over a project whose tests instantiate generic code with hundreds of types needs about 650,000 keys for one request).
- Integers in the comptime interpreter are not interned until a result is handed out, so the intermediate values of comptime loops do not bloat the InternPool.
- Calls whose arguments contain such integers do not go through `CallEval`; they execute in a new interpreter (with its own memory and backward branch count, as with `CallEval`), and their results are cached within the current evaluation by instance, quota, and arguments (the number of entries is bounded, and the cache is cleared when full).
- Once half of the native stack is used, these calls go through `CallEval` instead, so very deep recursion is still computed in segments by the query engine.
- The identity of a container type does not depend on its field types, so recursive types do not form cycles.
- Error sets with the same members are the same type whatever the order of their names; the set keeps the order of the first set interned with those members, which `@typeInfo(E).error_set.error_names` lists (the compiler lists the names in the order it first saw them, in practice the declaration order), while type names sort them by bytes as the compiler does.
- Pointer types keep their attributes as the compiler does: `align` (an explicit alignment equal to the natural one still makes a different type: `*align(4) u32` is not `*u32`), the host size and bit offset of a bit pointer (a bit range covering the whole child is dropped), `addrspace`, `volatile`, and `allowzero` (implied for C pointers).
  - An attribute whose expression cannot be evaluated is unknown, so the type is never known to equal another and is shown as `align(unknown)`; where a condition cannot be evaluated, branches giving pointer types that differ only in their alignment give that pointer type with an unknown alignment (`if (alignment) |a| []align(a) T else []T` in a generic body).
  - `&x` takes the attributes of the place: the `align(...)` of a variable, and for a field or element those of the pointer it is reached through adjusted as by the compiler's `fieldPtrType` / `elemPtrType` (a field of a packed struct is a bit pointer such as `*align(4:0:4) bool`; a field of an extern struct is aligned by its offset; with an explicit alignment, an element is aligned by its offset).
  - Derived pointers keep the attributes as the compiler gives them:
    - slicing (`s[a..b]`, also the `*[N]T` of comptime-known bounds) and pointer arithmetic (`p + n`, `p - n`) take those of a pointer to the start element (`[]align(16) u32` sliced from 1 is `[]align(4) u32`; slicing from a nonzero index drops `allowzero`);
    - `.ptr` keeps them;
    - pointer captures of `for` point to an element at a runtime index (an `inline for` capture whose first element is aligned differently from the others has an unknown alignment), those of `if` / `while` / `switch` to the payload or union field as `&x` does (a pointer to an error union payload keeps only the address space);
    - peers of pointers take the lower alignment (explicit unless neither side's is), and `volatile` / `allowzero` when either side has them, and do not resolve when the address spaces or bit ranges differ.
- Function types keep their calling convention and whether they are generic (comptime or `anytype` parameters), as in the compiler: a declaration without `callconv(...)` is `.c` when `export` or `extern`, `.@"inline"` when `inline`, and `.auto` otherwise.
  - `.c` and the tags without options are known from the syntax;
  - another value of `std.builtin.CallingConvention` is evaluated, and when it equals the target's C calling convention (`builtin.target.cCallingConvention()`) it is `.c`, as the compiler prints and compares it (`callconv(.{ .x86_64_sysv = .{} })` on x86_64-linux);
  - when it or the C calling convention cannot be evaluated, the calling convention is unknown (`callconv(unknown)`, never known to equal another).
  - Types print `callconv(...)` as the compiler does (`fn (u8) callconv(.c) void`), `@typeInfo(...).@"fn"` fills `attrs.callconv` (the value of `.c` needs the target) and `is_generic`, and `@Fn` reads the calling convention back.

### Core queries

`DeclType` (the type and comptime value of a declaration; reads only the signature), `Infer` (BodyOwner + instance → the type and resolution target of every expression), `CallEval` (comptime calls, memoized per instance and arguments), `ErrorSetOf` (inferred error sets), `LocalValue` (a single local binding).

### Inference

- Bidirectional inference mirrors Zig's result type semantics, with expected types pushed down from parameters, return values, annotations, and field initializers.
- Where branches merge, peer type resolution applies (including enum literals with enums, and `&.{}` with slices), and an enum literal in a branch, a `break` value or a loop `else` value without a result type is resolved against the peer type (`if (t) |x| x.kind else .invalid`, `break :blk .b`); `unknown` absorbs everything.
- To decide whether a call is generic, the call site reads only the callee's parameter forms (`ParamForms`), so callers are not re-inferred when only the callee's function body changes.
- For an enum literal received by an anytype parameter, the type it is coerced to in the callee's instance (for each parameter, the first coercion in the function body) is recorded in the inference result, and the literal at the call site refers to a member of that type: `testing.expectEqual(.x, actual)` coerces it to the type of actual through `@TypeOf(expected, actual)`.
- The capture of an `inline` prong on a tagged union is inferred per payload, like a loop over types: each item (for `inline else`, each field not named by another prong) is instantiated separately, so `inline .a, .b => |x|` has the type of `a`'s payload in one iteration and of `b`'s in the other, and is unknown without an iteration when they differ.
  - When a switch operand is comptime-known, the capture of the prong that executes takes the actual payload value, and its type when the capture's type is unknown.

### `.zon` values

- `@import` of a `.zon` file yields the value in that file (`ZonValue`, cached per file), in inference and in the interpreter alike.
- The text is processed by the official parser and ZonGen; when it has errors, the value is `unknown`, without guessing at half-edited content.
- Without a result type, values are the same as in the compiler: struct literals are anonymous structs and array literals are tuples (all of their fields are comptime fields), integers and characters are `comptime_int`, floats are `comptime_float`, and strings are `*const [n:0]u8`; member completion, hover, and member access therefore behave as for the same anonymous literals in source code.
- `inf` and `nan` need a result type, so values containing them are `unknown`; values nest at most 256 levels deep, and deeper ones are `unknown`.
- With a result type, the compiler parses the text according to the result type: scalars (bool, null, integers, floats, enum literals) are coerced to the result type, and anything else takes only the result type, with the value `unknown` (strings, tuples, and structs can be parsed as slices, arrays, pointers, or structs with default values, which cannot be obtained by coercing the anonymous value).

### Result types of `.zon` files

- When a `.zon` file is edited, its root expression is inferred with the result type of its import sites (`ZonResultType`, cached per file and computed when the root expression of a `.zon` file is inferred and when deciding whether `build.zig.zon` uses its schema).
- Inferring an `@import` records the reachable `.zon` import sites that have a result type (`Result.zon_imports`);
- the query finds the files that import the file directly through the `FileIndex.imports` of the files in the module graph and of the user's source files under the root directories (detached files and build scripts included) and `resolveImport` (paths ending in `.zig` are skipped), and reads the inference results of the members in them that contain these `@import` calls.
- Import sites without a result type do not constrain the value and are not counted; when all the other import sites have the same type, free of abstract parameters and unknown parts, that type is used; types that differ only in the optionals and single-item pointers around the value (`T`, `*const T`, `?T`) parse the value the same way, and the type of the value is used.
- When the types differ, depend on a generic parameter, or there is no such import site, there is no result type, without guessing.
- Values are converted to the result type as the compiler (`LowerZon`) does: the value of a single-item pointer is parsed as the pointee type and the value of a slice is an array literal (`.{ a, b }` is inferred as `[2]T`), where a `.zig` file needs `&`.
- Completion of initializer fields and enum literals, goto and references of field names, and inlay hints of field types are therefore the same as for the same typed literal in a `.zig` file; reference search does not skip a `.zon` file with a result type for not importing the file that contains the definition, and skips one without a result type, where nothing refers to a declaration.
- The dependency chain is inference of the `.zon` root → `ZonResultType` → inference of the importers → `ZonValue`, which reads only the text, so there is no cycle.

### comptime interpreter

- Executes on HIR and supports arithmetic (wrapping / saturating / overflow-checked by bit width), control flow, function calls, container construction, `@typeInfo`, and type-constructing builtins such as `@Struct` / `@Enum`; runtime values and extern functions evaluate to `unknown`. std's generic containers, `std.meta`, and so on therefore need no special-casing.
- Constructed types (`@Struct` / `@Enum` / `@Union`) are named after the function instance that constructs them (`FieldEnum(S)`); a type that is not constructed in a function and is exactly the value of some constant is named after that constant.
- Goto for members of constructed types (field access `x.name`, `E.name`, enum literal `.name`, field names in initializers `.{ .name = v }`): the name is a string computed at comptime.
  - When it comes from a string literal (such as the field names zig-clap obtains by parsing help text), the name is evaluated again while tracking the origin of literals:
    - string literals are placed in separate storage cells, and slices keep referencing them, which gives the position of the name in the literal;
    - the candidates are the constants whose initializer contains this literal, and the local bindings of the members containing the use site and the construction site.
  - A single byte taken from a string (short parameter names built with `@as(*const [1]u8, &str[i])`) records its offset in the literal, and a single-character name is also matched by byte.
  - When the literal is not in a constant visible at the construction site but is passed in as an argument (as with `help` in `clap.parseParamsComptime(help)`, which is defined in another file on the caller's side), the argument is traced back through the call sites of the instance: when the argument is a parameter of the enclosing function, the trace continues up to the call sites of the enclosing instance;
  - when the argument is a constant, the constant's initializer is used.
  - When the name comes from `@typeInfo(X)` (`@typeInfo(Tag).@"enum".field_names`), goto jumps to the member of X with the same name.
  - When the name cannot be traced to characters in a literal (such as short parameter names built from the character literal `'h'`), goto jumps to the call that constructs the type (`@Struct(...)`, etc.); `tools/lsp_bench.zig` counts such jumps separately as "at construction", not as mismatches.
  - Fields of anonymous struct values (`anon.first`) are defined by the initializer that creates the value: goto follows the value back through constants without a type annotation, fields of anonymous values, and the items of a tuple a `for` loop iterates, to the field names in those initializers.
- Builtins: integer arithmetic (including operations with an overflow bit, exact shifts, `@byteSwap` / `@bitReverse`) and float arithmetic, `@memcpy` / `@memset` / `@memmove`, `@call`, and `@embedFile` (relative to the containing file; reads the open document or the disk; `unknown` if the file does not exist).
  - `@src()` gives only its type: the `module` field is the name the build system gives the module, which the project model does not have.
  - Builtins that are meaningful only at runtime (atomic operations, C varargs, return addresses, etc.) and `@intFromError` (whose numbers are assigned by the compiler) cannot be evaluated.
- As in the compiler, backward branches (each loop iteration, each call) are counted, with a default quota of 1000 that `@setEvalBranchQuota` raises; when the quota is exceeded, the compiler reports an error, while here evaluation gives up.
  - For comptime calls (`CallEval`), counting restarts with the current quota at the call site, and evaluations that inference and goto start directly in a member use the largest quota set by `@setEvalBranchQuota` in the member body: neither gives up before the compiler does.
- The memory limit is 1 GB (the same as the limit of rust-analyzer's const evaluation), and the number of elements of an aggregate is bounded only by it: before an aggregate is expanded (copying, concatenation, slicing, `@splat`, etc.), the used capacity plus the new allocation is checked; otherwise it is checked once every 256 expressions.
- comptime-only types (calls that return them are executed at comptime) are cached per type (`ComptimeOnly`); the check covers all fields of structs (files included) and unions (excluding comptime fields) and the types in pointers, arrays, optionals, error unions, and tuples; function pointers are runtime values. Recursive types take the least fixpoint.
- A slice pointing into local storage is represented as "storage cell + path + range"; elements and the length are read directly from the original aggregate, without copying the range.
- Interned values are nested at most 256 levels deep (a self-referencing value becomes `unknown`). Aggregates whose elements are all u8 (including structs, such as a value of `struct { short: ?u8 }`) are represented as bytes; elements are read with the declared element type, and anything other than a string is displayed as an aggregate.
- In inference, slicing and dereferencing a constant (`longest[0..longest.len].*`), as well as `++`, are evaluated by the interpreter when the operands are comptime-known; taking the address of a comptime-known constant yields a pointer to that value (`@field(arguments, &name)`).
- The value of a `comptime var` is tracked in statement order: assignments and compound assignments to the variable itself update it; once it may be modified otherwise (an assignment to a field or element of it, taking its address, a method call on it, a pointer capture of it), its value is unknown from there on.
  - Zig allows modifying it only in comptime-known control flow; in inference, modifications in if / switch branches whose condition cannot be evaluated, and in loop bodies not inferred per iteration, are treated as unknown (a variable modified by a loop body not inferred per iteration is unknown inside the loop body as well).
  - When a `for` loop is inferred for iteration n, an outer `comptime var` modified by the loop body takes its value at the end of iteration n - 1 (from the inference result of that iteration), and is unknown after the loop.

### Generic function bodies

- Without a concrete instance, they are inferred under an abstract instance:
  - `comptime T: type` is an abstract parameter, shown as `T`;
  - for `comptime x: anytype`, the instance records the argument value;
  - an error union whose error set cannot be evaluated, such as `B.Error!Event`, keeps its payload type, so the result of `try` can still be determined;
  - a container defined in the body, such as `@This()` or `Self` in `fn Pair(comptime A: type, comptime B: type) type`, belongs to the function's abstract instance and is the same type as the call `Pair(A, B)` written there, shown as `Pair(A, B)` with unknown comptime values as `_`, and seeded like any other abstract type.
- **call-site seeding** infers under a call site that yields a concrete instance, and hover notes the source:
- Cross-file lookup goes through the file index; when a caller is itself inside a generic function, the caller's instance is taken, and the search for the first instance (hover / goto / completion) goes up at most 16 levels.
  - Call sites are searched in the target's file first, then in the files importing it by import distance, files at the same distance in path order, so the first instance depends only on the source, not on the order in which files were opened
- All instances (for find references, rename, goto, and the last candidate stage of semantic tokens) are computed as a closure (`AllInstances`): starting from calls outside generic functions, type flow, and dispatch sites in std, it propagates along the calls to the target in each instance of the generic callers until no new instance appears, with no truncation by depth or count.
  - The set of instantiations of code that compiles is finite; when instantiation grows without bound, the closure is truncated and marked incomplete: either argument types nest deeper with each recursion (more than 64 levels of nesting), or the total number of instances exceeds 2^18 (projects with many tests can reach tens of thousands of instances).
  - Rename and naming fixes refuse in that case.
  - The callers of each generic function (`RootCallers`) and a caller's calls under a given instance (`CallsIn`) are cached as queries and shared by the closures of a group of generic functions that call each other.
  - Callers are taken from all files in the project; for a generic function in a file that does not import the target's file, only instances whose arguments lead to types defined in the importers are kept, and scanning its callers takes only callers in the importers and in generic functions
- Before a caller is inferred, every place where it mentions the function name is first resolved statically (namespaces, global declarations, and parameter types): when all of them refer to other functions, the caller is not inferred (common names such as `print` and `init`). The caller list is cached per target and file (`Callers`) and shared by the lookups at all levels
- Calls that pass a function value together with an argument tuple (`Thread.spawn(.{}, f, .{ a, b })`, `@call(.auto, f, .{ a })`) use the tuple elements as the arguments
- Generic methods with no call sites in the project get their instances from dispatch sites in the standard library: in `std.Io.Writer.printValue`, `value.format(w)`, `value.formatNumber(w, ...)`, etc.
- The results of `@hasDecl` / `@hasField` on abstract parameters are unknown (consistently in inference and the interpreter), so comptime branches that depend on them are not judged inactive;
  - which members a container in an abstract instance (such as `@This()`) has depends only on the source, so the result is still definite;
  - tuples, anonymous structs (`@TypeOf(.{ .tag = "t" })`), and constructed types have no declarations, and their field names are in the type itself;
  - as in the compiler, slices have the fields `ptr` and `len`, arrays the field `len`, and the `_` of a non-exhaustive enum is not a field
- Instance selection: hover / goto / completion and semantic tokens share a `Refiner` that is reused per owner and picks, for each position, an instance in which the code is active and the target has a concrete type.
  - Candidates are tried in fixed stages: the first instance, the first 32 instances, all instances; they are searched in combination with the iterations of heterogeneous loops, and when none of them yields a type, the error-tolerant result of an active branch is kept.
  - Goto (definition / declaration / type definition) puts the target under that instance first, then lists the targets under every other instance (`AllInstances`, and each iteration of a heterogeneous loop) in which the code is active, each target once: the compiler analyzes each instance separately, and the same member name can refer to a different declaration in each.
- When a caller is inside a generic function but every place in it that may refer to the target (callee expressions, function arguments passed along with a tuple) already resolves to another function or another value in abstract inference, the caller's instances are not taken: a value already resolved in abstract inference is the same under every instance (unknown comptime conditions select no branch), so another function with the same name (`writer.print`) does not make the lookup go up to the caller's call sites
- When a caller calls the target through its own comptime type parameter (`P.name(...)`), only the caller's real instances are used: if no call site instantiates the caller with the target's container, no compiler-generated instance exists, so the body stays abstract (unknown), and no instance is pieced together from the target's container
- The target's container is passed to a generic function as a comptime type argument, which then calls the target through the type parameter (`ctx.get(Q, key)` → … → `Q.compute(ctx, key)` in the query engine): the file containing the dispatch site need not import the target's file, so following the import chain does not find it.
  - Starting from the calls that pass this container type in their arguments, the lookup enters, level by level, the generic calls whose arguments still contain it, until it reaches the call to the target; collecting all instances follows the same path
- Loops whose loop variable differs in each iteration: iterating over a comptime-known list of types (`inline for`, `for` in comptime; the loop variable is an abstract type), over a comptime-known list of values (`for (params) |param| ParamType(param)`; the loop variable has a type but no value), or over a tuple whose elements have different types (`inline for (.{ &posix, &windows }) |cases|`; the type of the loop variable cannot be determined).
  - When the type of the expression at the cursor cannot be determined, or the call is inside such a loop, inference runs one iteration at a time (over all iterations):
    - the other loop variables of the same loop (`for (types, 0..) |T, i|`) take the value and type of that iteration, and a pointer capture over a constant list (`|*param|`) takes a pointer to the element of that iteration;
    - iterations in which the type at the cursor is noreturn (`.none => continue`) never reach that point and are not chosen.
  - `inline` switch prongs (`inline 0...n => |index|`, where the operand is neither a union nor an error set) are likewise inferred for the value of each prong item, with ranges expanded integer by integer.
  - A container defined in such a loop body or prong body (`const Wrapper = struct { inner: V };`, where `V` depends on the loop variable) takes the instance of that iteration when inferred per iteration (the instance records the loop variable and the iteration number), so its field types can be determined;
  - when not inferred per iteration, it takes an instance whose iteration is undetermined, which does not count as a concrete type, and call-site inference expands each iteration instead;
  - hover notes `inferred from iteration <n> of the loop at <location>`
- The search cache stores the caller owner, expression identities, and instances, and converts them to absolute positions only at presentation; the import closure and the candidate-name queries are reused across members.
  - Arguments, declarations, imports, and the project configuration are still invalidation dependencies, and edits that only shift positions do not repeat the deep search.

### Other build configurations

- Members that do not exist under the current configuration (code compiled only on other targets, such as `posix.system.EVFILT.READ`, or `settings.cflag.CCTS_OFLOW` on macOS) are looked up in the containers of other configurations: the containers under each configuration are collected along aliases and the branches of comptime-conditional `if` / `switch`;
- the types of instances are collected along local variables, global variables, call return types, and field types.
- The candidates are distinct container types, with no limit on their number; aliases and inference chains are followed at most 16 levels deep, so that mutually referencing declarations do not form a cycle.

### Target-dependent

- Parameters that depend on the target are computed for each compilation (`ContextTarget`) from the target (architecture, operating system, ABI, CPU features) parsed from the builtin.zig of its root module, since the compiler lays out every type of a compilation for that target, and results that depend on them are invalidated when the target changes;
- compilations and modules with the same parameters share one builtin.zig, and each copy is read and parsed only once.
- A computation selects the parameters of its compilation when it starts (`enterContext`); computations outside every compilation (no module graph yet) use the parts the builtins of all modules and compilations agree on (`TargetAbi`).
- The parameters include the pointer bit width, the layout rules for vectors, the maximum alignment of integers, the signedness of `c_char`, and the size, alignment, and bit width of the C types and of `f32` / `f64` / `f80` / `f128`, computed by the rules of the compiler's `Type.abiAlignment` / `abiSize`: C types use `std.Target.cType*`, integers use `std.zig.target.intAlignment` / `intByteSize`, and floats follow the C type, the integer that represents them, or compiler-rt's soft-float representation.
- The bit width of error codes, which sets the layout of error sets and error unions, comes from the compile step's `error_limit` (`--error-limit`; 16 bits by default) as the compiler's `Zcu.errorSetBits` computes it; the common parameters keep it only when every compile step agrees.
- When the targets differ, those common parameters keep only the parts they agree on: the maximum integer alignment becomes a range, only integers whose alignment it does not affect have a determined layout, and the rest is `unknown`.
  - When builtin.zig cannot be read, the parameters last parsed from it are used (a generated builtin.zig is named by the hash of its contents, so deleting it from the cache during a session does not change them); when it has never been read, only integers of at most 1 byte have a determined layout; without any builtin, the analyzer's own target is used.
- Values that std does not define are `unknown`: the 32-bit `long double` of AVR, and the C types of ps3 / contiki / managarm.

---

## Build integration (`project/`)

### Build system protocol

- Acts directly as a client of the official build system protocol `zig build --listen=-`:
  - the handshake checks `build_system_version`;
  - the build graph (`std.Build.Configuration`) in `bsp_configuration` is read and converted into a ProjectModel;
  - builds are requested per step, and the `ErrorBundle` and generated file paths are taken from `bsp_step_completed`;
  - `bsp_configuration_failed` is published as diagnostics of `build.zig`.
- A diagnostics step or one of its dependencies that fails without reporting errors, and not because one of its own dependencies failed (a missing system library, a failing Run or Fail step: the cause is only on the maker's stderr), is named in the end of the build progress instead of `Done`, and the user is warned once until the set of such steps changes.

### Projects without a compile step

- The build graph contains only modules reachable from steps.
- A project without any compile step (a library that only exports modules and is compiled by its users) gets a probe package generated in `.zig-cache/zig-analyzer/exports`: it has the project as a path dependency, adds an object step for each exported module, and reuses the project's `zig-pkg`.
- The modules and compile steps read from it are merged into the ProjectModel, used only to determine module membership, and never appear in build requests.

### C bindings

C bindings are generated by the build system's translate-c (Zig 0.17 removed `@cImport`) as modules rooted at generated files, whose paths become known after the build.

### Module graph updates during a build

- As the paths of generated module root files become known one by one during a build, the compile set is recomputed and the module graph updated without waiting for the whole build to finish, but throttled: at least 1 second after the previous recompute ends, and no less than 4 times its duration.
- Reading build events and recomputing happen in the same task, and on a large project one recompute can take seconds (the Zig compiler's build graph has over four thousand compile steps); with a fixed interval, this task would recompute all the time, the maker's events would pile up, the build would slow down, and the module graph would update every second throughout the build.

### Local cache directory

- Generated file paths that the maker reports with the `local_cache` prefix, and paths in the build graph relative to the local cache, are resolved against the local cache directory the maker actually uses.
- It is derived from the path of the build graph given in `bsp_configuration` (`<local cache>/c/<hash>`, or `tmp/<hex>` when no cache is used), so `--cache-dir` in `build.args` and `ZIG_LOCAL_CACHE_DIR` are respected.
- Rename does not modify generated files in this directory; when the local cache directory contains the build root, generated files and project files cannot be told apart, so the directory is not used for exclusion.

### Fetched packages

- Among the dependency packages containing modules, those whose root directory name is the package hash are fetched packages (the maker stores fetched packages in the `<hash>` subdirectory of the package directory); their root directories are recorded in the ProjectModel to tell dependency code apart from user code.
- A package given by `--fork` uses the directory the user specifies and is not included.

### Restarts

The same process provides both the project model and the compiler diagnostics. A restart runs as a new instance:

- First the maker and its child processes are ended, for both the project's current instance and any new instance that has not replaced it yet; then the new instance is started.
  - The new instance replaces the old one when its first build completes (or configuration fails while the old instance has no model, or no build is needed); until then, the old instance's model, compile set, and compiler diagnostics stay in effect, and build requests are forwarded to the new instance.
  - When the old instance has no model and compile set, the new instance replaces it as soon as it has computed its compile set.
  - When configuration fails while the old instance has a model, the new instance is dropped instead: the old instance's model and compile set stay in effect (named imports keep resolving, and references and rename keep finding importers), and the configuration errors replace its compiler diagnostics until `build.zig` is saved again.
  - Instances are reclaimed by reference counting.
- Restart triggers:
  - `build.zig`, `build.zig.zon`, or `zig-analyzer.zon` in the root directory, or a build script (a file reachable through `@import`s along relative paths from the `build.zig` of the project or of a dependency package with a `build.zig`, found through the `.dependencies` of each `build.zig.zon` (`.path` relative to the declaring package, `.hash` in the package directory), together with those packages' `build.zig.zon`: the maker compiles all of them into the configure program), is saved or changes on disk;
  - a configure input that `build.zig` declares (`b.dependOnFileContents`, `dependOnFileMetadata`, `dependOnDirectoryContents`, ...; the build graph's `path_deps`) changes: such a file is saved, created, deleted, or changed on disk, or such a directory is created or deleted or an entry is created in or deleted from it (not recursive), as `zig build` repeats the configure phase then;
  - the build configuration changes;
  - the maker crashes (restarted immediately, at most 3 times in a row without a completed build in between: the crashes it recovers from are races in the maker, which waiting does not avoid);
  - the maker's local cache directory or its `h` directory is deleted or replaced (the maker writes through the handles it opened at startup, so steps writing into the cache would fail without errors; checked by inode before each build and when a build ends, and a build that ends this way keeps the previous diagnostics).
  - Creating or deleting `build.zig` in a root directory starts or stops the project.
- When the new instance is abandoned (the maker crashes more times in a row than the limit, exits during the configure phase without sending configuration errors, or the protocol version does not match), the old instance's compiler diagnostics are cleared and its model is kept until `build.zig` is saved again.
  - A maker that exits before sending a build graph or `bsp_configuration_failed` failed its configure phase (an invalid option in `build.args`, an unknown target, an error or panic in `build()`): this is not a crash and is not restarted, since it would fail the same way; the user is shown the line of its stderr that gives the cause (the maker's stderr is always read, keeping its last 64 KiB).
  - When the build graph cannot be read, the user is notified and the maker is stopped until `build.zig` is saved;
  - when `bsp_configuration_failed` contains no errors (a problem with `build.zig.zon` or a dependency package, which the maker writes only to its stderr), the located errors on its stderr (`<path>:<line>:<column>: error: ...` with their source line, marker line, and notes) become the configuration errors, published on `build.zig.zon` like the errors of `build.zig`;
  - when none can be located, the user is shown the line of its stderr that gives the cause.

### Process management

- The maker and the child processes it starts belong to a process group led by a watchdog `sh` on POSIX, and to a Job Object with `KILL_ON_JOB_CLOSE` set on Windows.
- Stopping a project (shutdown, exit, end of input, restart) ends the whole group immediately, without waiting for the build; however the server exits, the whole group ends with it.
- A maker ended this way never runs its clean exit, which is where it deletes a poisoned build graph (one that cannot be cached, e.g. when `build.zig` calls `b.findProgram`, left in `<local cache>/tmp` for a single run): the server deletes such a build graph once it has read it, or when the instance that received it is stopping.
- Each single-file `zig build-obj` and the processes it starts form such a group as well. Shutdown, exit, end of input, and the exit of the client process end the compiles in progress immediately, without waiting for them or publishing their results, and start no further compiles (including those requested during a compile); however the server exits, the compilers end with it.

### zig environment

At startup, `zig env` is run to get the lib directory, the standard library directory, and the global cache directory. When it cannot be run (zig not found at `zig.path` or in `PATH`, or `zig env` fails), the user is warned: without it there is no standard library, no named modules, and no compiler diagnostics.

- `zig.lib_path` and `zig.global_cache_path` override the detected directories: the lib directory must contain `std/std.zig`, and the cache directory must already exist; otherwise the user is notified and the detected directory is kept.
  - The overriding paths are passed through the environment variables `ZIG_LIB_DIR` and `ZIG_GLOBAL_CACHE_DIR` to every zig process that is started (`zig build` has no argument for setting the global cache directory), so the maker, single-file compilation, and the generation of builtin.zig use the same standard library as name resolution.
- `zig.builtin_path` replaces `@import("builtin")` for files that belong to no project (by default it is generated for the native target with the settings of `zig build-obj`, as single files are compiled); modules in projects still use the one generated from their build arguments, so their own targets are unaffected.
- When these options change, they are applied again: the standard library and builtin.zig are reloaded with the module graph; when the lib or cache directory changes, projects restart and detached files are recompiled. A replaced environment is freed only when the server exits: tasks in progress and running project instances may still be using it.

### Version coupling

- The `Configuration` format and the in-process AstGen both come from the standard library zig-analyzer is compiled with.
- The build graph file has no version number and is read as raw structs, byte for byte, so a mismatched format is misread (the `build_system_version` checked in the handshake covers only the protocol messages).
- It is therefore read only when the user's zig version is exactly the one zig-analyzer was compiled with.
- Before it is converted, the lengths in its header must add up to the file size and every index, tag, and string the conversion follows must be in range; a file that fails this is reported like any other unreadable build graph.
- When the versions differ, the build system is not started for root directories with `build.zig`: there are no compiler diagnostics, imports of named modules (dependency packages, build options) cannot be resolved, and only the live diagnostics of `zig ast-check` remain.
  - Files under these root directories are not compiled in single-file mode either (files that use named modules would report modules not found).
  - At startup, the user is told both versions and the affected features.
- Other files are still compiled in single-file mode, reading the `ErrorBundle` produced by the user's zig. Its format has no version number either: it is validated as described in `docs/diagnostics.md` before use and dropped if validation fails; a bundle that passes validation is never read out of bounds, but with a mismatched format the diagnostic contents may be garbled.
- Release versions follow Zig versions.
  - The version a binary reports (`--version`, `serverInfo`) comes from `git describe --tags` at build time, and falls back to the version in `build.zig.zon` when no tag is reachable or git is unavailable.
  - Since git's answer is outside what the configure cache tracks, `build.zig` marks its configuration as not cacheable, so every `zig build` runs the configure phase.

---

## Server and concurrency (`server/`)

### Write transactions

Write messages (document sync, configuration, workspace and file-watching events) run serially: register as waiting (increment the cancellation counter) → wait for readers to exit → apply the changes and advance the revision. The main loop's message handling and the handling of external changes discovered by the server are serialized by the same lock.

- No write transaction is opened when the inputs have not changed: a write of an identical value does not advance the revision, but it still cancels in-flight read requests (answered with `ContentModified`) and background computations. The module graph is recomputed after every build; when it is the same as the current one, the update returns immediately.

### Requests during project loading

- Requests that use name resolution and types are answered at once while the zig environment or a project's first load is pending, on what is known so far.
- A hover then says that the project is still loading; other answers have no place for such a note and may lack results.
- With `sema.wait_for_project`, these requests are held back until the load ends (or they are canceled, or the server shuts down) and every answer is complete; what changes meanwhile cancels a held request only when it changes the text of the request's own document (`ContentModified`), since its positions refer to that text.
- While the configuration that starts the projects is on its way from the client, whether that setting is on is not known: these requests are held until it arrives in either case.
- A restart (`build.zig` saved, settings changed) does not end a first load: it goes on in the new instance.
- Syntax features never wait.

### Read requests

- Read requests run concurrently on snapshots; both `$/cancelRequest` and write transactions can cancel them.
- A request is answered on the state at the time it was received: when its task starts reading only after a write transaction that began since then (such as a later `didChange` applied by the main loop), it is answered with `ContentModified`.
- The server's own updates (the module graph, the workspace file list, the live diagnostics backend) are not ordered with the requests: a request that starts reading after one has finished reads its changes.
- Requests whose results depend only on document text (formatting, document symbols, folding ranges, selection ranges, the syntax tree) are canceled only by writes that may change text: the server's own writes of the module graph, the workspace file list, and the live diagnostics backend wait for them instead.

### Diagnostic publishing

- Edit-triggered publishing is debounced per file and given up when superseded by a newer edit; live diagnostics (in-process AstGen and the `zig ast-check` child process) are computed outside read transactions and do not block write transactions.
- While a compile is in progress, the previous round's results are kept; when it completes, they are replaced atomically.
- Compile results never change after creation and are shared by reference counting: a publish takes a reference under the owner's lock and releases the lock right away, so a result is not freed during merging even if it is replaced, and it does not need to be copied.
- The publish queue coalesces by file: a file already in the queue is not enqueued again (requests to clear old diagnostics are combined as a union), and a file being computed is published once more after it finishes. Every state change (such as a build finishing) requests publishing for the open files, and computing the same file concurrently is just duplicate work.
- The diagnostics of a file may depend on the text of other files (notes and reference traces located in them, inactive code whose conditions read them, naming hints that depend on their declarations).
  - So when a document is edited (after the debounce), opened or closed, or a file changes on disk, the other open files are recomputed too; such a result is sent only when it differs from the last one sent for that file.
- Edit-triggered publishes bypass the queue and may compute concurrently with queued ones: each takes an increasing sequence number before reading state, and only results whose number is no smaller than the one already sent are sent. Every state change is followed by a publish, so the last result sent has read the state after the last change.

### Configuration

- Configuration comes from the client (`initializationOptions`, `workspace/configuration`); a `zig-analyzer.zon` in the project root (ZON, comments allowed) can override the project-related options.
- See `src/server/Config.zig` for a description of each option.
- Settings pulled through `workspace/configuration` or pushed through `workspace/didChangeConfiguration` replace the current settings; a `null` section in the reply to a pull means the client cannot provide it, and the current settings (from `initializationOptions` or an earlier push) stay in effect.

### Exit

- On `exit` and at end of input, the read requests in flight are canceled instead of awaited (nobody reads their results anymore; `shutdown` still waits for them), and the server no longer waits for the client's replies to configuration requests (a `zig-analyzer/waitIdle` request in flight waits for them); it stops all projects and exits.
- When `initialize` gives a `processId`, the server waits for the client process to exit and then exits too (the write end of stdin may be inherited by other child processes of the client and never be closed).
- The wait uses the operating system's process exit notification: a pidfd on Linux (since kernel 5.3), kqueue's `EVFILT_PROC` on macOS, FreeBSD, NetBSD, and OpenBSD, and the process handle on Windows.
- Only when none of these is available (old kernel, forbidden by a sandbox, no permission to open the process, other platforms) does it check every 2 seconds whether the process still exists.

### External changes

- When the client supports dynamic registration, the server registers `workspace/didChangeWatchedFiles` (`.zig` and `.zon`; other files read by `@embedFile` and the files among the configure inputs are additionally registered by file name, as `**/<file name>`, once interned, the directories under the root directories that contain interned files by their name, as `**/<name>`, and the configure input directories as `**/<name>` and `**/<name>/*`).
- Clients report a folder created, deleted, moved or renamed by its own path only: an event for a path that is not a known file applies to every known file under it.
- When the client does not support it (the default for Neovim on Linux), or when `files.watcher` is `server`, the server watches the files itself;
- with `auto` and a client that registers the watchers, the server still watches the files outside the root directories itself, since clients apply the registered watchers inside the workspace folders only (without workspace folders, that is every file);
- when the client answers the registration with an error, `auto` watches every file on the server as if the client did not support it.
- When the server starts watching files nobody watched before (`files.watcher` changed at runtime, or the registration rejected), it compares them with the disk once: a known file whose known text (for one only read from disk on demand, the contents that read) differs from the disk is handled as changed, the others trigger nothing; open documents are skipped.
- Changes are handled along the same path:
- Files of interest are the interned files (`.zig` / `.zon`, files read by `@embedFile`, and the files among the configure inputs), the configure input directories, and `build.zig`, `build.zig.zon`, and `zig-analyzer.zon` in each root directory, excluding files in dependency libraries (see `docs/diagnostics.md`);
  - open documents are included: their buffers take precedence over the disk contents, but builds read the disk, so their changes on disk rebuild (or restart) like those of other files.
  - The configure input directories are watched themselves as well (their modification time is polled when they cannot be watched), so entries created in or deleted from them are reported.
- A change that leaves the contents the same is not a modification.
  - When a build step rewrites a file in the source tree unchanged every time (such as generated code), treating that as a modification would rebuild, which rewrites the file again, so the server would never become idle.
  - When a file changes several times in one batch, the last change wins (an atomic save first deletes and then recreates the file).
  - Whether to write and republish is decided against the known text: when it is the same, nothing is written or republished.
    - For a file whose text was never set, the known text is what it was read from disk on demand (`SourceText`), if anything read it: a file nothing has read yet is not changed, since nothing was computed from its contents.
    - FSEvents reports writes made shortly before the stream started, such as the files of a checkout made just before the editor starts; writing them would cancel the requests in flight.
  - Whether to rebuild (including restarting projects and recompiling single files) is decided against the disk contents read when the last rebuild was triggered this way or by saving the document (recorded as a hash): builds read the disk, whereas the known text may also come from reading the file when a document is opened or closed, or when it is first loaded, which a build has not necessarily seen.
    - So the first time a file is rewritten unchanged, it still triggers one rebuild; after that, identical contents trigger none, and the notification of a save rebuilds nothing beyond the save itself.
    - Opening a document clears its record.
    - Without a record, `build.zig`, `build.zig.zon` and `zig-analyzer.zon` in a root directory are compared with their disk contents taken just before the project's newest instance started its maker, which reads them afterwards: a notification of those contents (such as one FSEvents reports for a write made before the stream started) does not restart the project.
- The directories containing these files are watched with the operating system's native notifications: inotify on Linux, FSEvents on macOS, and directory change notifications on Windows.
  - A directory that does not exist is watched through its nearest existing ancestor; once it appears, it is watched itself, and files already in it are treated as created.
  - The directories to watch are recomputed when new files are interned (Vfs notification), roots are added or removed, directories are created or deleted, or notifications are lost.
  - A name reported created or removed that has files of interest under it is such a directory, since Windows notifications do not tell directories apart (a rename or a move to the Recycle Bin): those files are checked again.
  - A burst of notifications is merged into one batch (50 ms of quiet, delayed at most 500 ms).
  - A notification that names a file of interest under another spelling (FSEvents reports decomposed Unicode names) counts for that file (see `docs/diagnostics.md`, file identity).
- Polling (checking size and modification time) is only the last resort: when native notifications are unavailable (other platforms, initialization failure), or some directories exceed the limit on the number of watches (such as inotify's `max_user_watches`), only the files in those directories are polled, at intervals of at least 1 second and no less than 20 times the duration of one check.
  - A file's state is recorded when it starts being polled, like a watch being added, so a change before its first check is reported.
- Handling the changes counts as busy: when a project restarts, whoever is waiting for idle does not return between the end of the old instance and the start of the new one.
- Known limitation: on network file systems (NFS, SMB/CIFS, FUSE file systems such as sshfs), Windows-side files in WSL2 (`/mnt/c`), and directories shared with containers and virtual machines, native notifications do not report changes made on other machines or on the host, yet adding the watch succeeds, so there is no fallback to polling and these changes go unnoticed (as in rust-analyzer, the file system type is not detected).

### Client capabilities

- Client capabilities shape the results:
  - `RenameOptions` only with `rename.prepareSupport`;
  - code actions (which all carry edits) only with `codeActionLiteralSupport`, otherwise `codeActionProvider` is false;
  - a `DocumentSymbol` tree only with `hierarchicalDocumentSymbolSupport`, otherwise a flat `SymbolInformation[]` naming the parent as `containerName`;
  - symbol and completion kinds added after the initial protocol version only for clients that list their kinds (`valueSet`), otherwise the closest initial kind (`Struct` → `Class`, `EnumMember` → `Enum`, `Constant` → `Variable`);
  - plain text instead of markdown (without code fences) when the client lists formats without markdown;
  - signature help parameter labels as `[start, end]` offsets into the signature label (in the negotiated position encoding) with `labelOffsetSupport`, otherwise as substrings of it.

### Observability

Slow request logging (`log.slow_request_ms`); `-Dtracy=<dir>` enables tracy. Custom requests (method names prefixed with `zig-analyzer/`; for the result fields, see the respective result types in `server/Server.zig`):

- `status`: per-query execution counts, hit rates, time, and memory; InternPool and heap usage.
- `fileStatus` (parameter `textDocument`): the file's origin (see `docs/diagnostics.md`), its compile context (project, project directory, unloaded project, dependency library, detached file), whether it is open, the roots of its modules, the projects containing it and their last builds (completion time, file count, diagnostic count), and the roots of the single-file compiles rooted at it or containing it.
- `syntaxTree` (parameter `textDocument`): the indented syntax tree (nodes and tokens) and syntax errors.
- `moduleGraph`: the module graph combined from all projects: the standard library root, and each module's root file, builtin, imports, and file count.
- `reloadWorkspace`: restarts all projects, the same as saving `build.zig`.
- `waitIdle`: returns only once the server is idle (background tasks such as builds and diagnostic publishing have finished); used by tests and benchmarks.

### Crashes

- Zig has no stack unwinding, so a panic ends the whole process.
- Before exiting, the message, the current thread's context, and the call stack are written to the log.
- The context includes the message the main loop is handling; the method, document, and position of a read request; the file whose diagnostics are being published; the root of a single-file compile; a project's build events; indexing; and the stack of queries being computed.
- Assumptions that analysis code makes about input data, where degrading is possible, use soft assertions (`util/assert.zig`): a failure panics in Debug and in tests; in other builds, each site logs only once and takes the degraded path.

---

---

## Automated tests (CI, Linux / macOS / Windows)

| Command | What it covers |
|---|---|
| `zig build test-all` (Debug and ReleaseSafe) | All tests: engine (incrementality, cutoff, cycles, cancellation, eviction), syntax, names, sema, and IDE features, plus the build system protocol, single-file compilation, diagnostic consistency, and end-to-end tests, which run the zig in PATH |
| `zig build test --fuzz=<count>` | Coverage-guided fuzzing: URI ↔ path, parser losslessness, agreement between incremental and full parses, position conversion |
| `zig build corpus -- <dir or file>...` | Parser corpus cross-check (`.zig` and `.zon` files; `.zon` files are compared with the ZON mode of `std.zig.Ast`): lossless, no false errors, same structure as `std.zig.Ast`, no crash on truncation; HIR references correspond one to one to source positions and decoded names, including asm output targets, with nested containers checked by their own owners |
| `zig build check -Dtarget=x86_64-windows` (a Windows target whose minimum is Windows 10 1507, Zig's default) | Besides compiling everything, fails when the executable imports a function of ntdll, kernel32, or advapi32 that Windows 10 1507 lacks, per the version groups of the mingw-w64 `.def` files bundled with Zig; the loader would refuse to start it on earlier Windows 10 releases |
| `zig fmt --check`, no diff after `zig build gen` | Formatting and generated code |

- `zig build test`: runs only the tests that need no external tools, for quick checks during development. Under this step, zig is not found (`ZigEnv.query` returns `ZigNotFound` in this case), so the tests that depend on it (example projects, the real standard library) are skipped, and the server starts no projects or compiles.
- `zig build test-stress -Dstress-filter=<part of the full test name> [-Dstress-runs=<count>]`: runs the selected tests repeatedly, one after another, in server mode (50 times by default, each one actually run), to verify concurrency-related changes. A filter that matches no test fails.
- `zig build sema-corpus`: runs full type inference over the standard library, checking that nothing crashes and reporting the share of known types.
- When tests write logs to stderr, `zig build test` and `test-all` also print `failed command: ...`; exit code 0 means they passed. Real failures come with "N pass, M fail" and the test names.

Benchmark commands and current acceptance results: see `docs/perf.md`. The definition of diagnostic consistency and the diagnostic pipelines: see `docs/diagnostics.md`.
