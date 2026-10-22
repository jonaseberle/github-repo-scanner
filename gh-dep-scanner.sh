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

# Default values
DELAY=1
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
LOG_FILE="./var/log/gh-dep-scanner.log"
# At startup, a log of this size or more is cut to its newer half.
LOG_MAX_BYTES=$((20 * 1024 * 1024))
USE_CACHE=1
# Terminal width, for the progress line and the result table.
TERM_COLUMNS=$(tput cols 2>/dev/null || echo 80)
# One line per request: "cache <mtime>" or "network".
# A file, because gh_cached runs in subshells.
REQUEST_LOG=""
URL=""
REPO=""
TYPE=""
PACKAGES=""
AFFECTED=""
# --affected, parsed: per condition the group number, the operator and the version.
declare -a RANGE_GROUPS=()
declare -a RANGE_OPERATORS=()
declare -a RANGE_VERSIONS=()

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
NOT_FOUND_COUNT=0
BRANCHES_SCANNED=0
NO_BRANCH_COUNT=0
MERGED_COUNT=0
FILTERED_OUT_COUNT=0
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

    --delay=<seconds>   Optional: delay after each network request (default: 1)
                        Requests served from the cache do not wait.
                        Increase if hitting rate limits

    --alternativePaths[=regex]
                        Optional: also check the dependency files in the
                        directories that match this extended regular
                        expression. One row per directory.
                        Without a regex: all directories.
                        Example: --alternativePaths='^(webroot|packages/[^/]+)$'

    --show-visibility   Optional: add a column with the repository
                        visibility (public/private)

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
    printf '%s [%s] %-5s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$$" "$severity" "$message" >> "$LOG_FILE"
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
# Cut the line to the terminal width: a wrapped line is not cleared by "\r".
# Keep room for the dots of the network requests.
print_progress() {
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
    printf '\r\033[K%s ' "$out"
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

    # Retry a network error (no HTTP status, e.g. "connection reset") or a 5xx
    # up to 3 times. Other HTTP errors (404, rate limit, authentication) do
    # not change on retry.
    local output status attempt
    for attempt in 1 2 3 4; do
        # One dot per network request shows progress during slow requests.
        if [[ -t 2 ]]; then
            printf '.' >&2
        fi

        status=0
        local started=$SECONDS
        output=$(gh "$@" 2>&1) || status=$?
        echo "network" >> "$REQUEST_LOG"
        local http
        http=$(http_status "$output")
        log INFO "gh $* -> exit $status${http:+ (HTTP $http)}, $((SECONDS - started)) s, attempt $attempt"
        # Rate limiting delay
        sleep "$DELAY"

        if [[ $status -eq 0 || $attempt -eq 4 ]] || ! is_retryable_error "$output"; then
            break
        fi
        log WARN "Retry in $((attempt * 2)) s: ${output##*$'\n'}"
        # A red "x" replaces the dot of the failed attempt.
        if [[ -t 2 ]]; then
            printf '\b%sx%s' "$RED" "$NC" >&2
        fi
        sleep $((attempt * 2))
    done

    if [[ $status -eq 0 ]]; then
        write_cache_entry "$file" "$output"
        rm -f "$file.404"
        log DEBUG "cache write: $key"
    elif [[ "$(http_status "$output")" == "404" ]]; then
        write_cache_entry "$file.404" "$output"
        rm -f "$file"
        log DEBUG "cache write (404): $key"
    fi
    printf '%s\n' "$output"
    return $status
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
        if gh_cached "api/orgs/$OWNER" api "orgs/$OWNER" &> /dev/null; then
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
        # Wrap in an array to get the same shape as "gh repo list".
        repos_json=$(gh_cached "repo-view/$OWNER/$REPO" repo view "$OWNER/$REPO" --json name,url,isPrivate,defaultBranchRef --jq '[.]') || {
            print_error "Failed to fetch repository: $OWNER/$REPO"
            exit 1
        }
    elif [[ "$OWNER_TYPE" == "org" ]]; then
        repos_json=$(gh_cached "repo-list/$OWNER" repo list "$OWNER" --limit 1000 --json name,url,isPrivate,isArchived,defaultBranchRef) || {
            print_error "Failed to fetch repositories for organization: $OWNER"
            exit 1
        }
    else
        repos_json=$(gh_cached "repo-list/$OWNER" repo list "$OWNER" --limit 1000 --json name,url,isPrivate,isArchived,defaultBranchRef) || {
            print_error "Failed to fetch repositories for user: $OWNER"
            exit 1
        }
    fi

    # Filter here: "gh repo list --no-archived" and "--archived" return incomplete lists.
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

#===============================================================================
# DEPENDENCY FILE FETCHING
#===============================================================================

# Fetch the dependency file in directory $3 ("." is the root).
# For --type=node, try package-lock.json first, then yarn.lock.
fetch_dependency_file() {
    local repo_name="$1"
    local branch="$2"
    local dir="$3"
    local dep_file dep_files
    dep_files=$(dep_file_names)

    local prefix=""
    if [[ "$dir" != "." ]]; then
        prefix="$dir/"
    fi

    # Fetch file content from GitHub API.
    # Use the raw media type: the JSON response has no content for files over 1 MB (e.g. composer.lock).
    local ref
    ref=$(url_encode "$branch")

    local response=""
    for dep_file in $dep_files; do
        local file_path request
        file_path=$(url_encode "$prefix$dep_file")
        request="repos/$OWNER/$repo_name/contents/$file_path?ref=$ref"
        # Cache by branch first: all files of a branch are in one directory.
        local key="api/repos/$OWNER/$repo_name/ref/$branch/$prefix$dep_file"
        response=$(gh_cached "$key" api --header "Accept: application/vnd.github.raw+json" "$request") && break
        # Only a 404 means "no file". Other errors (rate limit, auth, network) must stop the scan.
        if [[ "$(http_status "$response")" != "404" ]]; then
            print_error "Failed to fetch $prefix$dep_file from $OWNER/$repo_name: $response"
            exit 1
        fi
        response=""
    done

    if [[ -z "$response" ]]; then
        echo "NOT_FOUND"
        return
    fi

    # yarn.lock is not JSON.
    if [[ "$dep_file" != *.json ]] || echo "$response" | jq --exit-status 'type == "object"' &> /dev/null; then
        echo "$response"
    else
        echo "PARSE_ERROR"
    fi
}

# Print the directories of a branch that contain a dependency file, one per
# line: the root (".") and those that match --alternativePaths.
# Uses the file list of the branch: one request, also for many directories.
matching_dirs() {
    local repo_name="$1"
    local branch="$2"
    local ref listing
    ref=$(url_encode "$branch")
    local request="repos/$OWNER/$repo_name/git/trees/$ref?recursive=1"
    listing=$(gh_cached "api/repos/$OWNER/$repo_name/ref/$branch/tree?recursive=1" api "$request" \
        --jq '(if .truncated then "TRUNCATED" else empty end), (.tree[] | select(.type == "blob") | .path)') || {
        # Only a 404 means "no files" (e.g. an empty repository). Other errors must stop the scan.
        if [[ "$(http_status "$listing")" == "404" ]]; then
            return 0
        fi
        print_error "Failed to fetch the file list of $OWNER/$repo_name ($branch): $listing"
        exit 1
    }
    if [[ "$listing" == TRUNCATED* ]]; then
        print_warning_line "The file list of $OWNER/$repo_name ($branch) is incomplete (too many files). Some directories are not checked."
    fi

    local dir
    while IFS= read -r dir; do
        if [[ "$dir" == "." || "$dir" =~ $ALTERNATIVE_PATHS ]]; then
            echo "$dir"
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
            if ((file in wanted) && !(dir in seen)) { seen[dir] = 1; print dir }
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

# Print the version of a constraint as "major minor patch". A missing part is 0.
get_version() {
    local version_constraint="$1"

    # Handle special cases
    if [[ "$version_constraint" == "*" || "$version_constraint" == "latest" ]]; then
        echo "0 0 0"
        return
    fi

    # Handle dev versions
    if [[ "$version_constraint" =~ ^dev- ]]; then
        echo "0 0 0"
        return
    fi

    # Remove common prefixes: ^, ~, >=, >, =, v
    # Quote "~": unquoted, bash expands it to $HOME and nothing is removed.
    local cleaned="${version_constraint#^}"
    cleaned="${cleaned#\~}"
    cleaned="${cleaned#>=}"
    cleaned="${cleaned#>}"
    cleaned="${cleaned#<=}"
    cleaned="${cleaned#<}"
    cleaned="${cleaned#=}"
    cleaned="${cleaned#v}"

    # Handle OR constraints (e.g., "^2.0|^3.0") - take the first one
    if [[ "$cleaned" == *"|"* ]]; then
        cleaned="${cleaned%%|*}"
        cleaned="${cleaned#^}"
        cleaned="${cleaned#\~}"
        cleaned="${cleaned#>=}"
        cleaned="${cleaned#>}"
        cleaned="${cleaned#=}"
        cleaned="${cleaned#v}"
    fi

    # Handle space-separated constraints (e.g., ">=2.0 <4.0") - take the first one
    if [[ "$cleaned" == *" "* ]]; then
        cleaned="${cleaned%% *}"
    fi

    # Extract the version (e.g. "3.*" gives 3 0 0)
    if [[ "$cleaned" =~ ^([0-9]+)(\.([0-9]+))?(\.([0-9]+))? ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[3]:-0} ${BASH_REMATCH[5]:-0}"
    else
        echo "0 0 0"
    fi
}

# Parse --affected into RANGE_GROUPS, RANGE_OPERATORS and RANGE_VERSIONS.
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
            RANGE_VERSIONS+=("$(get_version "${BASH_REMATCH[2]}")")
        done
    done
}

# True if version (constraint) $1 is in one of the --affected ranges:
# all conditions of at least one group hold.
is_affected() {
    local -a have wanted
    read -r -a have <<< "$(get_version "$1")"

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
        read -r -a wanted <<< "${RANGE_VERSIONS[$i]}"
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

# Print the branches of a repository that match --branches, one per line.
# With --hide-merged, a branch that is fully merged into the default branch
# ($2) is printed as "merged<TAB>name".
matching_branches() {
    local listing
    if [[ $HIDE_MERGED -eq 1 ]]; then
        listing=$(branches_with_merge_state "$1" "$2")
    else
        local request="repos/$OWNER/$1/branches?per_page=100"
        listing=$(gh_cached "api/$request" api --paginate "$request" --jq '.[].name') || {
            # Only a 404 means "no branches". Other errors must stop the scan.
            if [[ "$(http_status "$listing")" == "404" ]]; then
                return 0
            fi
            print_error "Failed to fetch the branches of $OWNER/$1: $listing"
            exit 1
        }
    fi

    # Branch names contain no spaces, tabs or glob characters.
    local name behind
    while IFS=$'\t' read -r name behind; do
        if [[ -z "$name" || ! "$name" =~ $BRANCHES ]]; then
            continue
        fi
        # Nothing of the branch is missing in the default branch: it is merged.
        if [[ "$behind" == "0" && "$name" != "$2" ]]; then
            printf 'merged\t%s\n' "$name"
        else
            echo "$name"
        fi
    done <<< "$listing"
}

# Print "name<TAB>commits that are not in the default branch ($2)" for all
# branches of repository $1. One GraphQL request per 100 branches, instead
# of one comparison per branch.
branches_with_merge_state() {
    # $owner, $name, $base and $endCursor are GraphQL variables, not shell ones.
    # shellcheck disable=SC2016
    local query='query($owner: String!, $name: String!, $base: String!, $endCursor: String) {
        repository(owner: $owner, name: $name) {
            refs(refPrefix: "refs/heads/", first: 100, after: $endCursor) {
                pageInfo { hasNextPage endCursor }
                nodes { name compare(headRef: $base) { behindBy } }
            }
        }
    }'
    local listing
    listing=$(gh_cached "api/repos/$OWNER/$1/branches?merged-into=$2" api graphql --paginate \
        -f owner="$OWNER" -f name="$1" -f base="$2" -f query="$query" \
        --jq '.data.repository.refs.nodes[] | "\(.name)\t\(.compare.behindBy // "")"') || {
        print_error "Failed to fetch the branches of $OWNER/$1: $listing"
        exit 1
    }
    echo "$listing"
}

#===============================================================================
# MAIN SCANNING LOGIC
#===============================================================================

# The number of the repository that is scanned now, for an interrupted scan.
SCAN_POSITION=0
SCAN_INTERRUPTED=0

# Ctrl-C during the scan shows the results so far. A second Ctrl-C stops at once.
on_scan_interrupt() {
    trap - INT
    SCAN_INTERRUPTED=1
    log WARN "Interrupted (Ctrl-C) in repo $SCAN_POSITION/$TOTAL_REPOS: printing the results so far."
    echo -ne "\r\033[K"
    PROGRESS_SHOWN=0
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
        NO_FILE_COUNT=$((NO_FILE_COUNT + 1))
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

    local i=0
    while IFS= read -r repo_line; do
        i=$((i + 1))
        SCAN_POSITION=$i
        log INFO "Scanning repo $i/$TOTAL_REPOS: $(echo "$repo_line" | jq -r '.name')"

        local repo_name repo_url is_private default_branch
        repo_name=$(echo "$repo_line" | jq -r '.name')
        repo_url=$(echo "$repo_line" | jq -r '.url')
        is_private=$(echo "$repo_line" | jq -r '.isPrivate')
        default_branch=$(echo "$repo_line" | jq -r '.defaultBranchRef.name // "main"')

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
            branches=$(echo "$listing" | awk -F '\t' 'NF == 1')
            log INFO "Branches of $repo_name: $(echo "$branches" | awk 'NF > 0 { n++ } END { print n + 0 }') matching, $merged merged and hidden"
            if [[ -z "$branches" ]]; then
                # Only merged branches match: they are counted as merged.
                if [[ -z "$listing" ]]; then
                    NO_BRANCH_COUNT=$((NO_BRANCH_COUNT + 1))
                fi
                continue
            fi
        else
            branches="${BRANCH:-$default_branch}"
        fi

        local branch_count=0 branch_number=0
        for target_branch in $branches; do
            branch_count=$((branch_count + 1))
        done
        for target_branch in $branches; do
            BRANCHES_SCANNED=$((BRANCHES_SCANNED + 1))
            branch_number=$((branch_number + 1))

            if [[ -n "$BRANCHES" ]]; then
                print_progress "" "Scanning repo: " "$CYAN" "$repo_name" "" " ($i/$TOTAL_REPOS), branch " \
                    "$COLOR_BRANCH" "$target_branch" "" " ($branch_number/$branch_count)"
            else
                print_progress "" "Scanning repo: " "$CYAN" "$repo_name" "" " ($i/$TOTAL_REPOS)"
            fi

            # One row per directory with a dependency file.
            local dirs dir
            if [[ -n "$ALTERNATIVE_PATHS" ]]; then
                dirs=$(matching_dirs "$repo_name" "$target_branch")
                if [[ -z "$dirs" ]]; then
                    record_file "$repo_url" "$target_branch" "" "$visibility" "NOT_FOUND"
                    continue
                fi
            else
                dirs="."
            fi
            while IFS= read -r dir; do
                local content
                content=$(fetch_dependency_file "$repo_name" "$target_branch" "$dir")
                # Without --alternativePaths, there is no PATH column.
                if [[ "$content" == "NOT_FOUND" ]]; then
                    record_file "$repo_url" "$target_branch" "" "$visibility" "$content"
                else
                    record_file "$repo_url" "$target_branch" "$dir" "$visibility" "$content"
                fi
            done <<< "$dirs"
        done

    done < <(echo "$REPOS_DATA" | jq -c '.[]')
    trap - INT

    # Clear progress line
    echo -ne "\r\033[K"
    PROGRESS_SHOWN=0
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

# The PATH column shows where the file was found: only useful with --alternativePaths.
show_path_column() {
    [[ -n "$ALTERNATIVE_PATHS" ]]
}

# Arguments: color, URL, branch, path, package, version, visibility
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
    if show_branch_column; then
        while IFS= read -r line; do
            branch_lines+=("$line")
        done < <(wrap_path "$BRANCH_COLUMN_WIDTH" "$3")
    fi
    if show_path_column; then
        while IFS= read -r line; do
            path_lines+=("$line")
        done < <(wrap_path "$PATH_COLUMN_WIDTH" "$4")
    fi
    while IFS= read -r line; do
        package_lines+=("$line")
    done < <(wrap_path "$PACKAGE_COLUMN_WIDTH" "$5")
    while IFS= read -r line; do
        version_lines+=("$line")
    done < <(wrap_text "$VERSION_COLUMN_WIDTH" "$6")

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
    local version_color="$COLOR_VERSION" visibility_color="$COLOR_VISIBILITY"
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
        printf "%s\n" "$row"
    done
}

print_results() {
    local dep_file_name
    dep_file_name=$(dep_file_names)
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

    # Group the rows: affected, not affected (or found), package not found, no file.
    # A string, not an array: an empty array fails with nounset in bash 3.2 (macOS).
    local ordered_rows="" wanted_status i
    for wanted_status in affected not_affected found not_in_file no_file error; do
        # The summary still counts the hidden rows.
        if [[ ("$wanted_status" == "no_file" && $HIDE_UNKNOWN -eq 1) || ("$wanted_status" == "not_in_file" && $HIDE_ABSENT -eq 1) ]]; then
            continue
        fi
        for i in $sorted_rows; do
            if [[ "${RESULT_STATUS[$i]}" == "$wanted_status" ]]; then
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
            affected) row_group="AFFECTED" ;;
            not_affected) row_group="NOT AFFECTED" ;;
            found) row_group="VERSION FOUND" ;;
            not_in_file) row_group="PACKAGE NOT FOUND" ;;
            no_file) row_group="VERSION FILE NOT FOUND ($(dep_file_names | sed 's/ /, /g'))" ;;
            *) row_group="PARSE ERROR" ;;
        esac
        if [[ "$row_group" != "$group" ]]; then
            group="$row_group"
            echo ""
            echo -e "${BOLD}$group${NC}"
        fi

        # Repos at or above the version do not count as results.
        if [[ "$status" == "affected" ]]; then
            print_row "$RED" "$url" "$branch" "$path" "$package" "$version" "$visibility"
            has_results=1
        elif [[ "$status" == "not_affected" ]]; then
            print_row "$GREEN" "$url" "$branch" "$path" "$package" "$version" "$visibility"
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
    local complete="complete"
    if [[ $SCAN_INTERRUPTED -eq 1 ]]; then
        complete="NOT complete"
    fi
    log INFO "Done ($complete): ${#RESULT_STATUS[@]} rows, $AFFECTED_COUNT affected, $FOUND_COUNT found, $NO_FILE_COUNT without file, $NOT_FOUND_COUNT without package; $cache_hits of $requests requests from the cache"
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
    trap 'rm -f "$REQUEST_LOG"; remove_temp_files' EXIT
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

    log INFO "Options: url=$URL type=$TYPE packages=$PACKAGES affected=$AFFECTED repo=$REPO_FILTER branch=$BRANCH branches=$BRANCHES hide-merged=$HIDE_MERGED hide-unknown=$HIDE_UNKNOWN hide-absent=$HIDE_ABSENT alternativePaths=$ALTERNATIVE_PATHS cache=$USE_CACHE delay=$DELAY"

    # Parse the GitHub URL
    parse_github_url "$URL"

    # Fetch repositories
    fetch_repos

    # Scan repositories
    scan_repos

    # Print results
    print_results
}

# Run main function
main "$@"
