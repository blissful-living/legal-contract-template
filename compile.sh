#!/usr/bin/env bash
# compile.sh — link cross-references and render a .qmd to HTML (and optionally PDF).
#
# Usage:
#   ./compile.sh <file.qmd> [-o output.html] [--fix-refs] [--pdf]
#
# Steps:
#   1. python3 link-refs.py <file.qmd>   — rewrite plain-text cross-refs
#   2. quarto render <file.qmd>          — produce HTML
#   3. headless Chrome (--pdf only)      — convert HTML to PDF
#
# The linker is idempotent, so re-running compile.sh on the same file is safe.
#
# --fix-refs   Rewrite stale letter-suffix link display text to match the
#              document's positional numbering (e.g. "4c" → "4.3").
# --pdf        Convert the rendered HTML to PDF using headless Chrome.
#              Set CHROME=/path/to/binary to override auto-detection.

set -euo pipefail

usage() {
    echo "Usage: $0 <file.qmd> [-o output.html] [--fix-refs] [--pdf]" >&2
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

echo "→ Linking cross-references in $input"
python3 "$script_dir/link-refs.py" $fix_refs "$input"

echo "→ Rendering $input"
if [[ -n "$output" ]]; then
    quarto render "$input" --output "$output"
else
    quarto render "$input"
fi

# Resolve the HTML output path (Quarto default: same name as input, .html extension).
html_path="${output:-${input%.qmd}.html}"

if [[ -n "$make_pdf" ]]; then
    chrome_bin=$(find_chrome) || {
        echo "✗ --pdf: no Chrome/Chromium binary found." \
             "Install Chrome or set CHROME=/path/to/binary." >&2
        exit 1
    }

    pdf_path="${html_path%.html}.pdf"

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
