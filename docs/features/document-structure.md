# Folding, selection ranges, and document symbols

All three are computed from the syntax tree only.

## Selection ranges

A selection range at the boundary of two tokens starts from the left one when it is a word (name, keyword, literal) and the right one is not, or when the right one is whitespace or a comment.

## Document symbols

In the outline:

- The children of a declaration are the members of the container it declares (`const S = struct {...}`, a field's struct type, a struct a function returns), not of containers only lexically inside it (local types, call arguments, `?struct {...}`).
- Tuple fields are named by their index (`0`, `1`, as in `t.@"0"`).
- Names that are empty or only whitespace keep their quoted form (`@" "`, `test ""` as `""`).
- Declarations without a name are not listed.
- The outline of a ZON file is the field tree of its root expression (named fields are listed by name and tuple elements by index; the fields of a value that is an initializer list are child symbols).
