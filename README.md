# Quarto Legal Templates

A lightweight toolkit for authoring legal documents in Markdown and rendering them as polished, self-contained HTML files. Built on [Quarto](https://quarto.org), with a custom Pandoc Lua filter that applies standard legal numbering conventions and a minimal stylesheet suited for printing or digital distribution.

## Features

- Legal-style hierarchical numbering: `1.` → `1.1` → `(a)` → `(i)`
- Cross-references between clauses (e.g. *"as defined in clause 1.1"*)
- Template variables for party names, dates, and other document-level values
- Self-contained HTML output — a single file with no external dependencies
- Print-ready styling (Arial, 11pt, 800 px body width)

## Prerequisites

Install [Quarto](https://quarto.org/docs/get-started/) (version 1.4 or later):

```bash
# macOS (Homebrew)
brew install quarto

# or download the installer from https://quarto.org/docs/get-started/
```

## Repository structure

```
.
├── _quarto.yml          # Quarto project configuration
├── _variables.yml       # Document variables (parties, dates, etc.)
├── agreement.qmd        # Source document in Quarto Markdown
├── legal-numbering.lua  # Pandoc Lua filter for legal section numbering
└── style.css            # Print-oriented stylesheet
```

## Customising variables

Edit `_variables.yml` to set the party names and signing date before rendering:

```yaml
parties:
  person_1: "Alice Smith"
  person_2: "Bob Jones"

dates:
  signed_date: "26 April 2026"
```

These values are referenced in the document source with `{{< var parties.person_1 >}}` etc.

## Rendering HTML

To render a single document:

```bash
quarto render agreement.qmd
```

This produces `agreement.html` — a fully self-contained file that can be opened in any browser, emailed, or printed.

To render all documents in the project at once:

```bash
quarto render
```

## Adding a new document

1. Copy `agreement.qmd` to a new file, e.g. `nda.qmd`.
2. Update the `title` in the YAML front matter.
3. Write the document body using standard Markdown headings (`#`, `##`, `###`, `####`).
4. Assign an `{#sec-*}` identifier to any clause you wish to cross-reference.
5. Reference it elsewhere with `@sec-*` — the Lua filter resolves these to numbered links automatically.
6. Run `quarto render nda.qmd`.

## Cross-references

Assign an identifier to a heading:

```markdown
## Payment Terms {#sec-payment}
```

Then reference it from anywhere in the document:

```markdown
Payment is governed by @sec-payment.
```

The filter replaces `@sec-payment` with a hyperlink such as *clause 2.1*.

## Licence

Apache 2.0 — see [LICENSE](LICENSE).  
Copyright &copy; 2026 [Blissful Living Foundation](https://labs.blissful.im).
