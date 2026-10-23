# shellcheck shell=bash
# Sourced by gh-dep-scanner.sh: The GitHub rate limit: check, pacing and waits.

# The rate limit bucket of a gh call: GraphQL ("api graphql", "repo view")
# or REST ("core").
rate_bucket() {
    if [[ "$1" == "repo" || "${2:-}" == "graphql" ]]; then
        echo "graphql"
    else
        echo "core"
    fi
}

# The network requests of all scans in this directory (see RATE_COUNTER).
# Short option: BSD wc (macOS) has no --bytes.
network_requests() {
    if [[ -f "$RATE_COUNTER" ]]; then
        echo $(($(wc -c < "$RATE_COUNTER")))
    else
        echo 0
    fi
}

# Store the rate limits in RATE_FILE. "gh api rate_limit" does not count.
check_rate_limit() {
    if [[ $OFFLINE -eq 1 ]]; then
        return 0
    fi
    local limits requests
    limits=$(gh api rate_limit --jq '
        "core \(.resources.core.remaining) \(.resources.core.limit) \(.resources.core.reset)",
        "graphql \(.resources.graphql.remaining) \(.resources.graphql.limit) \(.resources.graphql.reset)"' 2>/dev/null) || return 0
    requests=$(network_requests)
    # Written at once (rename): another scan may read it now.
    write_cache_entry "$RATE_FILE" "$(echo "$limits" | awk -v requests="$requests" '{ print $0, requests }')"
    log INFO "Rate limit: $(echo "$limits" | awk '{ printf "%s %s of %s; ", $1, $2, $3 }')"
}

# Field $2 of the rate limit of bucket $1: 2 remaining, 3 limit, 4 reset,
# 5 network requests at the check.
rate_value() {
    awk -v bucket="$1" -v field="$2" '$1 == bucket { print $field }' "$RATE_FILE" 2>/dev/null
}

# "Rate limit: REST 4941 of 5000, GraphQL 4990 of 5000, resets at 00:01:06"
rate_limit_summary() {
    if [[ ! -s "$RATE_FILE" ]]; then
        echo "Rate limit: unknown"
        return
    fi
    echo "Rate limit: REST $(rate_value core 2) of $(rate_value core 3), GraphQL $(rate_value graphql 2) of $(rate_value graphql 3), resets at $(format_clock "$(rate_value core 4)")"
}

format_clock() {
    jq --null-input --raw-output --argjson time "$1" '$time | strflocaltime("%H:%M:%S")'
}

# Wait until epoch second $1, with a countdown. $2: the reason (for the log).
wait_until() {
    local until="$1" now
    if [[ $until -le $(date +%s) ]]; then
        return 0
    fi
    log WARN "$2: waiting until $(format_clock "$until")"
    if [[ $PROGRESS_SHOWN -eq 1 && -t 2 ]]; then
        echo "" >&2
    fi
    while now=$(date +%s); [[ $now -lt $until ]]; do
        if [[ -t 2 ]]; then
            printf '\r\033[K%s%s: waiting %s, until %s%s' "$YELLOW" "$2" "$(format_age $((until - now)))" "$(format_clock "$until")" "$NC" >&2
        fi
        sleep 1
    done
    if [[ -t 2 ]]; then
        printf '\r\033[K' >&2
    fi
}

# Before a network request: wait for the reset if the limit is used up.
# With less than 20 % left, spread the rest evenly until the reset.
pace_requests() {
    if [[ $OFFLINE -eq 1 || ! -s "${RATE_FILE:-}" ]]; then
        return 0
    fi
    local requests checked
    requests=$(network_requests)
    checked=$(rate_value "$1" 5)
    if [[ -z "$checked" ]]; then
        return 0
    fi
    if [[ $((requests - checked)) -ge $RATE_CHECK_EVERY ]]; then
        check_rate_limit
        checked=$(rate_value "$1" 5)
    fi
    local remaining limit reset now left
    remaining=$(rate_value "$1" 2)
    limit=$(rate_value "$1" 3)
    reset=$(rate_value "$1" 4)
    now=$(date +%s)
    left=$((remaining - (requests - checked)))
    if [[ $left -le 0 ]]; then
        wait_until "$reset" "Rate limit used up"
        check_rate_limit
    elif [[ $((left * 5)) -lt $limit && $reset -gt $now ]]; then
        log DEBUG "Rate limit: $left of $limit left, $(((reset - now) / left)) s per request until the reset"
        # A "z": the scan slows down for the rate limit.
        if [[ -t 2 ]]; then
            printf '%sz%s' "$YELLOW" "$NC" >&2
        fi
        sleep $(((reset - now) / left))
    fi
}
