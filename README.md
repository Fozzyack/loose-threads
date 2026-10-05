# Loose Threads

> Why write a blog post when you can spend three weeks building the thing that renders it?

A personal programming blog and a single-threaded static-site generator built in **Zig 0.16.0**, with vendored Tree-sitter for Zig syntax highlighting.

Posts live in `markdown/`, templates in `templates/`, and assets in `static/`. Generated HTML goes to `public/` for deployment to Cloudflare Pages.

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

Metadata is project-specific, not full YAML. Dates are optional; `timestamp` (Unix seconds, UTC) takes precedence. Posts are listed newest first. Fenced Zig code blocks are syntax-highlighted; other languages render as plain text.
