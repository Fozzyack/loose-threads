# A blog built with Zig

A learning project: a single-threaded, dependency-free static-site generator built with **Zig 0.16.0**, intended for Cloudflare Pages.

## Current status

- Reads posts from `markdown/` and renders basic headings and paragraphs.
- Uses `templates/` to generate a homepage and a `{slug}.html` page per post.
- Displays dates, preferring UTC timestamps, and copies CSS from `static/`.

## Build and run

From the repository root:

```sh
zig build
./zig-out/bin/blog-generator
```

The executable is built into `zig-out/bin/`. Running it **deletes and recreates `public/`**, the generated site directory.

Optionally format generated HTML (requires `prettier` on your `PATH`):

```sh
zig build format-html
```

Formatting updates existing files only; it does not build or generate the site.

## Post format

```markdown
---
name: Hello World
description: Learning Zig by building a blog.
slug: hello-world
date: 2026-10-01
timestamp: 1790858096
---

# Hello World

Welcome to my blog.
```

Metadata is project-specific, not full YAML. Keep `---` delimiters on their own lines and end body lines with newlines. Dates and timestamps are optional; timestamps use Unix seconds and take precedence over dates.

## Tests

```sh
zig test src/entries.zig
zig test src/parser.zig
zig test src/templates.zig --test-filter create_homepage_post
```

## Next steps

Date sorting, richer Markdown support, complete HTML escaping, and Cloudflare Pages deployment.
