# Folding, selection ranges, and document symbols

Folding and selection ranges are computed from the syntax tree only. Document symbols are computed from the syntax tree, with the kinds of functions and of constants and variables whose value is a function taken from the inferred type.

## Selection ranges

A selection range at the boundary of two tokens starts from the left one when it is a word (name, keyword, literal) and the right one is not, or when the right one is whitespace or a comment.

## Document symbols

In the outline:

- The children of a declaration are the members of the container it declares (`const S = struct {...}`, a field's struct type, a struct a function returns), not of containers only lexically inside it (local types, call arguments, `?struct {...}`).
- A function is a method when its first parameter is the container it is declared in or a single-item pointer to it, and a function otherwise; this is the same classification as semantic highlighting. A `const` or `var` whose inferred value is a function is shown as a function. Other kinds follow the syntax: a `const` that declares a struct, enum, union or opaque type is shown as that type, a `const` that declares no container is a constant, and a `var` is a variable. Without type information (the ZON outline, or a caller that has none), a function is a function at file level and a method in any other container.
- Tuple fields are named by their index (`0`, `1`, as in `t.@"0"`).
- Names that are empty or only whitespace keep their quoted form (`@" "`, `test ""` as `""`).
- Declarations without a name are not listed.
- The outline of a ZON file is the field tree of its root expression (named fields are listed by name and tuple elements by index; the fields of a value that is an initializer list are child symbols).
