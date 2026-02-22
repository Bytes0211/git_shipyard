# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Git Shipyard is a single-file Bash utility (`git-shipyard.sh`) that automates the Git workflow: staging, committing, pushing, and creating GitHub pull requests in one interactive session. No build system or external dependencies beyond git, gh CLI, and bash 4.0+.

## Commands

```bash
# Run the script
./git-shipyard.sh
./git-shipyard.sh --base production --head feature-branch
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

- **Full mode** (uncommitted changes exist): stage → commit → push → create PR
- **PR-only mode** (commits ahead, open PR exists): push (if needed) → create PR
- **Squash-merge mode** (commits ahead, no open PRs): user chooses PR or direct squash-merge into base

Detection relies on `has_uncommitted_changes()`, `has_commits_ahead()`, and `has_open_prs()` functions.

### Script Structure (git-shipyard.sh)

- **Lines 10-11**: Default branch config (`BASE_BRANCH="main"`, `HEAD_BRANCH="dev"`)
- **Utility functions**: Color output, `error_exit()`, command checking
- **Pre-flight checks**: Validates git, gh CLI, authentication, remote
- **Line 164**: Stdin buffer flush for pasted multi-line text
- **Git operations section (lines ~197-224)**: Where new workflow steps should be inserted
- **PR creation**: Uses `gh pr create --base BASE --head HEAD --fill`
- **Line 259**: Global ERR trap for unexpected errors
- **Special case**: Existing PR opens in browser instead of failing

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
- `select_issue()`: Pre-PR-creation, adds `Closes #<issue>` to the new PR body
- `create_github_issue()`: Post-issue-creation, offers to append `Closes #<issue>` to an existing open PR body via `gh pr edit`

### Test Structure

Tests use BATS with isolated temporary git repositories per test case. Each test in `test/git-shipyard.bats` sources script functions via a helper that avoids running `main()`. Tests cover argument parsing, all three execution modes, issue/PR linking, command validation, and edge cases.

## Key Constraints

- GitHub-only (hardcoded to `gh` CLI) — abstracting would require changes to auth check (lines 98-101) and PR creation (lines 226-238)
- Uses `origin` remote by default
- Stages all changes (`git add .`), no selective staging
