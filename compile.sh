#!/usr/bin/env bash
# compile.sh — link cross-references and render a .qmd to HTML (and optionally PDF).
#
# Usage:
#   ./compile.sh <file.qmd> [-o path/to/output.html] [--fix-refs] [--pdf] [--force]
#
# Steps:
#   1. python3 link-refs.py <file.qmd>   — rewrite plain-text cross-refs
#   2. quarto render <file.qmd>          — produce HTML
#   3. headless Chrome (--pdf only)      — convert HTML to PDF
#
# The linker is idempotent, so re-running compile.sh on the same file is safe.
#
# -o accepts a full path (directory + filename). The directory is created if it
#    does not exist. PDF output (--pdf) is placed alongside the HTML output.
# --fix-refs   Rewrite stale letter-suffix link display text to match the
#              document's positional numbering (e.g. "4c" → "4.3").
# --pdf        Convert the rendered HTML to PDF using headless Chrome.
#              Set CHROME=/path/to/binary to override auto-detection.
# --force / -f Overwrite existing output files without prompting.

set -euo pipefail

usage() {
    echo "Usage: $0 <file.qmd> [-o path/to/output.html] [--fix-refs] [--pdf] [--force]" >&2
    exit 2
}

# Print the path to a headless-capable Chrome/Chromium binary, or return 1.
find_chrome() {
    if [[ -n "${CHROME:-}" ]]; then
        echo "$CHROME"
        return 0
    fi

    local candidates=(
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        "/Applications/Chromium.app/Contents/MacOS/Chromium"
        "google-chrome"
        "google-chrome-stable"
        "chromium-browser"
        "chromium"
    )

    for c in "${candidates[@]}"; do
        if [[ "$c" == /* ]]; then
            [[ -x "$c" ]] && { echo "$c"; return 0; }
        else
            command -v "$c" &>/dev/null && { echo "$c"; return 0; }
        fi
    done

    return 1
}

input=""
output=""
fix_refs=""
make_pdf=""
force=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            [[ $# -ge 2 ]] || usage
            output="$2"
            shift 2
            ;;
        --fix-refs)
            fix_refs="--fix-refs"
            shift
            ;;
        --pdf)
            make_pdf=1
            shift
            ;;
        --force|-f)
            force=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Unknown flag: $1" >&2
            usage
            ;;
        *)
            [[ -z "$input" ]] || usage
            input="$1"
            shift
            ;;
    esac
done

[[ -n "$input" ]] || usage
[[ -f "$input" ]] || { echo "File not found: $input" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve output paths to absolute paths so they are correct regardless of
# whether quarto or Chrome are invoked from a different working directory.
# -o may be a full path; the destination directory is created if needed.
if [[ -n "$output" ]]; then
    mkdir -p "$(dirname "$output")"
    html_path="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"
else
    html_path="$(cd "$(dirname "${input%.qmd}.html")" && pwd)/$(basename "${input%.qmd}.html")"
fi
pdf_path="${html_path%.html}.pdf"

existing=()
[[ -f "$html_path" ]] && existing+=("$html_path")
[[ -n "$make_pdf" && -f "$pdf_path" ]] && existing+=("$pdf_path")

if [[ ${#existing[@]} -gt 0 && -z "$force" ]]; then
    echo "The following output file(s) already exist:" >&2
    for f in "${existing[@]}"; do echo "  $f" >&2; done
    if [[ -t 0 ]]; then
        printf "Overwrite? [y/N] " >&2
        read -r _reply
        [[ "$_reply" =~ ^[Yy]$ ]] || { echo "Aborted." >&2; exit 1; }
    else
        echo "Aborted (non-interactive; use --force to overwrite)." >&2
        exit 1
    fi
fi

echo "→ Linking cross-references in $input"
python3 "$script_dir/scripts/link-refs.py" $fix_refs "$input"

echo "→ Rendering $input"

# Quarto discovers _quarto.yml by walking up from the input file's directory,
# not the CWD.  When the input file lives inside this repo, _quarto.yml is
# found automatically and supplies the project settings (CSS, Lua filter,
# theme: none).  When it lives outside, those settings must be mirrored via
# --metadata-file using absolute paths.
#
# Do NOT pass --metadata-file when _quarto.yml is already discoverable:
# Quarto merges metadata sources additively, so duplicating `filters:` or
# `css:` makes the Lua filter run twice and the CSS get embedded twice
# (producing doubled section numbers and two TOC blocks).
in_project=""
search_dir="$(cd "$(dirname "$input")" && pwd)"
while [[ -n "$search_dir" && "$search_dir" != "/" ]]; do
    if [[ -f "$search_dir/_quarto.yml" ]]; then
        in_project=1
        break
    fi
    search_dir="$(dirname "$search_dir")"
done

# quarto --output rejects paths; render to the default location next to the
# source, then move to the requested destination if -o specified a different path.
quarto_html="$(cd "$(dirname "$input")" && pwd)/$(basename "${input%.qmd}").html"

if [[ -n "$in_project" ]]; then
    quarto render "$input"
else
    _tmp_meta=$(mktemp /tmp/quarto-meta-XXXXX.yml)
    trap 'rm -f "$_tmp_meta"' EXIT
    cat > "$_tmp_meta" <<EOF
css: "${script_dir}/assets/style.css"
embed-resources: true
theme: none
minimal: true
format-links: false
number-sections: false
crossrefs-hover: false
toc-title: "TABLE OF CONTENTS"
filters:
  - "${script_dir}/assets/legal-numbering.lua"
crossref:
  sec-prefix: ""
  chapters: false
EOF
    quarto render "$input" --metadata-file "$_tmp_meta"
fi

[[ "$quarto_html" != "$html_path" ]] && mv "$quarto_html" "$html_path"

# Quarto resolves {{< meta >}} shortcodes after Lua filters run, so TOC entries
# built by the filter may have empty placeholders where shortcode values belong.
# Rebuild TOC labels from the already-rendered heading text to correct this.
python3 "$script_dir/scripts/fix-toc.py" "$html_path"

# Clean up any _files/ dir Quarto may still produce.
files_dir="${html_path%.html}_files"
[[ -d "$files_dir" ]] && rm -rf "$files_dir"

if [[ -n "$make_pdf" ]]; then
    chrome_bin=$(find_chrome) || {
        echo "✗ --pdf: no Chrome/Chromium binary found." \
             "Install Chrome or set CHROME=/path/to/binary." >&2
        exit 1
    }

    # --print-to-pdf requires an absolute path in some Chrome versions.
    abs_html="$(cd "$(dirname "$html_path")" && pwd)/$(basename "$html_path")"
    abs_pdf="$(cd "$(dirname "$pdf_path")" && pwd)/$(basename "$pdf_path")"

    echo "→ Rendering PDF via $(basename "$chrome_bin")"
    "$chrome_bin" \
        --headless \
        --print-to-pdf="$abs_pdf" \
        --no-pdf-header-footer \
        --run-all-compositor-stages-before-draw \
        "file://$abs_html" 2>/dev/null

    echo "✓ Done → $pdf_path"
else
    echo "✓ Done"
fi
