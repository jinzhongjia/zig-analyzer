#!/usr/bin/env bash
# Adds the section of a new version to CHANGELOG.md, from the pull requests merged into HEAD since
# the last release tag.
#
# Usage: tools/changelog.sh <version>    (e.g. 0.2.0 or 0.2.0-rc.1, without the `v`)
#
# Each pull request is one line, `- <title> (#<number>)`, under the section its labels select:
# `breaking`, `enhancement`, `bug`, `performance`; one with `internal` is left out, and one with none
# of these goes under "Other changes". The titles are the starting point: edit the lines into
# user-facing text before committing. Needs git and an authenticated gh.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <version>" >&2
  exit 2
fi
version=$1
cd "$(git rev-parse --show-toplevel)"
file=CHANGELOG.md
repo_url=$(gh repo view --json url -q .url)

if grep -qF "## [$version](" "$file"; then
  echo "error: $file already has a section for $version" >&2
  exit 1
fi

# The previous release; without one, the whole history
if prev=$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null); then
  range="$prev..HEAD"
else
  range=HEAD
fi

# Merge commits on the first-parent chain name their pull requests
numbers=$(git log --first-parent --format=%s "$range" | sed -n -E 's/^Merge pull request #([0-9]+) .*/\1/p; s/.*\(#([0-9]+)\)$/\1/p')

breaking='' features='' fixes='' performance='' other=''
for n in $numbers; do
  IFS=$'\t' read -r title labels < <(gh pr view "$n" --json title,labels -q '[.title, ([.labels[].name] | join(","))] | @tsv')
  line="- $title ([#$n]($repo_url/pull/$n))"$'\n'
  case ",$labels," in
    *,internal,*) ;;
    *,breaking,*) breaking+=$line ;;
    *,enhancement,*) features+=$line ;;
    *,bug,*) fixes+=$line ;;
    *,performance,*) performance+=$line ;;
    *) other+=$line ;;
  esac
done

section="## [$version]($repo_url/releases/tag/v$version) - $(date -u +%Y-%m-%d)"$'\n'
for pair in "Breaking changes:$breaking" "Features:$features" "Fixes:$fixes" "Performance:$performance" "Other changes:$other"; do
  heading=${pair%%:*}
  items=${pair#*:}
  if [ -n "$items" ]; then section+=$'\n'"### $heading"$'\n\n'"$items"; fi
done

# The new section goes before the first version section, after the introduction
tmp=$(mktemp)
SECTION=$section awk '
  !done && /^## \[/ { print ENVIRON["SECTION"]; done = 1 }
  { print }
  END { if (!done) { print ""; print ENVIRON["SECTION"] } }
' "$file" > "$tmp"
mv "$tmp" "$file"
echo "added the section of $version to $file ($(echo "$numbers" | grep -c . || true) pull requests since ${prev:-the first commit})"
