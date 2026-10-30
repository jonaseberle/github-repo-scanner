# shellcheck shell=bash
# Sourced by gh-dep-scanner.sh: The scan of the repositories and branches: result rows.

# The number of the repository that is scanned now, for an interrupted scan.
SCAN_POSITION=0
SCAN_INTERRUPTED=0

# Ctrl-C during the scan shows the results so far. A second Ctrl-C stops at once.
# Called by a trap.
# shellcheck disable=SC2329
on_scan_interrupt() {
    trap - INT
    SCAN_INTERRUPTED=1
    log WARN "Interrupted (Ctrl-C) in repo $SCAN_POSITION/$TOTAL_REPOS: printing the results so far."
    clear_progress
    print_results
    write_outputs
    exit 130
}

# Classify a package version and add a result row.
# Arguments: URL, branch, path, visibility, package, and the version or
# NOT_FOUND (no file) / PARSE_ERROR / NOT_IN_FILE (no matching package) /
# FILENAME_MATCH:<number of files> / LISTED (a row of the list of repositories).
record_result() {
    local value="$6"

    local version_str status

    if [[ "$value" == "NOT_FOUND" ]]; then
        version_str="N/A"
        status="no_file"
        NO_FILE_COUNT=$((NO_FILE_COUNT + 1))
    elif [[ "$value" == "PARSE_ERROR" ]]; then
        version_str="Parse error"
        status="error"
        PARSE_ERROR_COUNT=$((PARSE_ERROR_COUNT + 1))
    elif [[ "$value" == "NOT_IN_FILE" ]]; then
        version_str="Not found"
        status="not_in_file"
        NOT_FOUND_COUNT=$((NOT_FOUND_COUNT + 1))
    elif [[ "$value" == FILENAME_MATCH:* ]]; then
        version_str="${value#*:} files"
        if [[ "$version_str" == "1 files" ]]; then
            version_str="1 file"
        fi
        status="filename_match"
        FILENAME_MATCH_COUNT=$((FILENAME_MATCH_COUNT + 1))
    elif [[ "$value" == "LISTED" ]]; then
        version_str=""
        status="listed"
    else
        version_str="$value"
        if [[ -z "$AFFECTED" ]]; then
            status="found"
            FOUND_COUNT=$((FOUND_COUNT + 1))
        else
            local affected=0
            is_affected "$version_str" || affected=$?
            case $affected in
                0) status="affected"; AFFECTED_COUNT=$((AFFECTED_COUNT + 1)) ;;
                1) status="not_affected" ;;
                *) status="unchecked"; UNCHECKED_COUNT=$((UNCHECKED_COUNT + 1)) ;;
            esac
        fi
    fi

    log DEBUG "Result: $1 branch=$2 path=$3 package=$5 version=$version_str status=$status"
    RESULT_URLS+=("$1")
    RESULT_BRANCHES+=("$2")
    RESULT_BRANCH_STATUS+=("$CURRENT_BRANCH_STATUS")
    RESULT_PATHS+=("$3")
    RESULT_CONFLICT+=(0)
    RESULT_VISIBILITY+=("$4")
    RESULT_PACKAGES+=("$5")
    RESULT_TOPICS+=("$CURRENT_TOPICS")
    RESULT_PUSHED+=("$CURRENT_PUSHED")
    RESULT_CREATED+=("$CURRENT_CREATED")
    RESULT_FIRST_AUTHOR+=("$CURRENT_FIRST_AUTHOR")
    RESULT_FIRST_COMMIT_DATE+=("$CURRENT_FIRST_COMMIT_DATE")
    RESULT_ARCHIVED+=("$CURRENT_ARCHIVED")
    RESULT_VERSIONS+=("$version_str")
    RESULT_STATUS+=("$status")
}

# Add one result row per matching package of a dependency file.
# Arguments: URL, branch, path, visibility, content (or NOT_FOUND)
record_file() {
    local content="$5"
    if [[ "$content" == "NOT_FOUND" ]]; then
        record_result "$1" "$2" "$3" "$4" "" "$content"
        return
    fi

    local listing packages name version
    if ! listing=$(list_packages "$content" "$TYPE" "$3"); then
        record_result "$1" "$2" "$3" "$4" "" "PARSE_ERROR"
        return
    fi
    packages=$(matching_packages "$listing")
    if [[ -z "$packages" ]]; then
        record_result "$1" "$2" "$3" "$4" "" "NOT_IN_FILE"
        return
    fi
    while IFS=$'\t' read -r name version; do
        record_result "$1" "$2" "$3" "$4" "$name" "$version"
    done <<< "$packages"
}

# Set RESULT_CONFLICT for the rows from number $1 on whose path is in
# one of the directories $2 (one per line).
mark_lock_conflicts() {
    local i dir
    for ((i = $1; i < ${#RESULT_STATUS[@]}; i++)); do
        dir="."
        if [[ "${RESULT_PATHS[$i]}" == */* ]]; then
            dir="${RESULT_PATHS[$i]%/*}"
        fi
        if [[ $'\n'"$2" == *$'\n'"$dir"$'\n'* ]]; then
            RESULT_CONFLICT[i]=1
        fi
    done
}

# True if a row from number $1 on has a version (FOUND).
rows_have_version() {
    local i
    for ((i = $1; i < ${#RESULT_STATUS[@]}; i++)); do
        case "${RESULT_STATUS[$i]}" in
            affected | not_affected | unchecked | found) return 0 ;;
        esac
    done
    return 1
}

# --filename-match, for a repository without a version: if a file of commit
# $4 of repository $3 matches, the rows of the branch from number $1 to $2
# (excluded) get the status "replaced" (not shown, not counted), and one
# FILENAME MATCH row replaces them: the first matching path up to the end of
# the match and its name (typo3conf/ENABLE_INSTALL_TOOL with "typo3conf/"
# gives typo3conf/), and the number of files. $5..$7: URL, branch and visibility.
filename_fallback() {
    local i matches count path rest
    # An assignment of its own: an error of filename_matches must stop the scan.
    matches=$(filename_matches "$3" "$4")
    if [[ -z "$matches" ]]; then
        return 0
    fi
    count=$(printf '%s\n' "$matches" | awk 'END { print NR }')
    for ((i = $1; i < $2; i++)); do
        case "${RESULT_STATUS[$i]}" in
            no_file) NO_FILE_COUNT=$((NO_FILE_COUNT - 1)) ;;
            not_in_file) NOT_FOUND_COUNT=$((NOT_FOUND_COUNT - 1)) ;;
            error) PARSE_ERROR_COUNT=$((PARSE_ERROR_COUNT - 1)) ;;
        esac
        RESULT_STATUS[i]="replaced"
    done
    path="${matches%%$'\n'*}"
    if [[ "$path" =~ $FILENAME_MATCH ]]; then
        rest="${path#*"${BASH_REMATCH[0]}"}"
        path="${path%%"${BASH_REMATCH[0]}"*}${BASH_REMATCH[0]}"
        # Up to the end of the name: "wp" in wordpress/wp-content/x gives
        # wordpress/wp-content/, not wordpress/wp.
        if [[ "$path" != */ && "$rest" == */* ]]; then
            path+="${rest%%/*}/"
        elif [[ "$path" != */ ]]; then
            path+="$rest"
        fi
    fi
    record_result "$5" "$6" "$path" "$7" "" "FILENAME_MATCH:$count"
}

# With nodeEngines: for each package.json row from number $1 on, find the
# .nvmrc or .node-version that nvm uses there: the nearest one in its
# directory or above (.nvmrc first). Mark both rows if its Node version is
# outside "engines.node". $2, $3: repository and branch, for the warning.
check_node_versions() {
    local i j dir best best_dir file candidate
    for ((j = $1; j < ${#RESULT_STATUS[@]}; j++)); do
        if [[ "${RESULT_PACKAGES[$j]}" != "node" || "${RESULT_PATHS[$j]##*/}" != "package.json" ]]; then
            continue
        fi
        dir="${RESULT_PATHS[$j]%package.json}"
        best="" best_dir=""
        for ((i = $1; i < ${#RESULT_STATUS[@]}; i++)); do
            file="${RESULT_PATHS[$i]##*/}"
            if [[ "${RESULT_PACKAGES[$i]}" != "node" || ( "$file" != ".nvmrc" && "$file" != ".node-version" ) ]]; then
                continue
            fi
            candidate="${RESULT_PATHS[$i]%"$file"}"
            # In the directory of package.json or above it.
            if [[ "$dir" != "$candidate"* ]]; then
                continue
            fi
            if [[ -z "$best" || ${#candidate} -gt ${#best_dir} || ( "$candidate" == "$best_dir" && "$file" == ".nvmrc" ) ]]; then
                best=$i best_dir="$candidate"
            fi
        done
        if [[ -z "$best" ]]; then
            continue
        fi
        # A value that is no version range (e.g. "lts/*") is not checked.
        range_parse "${RESULT_VERSIONS[$j]}" npm || continue
        range_keep other
        range_parse "${RESULT_VERSIONS[$best]}" npm || continue
        if ! range_overlaps other; then
            RESULT_CONFLICT[best]=1
            RESULT_CONFLICT[j]=1
            NODE_VERSION_CONFLICT_COUNT=$((NODE_VERSION_CONFLICT_COUNT + 1))
            print_warning_line "$OWNER/$2 ($3): ${RESULT_PATHS[$best]} has Node ${RESULT_VERSIONS[$best]}, outside \"engines\" ${RESULT_VERSIONS[$j]} of ${RESULT_PATHS[$j]}."
        fi
    done
}

scan_repos() {
    echo ""
    if [[ $LIST_ONLY -eq 1 ]]; then
        printf '%s\n' "${BOLD}Listing $OWNER repositories...${NC}"
    else
        printf '%s\n' "${BOLD}Scanning $OWNER repositories for ${NC}$(packages_label)${AFFECTED:+, affected: ${COLOR_VERSION}$AFFECTED${NC}}..."
    fi
    if [[ $LIST_ONLY -eq 1 ]]; then
        :
    elif [[ -n "$BRANCHES" ]]; then
        printf '%s\n' "Branches: matching ${COLOR_BRANCH}$BRANCHES${NC}"
    elif [[ -n "$BRANCH" ]]; then
        printf '%s\n' "Branch: ${COLOR_BRANCH}$BRANCH${NC}"
    else
        printf '%s\n' "Branch: ${COLOR_BRANCH}default${NC}"
    fi
    echo ""

    trap on_scan_interrupt INT

    local i=0 repo_name repo_url is_private is_archived topics pushed created default_branch
    while IFS=$'\t' read -r repo_name repo_url is_private is_archived topics pushed created default_branch; do
        i=$((i + 1))
        SCAN_POSITION=$i
        # Only --topics shows the topics.
        CURRENT_TOPICS=""
        if [[ $TOPICS_SHOW -eq 1 && "$topics" != "-" ]]; then
            CURRENT_TOPICS="$topics"
        fi
        CURRENT_PUSHED="${pushed#-}"
        CURRENT_CREATED=""
        if [[ $SHOW_CREATED -eq 1 ]]; then
            CURRENT_CREATED="${created/#-/?}"
        fi
        CURRENT_FIRST_AUTHOR="" CURRENT_FIRST_COMMIT_DATE=""
        if [[ $SHOW_FIRST_AUTHOR -eq 1 || $SHOW_FIRST_COMMIT_DATE -eq 1 ]]; then
            first_commit_labels "$repo_name"
            if [[ $SHOW_FIRST_AUTHOR -eq 1 ]]; then
                CURRENT_FIRST_AUTHOR="$FIRST_AUTHOR_LABEL"
            fi
            if [[ $SHOW_FIRST_COMMIT_DATE -eq 1 ]]; then
                CURRENT_FIRST_COMMIT_DATE="$FIRST_COMMIT_DATE"
            fi
        fi
        CURRENT_ARCHIVED=0
        if [[ "$is_archived" == "true" ]]; then
            CURRENT_ARCHIVED=1
        fi
        log INFO "Scanning repo $i/$TOTAL_REPOS: $repo_name"

        # Visibility
        local visibility
        if [[ "$is_private" == "true" ]]; then
            visibility="private"
        else
            visibility="public"
        fi

        # The list needs no request per repository.
        if [[ $LIST_ONLY -eq 1 ]]; then
            CURRENT_BRANCH_STATUS=""
            record_result "$repo_url" "" "" "$visibility" "" "LISTED"
            continue
        fi

        # Determine which branches to use
        local branches target_branch
        if [[ -n "$BRANCHES" ]]; then
            # The numbers first: a long name is cut at the end of the line.
            print_progress "" "Scanning repo: ($i/$TOTAL_REPOS) " "$CYAN" "$repo_name" "" ", branches"
            local listing merged
            listing=$(matching_branches "$repo_name" "$default_branch")
            merged=$(echo "$listing" | awk -F '\t' '$1 == "merged"' | awk 'END { print NR }')
            MERGED_COUNT=$((MERGED_COUNT + merged))
            branches=$(echo "$listing" | awk -F '\t' '$1 != "merged"')
            log INFO "Branches of $repo_name: $(echo "$branches" | awk 'NF > 0 { n++ } END { print n + 0 }') matching, $merged merged and hidden"
            if [[ -z "$branches" ]]; then
                # Only merged branches match: they are counted as merged.
                if [[ -z "$listing" ]]; then
                    NO_BRANCH_COUNT=$((NO_BRANCH_COUNT + 1))
                fi
                continue
            fi
        else
            # An assignment of its own: an error of branch_commit must stop the scan.
            local default_commit
            target_branch="${BRANCH:-$default_branch}"
            default_commit=$(branch_commit "$repo_name" "$target_branch")
            branches=$(printf '%s\t%s' "$target_branch" "$default_commit")
        fi

        # One line per branch: "name<TAB>commit<TAB>branch status".
        collect_candidates "$repo_name" "$branches"
        local repo_first_row=${#RESULT_STATUS[@]} fallback_branches=""
        prefetch_repo_files "$repo_name" "$branches"
        local branch_count branch_number=0 commit
        branch_count=$(echo "$branches" | awk 'NF > 0 { n++ } END { print n + 0 }')
        while IFS=$'\t' read -r target_branch commit CURRENT_BRANCH_STATUS; do
            if [[ -z "$target_branch" ]]; then
                continue
            fi
            BRANCHES_SCANNED=$((BRANCHES_SCANNED + 1))
            branch_number=$((branch_number + 1))

            if [[ -n "$BRANCHES" ]]; then
                print_progress "" "Scanning repo: ($i/$TOTAL_REPOS) " "$CYAN" "$repo_name" "" \
                    ", branch ($branch_number/$branch_count) " "$COLOR_BRANCH" "$target_branch"
            else
                print_progress "" "Scanning repo: ($i/$TOTAL_REPOS) " "$CYAN" "$repo_name"
            fi

            # No commit: no such branch, e.g. an empty repository.
            if [[ -z "$commit" ]]; then
                if [[ -n "$PACKAGES" ]]; then
                    record_file "$repo_url" "$target_branch" "" "$visibility" "NOT_FOUND"
                fi
                continue
            fi

            # The dependency files of this commit, "directory<TAB>file".
            local candidates="" candidate dir file
            while IFS=$'\t' read -r candidate dir file; do
                if [[ "$candidate" == "$commit" ]]; then
                    candidates+="$dir"$'\t'"$file"$'\n'
                fi
            done <<< "$REPO_CANDIDATES"

            # One row per found file. Two lock files in one directory (package-lock.json
            # and yarn.lock) are a mistake: each gets a row, and a warning.
            local found=0 found_dirs="" conflict_dirs="" first_row=${#RESULT_STATUS[@]}
            while IFS=$'\t' read -r dir file; do
                if [[ -z "$file" ]]; then
                    continue
                fi
                local content path="$file"
                if [[ "$dir" != "." ]]; then
                    path="$dir/$file"
                fi
                content=$(fetch_dependency_file "$repo_name" "$commit" "$path")
                if [[ "$content" == "NOT_FOUND" ]]; then
                    continue
                fi
                found=$((found + 1))
                if [[ "$TYPE" == "node" && $'\n'"$found_dirs" == *$'\n'"$dir"$'\n'* ]]; then
                    LOCK_CONFLICT_COUNT=$((LOCK_CONFLICT_COUNT + 1))
                    print_warning_line "$OWNER/$repo_name ($target_branch), directory $dir: package-lock.json and yarn.lock. Use one package manager."
                    conflict_dirs+="$dir"$'\n'
                fi
                found_dirs+="$dir"$'\n'
                # The PATH column: the file with --type=node (there can be two lock
                # files) and nodeEngines (package.json, .nvmrc), else the directory.
                if [[ "$TYPE" != "node" && "$TYPE" != "nodeEngines" ]]; then
                    path="$dir"
                fi
                record_file "$repo_url" "$target_branch" "$path" "$visibility" "$content"
            done <<< "$candidates"
            # The row of the first lock file is recorded before the second one is found.
            if [[ -n "$conflict_dirs" ]]; then
                mark_lock_conflicts "$first_row" "$conflict_dirs"
            fi
            if [[ "$TYPE" == "nodeEngines" ]]; then
                check_node_versions "$first_row" "$repo_name" "$target_branch"
            fi
            if [[ $found -eq 0 && -n "$PACKAGES" ]]; then
                record_file "$repo_url" "$target_branch" "" "$visibility" "NOT_FOUND"
            fi
            # The rows of this branch, for --filename-match after the last branch.
            # "-": no branch status. Not an empty field: read joins adjacent tabs.
            fallback_branches+="$first_row"$'\t'"${#RESULT_STATUS[@]}"$'\t'"$commit"$'\t'"${CURRENT_BRANCH_STATUS:--}"$'\t'"$target_branch"$'\n'
        done <<< "$branches"

        # --filename-match: only for a repository without a version in any branch.
        if [[ -n "$FILENAME_MATCH" ]] && ! rows_have_version "$repo_first_row"; then
            local fallback_first fallback_end fallback_commit fallback_status fallback_branch
            while IFS=$'\t' read -r fallback_first fallback_end fallback_commit fallback_status fallback_branch; do
                if [[ -n "$fallback_commit" ]]; then
                    # record_result takes the branch status from here.
                    CURRENT_BRANCH_STATUS="${fallback_status#-}"
                    filename_fallback "$fallback_first" "$fallback_end" "$repo_name" "$fallback_commit" "$repo_url" "$fallback_branch" "$visibility"
                fi
            done <<< "$fallback_branches"
        fi

    # The default branch last: it can be empty ("gh repo view" of an empty
    # repository), and read joins adjacent tabs. No topics, no push or no
    # creation time: "-", which no topic or time can be.
    done < <(echo "$REPOS_DATA" | jq -r '.[] | [.name, .url, .isPrivate, (.isArchived // false), ((.topics // []) | join(" ") | if . == "" then "-" else . end), (.pushedAt // "-"), (.createdAt // "-"), (.defaultBranchRef.name // "main")] | @tsv')
    trap - INT

    clear_progress
}
