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

### Verification and early cutoff

A memo records `verified_at` / `changed_at` and its dependencies. After an input changes, dependencies are verified one by one; when a recomputation produces an equal value, the old `changed_at` is kept and nothing downstream is recomputed. A query may declare `computeIncremental(ctx, key, prev)` to receive its previous value (used for local reparse).

### Durability

Set from the file's origin (see `docs/diagnostics.md`) when contents are written: high for the Zig installation and fetched packages, medium for generated files, low otherwise; verification skips unchanged levels as a whole. Files read from disk on demand are low.

A memo that passes verification takes the current lowest durability of its dependencies: when an input's durability is lowered but early cutoff keeps its value, downstream memos must not keep skipping verification.

### Cycles and depth

Each thread keeps an active query stack; a cycle calls the query's `cycleFallback`.

- A result in a cycle is not written to a memo, and its reader does not record it as a dependency: the dependencies it read go to the nearest frame not in a cycle. Memos therefore form no cycles among themselves, and early cutoff on a member's old memo cannot mask a change seen by the cycle's entry.
- Such a result is freed when the query that read it returns, or at the end of the read transaction when read outside any query. A value may point only into values of queries that are never in a cycle (those that read no query declaring `cycleFallback`, such as the syntax queries and `FileDecls`), so nothing else can hold it, and a read that computes a cycle repeatedly does not accumulate its results.
- During verification, a memo whose dependencies lead through a cycle back to a query on the stack is unverifiable until that query is popped: reading it recomputes it, and verifying other memos treats it as changed.
- When nested computations exceed the native stack limit (48 MiB on 64 MiB worker stacks, 4 MiB elsewhere), they fall back the same way, and no query on the stack writes a memo. The interrupted read computes from the bottom of the stack and retries, so deep chains complete in segments; at most 16 segments per top-level read, so infinite recursion terminates.

### Cancellation

- `pending_write` counts write transactions waiting for the exclusive lock. While it is nonzero, read queries return `error.Canceled` on entry to `get`, canceled computations write no memos, and read requests stop (see "Read requests"). A write transaction decrements it only after acquiring the lock, so overlapping writes do not clear each other's registration.
- A write may declare the inputs it changes (`beginWriteOf`), and a read the inputs its results may depend on (`Mark`): a write cancels only the reads it may affect, and the others finish first.

### Concurrent reads

Read transactions that need the same memo brought up to date do it once: the first claims it, the others wait, then use what it wrote or claim it themselves when nothing was written. Waiting reads are canceled like running ones. A wait that would close a cycle of read transactions is not taken: the read computes the memo on its own stack, where the cycle falls back as usual.

### Memory reclamation

A query may declare `lru` (count) and `lru_bytes`; eviction deletes the value and keeps the dependencies. Capacities can be changed with `cache.capacity` and `cache.queries`. `resetQueries` clears the type-related queries a generation at a time, together with `InternPool.reset`.

Eviction normally waits for a moment without read transactions, but one read transaction can compute a large part of a project under many instances. A query may therefore declare `lru_read_bytes`: above that size, a read evicts the least recently used values that nothing holds. A read pins the value until the compute that read it returns, or until its transaction ends when read outside any query; values store no pointers into the values they read, so nothing else can hold it. Only `Infer` declares it, at 512 MB: recomputing it costs little there, while the syntax trees and bodies are read again so often during such a computation that evicting them dominates its time.

### Allocator

Release builds use `PagedAllocator`, one heap shared by all threads: cached values are allocated on worker threads but freed on the threads that sweep and run write transactions, so a block freed by any thread must be reusable by any thread. `std.heap.smp_allocator` splits its free lists by thread slot, so resident memory keeps growing over a session.

- Blocks up to 32 KiB come from 64 KiB pages carved from 4 MiB segments; each page holds one size class. Larger allocations are mapped directly.
- A size class allocates from the page that most recently got room, reusing blocks likely still cached; pages with less than an eighth of their blocks in use get new blocks only when no other page has room, which lets the rest become empty.
- Empty pages go to a pool shared by all classes, which keeps 256 committed and returns the others to the system. The analyzer has transient peaks of several GB, so memory that is never returned would stay near the peak; the cost is the system time of faulting pages in again.
- Returning pages differs per platform: `madvise(MADV_DONTNEED)` on Linux; a new mapping on macOS, where `madvise` leaves the resident size unchanged; decommit on Windows.
- On Linux, segments are excluded from transparent huge pages: with THP `always`, touching a page would back the whole 2 MiB around it.

### Errors and results

Only `Canceled` and `OutOfMemory` propagate within the engine. Query results are self-contained immutable values that store IDs, never pointers to other memos.

---

## Syntax layer (`syntax/`)

`std.zig.Ast` is used only for formatting (rendered by the version-specific copies in `src/ide/render/`) and AstGen diagnostics, not as the IDE syntax tree: its recovery from half-written expressions such as `foo.` is coarse-grained, it does not preserve trivia structure, and its node indices shift globally, which makes local reparse impossible.

- **Red-green CST**: hand-written recursive descent following the official PEG grammar that never fails. Where no structure can be recovered, an `ERROR` node is produced; concatenating the tree's text always yields the source.
- **Local reparse**: an edit inside a brace-balanced `block` / `container_decl` reparses only that node. The result must equal a full parse (ensured by corpus and random-edit tests).
- **ZON mode**: the root of a `.zon` file holds a single expression parsed as Zig; other tokens go into `ERROR` nodes. Whether the file stays within the ZON subset is diagnosed by `zig ast-check --zon`.
- **ItemTree**: the declaration skeleton of a file, without function bodies. When only bodies change its value stays the same, so neither the name layer nor signature inference is invalidated. A ZON file has one member, its root expression, which is a BodyOwner and not a declaration.
- **AstId**: derived from the parent AstId, kind, name, and ordinal among same-named nodes, and stable across edits. Nodes inside function bodies are located by their HIR `ExprId`.
- **Position-independent summaries**: `ItemNames` and `ContainerRels` hold no absolute positions (those stay in `ItemSummaries` / `FileAstIdMap`), so moving code does not invalidate semantic search.
- **Typed AST layer** (`ast.zig`): centralizes which child node holds which information; accessors return optionals.
- **Incomplete names**: an unterminated quoted identifier is recovered as a name in syntactic decisions; HIR lowers a reference without a valid name to an unknown expression.

### Nesting depth

Neither the parser nor the tree limits depth; recursion is limited only by the thread stack (64 MiB on workers). Deeper nesting than that overflows and crashes the process, which the client restarts; current limits are far above real code.

Responses that return nested structures do limit depth, because `std.json.Stringify` panics past 256 levels with safety checks: selection ranges keep the innermost 200 levels, document symbols list 100 levels, and requests whose params nest more than 128 levels (they may be echoed back) are answered with `InvalidParams`.

---

## Name layer and HIR (`names/`, `hir/`)

### Module graph

The graph comes from the build graph, plus:

- `std`: `std/std.zig` of the compile step's `zig_lib_dir`, or of the zig environment.
- `builtin`: generated by `zig --show-builtin` with the module's options in the compilation that reaches it first, with inheritance as in the compiler. It is cached globally by zig version, detected native target, and options, so a host change generates it again.
- `root`.
- A module for the `build.zig` of the project and of each dependency package with one, as in the maker's configure program.

### Module membership

- A file's modules come from the compile sets of the compile steps, and it can belong to several (an exe and a test sharing a root).
- Compile sets follow the `@import`s in the syntax tree, not ZIR: a file with a parse error has no ZIR, but what it imports keeps its modules while it is edited. A relative `@import` leaving the module's root directory is not followed, as in the compiler.
- Compile sets are recomputed when the imports of a reached file change, without waiting for a build, so a new `@import` joins the module at once.

### Several modules, one name

When modules import different targets under the same name, name resolution uses the highest-priority module: diagnostics steps first (native-target ones first), then other compile steps in build graph order (`diagnostics.steps` changes it). Position makes no difference.

- Goto on an `@import` returns all targets in that order.
- A member reached through such an import corresponds to the member at the same name path in each other target (`Resolver.moduleAlternatives`): goto lists them all, and the use is a reference of each, recorded as ambiguous since renaming it would break the other modules.
- In a test compilation, `@import("root")` is the test runner.

### Files in no module

Single-file roots, files in no compile set, files during project loading, and build scripts are in a compilation of their own (`ModuleGraph.none`): they use std of the zig environment and a native Debug `builtin`.

`@import("root")` is `unknown` there, since such a file may be imported by another or run by `zig test`; values read through `@hasDecl(root, ...)` are therefore `unknown` and produce no inactive code. Navigation targets the files that may be compiled as the root (`Resolver.singleFileRoots`).

### Compilations

A compilation (`ModuleGraph.Compile`) determines `@import("std")`, `@import("root")`, each `builtin`, and the type layout; steps with the same root, standard library, and builtin are one compilation. Code is analyzed in the compilation of the code that reaches it, as the compiler compiles a shared file once per compilation: a Windows exe and its host tool read std with their own `builtin`, and two workspace folders never read each other's `root`.

- The compilation is part of the instance context of the sema queries and of the identity of the values they produce. It travels like an instance, normalized to null in a file's own compilation (`ModuleGraph.home`), so a project with one compilation analyzes every file once with unchanged keys.
- A computation runs entirely in one compilation (`enterContext`), as the compiler never mixes them.
- Only the analysis is per compilation: files, trees, HIR, indexes, returned locations, and declarations (`Def`, `OwnerKey`) are not, so references, rename, and workspace symbol see each position once.
- Shared files are analyzed lazily, only for the members a compilation uses (cost in `docs/perf.md`).

### Name resolution and HIR

- **Name resolution**: local scopes, then the chain of enclosing containers; `a.b.c` resolves along `@import`, container definitions, `@This()`, and aliases. An imported `.zon` file is a value, not a namespace.
- **HIR**: function bodies, initializers, comptime / test blocks, field types and defaults, and the ZON root are BodyOwners, lowered to an error-tolerant IR (not ZIR, which syntax errors prevent) along with local scopes. A member with unchanged source reuses its Body.

---

## Semantic layer (`sema/`)

### Core queries

`DeclType` (type and comptime value of a declaration; reads only the signature), `Infer` (BodyOwner + instance → type and target of every expression), `CallEval` (comptime calls, memoized per instance and arguments), `ErrorSetOf`, `LocalValue` (one local of a member, inferred from its initializer alone), and `LocalEval` (a local constant as the interpreter computes it by executing its function).

### InternPool

The unique representation of types and comptime values. The identity of a container type does not depend on its field types, so recursive types form no cycles.

- Past `sema.max_intern_pool_mb` it is reclaimed as a generation once no read is in progress; this changes no result, so it cancels nothing. The reclaim also waits until the type information is twice the most one request has added: otherwise every later request would infer it all again and exceed the limit once more.
- Interpreter integers are interned only when a result is handed out, so comptime loops do not bloat the pool.
- Error sets, pointer attributes (`align`, bit ranges, `addrspace`, `volatile`, `allowzero`), and function types (calling convention, genericity) follow the compiler's identity and derivation rules (`fieldPtrType`, `elemPtrType`, `builtin.target.cCallingConvention()`). An attribute that cannot be evaluated is unknown, never equal to another, and printed as such (`align(unknown)`, `callconv(unknown)`).

### Inference

Bidirectional inference mirrors Zig's result type semantics, with peer type resolution where branches merge; `unknown` absorbs everything. To decide whether a call is generic, the call site reads only the callee's parameter forms (`ParamForms`), so callers are not re-inferred when only a body changes.

- An enum literal received by an anytype parameter refers to a member of the type it is coerced to in the callee's instance (`testing.expectEqual(.x, actual)`).
- As in the compiler, a branch whose condition or `switch` operand is comptime-known gives the type and value of the branch that executes, and the other branches are inactive. `switch` items are coerced to the operand type (the tag type for a tagged union); a scalar item matches by value and a range `a...b` by both bounds inclusive.
- The capture of an `inline` prong on a tagged union is inferred per payload, like a loop over types.
- `@tagName` and `@errorName` of a comptime-known operand are string literals `*const [N:0]u8`, as in the compiler (`Sema.zirTagName`); when inference has no value for the operand (a tagged union literal, `@enumFromInt`, a call in a container-level initializer), the interpreter evaluates the name, and the type is `unknown` when it cannot. Only a runtime operand gives `[:0]const u8`.

### `.zon` files

- `@import` of a `.zon` file yields its value (`ZonValue`), processed by the official parser and ZonGen; with errors it is `unknown`, without guessing at half-edited content. Without a result type, values are as in the compiler: anonymous structs, tuples, `comptime_int`, and so on. As in the compiler, each struct literal of a `.zon` file has a type of its own: the type records the file and the path of field and element indices to the literal, so literals with the same contents are different types, and two imports of a file give the same type.
- With a result type, scalars are coerced and anything else takes only the type, with the value `unknown`, since the compiler parses the text according to that type.
- Editing a `.zon` file infers its root with the result type of its import sites (`ZonImports`, read through `ZonResultType`). When all import sites with a result type agree, ignoring optionals and single-item pointers around the value, that type is used; when they differ or depend on a generic parameter, there is none, without guessing. Completion, goto, references, and inlay hints then behave as for the same typed literal in a `.zig` file.
- The dependency chain is `.zon` root → `ZonResultType` → `ZonImports` → importers' inference → `ZonValue`, which reads only text, so there is no cycle.

### comptime interpreter

Executes on HIR: arithmetic by bit width, control flow, calls, container construction, `@typeInfo`, and type-constructing builtins. Runtime values and extern functions are `unknown`, so std's generic containers and `std.meta` need no special-casing. Builtins meaningful only at runtime and `@intFromError` cannot be evaluated.

- **Limits**: backward branches are counted as in the compiler (default quota 1000, `@setEvalBranchQuota`), and evaluation never gives up before the compiler does: `CallEval` restarts counting with the current quota. Memory is limited to 1 GB, checked before aggregates expand; interned values nest at most 256 levels.
- **Calls**: a call goes through `CallEval` with interned arguments unless an argument refers to interpreter storage that can change: an aggregate or pointer passed to a runtime parameter, or a pointer to a `var` (directly, inside an aggregate, or behind constants) passed to an anytype or comptime parameter. Such a call runs on the caller's storage, so its writes and the pointers it returns stay visible, as in the compiler, which does not memoize a call whose arguments can mutate comptime state. Pointers to constants and temporaries are interned, so those calls stay memoized.
- **Goto for constructed types**: names are computed at comptime, so they are traced back to the string literal they came from, through call sites when passed as arguments; names from `@typeInfo(X)` go to the member of X. An untraceable name goes to the call that constructs the type. Fields of anonymous values go to the field names in their initializers.
- **`comptime var`**: tracked in statement order; once it may be modified indirectly, or in branches and loops that are not inferred per iteration, its value is unknown from there on. A `for` inferred for iteration n takes the value at the end of iteration n - 1.
- **Captured locals**: a container defined in a function body captures the values the body has computed for the function's locals when it reaches the container, as in the compiler (`getCaptures`). When a member reads a local constant of the enclosing function and inferring the constant's initializer alone gives no value (it reads a local array, or a local variable that earlier statements modify), the interpreter executes the function in the container's instance up to the constant's definition (`LocalEval`). A constant in the body, condition, or continue expression of a loop gets no value this way: it has one value per iteration, while the containers of all iterations share one instance. The instance records only the type of an anytype argument, so values that depend on its value stay unknown. The call sites that produce the instance are not known, so the execution counts backward branches against the default quota, raised by `@setEvalBranchQuota` in the function itself; when only a caller's larger quota lets the function reach the constant, its value is unknown.
- **Pointers** point into the interpreter's storage: locals, temporaries, and one cell per container-level declaration whose address is taken in the evaluation. Writes through them reach the variable, addresses of the same place compare equal, and `@fieldParentPtr` goes back from a field to the value containing it. An interned pointer (in a declaration's value, or an argument of a memoized call) keeps only its pointee, not the place it points to.
- **comptime-only types** are cached per type (`ComptimeOnly`); recursive types take the least fixpoint.

### Generic function bodies

Without a concrete instance, a body is inferred under an abstract instance: `comptime T: type` is an abstract parameter shown as `T`, and a container defined in the body is the same type as the call that names it (`Pair(A, B)`). A container in the function's prototype is outside the abstract instance in the function's own type, which that instance is made from, so arguments still coerce to it; elsewhere it has the abstract instance, computed once at the entry of that cycle (`SignatureInst`). **Call-site seeding** then infers under a call site that yields a concrete instance, and hover notes the source. Call sites are looked for only in files containing the function's name, found through one index of the names of all searched files (`NameIndex`), so that a change to a file's names recomputes the lookups only for the names it gains or loses.

- **First instance** (hover, goto, completion): call sites are searched in the target's file, then importers by import distance and path order, so the result depends only on the source, not on which files were opened. Lookup goes up at most 16 levels through generic callers.
- **All instances** (references, rename, goto, last stage of semantic tokens): a closure (`AllInstances`) from calls outside generic functions, type flow, and dispatch sites in std, propagated until no new instance appears, with no truncation by depth or count. Code that compiles has finitely many instances; when argument nesting exceeds 64 levels or instances exceed 2^18, the closure is marked incomplete and rename and naming fixes refuse.
- **Instance selection**: a `Refiner` shared by hover, goto, completion, and semantic tokens picks, per position, an instance where the code is active and the target has a concrete type, trying the first instance, the first 32, then all. Goto lists the target under that instance first, then under every other active instance, since the same member name can refer to different declarations.
- **Only real instances**: when a caller calls the target through its own comptime type parameter, only its real instances are used, without piecing one together from the target's container. Callers whose every mention already resolves to something else are not inferred or followed (common names such as `print`).
- **Comptime type arguments**: when a container is passed as a type argument and the target is called through the parameter (`ctx.get(Q, key)` → `Q.compute(ctx, key)`), the dispatch file need not import the target, so the lookup follows the calls that pass this type.
- **Function values and std dispatch**: `Thread.spawn(.{}, f, .{ a, b })` and `@call` use the tuple elements as arguments; methods with no call sites get instances from std dispatch sites such as `std.Io.Writer.printValue`.
- **`@hasDecl` / `@hasField`** on abstract parameters are unknown, so branches depending on them are not judged inactive.
- **Heterogeneous loops**: over comptime-known lists of types or values, tuples with differing element types, and `inline` switch prongs, inference runs one iteration at a time when the type at the cursor cannot be determined. Noreturn iterations are not chosen; containers defined in the body take that iteration's instance; hover notes `inferred from iteration <n> of the loop at <location>`.
- **Caching**: search results store owners, expression identities, and instances, converted to positions only at presentation, so edits that only shift positions do not repeat the search.

### Other build configurations

Members that do not exist under the current configuration (`posix.system.EVFILT.READ` on another OS) are looked up in the containers of other configurations, collected along aliases and comptime-conditional branches. Candidates are unlimited; alias and inference chains stop at 16 levels so that mutual references do not cycle.

### Target-dependent layout

Parameters are computed per compilation (`ContextTarget`) from the target parsed from its root module's builtin.zig, by the rules of the compiler's `Type.abiAlignment` / `abiSize`, and results depending on them are invalidated when the target changes. Error set width comes from the compile step's `error_limit`.

- Outside every compilation, only what all builtins agree on is used (`TargetAbi`); the rest is `unknown`.
- When builtin.zig cannot be read, the last parsed parameters are used; when it was never read, only integers of at most 1 byte have a known layout.
- Values std does not define are `unknown` (AVR's 32-bit `long double`, the C types of ps3 / contiki / managarm).

---

## Build integration (`project/`)

### Build system protocol

zig-analyzer is a client of `zig build --listen=-`: the handshake checks `build_system_version`, `bsp_configuration` gives the build graph, builds are requested per step, and `bsp_step_completed` gives the `ErrorBundle` and generated paths. `bsp_configuration_failed` is published as diagnostics of `build.zig`. The same process provides the project model and compiler diagnostics.

A diagnostics step that fails without reporting errors (a missing system library, a failing Run step: the cause is only on the maker's stderr) is named at the end of the build progress, and the user is warned once.

### Module discovery

- The build graph contains only modules reachable from steps. A project without a compile step gets a probe package in `.zig-cache/zig-analyzer/exports` with an object step per exported module; what it reads is used only for membership and never built.
- C bindings are modules rooted at generated files from translate-c (Zig 0.17 removed `@cImport`), whose paths become known during the build.
- As those paths arrive, the compile set is recomputed, throttled to at least 1 second and 4 times the last recompute's duration: reading build events shares a task with recomputing, and on the Zig compiler one recompute takes seconds, so a fixed interval would stall the build.
- Generated paths are resolved against the local cache the maker actually uses, derived from the build graph path, so `--cache-dir` and `ZIG_LOCAL_CACHE_DIR` are respected.
- Packages whose root directory name is their hash are fetched packages, told apart from user code; `--fork` packages are not.

### Restarts

A restart runs as a new instance: the maker and its children are ended, and the new instance replaces the old one when its first build completes. Until then the old model and diagnostics stay in effect.

Triggers:

- `build.zig`, `build.zig.zon`, `zig-analyzer.zon`, or a build script of the project or a dependency package is saved or changes on disk;
- a configure input declared by `build.zig` changes (the build graph's `path_deps`), as `zig build` repeats configure then;
- the build configuration changes;
- the maker crashes: restarted at once, at most 3 times in a row without a completed build, since the crashes it recovers from are races waiting would not avoid;
- the local cache or its `h` directory is deleted or replaced, because the maker writes through handles opened at startup and would otherwise fail silently (checked by inode around each build).

Creating or deleting `build.zig` in a root starts or stops the project.

Failures:

- Configuration failing while the old instance has a model drops the new instance: the model stays, and the configuration errors replace its compiler diagnostics until `build.zig` is saved.
- An abandoned instance (too many crashes, protocol mismatch) clears the old diagnostics and keeps the model until the next save.
- A build graph that cannot be read stops the maker until `build.zig` is saved, and the user is told.
- A maker that exits before sending a build graph failed configure, so it is not restarted; the user is shown the stderr line with the cause (the last 64 KiB of stderr is always kept).
- `bsp_configuration_failed` without errors (a `build.zig.zon` or package problem) takes the located errors from stderr and publishes them on `build.zig.zon`.

### Process management

The maker and its children are a process group led by a watchdog `sh` on POSIX and a Job Object with `KILL_ON_JOB_CLOSE` on Windows, as is each single-file `zig build-obj`; however the server exits, they end with it. Shutdown does not wait for builds or publish their results. A maker ended this way never deletes a poisoned build graph left in `<local cache>/tmp`, so the server deletes it.

### zig environment

At startup `zig env` gives the lib, std, and global cache directories; when it fails the user is warned, since nothing works without them.

- `zig.lib_path` and `zig.global_cache_path` override them after validation and are passed through `ZIG_LIB_DIR` and `ZIG_GLOBAL_CACHE_DIR` to every zig process, so all use the same standard library as name resolution.
- `zig.builtin_path` replaces `builtin` only for files in no project.
- Changes are applied again, restarting projects when the directories change. A replaced environment is freed only at exit, since running tasks may still use it.

### Version coupling

The `Configuration` format and in-process AstGen come from the standard library zig-analyzer is compiled with. zig-analyzer builds with Zig 0.17.0 and 0.17.1, and works with either as the user's zig whichever one built it. The build graph file has no version number and is read as raw structs, so it is read only from these versions, whose formats are compatible (`ZigEnv.supported_versions`), and its lengths and indices are validated first.

- When the user's zig is another of these versions, in-process AstGen would not match it, so live diagnostics use `zig ast-check`; everything else works as usual.
- `Parse.Dialect`, from the user's zig, selects the rules that differ, with versions other than 0.17.0 following the latest. The CST parser (the `SyntaxDialect` input): only 0.17.0 accepts doc comments on `...`. Type layouts (`InternPool.Target`): in 0.17.0 the size of a `@Vector` whose alignment is capped at the stack alignment (32-bit ARM, aarch64 and s390x) is its byte size padded to the alignment rather than rounded up to a power of two, and a pointer is aligned to its size even where the maximum integer alignment is smaller (AVR, spork8). The layouts of scalar types and the stack alignment that caps vector alignment come from `std.Target` of the Zig that zig-analyzer was built with and do not follow the user's zig (the stack alignments of those vector architectures are the same in both versions): with different versions they can disagree with the compiler on uncommon targets (C types and floats on sparc, xtensa, spirv64, amdgcn, avr and ez80, and types containing them). Builtin documentation: the links and notes name the user's version; the texts of the two versions are otherwise identical, so there is one generated table. Naming diagnostics link to the style guide of the user's version.
- Formatting uses the renderer of the user's zig, in process, and the parser of the standard library zig-analyzer is compiled with (see `docs/features/formatting.md`).
- With any other version, the build system is not started for roots with `build.zig`: no compiler diagnostics or named imports, only `zig ast-check` live diagnostics, and no single-file compiles there. The user is told at startup.
- Other files still compile in single-file mode; the `ErrorBundle` is validated as in `docs/diagnostics.md`, never read out of bounds, though contents may be garbled.
- Release versions follow Zig versions. The reported version comes from `git describe --tags`, falling back to `build.zig.zon`; `build.zig` is marked not cacheable because git's answer is outside the configure cache.

---

## Server and concurrency (`server/`)

### Write transactions

Writes (document sync, configuration, workspace and file events) run serially: register as waiting → wait for readers to exit → apply and advance the revision. No transaction is opened when inputs are unchanged, because an identical write would still cancel in-flight reads.

### Requests during project loading

Requests using name resolution are answered at once on what is known so far while the zig environment or a project's first load is pending; a hover says the project is still loading, and other answers may lack results.

With `sema.wait_for_project`, they are held until the load ends and every answer is complete; besides explicit cancellation and shutdown, only a change to the request's own document text ends the wait. While the configuration that starts projects is in flight they are held either way. A restart does not end a first load. Syntax features never wait.

### Read requests

Reads run concurrently on snapshots and are canceled by `$/cancelRequest` and writes. A request is answered on the state when it was received: when a later write interrupts it or its task starts reading after one, it gets `ContentModified`. The server's own updates (module graph, file list, live backend, files loaded from disk) are not ordered with requests: a request they interrupt runs again on the new state, as the text it refers to has not changed, so loading a project does not fail requests. Requests depending only on text are canceled only by text writes.

### Diagnostic publishing

Edit-triggered publishing is debounced per file; live diagnostics are computed outside read transactions. During a compile the previous results are kept, then replaced atomically; compile results are immutable and reference counted.

- The queue coalesces by file, and a file being computed is published once more after it finishes.
- A file's diagnostics may depend on other files' text, so other open files are recomputed when a document is edited, opened, or closed or a file changes on disk, and sent only when they differ.
- Edit-triggered publishes bypass the queue: each takes an increasing sequence number before reading state, and only results no older than the last sent are sent.

### Configuration

Options come from the client (`initializationOptions`, `workspace/configuration`), and a project-root `zig-analyzer.zon` can override project options; `src/server/Config.zig` describes each option. Pulled or pushed settings replace the current ones; a `null` section in a pull reply leaves them in effect.

### Exit

On `exit` and end of input, in-flight reads are canceled rather than awaited (`shutdown` still waits), then projects stop. When `initialize` gives a `processId`, the server also exits with the client, since stdin may be inherited and never closed; it uses pidfd, kqueue, or a process handle, and polls every 2 seconds only when none is available.

### External changes

The server registers `workspace/didChangeWatchedFiles` when the client supports it. With `files.watcher = auto`, it watches every file itself when the client cannot register or rejects the registration, and otherwise only files outside the workspace folders, which clients do not watch. `server` always watches on the server, and `client` never does. Clients report folder changes by the folder's path only, so such an event applies to every known file under it. When the server takes over watching, it compares known files with the disk once.

Files of interest are interned files, configure inputs, and root build files, excluding dependency libraries. Open documents are included: buffers win over disk, but builds read the disk.

**Unchanged contents are not a modification.** A build step that rewrites a source file unchanged would otherwise rebuild forever.

- Writing and republishing compares against the known text. A file nothing has read is not changed: FSEvents reports writes from just before the stream started, which would cancel requests in flight.
- Rebuilding compares against a hash of the disk contents at the last rebuild, because builds read the disk while the known text may come from elsewhere. The first unchanged rewrite therefore still rebuilds once.
- Root build files without a record compare with their contents just before the newest maker started, so such a late notification does not restart the project.

**Watching**: native notifications (inotify, FSEvents, Windows directory changes), batched by 50 ms of quiet, at most 500 ms. Missing directories are watched through their nearest ancestor. A reported name with files of interest under it is a directory, since Windows notifications do not distinguish them. Polling is the last resort, only for directories that cannot be watched natively, at intervals of at least 1 second and at least 20 times one check's duration.

**Known limitation**: on network file systems, `/mnt/c` in WSL2, and directories shared with containers or VMs, native watches succeed but miss remote changes, so there is no fallback to polling and these go unnoticed (as in rust-analyzer).

### Client capabilities

Results follow the capabilities: `rename.prepareSupport`, `codeActionLiteralSupport`, `hierarchicalDocumentSymbolSupport` (otherwise flat with `containerName`), `valueSet` (otherwise the closest initial kind), markdown support, and `labelOffsetSupport`.

### Observability

Slow requests are logged (`log.slow_request_ms`), and `-Dtracy=<dir>` enables tracy. Custom requests are prefixed with `zig-analyzer/`, with result fields in `server/Server.zig`: `status` (query execution counts, hit rates, time, and memory; InternPool and heap usage), `fileStatus`, `syntaxTree`, `moduleGraph`, `reloadWorkspace`, and `waitIdle` (returns once background tasks have finished; used by tests and benchmarks).

### Crashes

Zig has no unwinding, so a panic ends the process, after logging the message, thread context (the request, file, or build being handled, and the query stack), and call stack. Assumptions about input data use soft assertions (`util/assert.zig`) where degrading is possible: they panic in Debug and tests, and elsewhere log once and take the degraded path.

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
- The tests use the test runner bundled with Zig, patched by `tools/patch_test_runner.zig`: the testing allocator records 12 frames per allocation in every mode, so that leak reports have stack traces in ReleaseSafe too; tests that take 10 s or more are reported on stderr with their duration; and on aarch64 Darwin stack traces are unwound with frame pointers, because unwinding with the unwind info made stack capture most of the run time there (see `docs/zig-macos-stack-unwinding.md`).

Benchmark commands and current acceptance results: see `docs/perf.md`. The definition of diagnostic consistency and the diagnostic pipelines: see `docs/diagnostics.md`.
