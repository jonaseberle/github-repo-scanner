# shellcheck shell=bash
# Sourced by gh-dep-scanner.sh: Help, prerequisites, command line options and the GitHub URL.

show_help() {
    cat << EOF
${BOLD}GitHub Dependency Scanner${NC}

Scans all repositories in a GitHub organization or personal account (or a
single repository) to find repos that use a package in an affected version range.

${BOLD}USAGE:${NC}
    ./gh-dep-scanner.sh --url=<url> --type=<type> --packages[=regex] [OPTIONS]

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
                          nodeEngines   Node versions: "engines" in package.json
                                        (node, npm, yarn), .nvmrc, .node-version

    --packages[=regex]  Packages to search for: an extended regular expression
                        for the package names. Without a regex: all packages.
                        Examples: --packages='^livewire/livewire$',
                                  --packages='^typo3/cms-', --packages=react

    --affected=<ranges> Optional: show which packages are in these version
                        ranges, in the form of security advisories (e.g. on
                        packagist.org): "|" separates alternatives, "," joins
                        conditions. Operators: >=, >, <=, <, =, !=.
                        A constraint (e.g. ^3.2) counts if it has a version
                        in the ranges. "?": no version range (e.g. dev-main).
                        Example: --affected='>=13.0.0,<13.3.5|<6.4.5'
                        Default: show all found packages

    --group-by-affected Optional, with --affected: split FOUND into the groups
                        AFFECTED, NOT CHECKED ("?") and NOT AFFECTED

    --repo=<regex>      Optional: check only the repositories whose name (without
                        the owner) matches this extended regular expression
                        Examples: --repo='^typo3-', --repo='\.de$'

    --branch=<name>     Optional: specific branch to check
                        Default: repository's default branch

    --branches[=regex]  Optional: check all branches that match this extended
                        regular expression, instead of one branch.
                        Without a regex: check all branches.
                        After the branch: "*" for the default branch, else
                        "(+3/-2)": 3 commits that are not in the default
                        branch, and 2 commits of it that are not in the branch.
                        Examples: --branches='^feat/|^upgrade/'
                                  --branches=typo3 --branches='upgrade$'

    --hide-path         Optional: hide the path of a branch with only one found
                        dependency file

    --hide-unknown      Optional: hide the rows without a dependency file
                        (VERSION FILE NOT FOUND)

    --hide-absent       Optional: also hide the rows without a matching package
                        (PACKAGE NOT FOUND)

    --hide-merged       Optional, with --branches: hide the branches that are
                        fully merged into the default branch (ahead 0).
                        Squash and rebase merges are not detected.

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

    --filename-match=<regex>
                        Optional: a fallback for a repository without a
                        version in any scanned branch: if a file path matches
                        this extended regular expression, a branch gets one
                        row in the group FILENAME MATCH instead of its rows.
                        Example: --filename-match='typo3conf/' finds TYPO3
                        projects without composer.lock. Without --packages
                        (and --type), only the file names are checked.

    --excludePaths=<regex>
                        Optional, with --alternativePaths: do not check the
                        directories that match this extended regular
                        expression. Example: --excludePaths=node_modules
                        Default with --type=nodeEngines: the directories of
                        package managers (each dependency there has a
                        package.json): node_modules/, bower_components/,
                        jspm_packages/, web_modules/, vendor/, .yarn/ and
                        .pnpm-store/. To check them too: --excludePaths='^$'

    --show-visibility   Optional: add a column with the repository
                        visibility (public/private)

    --output-text[=file], --output-md[=file], --output-html[=file],
    --output-pdf[=file]
                        Optional: also write the results to a file, 160
                        columns wide: plain text, Markdown tables, HTML (white
                        page with the colors) or PDF (that HTML, printed by a
                        headless Chromium or Google Chrome; set CHROMIUM=<path>
                        for another one). A relative path is below ./output.
                        Without a file: <owner>_<packages>.<txt|md|html|pdf>,
                        e.g. ./output/dmind-gmbh_typo3-cms-core.pdf. An
                        existing file stays: the new one is e.g. ...-1.pdf.

    --offline           Optional: use the cached repository list and do not
                        check for pushes. Once cached, a scan needs no network.

    --cache-repo-list-max-age=<minutes>
                        Optional: use the cached repository list without a
                        check for changes (3 requests) if the last check is
                        younger than this (default: 30; 0: always check)

    --no-cache          Optional: do not read the cache in ./var/cache.
                        New responses are still written to it.
                        To fetch one request again, delete its entry there.

    -v, --verbose       Print each command before it runs (set -x)

    -h, --help          Show this help message

${BOLD}EXAMPLES:${NC}
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

parse_args() {
    # For the files: the options, a value with special characters in single
    # quotes as typed in a shell: --packages='^a$'.
    local argument name value
    SCAN_ARGUMENTS=""
    for argument in "$@"; do
        # The files themselves say nothing about the scan.
        if [[ "$argument" == --output-* ]]; then
            continue
        fi
        if [[ ! "$argument" =~ ^[A-Za-z0-9_./:=@%+,-]*$ ]]; then
            name="" value="$argument"
            if [[ "$argument" == --*=* ]]; then
                name="${argument%%=*}=" value="${argument#*=}"
            fi
            argument="$name'${value//\'/\'\\\'\'}'"
        fi
        SCAN_ARGUMENTS+="${SCAN_ARGUMENTS:+ }$argument"
    done
    # Values only in the form --option=value: personal preference.
    while [[ $# -gt 0 ]]; do
        case $1 in
            # Without a file name: the default of write_outputs.
            --output-text | --output-text=)
                OUTPUT_TEXT="$OUTPUT_DEFAULT"
                ;;
            --output-md | --output-md=)
                OUTPUT_MD="$OUTPUT_DEFAULT"
                ;;
            --output-html | --output-html=)
                OUTPUT_HTML="$OUTPUT_DEFAULT"
                ;;
            --output-pdf | --output-pdf=)
                OUTPUT_PDF="$OUTPUT_DEFAULT"
                ;;
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
            --cache-repo-list-max-age=*)
                REPO_LIST_MAX_AGE="${1#*=}"
                ;;
            --alternativePaths=*)
                ALTERNATIVE_PATHS="${1#*=}"
                ;;
            --alternativePaths)
                # Without a value, every directory matches.
                ALTERNATIVE_PATHS="."
                ;;
            --filename-match=*)
                FILENAME_MATCH="${1#*=}"
                ;;
            --excludePaths=*)
                EXCLUDE_PATHS="${1#*=}"
                EXCLUDE_PATHS_GIVEN=1
                ;;
            --show-visibility)
                SHOW_VISIBILITY=1
                ;;
            --output-text=*)
                OUTPUT_TEXT="${1#*=}"
                ;;
            --output-md=*)
                OUTPUT_MD="${1#*=}"
                ;;
            --output-html=*)
                OUTPUT_HTML="${1#*=}"
                ;;
            --output-pdf=*)
                OUTPUT_PDF="${1#*=}"
                ;;
            --hide-path)
                HIDE_PATH=1
                ;;
            --hide-merged)
                HIDE_MERGED=1
                ;;
            --group-by-affected)
                GROUP_BY_AFFECTED=1
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
            -h|--help)
                show_help
                exit 0
                ;;
            --url|--type|--affected|--repo|--branch|--delay|--cache-repo-list-max-age|--excludePaths|--filename-match)
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
