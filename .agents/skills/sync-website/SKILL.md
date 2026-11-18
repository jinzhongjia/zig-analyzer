---
name: sync-website
description: Bring the zig-analyzer.dev website (website/index.html) in line with the repository after a user-visible change - a new or renamed editor plugin, an install channel added or removed, a new supported Zig version, or a feature worth listing. Use when asked to update the website, or after such a change lands in README.md, docs/editors.md, or editors/*.
---

# Sync the website with the repository

The website is one static page, `website/index.html` (with `style.css` and `main.js`), deployed to
zig-analyzer.dev by `.github/workflows/website.yml`: a pull request that touches `website/**`
gets a preview URL (`pr-<number>-zig-analyzer` on workers.dev), and the push to `main` deploys
production. There is no build step and no generator: every fact on the page is written by hand
and copied from a source in the repository, so it goes stale when that source changes.

## 1. Facts on the page and their sources

| Page section | Fact | Source of truth |
| --- | --- | --- |
| `<head>` meta, hero `.lead` | One-line description | `README.md` intro |
| Hero `.eyebrow` | Supported Zig version (`For Zig 0.17`) | `build.zig.zon` `minimum_zig_version`, README "Development" |
| Hero `.cmd`, `#install` tabs | Install commands and channels (Homebrew, AUR, Scoop, archive, source) | README "Installation" |
| `#install` source tab | Accepted Zig versions | README "Installation" and "Development" |
| `#features` cards | Feature summary | `README.md` "Features", `docs/features/*.md` |
| `#editors` cards | Editors with an own plugin or extension, their link and minimum version | README "Editor support", `editors/*/README.md`, `.github/workflows/mirror.yml` (mirror repositories) |
| `#editors` "Other editors" card | Editors set up by configuration only | README "Editor support", `docs/editors.md` headings |
| `#editors` `.section-lead` | What the plugins do for the server (install, signature check) | `editors/*/README.md` |

## 2. Find what changed

Find the last website change and read what changed in the sources since then:

```sh
last=$(git log -1 --format=%H -- website)
git log --oneline "$last"..HEAD -- README.md docs/editors.md docs/features editors build.zig.zon .github/workflows/mirror.yml
git diff "$last"..HEAD -- README.md
```

Compare every row of the table above against the page, not only the rows the log points at.

## 3. Edit

- Keep the page's wording style: short sentences, no marketing language, facts the README also
  states. Never state on the page what the repository does not.
- Editor cards: the heading is the editor name with its minimum version when the plugin has one
  (`Neovim 0.12+`, `Emacs 29.1+`); the link is the plugin's own repository when it has a mirror
  (`mirror.yml`), otherwise the `editors/<name>` directory; the text names the package and the
  LSP client it uses. An editor that gains its own plugin moves out of the "Other editors" card.
- Grids: `.grid` has 3 columns (2 below 960px, 1 below 640px). Keep the editor cards a multiple
  of 3 where possible (the "Other editors" card fills a row); otherwise check the last row looks
  intentional.
- Install tabs: each tab is a `button[role=tab]` plus a `.panel` with matching `id` /
  `aria-controls` / `aria-labelledby`; only the first panel lacks `hidden`. `main.js` handles the
  tabs and the copy buttons: the `data-copy` attribute is the copied text (`&#10;` for newlines),
  separate from the displayed `<code>`, so update both.
- The Chinese README is not mirrored on the site; the site is English only.

## 4. Check

Render the page and look at it (light and dark if colors changed, and a narrow width if a grid
changed):

```sh
mkdir -p /tmp/za-site
google-chrome-stable --headless --disable-gpu --window-size=1280,3400 \
  --screenshot=/tmp/za-site/wide.png "file://$PWD/website/index.html"
google-chrome-stable --headless --disable-gpu --window-size=600,5000 \
  --screenshot=/tmp/za-site/narrow.png "file://$PWD/website/index.html"
```

Read the screenshots. Check every changed link resolves (`curl -sI <url> | head -n 1`).

## 5. Commit and pull request

Commit the website change on its own (`website: ...`), apart from the change it follows. The pull
request gets the `internal` label unless the user says otherwise; ask before pushing and opening
it. After the website workflow uploads the preview, give the user the preview URL from the
pull request's `website-preview` deployment.
