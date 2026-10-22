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
SHOW_VISIBILITY=0
CACHE_DIR="./var/cache"
USE_CACHE=1
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
declare -a RESULT_STATUS=()

# Counters
TOTAL_REPOS=0
BELOW_COUNT=0
FOUND_COUNT=0
NO_FILE_COUNT=0
NOT_FOUND_COUNT=0
BRANCHES_SCANNED=0
NO_BRANCH_COUNT=0
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
    --url <url>         GitHub URL (org or personal repos page, or one repo)
                        Examples:
                          https://github.com/orgs/MyOrg/repositories
                          https://github.com/username?tab=repositories
                          https://github.com/username
                          https://github.com/orgs/MyOrg
                          https://github.com/owner/repo

    --type <type>       Dependency type:
                          composer      installed version from composer.lock
                          composerJson  version constraint from composer.json
                          node          installed version from package-lock.json
                                        or yarn.lock
                          nodeJson      version constraint from package.json

    --package <name>    Package name to search for
                        Examples: livewire/livewire, laravel/framework, react

    --below <version>   Optional: find packages below this major version
                        Default: find all repos that have the package
                        Example: 4 (finds all packages with major version < 4)

    --branch <name>     Optional: specific branch to check
                        Default: repository's default branch

    --branches [regex]  Optional: check all branches that match this extended
                        regular expression, instead of one branch.
                        Without a regex: check all branches.
                        Examples: '^feat/|^upgrade/', 'typo3', 'upgrade$'

    --delay <seconds>   Optional: delay after each network request (default: 1)
                        Requests served from the cache do not wait.
                        Increase if hitting rate limits

    --alternativePaths <path1[,path2,...]>
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
    ./gh-dep-scanner.sh --url "https://github.com/orgs/YOUR_ORG/repositories" \\
                        --type composer \\
                        --package livewire/livewire \\
                        --below 4

    # Find repos with react < v18 for a user
    ./gh-dep-scanner.sh --url "https://github.com/USERNAME" \\
                        --type node \\
                        --package react \\
                        --below 18

    # Specify a branch
    ./gh-dep-scanner.sh --url "https://github.com/orgs/YOUR_ORG/repositories" \\
                        --type composer \\
                        --package laravel/framework \\
                        --below 10 \\
                        --branch develop

${BOLD}REQUIREMENTS:${NC}
    - gh (GitHub CLI) - must be installed and authenticated
    - jq (JSON parser) - for parsing dependency files

EOF
}

print_error() {
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

print_progress() {
    echo -ne "\r\033[K${CYAN}$1${NC}"
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
# The key is the request, e.g. "api/orgs/NAME".
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
    mkdir -p "$(dirname "$1")"
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
    while [[ $# -gt 0 ]]; do
        case $1 in
            --url)
                URL="$2"
                shift 2
                ;;
            --type)
                TYPE="$2"
                shift 2
                ;;
            --package)
                PACKAGE="$2"
                shift 2
                ;;
            --below)
                BELOW_VERSION="$2"
                shift 2
                ;;
            --branch)
                BRANCH="$2"
                shift 2
                ;;
            --branches)
                # The value is optional: without it, match all branches.
                if [[ $# -ge 2 && "$2" != -* ]]; then
                    BRANCHES="$2"
                    shift 2
                else
                    BRANCHES="."
                    shift
                fi
                ;;
            --delay)
                DELAY="$2"
                shift 2
                ;;
            --alternativePaths)
                ALTERNATIVE_PATHS="$2"
                shift 2
                ;;
            --show-visibility)
                SHOW_VISIBILITY=1
                shift
                ;;
            --no-cache)
                USE_CACHE=0
                shift
                ;;
            -v|--verbose)
                set -x
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information."
                exit 1
                ;;
        esac
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

    REPOS_DATA="$repos_json"
    TOTAL_REPOS=$(echo "$repos_json" | jq 'length')

    if [[ "$TOTAL_REPOS" -eq 0 ]]; then
        print_warning "No repositories found for $OWNER"
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
    local path response
    for path in "${paths[@]}"; do
        path="${path%/}"
        for dep_file in $dep_files; do
            # Encode "/" in the branch name: else the cache entry becomes a directory.
            local request="repos/$OWNER/$repo_name/contents/${path:+$path/}$dep_file?ref=${branch//\//%2F}"
            response=$(gh_cached "api/$request" api --header "Accept: application/vnd.github.raw+json" "$request") && break 2
            # Only a 404 means "no file". Other errors (rate limit, auth, network) must stop the scan.
            if [[ "$response" != *"(HTTP 404)"* ]]; then
                print_error "Failed to fetch ${path:+$path/}$dep_file from $OWNER/$repo_name: $response"
                exit 1
            fi
            response=""
        done
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

            print_progress "Scanning repo $i/$TOTAL_REPOS: $repo_name${BRANCHES:+ ($target_branch)}..."

            # Fetch dependency file
            local content
            content=$(fetch_dependency_file "$repo_name" "$target_branch")

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
            RESULT_URLS+=("$repo_url${BRANCHES:+/tree/$target_branch}")
            RESULT_VERSIONS+=("$version_str")
            RESULT_VISIBILITY+=("$visibility")
            RESULT_STATUS+=("$status")
        done

    done < <(echo "$REPOS_DATA" | jq -c '.[]')

    # Clear progress line
    echo -ne "\r\033[K"
}

#===============================================================================
# OUTPUT
#===============================================================================

# Arguments: color, URL, version, visibility
print_row() {
    if [[ $SHOW_VISIBILITY -eq 1 ]]; then
        printf "%s%-55s %-15s %-10s%s\n" "$1" "$2" "$3" "$4" "$NC"
    else
        printf "%s%-55s %s%s\n" "$1" "$2" "$3" "$NC"
    fi
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
    print_row "$BOLD" "REPO URL" "VERSION" "VISIBILITY"
    print_row "" "--------" "-------" "----------"

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
            print_row "$RED" "$url" "$version" "$visibility"
            has_results=1
        elif [[ "$status" == "ok" ]]; then
            print_row "$GREEN" "$url" "$version" "$visibility"
        elif [[ "$status" == "found" ]]; then
            print_row "$GREEN" "$url" "$version" "$visibility"
            has_results=1
        elif [[ "$status" == "no_file" || "$status" == "error" ]]; then
            print_row "$YELLOW" "$url" "$version" "$visibility"
            has_results=1
        elif [[ "$status" == "not_in_file" ]]; then
            print_row "$CYAN" "$url" "$version" "$visibility"
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

    if [[ -n "$BRANCHES" ]]; then
        # Status 2 means an invalid regular expression. We want the status of the condition.
        local regex_status=0
        # shellcheck disable=SC2319
        [[ "" =~ $BRANCHES ]] || regex_status=$?
        if [[ $regex_status -eq 2 ]]; then
            print_error "Invalid regular expression for --branches: $BRANCHES"
            exit 1
        fi
    fi

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
