# A blog built with Zig

A personal blog and a learning project: a single-threaded, dependency-free static-site generator built with **Zig 0.16.0**. The goal is to publish generated files through Cloudflare Pages.

## Current status

- Reads `.md` posts from `markdown/` and parses their metadata.
- Renders headings (`#`–`#####`) and paragraphs, skipping blank lines.
- Stores dates and Unix timestamps, rendering one date paragraph with UTC date and time when a timestamp is present.
- Recreates `public/`, copies CSS from `static/`, and prints parsed posts to the terminal.

HTML page generation and template substitution are still in progress. `goal/` contains the hand-written reference site.

## Build and run

From the repository root:

```sh
zig build
./zig-out/bin/blog-generator
```

Running the generator deletes and recreates `public/`; treat it as disposable output. There is no `zig build run` or `zig build generate` step yet.

Run the metadata tests:

```sh
zig test src/entries.zig --test-filter parse_metadata
```

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

The header is a small project-specific `key: value` format, not full YAML. Keys can appear in any order; surrounding spaces are trimmed from values. Use newline-terminated lines and `---` delimiters on their own lines.

`date` accepts valid `YYYY-MM-DD` dates. `timestamp` accepts Unix **seconds**, from 1970 through 9999, and is stored as a number. Both are optional: when both are present, the timestamp takes precedence for display, producing a single paragraph such as **October 1, 2026 at 12:34:56 UTC**. Without a timestamp, the date is displayed on its own.

## Next steps

- HTML escaping and template substitution.
- Individual post pages and a homepage sorted by date.
- More Markdown features and deployment to Cloudflare Pages.
