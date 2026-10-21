# GitHub Dependency Scanner

A bash script that scans all repositories in a GitHub organization or personal account (or a single repository) to find which repos use a specific package below a given version.

## Why?

Managing dependencies across dozens (or hundreds) of repositories is challenging:

- **Upgrade planning**: Before a major version bump, know exactly which repos need updating
- **Security audits**: Quickly find repos using a vulnerable package version
- **Dependency tracking**: Get a unified view of package versions across all your projects

GitHub's built-in tools (Dependency Graph, Dependabot) work per-repository, but don't provide a simple way to query "which repos use package X below version Y" across your entire organization.

This script fills that gap.

## Features

- Scans all repositories in a GitHub organization or personal account
- Supports **Composer** (PHP) and **Node** (JavaScript) dependencies
- Reads the installed Composer version from `composer.lock` (or the constraint from `composer.json` with `--type composerJson`)
- Interactive mode or CLI flags for automation
- Rate limiting to avoid GitHub API limits
- Colored output with progress indicator
- Shows repo visibility (public/private)
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
2. Dependency type (composer/node/composerJson)
3. Package name
4. Minimum version to check against
5. Branch (optional)

### CLI Flags

```bash
./gh-dep-scanner.sh [OPTIONS]

Options:
  --url <url>         GitHub URL (org or personal repos page, or one repo)
  --type <type>       Dependency type: "composer" (composer.lock), "composerJson"
                      (composer.json) or "node" (package.json)
  --package <name>    Package name to search for
  --below <version>   Find packages below this major version
  --branch <name>     Optional: specific branch to check (default: repo's default)
  --delay <seconds>   Optional: delay between API requests (default: 1)
  -v, --verbose       Print each command before it runs (set -x)
  --help              Show help message
```

## Examples

### Find repos with Livewire < v4 in an organization

```bash
./gh-dep-scanner.sh \
  --url "https://github.com/orgs/YOUR_ORG/repositories" \
  --type composer \
  --package livewire/livewire \
  --below 4
```

### Find repos with React < v18 for a personal account

```bash
./gh-dep-scanner.sh \
  --url "https://github.com/USERNAME" \
  --type node \
  --package react \
  --below 18
```

### Find repos with Laravel < v10 on develop branch

```bash
./gh-dep-scanner.sh \
  --url "https://github.com/orgs/MyOrg/repositories" \
  --type composer \
  --package laravel/framework \
  --below 10 \
  --branch develop
```

### Increase delay for large organizations (avoid rate limits)

```bash
./gh-dep-scanner.sh \
  --url "https://github.com/orgs/LargeOrg/repositories" \
  --type composer \
  --package symfony/console \
  --below 6 \
  --delay 2
```

### Debug a scan

`--verbose` prints each command before it runs.

```bash
./gh-dep-scanner.sh \
  --url "https://github.com/orgs/YOUR_ORG/repositories" \
  --type composer \
  --package livewire/livewire \
  --below 4 \
  --verbose
```

### Check a single repository

```bash
./gh-dep-scanner.sh \
  --url "https://github.com/OWNER/REPO" \
  --type composer \
  --package laravel/framework \
  --below 10
```

## Sample Output

```
Scanning YOUR_ORG repositories for livewire/livewire < 4...
Branch: default

REPO URL                                          NAME              VERSION      VISIBILITY
--------                                          ----              -------      ----------
https://github.com/YOUR_ORG/project-alpha         project-alpha     ^3.2         private
https://github.com/YOUR_ORG/client-portal         client-portal     N/A          private
https://github.com/YOUR_ORG/marketing-site        marketing-site    ~3.1.0       public

================================================================================
Summary:
  - Total repos scanned: 25
  - Repos with livewire/livewire below v4: 2
  - Repos without composer.json: 5
  - Repos without livewire/livewire in dependencies: 10
```

### Output Legend

| Color | Meaning |
|-------|---------|
| Red | Package found below target version |
| Yellow | No dependency file (composer.lock/composer.json/package.json) |
| Cyan | Dependency file exists but package not found |
| Green | All repos at target version or higher |

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

The script extracts the major version from common constraint formats:

| Constraint | Extracted Major | Below v4? |
|------------|-----------------|-----------|
| `^3.2` | 3 | Yes |
| `~3.1.0` | 3 | Yes |
| `>=3.0` | 3 | Yes |
| `3.*` | 3 | Yes |
| `^4.0` | 4 | No |
| `4.1.2` | 4 | No |
| `*` | 0 | Yes (conservative) |
| `dev-main` | 0 | Yes (conservative) |

## Limitations

- Only scans the root dependency file (not monorepo subdirectories)
- Compares major versions only (not minor/patch)
- Maximum ~1000 repos per scan (GitHub API limit)
- Reads `package.json`, not `package-lock.json`

## License

MIT License - feel free to use, modify, and distribute.

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.
