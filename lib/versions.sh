# shellcheck shell=bash
# Sourced by gh-dep-scanner.sh: Packages of a dependency file, versions and --affected.

# "all packages" or "packages matching <regex>", for headers and the summary.
packages_label() {
    if [[ -z "$PACKAGES" ]]; then
        echo "file names matching ${COLOR_PATH}$FILENAME_MATCH${NC}"
    elif [[ "$PACKAGES" == "." ]]; then
        echo "all packages"
    else
        echo "packages matching ${COLOR_PACKAGE}$PACKAGES${NC}"
    fi
}

# Print all packages of a dependency file: "name<TAB>version", one per line.
# A name that is listed twice (e.g. in require and require-dev) is printed once.
# Fails if jq cannot parse the file, or if it is not a JSON object.
# Arguments: content, type, path of the file (for nodeEngines).
list_packages() {
    local content="$1"
    local dep_type="$2"
    # A dependency file in JSON is an object.
    local object='if type != "object" then error("not an object") else . end | '

    {
        if [[ "$dep_type" == "nodeEngines" && ( "${3:-}" == *.nvmrc || "${3:-}" == *.node-version ) ]]; then
            # The Node version of nvm and similar tools: the first line that is
            # not empty or a comment, e.g. "v16.18.0", "20" or "lts/iron".
            echo "$content" | awk '{ sub(/#.*/, ""); gsub(/^[ \t\r]+|[ \t\r]+$/, "") } $0 != "" { print "node\t" $0; exit }'
        elif [[ "$dep_type" == "nodeEngines" ]]; then
            # package.json: the versions of node, npm, yarn etc. in "engines".
            echo "$content" | jq -r "$object"'(.engines // {}) | if type == "object" then to_entries[] else empty end | "\(.key)\t\(.value | if type == "string" then . else tojson end)"' 2>/dev/null
        elif [[ "$dep_type" == "composer" ]]; then
            # packages first, then packages-dev
            echo "$content" | jq -r "$object"'((.packages // []), (.["packages-dev"] // []))[] | "\(.name)\t\(.version)"' 2>/dev/null
        elif [[ "$dep_type" == "composerJson" ]]; then
            # require first, then require-dev
            echo "$content" | jq -r "$object"'((.require // {}), (.["require-dev"] // {})) | to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null
        elif [[ "$dep_type" == "node" && "$content" =~ ^[[:space:]]*[{[] ]]; then
            # package-lock.json: "packages" since lockfileVersion 2, "dependencies" in version 1.
            # Use the top-level node_modules entries: nested ones belong to other packages.
            echo "$content" | jq -r "$object"'
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
            echo "$content" | jq -r "$object"'((.dependencies // {}), (.devDependencies // {})) | to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null
        fi
    } | awk -F '\t' '!seen[$1]++'
}

# Print the packages of the list $1 (see list_packages) that match --packages.
matching_packages() {
    local name version
    while IFS=$'\t' read -r name version; do
        if [[ -n "$name" && "$name" =~ $PACKAGES ]]; then
            printf '%s\t%s\n' "$name" "$version"
        fi
    done <<< "$1"
}

# The syntax of the version ranges of TYPE: "composer" or "npm".
version_dialect() {
    case "$TYPE" in
        composer|composerJson) echo "composer" ;;
        *) echo "npm" ;;
    esac
}

# Parse --affected into AFFECTED_*: the syntax of security advisories (e.g.
# on packagist.org), "|" between alternatives, "," between conditions.
# Stop on an invalid range.
parse_affected() {
    VERSION_DIALECT=$(version_dialect)
    if [[ -z "$AFFECTED" ]]; then
        if [[ $GROUP_BY_AFFECTED -eq 1 ]]; then
            print_error "--group-by-affected needs --affected."
            exit 1
        fi
        return 0
    fi
    if ! range_parse "$AFFECTED" composer; then
        print_error "Invalid --affected: '$AFFECTED' (use e.g. '>=1.2.3,<2|<1.0.5')."
        exit 1
    fi
    range_keep affected
}

# Return 0 if the version or constraint $1 overlaps the --affected ranges,
# 1 if not, 2 if it is no version range (e.g. "dev-main", "latest").
is_affected() {
    range_parse "$1" "$VERSION_DIALECT" || return 2
    range_overlaps affected
}
