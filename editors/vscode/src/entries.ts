/** A declaration that can be run: its name and the offset of its first token */
export interface Entry {
  name: string;
  offset: number;
}

/**
 * The named tests of a Zig file (`test "name" {` and `test name {`). A declaration is matched from
 * the start of its line, which leaves out the text of comments and multiline string literals:
 * their lines start with `//` and `\\`.
 */
export function tests(text: string): Entry[] {
  const re = /^([ \t]*)test[ \t]+(?:"((?:[^"\\\n]|\\.)*)"|([A-Za-z_][A-Za-z0-9_]*))[ \t]*\{/gm;
  const out: Entry[] = [];
  for (const m of text.matchAll(re)) out.push({ name: m[2] ?? m[3], offset: m.index + m[1].length });
  return out;
}

/** The `pub fn main` declarations of a Zig file */
export function mains(text: string): Entry[] {
  const re = /^([ \t]*)pub[ \t]+fn[ \t]+main[ \t]*\(/gm;
  const out: Entry[] = [];
  for (const m of text.matchAll(re)) out.push({ name: "main", offset: m.index + m[1].length });
  return out;
}
