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
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Default values
DELAY=1
BRANCH=""
URL=""
REPO=""
TYPE=""
PACKAGE=""
BELOW_VERSION=""

# Results arrays
declare -a RESULT_URLS=()
declare -a RESULT_NAMES=()
declare -a RESULT_VERSIONS=()
declare -a RESULT_VISIBILITY=()
declare -a RESULT_STATUS=()

# Counters
TOTAL_REPOS=0
BELOW_COUNT=0
NO_FILE_COUNT=0
NOT_FOUND_COUNT=0

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

    --type <type>       Dependency type: "composer" or "node"

    --package <name>    Package name to search for
                        Examples: livewire/livewire, laravel/framework, react

    --below <version>   Find packages below this major version
                        Example: 4 (finds all packages with major version < 4)

    --branch <name>     Optional: specific branch to check
                        Default: repository's default branch

    --delay <seconds>   Optional: delay between API requests (default: 1)
                        Increase if hitting rate limits

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
    echo -ne "\r${CYAN}$1${NC}"
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
        # Check if gh is authenticated
        if ! gh auth status &> /dev/null; then
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
            --delay)
                DELAY="$2"
                shift 2
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
        echo "  1) composer (PHP - composer.json)"
        echo "  2) node (JavaScript - package.json)"
        read -r -p "> " type_choice
        case $type_choice in
            1|composer) TYPE="composer" ;;
            2|node) TYPE="node" ;;
            *)
                print_error "Invalid choice. Please enter 1, 2, 'composer', or 'node'."
                exit 1
                ;;
        esac
        echo ""
    fi

    # Package
    if [[ -z "$PACKAGE" ]]; then
        echo -e "${CYAN}Enter package name:${NC}"
        if [[ "$TYPE" == "composer" ]]; then
            echo "  Example: livewire/livewire, laravel/framework"
        else
            echo "  Example: react, vue, lodash"
        fi
        read -r -p "> " PACKAGE
        echo ""
    fi

    # Version
    if [[ -z "$BELOW_VERSION" ]]; then
        echo -e "${CYAN}Enter minimum major version to check against:${NC}"
        echo "  Example: 4 (will find all repos with major version < 4)"
        read -r -p "> " BELOW_VERSION
        echo ""
    fi

    # Branch (optional)
    if [[ -z "$BRANCH" ]]; then
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
        if gh api "orgs/$OWNER" &> /dev/null; then
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
        repos_json=$(gh repo view "$OWNER/$REPO" --json name,url,isPrivate,defaultBranchRef --jq '[.]' 2>&1) || {
            print_error "Failed to fetch repository: $OWNER/$REPO"
            exit 1
        }
    elif [[ "$OWNER_TYPE" == "org" ]]; then
        repos_json=$(gh repo list "$OWNER" --limit 1000 --json name,url,isPrivate,defaultBranchRef 2>&1) || {
            print_error "Failed to fetch repositories for organization: $OWNER"
            exit 1
        }
    else
        repos_json=$(gh repo list "$OWNER" --limit 1000 --json name,url,isPrivate,defaultBranchRef 2>&1) || {
            print_error "Failed to fetch repositories for user: $OWNER"
            exit 1
        }
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
    local dep_file

    if [[ "$TYPE" == "composer" ]]; then
        dep_file="composer.json"
    else
        dep_file="package.json"
    fi

    # Fetch file content from GitHub API
    local response
    response=$(gh api "repos/$OWNER/$repo_name/contents/$dep_file?ref=$branch" 2>&1) || {
        # Only a 404 means "no file". Other errors (rate limit, auth, network) must stop the scan.
        if [[ "$response" == *"(HTTP 404)"* ]]; then
            echo "NOT_FOUND"
            return
        fi
        print_error "Failed to fetch $dep_file from $OWNER/$repo_name: $response"
        exit 1
    }

    # Check if it's a valid response with content
    if echo "$response" | jq -e '.content' &> /dev/null; then
        # Decode base64 content
        echo "$response" | jq -r '.content' | base64 -d 2>/dev/null || echo "PARSE_ERROR"
    else
        echo "NOT_FOUND"
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
        # Check in require first, then require-dev
        version=$(echo "$json_content" | jq -r --arg pkg "$package" '.require[$pkg] // .["require-dev"][$pkg] // empty' 2>/dev/null)
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

#===============================================================================
# MAIN SCANNING LOGIC
#===============================================================================

scan_repos() {
    local dep_file_name
    if [[ "$TYPE" == "composer" ]]; then
        dep_file_name="composer.json"
    else
        dep_file_name="package.json"
    fi

    echo ""
    echo -e "${BOLD}Scanning $OWNER repositories for $PACKAGE < $BELOW_VERSION...${NC}"
    if [[ -n "$BRANCH" ]]; then
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

        # Determine which branch to use
        local target_branch="${BRANCH:-$default_branch}"

        # Visibility
        local visibility
        if [[ "$is_private" == "true" ]]; then
            visibility="private"
        else
            visibility="public"
        fi

        print_progress "Scanning repo $i/$TOTAL_REPOS: $repo_name..."

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
        RESULT_URLS+=("$repo_url")
        RESULT_NAMES+=("$repo_name")
        RESULT_VERSIONS+=("$version_str")
        RESULT_VISIBILITY+=("$visibility")
        RESULT_STATUS+=("$status")

        # Rate limiting delay
        sleep "$DELAY"

    done < <(echo "$REPOS_DATA" | jq -c '.[]')

    # Clear progress line
    echo -ne "\r\033[K"
}

#===============================================================================
# OUTPUT
#===============================================================================

print_results() {
    local dep_file_name
    if [[ "$TYPE" == "composer" ]]; then
        dep_file_name="composer.json"
    else
        dep_file_name="package.json"
    fi

    echo ""
    echo -e "${BOLD}Results: Repositories with $PACKAGE below version $BELOW_VERSION${NC}"
    echo "================================================================================"
    echo ""

    # Print header
    printf "${BOLD}%-55s %-20s %-15s %-10s${NC}\n" "REPO URL" "NAME" "VERSION" "VISIBILITY"
    printf "%-55s %-20s %-15s %-10s\n" "--------" "----" "-------" "----------"

    local has_results=0

    for i in "${!RESULT_URLS[@]}"; do
        local status="${RESULT_STATUS[$i]}"
        local url="${RESULT_URLS[$i]}"
        local name="${RESULT_NAMES[$i]}"
        local version="${RESULT_VERSIONS[$i]}"
        local visibility="${RESULT_VISIBILITY[$i]}"

        # Only show repos that are below version, have no file, or package not found
        if [[ "$status" == "below" ]]; then
            printf "${RED}%-55s %-20s %-15s %-10s${NC}\n" "$url" "$name" "$version" "$visibility"
            has_results=1
        elif [[ "$status" == "no_file" || "$status" == "error" ]]; then
            printf "${YELLOW}%-55s %-20s %-15s %-10s${NC}\n" "$url" "$name" "$version" "$visibility"
            has_results=1
        elif [[ "$status" == "not_in_file" ]]; then
            printf "${CYAN}%-55s %-20s %-15s %-10s${NC}\n" "$url" "$name" "$version" "$visibility"
            has_results=1
        fi
    done

    if [[ $has_results -eq 0 ]]; then
        echo -e "${GREEN}All repositories have $PACKAGE at version $BELOW_VERSION or higher!${NC}"
    fi

    # Summary
    echo ""
    echo "================================================================================"
    echo -e "${BOLD}Summary:${NC}"
    echo "  - Total repos scanned: $TOTAL_REPOS"
    echo -e "  - Repos with $PACKAGE below v$BELOW_VERSION: ${RED}$BELOW_COUNT${NC}"
    echo -e "  - Repos without $dep_file_name: ${YELLOW}$NO_FILE_COUNT${NC}"
    echo -e "  - Repos without $PACKAGE in dependencies: ${CYAN}$NOT_FOUND_COUNT${NC}"
    echo ""
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    # Parse command line arguments
    parse_args "$@"

    # Check prerequisites
    check_prerequisites

    # If required arguments are missing, enter interactive mode
    if [[ -z "$URL" || -z "$TYPE" || -z "$PACKAGE" || -z "$BELOW_VERSION" ]]; then
        interactive_mode
    fi

    # Validate inputs
    if [[ -z "$URL" ]]; then
        print_error "GitHub URL is required."
        exit 1
    fi

    if [[ "$TYPE" != "composer" && "$TYPE" != "node" ]]; then
        print_error "Type must be 'composer' or 'node'."
        exit 1
    fi

    if [[ -z "$PACKAGE" ]]; then
        print_error "Package name is required."
        exit 1
    fi

    if ! [[ "$BELOW_VERSION" =~ ^[0-9]+$ ]]; then
        print_error "Version must be a number (major version)."
        exit 1
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
