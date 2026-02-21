# PRD: Git Shipyard v2 — Enhanced Workflow Automation

**Date:** 2026-02-21
**Project:** Git Shipyard
**Version:** 2.0

---

## 1. Overview and Objectives

Git Shipyard is a single-file Bash utility that automates the Git workflow: staging, committing, pushing, and creating GitHub pull requests in one interactive session.

**Version 2** extends the tool with five new capabilities:

1. **Auto-sync dev with main** before any work begins
2. **GitHub Issue creation** directly from the CLI
3. **PR management mode** to close, squash-merge, and clean up existing PRs
4. **Pre-PR conflict resolution** to ensure clean merges
5. **Post-PR squash-merge and branch cleanup** to maintain a clean repository

### Goals

- Eliminate manual branch synchronization steps
- Provide a complete issue-to-merge lifecycle without leaving the terminal
- Enforce a consistent squash-merge strategy across all PRs
- Keep the dev environment clean by automatically removing merged branches

---

## 2. Target Audience

- Solo developers and small teams using GitHub
- Developers who prefer terminal-based Git workflows over GitHub's web UI
- Users already running `git`, `gh` CLI, and `bash 4.0+`

---

## 3. Core Features and Functionality

### F1: Auto-Sync Dev with Main

**Description:** At the start of every run (after pre-flight checks), automatically pull the latest changes from `main` into `dev`. If uncommitted changes exist, stash them first and restore them after.

**Workflow:**
```
Pre-flight checks pass
  ├── Uncommitted changes detected?
  │   ├── YES: git stash → git pull origin main → git stash pop
  │   └── NO:  git pull origin main
  └── Display status feedback at each step
```

**Implementation Details:**
- Run immediately after pre-flight checks, before any user prompts
- Use `git stash` / `git stash pop` to preserve uncommitted work
- If `git stash pop` produces conflicts, notify the user and halt with instructions to resolve manually
- If `dev` is already up-to-date with `main`, display: `✓ Dev is up to date with main`

**Acceptance Criteria:**
- Uncommitted changes are preserved through the sync via stash/pop
- User sees color-coded status messages for each step (stashing, pulling, popping)
- If the pull introduces conflicts with stashed changes, the script halts with a clear error message and does not proceed
- If `dev` is already current with `main`, the sync is a no-op with feedback

---

### F2: GitHub Issue Creation

**Description:** After syncing, prompt the user to optionally create a GitHub Issue before proceeding to the commit/PR workflow. Uses the same single-line / multi-line (editor) input pattern as commit messages.

**Workflow:**
```
Sync complete
  └── "Create a GitHub Issue? (y/N)"
      ├── YES:
      │   ├── Prompt for issue title (single-line)
      │   ├── Prompt for issue body using:
      │   │   ├── 1) Single line (type here)
      │   │   └── 2) Multi-line (open editor)
      │   ├── Editor pre-populates with ~/.config/issue-template.md
      │   ├── Create issue via: gh issue create --title "..." --body "..."
      │   └── Display: ✓ Issue #N created: <title>
      └── NO: Continue to Detect Workflow Mode
```

**Implementation Details:**
- Reuse the existing `get_commit_message()` pattern for the input UX
- Load `~/.config/issue-template.md` as the editor template (pre-populate the temp file)
- If the template file doesn't exist, proceed with a blank template and display a warning
- Parse issue fields from the template (Overview, Labels, etc.) to populate `gh issue create` flags where applicable
- After issue creation, continue to the next step (Detect Workflow Mode)

**Acceptance Criteria:**
- User can skip issue creation entirely by choosing "N"
- Single-line and multi-line (editor) input both work for issue body
- The editor opens pre-populated with the issue template from `~/.config/issue-template.md`
- The created issue number and title are displayed on success
- Missing template file produces a warning but does not block execution

---

### F3: PR Management Mode (New Workflow Mode)

**Description:** When no uncommitted changes exist AND no commits are ahead of `main`, check for open GitHub PRs. If open PRs exist, display a numbered list and let the user select a PR to close, squash-merge, and clean up — or exit.

**Workflow:**
```
Detect Workflow Mode
  ├── Uncommitted changes? → Full Mode (existing)
  ├── Commits ahead? → PR-Only Mode (existing)
  └── Neither? → PR Management Mode (NEW)
      ├── Fetch open PRs: gh pr list --state open
      ├── Open PRs found?
      │   ├── YES: Display numbered list
      │   │   ├── User selects a PR number → Close, squash-merge, cleanup
      │   │   └── User enters "x" → Exit
      │   └── NO: Display "No open PRs" → Exit
      └── Selected PR actions:
          ├── gh pr merge <number> --squash --delete-branch
          ├── git branch -d <branch> (delete local)
          ├── git checkout main && git pull origin main
          └── Display: ✓ PR #N merged and cleaned up
```

**Implementation Details:**
- This replaces the current `error_exit "No changes to commit and no commits ahead of main."` behavior
- Use `gh pr list --state open --json number,title --limit 20` (same pattern as existing `link_to_pr()`)
- After squash-merge, switch to `main` and pull to ensure local `main` is up to date
- If the selected PR has merge conflicts, notify the user and do not force merge

**Acceptance Criteria:**
- When no changes and no commits ahead, the script checks for open PRs instead of erroring out
- Open PRs are displayed as a numbered list with PR number and title
- User can select a PR by number or enter "x" to exit
- Selected PR is squash-merged into main via `gh pr merge --squash`
- The head branch is deleted both locally and on GitHub
- Local `main` is updated after merge
- If no open PRs exist, the script exits with a friendly message

---

### F4: Pre-PR Conflict Resolution

**Description:** Right before creating a PR (in Full Mode and PR-Only Mode), pull `main` into `dev` to ensure no conflicts exist before the PR is opened.

**Workflow:**
```
Ready to create PR
  ├── git checkout dev (ensure on correct branch)
  ├── git pull origin main
  ├── Conflicts?
  │   ├── YES: Notify user, pause for manual resolution
  │   │   └── After resolution: git add . → git commit → continue
  │   └── NO: ✓ Dev is up to date with main
  └── Proceed to create PR
```

**Implementation Details:**
- Run after push but before `gh pr create`
- This is a second sync (F1 syncs at the start; F4 syncs right before PR creation) to catch any changes merged to `main` during the session
- If conflicts arise, display the conflicting files and instruct the user to resolve them
- After the user resolves conflicts, the script should detect the resolution and continue

**Acceptance Criteria:**
- `main` is pulled into `dev` immediately before PR creation
- If no conflicts, a success message is shown and PR creation proceeds
- If conflicts exist, the script displays conflicting files and halts with instructions
- The user can resolve conflicts and the workflow continues

**Technical Considerations:**
- Conflict detection: check the exit code of `git pull origin main`; a non-zero exit with merge conflicts should trigger the pause
- Consider using `git merge --no-commit origin/main` for more control, then `git commit` after user resolution

---

### F5: Post-PR Squash-Merge and Branch Cleanup

**Description:** After a PR is created (in Full Mode and PR-Only Mode), squash-merge it into `main` and delete the `dev` branch both locally and on GitHub.

**Workflow:**
```
PR created successfully
  ├── gh pr merge --squash --delete-branch
  ├── git checkout main
  ├── git pull origin main
  ├── git branch -d dev (delete local dev)
  └── Display summary:
      ├── ✓ PR #N squash-merged into main
      ├── ✓ Branch 'dev' deleted locally
      ├── ✓ Branch 'dev' deleted on GitHub
      └── ✓ Local main updated
```

**Implementation Details:**
- `gh pr merge --squash --delete-branch` handles the remote merge and remote branch deletion in one command
- After merge, switch to `main` and pull to keep local state in sync
- Delete the local `dev` branch with `git branch -d dev`
- If `dev` branch deletion fails (e.g., unmerged changes), use `git branch -D dev` as a fallback with a warning

**Acceptance Criteria:**
- PR is squash-merged into `main` (single commit on main)
- `dev` branch is deleted on GitHub
- `dev` branch is deleted locally
- Local `main` is updated to include the squash-merged commit
- User sees a clear summary of all cleanup actions performed

---

## 4. Technical Stack

| Component | Technology | Notes |
|-----------|-----------|-------|
| Language | Bash 4.0+ | Single-file script, no build system |
| Git CLI | `git` | Core version control operations |
| GitHub CLI | `gh` | PR creation, issue creation, PR merging, auth |
| JSON parsing | `jq` | Parsing `gh` CLI JSON output |
| Config | `~/.config/issue-template.md` | Issue template for F2 |

No new dependencies are introduced. All new features use `git` and `gh` CLI commands.

---

## 5. Revised Workflow Diagram

```
┌─────────────────────────┐
│   Pre-flight Checks     │
└──────────┬──────────────┘
           ▼
┌─────────────────────────┐
│  F1: Auto-Sync Dev      │
│  with Main              │
│  (stash if needed)      │
└──────────┬──────────────┘
           ▼
┌─────────────────────────┐
│  F2: Create GitHub      │
│  Issue? (y/N)           │
├──────────┬──────────────┤
│ YES: create issue       │
│ NO: continue            │
└──────────┬──────────────┘
           ▼
┌─────────────────────────┐
│  Detect Workflow Mode   │
├─────────┬───────┬───────┤
│ Full    │PR-Only│PR Mgmt│
│ Mode    │ Mode  │ Mode  │
└────┬────┴───┬───┴───┬───┘
     │        │       │
     ▼        ▼       ▼
  Stage &   Push   List open
  Commit   (if     PRs → user
    │      needed)  selects
    ▼        │       │
   Push      │       ▼
    │        │    Close PR,
    ▼        ▼    squash-merge,
┌─────────────┐   cleanup
│F4: Pre-PR   │     │
│Sync with    │     ▼
│Main         │   Done
└──────┬──────┘
       ▼
┌─────────────┐
│ Create PR   │
└──────┬──────┘
       ▼
┌─────────────┐
│F5: Squash-  │
│merge +      │
│cleanup      │
└──────┬──────┘
       ▼
     Done
```

---

## 6. CLI Interaction Patterns

### Color Coding (existing convention)
| Color | Usage |
|-------|-------|
| Blue | Action descriptions ("Syncing dev with main...") |
| Green | Success messages ("✓ Dev is up to date") |
| Yellow | Warnings and prompts |
| Red | Errors |
| Cyan | Options and selections |

### Feedback Pattern
Every automated action follows the existing convention:
```bash
echo -e "${BLUE}Action description...${NC}"
# perform action
echo -e "  ${GREEN}✓${NC} Success message"
```

### User Input Pattern
Reuse the existing single-line / multi-line editor pattern from `get_commit_message()` for issue creation (F2).

---

## 7. Security Considerations

- **Branch protection:** `gh pr merge --squash` will fail if branch protection rules prevent direct merges — the script should handle this gracefully with a clear error message
- **Stash conflicts:** Stash pop conflicts should halt execution rather than silently losing changes
- **Force operations:** No force pushes or hard resets are used; all operations are safe and reversible
- **Authentication:** Existing `check_gh_auth()` covers GitHub operations for both PRs and issues

---

## 8. Development Phases

### Phase 1: Auto-Sync (F1)
- Implement stash detection and sync logic
- Add status feedback messages
- Update tests for sync scenarios (clean dev, dirty dev, already up-to-date, conflict on stash pop)

### Phase 2: GitHub Issue Creation (F2)
- Add issue creation prompt after sync
- Reuse `get_commit_message()` input pattern
- Load and use `~/.config/issue-template.md`
- Add tests for issue creation flow (skip, single-line, multi-line, missing template)

### Phase 3: PR Management Mode (F3)
- Update `main()` workflow detection to add third mode
- Implement PR listing, selection, and squash-merge + cleanup
- Add tests for PR management (no PRs, select PR, exit, merge failure)

### Phase 4: Pre-PR Sync (F4)
- Add pre-PR sync step before `gh pr create`
- Handle conflict detection and user notification
- Add tests for pre-PR sync (clean merge, conflict)

### Phase 5: Post-PR Merge & Cleanup (F5)
- Add squash-merge and branch cleanup after PR creation
- Handle edge cases (merge failures, branch deletion failures)
- Add tests for post-merge cleanup
- End-to-end integration testing of the full revised workflow

---

## 9. Potential Challenges and Solutions

| Challenge | Solution |
|-----------|----------|
| Stash pop conflicts during F1 sync | Halt with clear error, leave stash intact so user can resolve manually (`git stash show`, `git stash pop`) |
| Merge conflicts during F4 pre-PR sync | Display conflicting files, pause for manual resolution, detect when user has resolved and continue |
| PR has merge conflicts in F3/F5 | Display error from `gh pr merge`, suggest user resolve conflicts on the branch first |
| `~/.config/issue-template.md` missing | Warn the user, proceed with blank template |
| Branch protection rules block squash-merge | Catch `gh pr merge` failure, display GitHub's error message, suggest user check repo settings |
| Local `dev` branch already deleted | Check if branch exists before attempting deletion, skip with info message if not found |
| User runs script after F5 cleanup (no dev branch) | Script is run from `main` after cleanup; `check_not_on_base_branch()` will prompt user to create a new feature branch |

---

## 10. Future Expansion Possibilities

- **Selective staging:** Allow users to choose which files to stage instead of `git add .`
- **Multiple remote support:** Support remotes other than `origin`
- **PR templates:** Support PR body templates similar to issue templates
- **Branch naming conventions:** Auto-generate branch names from issue numbers (e.g., `issue-42`)
- **Configuration file:** `~/.config/git-shipyard/config` for defaults (base branch, merge strategy, template paths)
- **Dry-run mode:** `--dry-run` flag to preview all actions without executing them
