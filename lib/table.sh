# shellcheck shell=bash
# Sourced by gh-dep-scanner.sh: The result table and the summary.

# Print $2 in lines of at most $1 characters. Break at spaces where possible.
wrap_text() {
    local width="$1" text="$2" line="" word
    # A width below 1 would never end the loop below.
    if [[ $width -lt 1 ]]; then
        width=1
    fi
    if [[ ${#text} -le $width ]]; then
        echo "$text"
        return
    fi
    # read, not "for word in $text": a version like "3.*" must not glob.
    local -a words
    read -r -a words <<< "$text"
    for word in "${words[@]}"; do
        while [[ ${#word} -gt $width ]]; do
            if [[ -n "$line" ]]; then
                echo "$line"
                line=""
            fi
            echo "${word:0:$width}"
            word="${word:$width}"
        done
        if [[ -z "$line" ]]; then
            line="$word"
        elif [[ $((${#line} + 1 + ${#word})) -le $width ]]; then
            line="$line $word"
        else
            echo "$line"
            line="$word"
        fi
    done
    if [[ -n "$line" ]]; then
        echo "$line"
    fi
}

# Like wrap_text, but break a path after a "/".
wrap_path() {
    local width="$1" rest="$2" line="" part
    # A width below 1 would never end the loop below.
    if [[ $width -lt 1 ]]; then
        width=1
    fi
    while [[ -n "$rest" ]]; do
        if [[ "$rest" == */* ]]; then
            part="${rest%%/*}/"
            rest="${rest#*/}"
        else
            part="$rest"
            rest=""
        fi
        if [[ -n "$line" && $((${#line} + ${#part})) -gt $width ]]; then
            echo "$line"
            line=""
        fi
        line+="$part"
        # A part that is longer than the line is split.
        while [[ ${#line} -gt $width ]]; do
            echo "${line:0:$width}"
            line="${line:$width}"
        done
    done
    echo "$line"
}

# Column widths, set by set_column_widths.
URL_COLUMN_WIDTH=55
VERSION_COLUMN_WIDTH=15
PATH_COLUMN_WIDTH=4
BRANCH_COLUMN_WIDTH=6
PACKAGE_COLUMN_WIDTH=7

# Fit the columns to the longest values and to the terminal width.
# If the row is too wide, fit_columns chooses the widths.
set_column_widths() {
    local i width url_width=8 version_width=7 path_width=0 branch_width=0 package_width=7
    for i in "${!RESULT_STATUS[@]}"; do
        # A hidden row must not widen a column.
        if ! row_shown "$i"; then
            continue
        fi
        if [[ ${#RESULT_URLS[$i]} -gt $url_width ]]; then
            url_width=${#RESULT_URLS[$i]}
        fi
        if [[ ${#RESULT_VERSIONS[$i]} -gt $version_width ]]; then
            version_width=${#RESULT_VERSIONS[$i]}
        fi
        # The "!" of a lock file conflict (see print_row).
        width=${#RESULT_PATHS[$i]}
        if [[ ${RESULT_LOCK_CONFLICT[$i]} -eq 1 ]]; then
            width=$((width + 1))
        fi
        if show_path_column && [[ $width -gt $path_width ]]; then
            path_width=$width
        fi
        # The branch with its status, as print_row shows it.
        if show_branch_column; then
            branch_label "${RESULT_BRANCHES[$i]}" "${RESULT_BRANCH_STATUS[$i]}"
            if [[ ${#BRANCH_LABEL} -gt $branch_width ]]; then
                branch_width=${#BRANCH_LABEL}
            fi
        fi
        if [[ ${#RESULT_PACKAGES[$i]} -gt $package_width ]]; then
            package_width=${#RESULT_PACKAGES[$i]}
        fi
    done

    # Space for the cells: the terminal width minus the gaps and the visibility.
    # Keep the last column free: some terminals wrap a line that fills it.
    local available=$((TERM_COLUMNS - 3))
    # The " *" of an affected row.
    if [[ -n "$AFFECTED" ]]; then
        available=$((available - 2))
    fi
    if show_path_column; then
        available=$((available - 1))
        if [[ $path_width -lt 4 ]]; then
            path_width=4
        fi
    fi
    if show_branch_column; then
        available=$((available - 1))
        if [[ $branch_width -lt 6 ]]; then
            branch_width=6
        fi
    fi
    if [[ $SHOW_VISIBILITY -eq 1 ]]; then
        available=$((available - 11))
    fi

    if [[ $((url_width + branch_width + path_width + package_width + version_width)) -gt $available ]]; then
        read -r url_width branch_width path_width package_width version_width < <(fit_columns "$available" \
            "$url_width" "$branch_width" "$path_width" "$package_width" "$version_width")
    fi

    URL_COLUMN_WIDTH=$url_width
    VERSION_COLUMN_WIDTH=$version_width
    PATH_COLUMN_WIDTH=$path_width
    BRANCH_COLUMN_WIDTH=$branch_width
    PACKAGE_COLUMN_WIDTH=$package_width
}

# Print the column widths "url branch path package version" for the shown
# rows with the fewest lines in the table, as print_row prints them:
# a URL or branch that is too wide gets its own line, a path or package wraps
# after a "/", a version at spaces. $1: the space for the cells, $2-$6: the
# widest values. Tries the 8 largest widths that occur in each of the URL,
# branch and path columns. Package and version get the rest.
fit_columns() {
    local i
    # Identical rows are counted once, with their number.
    # Short option: BSD uniq (macOS) has no --count.
    for i in "${!RESULT_STATUS[@]}"; do
        if ! row_shown "$i"; then
            continue
        fi
        local path="" label=""
        if show_path_column; then
            path="${RESULT_PATHS[$i]}"
            if [[ ${RESULT_LOCK_CONFLICT[$i]} -eq 1 ]]; then
                path+="!"
            fi
        fi
        if show_branch_column; then
            branch_label "${RESULT_BRANCHES[$i]}" "${RESULT_BRANCH_STATUS[$i]}"
            label="$BRANCH_LABEL"
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "${#RESULT_URLS[$i]}" "${#label}" "$path" "${RESULT_PACKAGES[$i]}" "${RESULT_VERSIONS[$i]}"
    done | sort | uniq -c | awk -v available="$1" -v columns="$TERM_COLUMNS" \
        -v max_url="$2" -v max_branch="$3" -v max_path="$4" -v max_package="$5" -v max_version="$6" \
        -v show_branch="$(show_branch_column && echo 1 || echo 0)" -v show_path="$(show_path_column && echo 1 || echo 0)" '
        # The lines of wrap_path.
        function path_lines(text, width,   key, n, used, rest, part, slash) {
            key = text SUBSEP width
            if (key in PATH_LINES) return PATH_LINES[key]
            n = 0; used = 0; rest = text
            while (rest != "") {
                slash = index(rest, "/")
                if (slash > 0) { part = substr(rest, 1, slash); rest = substr(rest, slash + 1) }
                else { part = rest; rest = "" }
                if (used > 0 && used + length(part) > width) { n++; used = 0 }
                used += length(part)
                while (used > width) { n++; used -= width }
            }
            return PATH_LINES[key] = n + 1
        }
        # The lines of wrap_text.
        function text_lines(text, width,   key, n, words, count, j, word, line) {
            if (length(text) <= width) return 1
            key = text SUBSEP width
            if (key in TEXT_LINES) return TEXT_LINES[key]
            n = 0; line = ""
            count = split(text, words, " ")
            for (j = 1; j <= count; j++) {
                word = words[j]
                while (length(word) > width) {
                    if (line != "") { n++; line = "" }
                    n++; word = substr(word, width + 1)
                }
                if (line == "") line = word
                else if (length(line) + 1 + length(word) <= width) line = line " " word
                else { n++; line = word }
            }
            if (line != "") n++
            return TEXT_LINES[key] = n
        }
        # The 8 largest values of list[1..n] from at least low, and low: in LIST, largest first.
        function candidates(list, n, low,   seen, i, j, k, value, tmp) {
            delete LIST; k = 0
            for (i = 1; i <= n; i++) {
                value = list[i]
                if (value > low && !(value in seen)) { seen[value] = 1; LIST[++k] = value }
            }
            for (i = 2; i <= k; i++) for (j = i; j > 1 && LIST[j] > LIST[j - 1]; j--) { tmp = LIST[j]; LIST[j] = LIST[j - 1]; LIST[j - 1] = tmp }
            if (k > 8) k = 8
            LIST[++k] = low
            return k
        }
        {
            # "uniq -c": the number, then the fields of the row.
            count = $1; line = $0; sub(/^ *[0-9]+ /, "", line)
            split(line, field, "\t")
            rows++; WEIGHT[rows] = count + 0
            URL[rows] = field[1] + 0; BRANCH[rows] = field[2] + 0
            PATH[rows] = field[3]; PACKAGE[rows] = field[4]; VERSION[rows] = field[5]
            urls[rows] = URL[rows]; branches[rows] = BRANCH[rows]; paths[rows] = length(PATH[rows])
        }
        END {
            min_url = max_url < 20 ? max_url : 20
            min_branch = max_branch < 12 ? max_branch : 12
            min_path = max_path < 12 ? max_path : 12
            min_package = max_package < 12 ? max_package : 12
            min_version = max_version < 10 ? max_version : 10
            nu = candidates(urls, rows, min_url); for (i = 1; i <= nu; i++) CU[i] = LIST[i]
            nb = 1; CB[1] = max_branch
            if (show_branch) { nb = candidates(branches, rows, min_branch); for (i = 1; i <= nb; i++) CB[i] = LIST[i] }
            np = 1; CP[1] = max_path
            if (show_path) { np = candidates(paths, rows, min_path); for (i = 1; i <= np; i++) CP[i] = LIST[i] }

            best = -1
            for (a = 1; a <= nu; a++) for (b = 1; b <= nb; b++) for (c = 1; c <= np; c++) {
                u = CU[a]; w = CB[b]; p = CP[c]
                rest = available - u - w - p
                # Shrink the package first, or the version first.
                for (m = 1; m <= 2; m++) {
                    k = max_package; v = max_version
                    if (k + v <= rest) {
                        if (m == 2) continue
                    } else if (m == 1) {
                        k = rest - v
                        if (k < min_package) { k = min_package; v = rest - k }
                    } else {
                        v = rest - k
                        if (v < min_version) { v = min_version; k = rest - v }
                    }
                    if (k < min_package || v < min_version) continue
                    total = 0
                    for (r = 1; r <= rows && (best < 0 || total < best); r++) {
                        cells = text_lines(VERSION[r], v)
                        n = path_lines(PACKAGE[r], k); if (n > cells) cells = n
                        if (show_path) { n = path_lines(PATH[r], p); if (n > cells) cells = n }
                        extra = URL[r] > u
                        # In the PATH column of a row without a path, see print_row.
                        if (show_branch && BRANCH[r] > w && !(show_path && PATH[r] == "" && BRANCH[r] <= w + 1 + p)) {
                            # On the line of the URL if it fits there, else on a line of its own.
                            extra = (!extra && u + 1 + BRANCH[r] <= columns - 1) ? 1 : 2
                        }
                        total += WEIGHT[r] * (extra + cells)
                    }
                    if (best < 0 || total < best) { best = total; result = u " " w " " p " " k " " v }
                }
            }
            if (best < 0) result = min_url " " min_branch " " min_path " " min_package " " min_version
            print result
        }'
}

# The BRANCH column: only with --branches.
show_branch_column() {
    [[ -n "$BRANCHES" ]]
}

# The PATH column shows where the file was found: with --alternativePaths, and
# with --type=node, where a directory can have package-lock.json and yarn.lock.
show_path_column() {
    [[ ( -n "$ALTERNATIVE_PATHS" || "$TYPE" == "node" ) && $PATHS_HIDDEN -eq 0 ]]
}

# True if row $1 is printed: --hide-unknown and --hide-absent hide rows.
# The summary still counts the hidden rows.
row_shown() {
    case "${RESULT_STATUS[$1]}" in
        no_file) [[ $HIDE_UNKNOWN -eq 0 ]] ;;
        not_in_file) [[ $HIDE_ABSENT -eq 0 ]] ;;
        *) return 0 ;;
    esac
}

# --hide-path: clear the path of the rows of each branch with only one
# shown dependency file. Without any path left, the PATH column goes.
hide_single_paths() {
    if [[ $HIDE_PATH -eq 0 ]]; then
        return 0
    fi
    local i
    # One awk for all rows: bash 3.2 has no associative arrays.
    # RESULT_STATUS is added last: after an interrupt, the other arrays can be longer.
    while IFS= read -r i; do
        RESULT_PATHS[i]=""
    done < <(for i in "${!RESULT_STATUS[@]}"; do
            if row_shown "$i"; then
                printf '%s\t%s\t%s\t%s\n' "$i" "${RESULT_URLS[$i]}" "${RESULT_BRANCHES[$i]}" "${RESULT_PATHS[$i]}"
            fi
        done | awk -F '\t' '
            $4 != "" { row[NR] = $1; key[NR] = $2 "\t" $3; if (!seen[$2 "\t" $3 "\t" $4]++) paths[$2 "\t" $3]++ }
            END { for (n in row) if (paths[key[n]] == 1) print row[n] }')
    PATHS_HIDDEN=1
    for i in "${!RESULT_STATUS[@]}"; do
        if row_shown "$i" && [[ -n "${RESULT_PATHS[$i]}" ]]; then
            PATHS_HIDDEN=0
            break
        fi
    done
}

# Set BRANCH_LABEL to branch $1 with its status $2: "main *" for the default
# branch, "feat/x (+3/-2)" for 3 commits ahead and 2 behind, "feat/x (?)".
# A variable, not output: no subshell for each row.
branch_label() {
    case "$2" in
        "") BRANCH_LABEL="$1" ;;
        default) BRANCH_LABEL="$1 *" ;;
        "?") BRANCH_LABEL="$1 (?)" ;;
        *) BRANCH_LABEL="$1 (+${2%/*}/-${2#*/})" ;;
    esac
}

# Arguments: color, URL, branch, branch status (see branch_label), path, package, version,
# visibility, and optionally the color of the version, a mark for the end
# of the row and 1 for a lock file conflict (a yellow "!" after the path).
# A path, package or version that is too wide wraps and stays in its column.
# A URL never wraps: a line break makes it unclickable. A URL that is too
# wide gets its own line, and the other cells start on the next line.
# A branch does not wrap either: a branch that is too wide uses the empty
# PATH cell of its row, or gets a line of its own, from the branch column on,
# or further left if the line is too short.
print_row() {
    local row_color="$1" url="$2" branch="$3" branch_status="$4" path="$5" package="$6"
    local version="$7" visibility="$8" version_color_arg="${9:-}" mark="${10:-}" lock_conflict="${11:-0}"
    # The URL has the color of the group, the other cells the color of their column.
    # The header (bold) and the dashes (no color) have one color for all cells.
    local branch_color="$COLOR_BRANCH" path_color="$COLOR_PATH" package_color="$COLOR_PACKAGE"
    local version_color="${version_color_arg:-$COLOR_VERSION}" visibility_color="$COLOR_VISIBILITY"
    if [[ -z "$row_color" || "$row_color" == "$BOLD" ]]; then
        branch_color="$row_color" path_color="$row_color" package_color="$row_color" version_color="$row_color" visibility_color="$row_color"
    fi
    # Before the width checks: set_column_widths counts the label too.
    if [[ -n "$branch_status" ]]; then
        branch_label "$branch" "$branch_status"
        branch="$BRANCH_LABEL"
        if [[ "$branch_status" == "default" && -n "$row_color" && "$row_color" != "$BOLD" ]]; then
            branch_color="$COLOR_DEFAULT_BRANCH"
        fi
    fi

    local -a url_lines=("$url") branch_lines=() path_lines=() package_lines=() version_lines=()
    local line cell
    if [[ ${#url} -gt $URL_COLUMN_WIDTH ]]; then
        printf "%s%s%s\n" "$row_color" "$url" "$NC"
        url_lines=("")
    fi
    # A branch that is too wide can use the PATH column of a row without a path.
    local spill=0
    if show_branch_column && show_path_column && [[ -z "$path" && ${#branch} -gt $BRANCH_COLUMN_WIDTH &&
        ${#branch} -le $((BRANCH_COLUMN_WIDTH + 1 + PATH_COLUMN_WIDTH)) ]]; then
        spill=1
    fi
    if [[ $spill -eq 1 ]]; then
        branch_lines=("$branch")
    elif show_branch_column && [[ ${#branch} -gt $BRANCH_COLUMN_WIDTH ]]; then
        # Keep the last column free, as in set_column_widths.
        local start=$((URL_COLUMN_WIDTH + 1)) latest=$((TERM_COLUMNS - 1 - ${#branch}))
        if [[ -n "${url_lines[0]}" && $start -le $latest ]]; then
            printf -v cell "%-*s" "$URL_COLUMN_WIDTH" "$url"
            printf "%s%s%s %s%s%s\n" "$row_color" "$cell" "$NC" "$branch_color" "$branch" "$NC"
        else
            if [[ -n "${url_lines[0]}" ]]; then
                printf "%s%s%s\n" "$row_color" "$url" "$NC"
            fi
            if [[ $start -gt $latest ]]; then
                start=$latest
            fi
            if [[ $start -lt 0 ]]; then
                start=0
            fi
            printf "%*s%s%s%s\n" "$start" "" "$branch_color" "$branch" "$NC"
        fi
        url_lines=("")
        branch_lines=("")
    elif show_branch_column; then
        branch_lines=("$branch")
    fi
    # Before the width checks: set_column_widths counts the "!" too.
    if [[ $lock_conflict -eq 1 ]]; then
        path+="!"
    fi
    # A cell that fits needs no wrap: no subshell for most rows.
    if ! show_path_column; then
        :
    elif [[ ${#path} -le $PATH_COLUMN_WIDTH ]]; then
        path_lines=("$path")
    else
        while IFS= read -r line; do
            path_lines+=("$line")
        done < <(wrap_path "$PATH_COLUMN_WIDTH" "$path")
    fi
    if [[ ${#package} -le $PACKAGE_COLUMN_WIDTH ]]; then
        package_lines=("$package")
    else
        while IFS= read -r line; do
            package_lines+=("$line")
        done < <(wrap_path "$PACKAGE_COLUMN_WIDTH" "$package")
    fi
    if [[ ${#version} -le $VERSION_COLUMN_WIDTH ]]; then
        version_lines=("$version")
    else
        while IFS= read -r line; do
            version_lines+=("$line")
        done < <(wrap_text "$VERSION_COLUMN_WIDTH" "$version")
    fi

    local count=${#url_lines[@]}
    if show_branch_column && [[ ${#branch_lines[@]} -gt $count ]]; then
        count=${#branch_lines[@]}
    fi
    if show_path_column && [[ ${#path_lines[@]} -gt $count ]]; then
        count=${#path_lines[@]}
    fi
    if [[ ${#package_lines[@]} -gt $count ]]; then
        count=${#package_lines[@]}
    fi
    if [[ ${#version_lines[@]} -gt $count ]]; then
        count=${#version_lines[@]}
    fi

    # Pad first, then color: the color codes have no width.
    local i row
    for ((i = 0; i < count; i++)); do
        printf -v cell "%-*s" "$URL_COLUMN_WIDTH" "${url_lines[$i]:-}"
        row="$row_color$cell$NC"
        if [[ $spill -eq 1 && $i -eq 0 ]]; then
            printf -v cell "%-*s" "$((BRANCH_COLUMN_WIDTH + 1 + PATH_COLUMN_WIDTH))" "${branch_lines[$i]:-}"
            row+=" $branch_color$cell$NC"
        elif show_branch_column; then
            printf -v cell "%-*s" "$BRANCH_COLUMN_WIDTH" "${branch_lines[$i]:-}"
            row+=" $branch_color$cell$NC"
        fi
        if show_path_column && ! [[ $spill -eq 1 && $i -eq 0 ]]; then
            printf -v cell "%-*s" "$PATH_COLUMN_WIDTH" "${path_lines[$i]:-}"
            # Pad first, then color the "!": the color codes have no width.
            if [[ $lock_conflict -eq 1 && "${path_lines[$i]:-}" == *"!" && $((i + 1)) -eq ${#path_lines[@]} ]]; then
                local text="${path_lines[$i]%!}"
                cell="$text$YELLOW!$NC$path_color${cell:$((${#text} + 1))}"
            fi
            row+=" $path_color$cell$NC"
        fi
        # Color the text only: an underline must not run over the padding.
        local package_text="${package_lines[$i]:-}"
        printf -v cell "%-*s" "$PACKAGE_COLUMN_WIDTH" ""
        row+=" $package_color$package_text$NC${cell:${#package_text}}"
        if [[ $SHOW_VISIBILITY -eq 1 ]]; then
            printf -v cell "%-*s" "$VERSION_COLUMN_WIDTH" "${version_lines[$i]:-}"
            row+=" $version_color$cell$NC"
            if [[ $i -eq 0 ]]; then
                row+=" $visibility_color$visibility$NC"
            fi
        else
            row+=" $version_color${version_lines[$i]:-}$NC"
        fi
        if [[ $i -eq 0 && -n "${mark:-}" ]]; then
            row+=" $COLOR_AFFECTED$mark$NC"
        fi
        printf "%s\n" "$row"
    done
}

print_results() {
    local dep_file_name no_file_group
    dep_file_name=$(dep_file_names)
    no_file_group="VERSION FILE NOT FOUND (${dep_file_name// /, })"
    dep_file_name="${dep_file_name// / or }"

    echo ""
    printf '%s\n' "${BOLD}Results: ${NC}$(packages_label)${BOLD} in repositories${NC}${AFFECTED:+ (affected: ${COLOR_VERSION}$AFFECTED${NC})}"
    echo "================================================================================"
    echo ""

    # Print header
    hide_single_paths
    set_column_widths
    print_row "$BOLD" "REPO URL" "BRANCH" "" "PATH" "PACKAGE" "VERSION" "VISIBILITY"
    print_row "" "--------" "------" "" "----" "-------" "-------" "----------"

    local has_results=0

    # Sort the rows by URL, branch, path and package. The index is the last field.
    # The default branch first: "0" before its name, "1" before the others.
    local sorted_rows
    # RESULT_STATUS is added last: after an interrupt, the other arrays can be longer.
    sorted_rows=$(for i in "${!RESULT_STATUS[@]}"; do
        first=1
        if [[ "${RESULT_BRANCH_STATUS[$i]}" == "default" ]]; then
            first=0
        fi
        echo "${RESULT_URLS[$i]} $first${RESULT_BRANCHES[$i]} ${RESULT_PATHS[$i]} ${RESULT_PACKAGES[$i]} $i"
    done | sort --ignore-case | awk '{ print $NF }')

    # Group the rows: version found, package not found, no file, parse error.
    # A string, not an array: an empty array fails with nounset in bash 3.2 (macOS).
    local ordered_rows="" wanted_status i
    for wanted_status in found not_in_file no_file error; do
        # See row_shown.
        if [[ ("$wanted_status" == "no_file" && $HIDE_UNKNOWN -eq 1) || ("$wanted_status" == "not_in_file" && $HIDE_ABSENT -eq 1) ]]; then
            continue
        fi
        for i in $sorted_rows; do
            # FOUND has all rows with a version, affected by --affected or not.
            if [[ "${RESULT_STATUS[$i]}" == "$wanted_status" || ( "$wanted_status" == "found" && "${RESULT_STATUS[$i]}" == *affected ) ]]; then
                ordered_rows+=" $i"
            fi
        done
    done

    local group="" row_group
    for i in $ordered_rows; do
        local status="${RESULT_STATUS[$i]}"
        local url="${RESULT_URLS[$i]}"
        local version="${RESULT_VERSIONS[$i]}"
        local visibility="${RESULT_VISIBILITY[$i]}"
        local path="${RESULT_PATHS[$i]}"
        local branch="${RESULT_BRANCHES[$i]}"
        local branch_status="${RESULT_BRANCH_STATUS[$i]}"
        local lock_conflict="${RESULT_LOCK_CONFLICT[$i]}"
        local package="${RESULT_PACKAGES[$i]}"

        case "$status" in
            affected | not_affected | found) row_group="FOUND" ;;
            not_in_file) row_group="PACKAGE NOT FOUND" ;;
            no_file) row_group="$no_file_group" ;;
            *) row_group="PARSE ERROR" ;;
        esac
        if [[ "$row_group" != "$group" ]]; then
            group="$row_group"
            echo ""
            printf '%s\n' "${BOLD}$group${NC}"
        fi

        # With --affected, the color of the version and a "*" at the end show
        # whether it is affected. Not affected rows do not count as results.
        if [[ "$status" == "affected" ]]; then
            print_row "$GREEN" "$url" "$branch" "$branch_status" "$path" "$package" "$version" "$visibility" "$COLOR_AFFECTED" "*" "$lock_conflict"
            has_results=1
        elif [[ "$status" == "not_affected" ]]; then
            print_row "$GREEN" "$url" "$branch" "$branch_status" "$path" "$package" "$version" "$visibility" "$COLOR_NOT_AFFECTED" "" "$lock_conflict"
        elif [[ "$status" == "found" ]]; then
            print_row "$GREEN" "$url" "$branch" "$branch_status" "$path" "$package" "$version" "$visibility" "" "" "$lock_conflict"
            has_results=1
        elif [[ "$status" == "no_file" || "$status" == "error" ]]; then
            print_row "$YELLOW" "$url" "$branch" "$branch_status" "$path" "$package" "$version" "$visibility" "" "" "$lock_conflict"
            has_results=1
        elif [[ "$status" == "not_in_file" ]]; then
            print_row "$CYAN" "$url" "$branch" "$branch_status" "$path" "$package" "$version" "$visibility" "" "" "$lock_conflict"
            has_results=1
        fi
    done

    if [[ ${#RESULT_STATUS[@]} -eq 0 && $SCAN_INTERRUPTED -eq 1 ]]; then
        printf '%s\n' "${YELLOW}No results yet.${NC}"
    elif [[ ${#RESULT_STATUS[@]} -eq 0 && $MERGED_COUNT -gt 0 ]]; then
        printf '%s\n' "${YELLOW}All matching branches are merged (hidden by --hide-merged).${NC}"
    elif [[ ${#RESULT_STATUS[@]} -eq 0 ]]; then
        printf '%s\n' "${YELLOW}No branch matches --branches '$BRANCHES'.${NC}"
    elif [[ $has_results -eq 0 ]]; then
        printf '%s\n' "${GREEN}No found package is affected.${NC}"
    fi

    # Summary
    echo ""
    echo "================================================================================"
    printf '%s\n' "${BOLD}Summary:${NC}"
    if [[ $SCAN_INTERRUPTED -eq 1 ]]; then
        echo "  - Total repos scanned: $((SCAN_POSITION - 1)) of $TOTAL_REPOS (stopped in repo $SCAN_POSITION)"
    else
        echo "  - Total repos scanned: $TOTAL_REPOS"
    fi
    if [[ -n "$REPO_FILTER" ]]; then
        echo "  - Repos not matching --repo: $FILTERED_OUT_COUNT"
    fi
    if [[ -n "$BRANCHES" ]]; then
        echo "  - Branches scanned: $BRANCHES_SCANNED"
        echo "  - Repos without a matching branch: $NO_BRANCH_COUNT"
        if [[ $HIDE_MERGED -eq 1 ]]; then
            echo "  - Merged branches: hidden ($MERGED_COUNT)"
        else
            echo "  - Merged branches: shown (hide them with --hide-merged)"
        fi
    fi
    if [[ -n "$ARCHIVED_COUNT" ]]; then
        echo "  - Archived repos: $ARCHIVED_COUNT"
    fi
    if [[ $OFFLINE -eq 1 ]]; then
        echo "  - Cache: offline (pushes are not checked)"
    else
        echo "  - Cache: $REFRESHED_COUNT repos with new pushes refreshed"
    fi
    # With --branches, the counts are per branch.
    local rows="Repos"
    if [[ -n "$BRANCHES" ]]; then
        rows="Branches"
    fi
    # A file can give several rows: count packages, not repositories.
    if [[ -n "$AFFECTED" ]]; then
        printf '%s\n' "  - Packages affected: ${RED}$AFFECTED_COUNT${NC}"
    else
        printf '%s\n' "  - Packages found: ${GREEN}$FOUND_COUNT${NC}"
    fi
    local unknown_note="" absent_note=""
    if [[ $HIDE_UNKNOWN -eq 1 ]]; then
        unknown_note=" (hidden)"
    fi
    if [[ $HIDE_ABSENT -eq 1 ]]; then
        absent_note=" (hidden)"
    fi
    printf '%s\n' "  - $rows without $dep_file_name: ${YELLOW}$NO_FILE_COUNT${NC}$unknown_note"
    if [[ $PARSE_ERROR_COUNT -gt 0 ]]; then
        printf '%s\n' "  - Dependency files that are not valid JSON: ${YELLOW}$PARSE_ERROR_COUNT${NC}"
    fi
    if [[ $LOCK_CONFLICT_COUNT -gt 0 ]]; then
        printf '%s\n' "  - Directories with package-lock.json and yarn.lock: ${YELLOW}$LOCK_CONFLICT_COUNT${NC}"
    fi
    printf '%s\n' "  - Files without $(packages_label): ${CYAN}$NOT_FOUND_COUNT${NC}$absent_note"

    local requests cache_hits oldest
    read -r requests cache_hits oldest <<< "$(awk '
        { requests++ }
        $1 == "cache" { hits++; if (oldest == "" || $2 < oldest) oldest = $2 }
        END { print requests + 0, hits + 0, oldest }
    ' "$REQUEST_LOG")"
    if [[ $cache_hits -gt 0 ]]; then
        echo "  - Requests served from the cache: $cache_hits of $requests (oldest entry: $(format_age $(($(date +%s) - oldest))) old)"
    else
        echo "  - Requests served from the cache: 0 of $requests"
    fi
    if [[ $OFFLINE -eq 0 ]]; then
        check_rate_limit
        echo "  - $(rate_limit_summary)"
    fi
    local complete="complete"
    if [[ $SCAN_INTERRUPTED -eq 1 ]]; then
        complete="NOT complete"
    fi
    log INFO "Done ($complete): ${#RESULT_STATUS[@]} rows, $AFFECTED_COUNT affected, $FOUND_COUNT found, $NO_FILE_COUNT without file, $PARSE_ERROR_COUNT parse errors, $NOT_FOUND_COUNT without package; $cache_hits of $requests requests from the cache"
    if [[ $SCAN_INTERRUPTED -eq 1 ]]; then
        echo ""
        printf '%s\n' "${RED}${BOLD}Scanning NOT complete.${NC}"
    fi
    echo ""
}
