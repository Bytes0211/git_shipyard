# AGENTS.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

Git Shipyard is a single-file Bash utility (`git-shipyard.sh`) that automates the Git workflow: staging, committing, pushing, and creating GitHub pull requests in one interactive session.

## Architecture

### Single Script Design
The entire application is contained in `git-shipyard.sh` with no external dependencies beyond standard Unix tools, git, and GitHub CLI (gh).

### Execution Modes
The script automatically detects and switches between two operational modes:
- **Full mode**: Triggered when uncommitted changes exist (staged, unstaged, or untracked files). Executes: stage → commit → push → create PR
- **PR-only mode**: Triggered when branch has commits ahead of base but no uncommitted changes. Executes: push (if needed) → create PR

Mode detection logic relies on `has_uncommitted_changes()` and `has_commits_ahead()` functions which query git state.

### Error Handling Strategy
- All Git/GitHub operations use conditional checks with `error_exit()` on failure
- Global ERR trap (line 259) catches unexpected errors
- Special case: If PR already exists, script opens it in browser rather than failing

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
- Test both execution modes by manipulating repository state

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
- Line 164 flushes stdin buffer to handle pasted multi-line text that could interfere with confirmation prompt
- Empty commit messages are rejected before any git operations execute

### State Detection Functions
- `has_uncommitted_changes()`: Checks git diff (staged/unstaged) and untracked files
- `has_commits_ahead()`: Uses `git rev-list --count BASE..HEAD` to detect unpushed commits
- Both functions determine which workflow mode executes

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
