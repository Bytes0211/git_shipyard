# AGENTS.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

Git Shipyard is a single-file Bash utility (`git-shipyard.sh`) that automates the Git workflow: staging, committing, pushing, and creating GitHub pull requests—or performing direct squash-merges—in one interactive session.

## Architecture

### Single Script Design
The entire application is contained in `git-shipyard.sh` with no external dependencies beyond standard Unix tools, git, GitHub CLI (gh), and jq (for JSON parsing).

### Execution Modes
The script automatically detects and switches between five operational modes:
- **Full mode**: Triggered when uncommitted changes exist (staged, unstaged, or untracked files). Executes: stage → commit → push → create PR
- **Squash-eligible mode**: Triggered when branch has commits ahead of base AND no open PRs exist for the branch. Prompts user to choose: (1) create a PR (continues as PR-only) or (2) squash-merge directly (push → sync → create PR → squash-merge → clean up branches → reset environment).
- **PR-only mode**: Triggered when branch has commits ahead of base AND open PRs exist. Executes: push (if needed) → create PR. Includes a merge-ready sub-check (see below).
- **Merge-ready mode** (sub-mode of PR-only): Triggered when all PR-only conditions are met AND the branch is fully pushed (local HEAD == remote HEAD), an open PR exists for the branch, and the PR has a linked issue. Offers to merge the PR, clean up branches, and create a new feature branch.
- **PR Management mode**: Triggered when clean working tree and no commits ahead of base. Interactive menu to view, close, squash-merge PRs, or manage linked issues.

Mode detection logic relies on `has_uncommitted_changes()`, `has_commits_ahead()`, `has_open_prs()`, `is_local_synced_with_remote()`, `has_open_pr_for_branch()`, and `pr_has_linked_issue()` functions which query git and GitHub state.

### Error Handling Strategy
- All Git/GitHub operations use conditional checks with `error_exit()` on failure
- ERR trap inside `main()` catches unexpected errors (moved inside main for source guard compatibility)
- Special case: If PR already exists, script opens it in browser rather than failing
- Squash-merge conflicts trigger PR fallback option with proper `git reset --merge` cleanup

## Development Commands

### Testing the Script
```bash
# Test in a repository with uncommitted changes (full mode)
./git-shipyard.sh

# Test with custom branches
./git-shipyard.sh --base production --head feature-branch

# Test PR-only mode: commit changes first, then run
git commit -m "test"
./git-shipyard.sh
```

### Manual Testing Prerequisites
- Must be in a git repository with configured origin remote
- Requires GitHub CLI authentication: `gh auth status`
- Test all three execution modes by manipulating repository state

### Running Unit Tests
```bash
# Run all BATS tests (159 tests)
bats test/git-shipyard.bats
```

### Installation Testing
```bash
# Verify executable permissions
chmod +x git-shipyard.sh

# Test as git subcommand (requires script in PATH as 'git-shipyard')
git shipyard --help
```

## Key Implementation Details

### Branch Configuration
- `BASE_BRANCH` defaults to `"main"` (line 10)
- `HEAD_BRANCH` auto-detects from the current branch via `git symbolic-ref --short HEAD` (line 11); falls back to empty and is resolved in `main()` after pre-flight checks
- Both are overrideable via `--base` and `--head` flags
- These values determine PR direction and push targets

### GitHub CLI Integration
- Uses `gh pr create --base BASE --head HEAD --fill` to auto-populate PR from commit messages
- Depends on gh authentication state checked via `gh auth status`
- PR view fallback if creation fails due to existing PR

### Input Handling
- `get_commit_message()`: Prompts user to choose single-line input or multi-line via editor
- Editor mode respects `git config core.editor`, `$VISUAL`, `$EDITOR`, with fallback to nano/vim/vi
- `format_message_preview()`: Truncates multi-line messages for display (shows first line + count)
- Empty commit messages are rejected before any git operations execute

### State Detection Functions
- `has_uncommitted_changes()`: Checks git diff (staged/unstaged) and untracked files
- `has_commits_ahead()`: Uses `git rev-list --count BASE..HEAD` to detect unpushed commits
- `has_open_prs()`: Queries `gh pr list --head HEAD_BRANCH --state open` to check if open PRs exist for the current branch
- `is_local_synced_with_remote()`: Fetches remote HEAD_BRANCH and compares commit hashes to verify all commits are pushed
- `has_open_pr_for_branch()`: Queries `gh pr list` for an open PR matching HEAD_BRANCH → BASE_BRANCH; sets `MERGE_READY_PR_NUMBER` and `MERGE_READY_PR_TITLE` globals
- `pr_has_linked_issue()`: Scans PR body for closing keywords (`Closes/Fixes/Resolves/Part of #N`)
- These functions determine which workflow mode executes

### PR and Issue Linking Functions
- `link_to_pr()`: After committing, prompts user to link the commit to an existing open PR by amending the commit message with `Part of #<PR>`
- `select_issue()`: Before PR creation, prompts user to link a GitHub issue to the new PR using `Closes #<issue>` in PR body
- `create_github_issue()`: After creating a new issue, prompts user to link it to an existing open PR by appending `Closes #<issue>` to the PR body via `gh pr edit`
- All functions list available items via `gh pr list` / `gh issue list` and parse JSON with `jq`
- Option "0" (None) skips linking in all cases

### Source Guard
The script uses a source guard pattern for testability:
```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```
This allows BATS tests to source the script and test individual functions without executing `main()`.

## Modification Guidelines

### Adding New Workflow Steps
Insert between lines 197-224 (git operations section). Follow pattern:
```bash
echo -e "${BLUE}Action description...${NC}"
if ! your_command; then
    error_exit "Failure message."
fi
echo -e "  ${GREEN}✓${NC} Success message"
```

### Supporting Additional Git Hosting Providers
- Current implementation hardcoded to GitHub via `gh` CLI
- Would require abstracting lines 98-101 (auth check) and 226-238 (PR creation)
- Consider adding `--provider` flag and conditional logic

### Branch Defaults for Different Projects
HEAD_BRANCH auto-detects the current branch, so no per-project configuration is needed for the head branch. Users can override the base branch per-invocation with `--base`, or modify line 10 for a permanent change. Consider reading from git config if permanent per-repo customization is needed.

### Merge-Ready Mode
- Detected within `pr_only` mode after `check_prs_with_comments`, before the normal push/PR flow
- Conditions: clean tree + local HEAD matches `origin/HEAD_BRANCH` + open PR exists + PR body has linked issue
- Executes: `gh pr merge --merge --delete-branch` → `git checkout BASE` → `git pull` → delete local branch → prompt for new feature branch
- Uses `--delete-branch` flag to handle remote branch cleanup (no separate `git push origin --delete` needed)
- If user declines, falls back to normal `pr_only` workflow
- `merge_ready_mode()` returns 0 on success (caller exits), 1 if declined (caller continues)

### Squash-Merge Considerations
- Squash-merge uses `git merge --squash` which does NOT set `MERGE_HEAD`
- On conflict, must use `git reset --merge` (not `git merge --abort`)
- After squash-merge, user is prompted to delete feature branch
- Warning displayed if user keeps branch (re-merge may cause duplicate conflicts)
