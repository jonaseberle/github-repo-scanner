# shellcheck shell=bash
# Sourced by gh-dep-scanner.sh: Branches: list with branch status, and the commit of a branch.

# Print the branches of repository $1 that match --branches as
# "name<TAB>commit<TAB>branch status", one per line. With --hide-merged, a
# branch that is fully merged into the default branch ($2) is printed as
# "merged<TAB>name".
matching_branches() {
    local listing
    listing=$(branches_with_status "$1" "$2")

    # Branch names contain no spaces, tabs or glob characters.
    local name ahead behind commit status
    while IFS=$'\t' read -r name ahead behind commit; do
        if [[ -z "$name" || ! "$name" =~ $BRANCHES ]]; then
            continue
        fi
        if [[ "$name" == "$2" ]]; then
            status="default"
        elif [[ "$ahead" == "-" ]]; then
            # GitHub gave no comparison, e.g. after a timeout.
            status="?"
        else
            status="$ahead/$behind"
        fi
        # Nothing of the branch is missing in the default branch: it is merged.
        if [[ $HIDE_MERGED -eq 1 && "$ahead" == "0" && "$name" != "$2" ]]; then
            printf 'merged\t%s\n' "$name"
        else
            printf '%s\t%s\t%s\n' "$name" "$commit" "$status"
        fi
    done <<< "$listing"
}

# Print "name<TAB>ahead<TAB>behind<TAB>commit" for all branches of repository
# $1. Ahead: the commits of the branch that are not in the default branch
# ($2). Behind: the other way round. "-" if GitHub gives no comparison.
# One GraphQL request per 100 branches, instead of one comparison per branch.
branches_with_status() {
    # $owner, $name, $base and $endCursor are GraphQL variables, not shell ones.
    # shellcheck disable=SC2016
    local query='query($owner: String!, $name: String!, $base: String!, $endCursor: String) {
        repository(owner: $owner, name: $name) {
            refs(refPrefix: "refs/heads/", first: 100, after: $endCursor) {
                pageInfo { hasNextPage endCursor }
                nodes { name target { oid } compare(headRef: $base) { aheadBy behindBy } }
            }
        }
    }'
    # The branch is the base of the comparison: its "behindBy" are the
    # commits that only the branch has.
    local listing
    listing=$(gh_cached "api/repos/$OWNER/$1/branches?compare=$2&heads" api graphql --paginate \
        -f owner="$OWNER" -f name="$1" -f base="$2" -f query="$query" \
        --jq '.data.repository.refs.nodes[] | "\(.name)\t\(.compare.behindBy // "-")\t\(.compare.aheadBy // "-")\t\(.target.oid)"') || {
        print_error "Failed to fetch the branches of $OWNER/$1: $listing"
        exit 1
    }
    echo "$listing"
}

# Print the commit of branch $2 in repository $1, or nothing if there is no
# such branch (e.g. an empty repository).
branch_commit() {
    # "gh repo view" gives an empty repository no default branch name.
    if [[ -z "$2" ]]; then
        return 0
    fi
    local commit
    commit=$(gh_cached "api/repos/$OWNER/$1/branches/$2" api "repos/$OWNER/$1/branches/$(url_encode "$2")" --jq '.commit.sha') || {
        if [[ "$(http_status "$commit")" == "404" ]]; then
            return 0
        fi
        print_error "Failed to fetch the branch $2 of $OWNER/$1: $commit"
        exit 1
    }
    echo "$commit"
}
