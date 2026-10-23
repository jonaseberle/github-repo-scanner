# shellcheck shell=bash
# Sourced by gh-dep-scanner.sh: version ranges in npm and Composer syntax, as
# lists of intervals, and their overlap.

# A version is one number: major (up to 4 digits), minor (6) and patch (8,
# e.g. caniuse-lite 1.0.30001815). Above all of them, within 64 bits:
RANGE_INFINITY=9000000000000000000

# The result of range_parse: intervals from RANGE_LOW to RANGE_HIGH. A 1 in
# RANGE_LOW_IN or RANGE_HIGH_IN includes the end.
declare -a RANGE_LOW=() RANGE_LOW_IN=() RANGE_HIGH=() RANGE_HIGH_IN=()

# Set VERSION_PARTS to major, minor and patch of $1 (a missing part is 0),
# and VERSION_GIVEN to the number of parts before the first wildcard
# ("1.2.x" and "1.2" give 2). A pre-release or build suffix is ignored:
# "1.2.3-beta.1" is 1.2.3. Fails for a value that is not a version.
parse_version_parts() {
    local text="${1#[vV]}"
    text="${text%%+*}"
    text="${text%%-*}"
    VERSION_PARTS=(0 0 0)
    VERSION_GIVEN=0
    if [[ -z "$text" ]]; then
        return 0
    fi
    # Composer versions can have a fourth part: it is ignored.
    if [[ ! "$text" =~ ^([0-9]+|[xX*])(\.([0-9]+|[xX*]))?(\.([0-9]+|[xX*]))?(\.[0-9]+)?$ ]]; then
        return 1
    fi
    local part index=0 digits=(4 6 8)
    for part in "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]}"; do
        if [[ -z "$part" || "$part" == [xX*] ]]; then
            break
        fi
        # See RANGE_INFINITY. "10#": "08" is not octal.
        if [[ ${#part} -gt ${digits[index]} ]]; then
            return 1
        fi
        VERSION_PARTS[index]=$((10#$part))
        index=$((index + 1))
    done
    VERSION_GIVEN=$index
}

# Set VERSION_KEY to the number of the version $1 $2 $3.
version_key() {
    VERSION_KEY=$(($1 * 100000000000000 + $2 * 100000000 + $3))
}

# Set VERSION_KEY to the first version after the first $1 parts of
# VERSION_PARTS: 1.2.3 with 1 gives 2.0.0, with 2 gives 1.3.0.
next_version_key() {
    case "$1" in
        1) version_key $((VERSION_PARTS[0] + 1)) 0 0 ;;
        2) version_key "${VERSION_PARTS[0]}" $((VERSION_PARTS[1] + 1)) 0 ;;
        *) version_key "${VERSION_PARTS[0]}" "${VERSION_PARTS[1]}" $((VERSION_PARTS[2] + 1)) ;;
    esac
}

# Set COMPARATOR_* to the intervals of one comparator: the operator $1 and the
# version $2 in the syntax $3 (npm or composer). Fails for an unknown version.
comparator_intervals() {
    local operator="$1" dialect="$3" low high
    COMPARATOR_LOW=() COMPARATOR_LOW_IN=() COMPARATOR_HIGH=() COMPARATOR_HIGH_IN=()
    parse_version_parts "$2" || return 1
    local given=$VERSION_GIVEN
    version_key "${VERSION_PARTS[@]}"
    low=$VERSION_KEY

    # Without an operator: npm and a Composer wildcard take a partial version
    # as a range ("1.2" is 1.2.x). Composer takes "1.2" as exactly 1.2.0.
    if [[ "$operator" == "" || "$operator" == "=" || "$operator" == "==" ]]; then
        if [[ "$dialect" == "composer" && $given -gt 0 && "$2" != *[xX*]* ]]; then
            given=3
        fi
        if [[ $given -eq 0 ]]; then
            add_comparator 0 1 "$RANGE_INFINITY" 1
        elif [[ $given -eq 3 ]]; then
            add_comparator "$low" 1 "$low" 1
        else
            next_version_key "$given"
            add_comparator "$low" 1 "$VERSION_KEY" 0
        fi
        return 0
    fi

    # npm: a comparator with a partial version means its whole range,
    # ">1.2" is ">=1.3.0" and "<=1.2" is "<1.3.0". Composer fills in zeros.
    local partial=0
    if [[ "$dialect" == "npm" && $given -lt 3 ]]; then
        partial=1
    fi
    case "$operator" in
        ">=")
            add_comparator "$low" 1 "$RANGE_INFINITY" 1 ;;
        ">")
            if [[ $given -eq 0 ]]; then
                return 0
            elif [[ $partial -eq 1 ]]; then
                next_version_key "$given"
                add_comparator "$VERSION_KEY" 1 "$RANGE_INFINITY" 1
            else
                add_comparator "$low" 0 "$RANGE_INFINITY" 1
            fi ;;
        "<")
            if [[ $given -gt 0 || "$dialect" == "composer" ]]; then
                add_comparator 0 1 "$low" 0
            fi ;;
        "<=")
            if [[ $given -eq 0 ]]; then
                add_comparator 0 1 "$RANGE_INFINITY" 1
            elif [[ $partial -eq 1 ]]; then
                next_version_key "$given"
                add_comparator 0 1 "$VERSION_KEY" 0
            else
                add_comparator 0 1 "$low" 1
            fi ;;
        "!=")
            add_comparator 0 1 "$low" 0
            add_comparator "$low" 0 "$RANGE_INFINITY" 1 ;;
        "~")
            # npm: "~1.2" is ">=1.2.0 <1.3.0". Composer: "~1.2" is ">=1.2.0 <2.0.0".
            # Both: "~1.2.3" is ">=1.2.3 <1.3.0", "~1" is ">=1.0.0 <2.0.0".
            if [[ $given -eq 0 ]]; then
                add_comparator 0 1 "$RANGE_INFINITY" 1
                return 0
            fi
            high=$given
            if [[ $given -eq 3 || ( $given -eq 2 && "$dialect" == "composer" ) ]]; then
                high=$((given - 1))
            fi
            next_version_key "$high"
            add_comparator "$low" 1 "$VERSION_KEY" 0 ;;
        "^")
            # The first part that is not 0 must stay: "^1.2" is "<2.0.0",
            # "^0.2" is "<0.3.0", "^0.0.3" is "<0.0.4", "^0.0" is "<0.1.0".
            if [[ $given -eq 0 ]]; then
                add_comparator 0 1 "$RANGE_INFINITY" 1
                return 0
            fi
            high=1
            if [[ ${VERSION_PARTS[0]} -eq 0 && $given -ge 2 ]]; then
                high=2
                if [[ ${VERSION_PARTS[1]} -eq 0 && $given -eq 3 ]]; then
                    high=3
                fi
            fi
            next_version_key "$high"
            add_comparator "$low" 1 "$VERSION_KEY" 0 ;;
        *)
            return 1 ;;
    esac
}

add_comparator() {
    COMPARATOR_LOW+=("$1")
    COMPARATOR_LOW_IN+=("$2")
    COMPARATOR_HIGH+=("$3")
    COMPARATOR_HIGH_IN+=("$4")
}

# Intersect the intervals in CURRENT_* with those in COMPARATOR_*.
intersect_comparator() {
    local -a low=() low_in=() high=() high_in=()
    local i j a a_in b b_in
    for i in ${CURRENT_LOW[@]+"${!CURRENT_LOW[@]}"}; do
        for j in ${COMPARATOR_LOW[@]+"${!COMPARATOR_LOW[@]}"}; do
            a=${CURRENT_LOW[i]} a_in=${CURRENT_LOW_IN[i]}
            if [[ ${COMPARATOR_LOW[j]} -gt $a ]]; then
                a=${COMPARATOR_LOW[j]} a_in=${COMPARATOR_LOW_IN[j]}
            elif [[ ${COMPARATOR_LOW[j]} -eq $a && ${COMPARATOR_LOW_IN[j]} -eq 0 ]]; then
                a_in=0
            fi
            b=${CURRENT_HIGH[i]} b_in=${CURRENT_HIGH_IN[i]}
            if [[ ${COMPARATOR_HIGH[j]} -lt $b ]]; then
                b=${COMPARATOR_HIGH[j]} b_in=${COMPARATOR_HIGH_IN[j]}
            elif [[ ${COMPARATOR_HIGH[j]} -eq $b && ${COMPARATOR_HIGH_IN[j]} -eq 0 ]]; then
                b_in=0
            fi
            if [[ $a -lt $b || ( $a -eq $b && $a_in -eq 1 && $b_in -eq 1 ) ]]; then
                low+=("$a") low_in+=("$a_in") high+=("$b") high_in+=("$b_in")
            fi
        done
    done
    CURRENT_LOW=(${low[@]+"${low[@]}"})
    CURRENT_LOW_IN=(${low_in[@]+"${low_in[@]}"})
    CURRENT_HIGH=(${high[@]+"${high[@]}"})
    CURRENT_HIGH_IN=(${high_in[@]+"${high_in[@]}"})
}

# Set the RANGE_* intervals to the versions of the constraint $1 in the
# syntax $2: "npm" (package.json, .nvmrc) or "composer" (composer.json,
# --affected). Fails for a value that is no range, e.g. "dev-main", "latest"
# or a git URL.
#   npm:      "||" between alternatives, a space between conditions.
#   Composer: "||" or "|" between alternatives, a space or "," between
#             conditions, a stability flag like "@dev" is ignored.
#   Both:     hyphen ranges ("1.2 - 2.3"), "*", "x" and "X" as wildcards.
range_parse() {
    local constraint="$1" dialect="$2"
    RANGE_LOW=() RANGE_LOW_IN=() RANGE_HIGH=() RANGE_HIGH_IN=()
    constraint="${constraint//||/|}"
    if [[ "$dialect" == "composer" ]]; then
        constraint="${constraint//,/ }"
    fi

    local -a alternatives tokens
    local alternative token operator pending i
    IFS='|' read -r -a alternatives <<< "$constraint"
    # A constraint that ends with "|" has an empty last alternative.
    if [[ "$constraint" == *"|" ]]; then
        alternatives+=("")
    fi
    if [[ ${#alternatives[@]} -eq 0 ]]; then
        alternatives=("")
    fi
    for alternative in "${alternatives[@]}"; do
        CURRENT_LOW=(0) CURRENT_LOW_IN=(1) CURRENT_HIGH=("$RANGE_INFINITY") CURRENT_HIGH_IN=(1)
        if [[ "$alternative" =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]+-[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
            # A hyphen range: a partial upper end includes all of its range
            # ("1.2 - 2.3" ends before 2.4.0).
            local upper="${BASH_REMATCH[2]}"
            comparator_intervals ">=" "${BASH_REMATCH[1]}" composer || return 1
            intersect_comparator
            parse_version_parts "$upper" || return 1
            if [[ $VERSION_GIVEN -eq 3 ]]; then
                comparator_intervals "<=" "$upper" composer || return 1
            else
                comparator_intervals "<=" "$upper" npm || return 1
            fi
            intersect_comparator
        else
            read -r -a tokens <<< "$alternative"
            if [[ ${#tokens[@]} -eq 0 && "$dialect" == "composer" ]]; then
                return 1
            fi
            pending=""
            for token in ${tokens[@]+"${tokens[@]}"}; do
                token="$pending$token"
                pending=""
                if [[ "$dialect" == "composer" ]]; then
                    token="${token%@*}"
                fi
                # An operator with a space before its version: ">= 1.2".
                if [[ "$token" =~ ^(\>=|\<=|!=|==|\>|\<|=|~|\^)$ ]]; then
                    pending="$token"
                    continue
                fi
                [[ "$token" =~ ^(\>=|\<=|!=|==|\>|\<|=|~|\^)?(.*)$ ]]
                operator="${BASH_REMATCH[1]}"
                comparator_intervals "$operator" "${BASH_REMATCH[2]}" "$dialect" || return 1
                intersect_comparator
            done
            if [[ -n "$pending" ]]; then
                return 1
            fi
        fi
        for i in ${CURRENT_LOW[@]+"${!CURRENT_LOW[@]}"}; do
            RANGE_LOW+=("${CURRENT_LOW[i]}")
            RANGE_LOW_IN+=("${CURRENT_LOW_IN[i]}")
            RANGE_HIGH+=("${CURRENT_HIGH[i]}")
            RANGE_HIGH_IN+=("${CURRENT_HIGH_IN[i]}")
        done
    done
}

# Copy the RANGE_* intervals to OTHER_* (other) or to AFFECTED_* (affected).
range_keep() {
    if [[ "$1" == "affected" ]]; then
        AFFECTED_LOW=(${RANGE_LOW[@]+"${RANGE_LOW[@]}"})
        AFFECTED_LOW_IN=(${RANGE_LOW_IN[@]+"${RANGE_LOW_IN[@]}"})
        AFFECTED_HIGH=(${RANGE_HIGH[@]+"${RANGE_HIGH[@]}"})
        AFFECTED_HIGH_IN=(${RANGE_HIGH_IN[@]+"${RANGE_HIGH_IN[@]}"})
    else
        OTHER_LOW=(${RANGE_LOW[@]+"${RANGE_LOW[@]}"})
        OTHER_LOW_IN=(${RANGE_LOW_IN[@]+"${RANGE_LOW_IN[@]}"})
        OTHER_HIGH=(${RANGE_HIGH[@]+"${RANGE_HIGH[@]}"})
        OTHER_HIGH_IN=(${RANGE_HIGH_IN[@]+"${RANGE_HIGH_IN[@]}"})
    fi
}
declare -a AFFECTED_LOW=() AFFECTED_LOW_IN=() AFFECTED_HIGH=() AFFECTED_HIGH_IN=()
declare -a OTHER_LOW=() OTHER_LOW_IN=() OTHER_HIGH=() OTHER_HIGH_IN=()

# True if one interval of RANGE_* overlaps one of AFFECTED_* ($1: affected)
# or OTHER_* ($1: other).
range_overlaps() {
    local -a low low_in high high_in
    if [[ "$1" == "affected" ]]; then
        low=(${AFFECTED_LOW[@]+"${AFFECTED_LOW[@]}"}) low_in=(${AFFECTED_LOW_IN[@]+"${AFFECTED_LOW_IN[@]}"})
        high=(${AFFECTED_HIGH[@]+"${AFFECTED_HIGH[@]}"}) high_in=(${AFFECTED_HIGH_IN[@]+"${AFFECTED_HIGH_IN[@]}"})
    else
        low=(${OTHER_LOW[@]+"${OTHER_LOW[@]}"}) low_in=(${OTHER_LOW_IN[@]+"${OTHER_LOW_IN[@]}"})
        high=(${OTHER_HIGH[@]+"${OTHER_HIGH[@]}"}) high_in=(${OTHER_HIGH_IN[@]+"${OTHER_HIGH_IN[@]}"})
    fi
    local i j a a_in b b_in
    for i in ${RANGE_LOW[@]+"${!RANGE_LOW[@]}"}; do
        for j in ${low[@]+"${!low[@]}"}; do
            a=${RANGE_LOW[i]} a_in=${RANGE_LOW_IN[i]}
            if [[ ${low[j]} -gt $a ]]; then
                a=${low[j]} a_in=${low_in[j]}
            elif [[ ${low[j]} -eq $a && ${low_in[j]} -eq 0 ]]; then
                a_in=0
            fi
            b=${RANGE_HIGH[i]} b_in=${RANGE_HIGH_IN[i]}
            if [[ ${high[j]} -lt $b ]]; then
                b=${high[j]} b_in=${high_in[j]}
            elif [[ ${high[j]} -eq $b && ${high_in[j]} -eq 0 ]]; then
                b_in=0
            fi
            if [[ $a -lt $b || ( $a -eq $b && $a_in -eq 1 && $b_in -eq 1 ) ]]; then
                return 0
            fi
        done
    done
    return 1
}
