# shellcheck shell=bash
# Sourced by gh-dep-scanner.sh: Dependency files: fetch, file lists and the GraphQL prefetch.

# Space-separated, in the order they are tried.
dep_file_names() {
    case "$TYPE" in
        composer) echo "composer.lock" ;;
        composerJson) echo "composer.json" ;;
        node) echo "package-lock.json yarn.lock" ;;
        nodeEngines) echo "package.json .nvmrc .node-version" ;;
        *) echo "package.json" ;;
    esac
}

# Fetch the file $3 (a path, e.g. "webroot/yarn.lock") of commit $2.
# Prints its content, or NOT_FOUND.
fetch_dependency_file() {
    local repo_name="$1"
    local commit="$2"
    local file="$3"

    # Use the raw media type: the JSON response has no content for files over 1 MB (e.g. composer.lock).
    local request response
    request="repos/$OWNER/$repo_name/contents/$(url_encode "$file")?ref=$commit"
    # Cache by commit: a commit never changes, so the entry never gets old.
    response=$(gh_cached "api/repos/$OWNER/$repo_name/commit/$commit/$file" api --header "Accept: application/vnd.github.raw+json" "$request") || {
        # Only a 404 means "no file". Other errors (rate limit, auth, network) must stop the scan.
        if [[ "$(http_status "$response")" != "404" ]]; then
            print_error "Failed to fetch $file from $OWNER/$repo_name: $response"
            exit 1
        fi
        echo "NOT_FOUND"
        return
    }

    # list_packages finds parse errors: one jq parse per file, not two.
    echo "$response"
}

# Print the dependency files of commit $2 as "directory<TAB>file", one per
# line: in the root (".") and in the directories that match --alternativePaths.
# Uses the file list of the commit: one request, also for many directories.
matching_dirs() {
    local repo_name="$1"
    local commit="$2"
    local listing
    local request="repos/$OWNER/$repo_name/git/trees/$commit?recursive=1"
    listing=$(gh_cached "api/repos/$OWNER/$repo_name/commit/$commit/tree?recursive=1" api "$request" \
        --jq '(if .truncated then "TRUNCATED" else empty end), (.tree[] | select(.type == "blob") | .path)') || {
        # Only a 404 means "no files" (e.g. an empty repository). Other errors must stop the scan.
        if [[ "$(http_status "$listing")" == "404" ]]; then
            return 0
        fi
        print_error "Failed to fetch the file list of $OWNER/$repo_name ($commit): $listing"
        exit 1
    }
    if [[ "$listing" == TRUNCATED* ]]; then
        print_warning_line "The file list of $OWNER/$repo_name ($commit) is incomplete (too many files). Some directories are not checked."
    fi

    local dir file
    while IFS=$'\t' read -r dir file; do
        if [[ "$dir" == "." || "$dir" =~ $ALTERNATIVE_PATHS ]]; then
            printf '%s\t%s\n' "$dir" "$file"
        fi
    done < <(echo "$listing" | awk -v names="$(dep_file_names)" '
        BEGIN { n = split(names, list, " "); for (i = 1; i <= n; i++) wanted[list[i]] = 1 }
        $0 == "TRUNCATED" { next }
        {
            file = $0; dir = "."
            if (index($0, "/") > 0) {
                sub(/.*\//, "", file)
                dir = $0; sub(/\/[^\/]*$/, "", dir)
            }
            if (file in wanted) print dir "\t" file
        }')
}

# Files per GraphQL request. Lock files are large: 25 give up to about 5 MB.
PREFETCH_FILES=25

# Fetch the branch commit and the dependency files in the root for many
# repositories with few GraphQL requests. Write them to the cache entries of
# branch_commit and fetch_dependency_file: the scan then reads the cache.
# Only for repositories without a cached entry. For --branches,
# prefetch_repo_files does this per repository.
prefetch_dependency_files() {
    if [[ -n "$BRANCHES" || $USE_CACHE -eq 0 || $OFFLINE -eq 1 ]]; then
        return 0
    fi

    local files pending="" count=0 name branch commit file paths dir
    files=$(dep_file_names)
    while IFS=$'\t' read -r name branch; do
        if [[ -z "$branch" ]]; then
            continue
        fi
        dir="$CACHE_DIR/api/repos/$OWNER/$name"
        if [[ -f "$dir/branches/$branch.404" ]]; then
            continue
        fi
        # "-": the commit is not known. GraphQL then gives it with the files.
        commit="-"
        if [[ -f "$dir/branches/$branch" ]]; then
            commit=$(cat "$dir/branches/$branch")
        fi
        paths=""
        for file in $files; do
            if [[ "$commit" == "-" || ( ! -f "$dir/commit/$commit/$file" && ! -f "$dir/commit/$commit/$file.404" ) ]]; then
                paths+=$'\t'"$file"
                count=$((count + 1))
            fi
        done
        if [[ -n "$paths" ]]; then
            pending+="$name"$'\t'"$branch"$'\t'"$commit$paths"$'\n'
        fi
    done < <(echo "$REPOS_DATA" | jq -r --arg branch "$BRANCH" '.[] | "\(.name)\t\(if $branch != "" then $branch else .defaultBranchRef.name // "main" end)"')

    if [[ $count -gt 0 ]]; then
        log INFO "Prefetch: $count files in the root of the repositories"
        prefetch_files "$pending" "$count"
        clear_progress
    fi
}

# The dependency files to read in the scanned repository, set by
# collect_candidates: "commit<TAB>directory<TAB>file", one per line.
REPO_CANDIDATES=""

# Set REPO_CANDIDATES for the branches $2 ("name<TAB>commit" lines) of
# repository $1. Without --alternativePaths, all candidates in the root: the
# fetch shows which exist. Once per commit: the file list can give a warning.
collect_candidates() {
    REPO_CANDIDATES=""
    local branch commit listing dir file
    while IFS=$'\t' read -r branch commit _; do
        if [[ -z "$commit" || $'\n'"$REPO_CANDIDATES" == *$'\n'"$commit"$'\t'* ]]; then
            continue
        fi
        if [[ -n "$ALTERNATIVE_PATHS" ]]; then
            # An assignment of its own: an error of matching_dirs must stop the scan.
            listing=$(matching_dirs "$1" "$commit")
        else
            listing=$(for file in $(dep_file_names); do printf '.\t%s\n' "$file"; done)
        fi
        while IFS=$'\t' read -r dir file; do
            if [[ -n "$file" ]]; then
                REPO_CANDIDATES+="$commit"$'\t'"$dir"$'\t'"$file"$'\n'
            fi
        done <<< "$listing"
    done <<< "$2"
}

# Fetch the files of REPO_CANDIDATES that are not cached, for the branches
# $2 of repository $1. A single file is left to the scan: one request
# either way.
prefetch_repo_files() {
    if [[ $USE_CACHE -eq 0 || $OFFLINE -eq 1 ]]; then
        return 0
    fi
    local pending="" count=0 branch commit candidate dir file path paths base
    while IFS=$'\t' read -r branch commit _; do
        if [[ -z "$commit" || "$pending" == *$'\t'"$commit"$'\t'* ]]; then
            continue
        fi
        paths=""
        while IFS=$'\t' read -r candidate dir file; do
            if [[ "$candidate" != "$commit" ]]; then
                continue
            fi
            path="$file"
            if [[ "$dir" != "." ]]; then
                path="$dir/$file"
            fi
            base="$CACHE_DIR/api/repos/$OWNER/$1/commit/$commit/$path"
            if [[ ! -f "$base" && ! -f "$base.404" ]]; then
                paths+=$'\t'"$path"
                count=$((count + 1))
            fi
        done <<< "$REPO_CANDIDATES"
        if [[ -n "$paths" ]]; then
            pending+="$1"$'\t'"$branch"$'\t'"$commit$paths"$'\n'
        fi
    done <<< "$2"

    if [[ $count -gt 1 ]]; then
        log INFO "Prefetch: $count files of $OWNER/$1"
        prefetch_files "$pending"
    fi
}

# Fetch the files of the lines $1, "name<TAB>branch<TAB>commit or -<TAB>path..."
# with GraphQL requests of up to PREFETCH_FILES files.
# $2: the number of files, for a progress line (optional).
prefetch_files() {
    local response line header part path chunk="" chunk_files=0 done_files=0
    local -a fields
    response=$(mktemp)
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            continue
        fi
        IFS=$'\t' read -r -a fields <<< "$line"
        header="${fields[0]}"$'\t'"${fields[1]}"$'\t'"${fields[2]}"
        part=""
        for path in "${fields[@]:3}"; do
            if [[ $chunk_files -ge $PREFETCH_FILES ]]; then
                if [[ -n "$part" ]]; then
                    chunk+="$header$part"$'\n'
                fi
                if [[ -n "${2:-}" ]]; then
                    print_progress "" "Fetching the dependency files: " "$CYAN" "$done_files/$2" "" " files"
                fi
                prefetch_batch "$chunk" "$response"
                done_files=$((done_files + chunk_files))
                chunk="" part="" chunk_files=0
            fi
            part+=$'\t'"$path"
            chunk_files=$((chunk_files + 1))
        done
        chunk+="$header$part"$'\n'
    done <<< "$1"
    if [[ $chunk_files -gt 0 ]]; then
        if [[ -n "${2:-}" ]]; then
            print_progress "" "Fetching the dependency files: " "$CYAN" "$done_files/$2" "" " files"
        fi
        prefetch_batch "$chunk" "$response"
    fi
    rm -f "$response"
}

# Fetch the lines $1 (see prefetch_files) with one GraphQL request, and write
# the results to the cache. $2: a temporary file. A failed request writes
# nothing: then the scan fetches the files one by one.
prefetch_batch() {
    local query
    # The commit and the files come from one commit object: a push during
    # the request cannot mix them up.
    query=$(jq --null-input --raw-output --arg batch "$1" --arg owner "$OWNER" '
        [$batch | split("\n")[] | select(length > 0) | split("\t")] as $lines
        | "query { "
          + ([range($lines | length) as $i | $lines[$i] as $r
              | ("... on Commit { oid "
                 + ([range(3; $r | length) as $j
                     | "f\($j - 3): file(path: \($r[$j] | @json)) { object { ... on Blob { isTruncated isBinary text } } }"] | join(" "))
                 + " }") as $files
              | "r\($i): repository(owner: \($owner | @json), name: \($r[0] | @json)) { "
              + (if $r[2] != "-"
                 then "object(oid: \($r[2] | @json)) { \($files) } }"
                 else "ref(qualifiedName: \("refs/heads/" + $r[1] | @json)) { target { \($files) } } }"
                 end)] | join(" "))
          + " }"')

    # A missing file is a NOT_FOUND error: gh then fails, but the data is complete.
    # gh writes the body (one line, no newline at the end) to stdout, then
    # "gh: <messages>" to stderr. gh_request joins both: cut off the messages.
    # The greedy match keeps a "}gh: " in a file text.
    # Short options: BSD head (macOS) has no long options.
    gh_request api graphql -f query="$query" | head -n 1 | sed -e 's/\(.*}\)gh: .*$/\1/' >| "$2" || true
    if ! jq --exit-status '.data != null and ([.errors[]? | select(.type != "NOT_FOUND")] | length == 0)' "$2" &> /dev/null; then
        log WARN "Prefetch failed, the scan fetches these files one by one: $(head -c 300 "$2")"
        return 0
    fi

    # Records, each field ends with NUL: "branch", name, branch, commit
    # or "file", name, commit, path, "found" or "404", content.
    local kind name branch commit file state content dir written=0
    while IFS= read -r -d '' kind; do
        if [[ "$kind" == "branch" ]]; then
            IFS= read -r -d '' name
            IFS= read -r -d '' branch
            IFS= read -r -d '' commit
            dir="$CACHE_DIR/api/repos/$OWNER/$name/branches"
            if [[ -n "$commit" ]]; then
                write_cache_entry "$dir/$branch" "$commit"
                rm -f "$dir/$branch.404"
            else
                write_cache_entry "$dir/$branch.404" "gh: Not Found (HTTP 404)"
                rm -f "$dir/$branch"
            fi
            continue
        fi
        IFS= read -r -d '' name
        IFS= read -r -d '' commit
        IFS= read -r -d '' file
        IFS= read -r -d '' state
        IFS= read -r -d '' content
        dir="$CACHE_DIR/api/repos/$OWNER/$name/commit/$commit"
        if [[ "$state" == "found" ]]; then
            # Like "$(gh ...)" in gh_cached: without the newlines at the end.
            while [[ "$content" == *$'\n' ]]; do
                content="${content%$'\n'}"
            done
            write_cache_entry "$dir/$file" "$content"
            rm -f "$dir/$file.404"
        else
            write_cache_entry "$dir/$file.404" "gh: Not Found (HTTP 404)"
            rm -f "$dir/$file"
        fi
        written=$((written + 1))
    done < <(jq --join-output --arg batch "$1" '
        [$batch | split("\n")[] | select(length > 0) | split("\t")] as $lines
        | [.errors[]? | select(.type == "NOT_FOUND") | "\(.path[0])/\(.path[-1])"] as $missing
        | range($lines | length) as $i
        | $lines[$i] as $r
        | .data["r\($i)"] as $repo
        | select($repo != null)
        | ($repo.object // $repo.ref.target) as $commit
        | if $r[2] == "-" and $repo.ref == null then
              ["branch", $r[0], $r[1], ""]
          elif $commit.oid == null then
              empty
          else
              (if $r[2] == "-" then ["branch", $r[0], $r[1], $commit.oid] else empty end),
              (range(3; $r | length) as $j
               | $commit["f\($j - 3)"] as $f
               | if $f == null and ($missing | index(["r\($i)/f\($j - 3)"])) != null then
                     ["file", $r[0], $commit.oid, $r[$j], "404", ""]
                 elif $f.object.text != null and $f.object.isTruncated == false and $f.object.isBinary == false then
                     ["file", $r[0], $commit.oid, $r[$j], "found", $f.object.text]
                 else
                     empty
                 end)
          end
        | map(. + "\u0000") | add' "$2")
    log INFO "Prefetch: $written files written to the cache"
}
