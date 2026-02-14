# varg Documentation

Documentation for varg AI video generation SDK and Gateway API.

## About this project

- Built on [Mintlify](https://mintlify.com)
- Pages are MDX files with YAML frontmatter
- Configuration in `docs.json`
- Run `mint dev` to preview locally
- Run `mint broken-links` to check links

## Structure

```
docs/
├── index.mdx                 # Landing page
├── quickstart.mdx            # Setup guide
├── sdk/
│   ├── index.mdx             # SDK overview
│   ├── components.mdx        # JSX components reference
│   ├── models.mdx            # AI models reference
│   └── cli.mdx               # CLI reference
├── api/
│   └── index.mdx             # Gateway API docs
├── templates/
│   ├── index.mdx             # Template gallery
│   ├── slideshow.mdx         # Slideshow template
│   ├── talking-character.mdx # Talking head template
│   └── transformation.mdx    # Before/after template
└── ai-agents/
    ├── index.mdx             # AI agent context (most important)
    ├── claude-code.mdx       # Claude Code setup
    └── cursor.mdx            # Cursor setup
```

## Key Pages

### For AI Agents

The `/ai-agents/index.mdx` page is the most important - it contains complete context for AI assistants to understand varg and help users create videos.

### For Humans

- `/quickstart.mdx` - Getting started guide
- `/sdk/components.mdx` - Component reference
- `/templates/` - Copy-paste examples

## Terminology

- **varg** - The SDK and platform name (lowercase)
- **vargai** - The npm package name
- **Clip** - Time segment in a video
- **Element function** - `Image()`, `Video()`, `Speech()` that generate AI content
- **Component** - JSX component used in composition

## Style preferences

- Use active voice and second person ("you")
- Keep sentences concise - one idea per sentence
- Use sentence case for headings
- Bold for UI elements: Click **Settings**
- Code formatting for file names, commands, paths, and code references
- Always include full import statements in code examples
- Use tabs for bun/npm alternatives
- Include required API keys for each feature
- Add "Tips" sections with practical advice

## Content boundaries

- Document SDK (open-source vargai package)
- Document Gateway API (api.varg.ai)
- Do NOT document internal app implementation details
- Do NOT document deployment/infrastructure

## Commands

```bash
# Preview locally
mint dev

# Check broken links
mint broken-links

# Deploy (automatic via GitHub)
git push
```
