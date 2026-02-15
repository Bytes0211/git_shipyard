# AGENTS.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

Git Shipyard is a single-file Bash utility (`git-shipyard.sh`) that automates the Git workflow: staging, committing, pushing, and creating GitHub pull requests—or performing direct squash-merges—in one interactive session.

## Architecture

### Single Script Design
The entire application is contained in `git-shipyard.sh` with no external dependencies beyond standard Unix tools, git, and GitHub CLI (gh).

### Execution Modes
The script automatically detects and switches between three operational modes:
- **Full mode**: Triggered when uncommitted changes exist (staged, unstaged, or untracked files). Executes: stage → commit → push → create PR
- **PR-only mode**: Triggered when branch has commits ahead of base and an open PR exists. Executes: push (if needed) → create PR
- **Squash-merge mode**: Triggered when branch has commits ahead, no uncommitted changes, and no open PRs. User chooses between PR or direct squash-merge into base branch.

Mode detection logic relies on `has_uncommitted_changes()`, `has_commits_ahead()`, and `has_open_prs()` functions which query git and GitHub state.

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
# Run all BATS tests (33 tests)
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
- Default branches: `BASE_BRANCH="main"`, `HEAD_BRANCH="dev"` (lines 10-11)
- Overrideable via `--base` and `--head` flags
- These defaults determine PR direction and push targets

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
- `has_open_prs()`: Uses `gh pr list --head BRANCH --state open` to check for existing PRs
- These functions determine which workflow mode executes

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
Users can override defaults per-invocation with flags, or modify lines 10-11 for permanent changes. Consider reading from git config if permanent per-repo customization needed.

### Squash-Merge Considerations
- Squash-merge uses `git merge --squash` which does NOT set `MERGE_HEAD`
- On conflict, must use `git reset --merge` (not `git merge --abort`)
- After squash-merge, user is prompted to delete feature branch
- Warning displayed if user keeps branch (re-merge may cause duplicate conflicts)
