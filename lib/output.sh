# shellcheck shell=bash
# Sourced by gh-dep-scanner.sh: the results as files (--output-text,
# --output-md, --output-html, --output-pdf).

# Write the files of the --output-* options. They show the results of
# print_results for REPORT_COLUMNS columns. A copy: no log line.
write_outputs() {
    if [[ -z "$OUTPUT_TEXT$OUTPUT_MD$OUTPUT_HTML$OUTPUT_PDF" ]]; then
        return 0
    fi
    output_path OUTPUT_TEXT txt
    output_path OUTPUT_MD md
    output_path OUTPUT_HTML html
    output_path OUTPUT_PDF pdf
    local body
    body=$(TERM_COLUMNS=$REPORT_COLUMNS REPORT_ONLY=1 print_results)
    if [[ -n "$OUTPUT_TEXT" ]]; then
        {
            printf 'gh-dep-scanner, %s UTC\n' "$(date -u '+%Y-%m-%d %H:%M')"
            printf '%s\n' "$body" | strip_colors
            command_section
        } >| "$OUTPUT_TEXT"
        print_info "Text report: $OUTPUT_TEXT"
    fi
    if [[ -n "$OUTPUT_MD" ]]; then
        write_markdown "$body" >| "$OUTPUT_MD"
        print_info "Markdown report: $OUTPUT_MD"
    fi
    if [[ -n "$OUTPUT_HTML" ]]; then
        write_html "$body" >| "$OUTPUT_HTML"
        print_info "HTML report: $OUTPUT_HTML"
    fi
    if [[ -n "$OUTPUT_PDF" ]]; then
        write_pdf "$body"
    fi
}

# Put the file of the variable $1 below OUTPUT_DIR if its path is relative,
# and create its directory. An absolute path stays. An existing file gets a
# number: a-1.pdf, a-2.pdf. Without a file name, the
# name comes from the owner (and repository) and --packages, with the
# extension $2: "^typo3/cms-core$" gives dmind-gmbh_typo3-cms-core.pdf.
output_path() {
    local path="${!1}"
    if [[ -z "$path" ]]; then
        return 0
    fi
    if [[ "$path" == "$OUTPUT_DEFAULT" ]]; then
        local packages="$PACKAGES"
        if [[ "$packages" == "." ]]; then
            packages="all-packages"
        fi
        path=$(printf '%s_%s' "$OWNER${REPO:+_$REPO}" "$packages" | awk '{
            gsub(/[^A-Za-z0-9._-]+/, "-"); gsub(/-+/, "-"); gsub(/^[-.]+|-+$/, ""); gsub(/-_|_-/, "_"); print }').$2
    fi
    if [[ "$path" != /* ]]; then
        path="$OUTPUT_DIR/$path"
    fi
    # Short option: BSD mkdir (macOS) has no --parents.
    mkdir -p "$(dirname "$path")"
    # Do not overwrite a file: a.pdf, then a-1.pdf, a-2.pdf.
    local base="$path" extension="" number=1 file="${path##*/}"
    if [[ "$file" == ?*.* ]]; then
        base="${path%.*}" extension=".${path##*.}"
    fi
    while [[ -e "$path" ]]; do
        path="$base-$number$extension"
        number=$((number + 1))
    done
    printf -v "$1" '%s' "$path"
}

# Print the command line of the scan below a divider, as the summary.
command_section() {
    echo ""
    echo "================================================================================"
    echo "${1:-}Command line:${2:-}"
    printf '  %s %s\n' "$0" "$SCAN_ARGUMENTS"
}

strip_colors() {
    awk -v esc="$(printf '\033')" '{ gsub(esc "\\[[0-9;]*m", ""); print }'
}

# Escape the text $1 for a Markdown table cell.
markdown_cell() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//|/\\|}"
    text="${text//\*/\\*}"
    text="${text//\`/\\\`}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    printf '%s' "$text"
}

# Print the results as Markdown: a table per group, then the summary of the
# text $1 (print_results). Uses the rows and columns of print_results.
write_markdown() {
    printf '# gh-dep-scanner: %s\n\n' "$OWNER"
    printf '%s UTC\n' "$(date -u '+%Y-%m-%d %H:%M')"

    local dep_file_name header="| Repository |" line="|---|" i group="" row_group
    dep_file_name=$(dep_file_names)
    if show_branch_column; then
        header+=" Branch |"
        line+="---|"
    fi
    if show_path_column; then
        header+=" Path |"
        line+="---|"
    fi
    header+=" Package | Version |"
    line+="---|---|"
    if [[ $SHOW_VISIBILITY -eq 1 ]]; then
        header+=" Visibility |"
        line+="---|"
    fi
    if [[ -n "$AFFECTED" ]]; then
        header+=" Affected |"
        line+="---|"
    fi

    ordered_rows
    for i in $ORDERED_ROWS; do
        case "${RESULT_STATUS[$i]}" in
            affected | not_affected | unchecked | found) row_group="Found" ;;
            filename_match) row_group="File name match ($(markdown_cell "$FILENAME_MATCH"))" ;;
            not_in_file) row_group="Package not found" ;;
            no_file) row_group="Version file not found (${dep_file_name// /, })" ;;
            *) row_group="Parse error" ;;
        esac
        if [[ $GROUP_BY_AFFECTED -eq 1 ]]; then
            case "${RESULT_STATUS[$i]}" in
                affected) row_group="Affected" ;;
                unchecked) row_group="Not checked (no version range)" ;;
                not_affected) row_group="Not affected" ;;
            esac
        fi
        if [[ "$row_group" != "$group" ]]; then
            group="$row_group"
            printf '\n## %s\n\n%s\n%s\n' "$group" "$header" "$line"
        fi
        local url="${RESULT_URLS[$i]}" row path="${RESULT_PATHS[$i]}"
        row="| [$(markdown_cell "${url##*/}")]($url) |"
        if show_branch_column; then
            branch_label "${RESULT_BRANCHES[$i]}" "${RESULT_BRANCH_STATUS[$i]}"
            row+=" $(markdown_cell "$BRANCH_LABEL") |"
        fi
        if show_path_column; then
            if [[ ${RESULT_CONFLICT[$i]} -eq 1 ]]; then
                path+="!"
            fi
            row+=" $(markdown_cell "$path") |"
        fi
        row+=" $(markdown_cell "${RESULT_PACKAGES[$i]}") | $(markdown_cell "${RESULT_VERSIONS[$i]}") |"
        if [[ $SHOW_VISIBILITY -eq 1 ]]; then
            row+=" ${RESULT_VISIBILITY[$i]} |"
        fi
        if [[ -n "$AFFECTED" ]]; then
            case "${RESULT_STATUS[$i]}" in
                affected) row+=" yes |" ;;
                not_affected) row+=" no |" ;;
                unchecked) row+=" ? |" ;;
                *) row+=" |" ;;
            esac
        fi
        printf '%s\n' "$row"
    done

    # The summary of the text, as a list.
    printf '\n## Summary\n\n'
    printf '%s\n' "$1" | strip_colors | awk '
        /^Summary:/ { summary = 1; next }
        summary && /^  - / { sub(/^  - /, "- "); print; next }
        summary && /[^ =]/ { print "\n**" $0 "**" }'

    printf '\n## Command line\n\n```sh\n%s %s\n```\n' "$0" "$SCAN_ARGUMENTS"
}

# Print the results as HTML on a white page: the text $1 (print_results)
# with its colors.
write_html() {
    cat << EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>gh-dep-scanner: $OWNER</title>
<style>
body { background: #fff; color: #1a1a1a; margin: 24px; font-family: sans-serif; }
p { font-size: 13px; color: #555; }
pre { font: 12px/1.35 Menlo, Consolas, "DejaVu Sans Mono", monospace; }
/* A long command line must not run off the page. */
pre.command { white-space: pre-wrap; overflow-wrap: anywhere; }
a { color: inherit; }
.red { color: #c00000; }
.green { color: #0a7a0a; }
.yellow { color: #a35b00; }
.blue { color: #1f4fd1; }
.magenta { color: #8e2a8e; }
.cyan { color: #00707a; }
.bold { font-weight: bold; }
.dim { color: #777; }
.underline { text-decoration: underline; }
/* 160 columns fit on a landscape A4 page. */
@page { size: A4 landscape; margin: 12mm; }
@media print { body { margin: 0; } pre { font-size: 9.5px; } }
</style>
</head>
<body>
<p>gh-dep-scanner, $(date -u '+%Y-%m-%d %H:%M') UTC</p>
<pre>
EOF
    printf '%s\n' "$1" | ansi_to_html
    printf '</pre>\n<pre class="command">'
    command_section "$BOLD" "$NC" | ansi_to_html
    printf '</pre>\n</body>\n</html>\n'
}

# Print the path of Chromium or Google Chrome: $CHROMIUM, a command, or the
# app on macOS. Fails if there is none.
find_chromium() {
    local name
    if [[ -n "${CHROMIUM:-}" ]]; then
        echo "$CHROMIUM"
        return 0
    fi
    for name in chromium chromium-browser google-chrome google-chrome-stable; do
        if command -v "$name" 2>/dev/null; then
            return 0
        fi
    done
    for name in "/Applications/Chromium.app/Contents/MacOS/Chromium" "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
        if [[ -x "$name" ]]; then
            echo "$name"
            return 0
        fi
    done
    return 1
}

# Write OUTPUT_PDF: the HTML of the text $1, printed by a headless Chromium
# with a profile of its own.
write_pdf() {
    local browser
    if ! browser=$(find_chromium); then
        print_error "--output-pdf needs Chromium or Google Chrome. Set CHROMIUM=<path> to use another one."
        return 1
    fi
    local pdf="$OUTPUT_PDF"
    if [[ "$pdf" != /* ]]; then
        pdf="$PWD/$pdf"
    fi
    # Next to the PDF, not in /tmp: a snap Chromium cannot read the /tmp of the system.
    local html="${pdf%.pdf}.tmp.$$.html" profile output status=0
    write_html "$1" >| "$html"
    profile=$(mktemp -d)
    rm -f "$pdf"
    log INFO "PDF: $browser --headless --print-to-pdf=$pdf"
    output=$("$browser" --headless --disable-gpu --user-data-dir="$profile" --no-pdf-header-footer \
        --print-to-pdf="$pdf" "file://$(url_encode "$html")" 2>&1) || status=$?
    # Short options: BSD rm (macOS) has no long options.
    rm -f "$html"
    rm -r -f "$profile"
    if [[ $status -ne 0 || ! -s "$pdf" ]]; then
        log ERROR "PDF failed (exit $status): $output"
        print_error "Failed to write $OUTPUT_PDF with $browser (exit $status). See the log."
        return 1
    fi
    print_info "PDF report: $OUTPUT_PDF"
}

# Convert the color codes of lib/config.sh to spans with the classes of
# write_html. Escape the text for HTML, and make the URLs links.
ansi_to_html() {
    awk -v esc="$(printf '\033')" '
        function html(text) {
            gsub(/&/, "\\&amp;", text); gsub(/</, "\\&lt;", text); gsub(/>/, "\\&gt;", text)
            return text
        }
        function linked(text,   out, url) {
            out = ""
            while (match(text, /https?:\/\/[^ ]+/)) {
                url = substr(text, RSTART, RLENGTH)
                out = out substr(text, 1, RSTART - 1) "<a href=\"" url "\">" url "</a>"
                text = substr(text, RSTART + RLENGTH)
            }
            return out text
        }
        function class_of(code) {
            if (code == "0;31") return "red"
            if (code == "1;31") return "red bold"
            if (code == "0;32") return "green"
            if (code == "1;32") return "green bold"
            if (code == "1;33") return "yellow bold"
            if (code == "0;34") return "blue"
            if (code == "0;35") return "magenta"
            if (code == "1;35") return "magenta bold"
            if (code == "0;36") return "cyan"
            if (code == "1") return "bold"
            if (code == "2") return "dim"
            if (code == "4") return "underline"
            return ""
        }
        {
            # A span ends with its line and starts again on the next one.
            if (class != "") printf "<span class=\"%s\">", class
            count = split($0, part, esc)
            printf "%s", linked(html(part[1]))
            for (i = 2; i <= count; i++) {
                code = ""; rest = part[i]
                if (match(part[i], /^\[[0-9;]*m/)) {
                    code = substr(part[i], 2, RLENGTH - 2)
                    rest = substr(part[i], RLENGTH + 1)
                }
                if (class != "") printf "</span>"
                class = class_of(code)
                if (class != "") printf "<span class=\"%s\">", class
                printf "%s", linked(html(rest))
            }
            if (class != "") printf "</span>"
            printf "\n"
        }'
}
