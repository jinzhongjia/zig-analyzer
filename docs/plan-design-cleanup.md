# Plan: design cleanup

Structural problems found in a review of the server, the query registry, live diagnostics, and
formatting.

## 1. Live diagnostics query (`src/diagnostics/live.zig`) — done

- `live.Result.complete` is false for a check that could not run (zig cannot be started, exits
  with a code other than 0 or 1, is killed by a signal or by the 30 s watchdog, or no thread can be
  spawned for a deep file). `AstCheck` then calls `markIncomplete(.unavailable)`, so the result is
  not memoized and the next read runs the check again; `Prepared` does not keep such results.
- Text nested beyond `nesting.thread_depth` still gives a complete result without diagnostics.
- `AstCheck.eql` compares the diagnostics, so a recomputation that finds the same errors cuts off.
- `Watchdog.expired` tells whether the watchdog ended the child.
- Keeping `AstCheck` a query (with `Prepared`) is required: rename, code actions, and remove
  parameter read it inside read transactions.

## 2. Layer violation: `src/ide/project_config.zig` imported `src/server/Config.zig` — done

- `Config.zig` moved to `src/`, beside `database.zig`: its settings use types of `ide/` and
  `ide_db/`, so it cannot move below them. The CI path rule and the VS Code settings check follow
  the new path.

## 3. Split `Server` (`src/server/Server.zig`) — partly done

Done:

- `ClientCaps` (`src/server/ClientCaps.zig`): the capability flags read at `initialize`.
- `Refresh`: one implementation for the inlay hint and semantic token refreshes.
- `Documents`: open documents, versions, last URIs, real paths, virtual languages, with
  `docs.mutex`.
- `PublishQueue` and `Sent`: the publish queue and the last sent diagnostics, each with its mutex.

Open:

- Zig environment state (`zig_env`, `detected_env`, `envs`, `zig_environ`, `environ`,
  `default_builtin`): the fields are guarded by different means (`env_mutex`, atomics,
  `zig_paths_mutex`), so grouping them is only useful together with one locking rule for them.
- Single-file compiles (`single_mutex`, `single`), indexing and scanning generations.

## 4. Test hooks in `Server` — done

- `Server.hooks` (`TestHooks`) holds them; outside tests it is an empty struct and every use is
  behind `builtin.is_test`.

## 5. Configuration stored twice — not planned

The atomics (`slow_request_ms`, `max_intern_pool_mb`, `debounce_ms`, `callsite_seeding`,
`sub_projects_enabled`, `poll_interval_ms`) are lock-free reads of scalars on hot paths and in
places where `config_mutex` cannot be taken. An atomically swapped `*const Config` snapshot would
need reclamation of old snapshots while readers hold them, which costs more than the mirrors.

## 6. Formatter copies per zig patch version — not planned

Rendering in process with a copy per version, and parsing with the built-in parser, is the
documented trade-off in `docs/features/formatting.md`. `Renderer.built` failing to compile with a
zig that has no copy is what requires adding the copy for a new supported version.

## 7. Large files — not planned

Splitting `sema/eval.zig`, `sema/infer.zig`, and the large test files changes no behavior and
would need private declarations made `pub` across files; it is not worth the churn on its own.
