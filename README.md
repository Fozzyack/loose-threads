# Loose Threads

> Why write a blog post when you can spend three weeks building the thing that renders it?

A personal programming blog and a static-site generator built in **Zig 0.17.0**, with parallel Markdown parsing and vendored Tree-sitter for syntax highlighting.

Posts live in `markdown/`, templates in `templates/`, and assets in `static/`. Generated HTML goes to `public/` for deployment to Cloudflare Pages.

## Generation

The generator recursively finds `.md` files in `markdown/` and parses them in batches of up to **16 threads**. It waits for each batch before starting the next, so 16 is a concurrency limit, not a limit on the number of posts. Shared entry appends are mutex-protected, and the executable uses Zig's thread-safe `std.heap.smp_allocator`.

After parsing finishes, it renders the homepage and individual post pages sequentially. The homepage lists dated posts newest first, undated posts last, and ties by slug. Give each post a unique slug: pages are written as `{slug}.html`, and existing output files are not overwritten by post generation.

### Styles

`static/style.css` is the stylesheet entry point. It imports these plain CSS modules in order:

- `base.css`: theme variables, resets, and global typography.
- `layout.css`: shared page layout, header, navigation, and footer.
- `home.css`: homepage intro and post timeline.
- `article.css`: article typography, table of contents, and content elements.
- `callouts.css`: quotes and alert callouts.
- `code.css`: inline code, fenced code blocks, and syntax highlighting.
- `responsive.css`: mobile and reduced-motion overrides.

Edit the source files in `static/`, not generated files in `public/`. Keep `responsive.css` last so its overrides win.

### Assets

Assets are copied recursively into `public/`, flattening directory paths to basenames:

- From `static/`: `.css`, `.js`, `.png`, `.jpg`, `.jpeg`, `.svg`, and `.gif`.
- From `markdown/`: `.png`, `.jpg`, `.jpeg`, `.svg`, and `.gif`.

Keep asset basenames unique across both trees to avoid collisions. Reference copied images by their output basename, for example `![Diagram](./diagram.png)`. Other extensions are not copied.

## Build and run

```sh
git submodule update --init --recursive
zig build
zig build test
./zig-out/bin/blog-generator
```

Run from the repository root. Generation **deletes and recreates `public/`**.

The build fetches the pinned official `translate-c` package (from its Zig 0.17-compatible branch) to generate Zig bindings from Tree-sitter's C header. Tree-sitter and the Zig, Python, C, JSON, and Bash grammars remain vendored and are compiled as C, including external scanners where needed; `src/highlight.zig` imports the generated `tree_sitter` module instead of using the removed `@cImport` builtin. Initialize the vendored submodules with `git submodule update --init --recursive` after cloning.

Optional HTML formatting requires `prettier` on `PATH`:

```sh
./zig-out/bin/blog-generator --format # Generate, then format (-f also works).
zig build format-html               # Format existing output only.
```

Both use `.prettierignore` so the gitignored `public/` directory is still formatted. For scanner or ABI changes, also run `zig build test -Doptimize=ReleaseSafe`.

## Post format

```markdown
---
name: Hello World
description: Learning Zig by building a blog.
slug: hello-world
date: 2026-10-01
toc: true
---

# Hello World

Welcome to my blog.
```

Metadata is project-specific, not full YAML. Use `---` delimiters on their own lines with LF (`\n`) line endings. Only `name`, `description`, `slug`, `date`, `timestamp`, and `toc` are accepted; unknown keys fail parsing.

- `date` is optional and uses `YYYY-MM-DD`.
- `timestamp` is optional Unix seconds in UTC and takes precedence over `date`.
- `toc: true` enables a table of contents linking to generated heading anchors.

Local posts in `markdown/` are gitignored; only the placeholder `markdown/markdown_files_here` is tracked. Parser integration tests create temporary Markdown files rather than relying on local posts.

### Syntax highlighting

Fenced code blocks labeled `zig`, `python`, `c`, `json`, `sh`, or `bash` are syntax-highlighted (`sh` and `bash` use the same Bash grammar). Labels are case-sensitive; unknown or omitted languages render as plain text. Code always escapes HTML characters and preserves whitespace. Python f-strings and Bash strings containing substitutions retain whole-string coloring rather than nested token spans.
