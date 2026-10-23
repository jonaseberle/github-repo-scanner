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
    exit 130
}

# Classify a package version and add a result row.
# Arguments: URL, branch, path, visibility, package, and the version or
# NOT_FOUND (no file) / PARSE_ERROR / NOT_IN_FILE (no matching package).
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
    else
        version_str="$value"
        if [[ -z "$AFFECTED" ]]; then
            status="found"
            FOUND_COUNT=$((FOUND_COUNT + 1))
        elif is_affected "$version_str"; then
            status="affected"
            AFFECTED_COUNT=$((AFFECTED_COUNT + 1))
        else
            status="not_affected"
        fi
    fi

    log DEBUG "Result: $1 branch=$2 path=$3 package=$5 version=$version_str status=$status"
    RESULT_URLS+=("$1")
    RESULT_BRANCHES+=("$2")
    RESULT_BRANCH_STATUS+=("$CURRENT_BRANCH_STATUS")
    RESULT_PATHS+=("$3")
    RESULT_LOCK_CONFLICT+=(0)
    RESULT_VISIBILITY+=("$4")
    RESULT_PACKAGES+=("$5")
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
    if ! listing=$(list_packages "$content" "$TYPE"); then
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

# Set RESULT_LOCK_CONFLICT for the rows from number $1 on whose path is in
# one of the directories $2 (one per line).
mark_lock_conflicts() {
    local i dir
    for ((i = $1; i < ${#RESULT_STATUS[@]}; i++)); do
        dir="."
        if [[ "${RESULT_PATHS[$i]}" == */* ]]; then
            dir="${RESULT_PATHS[$i]%/*}"
        fi
        if [[ $'\n'"$2" == *$'\n'"$dir"$'\n'* ]]; then
            RESULT_LOCK_CONFLICT[i]=1
        fi
    done
}

scan_repos() {
    echo ""
    printf '%s\n' "${BOLD}Scanning $OWNER repositories for ${NC}$(packages_label)${AFFECTED:+, affected: ${COLOR_VERSION}$AFFECTED${NC}}..."
    if [[ -n "$BRANCHES" ]]; then
        printf '%s\n' "Branches: matching ${COLOR_BRANCH}$BRANCHES${NC}"
    elif [[ -n "$BRANCH" ]]; then
        printf '%s\n' "Branch: ${COLOR_BRANCH}$BRANCH${NC}"
    else
        printf '%s\n' "Branch: ${COLOR_BRANCH}default${NC}"
    fi
    echo ""

    trap on_scan_interrupt INT

    local i=0 repo_name repo_url is_private default_branch
    while IFS=$'\t' read -r repo_name repo_url is_private default_branch; do
        i=$((i + 1))
        SCAN_POSITION=$i
        log INFO "Scanning repo $i/$TOTAL_REPOS: $repo_name"

        # Visibility
        local visibility
        if [[ "$is_private" == "true" ]]; then
            visibility="private"
        else
            visibility="public"
        fi

        # Determine which branches to use
        local branches target_branch
        if [[ -n "$BRANCHES" ]]; then
            print_progress "" "Scanning repo: " "$CYAN" "$repo_name" "" " ($i/$TOTAL_REPOS), branches"
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
                print_progress "" "Scanning repo: " "$CYAN" "$repo_name" "" " ($i/$TOTAL_REPOS), branch " \
                    "$COLOR_BRANCH" "$target_branch" "" " ($branch_number/$branch_count)"
            else
                print_progress "" "Scanning repo: " "$CYAN" "$repo_name" "" " ($i/$TOTAL_REPOS)"
            fi

            # No commit: no such branch, e.g. an empty repository.
            if [[ -z "$commit" ]]; then
                record_file "$repo_url" "$target_branch" "" "$visibility" "NOT_FOUND"
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
                if [[ $'\n'"$found_dirs" == *$'\n'"$dir"$'\n'* ]]; then
                    LOCK_CONFLICT_COUNT=$((LOCK_CONFLICT_COUNT + 1))
                    print_warning_line "$OWNER/$repo_name ($target_branch), directory $dir: package-lock.json and yarn.lock. Use one package manager."
                    conflict_dirs+="$dir"$'\n'
                fi
                found_dirs+="$dir"$'\n'
                # The PATH column: the lock file with --type=node (there can be two), else the directory.
                if [[ "$TYPE" != "node" ]]; then
                    path="$dir"
                fi
                record_file "$repo_url" "$target_branch" "$path" "$visibility" "$content"
            done <<< "$candidates"
            # The row of the first lock file is recorded before the second one is found.
            if [[ -n "$conflict_dirs" ]]; then
                mark_lock_conflicts "$first_row" "$conflict_dirs"
            fi
            if [[ $found -eq 0 ]]; then
                record_file "$repo_url" "$target_branch" "" "$visibility" "NOT_FOUND"
            fi
        done <<< "$branches"

    # The default branch last: it can be empty ("gh repo view" of an empty
    # repository), and read joins adjacent tabs.
    done < <(echo "$REPOS_DATA" | jq -r '.[] | [.name, .url, .isPrivate, (.defaultBranchRef.name // "main")] | @tsv')
    trap - INT

    clear_progress
}
