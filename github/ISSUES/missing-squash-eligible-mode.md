# Bug: Cannot merge branch with multiple commits ahead — missing `squash_eligible` mode

## Overview

When a feature branch has multiple commits ahead of `main` with no uncommitted changes and no open PRs, the script should offer a direct squash-merge option (`squash_eligible` mode). Instead, it always enters `pr_only` mode and only offers to create a PR — there is no path to merge directly.

## Current Behavior

The mode detection in `main()` (git-shipyard.sh lines 1901–1911) always assigns `pr_only` when commits are ahead:

```bash
if has_uncommitted_changes; then
    mode="full"
elif has_commits_ahead; then
    mode="pr_only"          # <-- always pr_only
else
    mode="pr_management"
fi
```

This forces the user through PR creation even when they want to merge directly.

## Expected Behavior

Per the existing tests (Test 6–7, git-shipyard.bats lines 445–578) and AGENTS.md, the mode detection should check for open PRs:

```bash
elif has_commits_ahead; then
    if ! has_open_prs; then
        mode="squash_eligible"   # Offer PR or direct squash-merge
    else
        mode="pr_only"           # Open PR exists, push + create PR
    fi
```

When in `squash_eligible` mode, the user should be offered a choice:
1. Create a PR (current `pr_only` flow)
2. Squash-merge directly into the base branch

## Root Cause

Two pieces are missing from `git-shipyard.sh`:

1. **`has_open_prs()` function** — Defined in test mocks (bats lines 457–461) but never implemented in the script:
   ```bash
   has_open_prs() {
       local count
       count=$(gh pr list --head "${HEAD_BRANCH}" --state open --json number --jq 'length' 2>/dev/null || echo "0")
       [ "$count" -gt 0 ]
   }
   ```

2. **`squash_eligible` mode detection and workflow** — The mode detection in `main()` does not call `has_open_prs()` and has no `squash_eligible` branch. There is no workflow code for this mode.

## Affected Files

- `git-shipyard.sh` — missing `has_open_prs()` function and `squash_eligible` mode logic
- `test/git-shipyard.bats` — tests already exist for the expected behavior (Tests 6–7)

## Status

- Not Started
