# Writing the OpenArch docs

The site at docs.openarch.app is built from `src/content/docs/` with
[Starlight](https://starlight.astro.build). Every page is Markdown; the
sidebar's order is set in `astro.config.mjs`.

```sh
cd docs-site
nvm use            # Node 24 (.nvmrc); Astro needs 22.23 or newer
npm install
npm run dev        # http://localhost:4321, reloads as you write
npm run build      # dist/, as deployed
```

## How the pages read

- **English, to the reader, in the present tense.** "Press ⌘T and type…",
  not "The user can press…". Short sentences, one idea each.
- **Say what it does, then how to use it, then the details.** Every page
  opens with one or two sentences on what the feature is and why you would
  use it. Then the steps. Then settings, limits and what to know.
- **Only what OpenArch does today.** Every claim is checked against the
  code. No plans, no "coming soon", no guesses. If something is unclear,
  leave it out.
- **No marketing.** No "powerful", "seamless", "simply". Arc may be named
  where OpenArch does something the way Arc did, since many readers come
  from it.

## OpenArch's own words

OpenArch's menus and settings are in German. Write them exactly as the app
shows them, in bold, with the path joined by ›:

- **Settings › Allgemein › Sidebar** (the settings window is ⌘, — call it
  Settings, then the German tab and section names)
- **Ablage › Geschlossenes Fenster wieder öffnen** (menu bar menus)
- the command bar's commands in quotes: "Tabs mit KI aufräumen"

The first time a German label is not self-explanatory on a page, add the
English in parentheses: **Ansicht** (View).

Keys: `<kbd>⌘T</kbd>`, one `<kbd>` per shortcut. Modifiers in the order macOS menus
show them, ⌃ ⌥ ⇧ ⌘: `<kbd>⇧⌘T</kbd>`, not ⌘⇧T.

## Markdown

- Frontmatter: `title` (quoted) and a one-sentence `description`.
- Headings start at `##`; the title is the page's `#`.
- Asides for what must not be missed:
  `:::tip`, `:::note`, `:::caution` … `:::`.
- Links to other pages are absolute paths with a trailing slash:
  `[spaces](/sidebar/spaces/)`.
- Tables for lists of shortcuts or settings, prose for everything else.
