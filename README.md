# A blog built with Zig

A personal blog and a learning project: build a small static-site generator in Zig, then publish its output with Cloudflare Pages.

The generator reads Markdown posts, renders them into HTML templates, and writes a complete website to an output directory. Visitors receive those generated files directly from the hosting platform. Zig runs when the site is built, not when someone visits it.

## Project status

Under active development, still early. What works today:

- `zig build` compiles `src/main.zig` into `blog-generator` and installs it at `zig-out/bin/blog-generator`.
- Running the binary deletes and recreates `public/`, copies the stylesheet from `static/`, then reads every `.md` file under `markdown/`.
- The reader splits each file on newlines and converts `#`–`#####` headings and paragraphs into HTML fragments.
- Unit tests cover the `Entry` type and heading/paragraph parsing (`zig test src/main.zig`).

Not implemented yet: the `title`/`date` metadata header, HTML escaping, template substitution, generating post pages and a homepage, and writing HTML files into `public/`. At the moment the parsed HTML is printed to the terminal instead of being written to disk.

## Goals

- Learn Zig through file I/O, memory allocation, parsing, and error handling.
- Build a single-threaded, dependency-free static-site generator.
- Write posts in Markdown with a small title-and-date metadata header.
- Generate individual post pages and a homepage sorted by date.
- Use shared HTML templates and a responsive stylesheet.
- Deploy the generated files to Cloudflare Pages.

## How it works

The intended pipeline:

```text
Markdown posts + HTML templates + static assets
                       |
                 Zig generator
                       |
                       v
                    public/
                       |
              Cloudflare Pages
                       |
                       v
                Visitor's browser
```

The generator will:

1. Discover and read posts from `markdown/`.
2. Parse each post's metadata and Markdown body.
3. Convert supported Markdown into HTML.
4. Insert the title and rendered body into a shared page template.
5. Generate post pages and a homepage linking to them.
6. Copy static assets into `public/`.

Plain-text values such as titles must be HTML-escaped. HTML tags should be produced deliberately by the Markdown renderer. Invalid posts should produce useful errors identifying the source file.

## Project structure

```text
blog/
├── build.zig              # Build configuration
├── src/
│   └── main.zig           # Generator entry point and Markdown parser
├── markdown/
│   └── hello_world.md     # Blog posts
├── templates/
│   ├── index.html         # Homepage layout
│   └── page.html          # Post page layout
├── static/
│   └── style.css          # Stylesheet and other assets
├── goal/                  # Hand-written reference for the finished site
└── public/                # Generated output (git-ignored)
```

`markdown/`, `templates/`, and `static/` are source inputs. Treat `public/` as generated output: edit the inputs and rebuild rather than editing generated pages. The `goal/` directory holds a static, hand-written version of the pages the generator is meant to produce.

## Toolchain

This project targets **Zig 0.16.0**.

Check your installed version with:

```sh
zig version
```

## Build and run

From the project root:

```sh
zig build
./zig-out/bin/blog-generator
```

`zig build` builds and installs `blog-generator`. Running that binary regenerates `public/` and currently prints the parsed HTML to the terminal.

Run the unit tests with:

```sh
zig test src/main.zig
```

`zig build --help` lists the available steps; only `install` and `uninstall` exist. There is no `zig build generate` step yet.

## Post format

The current parser works line by line: a line of `#`–`#####` followed by a space becomes an `<h1>`–`<h5>`, any other non-empty line becomes a `<p>`, and blank lines are skipped.

Posts will eventually carry a small metadata header followed by Markdown:

```markdown
---
title: Hello World
date: 2026-10-01
---

# My first post

This blog is generated using Zig.
```

The first version will require `title` and `date`, using `YYYY-MM-DD` dates. This header is a project-specific format, not a full YAML implementation, and is not parsed yet.

The Markdown subset so far covers headings and paragraphs. Lists, links, and fenced code blocks can be added in later milestones.

## Templates

`templates/index.html` and `templates/page.html` are hand-written layouts. Template substitution is planned but not wired up: the generator will replace placeholders such as `{{title}}` with escaped text and `{{content}}` with rendered HTML.

## Deployment to Cloudflare Pages

The simplest initial workflow is to build locally and upload the generated output:

1. Run the generator after adding or editing posts.
2. Create a Cloudflare Pages project using Direct Upload.
3. Upload the contents of `public/` through the dashboard or deploy that directory with the Wrangler CLI.
4. Verify the site using its assigned `pages.dev` address.
5. Add your domain or subdomain through the project's **Custom domains** settings and follow the DNS setup instructions.

Add the custom domain through Pages before configuring DNS manually so that Cloudflare can associate the hostname with the project and set up HTTPS.

Only the generated site needs to be deployed. Cloudflare serves the files and handles HTTPS; it does not need to run Zig or a custom web server.

Later, a CI workflow can build and deploy the site automatically when posts are pushed to Git. Choose Direct Upload or Git integration intentionally when creating the Pages project; switching between those project types may require creating a new project.

## Implementation milestones

1. **Generate one page:** create the Zig build configuration and write a basic HTML file. *Build configuration done; no HTML is written yet.*
2. **Read a post:** load a Markdown file and parse its title and date. *Reading and line parsing done; title/date metadata not yet.*
3. **Render content:** implement headings, paragraphs, HTML escaping, and template substitution. *Headings and paragraphs done; escaping and substitution not yet.*
4. **Assemble the blog:** discover posts, generate individual pages, sort the homepage by date, and copy assets. *Asset copying done; pages and homepage not yet.*
5. **Publish:** verify the generated site and deploy it to Cloudflare Pages.
6. **Expand:** add more Markdown features, an RSS feed, and automated deployment.
