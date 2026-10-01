# A blog built with Zig

A personal blog and a learning project: build a small static-site generator in Zig, then publish its output with Cloudflare Pages.

The generator reads Markdown posts, renders them into HTML templates, and writes a complete website to an output directory. Visitors receive those generated files directly from the hosting platform. Zig runs when the site is built, not when someone visits it.

## Project status

This project is at the planning stage. The generator, build configuration, templates, and sample posts have not been implemented yet. The structure and commands below describe the intended first version.

## Goals

- Learn Zig through file I/O, memory allocation, parsing, and error handling.
- Build a single-threaded, dependency-free static-site generator.
- Write posts in Markdown with a small title-and-date metadata header.
- Generate individual post pages and a homepage sorted by date.
- Use shared HTML templates and a responsive stylesheet.
- Deploy the generated files to Cloudflare Pages.

## How it works

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

1. Discover and read posts from `content/`.
2. Parse each post's metadata and Markdown body.
3. Convert supported Markdown into HTML.
4. Insert the title and rendered body into a shared page template.
5. Generate post pages and a homepage linking to them.
6. Copy static assets into `public/`.

Plain-text values such as titles must be HTML-escaped. HTML tags should be produced deliberately by the Markdown renderer. Invalid posts should produce useful errors identifying the source file.

## Planned structure

```text
blog/
├── build.zig              # Build configuration and generation command
├── src/
│   └── main.zig           # Generator entry point
├── content/
│   └── hello-world.md     # Blog posts
├── templates/
│   └── page.html          # Shared page layout
├── static/
│   └── style.css          # Styles and other assets
└── public/                # Generated site, ready to upload
```

`content/`, `templates/`, and `static/` are source inputs. Treat `public/` as generated output: edit the inputs and rebuild rather than editing generated pages.

## Toolchain

The initial implementation will target **Zig 0.16.0**, the version installed when the project was started.

Check your installed version with:

```sh
zig version
```

## Planned build command

Once the generator and build configuration are implemented, run this from the project root:

```sh
zig build generate
```

The command will generate the site in `public/`. This command is not available yet.

## Post format

Posts will use a small metadata header followed by Markdown:

```markdown
---
title: Hello World
date: 2026-10-01
---

# My first post

This blog is generated using Zig.
```

The first version will require `title` and `date`, using `YYYY-MM-DD` dates. This header is a project-specific format, not a full YAML implementation.

The initial Markdown subset will support headings and paragraphs. Lists, links, and fenced code blocks can be added in later milestones.

## Templates

A page template will contain placeholders for the post title and rendered content:

```html
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{{title}}</title>
    <link rel="stylesheet" href="/style.css">
</head>
<body>
    <main>{{content}}</main>
</body>
</html>
```

The generator will replace `{{title}}` with escaped text and `{{content}}` with rendered HTML.

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

1. **Generate one page:** create the Zig build configuration and write a basic HTML file.
2. **Read a post:** load a Markdown file and parse its title and date.
3. **Render content:** implement headings, paragraphs, HTML escaping, and template substitution.
4. **Assemble the blog:** discover posts, generate individual pages, sort the homepage by date, and copy assets.
5. **Publish:** verify the generated site and deploy it to Cloudflare Pages.
6. **Expand:** add more Markdown features, an RSS feed, and automated deployment.
