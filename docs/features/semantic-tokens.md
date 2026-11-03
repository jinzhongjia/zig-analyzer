# Semantic tokens

Semantic tokens combine CST classification with per-member name resolution and type inference. Code that cannot be resolved keeps its syntactic classification. The kinds of declarations come from `ide_db/symbol_kind.zig`, shared with completion items.

- **Classification**: kinds are distinguished by actual types and bindings, never guessed from names or call syntax. Quoted identifiers follow lexical scoping; bare builtin names and `_` keep their language semantics.
- **Error tolerance**: at each token, an instance under which it resolves is chosen. Inference under an instance happens only where classification may vary between instances, so functions, methods, namespaces, and type parameters look up no call sites.
- **Unused bindings**: `unused` is added only to parameters of functions with a body, local variables, and captures, counted by binding identity. It changes highlighting only and produces no diagnostic.
- **Partial mode** (`semantic_tokens.mode = .partial`): tokens decidable without analysis are left to the editor's syntax highlighting. Every token sent is identical to the same token in full mode.
- **Global variables** (`semantic_tokens.global_var`): container-level `var`s are marked `global`. The modifier is appended to the legend, so existing indices do not change.
- **Encoding and ranges**: tokens use the negotiated encoding and are sorted, single-line, and non-overlapping. Range requests clip the analysis, but keep references outside the range that affect `unused`.
- **Incremental updates**: a delta is one replacement between the common prefix and suffix, and the full result when no baseline exists. Only the latest snapshot per open document is cached (at most 128 documents and 16 MiB).
- **Refresh**: changes to semantic dependencies trigger a coalesced refresh when supported. After one is sent, earlier results no longer serve as delta baselines.
