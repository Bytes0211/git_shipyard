# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Git Shipyard is a single-file Bash utility (`git-shipyard.sh`) that automates the Git workflow: staging, committing, pushing, creating GitHub pull requests, and managing PRs/issues — all in one interactive session. No build system or external dependencies beyond git, gh CLI, jq, and bash 4.0+.

## Commands

```bash
# Run the script
./git-shipyard.sh
./git-shipyard.sh --base production --head feature-branch
./git-shipyard.sh --draft
./git-shipyard.sh --help

# Run tests (requires bats - https://github.com/bats-core/bats-core)
bats test/git-shipyard.bats

# Run a single test by name
bats test/git-shipyard.bats --filter "test name pattern"

# Lint (not configured, but recommended)
shellcheck git-shipyard.sh
```

## Architecture

### Execution Modes

The script auto-detects repository state and switches between three modes:

- **Full mode** (uncommitted changes exist): stage → commit → push → sync → create PR
- **PR-only mode** (commits ahead of base): check for open PRs with comments → push (if needed) → sync → create PR
- **PR Management mode** (clean working tree, no commits ahead): select a PR → action menu

Detection relies on `has_uncommitted_changes()` and `has_commits_ahead()` functions.

### PR Management Action Menu

When entering PR Management mode, the user selects an open PR, then chooses from:

1. **View details & comments** (`view_pr_details()`): Shows PR metadata (title, state, author, branch, diff stats, labels, description), comments with authors/dates, and code reviews with color-coded states (APPROVED/CHANGES_REQUESTED/COMMENTED)
2. **Close PR** (`close_pr()`): Closes without merging, optionally deletes remote branch, offers to clean up local branch
3. **Squash-merge PR** (`squash_merge_pr()`): Squash-merges via `gh pr merge --squash --delete-branch`, switches to base, pulls latest, cleans up local branch, resets dev environment
4. **View/close linked issues** (`view_linked_issues()`): Parses PR body for issue references (`Closes #N`, `Fixes #N`, `Resolves #N`, `Part of #N`), displays issues with state (OPEN/CLOSED), offers to close individual or all open issues

The action menu loops — view and linked-issues actions return to the menu; close and squash-merge exit.

### Script Structure (git-shipyard.sh)

- **Lines 10-11**: Default branch config (`BASE_BRANCH="main"`, `HEAD_BRANCH="dev"`)
- **Utility functions**: Color output, `error_exit()`, `spinner()`, command checking, `get_editor()`, `format_message_preview()`
- **Pre-flight checks**: Validates git, gh CLI, jq, authentication, remote, detached HEAD, base branch guard; in PR-only mode, checks for open PRs with comments via `check_prs_with_comments()`
- **Commit workflow**: `get_commit_message()` (single-line or editor), `link_to_pr()` (amend commit with PR reference)
- **Issue linking**: `select_issue()` fetches open issues for PR linking; when none exist, offers to create one via `_create_issue_for_pr()`
- **Sync**: `sync_with_base()` fetches and merges base into head before PR creation; `check_merge_in_progress()` intercepts unresolved merges
- **PR comment check**: `check_prs_with_comments()` runs during pre-flight in PR-only mode; fetches open PRs with comments, lists them with comment counts, lets user view details via `view_pr_details()`, then offers to close the PR and exit, exit without closing, or continue with the workflow
- **PR Management**: `pr_management_mode()` → action menu dispatching to `view_pr_details()`, `close_pr()`, `squash_merge_pr()`, `view_linked_issues()`
- **Dev reset**: `reset_dev_environment()` pulls latest base, recreates fresh head branch (called by `squash_merge_pr()` after successful merge)
- **Standalone issue creation**: `prompt_issue_creation()` at startup before pre-flight checks
- **PR creation**: Uses `gh pr create --fill` or `--title`/`--body` when linking an issue
- **Source guard**: `main()` only runs when executed directly, not when sourced (enables testing)

### Adding New Workflow Steps

Follow the existing pattern:
```bash
echo -e "${BLUE}Action description...${NC}"
if ! your_command; then
    error_exit "Failure message."
fi
echo -e "  ${GREEN}✓${NC} Success message"
```

### Issue and PR Linking

- `link_to_pr()`: Post-commit, amends commit message with `Part of #<PR>` to link to an existing open PR
- `select_issue()`: Pre-PR-creation, fetches open issues and lets user pick one. Sets `SELECTED_ISSUE` which adds `Closes #<issue>` to the new PR body. When no issues exist, offers to create one via `_create_issue_for_pr()`
- `_create_issue_for_pr()`: Internal helper that creates a GitHub issue and sets `SELECTED_ISSUE` so it's linked to the upcoming PR
- `view_linked_issues()`: In PR Management mode, parses a PR body for linked issue references and offers to close them

### Test Structure

Tests use BATS with isolated temporary git repositories per test case. Each test in `test/git-shipyard.bats` sources script functions via a helper that avoids running `main()`. Tests cover:

- Argument parsing (`--base`, `--head`, `--draft`, `--help`)
- Mode detection (full, PR-only, PR management)
- Command validation and error handling
- Issue creation and linking (`select_issue`, `_create_issue_for_pr`)
- PR Management action menu validation
- `check_prs_with_comments()`: no PRs, no comments, listing with comment counts, skip selection, view on selection, close and exit, exit without closing, continue with workflow, integration in pr_only mode, non-interactive skip, action menu options
- `view_pr_details()`: metadata display, comments, review state color-coding
- `close_pr()`: cancellation, success/failure, branch deletion, summary
- `squash_merge_pr()`: confirmation, conflict detection, summary, `reset_dev_environment` integration
- `view_linked_issues()`: keyword parsing (case-insensitive), deduplication, state display, close all/single/skip, failure handling
- Sync (`sync_with_base`, `check_merge_in_progress`)
- Standalone issue creation (`prompt_issue_creation`)

## Key Constraints

- GitHub-only (hardcoded to `gh` CLI) — abstracting would require changes to auth check and all `gh` calls
- Requires `jq` for JSON parsing of `gh` API responses
- Uses `origin` remote by default
- Stages all changes (`git add .`), no selective staging
- `reset_dev_environment()` is only called after squash-merge, not before the PR management menu