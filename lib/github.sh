# shellcheck shell=bash
# Sourced by gh-dep-scanner.sh: GitHub requests: cache, locks, retries.

# Run "gh <arguments>" and cache the output in $CACHE_DIR/<key>.
# The key is a path below $CACHE_DIR, e.g. "api/orgs/NAME".
# A 404 is cached as <key>.404. Other errors are not cached.
gh_cached() {
    local file="$CACHE_DIR/$1" key="$1"
    shift

    if [[ $USE_CACHE -eq 1 && -f "$file" ]]; then
        log DEBUG "cache hit: $key"
        echo "cache $(file_mtime "$file")" >> "$REQUEST_LOG"
        cat "$file"
        return 0
    fi
    if [[ $USE_CACHE -eq 1 && -f "$file.404" ]]; then
        log DEBUG "cache hit (404): $key"
        echo "cache $(file_mtime "$file.404")" >> "$REQUEST_LOG"
        cat "$file.404"
        return 1
    fi

    # Only one process fetches a key. Another one waits and then uses the entry:
    # from the cache, or (also without the cache) if it was written during
    # this scan, e.g. the repository list.
    local lock
    lock=$(lock_path "$key")
    acquire_lock "$lock" "$key"
    if [[ $LOCK_WAITED -eq 1 ]] && { [[ $USE_CACHE -eq 1 ]] || written_since_start "$file" || written_since_start "$file.404"; }; then
        if [[ -f "$file" ]]; then
            release_lock "$lock"
            log DEBUG "cache hit after waiting: $key"
            echo "cache $(file_mtime "$file")" >> "$REQUEST_LOG"
            cat "$file"
            return 0
        fi
        if [[ -f "$file.404" ]]; then
            release_lock "$lock"
            log DEBUG "cache hit (404) after waiting: $key"
            echo "cache $(file_mtime "$file.404")" >> "$REQUEST_LOG"
            cat "$file.404"
            return 1
        fi
    fi

    local output status=0
    output=$(gh_request "$@") || status=$?

    if [[ $status -eq 0 ]]; then
        write_cache_entry "$file" "$output"
        rm -f "$file.404"
        log DEBUG "cache write: $key"
    elif [[ "$(http_status "$output")" == "404" ]]; then
        write_cache_entry "$file.404" "$output"
        rm -f "$file"
        log DEBUG "cache write (404): $key"
    fi
    release_lock "$lock"
    printf '%s\n' "$output"
    return $status
}

# Run "gh <arguments>" and print the output. Pace the requests, wait at the
# rate limit and retry network errors.
gh_request() {
    # Retry a network error (no HTTP status, e.g. "connection reset") or a 5xx
    # up to 3 times. Other HTTP errors (404, authentication) do not change on
    # retry. At the rate limit, wait and send the request again.
    local output status attempt=0 limit_waits=0 bucket
    bucket=$(rate_bucket "$@")
    while true; do
        attempt=$((attempt + 1))
        pace_requests "$bucket"

        # One dot per network request shows progress during slow requests.
        if [[ -t 2 ]]; then
            printf '.' >&2
        fi

        status=0
        local started=$SECONDS
        output=$(gh "$@" 2>&1) || status=$?
        echo "network" >> "$REQUEST_LOG"
        printf '.' >> "$RATE_COUNTER"
        local http
        http=$(http_status "$output")
        log INFO "gh $* -> exit $status${http:+ (HTTP $http)}, $((SECONDS - started)) s, attempt $attempt"
        if [[ "$DELAY" != "0" ]]; then
            sleep "$DELAY"
        fi

        if [[ $status -eq 0 ]]; then
            break
        fi
        if is_rate_limited "$output" && [[ $limit_waits -lt 5 ]]; then
            # A "z" replaces the dot: not an error, the scan waits for the rate limit.
            if [[ -t 2 ]]; then
                printf '\b%sz%s' "$YELLOW" "$NC" >&2
            fi
            limit_waits=$((limit_waits + 1))
            attempt=$((attempt - 1))
            if [[ "$output" == *"secondary rate limit"* ]]; then
                # GitHub: wait at least one minute, then longer.
                wait_until "$(($(date +%s) + 60 * limit_waits))" "Secondary rate limit"
            else
                check_rate_limit
                wait_until "$(rate_value "$bucket" 4)" "Rate limit used up"
                check_rate_limit
            fi
            continue
        fi
        # Not retried (e.g. a 404, "no such file"): the dot stays.
        if [[ $attempt -ge 4 ]] || ! is_retryable_error "$output"; then
            break
        fi
        mark_failed_attempt
        log WARN "Retry in $((attempt * 2)) s: ${output##*$'\n'}"
        sleep $((attempt * 2))
    done

    printf '%s\n' "$output"
    return $status
}

written_since_start() {
    [[ -f "$1" && $(file_mtime "$1") -ge $SCAN_STARTED ]]
}

# A lock is a directory: mkdir creates it or fails, in one step, also on macOS.
# Its name is a checksum of the key: flat, and short also for long keys.
lock_path() {
    local sum
    sum=$(printf '%s' "$1" | cksum)
    echo "$LOCK_DIR/${sum%% *}"
}

# Wait until this process has the lock. LOCK_WAITED=1 if another process
# had it: then that process may have written the cache entry.
# Arguments: lock, key (for the log)
acquire_lock() {
    LOCK_WAITED=0
    mkdir -p "$LOCK_DIR"
    local holder waited=0
    while ! mkdir "$1" 2>/dev/null; do
        holder=$(cat "$1/pid" 2>/dev/null || true)
        # A lock of a process that no longer runs (e.g. kill -9) is removed.
        # Short option: BSD ps (macOS) has no --pid.
        if [[ -n "$holder" ]] && ! ps -p "$holder" > /dev/null 2>&1; then
            log WARN "Removing the lock of process $holder, which no longer runs: $2"
            release_lock "$1"
            continue
        fi
        # No pid after 10 s: the process stopped between mkdir and writing it.
        if [[ -z "$holder" && $waited -ge 50 ]]; then
            log WARN "Removing a lock without a process: $2"
            release_lock "$1"
            continue
        fi
        if [[ $waited -eq 0 ]]; then
            log DEBUG "waiting for the lock of process ${holder:-?}: $2"
            # A "~": another scan fetches this entry, this one waits for it.
            if [[ -t 2 ]]; then
                printf '%s~%s' "$YELLOW" "$NC" >&2
            fi
        fi
        LOCK_WAITED=1
        waited=$((waited + 1))
        sleep 0.2
    done
    echo "$$" >| "$1/pid"
    echo "$2" >| "$1/key"
}

release_lock() {
    rm -f "$1/pid" "$1/key"
    rmdir "$1" 2>/dev/null || true
}

# Remove the locks of this process, e.g. after Ctrl-C during a request.
# Called by a trap.
# shellcheck disable=SC2329
remove_own_locks() {
    if [[ ! -d "$LOCK_DIR" ]]; then
        return 0
    fi
    local pid_file
    for pid_file in "$LOCK_DIR"/*/pid; do
        if [[ -f "$pid_file" && "$(cat "$pid_file")" == "$$" ]]; then
            release_lock "${pid_file%/pid}"
        fi
    done
}

# Percent-encode all characters except letters, digits, "-", ".", "_", "~"
# and "/" (it stays a path separator). Byte by byte: a branch name like
# "51-produktübersicht" must not reach GitHub as raw UTF-8 (HTTP 400).
url_encode() {
    local LC_ALL=C
    local s="$1" out="" c i byte
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9._~/-]) out+="$c" ;;
            *)
                # bash 3.2 reads a byte above 127 as a negative number.
                printf -v byte '%d' "'$c"
                if [[ $byte -lt 0 ]]; then
                    byte=$((byte + 256))
                fi
                printf -v c '%%%02X' "$byte"
                out+="$c"
                ;;
        esac
    done
    echo "$out"
}

# GNU stat first, then BSD stat (macOS).
file_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

# Remove temporary cache files of this scan and of scans that no longer run.
# A scan killed between write and rename leaves one behind.
remove_temp_files() {
    if [[ ! -d "$CACHE_DIR" ]]; then
        return 0
    fi
    local tmp pid
    while IFS= read -r tmp; do
        pid="${tmp##*.tmp.}"
        # Short option: BSD ps (macOS) has no --pid.
        if [[ "$pid" == "$$" ]] || ! ps -p "$pid" > /dev/null 2>&1; then
            rm -f "$tmp"
        fi
    done < <(find "$CACHE_DIR" -type f -name '*.tmp.*')
}

# A red "x" replaces the dot of an attempt that failed with a network or
# GitHub error and is sent again.
mark_failed_attempt() {
    if [[ -t 2 ]]; then
        printf '\b%sx%s' "$RED" "$NC" >&2
    fi
}

# Print the HTTP status of a failed gh call, or nothing. gh ends a line with
# "... (HTTP 404)" or, without a message, with "gh: HTTP 400". A hint can
# follow on the next line (e.g. about token scopes): use the last such line.
http_status() {
    local line status=""
    while IFS= read -r line; do
        if [[ "$line" =~ HTTP\ ([0-9][0-9][0-9])\)?$ ]]; then
            status="${BASH_REMATCH[1]}"
        fi
    done <<< "$1"
    echo "$status"
}

# GitHub refused the request because of the (primary or secondary) rate limit.
is_rate_limited() {
    if [[ "$1" == *RATE_LIMITED* ]]; then
        return 0
    fi
    local status
    status=$(http_status "$1")
    [[ ( "$status" == "403" || "$status" == "429" ) && "$1" == *[Rr]"ate limit"* ]]
}

# A GraphQL error has an "errors" list. Without an HTTP status and without
# it, the request did not get a response.
is_retryable_error() {
    if [[ "$1" == *'"errors":['* ]]; then
        return 1
    fi
    local status
    status=$(http_status "$1")
    if [[ -n "$status" ]]; then
        [[ $status -ge 500 ]]
    else
        return 0
    fi
}

# Short options only: BSD mkdir and mv (macOS) have no long options.
write_cache_entry() {
    # This fails if a file has the name of the directory, e.g. for a branch
    # "release" that was replaced by "release/x". Then do not cache.
    mkdir -p "$(dirname "$1")" 2>/dev/null || return 0
    # Write to a temporary file first: an interrupted scan must not leave a partial entry.
    printf '%s' "$2" >| "$1.tmp.$$"
    mv -f "$1.tmp.$$" "$1"
}

# Like gh_cached, but fetch even if the entry is cached (and write it).
gh_fresh() {
    local USE_CACHE=0
    gh_cached "$@"
}
