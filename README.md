# GitHub Dependency Scanner

A bash script that scans all repositories in a GitHub organization or personal account (or a single repository) to find which repos use packages in an affected version range.

## Why?

Managing dependencies across dozens (or hundreds) of repositories is challenging:

- **Upgrade planning**: Before a major version bump, know exactly which repos need updating
- **Security audits**: Quickly find repos using a vulnerable package version
- **Dependency tracking**: Get a unified view of package versions across all your projects

GitHub's built-in tools (Dependency Graph, Dependabot) work per-repository, but don't provide a simple way to query "which repos use package X below version Y" across your entire organization.

This script fills that gap.

## Features

- Scans all repositories in a GitHub organization or personal account (archived repositories are skipped)
- Supports **Composer** (PHP) and **Node** (JavaScript) dependencies
- Reads the installed Composer version from `composer.lock` (or the constraint from `composer.json` with `--type=composerJson`)
- Reads the installed Node version from `package-lock.json` or `yarn.lock` (or the constraint from `package.json` with `--type=nodeJson`)
- Interactive mode or CLI flags for automation
- Rate limiting to avoid GitHub API limits
- Caches every GitHub request in `./var/cache`, so a second scan needs no network
- Colored output with progress indicator
- Shows repo visibility (public/private) with `--show-visibility`
- Handles missing dependency files gracefully

## Requirements

- **[GitHub CLI (gh)](https://cli.github.com/)** - must be installed and authenticated
- **[jq](https://jqlang.github.io/jq/)** - JSON parser

### Installation

```bash
# macOS
brew install gh jq

# Authenticate GitHub CLI
gh auth login
```

## Usage

### Interactive Mode

Simply run the script without arguments:

```bash
./gh-dep-scanner.sh
```

You'll be prompted for:
1. GitHub URL (org, personal or a single repository)
2. Dependency type (composer/node/composerJson/nodeJson)
3. Packages (regular expression; Enter for all)
4. Affected version ranges (optional)
5. Branch (optional)

### CLI Flags

```bash
./gh-dep-scanner.sh [OPTIONS]

Options (values only in the form --option=value):
  --url=<url>         GitHub URL (org or personal repos page, or one repo)
  --type=<type>       Dependency type: "composer" (composer.lock), "composerJson"
                      (composer.json), "node" (package-lock.json or yarn.lock)
                      or "nodeJson" (package.json)
  --packages[=regex]  Packages whose name matches this extended regular
                      expression, e.g. '^livewire/livewire$'; without a regex,
                      all packages
  --affected=<ranges> Optional: affected version ranges, as in security
                      advisories, e.g. '>=13.0.0,<13.3.5|<6.4.5' (default:
                      show all found packages)
  --repo=<regex>      Optional: only repos whose name matches this extended
                      regular expression, e.g. --repo='^typo3-'
  --branch=<name>     Optional: specific branch to check (default: repo's default)
  --branches[=regex]  Optional: check all branches that match this extended
                      regular expression (instead of one branch); without a
                      regex, all branches
  --hide-unknown      Optional: hide rows without a dependency file
  --hide-absent       Optional: also hide rows without a matching package
  --hide-merged       Optional, with --branches: hide branches that are fully
                      merged into the default branch (one request per 100
                      branches; squash and rebase merges are not detected)
  --delay=<seconds>   Optional: delay after each network request (default: 0);
                      requests served from the cache do not wait. Without it,
                      the scan slows down when less than 20 % of the rate
                      limit is left, and waits for the reset when it is used up
  --alternativePaths[=regex]
                      Optional: also check the directories that match this
                      extended regular expression (one row per dependency
                      file); without a regex, all directories
  --show-visibility   Optional: add a column with the repo visibility
  --offline           Optional: use the cached repository list and do not check
                      for pushes (a cached scan then needs no network)
  --no-cache          Optional: do not read the cache in ./var/cache (new
                      responses are still written to it)
  -v, --verbose       Print each command before it runs (set -x)
  --help              Show help message
```

## Examples

### Find repos with Livewire < 4 in an organization

```bash
./gh-dep-scanner.sh \
  --url="https://github.com/orgs/YOUR_ORG/repositories" \
  --type=composer \
  --packages='^livewire/livewire$' \
  --affected='<4'
```

### Find repos with React < 18 for a personal account

```bash
./gh-dep-scanner.sh \
  --url="https://github.com/USERNAME" \
  --type=node \
  --packages='^react$' \
  --affected='<18'
```

### Find repos with Laravel < 10 on develop branch

```bash
./gh-dep-scanner.sh \
  --url="https://github.com/orgs/MyOrg/repositories" \
  --type=composer \
  --packages='^laravel/framework$' \
  --affected='<10' \
  --branch=develop
```

### Find all repos that use Livewire, in any version

```bash
./gh-dep-scanner.sh \
  --url="https://github.com/orgs/YOUR_ORG/repositories" \
  --type=composer \
  --packages='^livewire/livewire$'
```

### Check all branches that match a regular expression

`--branches` takes an extended regular expression. Each matching branch is one row, linked to the branch. Repositories without a matching branch are only counted in the summary.

```bash
# Branches that start with feat/ or upgrade/
./gh-dep-scanner.sh \
  --url="https://github.com/orgs/YOUR_ORG/repositories" \
  --type=composer \
  --packages='^typo3/cms-core$' \
  --affected='<13' \
  --branches='^feat/|^upgrade/'

# Branches that contain "typo3", or end with "upgrade"
./gh-dep-scanner.sh ... --branches='typo3'
./gh-dep-scanner.sh ... --branches='upgrade$'

# All branches
./gh-dep-scanner.sh ... --branches
```

### Debug a scan

`--verbose` prints each command before it runs.

```bash
./gh-dep-scanner.sh \
  --url="https://github.com/orgs/YOUR_ORG/repositories" \
  --type=composer \
  --packages='^livewire/livewire$' \
  --affected='<4' \
  --verbose
```

### Check a single repository

```bash
./gh-dep-scanner.sh \
  --url="https://github.com/OWNER/REPO" \
  --type=composer \
  --packages='^laravel/framework$' \
  --affected='<10'
```

### Check the constraint in composer.json instead of the installed version

```bash
./gh-dep-scanner.sh \
  --url="https://github.com/orgs/YOUR_ORG/repositories" \
  --type=composerJson \
  --packages='^livewire/livewire$' \
  --affected='<4'
```

### Also check subdirectories

```bash
./gh-dep-scanner.sh \
  --url="https://github.com/orgs/YOUR_ORG/repositories" \
  --type=composer \
  --packages='^typo3/cms-core$' \
  --affected='<12' \
  --alternativePaths='^(app|packages/[^/]+)$'
```

### Check the constraint in package.json instead of the installed version

```bash
./gh-dep-scanner.sh \
  --url="https://github.com/USERNAME" \
  --type=nodeJson \
  --packages='^react$' \
  --affected='<18'
```

### Show the visibility of each repository

```bash
./gh-dep-scanner.sh \
  --url="https://github.com/orgs/YOUR_ORG/repositories" \
  --type=composer \
  --packages='^livewire/livewire$' \
  --show-visibility
```

### Fetch everything again

`--no-cache` ignores the cache and replaces its entries with new responses.

```bash
./gh-dep-scanner.sh \
  --url="https://github.com/orgs/YOUR_ORG/repositories" \
  --type=composer \
  --packages='^livewire/livewire$' \
  --no-cache
```

## Cache

Each GitHub request is cached in `./var/cache` (relative to the current directory):

```
var/cache/
    api/orgs/YOUR_ORG/repos                     gh api --paginate orgs/YOUR_ORG/repos?type=all
    api/orgs/YOUR_ORG/repos.pushed              the newest pushes (also .updated, .full)
    api/orgs/NAME?about                         gh api orgs/NAME
    repo-view/OWNER/REPO                        gh repo view OWNER/REPO
    api/repos/OWNER/REPO/
        branches/main                           the commit of branch main
        branches?per_page=100&heads             all branches with their commits (for --branches)
        branches?merged-into=main&heads         the same, with the merge state (for --hide-merged)
        commit/<sha>/composer.lock              the file in commit <sha>
        commit/<sha>/tree?recursive=1           the file list (for --alternativePaths)
        commit/<sha>/webroot/composer.lock      a file in a subdirectory
```

- Files are cached by commit. A commit does not change, so these entries do not get old.
- A file that does not exist is cached too, with the suffix `.404`.
- Other errors (rate limit, authentication, network) are not cached.
- Each scan updates the repository list (a full list once in 24 hours, else only the repositories with new pushes) and deletes the entries of a repository that are older than its last push, except the files by commit. With `--offline`, a cached scan uses only local data.
- To fetch some requests again, delete their entries, for example:
  - `rm -r var/cache/api/repos/OWNER/REPO/branches` to check the branches again
  - `rm -r var/cache/api/repos/OWNER/REPO` to scan one repository again
- To fetch everything again, use `--no-cache` or delete `var/cache`.

Each run logs its GitHub requests and its steps to `./var/log/gh-dep-scanner.log`. At startup, a log of 20 MB or more is cut to its newer half.

## Sample Output

```
Scanning YOUR_ORG repositories for packages matching ^typo3/cms-core$, affected: <13...
Branch: default

Results: packages matching ^typo3/cms-core$ in repositories (affected: <13)
================================================================================

REPO URL                                   PACKAGE        VERSION
--------                                   -------        -------

FOUND
https://github.com/YOUR_ORG/client-portal  typo3/cms-core v12.4.45 *
https://github.com/YOUR_ORG/project-alpha  typo3/cms-core v13.4.36
https://github.com/YOUR_ORG/shop-backend   typo3/cms-core v11.5.41 *

PACKAGE NOT FOUND
https://github.com/YOUR_ORG/time-tracker                  Not found

VERSION FILE NOT FOUND (composer.lock)
https://github.com/YOUR_ORG/marketing-site                N/A

================================================================================
Summary:
  - Total repos scanned: 5
  - Archived repos: 1
  - Packages affected: 2
  - Repos without composer.lock: 1
  - Files without packages matching ^typo3/cms-core$: 1
  - Requests served from the cache: 9 of 11 (oldest entry: 2d 3h old)
```

### Output Legend

Rows are grouped: FOUND (the package is in the dependency file), PACKAGE NOT FOUND (the package is not in it), VERSION FILE NOT FOUND (no dependency file) and PARSE ERROR (invalid dependency file). Inside each group, rows are sorted by URL.

In FOUND, a version in an `--affected` range is red, and the row ends with `*`. A version outside the ranges is green.

With `--type=node`, the PATH column shows the lock file. A directory with both `package-lock.json` and `yarn.lock` gets a row for each file, and a warning.

During the scan, marks show the progress:

| Mark | Meaning |
|------|---------|
| `.` | A network request |
| `x` | A network or GitHub error; the request is sent again |
| `z` | A wait for the rate limit |
| `~` | A wait for another scan that fetches the same entry |

## Supported URL Formats

All of these formats are accepted:

```
https://github.com/orgs/YOUR_ORG/repositories
https://github.com/orgs/YOUR_ORG
https://github.com/USERNAME?tab=repositories
https://github.com/USERNAME
https://github.com/OWNER/REPO
```

## Version Comparison Logic

`--affected` takes ranges like the security advisories on packagist.org: `|` separates alternatives, `,` joins conditions that must all hold, e.g. `>=13.0.0,<13.3.5|<6.4.5`. Operators: `>=`, `>`, `<=`, `<`, `=`, `!=`.

For a constraint (`--type=composerJson`, `--type=nodeJson`), the script takes its first version:

| Constraint | Extracted version | Affected by `<4`? |
|------------|-------------------|----------|
| `^3.2` | 3.2.0 | Yes |
| `~3.1.0` | 3.1.0 | Yes |
| `>=3.0` | 3.0.0 | Yes |
| `3.*` | 3.0.0 | Yes |
| `^4.0` | 4.0.0 | No |
| `4.1.2` | 4.1.2 | No |
| `v3.5.2` (from `composer.lock`) | 3.5.2 | Yes |
| `*` | 0.0.0 | Yes (conservative) |
| `dev-main` | 0.0.0 | Yes (conservative) |

## Limitations

- Does not read `pnpm-lock.yaml`
- In `yarn.lock`, uses the first entry for the package if there are several versions

## License

MIT License - feel free to use, modify, and distribute.

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.
