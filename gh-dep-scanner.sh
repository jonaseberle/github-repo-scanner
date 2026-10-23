#!/bin/bash

#===============================================================================
# GitHub Dependency Scanner
# Scans all repositories in a GitHub org or personal account to find repos
# that use a package in an affected version range.
#
# Requirements: gh (GitHub CLI), jq
# Usage: ./gh-dep-scanner.sh --url=<url> --type=<type> --packages[=regex] [options]
#===============================================================================

set -o errexit -o nounset -o pipefail -o noclobber

# The directory of this script, also through symlinks: lib/ is next to it.
# A loop, not "readlink -f": macOS before 12.3 has no readlink -f.
script_dir() {
    local path="${BASH_SOURCE[0]}" dir
    while [[ -L "$path" ]]; do
        dir=$(cd -P "$(dirname "$path")" && pwd)
        path=$(readlink "$path")
        if [[ "$path" != /* ]]; then
            path="$dir/$path"
        fi
    done
    cd -P "$(dirname "$path")" && pwd
}
LIB_DIR="$(script_dir)/lib"

# "source" reads a whole file at once: a module that changes during a scan
# does not change the running scan.
# shellcheck source=lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=lib/github.sh
source "$LIB_DIR/github.sh"
# shellcheck source=lib/rate-limit.sh
source "$LIB_DIR/rate-limit.sh"
# shellcheck source=lib/options.sh
source "$LIB_DIR/options.sh"
# shellcheck source=lib/repos.sh
source "$LIB_DIR/repos.sh"
# shellcheck source=lib/branches.sh
source "$LIB_DIR/branches.sh"
# shellcheck source=lib/files.sh
source "$LIB_DIR/files.sh"
# shellcheck source=lib/ranges.sh
source "$LIB_DIR/ranges.sh"
# shellcheck source=lib/versions.sh
source "$LIB_DIR/versions.sh"
# shellcheck source=lib/scan.sh
source "$LIB_DIR/scan.sh"
# shellcheck source=lib/table.sh
source "$LIB_DIR/table.sh"
# shellcheck source=lib/output.sh
source "$LIB_DIR/output.sh"

main() {
    init_log
    log INFO "Start: $0 $*"

    # Without arguments: the usage.
    if [[ $# -eq 0 ]]; then
        show_help
        exit 1
    fi
    parse_args "$@"

    REQUEST_LOG=$(mktemp)
    mkdir -p "$LOCK_DIR"
    trap 'rm -f "$REQUEST_LOG"; remove_temp_files; remove_own_locks' EXIT
    remove_temp_files

    local missing=0
    if [[ -z "$URL" ]]; then
        print_error "--url is required, e.g. --url=https://github.com/orgs/ORG/repositories."
        missing=1
    fi
    # --filename-match alone checks only the file names: no --packages, no --type.
    if [[ -z "$PACKAGES" && -z "$FILENAME_MATCH" ]]; then
        print_error "--packages is required: --packages=<regex>, or --packages for all packages (or --filename-match alone)."
        missing=1
    fi
    if [[ -z "$TYPE" && -n "$PACKAGES" ]]; then
        print_error "--type is required: composer, composerJson, node, nodeJson or nodeEngines."
        missing=1
    fi
    if [[ $missing -eq 1 ]]; then
        echo "Use --help for usage information."
        exit 1
    fi

    # Check prerequisites
    check_prerequisites


    if [[ -n "$TYPE" && ! "$TYPE" =~ ^(composer|composerJson|node|nodeJson|nodeEngines)$ ]]; then
        print_error "Type must be 'composer', 'composerJson', 'node', 'nodeJson' or 'nodeEngines'."
        exit 1
    fi

    if [[ "$TYPE" == "nodeEngines" && $EXCLUDE_PATHS_GIVEN -eq 0 ]]; then
        EXCLUDE_PATHS="$NODE_ENGINES_EXCLUDE_PATHS"
    fi


    parse_affected

    if [[ ! "$REPO_LIST_MAX_AGE" =~ ^[0-9]+$ ]]; then
        print_error "--cache-repo-list-max-age needs a number of minutes, e.g. --cache-repo-list-max-age=60."
        exit 1
    fi

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
    check_regex --excludePaths "$EXCLUDE_PATHS"
    check_regex --filename-match "$FILENAME_MATCH"

    if [[ $USE_CACHE -eq 1 ]]; then
        print_info "Using the cache in $CACHE_DIR. Delete entries there or use --no-cache to fetch again."
    else
        print_info "Not reading the cache (--no-cache). New responses are written to $CACHE_DIR."
    fi
    if [[ $OFFLINE -eq 0 ]]; then
        check_rate_limit
        print_info "$(rate_limit_summary)"
    fi

    log INFO "Options: url=$URL type=$TYPE packages=$PACKAGES affected=$AFFECTED repo=$REPO_FILTER branch=$BRANCH branches=$BRANCHES hide-merged=$HIDE_MERGED hide-unknown=$HIDE_UNKNOWN hide-absent=$HIDE_ABSENT hide-path=$HIDE_PATH alternativePaths=$ALTERNATIVE_PATHS excludePaths=$EXCLUDE_PATHS filename-match=$FILENAME_MATCH cache=$USE_CACHE offline=$OFFLINE repo-list-max-age=$REPO_LIST_MAX_AGE delay=$DELAY"

    # Parse the GitHub URL
    parse_github_url "$URL"

    # Fetch repositories
    fetch_repos
    prefetch_dependency_files

    # Scan repositories
    scan_repos

    # Print results
    print_results
    write_outputs
}

# Run main function. "exit" on the same line: bash reads the script while it
# runs it, so after main it must not read on in a file that changed meanwhile.
main "$@"; exit $?
