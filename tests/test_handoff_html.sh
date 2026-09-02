#!/bin/bash
# ============================================================
# Test script for the handoff HTML renderer embedded in
# dg_handoff.sh (the single handoff report implementation;
# primary/10_generate_handoff_report.sh is a thin wrapper around it)
# ============================================================
# Usage: bash tests/test_handoff_html.sh
#
# The renderer (handoff_md_to_html + render_handoff_html) converts the
# Markdown handoff report into a styled, self-contained HTML page. The
# block lives between the "# ---- begin/end handoff html renderer ----"
# markers in dg_handoff.sh; this test:
#   1. checks the block is present and extractable
#   2. sources the extracted block and converts a fixture covering the
#      full Markdown subset the emitters produce, asserting the HTML:
#      headings h1-h4, meta chips source list, pipe tables with header
#      rows, fenced code blocks (verbatim, escaped, no leading blank
#      line), "- [ ]" checklist items, bullet continuations, verdict
#      pill (HEALTHY/WARNING/ERROR classes), "**WARNING:**" callout,
#      blockquote, links, inline bold/code, entity escaping, tag
#      balance, and the page chrome (title, both theme palettes, copy
#      button script)
#   3. asserts the navigation/branding layer: unique slugified ids on
#      every h2/h3, a <nav class="toc"> whose entries point at them, the
#      sticky-sidebar layout wrapper, the @media print stylesheet, the
#      staleness banner (data-stale-days default and the
#      DG_HANDOFF_STALE_DAYS override) and the DG_HANDOFF_BRAND_*
#      overrides (name, logo, colors, invalid-color fallback)
# ============================================================

# Don't use set -e as we need to test for failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

assert_contains() {
    # assert_contains <label> <needle> <haystack-file>
    local label="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file"; then
        echo "  PASS: $label"
        PASS=$((PASS+1))
    else
        echo "  FAIL: $label"
        echo "        missing: $needle"
        FAIL=$((FAIL+1))
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file"; then
        echo "  FAIL: $label"
        echo "        found unexpected: $needle"
        FAIL=$((FAIL+1))
    else
        echo "  PASS: $label"
        PASS=$((PASS+1))
    fi
}

extract_block() {
    # extract_block <script-file> <output-file>
    sed -n '/^# ---- begin handoff html renderer ----$/,/^# ---- end handoff html renderer ----$/p' "$1" > "$2"
}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "============================================================"
echo "Test 1: renderer block is present in dg_handoff.sh"
echo "============================================================"

extract_block "${REPO_DIR}/dg_handoff.sh" "${WORK_DIR}/block_ref.sh"

if [[ ! -s "${WORK_DIR}/block_ref.sh" ]]; then
    echo "  FAIL: renderer block not found in dg_handoff.sh"
    FAIL=$((FAIL+1))
else
    echo "  PASS: renderer block extracted from dg_handoff.sh"
    PASS=$((PASS+1))
fi

echo ""
echo "============================================================"
echo "Test 2: Markdown subset converts to the expected HTML"
echo "============================================================"

# shellcheck disable=SC1090
source "${WORK_DIR}/block_ref.sh"

cat > "${WORK_DIR}/fixture.md" <<'EOF'
# Data Guard Handoff Report

- **Generated:** 2020-01-02 03:04:05 UTC
- **Interactive diagram:** [open in the visualizer](https://example.com/#cfg=abc) - topology only, no credentials

## 1. Connection Strings

### Descriptor Parameters

| Parameter | Value |
|-----------|-------|
| LOAD_BALANCE | OFF |
| RETRY_COUNT | 3 & 3 |

#### Primary-only

```
APP_HA =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = <h>)(PORT = 1521))
  )
```

**Verdict:** HEALTHY

**WARNING:** trigger not deployed.

> **Admin/default service** - not managed by the role trigger.

- plain bullet with **bold** and `code`
- a bullet that continues
  on a second source line
- [ ] a checklist item

## 2. Application Impact

### Service: `app_svc`

Text with a `snippet` inside.

### Service: `app_svc`

A repeated heading title, so the anchor id has to be de-duplicated.
EOF

PRIMARY_DB_UNIQUE_NAME="TESTPRIM"
render_handoff_html < "${WORK_DIR}/fixture.md" > "${WORK_DIR}/out.html" 2>"${WORK_DIR}/stderr.log"

if [[ -s "${WORK_DIR}/stderr.log" ]]; then
    echo "  FAIL: renderer wrote to stderr:"
    head -5 "${WORK_DIR}/stderr.log"
    FAIL=$((FAIL+1))
else
    echo "  PASS: renderer ran silently"
    PASS=$((PASS+1))
fi

H="${WORK_DIR}/out.html"
assert_contains "page title carries DB_UNIQUE_NAME" "<title>Data Guard Handoff - TESTPRIM</title>" "$H"
assert_contains "h1 rendered"                "<h1>Data Guard Handoff Report</h1>" "$H"
assert_contains "h2 rendered with anchor id" "<h2 id=\"1-connection-strings\">1. Connection Strings</h2>" "$H"
assert_contains "h3 rendered with anchor id" "<h3 id=\"descriptor-parameters\">Descriptor Parameters</h3>" "$H"
assert_contains "h4 rendered"                "<h4>Primary-only</h4>" "$H"
assert_contains "meta bullet bold"           "<li><strong>Generated:</strong> 2020-01-02 03:04:05 UTC</li>" "$H"
assert_contains "link rendered"              "<a href=\"https://example.com/#cfg=abc\">open in the visualizer</a>" "$H"
assert_contains "table header row"           "<tr><th>Parameter</th><th>Value</th></tr>" "$H"
assert_contains "table cell escaped"         "<td>3 &amp; 3</td>" "$H"
assert_contains "table wrapped for scroll"   "<div class=\"twrap\"><table>" "$H"
assert_contains "fence opens without blank line" "<pre><code>APP_HA =" "$H"
assert_contains "fence content escaped"      "(HOST = &lt;h&gt;)(PORT = 1521))" "$H"
assert_contains "verdict pill healthy"       "<span class=\"pill pill-healthy\">HEALTHY</span>" "$H"
assert_contains "warning callout"            "<p class=\"warn\"><strong>WARNING:</strong> trigger not deployed.</p>" "$H"
assert_contains "blockquote rendered"        "<blockquote><p><strong>Admin/default service</strong> - not managed by the role trigger.</p></blockquote>" "$H"
assert_contains "inline bold in bullet"      "<li>plain bullet with <strong>bold</strong> and <code>code</code></li>" "$H"
assert_contains "bullet continuation joined" "<li>a bullet that continues on a second source line</li>" "$H"
assert_contains "checklist item class"       "<li class=\"task\">a checklist item</li>" "$H"
assert_contains "inline code in paragraph"   "<p>Text with a <code>snippet</code> inside.</p>" "$H"
assert_contains "light palette token"        ":root{" "$H"
assert_contains "dark palette media query"   "@media (prefers-color-scheme: dark)" "$H"
assert_contains "copy button script"         "btn.className = 'copy';" "$H"
assert_not_contains "no raw markdown bold leaks" "**Generated:**" "$H"
assert_not_contains "no raw fence markers leak"  '```' "$H"

echo ""
echo "============================================================"
echo "Test 3: verdict pill classes for WARNING and ERROR"
echo "============================================================"

printf '**Verdict:** WARNING\n' | handoff_md_to_html > "${WORK_DIR}/v_warn.html"
printf '**Verdict:** ERROR\n'   | handoff_md_to_html > "${WORK_DIR}/v_err.html"
assert_contains "warning pill class" "pill pill-warning\">WARNING" "${WORK_DIR}/v_warn.html"
assert_contains "error pill class"   "pill pill-error\">ERROR"     "${WORK_DIR}/v_err.html"

echo ""
echo "============================================================"
echo "Test 4: HTML tag balance on the fixture output"
echo "============================================================"

BALANCED=1
for tag in ul table pre blockquote div p li tr code strong span h1 h2 h3 h4 a; do
    OPEN=$(grep -o "<${tag}[ >]" "$H" | wc -l | tr -d ' ')
    CLOSE=$(grep -o "</${tag}>" "$H" | wc -l | tr -d ' ')
    if [[ "$OPEN" -ne "$CLOSE" ]]; then
        echo "  FAIL: <${tag}> open=${OPEN} close=${CLOSE}"
        BALANCED=0
        FAIL=$((FAIL+1))
    fi
done
if [[ $BALANCED -eq 1 ]]; then
    echo "  PASS: all element tags balanced"
    PASS=$((PASS+1))
fi

echo ""
echo "============================================================"
echo "Test 5: renderer stays within AIX awk's array rules"
echo "============================================================"
# AIX 7.2 /usr/bin/awk aborts the run with "0602-558 cannot be used as an
# array" instead of coping with a name it has not already seen subscripted
# or with a multi-subscript (SUBSEP) reference.
if grep -q 'tcell\["0|0"\] = ""' "${WORK_DIR}/block_ref.sh"; then
    echo "  PASS: cell table seeded in BEGIN"
    PASS=$((PASS+1))
else
    echo "  FAIL: no BEGIN block seeding tcell/tnc/cells"
    FAIL=$((FAIL+1))
fi
if grep -qE '(tcell|tnc|cells)\[[^]]*,' "${WORK_DIR}/block_ref.sh"; then
    echo "  FAIL: multi-subscript array reference (arr[i,j]) in the renderer:"
    grep -nE '(tcell|tnc|cells)\[[^]]*,' "${WORK_DIR}/block_ref.sh" | head -5
    FAIL=$((FAIL+1))
else
    echo "  PASS: no multi-subscript array references"
    PASS=$((PASS+1))
fi

echo ""
echo "============================================================"
echo "Test 6: heading anchors and table of contents"
echo "============================================================"

assert_contains "second h2 anchor id"        "<h2 id=\"2-application-impact\">2. Application Impact</h2>" "$H"
assert_contains "inline markup stripped from id" "<h3 id=\"service-app-svc\">Service: <code>app_svc</code></h3>" "$H"
assert_contains "duplicate heading id suffixed" "<h3 id=\"service-app-svc-2\">" "$H"
assert_contains "toc nav emitted"            "<nav class=\"toc\" aria-label=\"Contents\">" "$H"
assert_contains "toc is collapsible"         "<summary>Contents</summary>" "$H"
assert_contains "toc links first h2"         "<a href=\"#1-connection-strings\">1. Connection Strings</a>" "$H"
assert_contains "toc links second h2"        "<a href=\"#2-application-impact\">2. Application Impact</a>" "$H"
assert_contains "toc nests h3"               "<a href=\"#descriptor-parameters\">Descriptor Parameters</a>" "$H"
assert_contains "toc h3 label is plain text" "<a href=\"#service-app-svc\">Service: app_svc</a>" "$H"
assert_contains "toc h3 dedup href"          "<a href=\"#service-app-svc-2\">" "$H"
assert_contains "sidebar layout wrapper"     "<div class=\"layout\">" "$H"
assert_contains "sticky sidebar breakpoint"  "@media (min-width:1100px){" "$H"

# The TOC must reference exactly the ids the headings carry, and no id twice.
IDS=$(grep -o 'id="[^"]*"' "$H" | sed 's/^id="//; s/"$//' | sort)
DUP_IDS=$(printf '%s\n' "$IDS" | uniq -d)
if [[ -z "$DUP_IDS" ]]; then
    echo "  PASS: heading ids are unique"
    PASS=$((PASS+1))
else
    echo "  FAIL: duplicate heading ids: $(printf '%s' "$DUP_IDS" | tr '\n' ' ')"
    FAIL=$((FAIL+1))
fi

TOC_HREFS=$(sed -n '/<nav class="toc"/,/<\/nav>/p' "$H" | grep -o 'href="#[^"]*"' | sed 's/^href="#//; s/"$//' | sort)
if [[ -n "$TOC_HREFS" ]] && [[ "$TOC_HREFS" == "$IDS" ]]; then
    echo "  PASS: every toc entry matches a heading id (and vice versa)"
    PASS=$((PASS+1))
else
    echo "  FAIL: toc hrefs and heading ids differ"
    echo "        ids:   $(printf '%s' "$IDS" | tr '\n' ' ')"
    echo "        hrefs: $(printf '%s' "$TOC_HREFS" | tr '\n' ' ')"
    FAIL=$((FAIL+1))
fi

echo ""
echo "============================================================"
echo "Test 7: print stylesheet and staleness banner"
echo "============================================================"

assert_contains "print media query"          "@media print{" "$H"
assert_contains "print breaks pages on h2"   "h2{page-break-before:always;break-before:page}" "$H"
assert_contains "print keeps blocks whole"   "page-break-inside:avoid" "$H"
assert_contains "print hides chrome"         ".toc,.stale,.prewrap .copy{display:none}" "$H"
assert_contains "print shows link urls"      "a[href^=\"http\"]::after{content:\" (\" attr(href) \")\"" "$H"
assert_contains "staleness threshold baked in" "<body data-stale-days=\"30\">" "$H"
assert_contains "staleness banner script"    "box.className = 'stale';" "$H"
assert_contains "staleness banner css"       ".stale{" "$H"

DG_HANDOFF_STALE_DAYS=7 render_handoff_html < "${WORK_DIR}/fixture.md" > "${WORK_DIR}/stale7.html" 2>/dev/null
assert_contains "DG_HANDOFF_STALE_DAYS honored" "<body data-stale-days=\"7\">" "${WORK_DIR}/stale7.html"
DG_HANDOFF_STALE_DAYS="soon" render_handoff_html < "${WORK_DIR}/fixture.md" > "${WORK_DIR}/stalebad.html" 2>/dev/null
assert_contains "invalid stale days falls back to 30" "<body data-stale-days=\"30\">" "${WORK_DIR}/stalebad.html"

echo ""
echo "============================================================"
echo "Test 8: brand defaults and DG_HANDOFF_BRAND_* overrides"
echo "============================================================"

assert_contains "default eyebrow text"       "<span class=\"eyebrow\">Oracle Data Guard</span>" "$H"
assert_contains "default inline logo"        "<img class=\"hd-logo\" src=\"data:image/png;base64," "$H"
assert_contains "default light accent"       "--accent:#0099CC;" "$H"
assert_contains "default ink"                "--accent-ink:#003366;" "$H"

DG_HANDOFF_BRAND_NAME='Acme Corp' \
DG_HANDOFF_BRAND_LOGO=none \
DG_HANDOFF_BRAND_COLOR='#FF0000' \
    render_handoff_html < "${WORK_DIR}/fixture.md" > "${WORK_DIR}/brand.html" 2>"${WORK_DIR}/brand_err.log"
assert_contains "brand name in eyebrow"      "<span class=\"eyebrow\">Acme Corp</span>" "${WORK_DIR}/brand.html"
assert_not_contains "logo omitted with none" "<img" "${WORK_DIR}/brand.html"
assert_contains "brand color in css"         "#FF0000" "${WORK_DIR}/brand.html"
if [[ -s "${WORK_DIR}/brand_err.log" ]]; then
    echo "  FAIL: brand override wrote to stderr:"
    head -3 "${WORK_DIR}/brand_err.log"
    FAIL=$((FAIL+1))
else
    echo "  PASS: brand override ran silently"
    PASS=$((PASS+1))
fi

DG_HANDOFF_BRAND_COLOR='red' render_handoff_html < "${WORK_DIR}/fixture.md" \
    > "${WORK_DIR}/badcolor.html" 2>"${WORK_DIR}/badcolor_err.log"
assert_contains "invalid color falls back"   "--accent:#0099CC;" "${WORK_DIR}/badcolor.html"
assert_not_contains "invalid color not used" "--accent:red" "${WORK_DIR}/badcolor.html"
assert_contains "invalid color warns"        "DG_HANDOFF_BRAND_COLOR" "${WORK_DIR}/badcolor_err.log"

DG_HANDOFF_BRAND_LOGO=/nonexistent/logo.png render_handoff_html < "${WORK_DIR}/fixture.md" \
    > "${WORK_DIR}/nologo.html" 2>"${WORK_DIR}/nologo_err.log"
assert_not_contains "unreadable logo omitted" "<img" "${WORK_DIR}/nologo.html"
assert_contains "unreadable logo warns"      "DG_HANDOFF_BRAND_LOGO" "${WORK_DIR}/nologo_err.log"

echo ""
echo "============================================================"
echo "Test Summary: ${PASS} passed, ${FAIL} failed"
echo "============================================================"

[[ $FAIL -eq 0 ]] || exit 1
exit 0
