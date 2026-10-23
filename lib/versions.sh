# shellcheck shell=bash
# Sourced by gh-dep-scanner.sh: Packages of a dependency file, versions and --affected.

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
# Fails if jq cannot parse the file, or if it is not a JSON object.
list_packages() {
    local content="$1"
    local dep_type="$2"
    # A dependency file in JSON is an object.
    local object='if type != "object" then error("not an object") else . end | '

    {
        if [[ "$dep_type" == "composer" ]]; then
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
