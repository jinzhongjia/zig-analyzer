# Editor test project

The project the editor smoke tests open (`editors/*/test`). Each test copies it to a temporary
directory, so builds and edits do not touch the repository. `src/lint.zig` is deliberately not
formatted and has an unused local constant: the tests check its diagnostic, the quick fix, and
formatting.
