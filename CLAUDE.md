# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Communication Guidelines

### Language
Always respond in English unless explicitly requested otherwise.

### Git Workflow
#### Initial Check
At the start of each conversation, always run:
1. `git fetch` to get the latest remote information
2. `git status` to check the current repository state

#### After completing any task:
1. Ask if the user wants to commit and push changes to the GitHub repository
2. If confirmed, commit changes with Turkish commit messages
3. Push to the remote repository

#### Commit Message Guidelines
When creating commit messages, **DO NOT** include the following automated signatures:
- 🤖 Generated with [Claude Code](https://claude.ai/code)
- Co-Authored-By: Claude <noreply@anthropic.com>

Keep commit messages clean, descriptive, and focused on the actual changes made.

## Project Overview

A single-file bash script (`gh-dep-scanner.sh`) that scans GitHub repositories (org or personal) to find which repos use packages in an affected version range. Supports Composer (PHP) and Node (JavaScript) dependencies.

## Requirements

- `gh` (GitHub CLI) - must be authenticated
- `jq` (JSON parser)

## Running the Script

```bash
# Scan
./gh-dep-scanner.sh --url="https://github.com/orgs/ORG_NAME/repositories" \
                    --type=composer \
                    --packages='^livewire/livewire$' \
                    --affected='<4'

# Show help
./gh-dep-scanner.sh --help
```

## Script Architecture

The script is organized into sections marked by comment blocks:

1. **HELPER FUNCTIONS** - Color output utilities (`print_error`, `print_success`, etc.)
2. **PREREQUISITES CHECK** - Verifies `gh` and `jq` are installed
3. **ARGUMENT PARSING** - Options in the form `--option=value` only (see `--help`)
4. **URL PARSING** - Extracts owner/org from various GitHub URL formats
5. **REPOSITORY FETCHING** - REST repository list, updated from the cache by push and update time
6. **DEPENDENCY FILE FETCHING** - Fetches the dependency files by commit (batched with GraphQL for the root files)
7. **VERSION EXTRACTION** - Lists the packages of a dependency file (`jq`, `awk` for `yarn.lock`)
8. **VERSION COMPARISON** - Parses constraints to major, minor, patch and checks the `--affected` ranges
9. **MAIN SCANNING LOGIC** - Iterates repos and branches
10. **OUTPUT** - Colored table output with summary

## Key Functions

- `gh_cached()` - Runs a `gh` call once and caches its output in `./var/cache` (a 404 as `<key>.404`), with a lock per key
- `gh_request()` - Sends a `gh` call: pacing, retries, rate limit waits
- `fetch_dependency_file()` - Returns the file content of a commit or `NOT_FOUND`/`PARSE_ERROR`
- `prefetch_dependency_files()` - Fills the cache with the root dependency files of 20 repos per GraphQL request
- `list_packages()` - Prints `name<TAB>version` for all packages of a dependency file
- `parse_version()` - Sets `VERSION` to major, minor, patch of a constraint (`^`, `~`, `>=`, OR constraints, etc.)
- `is_affected()` - Checks a version against the `--affected` ranges

## Commit Guidelines

Do not include AI-generated signatures or co-author attributions in commits.
