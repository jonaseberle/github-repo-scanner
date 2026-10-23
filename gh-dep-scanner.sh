#!/bin/bash

#===============================================================================
# GitHub Dependency Scanner
# Scans all repositories in a GitHub org or personal account to find repos
# that use a package in an affected version range.
#
# Requirements: gh (GitHub CLI), jq
# Usage: ./gh-dep-scanner.sh [options] or run interactively
#===============================================================================

set -o errexit -o nounset -o pipefail -o noclobber

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m' # No Color
BOLD=$'\033[1m'
# One color per kind of value, wherever it is printed.
COLOR_BRANCH=$'\033[0;35m'
COLOR_PATH=$'\033[0;34m'
COLOR_VERSION=$'\033[1m'
COLOR_VISIBILITY=$'\033[2m'
COLOR_PACKAGE=$'\033[4m'
# The version with --affected: bold like COLOR_VERSION, red or green. One code
# each: "$BOLD$RED" would end the bold, the "0;" of RED resets it.
COLOR_AFFECTED=$'\033[1;31m'
COLOR_NOT_AFFECTED=$'\033[1;32m'

# Default values
DELAY=0
BRANCH=""
BRANCHES=""
HIDE_MERGED=0
# --hide-unknown: no VERSION FILE NOT FOUND rows. --hide-absent: also no PACKAGE NOT FOUND rows.
HIDE_UNKNOWN=0
HIDE_ABSENT=0
ALTERNATIVE_PATHS=""
REPO_FILTER=""
SHOW_VISIBILITY=0
CACHE_DIR="./var/cache"
# One lock per cache key while a process fetches it: others wait for it.
LOCK_DIR="./var/lock"
# Start of this scan (epoch seconds): an entry written since then is fresh.
SCAN_STARTED=$(date +%s)
LOG_FILE="./var/log/gh-dep-scanner.log"
# At startup, a log of this size or more is cut to its newer half.
LOG_MAX_BYTES=$((20 * 1024 * 1024))
# bash 4.2 and later format the time without "date": no process per log line.
# bash 3.2 (macOS) runs "date" once per second of $SECONDS; the time can then be up to 1 s late.
LOG_TIME_BUILTIN=0
if [[ ${BASH_VERSINFO[0]} -gt 4 || ( ${BASH_VERSINFO[0]} -eq 4 && ${BASH_VERSINFO[1]} -ge 2 ) ]]; then
    LOG_TIME_BUILTIN=1
fi
LOG_TIME=""
LOG_TIME_SECOND=-1
USE_CACHE=1
OFFLINE=0
# Terminal width, for the progress line and the result table.
TERM_COLUMNS=$(tput cols 2>/dev/null || echo 80)
# One line per request: "cache <mtime>" or "network".
# A file, because gh_cached runs in subshells.
REQUEST_LOG=""
# The rate limits: "<bucket> <remaining> <limit> <reset> <network requests then>".
# Shared by all scans in this directory: they use the same rate limit.
RATE_FILE="./var/lock/rate-limit"
# One byte per network request of any scan in this directory.
RATE_COUNTER="./var/lock/rate-requests"
# Check the rate limit again after this many network requests.
RATE_CHECK_EVERY=50
URL=""
REPO=""
TYPE=""
PACKAGES=""
AFFECTED=""
# --affected, parsed: per condition the group number, the operator and the
# version (major, minor, patch).
declare -a RANGE_GROUPS=()
declare -a RANGE_OPERATORS=()
declare -a RANGE_MAJORS=()
declare -a RANGE_MINORS=()
declare -a RANGE_PATCHES=()
# Set by parse_version.
declare -a VERSION=()

# Results arrays
declare -a RESULT_URLS=()
declare -a RESULT_VERSIONS=()
declare -a RESULT_VISIBILITY=()
declare -a RESULT_PATHS=()
declare -a RESULT_BRANCHES=()
declare -a RESULT_PACKAGES=()
declare -a RESULT_STATUS=()

# Counters
TOTAL_REPOS=0
AFFECTED_COUNT=0
FOUND_COUNT=0
NO_FILE_COUNT=0
PARSE_ERROR_COUNT=0
NOT_FOUND_COUNT=0
BRANCHES_SCANNED=0
NO_BRANCH_COUNT=0
MERGED_COUNT=0
# Directories with package-lock.json and yarn.lock.
LOCK_CONFLICT_COUNT=0
FILTERED_OUT_COUNT=0
REFRESHED_COUNT=0
# Stays empty for a single repository.
ARCHIVED_COUNT=""

#===============================================================================
# HELPER FUNCTIONS
#===============================================================================

show_help() {
    cat << EOF
${BOLD}GitHub Dependency Scanner${NC}

Scans all repositories in a GitHub organization or personal account (or a
single repository) to find repos that use a package in an affected version range.

${BOLD}USAGE:${NC}
    ./gh-dep-scanner.sh [OPTIONS]
    ./gh-dep-scanner.sh                    # Interactive mode

${BOLD}OPTIONS:${NC}
    Options with a value take the form --option=value.

    --url=<url>         GitHub URL (org or personal repos page, or one repo)
                        Examples:
                          https://github.com/orgs/MyOrg/repositories
                          https://github.com/username?tab=repositories
                          https://github.com/username
                          https://github.com/orgs/MyOrg
                          https://github.com/owner/repo

    --type=<type>       Dependency type:
                          composer      installed version from composer.lock
                          composerJson  version constraint from composer.json
                          node          installed version from package-lock.json
                                        or yarn.lock
                          nodeJson      version constraint from package.json

    --packages[=regex]  Packages to search for: an extended regular expression
                        for the package names. Without a regex: all packages.
                        Examples: --packages='^livewire/livewire$',
                                  --packages='^typo3/cms-', --packages=react

    --affected=<ranges> Optional: show which packages are in these version
                        ranges, in the form of security advisories (e.g. on
                        packagist.org): "|" separates alternatives, "," joins
                        conditions. Operators: >=, >, <=, <, =, !=.
                        Example: --affected='>=13.0.0,<13.3.5|<6.4.5'
                        Default: show all found packages

    --repo=<regex>      Optional: check only the repositories whose name (without
                        the owner) matches this extended regular expression
                        Examples: --repo='^typo3-', --repo='\.de$'

    --branch=<name>     Optional: specific branch to check
                        Default: repository's default branch

    --branches[=regex]  Optional: check all branches that match this extended
                        regular expression, instead of one branch.
                        Without a regex: check all branches.
                        Examples: --branches='^feat/|^upgrade/'
                                  --branches=typo3 --branches='upgrade$'

    --hide-unknown      Optional: hide the rows without a dependency file
                        (VERSION FILE NOT FOUND)

    --hide-absent       Optional: also hide the rows without a matching package
                        (PACKAGE NOT FOUND)

    --hide-merged       Optional, with --branches: hide the branches that are
                        fully merged into the default branch (one request per
                        100 branches). Squash and rebase merges are not detected.

    --delay=<seconds>   Optional: delay after each network request (default: 0)
                        Requests served from the cache do not wait.
                        Without it, the scan slows down by itself when less
                        than 20 % of the rate limit is left, and it waits for
                        the reset when the limit is used up.

    --alternativePaths[=regex]
                        Optional: also check the dependency files in the
                        directories that match this extended regular
                        expression. One row per dependency file.
                        Without a regex: all directories.
                        Example: --alternativePaths='^(webroot|packages/[^/]+)$'

    --show-visibility   Optional: add a column with the repository
                        visibility (public/private)

    --offline           Optional: use the cached repository list and do not
                        check for pushes. Once cached, a scan needs no network.

    --no-cache          Optional: do not read the cache in ./var/cache.
                        New responses are still written to it.
                        To fetch one request again, delete its entry there.

    -v, --verbose       Print each command before it runs (set -x)

    --help              Show this help message

${BOLD}EXAMPLES:${NC}
    # Interactive mode
    ./gh-dep-scanner.sh

    # Find repos with livewire < 4 in an organization
    ./gh-dep-scanner.sh --url="https://github.com/orgs/YOUR_ORG/repositories" \\
                        --type=composer \\
                        --packages=livewire/livewire \\
                        --affected='<4'

    # Find repos with react < 18 for a user
    ./gh-dep-scanner.sh --url="https://github.com/USERNAME" \\
                        --type=node \\
                        --packages=react \\
                        --affected='<18'

    # Specify a branch
    ./gh-dep-scanner.sh --url="https://github.com/orgs/YOUR_ORG/repositories" \\
                        --type=composer \\
                        --packages=laravel/framework \\
                        --affected='<10' \\
                        --branch=develop

${BOLD}REQUIREMENTS:${NC}
    - gh (GitHub CLI) - must be installed and authenticated
    - jq (JSON parser) - for parsing dependency files

EOF
}

# Prepare the log file and keep it below LOG_MAX_BYTES.
# Short options only: BSD wc, tail and mkdir (macOS) have no long options.
init_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(wc -c < "$LOG_FILE")
        if [[ $size -ge $LOG_MAX_BYTES ]]; then
            # Drop the first line: the cut can be in the middle of it.
            tail -c $((size / 2)) "$LOG_FILE" | sed '1d' >| "$LOG_FILE.tmp.$$"
            mv -f "$LOG_FILE.tmp.$$" "$LOG_FILE"
            log INFO "Log was $size bytes: cut to the newer half."
        fi
    fi
}

# Arguments: severity (DEBUG, INFO, WARN, ERROR), message.
# One line per message: timestamp, process id, severity, message.
log() {
    local severity="$1"
    shift
    local message="$*"
    message="${message//$'\n'/ }"
    if [[ $LOG_TIME_BUILTIN -eq 1 ]]; then
        printf -v LOG_TIME '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    elif [[ $SECONDS -ne $LOG_TIME_SECOND ]]; then
        LOG_TIME=$(date '+%Y-%m-%dT%H:%M:%S%z')
        LOG_TIME_SECOND=$SECONDS
    fi
    printf '%s [%s] %-5s %s\n' "$LOG_TIME" "$$" "$severity" "$message" >> "$LOG_FILE"
}

print_error() {
    log ERROR "$1"
    # The progress line has no line break at its end.
    if [[ $PROGRESS_SHOWN -eq 1 ]]; then
        echo "" >&2
    fi
    echo -e "${RED}Error: $1${NC}" >&2
}

# A warning during the scan, on stderr: the caller may capture stdout.
print_warning_line() {
    log WARN "$1"
    if [[ $PROGRESS_SHOWN -eq 1 ]]; then
        echo "" >&2
    fi
    echo -e "${YELLOW}Warning: $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_info() {
    echo -e "${BLUE}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}$1${NC}"
}

PROGRESS_SHOWN=0

# Arguments: pairs of color and text.
# On stderr and only on a terminal, like the dots: stdout can go to a file.
# Cut the line to the terminal width: a wrapped line is not cleared by "\r".
# Keep room for the dots of the network requests.
print_progress() {
    if [[ ! -t 2 ]]; then
        return 0
    fi
    PROGRESS_SHOWN=1
    local max=$((TERM_COLUMNS - 12)) used=0 out="" color text keep
    while [[ $# -ge 2 ]]; do
        color="$1"
        text="$2"
        shift 2
        if [[ $((used + ${#text})) -gt $max ]]; then
            keep=$((max - used - 3))
            if [[ $keep -lt 0 ]]; then
                keep=0
            fi
            out+="$color${text:0:$keep}...$NC"
            break
        fi
        out+="$color$text$NC"
        used=$((used + ${#text}))
    done
    printf '\r\033[K%s ' "$out" >&2
}

clear_progress() {
    if [[ $PROGRESS_SHOWN -eq 1 ]]; then
        printf '\r\033[K' >&2
        PROGRESS_SHOWN=0
    fi
}

# Space-separated, in the order they are tried.
dep_file_names() {
    case "$TYPE" in
        composer) echo "composer.lock" ;;
        composerJson) echo "composer.json" ;;
        node) echo "package-lock.json yarn.lock" ;;
        *) echo "package.json" ;;
    esac
}

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

format_age() {
    local seconds="$1"
    if [[ $seconds -ge 86400 ]]; then
        echo "$((seconds / 86400))d $((seconds % 86400 / 3600))h"
    elif [[ $seconds -ge 3600 ]]; then
        echo "$((seconds / 3600))h $((seconds % 3600 / 60))m"
    elif [[ $seconds -ge 60 ]]; then
        echo "$((seconds / 60))m $((seconds % 60))s"
    else
        echo "${seconds}s"
    fi
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

# The rate limit bucket of a gh call: GraphQL ("api graphql", "repo view")
# or REST ("core").
rate_bucket() {
    if [[ "$1" == "repo" || "${2:-}" == "graphql" ]]; then
        echo "graphql"
    else
        echo "core"
    fi
}

# The network requests of all scans in this directory (see RATE_COUNTER).
# Short option: BSD wc (macOS) has no --bytes.
network_requests() {
    if [[ -f "$RATE_COUNTER" ]]; then
        echo $(($(wc -c < "$RATE_COUNTER")))
    else
        echo 0
    fi
}

# Store the rate limits in RATE_FILE. "gh api rate_limit" does not count.
check_rate_limit() {
    if [[ $OFFLINE -eq 1 ]]; then
        return 0
    fi
    local limits requests
    limits=$(gh api rate_limit --jq '
        "core \(.resources.core.remaining) \(.resources.core.limit) \(.resources.core.reset)",
        "graphql \(.resources.graphql.remaining) \(.resources.graphql.limit) \(.resources.graphql.reset)"' 2>/dev/null) || return 0
    requests=$(network_requests)
    # Written at once (rename): another scan may read it now.
    write_cache_entry "$RATE_FILE" "$(echo "$limits" | awk -v requests="$requests" '{ print $0, requests }')"
    log INFO "Rate limit: $(echo "$limits" | awk '{ printf "%s %s of %s; ", $1, $2, $3 }')"
}

# Field $2 of the rate limit of bucket $1: 2 remaining, 3 limit, 4 reset,
# 5 network requests at the check.
rate_value() {
    awk -v bucket="$1" -v field="$2" '$1 == bucket { print $field }' "$RATE_FILE" 2>/dev/null
}

# "Rate limit: REST 4941 of 5000, GraphQL 4990 of 5000, resets at 00:01:06"
rate_limit_summary() {
    if [[ ! -s "$RATE_FILE" ]]; then
        echo "Rate limit: unknown"
        return
    fi
    echo "Rate limit: REST $(rate_value core 2) of $(rate_value core 3), GraphQL $(rate_value graphql 2) of $(rate_value graphql 3), resets at $(format_clock "$(rate_value core 4)")"
}

format_clock() {
    jq --null-input --raw-output --argjson time "$1" '$time | strflocaltime("%H:%M:%S")'
}

# Wait until epoch second $1, with a countdown. $2: the reason (for the log).
wait_until() {
    local until="$1" now
    if [[ $until -le $(date +%s) ]]; then
        return 0
    fi
    log WARN "$2: waiting until $(format_clock "$until")"
    if [[ $PROGRESS_SHOWN -eq 1 && -t 2 ]]; then
        echo "" >&2
    fi
    while now=$(date +%s); [[ $now -lt $until ]]; do
        if [[ -t 2 ]]; then
            printf '\r\033[K%s%s: waiting %s, until %s%s' "$YELLOW" "$2" "$(format_age $((until - now)))" "$(format_clock "$until")" "$NC" >&2
        fi
        sleep 1
    done
    if [[ -t 2 ]]; then
        printf '\r\033[K' >&2
    fi
}

# Before a network request: wait for the reset if the limit is used up.
# With less than 20 % left, spread the rest evenly until the reset.
pace_requests() {
    if [[ $OFFLINE -eq 1 || ! -s "${RATE_FILE:-}" ]]; then
        return 0
    fi
    local requests checked
    requests=$(network_requests)
    checked=$(rate_value "$1" 5)
    if [[ -z "$checked" ]]; then
        return 0
    fi
    if [[ $((requests - checked)) -ge $RATE_CHECK_EVERY ]]; then
        check_rate_limit
        checked=$(rate_value "$1" 5)
    fi
    local remaining limit reset now left
    remaining=$(rate_value "$1" 2)
    limit=$(rate_value "$1" 3)
    reset=$(rate_value "$1" 4)
    now=$(date +%s)
    left=$((remaining - (requests - checked)))
    if [[ $left -le 0 ]]; then
        wait_until "$reset" "Rate limit used up"
        check_rate_limit
    elif [[ $((left * 5)) -lt $limit && $reset -gt $now ]]; then
        log DEBUG "Rate limit: $left of $limit left, $(((reset - now) / left)) s per request until the reset"
        # A "z": the scan slows down for the rate limit.
        if [[ -t 2 ]]; then
            printf '%sz%s' "$YELLOW" "$NC" >&2
        fi
        sleep $(((reset - now) / left))
    fi
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

#===============================================================================
# PREREQUISITES CHECK
#===============================================================================

check_prerequisites() {
    local missing=0

    # Check for gh CLI
    if ! command -v gh &> /dev/null; then
        print_error "GitHub CLI (gh) is not installed."
        echo "  Install it from: https://cli.github.com/"
        missing=1
    else
        # Check if gh is authenticated.
        # "gh auth token" reads the local login only. "gh auth status" needs the network.
        if ! gh auth token &> /dev/null; then
            print_error "GitHub CLI is not authenticated."
            echo "  Run: gh auth login"
            missing=1
        fi
    fi

    # Check for jq
    if ! command -v jq &> /dev/null; then
        print_error "jq is not installed."
        echo "  Install it with: brew install jq"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        exit 1
    fi

    print_success "Prerequisites check passed."
}

#===============================================================================
# ARGUMENT PARSING
#===============================================================================

parse_args() {
    # Values only in the form --option=value: personal preference.
    while [[ $# -gt 0 ]]; do
        case $1 in
            --*=)
                print_error "${1%=} needs a value: use $1<value>."
                exit 1
                ;;
            --url=*)
                URL="${1#*=}"
                ;;
            --type=*)
                TYPE="${1#*=}"
                ;;
            --packages=*)
                PACKAGES="${1#*=}"
                ;;
            --packages)
                # Without a value, match all packages.
                PACKAGES="."
                ;;
            --package|--package=*)
                print_error "--package is now --packages=<regex>, e.g. --packages='^vendor/name\$'."
                exit 1
                ;;
            --affected=*)
                AFFECTED="${1#*=}"
                ;;
            --below|--below=*)
                print_error "--below is now --affected=<ranges>, e.g. --affected='<${1#--below=}'."
                exit 1
                ;;
            --repo=*)
                REPO_FILTER="${1#*=}"
                ;;
            --branch=*)
                BRANCH="${1#*=}"
                ;;
            --branches=*)
                BRANCHES="${1#*=}"
                ;;
            --branches)
                # Without a value, match all branches.
                BRANCHES="."
                ;;
            --delay=*)
                DELAY="${1#*=}"
                ;;
            --alternativePaths=*)
                ALTERNATIVE_PATHS="${1#*=}"
                ;;
            --alternativePaths)
                # Without a value, every directory matches.
                ALTERNATIVE_PATHS="."
                ;;
            --show-visibility)
                SHOW_VISIBILITY=1
                ;;
            --hide-merged)
                HIDE_MERGED=1
                ;;
            --hide-unknown)
                HIDE_UNKNOWN=1
                ;;
            --hide-absent)
                HIDE_UNKNOWN=1
                HIDE_ABSENT=1
                ;;
            --no-cache)
                USE_CACHE=0
                ;;
            --offline)
                OFFLINE=1
                ;;
            -v|--verbose)
                set -x
                ;;
            --help)
                show_help
                exit 0
                ;;
            --url|--type|--affected|--repo|--branch|--delay)
                print_error "$1 needs a value: use $1=<value>."
                exit 1
                ;;
            *)
                print_error "Unknown option: $1"
                if [[ "$1" != -* ]]; then
                    echo "Values take the form --option=value, e.g. --type=composer."
                fi
                echo "Use --help for usage information."
                exit 1
                ;;
        esac
        shift
    done
}

#===============================================================================
# INTERACTIVE MODE
#===============================================================================

interactive_mode() {
    echo -e "${BOLD}GitHub Dependency Scanner - Interactive Mode${NC}"
    echo "=============================================="
    echo ""

    # URL
    if [[ -z "$URL" ]]; then
        echo -e "${CYAN}Enter GitHub URL:${NC}"
        echo "  Examples:"
        echo "    https://github.com/orgs/YOUR_ORG/repositories"
        echo "    https://github.com/USERNAME?tab=repositories"
        echo "    https://github.com/USERNAME"
        echo "    https://github.com/OWNER/REPO"
        read -r -p "> " URL
        echo ""
    fi

    # Type
    if [[ -z "$TYPE" ]]; then
        echo -e "${CYAN}Select dependency type:${NC}"
        echo "  1) composer (PHP - composer.lock, installed version)"
        echo "  2) node (JavaScript - package-lock.json or yarn.lock, installed version)"
        echo "  3) composerJson (PHP - composer.json, version constraint)"
        echo "  4) nodeJson (JavaScript - package.json, version constraint)"
        read -r -p "> " type_choice
        case $type_choice in
            1|composer) TYPE="composer" ;;
            2|node) TYPE="node" ;;
            3|composerJson) TYPE="composerJson" ;;
            4|nodeJson) TYPE="nodeJson" ;;
            *)
                print_error "Invalid choice. Please enter 1, 2, 3, 4, 'composer', 'node', 'composerJson', or 'nodeJson'."
                exit 1
                ;;
        esac
        echo ""
    fi

    # Packages
    if [[ -z "$PACKAGES" ]]; then
        echo -e "${CYAN}Enter a regular expression for the package names (press Enter for all packages):${NC}"
        if [[ "$TYPE" != node* ]]; then
            echo "  Example: ^livewire/livewire\$, ^typo3/cms-"
        else
            echo "  Example: ^react\$, ^@babel/"
        fi
        read -r -p "> " PACKAGES
        echo ""
        if [[ -z "$PACKAGES" ]]; then
            PACKAGES="."
        fi
    fi

    # Affected versions
    if [[ -z "$AFFECTED" ]]; then
        echo -e "${CYAN}Enter the affected version ranges (press Enter to show all found packages):${NC}"
        echo "  Example: <4, >=13.0.0,<13.3.5|<6.4.5"
        read -r -p "> " AFFECTED
        echo ""
    fi

    # Branch (optional)
    if [[ -z "$BRANCH" && -z "$BRANCHES" ]]; then
        echo -e "${CYAN}Enter branch name (press Enter for default branch):${NC}"
        read -r -p "> " BRANCH
        echo ""
    fi
}

#===============================================================================
# URL PARSING
#===============================================================================

parse_github_url() {
    local url="$1"

    # Remove trailing slashes
    url="${url%/}"

    # Pattern: https://github.com/orgs/NAME/repositories
    if [[ "$url" =~ github\.com/orgs/([^/]+) ]]; then
        OWNER="${BASH_REMATCH[1]}"
        OWNER_TYPE="org"
        return 0
    fi

    # Pattern: https://github.com/USERNAME?tab=repositories
    if [[ "$url" =~ github\.com/([^/?]+)\? ]]; then
        OWNER="${BASH_REMATCH[1]}"
        OWNER_TYPE="user"
        return 0
    fi

    # Pattern: https://github.com/NAME (could be user or org)
    if [[ "$url" =~ github\.com/([^/?]+)$ ]]; then
        OWNER="${BASH_REMATCH[1]}"
        # Try to determine if it's an org or user
        if gh_cached "api/orgs/$OWNER?about" api "orgs/$OWNER" --jq "$REPOS_COUNT" &> /dev/null; then
            OWNER_TYPE="org"
        else
            OWNER_TYPE="user"
        fi
        return 0
    fi

    # Pattern: https://github.com/OWNER/REPO (a single repository)
    if [[ "$url" =~ github\.com/([^/?]+)/([^/?]+)$ ]]; then
        OWNER="${BASH_REMATCH[1]}"
        REPO="${BASH_REMATCH[2]%.git}"
        OWNER_TYPE="repo"
        return 0
    fi

    print_error "Could not parse GitHub URL: $url"
    echo "  Expected formats:"
    echo "    https://github.com/orgs/ORG_NAME/repositories"
    echo "    https://github.com/USERNAME?tab=repositories"
    echo "    https://github.com/USERNAME"
    echo "    https://github.com/OWNER/REPO"
    exit 1
}

#===============================================================================
# REPOSITORY FETCHING
#===============================================================================

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
        repos_json=$("$view" "repo-view/$OWNER/$REPO" repo view "$OWNER/$REPO" --json name,url,isPrivate,defaultBranchRef,pushedAt --jq '[.]') || {
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
    if [[ -n "$REPO_FILTER" ]]; then
        local name matching=""
        while IFS= read -r name; do
            if [[ "$name" =~ $REPO_FILTER ]]; then
                matching+="$name"$'\n'
            else
                FILTERED_OUT_COUNT=$((FILTERED_OUT_COUNT + 1))
            fi
        done < <(echo "$repos_json" | jq -r '.[].name')
        repos_json=$(echo "$repos_json" | jq --arg names "$matching" '($names | split("\n")) as $names | [.[] | select(.name as $name | any($names[]; . == $name))]')
    fi

    REPOS_DATA="$repos_json"
    TOTAL_REPOS=$(echo "$repos_json" | jq 'length')

    if [[ $OFFLINE -eq 0 ]]; then
        refresh_pushed_repos
    fi

    if [[ "$TOTAL_REPOS" -eq 0 ]]; then
        if [[ -n "$REPO_FILTER" ]]; then
            print_warning "No repository of $OWNER matches --repo='$REPO_FILTER'"
        else
            print_warning "No repositories found for $OWNER"
        fi
        exit 0
    fi

    log INFO "Repositories of $OWNER_TYPE $OWNER: $TOTAL_REPOS to scan, ${ARCHIVED_COUNT:-0} archived, $FILTERED_OUT_COUNT not matching --repo"
    print_success "Found $TOTAL_REPOS repositories."
}

# Like gh_cached, but fetch even if the entry is cached (and write it).
gh_fresh() {
    local USE_CACHE=0
    gh_cached "$@"
}

# The REST fields of a repository, with the names of "gh repo view --json".
REPO_FIELDS='{name, url: .html_url, isPrivate: .private, isArchived: .archived, defaultBranchRef: {name: .default_branch}, pushedAt: .pushed_at, updatedAt: .updated_at}'
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

    if [[ $OFFLINE -eq 1 ]]; then
        listing=$(gh_cached "$key" api --paginate "$full_request" --jq ".[] | $REPO_FIELDS") || return 1
    elif [[ $USE_CACHE -eq 0 || ! -f "$file" ]]; then
        log INFO "Fetching the full repository list: $endpoint"
        listing=$(gh_fresh "$key" api --paginate "$full_request" --jq ".[] | $REPO_FIELDS") || return 1
        write_cache_entry "$full" ""
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

#===============================================================================
# DEPENDENCY FILE FETCHING
#===============================================================================

# Fetch the file $3 (a path, e.g. "webroot/yarn.lock") of commit $2.
# Prints its content, or NOT_FOUND or PARSE_ERROR.
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

    # yarn.lock is not JSON.
    if [[ "$file" != *.json ]] || echo "$response" | jq --exit-status 'type == "object"' &> /dev/null; then
        echo "$response"
    else
        echo "PARSE_ERROR"
    fi
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

#===============================================================================
# VERSION EXTRACTION
#===============================================================================

# "all packages" or "packages matching <regex>", for headers and the summary.
packages_label() {
    if [[ "$PACKAGES" == "." ]]; then
        echo "all packages"
    else
        echo "packages matching ${COLOR_PACKAGE}$PACKAGES${NC}"
    fi
}

# Print all packages of a dependency file: "name<TAB>version", one per line.
# A name that is listed twice (e.g. in require and require-dev) is printed once.
list_packages() {
    local content="$1"
    local dep_type="$2"

    {
        if [[ "$dep_type" == "composer" ]]; then
            # packages first, then packages-dev
            echo "$content" | jq -r '((.packages // []), (.["packages-dev"] // []))[] | "\(.name)\t\(.version)"' 2>/dev/null
        elif [[ "$dep_type" == "composerJson" ]]; then
            # require first, then require-dev
            echo "$content" | jq -r '((.require // {}), (.["require-dev"] // {})) | to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null
        elif [[ "$dep_type" == "node" && "$content" == "{"* ]]; then
            # package-lock.json: "packages" since lockfileVersion 2, "dependencies" in version 1.
            # Use the top-level node_modules entries: nested ones belong to other packages.
            echo "$content" | jq -r '
                if .packages then
                    .packages | to_entries[]
                    | select(.key | startswith("node_modules/"))
                    | (.key | ltrimstr("node_modules/")) as $name
                    | select($name | contains("node_modules/") | not)
                    | "\($name)\t\(.value.version)"
                else
                    (.dependencies // {}) | to_entries[] | "\(.key)\t\(.value.version)"
                end' 2>/dev/null
        elif [[ "$dep_type" == "node" ]]; then
            # yarn.lock (classic and berry): the version of the first entry for a package.
            echo "$content" | awk '
                /^[^ #]/ {
                    spec = $0
                    sub(/:$/, "", spec)
                    sub(/, .*/, "", spec)
                    gsub(/"/, "", spec)
                    # The name ends at the "@" of the range; a scoped name starts with "@".
                    at = index(substr(spec, 2), "@")
                    name = (at > 0) ? substr(spec, 1, at) : ""
                    next
                }
                name != "" && /^  version:? / {
                    version = $2
                    gsub(/"/, "", version)
                    print name "\t" version
                    name = ""
                }'
        else
            # dependencies first, then devDependencies
            echo "$content" | jq -r '((.dependencies // {}), (.devDependencies // {})) | to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null
        fi
    } | awk -F '\t' '!seen[$1]++'
}

# Print the packages of a dependency file that match --packages.
matching_packages() {
    local name version
    while IFS=$'\t' read -r name version; do
        if [[ -n "$name" && "$name" =~ $PACKAGES ]]; then
            printf '%s\t%s\n' "$name" "$version"
        fi
    done < <(list_packages "$1" "$TYPE")
}

#===============================================================================
# VERSION COMPARISON
#===============================================================================

# Set VERSION to the version of a constraint: (major minor patch). A missing
# part is 0. A variable, not output: no subshell for each of many rows.
parse_version() {
    local cleaned="$1"
    VERSION=(0 0 0)
    if [[ "$cleaned" == "*" || "$cleaned" == "latest" || "$cleaned" == dev-* ]]; then
        return 0
    fi

    # The first of OR constraints ("^2.0|^3.0", "^2.0 || ^3.0") and of
    # space-separated ones (">=2.0 <4.0").
    cleaned="${cleaned%%|*}"
    cleaned="${cleaned%% *}"

    # Quote "~": unquoted, bash expands it to $HOME and nothing is removed.
    cleaned="${cleaned#^}"
    cleaned="${cleaned#\~}"
    cleaned="${cleaned#>=}"
    cleaned="${cleaned#>}"
    cleaned="${cleaned#<=}"
    cleaned="${cleaned#<}"
    cleaned="${cleaned#=}"
    cleaned="${cleaned#v}"

    # "3.*" gives 3 0 0.
    if [[ "$cleaned" =~ ^([0-9]+)(\.([0-9]+))?(\.([0-9]+))? ]]; then
        VERSION=("${BASH_REMATCH[1]}" "${BASH_REMATCH[3]:-0}" "${BASH_REMATCH[5]:-0}")
    fi
}

# Parse --affected into the RANGE_* arrays.
# Stop on an invalid range.
parse_affected() {
    local -a groups conditions
    local group condition number=0
    IFS='|' read -r -a groups <<< "$AFFECTED"
    for group in ${groups[@]+"${groups[@]}"}; do
        number=$((number + 1))
        conditions=()
        IFS=',' read -r -a conditions <<< "$group"
        if [[ ${#conditions[@]} -eq 0 ]]; then
            print_error "Invalid --affected: an empty range in '$AFFECTED'."
            exit 1
        fi
        for condition in "${conditions[@]}"; do
            condition="${condition// /}"
            if [[ ! "$condition" =~ ^(\>=|\<=|!=|==|\>|\<|=)?v?([0-9]+(\.[0-9]+)*)$ ]]; then
                print_error "Invalid --affected: '$condition' (use e.g. >=1.2.3 or <2)."
                exit 1
            fi
            RANGE_GROUPS+=("$number")
            RANGE_OPERATORS+=("${BASH_REMATCH[1]:-=}")
            # After the operator: parse_version changes BASH_REMATCH.
            parse_version "${BASH_REMATCH[2]}"
            RANGE_MAJORS+=("${VERSION[0]}")
            RANGE_MINORS+=("${VERSION[1]}")
            RANGE_PATCHES+=("${VERSION[2]}")
        done
    done
}

# True if version (constraint) $1 is in one of the --affected ranges:
# all conditions of at least one group hold.
is_affected() {
    local -a have wanted
    parse_version "$1"
    have=("${VERSION[@]}")

    local i part comparison group=0 group_holds=0
    for i in "${!RANGE_OPERATORS[@]}"; do
        if [[ ${RANGE_GROUPS[$i]} -ne $group ]]; then
            if [[ $group -gt 0 && $group_holds -eq 1 ]]; then
                return 0
            fi
            group=${RANGE_GROUPS[$i]}
            group_holds=1
        fi
        if [[ $group_holds -eq 0 ]]; then
            continue
        fi

        # Compare major, then minor, then patch. "10#": a part like "08" is not octal.
        wanted=("${RANGE_MAJORS[$i]}" "${RANGE_MINORS[$i]}" "${RANGE_PATCHES[$i]}")
        comparison=0
        for part in 0 1 2; do
            if (( 10#${have[$part]} < 10#${wanted[$part]} )); then
                comparison=-1
                break
            fi
            if (( 10#${have[$part]} > 10#${wanted[$part]} )); then
                comparison=1
                break
            fi
        done

        case "${RANGE_OPERATORS[$i]}" in
            ">=") [[ $comparison -ge 0 ]] || group_holds=0 ;;
            ">") [[ $comparison -gt 0 ]] || group_holds=0 ;;
            "<=") [[ $comparison -le 0 ]] || group_holds=0 ;;
            "<") [[ $comparison -lt 0 ]] || group_holds=0 ;;
            "!=") [[ $comparison -ne 0 ]] || group_holds=0 ;;
            *) [[ $comparison -eq 0 ]] || group_holds=0 ;;
        esac
    done
    [[ $group -gt 0 && $group_holds -eq 1 ]]
}

# Print the branches of a repository that match --branches with their
# commit, "name<TAB>commit", one per line. With --hide-merged, a branch that is
# fully merged into the default branch ($2) is printed as "merged<TAB>name".
matching_branches() {
    local listing
    if [[ $HIDE_MERGED -eq 1 ]]; then
        listing=$(branches_with_merge_state "$1" "$2")
    else
        local request="repos/$OWNER/$1/branches?per_page=100"
        # "-": no merge state. Not an empty field: read joins adjacent tabs.
        listing=$(gh_cached "api/$request&heads" api --paginate "$request" --jq '.[] | "\(.name)\t-\t\(.commit.sha)"') || {
            # Only a 404 means "no branches". Other errors must stop the scan.
            if [[ "$(http_status "$listing")" == "404" ]]; then
                return 0
            fi
            print_error "Failed to fetch the branches of $OWNER/$1: $listing"
            exit 1
        }
    fi

    # Branch names contain no spaces, tabs or glob characters.
    local name behind commit
    while IFS=$'\t' read -r name behind commit; do
        if [[ -z "$name" || ! "$name" =~ $BRANCHES ]]; then
            continue
        fi
        # Nothing of the branch is missing in the default branch: it is merged.
        if [[ "$behind" == "0" && "$name" != "$2" ]]; then
            printf 'merged\t%s\n' "$name"
        else
            printf '%s\t%s\n' "$name" "$commit"
        fi
    done <<< "$listing"
}

# Print "name<TAB>commits that are not in the default branch ($2)<TAB>commit"
# for all branches of repository $1. One GraphQL request per 100 branches,
# instead of one comparison per branch.
branches_with_merge_state() {
    # $owner, $name, $base and $endCursor are GraphQL variables, not shell ones.
    # shellcheck disable=SC2016
    local query='query($owner: String!, $name: String!, $base: String!, $endCursor: String) {
        repository(owner: $owner, name: $name) {
            refs(refPrefix: "refs/heads/", first: 100, after: $endCursor) {
                pageInfo { hasNextPage endCursor }
                nodes { name target { oid } compare(headRef: $base) { behindBy } }
            }
        }
    }'
    local listing
    listing=$(gh_cached "api/repos/$OWNER/$1/branches?merged-into=$2&heads" api graphql --paginate \
        -f owner="$OWNER" -f name="$1" -f base="$2" -f query="$query" \
        --jq '.data.repository.refs.nodes[] | "\(.name)\t\(.compare.behindBy // "-")\t\(.target.oid)"') || {
        print_error "Failed to fetch the branches of $OWNER/$1: $listing"
        exit 1
    }
    echo "$listing"
}

# Print the commit of branch $2 in repository $1, or nothing if there is no
# such branch (e.g. an empty repository).
branch_commit() {
    # "gh repo view" gives an empty repository no default branch name.
    if [[ -z "$2" ]]; then
        return 0
    fi
    local commit
    commit=$(gh_cached "api/repos/$OWNER/$1/branches/$2" api "repos/$OWNER/$1/branches/$(url_encode "$2")" --jq '.commit.sha') || {
        if [[ "$(http_status "$commit")" == "404" ]]; then
            return 0
        fi
        print_error "Failed to fetch the branch $2 of $OWNER/$1: $commit"
        exit 1
    }
    echo "$commit"
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
    while IFS=$'\t' read -r branch commit; do
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
    while IFS=$'\t' read -r branch commit; do
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

#===============================================================================
# MAIN SCANNING LOGIC
#===============================================================================

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
    RESULT_PATHS+=("$3")
    RESULT_VISIBILITY+=("$4")
    RESULT_PACKAGES+=("$5")
    RESULT_VERSIONS+=("$version_str")
    RESULT_STATUS+=("$status")
}

# Add one result row per matching package of a dependency file.
# Arguments: URL, branch, path, visibility, content (or NOT_FOUND / PARSE_ERROR)
record_file() {
    local content="$5"
    if [[ "$content" == "NOT_FOUND" || "$content" == "PARSE_ERROR" ]]; then
        record_result "$1" "$2" "$3" "$4" "" "$content"
        return
    fi

    local packages name version
    packages=$(matching_packages "$content")
    if [[ -z "$packages" ]]; then
        record_result "$1" "$2" "$3" "$4" "" "NOT_IN_FILE"
        return
    fi
    while IFS=$'\t' read -r name version; do
        record_result "$1" "$2" "$3" "$4" "$name" "$version"
    done <<< "$packages"
}


scan_repos() {
    echo ""
    echo -e "${BOLD}Scanning $OWNER repositories for ${NC}$(packages_label)${AFFECTED:+, affected: ${COLOR_VERSION}$AFFECTED${NC}}..."
    if [[ -n "$BRANCHES" ]]; then
        echo -e "Branches: matching ${COLOR_BRANCH}$BRANCHES${NC}"
    elif [[ -n "$BRANCH" ]]; then
        echo -e "Branch: ${COLOR_BRANCH}$BRANCH${NC}"
    else
        echo -e "Branch: ${COLOR_BRANCH}default${NC}"
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

        # One line per branch: "name<TAB>commit".
        collect_candidates "$repo_name" "$branches"
        prefetch_repo_files "$repo_name" "$branches"
        local branch_count branch_number=0 commit
        branch_count=$(echo "$branches" | awk 'NF > 0 { n++ } END { print n + 0 }')
        while IFS=$'\t' read -r target_branch commit; do
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
            local found=0 found_dirs=""
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
                fi
                found_dirs+="$dir"$'\n'
                # The PATH column: the lock file with --type=node (there can be two), else the directory.
                if [[ "$TYPE" != "node" ]]; then
                    path="$dir"
                fi
                record_file "$repo_url" "$target_branch" "$path" "$visibility" "$content"
            done <<< "$candidates"
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

#===============================================================================
# OUTPUT
#===============================================================================

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
# If the row is too wide, shrink in this order: branch, path and package
# (they wrap after a "/"), then the version (it wraps at spaces), then the URL (it gets
# its own line, because a URL never wraps).
set_column_widths() {
    local i url_width=8 version_width=7 path_width=0 branch_width=0 package_width=7
    for i in "${!RESULT_STATUS[@]}"; do
        if [[ ${#RESULT_URLS[$i]} -gt $url_width ]]; then
            url_width=${#RESULT_URLS[$i]}
        fi
        if [[ ${#RESULT_VERSIONS[$i]} -gt $version_width ]]; then
            version_width=${#RESULT_VERSIONS[$i]}
        fi
        if show_path_column && [[ ${#RESULT_PATHS[$i]} -gt $path_width ]]; then
            path_width=${#RESULT_PATHS[$i]}
        fi
        if show_branch_column && [[ ${#RESULT_BRANCHES[$i]} -gt $branch_width ]]; then
            branch_width=${#RESULT_BRANCHES[$i]}
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

    local over=$((url_width + branch_width + path_width + package_width + version_width - available))
    local cut
    if [[ $over -gt 0 && $branch_width -gt 12 ]]; then
        cut=$((branch_width - 12 < over ? branch_width - 12 : over))
        branch_width=$((branch_width - cut))
        over=$((over - cut))
    fi
    if [[ $over -gt 0 && $path_width -gt 12 ]]; then
        cut=$((path_width - 12 < over ? path_width - 12 : over))
        path_width=$((path_width - cut))
        over=$((over - cut))
    fi
    if [[ $over -gt 0 && $package_width -gt 12 ]]; then
        cut=$((package_width - 12 < over ? package_width - 12 : over))
        package_width=$((package_width - cut))
        over=$((over - cut))
    fi
    if [[ $over -gt 0 && $version_width -gt 10 ]]; then
        cut=$((version_width - 10 < over ? version_width - 10 : over))
        version_width=$((version_width - cut))
        over=$((over - cut))
    fi
    if [[ $over -gt 0 && $url_width -gt 20 ]]; then
        cut=$((url_width - 20 < over ? url_width - 20 : over))
        url_width=$((url_width - cut))
    fi

    URL_COLUMN_WIDTH=$url_width
    VERSION_COLUMN_WIDTH=$version_width
    PATH_COLUMN_WIDTH=$path_width
    BRANCH_COLUMN_WIDTH=$branch_width
    PACKAGE_COLUMN_WIDTH=$package_width
}

# The BRANCH column: only with --branches.
show_branch_column() {
    [[ -n "$BRANCHES" ]]
}

# The PATH column shows where the file was found: with --alternativePaths, and
# with --type=node, where a directory can have package-lock.json and yarn.lock.
show_path_column() {
    [[ -n "$ALTERNATIVE_PATHS" || "$TYPE" == "node" ]]
}

# Arguments: color, URL, branch, path, package, version, visibility, and
# optionally the color of the version and a mark for the end of the row.
# A branch, path, package or version that is too wide wraps and stays in its column.
# A URL never wraps: a line break makes it unclickable. A URL that is too
# wide gets its own line, and the other cells start on the next line.
print_row() {
    local -a url_lines=("$2") branch_lines=() path_lines=() package_lines=() version_lines=()
    local line
    if [[ ${#2} -gt $URL_COLUMN_WIDTH ]]; then
        printf "%s%s%s\n" "$1" "$2" "$NC"
        url_lines=("")
    fi
    # A cell that fits needs no wrap: no subshell for most rows.
    if ! show_branch_column; then
        :
    elif [[ ${#3} -le $BRANCH_COLUMN_WIDTH ]]; then
        branch_lines=("$3")
    else
        while IFS= read -r line; do
            branch_lines+=("$line")
        done < <(wrap_path "$BRANCH_COLUMN_WIDTH" "$3")
    fi
    if ! show_path_column; then
        :
    elif [[ ${#4} -le $PATH_COLUMN_WIDTH ]]; then
        path_lines=("$4")
    else
        while IFS= read -r line; do
            path_lines+=("$line")
        done < <(wrap_path "$PATH_COLUMN_WIDTH" "$4")
    fi
    if [[ ${#5} -le $PACKAGE_COLUMN_WIDTH ]]; then
        package_lines=("$5")
    else
        while IFS= read -r line; do
            package_lines+=("$line")
        done < <(wrap_path "$PACKAGE_COLUMN_WIDTH" "$5")
    fi
    if [[ ${#6} -le $VERSION_COLUMN_WIDTH ]]; then
        version_lines=("$6")
    else
        while IFS= read -r line; do
            version_lines+=("$line")
        done < <(wrap_text "$VERSION_COLUMN_WIDTH" "$6")
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

    # The URL has the color of the group, the other cells the color of their column.
    # The header (bold) and the dashes (no color) have one color for all cells.
    local branch_color="$COLOR_BRANCH" path_color="$COLOR_PATH" package_color="$COLOR_PACKAGE"
    local version_color="${8:-$COLOR_VERSION}" visibility_color="$COLOR_VISIBILITY"
    if [[ -z "$1" || "$1" == "$BOLD" ]]; then
        branch_color="$1" path_color="$1" package_color="$1" version_color="$1" visibility_color="$1"
    fi

    # Pad first, then color: the color codes have no width.
    local i row cell
    for ((i = 0; i < count; i++)); do
        printf -v cell "%-*s" "$URL_COLUMN_WIDTH" "${url_lines[$i]:-}"
        row="$1$cell$NC"
        if show_branch_column; then
            printf -v cell "%-*s" "$BRANCH_COLUMN_WIDTH" "${branch_lines[$i]:-}"
            row+=" $branch_color$cell$NC"
        fi
        if show_path_column; then
            printf -v cell "%-*s" "$PATH_COLUMN_WIDTH" "${path_lines[$i]:-}"
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
                row+=" $visibility_color$7$NC"
            fi
        else
            row+=" $version_color${version_lines[$i]:-}$NC"
        fi
        if [[ $i -eq 0 && -n "${9:-}" ]]; then
            row+=" $COLOR_AFFECTED$9$NC"
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
    echo -e "${BOLD}Results: ${NC}$(packages_label)${BOLD} in repositories${NC}${AFFECTED:+ (affected: ${COLOR_VERSION}$AFFECTED${NC})}"
    echo "================================================================================"
    echo ""

    # Print header
    set_column_widths
    print_row "$BOLD" "REPO URL" "BRANCH" "PATH" "PACKAGE" "VERSION" "VISIBILITY"
    print_row "" "--------" "------" "----" "-------" "-------" "----------"

    local has_results=0

    # Sort the rows by URL, branch, path and package. The index is the last field.
    local sorted_rows
    # RESULT_STATUS is added last: after an interrupt, the other arrays can be longer.
    sorted_rows=$(for i in "${!RESULT_STATUS[@]}"; do echo "${RESULT_URLS[$i]} ${RESULT_BRANCHES[$i]} ${RESULT_PATHS[$i]} ${RESULT_PACKAGES[$i]} $i"; done | sort --ignore-case | awk '{ print $NF }')

    # Group the rows: version found, package not found, no file, parse error.
    # A string, not an array: an empty array fails with nounset in bash 3.2 (macOS).
    local ordered_rows="" wanted_status i
    for wanted_status in found not_in_file no_file error; do
        # The summary still counts the hidden rows.
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
            echo -e "${BOLD}$group${NC}"
        fi

        # With --affected, the color of the version and a "*" at the end show
        # whether it is affected. Not affected rows do not count as results.
        if [[ "$status" == "affected" ]]; then
            print_row "$GREEN" "$url" "$branch" "$path" "$package" "$version" "$visibility" "$COLOR_AFFECTED" "*"
            has_results=1
        elif [[ "$status" == "not_affected" ]]; then
            print_row "$GREEN" "$url" "$branch" "$path" "$package" "$version" "$visibility" "$COLOR_NOT_AFFECTED"
        elif [[ "$status" == "found" ]]; then
            print_row "$GREEN" "$url" "$branch" "$path" "$package" "$version" "$visibility"
            has_results=1
        elif [[ "$status" == "no_file" || "$status" == "error" ]]; then
            print_row "$YELLOW" "$url" "$branch" "$path" "$package" "$version" "$visibility"
            has_results=1
        elif [[ "$status" == "not_in_file" ]]; then
            print_row "$CYAN" "$url" "$branch" "$path" "$package" "$version" "$visibility"
            has_results=1
        fi
    done

    if [[ ${#RESULT_STATUS[@]} -eq 0 && $SCAN_INTERRUPTED -eq 1 ]]; then
        echo -e "${YELLOW}No results yet.${NC}"
    elif [[ ${#RESULT_STATUS[@]} -eq 0 && $MERGED_COUNT -gt 0 ]]; then
        echo -e "${YELLOW}All matching branches are merged (hidden by --hide-merged).${NC}"
    elif [[ ${#RESULT_STATUS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No branch matches --branches '$BRANCHES'.${NC}"
    elif [[ $has_results -eq 0 ]]; then
        echo -e "${GREEN}No found package is affected.${NC}"
    fi

    # Summary
    echo ""
    echo "================================================================================"
    echo -e "${BOLD}Summary:${NC}"
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
        echo -e "  - Packages affected: ${RED}$AFFECTED_COUNT${NC}"
    else
        echo -e "  - Packages found: ${GREEN}$FOUND_COUNT${NC}"
    fi
    local unknown_note="" absent_note=""
    if [[ $HIDE_UNKNOWN -eq 1 ]]; then
        unknown_note=" (hidden)"
    fi
    if [[ $HIDE_ABSENT -eq 1 ]]; then
        absent_note=" (hidden)"
    fi
    echo -e "  - $rows without $dep_file_name: ${YELLOW}$NO_FILE_COUNT${NC}$unknown_note"
    if [[ $PARSE_ERROR_COUNT -gt 0 ]]; then
        echo -e "  - Dependency files that are not valid JSON: ${YELLOW}$PARSE_ERROR_COUNT${NC}"
    fi
    if [[ $LOCK_CONFLICT_COUNT -gt 0 ]]; then
        echo -e "  - Directories with package-lock.json and yarn.lock: ${YELLOW}$LOCK_CONFLICT_COUNT${NC}"
    fi
    echo -e "  - Files without $(packages_label): ${CYAN}$NOT_FOUND_COUNT${NC}$absent_note"

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
        echo -e "${RED}${BOLD}Scanning NOT complete.${NC}"
    fi
    echo ""
}

#===============================================================================
# MAIN
#===============================================================================

# Stop if the value of option $1 is an invalid extended regular expression.
check_regex() {
    if [[ -z "$2" ]]; then
        return 0
    fi
    # Status 2 means an invalid regular expression. We want the status of the condition.
    local regex_status=0
    # shellcheck disable=SC2319
    [[ "" =~ $2 ]] || regex_status=$?
    if [[ $regex_status -eq 2 ]]; then
        print_error "Invalid regular expression for $1: $2"
        exit 1
    fi
}

main() {
    init_log
    log INFO "Start: $0 $*"

    # Parse command line arguments
    parse_args "$@"

    REQUEST_LOG=$(mktemp)
    mkdir -p "$LOCK_DIR"
    trap 'rm -f "$REQUEST_LOG"; remove_temp_files; remove_own_locks' EXIT
    remove_temp_files

    # Check prerequisites
    check_prerequisites

    # If required arguments are missing, enter interactive mode
    if [[ -z "$URL" || -z "$TYPE" || -z "$PACKAGES" ]]; then
        interactive_mode
    fi

    # Validate inputs
    if [[ -z "$URL" ]]; then
        print_error "GitHub URL is required."
        exit 1
    fi

    if [[ "$TYPE" != "composer" && "$TYPE" != "composerJson" && "$TYPE" != "node" && "$TYPE" != "nodeJson" ]]; then
        print_error "Type must be 'composer', 'composerJson', 'node' or 'nodeJson'."
        exit 1
    fi


    parse_affected

    # A number of seconds, as "sleep" takes it.
    if [[ ! "$DELAY" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        print_error "--delay needs a number of seconds, e.g. --delay=0.5."
        exit 1
    fi

    if [[ -n "$BRANCH" && -n "$BRANCHES" ]]; then
        print_error "Use either --branch or --branches."
        exit 1
    fi

    if [[ $HIDE_MERGED -eq 1 && -z "$BRANCHES" ]]; then
        print_error "--hide-merged needs --branches."
        exit 1
    fi

    check_regex --branches "$BRANCHES"
    check_regex --repo "$REPO_FILTER"
    check_regex --packages "$PACKAGES"
    check_regex --alternativePaths "$ALTERNATIVE_PATHS"

    if [[ $USE_CACHE -eq 1 ]]; then
        print_info "Using the cache in $CACHE_DIR. Delete entries there or use --no-cache to fetch again."
    else
        print_info "Not reading the cache (--no-cache). New responses are written to $CACHE_DIR."
    fi
    if [[ $OFFLINE -eq 0 ]]; then
        check_rate_limit
        print_info "$(rate_limit_summary)"
    fi

    log INFO "Options: url=$URL type=$TYPE packages=$PACKAGES affected=$AFFECTED repo=$REPO_FILTER branch=$BRANCH branches=$BRANCHES hide-merged=$HIDE_MERGED hide-unknown=$HIDE_UNKNOWN hide-absent=$HIDE_ABSENT alternativePaths=$ALTERNATIVE_PATHS cache=$USE_CACHE offline=$OFFLINE delay=$DELAY"

    # Parse the GitHub URL
    parse_github_url "$URL"

    # Fetch repositories
    fetch_repos
    prefetch_dependency_files

    # Scan repositories
    scan_repos

    # Print results
    print_results
}

# Run main function. "exit" on the same line: bash reads the script while it
# runs it, so after main it must not read on in a file that changed meanwhile.
main "$@"; exit $?
