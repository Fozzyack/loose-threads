# Loose Threads

> This has become a big markdown -> html translator

A personal programming blog, built with a single-threaded, dependency-free static-site generator in **Zig 0.16.0**.

Posts live in `markdown/`, HTML templates in `templates/`, and CSS, JavaScript, and images in `static/`. The generator writes everything to `public/` for static hosting such as Cloudflare Pages. The homepage includes a compact thread timeline with a looping light, pause control, and reduced-motion support.

## Build and run

```sh
zig build
./zig-out/bin/blog-generator
```

Run from the repository root. Generation **deletes and recreates `public/`**.

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

Metadata is project-specific, not full YAML. Dates are optional; an optional `timestamp` (Unix seconds, UTC) takes precedence. Posts are listed newest first. Markdown support is basic, including fenced code blocks styled with `.code-section`.

Planned: build-time syntax highlighting using Tree-sitter, with language-specific grammars and CSS token colors.

## Tests

```sh
zig test src/entries.zig
zig test src/parser.zig
zig test src/templates.zig --test-filter create_homepage_post
zig test src/templates.zig --test-filter render_post_page
```
