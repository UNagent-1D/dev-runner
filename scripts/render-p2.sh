#!/usr/bin/env bash
# Render the Prototype 2 deliverable end-to-end.
#
# Inputs : docs/p2_1D.md + docs/deployment-{1-context,2-host}.puml
# Output : docs/p2_1D.pdf
#
# Hard requirements: pandoc, and one of {weasyprint, wkhtmltopdf, xelatex}.
# Soft (auto-fallback): plantuml; ImageMagick.
#   - plantuml missing  → diagrams rendered via Kroki HTTP API (curl).
#   - convert  missing  → placeholder SVGs written instead of PNGs.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DOC_DIR="docs"
IMG_DIR="$DOC_DIR/img"
MD="$DOC_DIR/p2_1D.md"
PDF="$DOC_DIR/p2_1D.pdf"
KROKI="https://kroki.io/plantuml/svg"

mkdir -p "$IMG_DIR"

# ===========================================================================
# 1. PlantUML → SVG  (local plantuml if present, else Kroki HTTP API)
# ===========================================================================
render_puml() {
  local src="$1"
  local out="${src%.puml}.svg"

  if command -v plantuml >/dev/null; then
    echo "▶ plantuml → $out"
    plantuml -tsvg "$src" >/dev/null
  elif command -v curl >/dev/null; then
    echo "▶ kroki  → $out"
    curl -fsSL --data-binary @"$src" -H "Content-Type: text/plain" \
         "$KROKI" -o "$out"
  else
    echo "✗ Neither plantuml nor curl is available — cannot render $src" >&2
    return 1
  fi
}

render_puml "$DOC_DIR/deployment-1-context.puml"
render_puml "$DOC_DIR/deployment-2-host.puml"

# ===========================================================================
# 2. Placeholders for cnc / layered / decomposition  (PNG via convert, else SVG)
# ===========================================================================
make_placeholder() {
  local name="$1"  label="$2"
  local png="$IMG_DIR/$name.png"
  local svg="$IMG_DIR/$name.svg"
  local jpeg="$IMG_DIR/$name.jpeg"
  local jpg="$IMG_DIR/$name.jpg"

  # If a real raster image already exists in any common format, leave it alone
  [ -f "$png" ] || [ -f "$jpeg" ] || [ -f "$jpg" ] && return 0

  if command -v convert >/dev/null; then
    convert -size 1100x500 xc:'#FAFAFA' -gravity Center \
            -font Helvetica -pointsize 36 -fill '#666' \
            -annotate 0 "$label\n\n(Diagram TBD — replace with the team's export)" \
            "$png"
    echo "▶ placeholder PNG: $png"
  else
    cat > "$svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1100 500" width="1100" height="500">
  <rect width="1100" height="500" fill="#FAFAFA" stroke="#CCC" stroke-width="2"/>
  <text x="550" y="230" text-anchor="middle" font-family="Helvetica, sans-serif"
        font-size="42" fill="#444" font-weight="bold">$label</text>
  <text x="550" y="290" text-anchor="middle" font-family="Helvetica, sans-serif"
        font-size="22" fill="#888">(Diagram TBD — replace with the team's export)</text>
</svg>
EOF
    echo "▶ placeholder SVG: $svg"
  fi
}
make_placeholder "cnc"           "C&amp;C View"
make_placeholder "layered"       "Layered View"
make_placeholder "decomposition" "Decomposition View"

# When PNGs are missing but SVGs exist, rewrite the markdown image refs to .svg.
# This is non-destructive — uses a sed-edited copy in /tmp.
# Keep the work copy in the same dir as the source so relative image
# paths (img/foo.png, deployment-1-context.svg, logo.png) resolve.
WORK_MD="$DOC_DIR/.p2_1D.work.md"
trap 'rm -f "$WORK_MD"' EXIT
cp "$MD" "$WORK_MD"
for name in cnc layered decomposition; do
  if [ ! -f "$IMG_DIR/$name.png" ] && [ -f "$IMG_DIR/$name.svg" ]; then
    sed -i "s|img/$name.png|img/$name.svg|g" "$WORK_MD"
  fi
done

# ===========================================================================
# 3. Markdown → PDF  (pandoc + first available engine)
# ===========================================================================
command -v pandoc >/dev/null || { echo "✗ pandoc missing"; exit 1; }

ENGINE=""
# weasyprint / wkhtmltopdf first: HTML+CSS pipeline, no LaTeX font/style hassle.
# pdflatex next: ships with texlive-basic but pulls texlive-latexrecommended
# for xcolor / hyperref. xelatex / lualatex last: need texlive-fontsrecommended.
for cand in weasyprint wkhtmltopdf pdflatex xelatex lualatex; do
  if command -v "$cand" >/dev/null; then ENGINE="$cand"; break; fi
done
[ -n "$ENGINE" ] || { echo "✗ No PDF engine. Install one (texlive-xetex/weasyprint/wkhtmltopdf)"; exit 1; }

echo "▶ pandoc + $ENGINE → $PDF"

# Run pandoc from inside docs/ so image paths like `logo.png`, `img/foo.svg`,
# and `deployment-*.svg` resolve correctly under every PDF engine.
WORK_BASE="$(basename "$WORK_MD")"
PDF_BASE="$(basename "$PDF")"

PANDOC_ARGS=(
  "$WORK_BASE"
  --from gfm+yaml_metadata_block
  --pdf-engine="$ENGINE"
  --resource-path=.
  --metadata title="Prototype 2 — Advanced Architectural Structure"
  -V geometry:margin=2cm
  -V colorlinks=true
  --toc --toc-depth=3
  -o "$PDF_BASE"
)

case "$ENGINE" in
  weasyprint|wkhtmltopdf) PANDOC_ARGS+=( -V mainfont="Helvetica" -V fontsize=10pt ) ;;
esac

(cd "$DOC_DIR" && pandoc "${PANDOC_ARGS[@]}")

echo
echo "✓ Wrote $PDF"
ls -lh "$PDF"
