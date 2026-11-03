# Semantic tokens

Semantic tokens combine CST classification with per-member name resolution and type inference. References and declarations share type, binding, and member information, and code that cannot be resolved keeps its syntactic classification. The kinds of declarations come from `ide_db/symbol_kind.zig`, shared with the kinds of completion items.

## Classification

- Types, namespaces, variables, functions, methods, and members are distinguished by their actual types and bindings, not guessed from names.
- The abstract classification of a declaration is cached separately; declarations of and references to type aliases are refined by the instance at the current position, without writing back across instances.
- Quoted identifiers follow lexical scoping; bare builtin names and `_` keep their language semantics.

## Error tolerance

- Each member's candidate instances and the per-iteration results of loops are reused, and at each token position an instance under which the token resolves is chosen.
- The search is bounded: a token that cannot be resolved keeps its syntactic highlighting, and functions are not guessed from call syntax.
- Inference under an instance happens only at positions whose classification may vary between instances: references to declarations classified as variables or types, local bindings (except type parameters), and member accesses where abstract inference cannot find the member; functions, methods, namespaces, and type parameters are classified the same under every instance, so no call sites are looked up for them.

## Unused bindings

- Lexical references are counted by binding identity, and `unused` is added only to parameters of functions with a body, local variables, and captures.
- Writes, asm outputs, and explicit discards count as uses; top-level declarations and container members are not judged from local references.
- This changes only the highlighting and produces no diagnostic; Neovim uses the theme's dimmed `DiagnosticUnnecessary` color for it.

## Partial mode (`semantic_tokens.mode = .partial`)

- Tokens whose classification can be determined without name resolution or type inference (keywords, comments, literals, operators, labels, and builtin names with `defaultLibrary` such as `@import`, `u32`, and `true`) are not sent and are left to the editor's syntax highlighting.
- Tokens are filtered by their classification results; the analysis is the same as in full mode, and every token sent is identical to the same token in full mode.
- Full, delta, and range requests all follow the current configuration, and the client is asked to refresh when the configuration changes.

## Global variables (`semantic_tokens.global_var`)

Declarations of and references to container-level `var`s (names, member accesses, references in other files) are marked `global`; container-level consts, fields, and local variables are not. The new modifier is appended to the end of the legend, and the indices of existing token types and modifiers do not change.

## Encoding and ranges

- Tokens use the negotiated position encoding and are emitted sorted, single-line, and non-overlapping.
- An empty range returns immediately; otherwise the CST and the owner analysis are clipped to the range, while lexical references outside the range that affect `unused` are still kept.
- Whole tokens that intersect the range are returned, with positions relative to the start of the document.

## Incremental updates and caching

- Full, delta, and range requests are supported.
- A delta computes the common prefix and suffix in whole tokens and is expressed as one replacement of the part between them; it returns empty edits when nothing changed, and the full result when the baseline is unavailable.
- Only the latest snapshot of each open document is cached, for at most 128 documents and 16 MiB; closing a document frees its snapshot, reopening it isolates the old session, and range requests do not modify the snapshot.

## Refresh

When the client supports refresh, changes to semantic dependencies trigger a coalesced refresh request. After a refresh is sent, earlier results no longer serve as delta baselines, and the next delta request of each document returns the full result.
