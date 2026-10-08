# Loose Threads

> Why write a blog post when you can spend three weeks building the thing that renders it?

A personal programming blog and a single-threaded static-site generator built in **Zig 0.17.0**, with vendored Tree-sitter for Zig syntax highlighting.

Posts live in `markdown/`, templates in `templates/`, and assets in `static/`. Generated HTML goes to `public/` for deployment to Cloudflare Pages.

### Styles

`static/style.css` is the stylesheet entry point. It imports these plain CSS modules in order:

- `base.css`: theme variables, resets, and global typography.
- `layout.css`: shared page layout, header, navigation, and footer.
- `home.css`: homepage intro, post timeline, and about section.
- `article.css`: article typography, table of contents, and content elements.
- `callouts.css`: quotes and alert callouts.
- `code.css`: inline code, fenced code blocks, and syntax highlighting.
- `responsive.css`: mobile and reduced-motion overrides.

Edit the source files in `static/`, not generated files in `public/`. Keep the responsive imports last and CSS filenames unique: the asset copier copies files into `public/` using their basenames.

## Build and run

```sh
zig build
zig build test
./zig-out/bin/blog-generator
```

Run from the repository root. Generation **deletes and recreates `public/`**.

The build fetches the pinned official `translate-c` package (from its Zig 0.17-compatible branch) to generate Zig bindings from Tree-sitter's C header. Tree-sitter and the Zig grammar remain vendored and are compiled as C; `src/highlight.zig` imports the generated `tree_sitter` module instead of using the removed `@cImport` builtin.

Optional: `zig build format-html` formats existing output (requires Prettier).

## Post format

```markdown
---
name: Hello World
description: Learning Zig by building a blog.
slug: hello-world
date: 2026-10-01
---

# Hello World

Welcome to my blog.
```

Metadata is project-specific, not full YAML. Dates are optional; `timestamp` (Unix seconds, UTC) takes precedence. Posts are listed newest first. Fenced Zig code blocks are syntax-highlighted; other languages render as plain text.
