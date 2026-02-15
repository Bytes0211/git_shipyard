# PRD: Squash-Merge Mode for Git Shipyard

**Date:** 2026-02-14
**Status:** Draft

---

## Overview and Objectives

Add a new interactive execution mode to Git Shipyard that allows users to squash-merge their feature branch directly into the base branch without creating a pull request. When the script detects specific conditions (no uncommitted changes, no open PRs, local branch ahead of remote), it prompts the user to choose between the existing PR workflow or a direct squash-merge.

This PRD also addresses existing bugs discovered during a code review that should be fixed as a prerequisite to the new feature work.

### Goals

- Fix existing bugs in `git-shipyard.sh` to establish a stable foundation
- Give users a fast path to merge small or personal changes without PR overhead
- Maintain a clean, linear commit history on the base branch
- Keep the user in control via interactive prompts at every decision point

---

## Target Audience

Developers already using Git Shipyard who work on solo projects or small teams where PRs are not always required, but a clean squash-merge workflow is desired.

---

## Pre-Requisite: Existing Bug Fixes

The following bugs were found during a code review of `git-shipyard.sh` (commit `ba428c0`) and should be fixed before implementing the squash-merge feature.

### Bug 1: Script deleted from repository

**Severity:** Critical
**Location:** Repository-wide

`git-shipyard.sh` was deleted in commit `35ed3c5` (which added the test file). Neither `main` nor `dev` currently contains the script. The last 3 BATS tests (lines 524-542) reference `$SCRIPT_DIR/git-shipyard.sh` and will fail.

**Fix:** Restore `git-shipyard.sh` to the repository on both branches.

### Bug 2: PR-only push silently swallows real errors

**Severity:** High
**Location:** `git-shipyard.sh` ~line 214

```bash
if ! git push -u origin "${HEAD_BRANCH}" 2>/dev/null; then
    echo -e "  ${YELLOW}ℹ${NC} Already up to date or pushed"
```

`git push` returns exit 0 when already up-to-date, so the `if !` branch only fires on genuine failures (auth, network, rejected push). But stderr is redirected to `/dev/null`, hiding the real error. The user sees "Already up to date or pushed" and the script proceeds to create a PR against commits that were never pushed.

**Fix:** Remove `2>/dev/null`. Treat non-zero exit as `error_exit` with the actual error message. The "already up to date" case (exit 0) needs no special handling — it flows into the `else` branch correctly.

### Bug 3: Missing value for `--base`/`--head` triggers cryptic error

**Severity:** Medium
**Location:** `git-shipyard.sh` argument parsing block

Running `./git-shipyard.sh --base` (no value after flag) causes:
1. `BASE_BRANCH=""` (set to empty `$2`)
2. `shift 2` fails because only 1 argument remains — returns non-zero
3. The global ERR trap fires with: "An unexpected error occurred"

The user gets no indication of what they did wrong.

**Fix:** Validate `$2` before assigning:
```bash
--base)
    [[ -n "${2:-}" ]] || { echo "Error: Missing value for --base"; exit 1; }
    BASE_BRANCH="$2"
    shift 2
    ;;
```

### Bug 4: Unused `pid` parameter in `spinner()`

**Severity:** Low
**Location:** `git-shipyard.sh` spinner function

```bash
spinner() {
    local pid=$1
```

The `pid` parameter is accepted but never used. The function is purely cosmetic (animates for a fixed duration). The parameter name is misleading.

**Fix:** Remove the `pid` parameter. Update the call from `spinner $$ 2` to `spinner 2`.

### Bug 5: `clear` wipes terminal without consent

**Severity:** Low
**Location:** `git-shipyard.sh` first line of `main()`

`clear` destroys the user's terminal history. Users may have important output on screen.

**Fix:** Remove the `clear` call, or replace with a few blank lines (`echo ""`).

### Bug 6: Test code duplicates script logic

**Severity:** Low (maintainability)
**Location:** `test/git-shipyard.bats`

All argument parsing tests (lines 93-225) duplicate the entire parser in heredocs. The `source_functions.sh` helper duplicates all utility functions. Changes to the script won't be reflected in tests, meaning regressions won't be caught.

**Fix:** Refactor tests to source the actual script's functions. Extract functions from `git-shipyard.sh` so they can be sourced independently from `main()`, or use a pattern like `[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"` to prevent `main()` from running when sourced.

---

## Core Features and Functionality

### Feature 1: Squash-Merge Mode Detection

**Trigger conditions (all must be true):**

| Condition | Detection Method |
|---|---|
| No uncommitted changes (staged, unstaged, or untracked) | Existing `has_uncommitted_changes()` returns false |
| No open PRs from the head branch | `gh pr list --head <head_branch> --state open` returns empty |
| Local branch is ahead of remote base branch | Existing `has_commits_ahead()` returns true |

**Acceptance criteria:**
- When all three conditions are met, the script enters a new interactive prompt instead of proceeding directly to the PR-only flow
- When any condition is not met, the script falls through to existing behavior (Full mode or PR-only mode)
- The open PR check must query GitHub via `gh pr list --head <HEAD_BRANCH> --state open --json number --jq 'length'` and verify the count is 0

### Feature 2: Interactive Mode Selection Prompt

When squash-merge conditions are met, prompt the user:

```
No uncommitted changes detected.
No open PRs for <HEAD_BRANCH>.
Your branch is ahead of <BASE_BRANCH>.

How would you like to proceed?
  1. Create a Pull Request (existing workflow)
  2. Squash-merge into <BASE_BRANCH>

Choose (1/2):
```

**Acceptance criteria:**
- Option 1 falls through to the existing PR-only flow unchanged
- Option 2 initiates the squash-merge workflow
- Invalid input re-prompts the user
- Follows existing color-coded output conventions (BLUE for prompts, GREEN for success, etc.)

### Feature 3: Squash-Merge Execution

When the user selects squash-merge, execute the following sequence:

**Step 1 — Prompt for commit message:**
```
Enter squash-merge commit message:
>
```
- Empty messages are rejected (consistent with existing commit message validation)
- The message will be used for the single squash commit on the base branch

**Step 2 — Show action plan and confirm:**
```
The following actions will be performed:
  1. Switch to <BASE_BRANCH>
  2. Squash-merge <HEAD_BRANCH> into <BASE_BRANCH>
  3. Commit with message: "<message>"
  4. Push <BASE_BRANCH> to origin

Proceed? (y/N):
```

**Step 3 — Execute:**

| Step | Command | On Failure |
|---|---|---|
| Switch to base branch | `git checkout <BASE_BRANCH>` | `error_exit` |
| Squash-merge | `git merge --squash <HEAD_BRANCH>` | Conflict handling (see Feature 4) |
| Commit | `git commit -m "<message>"` | `error_exit` |
| Push to remote | `git push origin <BASE_BRANCH>` | `error_exit` |

**Acceptance criteria:**
- Each step prints color-coded progress (consistent with existing output style)
- Success prints checkmark: `✓ Squash-merged <HEAD_BRANCH> into <BASE_BRANCH>`
- After push, proceed to Feature 5 (branch cleanup prompt)

### Feature 4: Conflict Handling with PR Fallback

If `git merge --squash` encounters merge conflicts:

**Critical implementation detail:** `git merge --squash` does **not** set `MERGE_HEAD`. Therefore, `git merge --abort` will not work. The abort command **must** be `git reset --merge`.

**Conflict flow:**

```
  ✗ Merge conflicts detected

Unable to squash-merge automatically.
Would you like to create a Pull Request instead? (y/N):
```

| User Choice | Action |
|---|---|
| Yes | `git reset --merge` → `git checkout <HEAD_BRANCH>` → execute existing PR-only flow |
| No | `git reset --merge` → `git checkout <HEAD_BRANCH>` → exit with message |

**Acceptance criteria:**
- Conflicts are detected by non-zero exit code from `git merge --squash`
- `git reset --merge` is used to abort (not `git merge --abort`)
- After abort, script switches back to the original head branch
- If user accepts PR fallback, the existing PR creation flow executes seamlessly
- If user declines, script exits cleanly with an informational message

### Feature 5: Feature Branch Cleanup Prompt

After a successful squash-merge and push:

```
Squash-merge complete. Delete feature branch '<HEAD_BRANCH>'? (y/N):
```

| User Choice | Action |
|---|---|
| Yes | `git branch -d <HEAD_BRANCH>` → `git push origin --delete <HEAD_BRANCH>` |
| No | `git checkout <HEAD_BRANCH>` (return user to feature branch) |

**Warning when keeping the branch:** If the user chooses to keep the feature branch, display:

```
  ⚠ Note: Squash-merge does not record merge history.
    Re-merging this branch later may cause duplicate conflicts.
```

**Acceptance criteria:**
- Local branch deleted with `git branch -d` (safe delete; fails if not fully merged — which it will be after squash)
- Remote branch deleted with `git push origin --delete`
- If user keeps the branch, script returns them to it and displays the warning
- Each delete operation has individual error handling with `error_exit`

---

## Technical Stack

No changes to the existing tech stack:
- Bash 4.0+
- git
- GitHub CLI (`gh`)

---

## Conceptual Data Model

No persistent data. All state is derived from git repository state at runtime:

| State | Source |
|---|---|
| Uncommitted changes | `git diff`, `git diff --cached`, `git ls-files --others --exclude-standard` |
| Open PRs | `gh pr list --head <branch> --state open` |
| Commits ahead | `git rev-list --count <BASE>..<HEAD>` |

---

## UI Design Principles

- Consistent with existing Git Shipyard CLI patterns:
  - Color-coded output (BLUE prompts, GREEN success, RED errors, YELLOW warnings)
  - Progress checkmarks (`✓`) and failure marks (`✗`)
  - Confirmation prompts default to No (`y/N`) for safety
  - Action plan displayed before execution

---

## Security Considerations

- No new credentials or secrets introduced
- Relies on existing `gh auth status` pre-flight check
- `git branch -d` (safe delete) used over `-D` (force delete) to prevent accidental data loss
- Confirmation prompt before every destructive action

---

## Development Phases

### Phase 0: Bug Fixes (Pre-Requisite)
1. Restore `git-shipyard.sh` to the repository
2. Fix PR-only push error handling — remove `2>/dev/null`, use `error_exit` on non-zero
3. Fix `--base`/`--head` missing value — validate `$2` before `shift 2`
4. Remove unused `pid` parameter from `spinner()`
5. Remove `clear` from `main()`
6. Add source guard to `git-shipyard.sh` (`[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"`) so tests can source functions directly
7. Refactor BATS tests to source the actual script instead of duplicating logic
8. Verify all 17 existing tests pass

### Phase 1: Squash-Merge Implementation
9. Add `has_open_prs()` function using `gh pr list`
10. Add squash-merge mode detection logic (integrating with existing mode detection)
11. Implement interactive mode selection prompt
12. Implement squash-merge execution flow
13. Implement conflict detection and `git reset --merge` abort path
14. Implement PR fallback flow on conflict
15. Implement branch cleanup prompt with warning

### Phase 2: Testing
16. Add BATS tests for `has_open_prs()` function
17. Add BATS tests for mode detection (squash-merge conditions met/not met)
18. Add BATS tests for conflict abort path
19. Add BATS tests for branch cleanup (keep and delete paths)
20. Manual integration testing of full squash-merge flow

---

## Potential Challenges and Solutions

| Challenge | Solution |
|---|---|
| `git merge --abort` doesn't work with `--squash` | Use `git reset --merge` which works without `MERGE_HEAD` |
| User keeps branch after squash, then tries to re-merge | Display warning about duplicate conflicts; recommend deleting the branch |
| `gh pr list` requires network access | Existing pre-flight checks already validate `gh auth status` and remote connectivity |
| User is left on wrong branch after conflict abort | Always `git checkout <HEAD_BRANCH>` after abort to restore original state |
| `git branch -d` may fail after squash-merge (git doesn't recognize squash as a real merge) | Use `git branch -D` only if `-d` fails and user confirms, or reset the feature branch to the base first |
| Refactoring script for source guard may break existing behavior | Test `main "$@"` is still called when script is executed directly; add integration test for this |
| `has_commits_ahead()` returns false if base branch doesn't exist locally | Add validation that `BASE_BRANCH` exists as a local ref or remote tracking ref before mode detection |

---

## Future Expansion Possibilities

- **Auto-generated commit messages**: Option to compile commit messages from the squashed commits (similar to `gh pr create --fill`)
- **`--squash` flag**: Non-interactive flag to skip the mode selection prompt and go directly to squash-merge
- **Branch protection awareness**: Check if base branch has protection rules that would block direct push, and skip squash-merge option if so
