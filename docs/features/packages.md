# Packages

The package view shows the `build.zig.zon` of each workspace root. The Neovim and Vim plugins open it with `:ZigAnalyzer packages`, the VS Code extension with **zig-analyzer: Show Packages**. The server answers the inspection request `zig-analyzer/packages` (no parameters); Zed has no view for it.

## Contents

For each workspace root with a `build.zig.zon`:

- the manifest path, name, version, fingerprint, minimum Zig version, and paths (a single empty path, which includes every file, is shown as every file);
- each entry of `.dependencies`: its name, kind (`url` or `path`), URL or path, hash, `lazy`, and the directory it resolves to (a `.path` against the project, or the package directory entry of a `.hash`), whether that directory exists, and its `build.zig.zon` and `build.zig` when present.

The manifest text is the open buffer when the file is open, the file on disk otherwise. A manifest that does not parse is shown with the error; the rest of the projects still load. Name resolution of the dependencies is not part of the view: it is the module graph the project loaded.

## Following lines

`<CR>` on a project or a dependency opens its `build.zig.zon`, or the dependency's `build.zig`, or its directory when it has neither. Nothing is edited: dependency changes stay ordinary text edits, and the hash of a URL dependency is fetched by the code action in [`code-actions.md`](code-actions.md#dependency-hashes-in-buildzigzon).

## Data

The inspection request returns:

```json
{
  "projects": [{
    "root": "/work/app",
    "manifest": "/work/app/build.zig.zon",
    "name": "app",
    "version": "0.1.0",
    "fingerprint": "0x...",
    "minimum_zig_version": "0.17.0",
    "paths": ["src"],
    "dependencies": [{
      "name": "lib",
      "kind": "url",
      "url": "https://example.com/lib.tar.gz",
      "path": null,
      "hash": "lib-0.1.0-AAAA",
      "lazy": null,
      "root": "/work/app/zig-pkg/lib-0.1.0-AAAA",
      "exists": true,
      "manifest": "/work/app/zig-pkg/lib-0.1.0-AAAA/build.zig.zon",
      "build_zig": "/work/app/zig-pkg/lib-0.1.0-AAAA/build.zig"
    }],
    "parse_error": null
  }]
}
```

`kind` is `url`, `path`, or `none`. `paths` containing one empty string means the package includes every file. `exists` is whether the resolved directory exists; for a URL dependency whose hash is missing, `root` is null and `exists` false. Optional fields are absent when they have no value.
