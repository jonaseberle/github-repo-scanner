# shellcheck shell=bash
# Sourced by gh-dep-scanner.sh: colors, defaults and the global state.

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
# The default branch with --branches: bold, in one code (see COLOR_AFFECTED).
COLOR_DEFAULT_BRANCH=$'\033[1;35m'
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
# --excludePaths: directories that --alternativePaths does not check.
EXCLUDE_PATHS=""
# 1 if --excludePaths was given: then nodeEngines does not set its default.
EXCLUDE_PATHS_GIVEN=0
# The default of --excludePaths with nodeEngines: the directories of the
# package managers. Each dependency there has a package.json with "engines".
NODE_ENGINES_EXCLUDE_PATHS='(^|/)(node_modules|bower_components|jspm_packages|web_modules|vendor|\.yarn|\.pnpm-store)/'
REPO_FILTER=""
SHOW_VISIBILITY=0
# --output-text, --output-md, --output-html, --output-pdf: the files for the
# results, and their width in columns.
OUTPUT_TEXT=""
OUTPUT_MD=""
OUTPUT_HTML=""
OUTPUT_PDF=""
REPORT_COLUMNS=160
# A relative --output-* path is below this directory, like ./var.
OUTPUT_DIR="./output"
# An --output-* option without a file: write_outputs names it.
OUTPUT_DEFAULT=":default"
# 1 while print_results renders a copy for the files: no requests, no log line.
REPORT_ONLY=0
# The command line options, for the files.
SCAN_ARGUMENTS=""
# --hide-path: no path for a branch with only one found dependency file.
HIDE_PATH=0
# Set by hide_single_paths: no row has a path left.
PATHS_HIDDEN=0
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
# --cache-repo-list-max-age: use the cached repository list without a check
# for changes (3 requests) if it was checked less than this many minutes ago.
REPO_LIST_MAX_AGE=30
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
# The syntax of the version ranges: "composer" or "npm", see version_dialect.
VERSION_DIALECT="npm"

# Results arrays
declare -a RESULT_URLS=()
declare -a RESULT_VERSIONS=()
declare -a RESULT_VISIBILITY=()
declare -a RESULT_PATHS=()
# 1: a conflict in the directory of the path (a yellow "!"): package-lock.json
# and yarn.lock, or a .nvmrc outside the "engines" of package.json.
declare -a RESULT_CONFLICT=()
declare -a RESULT_BRANCHES=()
# With --branches: "ahead/behind", the commits of the branch that are not in
# the default branch, and the other way round. "default" for the default
# branch, "?" if GitHub gave no comparison.
declare -a RESULT_BRANCH_STATUS=()
# The branch status of the branch that is scanned now, for record_result.
CURRENT_BRANCH_STATUS=""
declare -a RESULT_PACKAGES=()
declare -a RESULT_STATUS=()

# Counters
TOTAL_REPOS=0
AFFECTED_COUNT=0
# Versions that are no range, with --affected (e.g. "dev-main").
UNCHECKED_COUNT=0
FOUND_COUNT=0
NO_FILE_COUNT=0
PARSE_ERROR_COUNT=0
NOT_FOUND_COUNT=0
BRANCHES_SCANNED=0
NO_BRANCH_COUNT=0
MERGED_COUNT=0
# Directories with package-lock.json and yarn.lock.
LOCK_CONFLICT_COUNT=0
# package.json files whose .nvmrc or .node-version is outside their "engines.node".
NODE_VERSION_CONFLICT_COUNT=0
FILTERED_OUT_COUNT=0
REFRESHED_COUNT=0
# Stays empty for a single repository.
ARCHIVED_COUNT=""
