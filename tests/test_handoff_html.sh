#!/bin/bash
# ============================================================
# Test script for the handoff HTML renderer embedded in
# dg_handoff.sh and primary/10_generate_handoff_report.sh
# ============================================================
# Usage: bash tests/test_handoff_html.sh
#
# The renderer (handoff_md_to_html + render_handoff_html) converts the
# Markdown handoff report into a styled, self-contained HTML page. The
# block is duplicated byte-identically in both handoff scripts between
# "# ---- begin/end handoff html renderer ----" markers; this test:
#   1. diffs the two copies (they must stay byte-identical)
#   2. sources the extracted block and converts a fixture covering the
#      full Markdown subset the emitters produce, asserting the HTML:
#      headings h1-h4, meta chips source list, pipe tables with header
#      rows, fenced code blocks (verbatim, escaped, no leading blank
#      line), "- [ ]" checklist items, bullet continuations, verdict
#      pill (HEALTHY/WARNING/ERROR classes), "**WARNING:**" callout,
#      blockquote, links, inline bold/code, entity escaping, tag
#      balance, and the page chrome (title, both theme palettes, copy
#      button script)
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
echo "Test 1: renderer block is byte-identical in both scripts"
echo "============================================================"

extract_block "${REPO_DIR}/dg_handoff.sh" "${WORK_DIR}/block_ref.sh"
extract_block "${REPO_DIR}/primary/10_generate_handoff_report.sh" "${WORK_DIR}/block_10.sh"

if [[ ! -s "${WORK_DIR}/block_ref.sh" ]]; then
    echo "  FAIL: renderer block not found in dg_handoff.sh"
    FAIL=$((FAIL+1))
elif diff -q "${WORK_DIR}/block_ref.sh" "${WORK_DIR}/block_10.sh" >/dev/null; then
    echo "  PASS: primary/10_generate_handoff_report.sh matches dg_handoff.sh"
    PASS=$((PASS+1))
else
    echo "  FAIL: renderer block drift between the two scripts:"
    diff "${WORK_DIR}/block_ref.sh" "${WORK_DIR}/block_10.sh" | head -20
    FAIL=$((FAIL+1))
fi

echo ""
echo "============================================================"
echo "Test 2: Markdown subset converts to the expected HTML"
echo "============================================================"

# shellcheck disable=SC1090
source "${WORK_DIR}/block_ref.sh"

cat > "${WORK_DIR}/fixture.md" <<'EOF'
# Data Guard Handoff Report

- **Generated:** today
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

Text with a `snippet` inside.
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
assert_contains "h2 rendered"                "<h2>1. Connection Strings</h2>" "$H"
assert_contains "h3 rendered"                "<h3>Descriptor Parameters</h3>" "$H"
assert_contains "h4 rendered"                "<h4>Primary-only</h4>" "$H"
assert_contains "meta bullet bold"           "<li><strong>Generated:</strong> today</li>" "$H"
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
echo "Test Summary: ${PASS} passed, ${FAIL} failed"
echo "============================================================"

[[ $FAIL -eq 0 ]] || exit 1
exit 0
