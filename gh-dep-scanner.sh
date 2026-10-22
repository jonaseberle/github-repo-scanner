#!/bin/bash

#===============================================================================
# GitHub Dependency Scanner
# Scans all repositories in a GitHub org or personal account to find repos
# using a specific package below a given version.
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

# Default values
DELAY=1
BRANCH=""
BRANCHES=""
ALTERNATIVE_PATHS=""
REPO_FILTER=""
SHOW_VISIBILITY=0
CACHE_DIR="./var/cache"
USE_CACHE=1
# Terminal width, for the progress line and the result table.
TERM_COLUMNS=$(tput cols 2>/dev/null || echo 80)
# One line per request: "cache <mtime>" or "network".
# A file, because gh_cached runs in subshells.
REQUEST_LOG=""
URL=""
REPO=""
TYPE=""
PACKAGE=""
BELOW_VERSION=""

# Results arrays
declare -a RESULT_URLS=()
declare -a RESULT_VERSIONS=()
declare -a RESULT_VISIBILITY=()
declare -a RESULT_PATHS=()
declare -a RESULT_STATUS=()

# Counters
TOTAL_REPOS=0
BELOW_COUNT=0
FOUND_COUNT=0
NO_FILE_COUNT=0
NOT_FOUND_COUNT=0
BRANCHES_SCANNED=0
NO_BRANCH_COUNT=0
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
single repository) to find repos using a specific package below a given version.

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

    --package=<name>    Package name to search for
                        Examples: livewire/livewire, laravel/framework, react

    --below=<version>   Optional: find packages below this major version
                        Default: find all repos that have the package
                        Example: 4 (finds all packages with major version < 4)

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

    --delay=<seconds>   Optional: delay after each network request (default: 1)
                        Requests served from the cache do not wait.
                        Increase if hitting rate limits

    --alternativePaths=<path1[,path2,...]>
                        Optional: directories to search for the dependency
                        file if it is not in the repository root.
                        They are tried in the given order.
                        Example: app,src/web

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

    # Find repos with livewire < v4 in an organization
    ./gh-dep-scanner.sh --url="https://github.com/orgs/YOUR_ORG/repositories" \\
                        --type=composer \\
                        --package=livewire/livewire \\
                        --below=4

    # Find repos with react < v18 for a user
    ./gh-dep-scanner.sh --url="https://github.com/USERNAME" \\
                        --type=node \\
                        --package=react \\
                        --below=18

    # Specify a branch
    ./gh-dep-scanner.sh --url="https://github.com/orgs/YOUR_ORG/repositories" \\
                        --type=composer \\
                        --package=laravel/framework \\
                        --below=10 \\
                        --branch=develop

${BOLD}REQUIREMENTS:${NC}
    - gh (GitHub CLI) - must be installed and authenticated
    - jq (JSON parser) - for parsing dependency files

EOF
}

print_error() {
    # The progress line has no line break at its end.
    if [[ $PROGRESS_SHOWN -eq 1 ]]; then
        echo "" >&2
    fi
    echo -e "${RED}Error: $1${NC}" >&2
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

# Cut the line to the terminal width: a wrapped line is not cleared by "\r".
# Keep room for the dots of the network requests.
print_progress() {
    PROGRESS_SHOWN=1
    local text="$1" max=$((TERM_COLUMNS - 12))
    if [[ ${#text} -gt $max ]]; then
        text="${text:0:$((max - 3))}..."
    fi
    echo -ne "\r\033[K${CYAN}$text ${NC}"
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
    local file="$CACHE_DIR/$1"
    shift

    if [[ $USE_CACHE -eq 1 && -f "$file" ]]; then
        echo "cache $(file_mtime "$file")" >> "$REQUEST_LOG"
        cat "$file"
        return 0
    fi
    if [[ $USE_CACHE -eq 1 && -f "$file.404" ]]; then
        echo "cache $(file_mtime "$file.404")" >> "$REQUEST_LOG"
        cat "$file.404"
        return 1
    fi

    # One dot per network request shows progress during slow requests.
    if [[ -t 2 ]]; then
        printf '.' >&2
    fi

    local output status=0
    output=$(gh "$@" 2>&1) || status=$?
    echo "network" >> "$REQUEST_LOG"
    # Rate limiting delay
    sleep "$DELAY"

    if [[ $status -eq 0 ]]; then
        write_cache_entry "$file" "$output"
        rm -f "$file.404"
    elif [[ "$output" == *"(HTTP 404)"* ]]; then
        write_cache_entry "$file.404" "$output"
        rm -f "$file"
    fi
    printf '%s\n' "$output"
    return $status
}

# Encode the characters that have a meaning in a URL ("/" stays).
# Branch names can contain "#": unencoded, GitHub ignores the rest of the request.
url_encode() {
    local s="$1"
    s="${s//\%/%25}"
    s="${s//\#/%23}"
    s="${s//\&/%26}"
    s="${s//+/%2B}"
    s="${s//\?/%3F}"
    s="${s// /%20}"
    echo "$s"
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
            --package=*)
                PACKAGE="${1#*=}"
                ;;
            --below=*)
                BELOW_VERSION="${1#*=}"
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
            --show-visibility)
                SHOW_VISIBILITY=1
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
            --url|--type|--package|--below|--repo|--branch|--delay|--alternativePaths)
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

    # Package
    if [[ -z "$PACKAGE" ]]; then
        echo -e "${CYAN}Enter package name:${NC}"
        if [[ "$TYPE" != node* ]]; then
            echo "  Example: livewire/livewire, laravel/framework"
        else
            echo "  Example: react, vue, lodash"
        fi
        read -r -p "> " PACKAGE
        echo ""
    fi

    # Version
    if [[ -z "$BELOW_VERSION" ]]; then
        echo -e "${CYAN}Enter minimum major version to check against (press Enter to find all repos with the package):${NC}"
        echo "  Example: 4 (will find all repos with major version < 4)"
        read -r -p "> " BELOW_VERSION
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

    print_success "Found $TOTAL_REPOS repositories."
}

#===============================================================================
# DEPENDENCY FILE FETCHING
#===============================================================================

fetch_dependency_file() {
    local repo_name="$1"
    local branch="$2"
    local dep_file dep_files
    dep_files=$(dep_file_names)

    # The leading comma adds the repository root as the first path.
    local -a paths
    IFS=',' read -r -a paths <<< ",$ALTERNATIVE_PATHS"

    # Fetch file content from GitHub API.
    # Use the raw media type: the JSON response has no content for files over 1 MB (e.g. composer.lock).
    local ref
    ref=$(url_encode "$branch")

    local path response
    for path in "${paths[@]}"; do
        path="${path%/}"
        for dep_file in $dep_files; do
            local file_path request
            file_path=$(url_encode "${path:+$path/}$dep_file")
            request="repos/$OWNER/$repo_name/contents/$file_path?ref=$ref"
            # Cache by branch first: all files of a branch are in one directory.
            local key="api/repos/$OWNER/$repo_name/ref/$branch/${path:+$path/}$dep_file"
            response=$(gh_cached "$key" api --header "Accept: application/vnd.github.raw+json" "$request") && break 2
            # Only a 404 means "no file". Other errors (rate limit, auth, network) must stop the scan.
            if [[ "$response" != *"(HTTP 404)"* ]]; then
                print_error "Failed to fetch ${path:+$path/}$dep_file from $OWNER/$repo_name: $response"
                exit 1
            fi
            response=""
        done
    done

    # The first output line is the directory of the file: "." for the root, empty if not found.
    if [[ -z "$response" ]]; then
        echo ""
        echo "NOT_FOUND"
        return
    fi
    echo "${path:-.}"

    # yarn.lock is not JSON.
    if [[ "$dep_file" != *.json ]] || echo "$response" | jq --exit-status 'type == "object"' &> /dev/null; then
        echo "$response"
    else
        echo "PARSE_ERROR"
    fi
}

#===============================================================================
# VERSION EXTRACTION
#===============================================================================

extract_version() {
    local json_content="$1"
    local package="$2"
    local dep_type="$3"

    local version=""

    if [[ "$dep_type" == "composer" ]]; then
        # Check in packages first, then packages-dev
        version=$(echo "$json_content" | jq -r --arg pkg "$package" 'first((.packages // [])[], (.["packages-dev"] // [])[] | select(.name == $pkg) | .version) // empty' 2>/dev/null)
    elif [[ "$dep_type" == "composerJson" ]]; then
        # Check in require first, then require-dev
        version=$(echo "$json_content" | jq -r --arg pkg "$package" '.require[$pkg] // .["require-dev"][$pkg] // empty' 2>/dev/null)
    elif [[ "$dep_type" == "node" && "$json_content" == "{"* ]]; then
        # package-lock.json: "packages" since lockfileVersion 2, "dependencies" in version 1.
        # Use the top-level node_modules entry: nested ones belong to other packages.
        version=$(echo "$json_content" | jq -r --arg pkg "$package" '.packages["node_modules/" + $pkg].version // .dependencies[$pkg].version // empty' 2>/dev/null)
    elif [[ "$dep_type" == "node" ]]; then
        # yarn.lock (classic and berry): take the version of the first entry for the package.
        version=$(echo "$json_content" | awk -v pkg="$package" '
            /^[^ #]/ {
                in_entry = 0
                line = $0
                sub(/:$/, "", line)
                n = split(line, specs, /, */)
                for (i = 1; i <= n; i++) {
                    spec = specs[i]
                    gsub(/"/, "", spec)
                    if (index(spec, pkg "@") == 1) in_entry = 1
                }
                next
            }
            in_entry && /^  version:? / {
                version = $2
                gsub(/"/, "", version)
                print version
                exit
            }
        ')
    else
        # Check in dependencies first, then devDependencies
        version=$(echo "$json_content" | jq -r --arg pkg "$package" '.dependencies[$pkg] // .devDependencies[$pkg] // empty' 2>/dev/null)
    fi

    if [[ -z "$version" || "$version" == "null" ]]; then
        echo "NOT_IN_FILE"
    else
        echo "$version"
    fi
}

#===============================================================================
# VERSION COMPARISON
#===============================================================================

get_major_version() {
    local version_constraint="$1"

    # Handle special cases
    if [[ "$version_constraint" == "*" || "$version_constraint" == "latest" ]]; then
        echo "0"
        return
    fi

    # Handle dev versions
    if [[ "$version_constraint" =~ ^dev- ]]; then
        echo "0"
        return
    fi

    # Remove common prefixes: ^, ~, >=, >, =, v
    local cleaned="${version_constraint#^}"
    cleaned="${cleaned#~}"
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
        cleaned="${cleaned#~}"
        cleaned="${cleaned#>=}"
        cleaned="${cleaned#>}"
        cleaned="${cleaned#=}"
        cleaned="${cleaned#v}"
    fi

    # Handle space-separated constraints (e.g., ">=2.0 <4.0") - take the first one
    if [[ "$cleaned" == *" "* ]]; then
        cleaned="${cleaned%% *}"
    fi

    # Extract major version (first number before a dot or end)
    if [[ "$cleaned" =~ ^([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "0"
    fi
}

is_below_version() {
    local version_constraint="$1"
    local target_major="$2"

    local major
    major=$(get_major_version "$version_constraint")

    if [[ "$major" -lt "$target_major" ]]; then
        return 0  # true, is below
    else
        return 1  # false, is not below
    fi
}

# Print the branches of a repository that match --branches, one per line.
matching_branches() {
    local request="repos/$OWNER/$1/branches?per_page=100"
    local names name
    names=$(gh_cached "api/$request" api --paginate "$request" --jq '.[].name') || {
        # Only a 404 means "no branches". Other errors must stop the scan.
        if [[ "$names" == *"(HTTP 404)"* ]]; then
            return 0
        fi
        print_error "Failed to fetch the branches of $OWNER/$1: $names"
        exit 1
    }
    # Branch names contain no spaces or glob characters.
    for name in $names; do
        if [[ "$name" =~ $BRANCHES ]]; then
            echo "$name"
        fi
    done
}

#===============================================================================
# MAIN SCANNING LOGIC
#===============================================================================

scan_repos() {
    echo ""
    echo -e "${BOLD}Scanning $OWNER repositories for $PACKAGE${BELOW_VERSION:+ < $BELOW_VERSION}...${NC}"
    if [[ -n "$BRANCHES" ]]; then
        echo -e "Branches: ${CYAN}matching $BRANCHES${NC}"
    elif [[ -n "$BRANCH" ]]; then
        echo -e "Branch: ${CYAN}$BRANCH${NC}"
    else
        echo -e "Branch: ${CYAN}default${NC}"
    fi
    echo ""

    local i=0
    while IFS= read -r repo_line; do
        i=$((i + 1))

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
            print_progress "Scanning repo $i/$TOTAL_REPOS: $repo_name (branches)"
            branches=$(matching_branches "$repo_name")
            if [[ -z "$branches" ]]; then
                NO_BRANCH_COUNT=$((NO_BRANCH_COUNT + 1))
                continue
            fi
        else
            branches="${BRANCH:-$default_branch}"
        fi

        for target_branch in $branches; do
            BRANCHES_SCANNED=$((BRANCHES_SCANNED + 1))

            print_progress "Scanning repo $i/$TOTAL_REPOS: $repo_name${BRANCHES:+ ($target_branch)}"

            # Fetch dependency file
            local fetched content found_path
            fetched=$(fetch_dependency_file "$repo_name" "$target_branch")
            found_path="${fetched%%$'\n'*}"
            content="${fetched#*$'\n'}"

            local version_str status

            if [[ "$content" == "NOT_FOUND" ]]; then
                version_str="N/A"
                status="no_file"
                NO_FILE_COUNT=$((NO_FILE_COUNT + 1))
            elif [[ "$content" == "PARSE_ERROR" ]]; then
                version_str="Parse error"
                status="error"
                NO_FILE_COUNT=$((NO_FILE_COUNT + 1))
            else
                # Extract version for the package
                version_str=$(extract_version "$content" "$PACKAGE" "$TYPE")

                if [[ "$version_str" == "NOT_IN_FILE" ]]; then
                    version_str="Not found"
                    status="not_in_file"
                    NOT_FOUND_COUNT=$((NOT_FOUND_COUNT + 1))
                elif [[ -z "$BELOW_VERSION" ]]; then
                    status="found"
                    FOUND_COUNT=$((FOUND_COUNT + 1))
                else
                    # Check if below target version
                    if is_below_version "$version_str" "$BELOW_VERSION"; then
                        status="below"
                        BELOW_COUNT=$((BELOW_COUNT + 1))
                    else
                        status="ok"
                    fi
                fi
            fi

            # Store results
            # With --branches, a row is a branch: link to it.
            local row_url="$repo_url"
            if [[ -n "$BRANCHES" ]]; then
                row_url="$repo_url/tree/$(url_encode "$target_branch")"
            fi
            RESULT_URLS+=("$row_url")
            RESULT_VERSIONS+=("$version_str")
            RESULT_VISIBILITY+=("$visibility")
            RESULT_PATHS+=("$found_path")
            RESULT_STATUS+=("$status")
        done

    done < <(echo "$REPOS_DATA" | jq -c '.[]')

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

# Fit the columns to the longest values and to the terminal width.
set_column_widths() {
    local i url_width=8 version_width=7 path_width=4
    for i in "${!RESULT_URLS[@]}"; do
        if [[ ${#RESULT_URLS[$i]} -gt $url_width ]]; then
            url_width=${#RESULT_URLS[$i]}
        fi
        if [[ ${#RESULT_VERSIONS[$i]} -gt $version_width ]]; then
            version_width=${#RESULT_VERSIONS[$i]}
        fi
        if [[ ${#RESULT_PATHS[$i]} -gt $path_width ]]; then
            path_width=${#RESULT_PATHS[$i]}
        fi
    done
    if [[ $path_width -gt $((TERM_COLUMNS / 3)) ]]; then
        path_width=$((TERM_COLUMNS / 3))
    fi

    # Keep at least 20 columns for the version and the visibility.
    local visibility_width=0
    if [[ $SHOW_VISIBILITY -eq 1 ]]; then
        visibility_width=11
    fi
    if show_path_column; then
        visibility_width=$((visibility_width + path_width + 1))
    fi
    local max_url_width=$((TERM_COLUMNS - 1 - 20 - visibility_width))
    if [[ $url_width -gt $max_url_width ]]; then
        url_width=$max_url_width
    fi
    if [[ $url_width -lt 20 ]]; then
        url_width=20
    fi
    local max_version_width=$((TERM_COLUMNS - url_width - 1 - visibility_width))
    if [[ $version_width -gt $max_version_width ]]; then
        version_width=$max_version_width
    fi
    if [[ $version_width -lt 10 ]]; then
        version_width=10
    fi

    URL_COLUMN_WIDTH=$url_width
    VERSION_COLUMN_WIDTH=$version_width
    PATH_COLUMN_WIDTH=$path_width
}

# The PATH column shows where the file was found: only useful with --alternativePaths.
show_path_column() {
    [[ -n "$ALTERNATIVE_PATHS" ]]
}

# Arguments: color, URL, path, version, visibility
# A path or version that is too wide wraps and stays in its column.
# A URL never wraps: a line break makes it unclickable. A URL that is too
# wide gets its own line, and the other cells start on the next line.
print_row() {
    local -a url_lines=("$2") path_lines=() version_lines=()
    local line
    if [[ ${#2} -gt $URL_COLUMN_WIDTH ]]; then
        printf "%s%s%s\n" "$1" "$2" "$NC"
        url_lines=("")
    fi
    while IFS= read -r line; do
        path_lines+=("$line")
    done < <(wrap_path "$PATH_COLUMN_WIDTH" "$3")
    while IFS= read -r line; do
        version_lines+=("$line")
    done < <(wrap_text "$VERSION_COLUMN_WIDTH" "$4")

    local count=${#url_lines[@]}
    if show_path_column && [[ ${#path_lines[@]} -gt $count ]]; then
        count=${#path_lines[@]}
    fi
    if [[ ${#version_lines[@]} -gt $count ]]; then
        count=${#version_lines[@]}
    fi

    local i row cell
    for ((i = 0; i < count; i++)); do
        printf -v row "%-*s" "$URL_COLUMN_WIDTH" "${url_lines[$i]:-}"
        if show_path_column; then
            printf -v cell " %-*s" "$PATH_COLUMN_WIDTH" "${path_lines[$i]:-}"
            row+="$cell"
        fi
        if [[ $SHOW_VISIBILITY -eq 1 ]]; then
            printf -v cell " %-*s" "$VERSION_COLUMN_WIDTH" "${version_lines[$i]:-}"
            row+="$cell"
            if [[ $i -eq 0 ]]; then
                row+=" $5"
            fi
        else
            row+=" ${version_lines[$i]:-}"
        fi
        printf "%s%s%s\n" "$1" "$row" "$NC"
    done
}

print_results() {
    local dep_file_name
    dep_file_name=$(dep_file_names)
    dep_file_name="${dep_file_name// / or }"

    echo ""
    echo -e "${BOLD}Results: $PACKAGE in repositories${BELOW_VERSION:+ (target version: $BELOW_VERSION)}${NC}"
    echo "================================================================================"
    echo ""

    # Print header
    set_column_widths
    print_row "$BOLD" "REPO URL" "PATH" "VERSION" "VISIBILITY"
    print_row "" "--------" "----" "-------" "----------"

    local has_results=0

    # Sort the rows by URL. URLs contain no spaces.
    local sorted_rows
    sorted_rows=$(for i in "${!RESULT_URLS[@]}"; do echo "${RESULT_URLS[$i]} $i"; done | sort --ignore-case | awk '{ print $2 }')

    # Group the rows: version below, version above (or found), package not found, no file.
    # A string, not an array: an empty array fails with nounset in bash 3.2 (macOS).
    local ordered_rows="" wanted_status i
    for wanted_status in below ok found not_in_file no_file error; do
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

        case "$status" in
            below) row_group="VERSION BELOW" ;;
            ok) row_group="VERSION ABOVE" ;;
            found) row_group="VERSION FOUND" ;;
            not_in_file) row_group="NOT FOUND" ;;
            *) row_group="N/A" ;;
        esac
        if [[ "$row_group" != "$group" ]]; then
            group="$row_group"
            echo ""
            echo -e "${BOLD}$group${NC}"
        fi

        # Repos at or above the version do not count as results.
        if [[ "$status" == "below" ]]; then
            print_row "$RED" "$url" "$path" "$version" "$visibility"
            has_results=1
        elif [[ "$status" == "ok" ]]; then
            print_row "$GREEN" "$url" "$path" "$version" "$visibility"
        elif [[ "$status" == "found" ]]; then
            print_row "$GREEN" "$url" "$path" "$version" "$visibility"
            has_results=1
        elif [[ "$status" == "no_file" || "$status" == "error" ]]; then
            print_row "$YELLOW" "$url" "$path" "$version" "$visibility"
            has_results=1
        elif [[ "$status" == "not_in_file" ]]; then
            print_row "$CYAN" "$url" "$path" "$version" "$visibility"
            has_results=1
        fi
    done

    if [[ ${#RESULT_URLS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No branch matches --branches '$BRANCHES'.${NC}"
    elif [[ $has_results -eq 0 ]]; then
        echo -e "${GREEN}All repositories have $PACKAGE at version $BELOW_VERSION or higher!${NC}"
    fi

    # Summary
    echo ""
    echo "================================================================================"
    echo -e "${BOLD}Summary:${NC}"
    echo "  - Total repos scanned: $TOTAL_REPOS"
    if [[ -n "$REPO_FILTER" ]]; then
        echo "  - Repos not matching --repo: $FILTERED_OUT_COUNT"
    fi
    if [[ -n "$BRANCHES" ]]; then
        echo "  - Branches scanned: $BRANCHES_SCANNED"
        echo "  - Repos without a matching branch: $NO_BRANCH_COUNT"
    fi
    if [[ -n "$ARCHIVED_COUNT" ]]; then
        echo "  - Archived repos: $ARCHIVED_COUNT"
    fi
    # With --branches, the counts are per branch.
    local rows="Repos"
    if [[ -n "$BRANCHES" ]]; then
        rows="Branches"
    fi
    if [[ -n "$BELOW_VERSION" ]]; then
        echo -e "  - $rows with $PACKAGE below v$BELOW_VERSION: ${RED}$BELOW_COUNT${NC}"
    else
        echo -e "  - $rows with $PACKAGE: ${GREEN}$FOUND_COUNT${NC}"
    fi
    echo -e "  - $rows without $dep_file_name: ${YELLOW}$NO_FILE_COUNT${NC}"
    echo -e "  - $rows without $PACKAGE in dependencies: ${CYAN}$NOT_FOUND_COUNT${NC}"

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
    # Parse command line arguments
    parse_args "$@"

    REQUEST_LOG=$(mktemp)
    trap 'rm -f "$REQUEST_LOG"; remove_temp_files' EXIT
    remove_temp_files

    # Check prerequisites
    check_prerequisites

    # If required arguments are missing, enter interactive mode
    if [[ -z "$URL" || -z "$TYPE" || -z "$PACKAGE" ]]; then
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

    if [[ -z "$PACKAGE" ]]; then
        print_error "Package name is required."
        exit 1
    fi

    if [[ -n "$BELOW_VERSION" && ! "$BELOW_VERSION" =~ ^[0-9]+$ ]]; then
        print_error "Version must be a number (major version)."
        exit 1
    fi

    if [[ -n "$BRANCH" && -n "$BRANCHES" ]]; then
        print_error "Use either --branch or --branches."
        exit 1
    fi

    check_regex --branches "$BRANCHES"
    check_regex --repo "$REPO_FILTER"

    if [[ $USE_CACHE -eq 1 ]]; then
        print_info "Using the cache in $CACHE_DIR. Delete entries there or use --no-cache to fetch again."
    else
        print_info "Not reading the cache (--no-cache). New responses are written to $CACHE_DIR."
    fi

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
