# shellcheck shell=bash
# Sourced by gh-dep-scanner.sh: The repository list.

fetch_repos() {
    print_info "Fetching repositories for $OWNER_TYPE: $OWNER${REPO:+/$REPO}..."

    local repos_json
    if [[ "$OWNER_TYPE" == "repo" ]]; then
        # Wrap in an array to get the shape of the repository list (REPO_FIELDS).
        # Fresh: its push time tells which cache entries are outdated. --offline uses the cache.
        local view=gh_fresh
        if [[ $OFFLINE -eq 1 ]]; then
            view=gh_cached
        fi
        repos_json=$("$view" "repo-view/$OWNER/$REPO" repo view "$OWNER/$REPO" --json name,url,isPrivate,defaultBranchRef,pushedAt,repositoryTopics \
            --jq '[. + {topics: [.repositoryTopics[]?.name]} | del(.repositoryTopics)]') || {
            print_error "Failed to fetch repository: $OWNER/$REPO"
            exit 1
        }
    else
        repos_json=$(fetch_repo_list) || {
            print_error "Failed to fetch the repositories of $OWNER_TYPE $OWNER"
            exit 1
        }
    fi

    # The list has the archived repositories too: count them, then skip them.
    if [[ "$OWNER_TYPE" != "repo" ]]; then
        ARCHIVED_COUNT=$(echo "$repos_json" | jq '[.[] | select(.isArchived)] | length')
        repos_json=$(echo "$repos_json" | jq '[.[] | select(.isArchived | not)]')
    fi

    # Filter with bash, not jq: jq regular expressions are not POSIX extended ones.
    if [[ -n "$REPO_FILTER$TOPICS_FILTER" ]]; then
        local name topics topic matching="" match
        while IFS=$'\t' read -r name topics; do
            if [[ -n "$REPO_FILTER" && ! "$name" =~ $REPO_FILTER ]]; then
                FILTERED_OUT_COUNT=$((FILTERED_OUT_COUNT + 1))
                continue
            fi
            if [[ -n "$TOPICS_FILTER" ]]; then
                match=0
                for topic in $topics; do
                    if [[ "$topic" =~ $TOPICS_FILTER ]]; then
                        match=1
                    fi
                done
                if [[ $match -eq 0 ]]; then
                    TOPICS_FILTERED_OUT_COUNT=$((TOPICS_FILTERED_OUT_COUNT + 1))
                    continue
                fi
            fi
            matching+="$name"$'\n'
        done < <(echo "$repos_json" | jq -r '.[] | [.name, (.topics // [] | join(" "))] | @tsv')
        repos_json=$(echo "$repos_json" | jq --arg names "$matching" '($names | split("\n")) as $names | [.[] | select(.name as $name | any($names[]; . == $name))]')
    fi

    REPOS_DATA="$repos_json"
    TOTAL_REPOS=$(echo "$repos_json" | jq 'length')

    if [[ $OFFLINE -eq 0 ]]; then
        refresh_pushed_repos
    fi

    if [[ "$TOTAL_REPOS" -eq 0 ]]; then
        if [[ -n "$REPO_FILTER$TOPICS_FILTER" ]]; then
            print_warning "No repository of $OWNER matches${REPO_FILTER:+ --repo='$REPO_FILTER'}${TOPICS_FILTER:+ --topics='$TOPICS_FILTER'}"
        else
            print_warning "No repositories found for $OWNER"
        fi
        exit 0
    fi

    log INFO "Repositories of $OWNER_TYPE $OWNER: $TOTAL_REPOS to scan, ${ARCHIVED_COUNT:-0} archived, $FILTERED_OUT_COUNT not matching --repo, $TOPICS_FILTERED_OUT_COUNT not matching --topics"
    print_success "Found $TOTAL_REPOS repositories."
}

# The REST fields of a repository, with the names of "gh repo view --json".
REPO_FIELDS='{name, url: .html_url, isPrivate: .private, isArchived: .archived, defaultBranchRef: {name: .default_branch}, pushedAt: .pushed_at, updatedAt: .updated_at, topics}'
# The number of repositories of an org or user (jq, on "gh api orgs/NAME").
# Nothing if GitHub does not give the private ones: this needs a token scope
# (e.g. "user" for the own account, which a "gh auth login" does not ask for).
REPOS_COUNT='if .owned_private_repos == null then empty else .public_repos + .owned_private_repos end'
# Repositories per page when only the changes are fetched: one page of 100
# takes about 2 s, one of 20 under 1 s, and usually a few repositories change.
REPOS_CHANGES_PER_PAGE=20
# Without the number, deleted repositories show only in a full list: fetch
# one if the last one is older than this (seconds).
REPOS_FULL_MAX_AGE=86400

# The REST endpoint for the repositories of OWNER.
# REST is about twice as fast as "gh repo list" (GraphQL).
repos_endpoint() {
    if [[ "$OWNER_TYPE" == "org" ]]; then
        echo "orgs/$OWNER/repos?type=all"
        return
    fi
    # Only the list of the logged-in user (user/repos) has the private repositories.
    local login
    # Not the key "api/user": it would be a file where "api/user/repos" needs a directory.
    login=$(gh_cached "api/user?login" api user --jq '.login') || login=""
    if [[ "$login" == "$OWNER" ]]; then
        echo "user/repos?affiliation=owner"
    else
        echo "users/$OWNER/repos?type=owner"
    fi
}

# The number of repositories that GitHub has for OWNER (fresh).
# Keys with "?": a key "api/orgs/NAME" would be a file where
# "api/orgs/NAME/repos" needs a directory.
repos_count() {
    if [[ "$OWNER_TYPE" == "org" ]]; then
        gh_fresh "api/orgs/$OWNER?about" api "orgs/$OWNER" --jq "$REPOS_COUNT"
    elif [[ "$1" == user/* ]]; then
        gh_fresh "api/user?count" api user --jq "$REPOS_COUNT"
    else
        # users/NAME/repos lists the public repositories only.
        gh_fresh "api/users/$OWNER?count" api "users/$OWNER" --jq '.public_repos'
    fi
}

# Print the repositories sorted by $1 (pushed, updated), newest first, page by
# page up to the first one whose $2 (pushedAt, updatedAt) is the same in the
# cached list: the older ones are the same too.
# Uses endpoint, key and file of fetch_repo_list.
changed_repos() {
    local sort="$1" field="$2" page=1 lines unchanged
    while true; do
        lines=$(gh_fresh "$key.$sort" api "$endpoint&per_page=$REPOS_CHANGES_PER_PAGE&sort=$sort&direction=desc&page=$page" --jq ".[] | $REPO_FIELDS") || return 1
        echo "$lines"
        # --slurpfile, not --argjson: a long list must not be a command line argument.
        unchanged=$(echo "$lines" | jq --slurp --slurpfile cached "$file" --arg field "$field" \
            'any(.[]; . as $r | $cached | any(.name == $r.name and .[$field] == $r[$field]))')
        if [[ -z "$lines" || "$unchanged" == "true" || $(echo "$lines" | awk 'END { print NR }') -lt $REPOS_CHANGES_PER_PAGE ]]; then
            break
        fi
        page=$((page + 1))
    done
    log INFO "Repository list: $page page(s) sorted by $sort"
}

# Print the repositories of OWNER as a JSON array.
# With a cached list, only the changes are fetched: the repositories with new
# pushes (sorted by pushed) and with other changes such as archiving or
# renaming (sorted by updated; a push does not always change updated_at).
# Usually one page each. A deleted repository is in no page: if the number
# of repositories on GitHub differs from the merged list, the full list is
# fetched. If GitHub does not give the number, a full list is fetched once
# in REPOS_FULL_MAX_AGE. --offline uses the cached list.
fetch_repo_list() {
    local endpoint key file listing
    endpoint=$(repos_endpoint)
    key="api/${endpoint%%\?*}"
    file="$CACHE_DIR/$key"
    local full_request="$endpoint&per_page=100&sort=pushed&direction=desc" full="$CACHE_DIR/$key.full"

    # A list cached before the topics were added has no "topics".
    local has_topics=1
    if [[ -f "$file" ]] && ! jq --slurp --exit-status 'all(.[]; has("topics"))' "$file" > /dev/null; then
        has_topics=0
    fi
    if [[ $OFFLINE -eq 1 ]]; then
        if [[ -n "$TOPICS_FILTER" && $has_topics -eq 0 ]]; then
            print_error "The cached repository list has no topics. Run once without --offline." >&2
            return 1
        fi
        listing=$(gh_cached "$key" api --paginate "$full_request" --jq ".[] | $REPO_FIELDS") || return 1
    elif [[ $USE_CACHE -eq 0 || ! -f "$file" || $has_topics -eq 0 ]]; then
        log INFO "Fetching the full repository list: $endpoint"
        listing=$(gh_fresh "$key" api --paginate "$full_request" --jq ".[] | $REPO_FIELDS") || return 1
        write_cache_entry "$full" ""
    elif [[ $(($(date +%s) - $(file_mtime "$file"))) -lt $((REPO_LIST_MAX_AGE * 60)) ]]; then
        # Each check writes the list: its age is the time since the last check.
        local age
        age=$(format_age $(($(date +%s) - $(file_mtime "$file"))))
        log INFO "Repository list: from the cache, checked $age ago (--cache-repo-list-max-age=$REPO_LIST_MAX_AGE)"
        # On stderr: stdout is the list.
        print_info "Repository list from the cache, checked $age ago (--cache-repo-list-max-age=$REPO_LIST_MAX_AGE)." >&2
        listing=$(gh_cached "$key" api --paginate "$full_request" --jq ".[] | $REPO_FIELDS") || return 1
    else
        local changed count
        changed=$(changed_repos pushed pushedAt && changed_repos updated updatedAt) || return 1
        # The changed entries first: for a name, the first entry stays.
        listing=$( (printf '%s\n' "$changed"; cat "$file") | jq --slurp --compact-output \
            'reduce .[] as $r ({}; if has($r.name) then . else .[$r.name] = $r end) | .[]')
        count=$(repos_count "$endpoint") || count=""
        local reason=""
        if [[ -n "$count" && "$count" != "$(echo "$listing" | awk 'NF { n++ } END { print n + 0 }')" ]]; then
            reason="GitHub has $count repositories, the merged list not"
        elif [[ -z "$count" && ( ! -f "$full" || $(($(date +%s) - $(file_mtime "$full"))) -ge $REPOS_FULL_MAX_AGE ) ]]; then
            reason="GitHub gives no number of repositories, and the last full list is older than $((REPOS_FULL_MAX_AGE / 3600)) h"
        fi
        if [[ -n "$reason" ]]; then
            log INFO "Repository list: $reason: fetching the full list"
            listing=$(gh_fresh "$key" api --paginate "$full_request" --jq ".[] | $REPO_FIELDS") || return 1
            write_cache_entry "$full" ""
        else
            write_cache_entry "$file" "$listing"
        fi
    fi
    echo "$listing" | jq --slurp '.'
}

# Delete the cache entries of each repository that are older than its last
# push. Entries written after the push stay, also those of a parallel scan.
# Entries below commit/ stay: a commit never changes.
refresh_pushed_repos() {
    local name pushed_at dir stamp outdated reference
    reference=$(mktemp)
    while IFS=$'\t' read -r name pushed_at; do
        dir="$CACHE_DIR/api/repos/$OWNER/$name"
        if [[ ! -d "$dir" || -z "$pushed_at" ]]; then
            continue
        fi
        # "2026-10-22T18:53:33Z" -> "202610221853.33", the format of touch -t.
        stamp="${pushed_at//[-:T]/}"
        stamp="${stamp%Z}"
        TZ=UTC touch -t "${stamp:0:12}.${stamp:12:2}" "$reference"
        # Short option: BSD wc (macOS) has no --lines.
        outdated=$(find "$dir" -path "$dir/commit" -prune -o -type f ! -newer "$reference" -print | wc -l)
        if [[ $outdated -gt 0 ]]; then
            find "$dir" -path "$dir/commit" -prune -o -type f ! -newer "$reference" -exec rm -f {} +
            REFRESHED_COUNT=$((REFRESHED_COUNT + 1))
            log INFO "Cache of $OWNER/$name: $((outdated)) entries older than the push at $pushed_at removed"
        fi
    done < <(echo "$REPOS_DATA" | jq -r '.[] | "\(.name)\t\(.pushedAt // "")"')
    rm -f "$reference"
}
