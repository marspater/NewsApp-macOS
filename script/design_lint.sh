#!/bin/bash
# Design-language ratchet for docs/DESIGN.md.
#
# Counts known deviations per file under Sources/Views (DesignSystem.swift owns the
# tokens and is exempt) and in Sources/App/NewsApp.swift (menus and commands) and compares
# them with script/design_lint_baseline.txt. A rising count fails; a falling count
# also fails until the baseline is lowered with `script/design_lint.sh --update`,
# so the baseline only moves down. Shell only, so it runs without a Swift toolchain.
set -euo pipefail

cd "$(dirname "$0")/.."
BASELINE="script/design_lint_baseline.txt"
export LC_ALL=C

# rule name | extended regular expression
RULES=(
    "literal-font-size|\.system\(size:"
    "literal-color|(^|[^A-Za-z0-9_])Color\.[A-Za-z]+|[(,:] ?\.(black|blue|brown|cyan|gray|green|indigo|mint|orange|pink|purple|red|teal|white|yellow)[^A-Za-z0-9_]|Color\((red|white|hue|\.sRGB|\.displayP3)"
    "corner-radius|\.cornerRadius\("
    "toolbar-background|toolbarBackground"
    "direct-glass|glassEffect|GlassEffectContainer"
    "scroll-edge-style|scrollEdgeEffectStyle"
    "uppercased|\.uppercased\(\)"
    "platform-label|(see platform_labels)"
    "material|\.(ultraThin|thin|regular|thick|ultraThick)Material"
    # Ratchets added 24 October 2026 (finish-pass slice 9): counts only go down.
    "literal-spacing|(spacing|padding)(\([^()]*)?[:(,] ?[1-9][0-9]*(\.[0-9]+)?[,)]"
    "literal-frame|\.frame\([^()]*(idealWidth|idealHeight|minWidth|minHeight|maxWidth|maxHeight|width|height): ?[0-9]+(\.[0-9]+)?[,)]"
    "literal-opacity|\.opacity\(0?\.[0-9]+\)"
    "literal-stroke|lineWidth: ?[0-9]+(\.[0-9]+)?"
    "raw-environment|\\\.(colorSchemeContrast|accessibilityReduceMotion|accessibilityReduceTransparency)"
    "foregroundColor|\.foregroundColor\("
    "legacy-alias|AppMotion\.(quick|responsive)|AppColor\.(label|tertiaryLabel|separator)[^A-Za-z]"
    "article-copy|(Text|Label|Button|help|accessibilityLabel|accessibilityHint)\(\"([^\"]*[^A-Za-z])?[Aa]rticle"
)
ALLOWED_COLORS='Color\.(clear|primary|secondary|accentColor)$'

# Labels set on AppKit-backed views (a ProgressView, or text with .textSelection(.enabled)) anywhere in the same
# modifier chain, which may span lines: the chain continues while lines start with "." or ")". Also counts a
# container that combines such a view into one element: a { } block holding one, whose closing chain applies
# .accessibilityElement(children: .combine). DESIGN.md section 16.
platform_labels() {
    local file="$1"
    awk '
        { line = $0; sub(/^[ \t]+/, "", line) }
        chained && line !~ /^[.)]/ { chained = 0 }
        closed && line !~ /^[.)}]/ { closed = 0 }
        {
            start = 0
            if (match(line, /ProgressView\(/)) start = RSTART
            else if (match(line, /\.textSelection\(\.enabled\)/)) start = RSTART
            if (start) { chained = 1; rest = substr(line, start) } else { rest = line }
            if (chained && index(rest, ".accessibilityLabel(")) count++

            # Track { } blocks; mark every open block that holds an AppKit-backed view.
            backed = start
            tail = line
            for (c = 1; c <= length(line); c++) {
                ch = substr(line, c, 1)
                if (backed && c == backed) for (d = 1; d <= depth; d++) holds[d] = 1
                if (ch == "{") { depth++; holds[depth] = 0 }
                else if (ch == "}" && depth > 0) {
                    closed = holds[depth]; depth--
                    tail = substr(line, c + 1)
                }
            }
            if (closed && index(tail, ".accessibilityElement(children: .combine)")) { count++; closed = 0 }
        }
        END { print count + 0 }
    ' "$file"
}

# Self-check on every run: three labelled AppKit-backed views (one split across lines), two containers combining
# one (one nested, one with a modifier between), and three safe containers that must not count.
platform_probe="$(mktemp)"
cat > "$platform_probe" <<'SWIFT'
ProgressView()
    .controlSize(.small)
    .accessibilityLabel("Loading")
Text(credit).font(.body)
    .textSelection(.enabled)
    .accessibilityLabel("Credit")
ProgressView().accessibilityLabel("One line")
HStack {
    ProgressView().accessibilityHidden(true)
}
.accessibilityLabel("Container")
VStack {
    if let caption {
        Text(caption).textSelection(.enabled)
    }
}
.accessibilityElement(children: .combine)
.accessibilityLabel("Combined")
HStack {
    Text(item).textSelection(.enabled)
}
.font(.body)
.accessibilityElement(children: .combine)
HStack {
    Text(item).textSelection(.enabled)
}
.accessibilityElement(children: .ignore)
.accessibilityLabel("Ignored")
HStack {
    Text("Plain")
}
.accessibilityElement(children: .combine)
SWIFT
if [[ "$(platform_labels "$platform_probe")" != "5" ]]; then
    rm -f "$platform_probe"
    echo "Design lint: the AppKit-backed label check failed its self-test." >&2
    exit 1
fi
rm -f "$platform_probe"

count() {
    local rule="$1" pattern="$2" file="$3"
    if [[ "$rule" == "platform-label" ]]; then
        platform_labels "$file"
    elif [[ "$rule" == "literal-color" ]]; then
        { grep -o -E "$pattern" "$file" || true; } | { grep -v -E "$ALLOWED_COLORS" || true; } | wc -l | tr -d ' '
    else
        { grep -o -E "$pattern" "$file" || true; } | wc -l | tr -d ' '
    fi
}

current="$(mktemp)"
trap 'rm -f "$current"' EXIT

{ find Sources/Views -name '*.swift' ! -name DesignSystem.swift; echo Sources/App/NewsApp.swift; } | sort | while read -r file; do
    for entry in "${RULES[@]}"; do
        rule="${entry%%|*}"
        pattern="${entry#*|}"
        n="$(count "$rule" "$pattern" "$file")"
        if [[ "$n" -gt 0 ]]; then
            printf '%s %s %s\n' "$rule" "$file" "$n"
        fi
    done
done | sort > "$current"

# Phase 4 (#354): a permanent zero-deviation gate for content styles.
if grep -E '^(literal-font-size|literal-color|uppercased|platform-label) ' "$current"; then
    echo "Design lint: literal fonts, colors, uppercasing and labels on AppKit-backed views must be zero (#354)." >&2
    exit 1
fi

if [[ "${1:-}" == "--update" ]]; then
    {
        echo "# Design lint baseline: rule file count. Generated by script/design_lint.sh --update."
        echo "# Counts may only go down; see docs/DESIGN.md before adding an exception."
        cat "$current"
    } > "$BASELINE"
    echo "Design lint baseline updated ($(wc -l < "$current" | tr -d ' ') entries)."
    exit 0
fi

if [[ ! -f "$BASELINE" ]]; then
    echo "Design lint: missing $BASELINE; run script/design_lint.sh --update." >&2
    exit 1
fi

{ grep -v '^#' "$BASELINE" || true; } | awk -v current="$current" '
    { base[$1 " " $2] = $3 }
    END {
        while ((getline line < current) > 0) {
            split(line, f, " ")
            key = f[1] " " f[2]
            now[key] = f[3]
        }
        status = 0
        for (key in now) {
            b = (key in base) ? base[key] : 0
            if (now[key] > b) {
                printf "Design lint: %s rose from %d to %d. Use the DESIGN.md token or helper instead.\n", key, b, now[key]
                status = 1
            }
        }
        for (key in base) {
            n = (key in now) ? now[key] : 0
            if (n < base[key]) {
                printf "Design lint: %s fell from %d to %d. Lower the baseline with script/design_lint.sh --update.\n", key, base[key], n
                status = 1
            }
        }
        exit status
    }
' >&2 || exit 1

echo "Design lint passed ($(awk '{ total += $3 } END { print total + 0 }' "$current") baseline deviations remaining)."
