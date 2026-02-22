# 🚢 Git Shipyard

**Ship your code in one command.** Git Shipyard is an interactive Bash utility that automates the entire Git workflow — staging, committing, pushing, creating GitHub pull requests, and managing PRs and issues — all in a single interactive session.

---

## ✨ Features

- 🚀 **One-command workflow** — Stage, commit, push, and create a PR in one go
- 🧠 **Smart mode detection** — Automatically adapts to your repository state
- 🔍 **PR details & comments** — Read PR metadata, comment threads, and code reviews
- ❌ **Close PRs** — Close pull requests without merging, with optional branch cleanup
- 🔀 **Squash-merge PRs** — Merge, clean up branches, and reset your dev environment
- 🎫 **Linked issue management** — Discover issues linked to a PR and close them
- 🔗 **Issue linking** — Link GitHub issues to new PRs (`Closes #N` for auto-close on merge)
- 📋 **Issue creation** — Create issues on the fly and link them to PRs
- 🔄 **Base branch sync** — Automatically merges latest base into head before PR creation
- 📝 **Multi-line commit messages** — Single-line input or open your preferred editor
- ✅ **Pre-flight checks** — Validates your entire environment before touching anything
- 🎨 **Beautiful CLI** — Color-coded output with progress indicators and spinners
- 🛡️ **Safe by default** — Confirmation prompts before every destructive operation
- ⚙️ **Configurable** — Override base/head branches and create draft PRs via flags
- 📄 **Single file** — No build system, no framework, just one Bash script

---

## 📋 Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| 🔧 **bash** 4.0+ | Shell runtime | Pre-installed on most systems |
| 🌿 **git** | Version control | [git-scm.com](https://git-scm.com/) |
| 🐙 **gh** | GitHub CLI for PRs & issues | [cli.github.com](https://cli.github.com/) |
| 📦 **jq** | JSON parsing | [jqlang.github.io/jq](https://jqlang.github.io/jq/) |

> 💡 Make sure you're authenticated: `gh auth login`

---

## 🛠️ Installation

### Quick Install

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/git_shipyard.git

# Make it executable
chmod +x git_shipyard/git-shipyard.sh

# Optional: Copy to PATH for global access
sudo cp git_shipyard/git-shipyard.sh /usr/local/bin/git-shipyard
```

### 🧲 As a Git Subcommand

Once `git-shipyard` is in your `$PATH`, invoke it like a native Git command:

```bash
git shipyard
```

---

## 🚀 Usage

### Basic

Run from within any Git repository:

```bash
./git-shipyard.sh
```

### Custom Branches

Override the default `dev → main` PR direction:

```bash
./git-shipyard.sh --base production --head feature-auth
```

### Draft PRs

```bash
./git-shipyard.sh --draft
```

### Help

```bash
./git-shipyard.sh --help
```

### ⚙️ CLI Options

| Flag | Description | Default |
|------|-------------|---------|
| `--base <branch>` | 🎯 Target (base) branch for the PR | `main` |
| `--head <branch>` | 🚀 Source (head) branch for the PR | `dev` |
| `--draft` | 📝 Create the PR as a draft | `false` |
| `--help`, `-h` | ❓ Print usage and exit | — |

---

## 🧭 How It Works

### 🔍 Pre-flight Checks

Before any operation, Git Shipyard validates your environment:

1. ✅ `git` is installed
2. ✅ `gh` CLI is installed
3. ✅ `jq` is installed
4. ✅ Inside a git repository
5. ✅ Not in detached HEAD state
6. ✅ Authenticated with GitHub
7. ✅ Remote `origin` is configured
8. ✅ No unresolved merge in progress

### 🔀 Execution Modes

Git Shipyard automatically detects your repository state and selects the right mode:

#### 📝 Full Mode

> **Triggered when:** Uncommitted changes exist (staged, unstaged, or untracked)

```
Stage All → Commit → Link to PR (opt.) → Push → Sync with Base → Link Issue (opt.) → Create PR
```

#### 📤 PR-Only Mode

> **Triggered when:** No uncommitted changes, but commits ahead of base

```
Push → Sync with Base → Link Issue (opt.) → Create PR
```

#### 🔀 PR Management Mode

> **Triggered when:** Clean working tree, no commits ahead of base

```
Select Open PR → Action Menu:
  1) View details & comments
  2) Close PR
  3) Squash-merge PR
  4) View/close linked issues
```

### 🔄 Base Branch Sync

Before creating a PR, Git Shipyard automatically:

1. 📥 Fetches the latest base branch from `origin`
2. 🔀 Merges it into your head branch (if needed)
3. 📤 Pushes the merge commit

If there are **merge conflicts**, the script lists the conflicting files and exits with clear resolution instructions. On your next run, it detects the in-progress merge and resumes automatically.

---

## 📖 Examples

### 🟢 Scenario 1: Full Workflow (uncommitted changes)

```
$ ./git-shipyard.sh

╔════════════════════════════════════════╗
║      Welcome to Git Shipyard           ║
╚════════════════════════════════════════╝

Create a GitHub Issue? (y/N): n

Running pre-flight checks...
  ✓ git found
  ✓ gh CLI found
  ✓ jq found
  ✓ Inside git repository
  ✓ On a valid branch
  ✓ GitHub authenticated
  ✓ Remote 'origin' configured
  ✓ Uncommitted changes detected
  ✓ Not on base branch

Enter your commit message:
  1) Single line (type here)
  2) Multi-line (open editor)

Choose (1/2): 1

> Add user authentication middleware

The following actions will be performed:
  1. Stage all changes (git add .)
  2. Commit with message: "Add user authentication middleware"
  3. Push to origin/dev
  4. Sync with main (merge any new changes)
  5. Create PR from dev → main

Proceed? (y/N): y

Staging changes...
  ✓ Changes staged
Committing...
  ✓ Changes committed
Pushing to origin/dev...
  ✓ Pushed to origin/dev
Syncing dev with main before PR...
  ✓ dev is up to date with main

Fetching open issues...
  ℹ No open issues found

Create a new issue to link to this PR? (y/N): n
  ℹ Skipping issue link

Creating pull request...
─────────────────────────────────────────
https://github.com/user/repo/pull/7
─────────────────────────────────────────

╔════════════════════════════════════════╗
║     ✓ All actions completed!           ║
╚════════════════════════════════════════╝

Summary:
  • Changes staged and committed
  • Pushed to origin/dev
  • Synced dev with main (already up to date)
  • Pull request created (dev → main)

Goodbye!
```

### 🟡 Scenario 2: PR-Only Mode (already committed)

```
$ ./git-shipyard.sh

  ✓ Commits ahead of main (already committed)

The following actions will be performed:
  1. Push to origin/dev (if needed)
  2. Sync with main (merge any new changes)
  3. Create PR from dev → main

Proceed? (y/N): y
```

### 🔵 Scenario 3: PR Management (action menu)

```
$ ./git-shipyard.sh

  ✓ Clean working tree — entering PR Management Mode

Fetching open pull requests...

Select a pull request:

   1) #42   Add user authentication
   2) #38   Fix database connection pooling

   x) Exit

Select PR [1-2/x]: 1

PR #42: Add user authentication

What would you like to do?

  1) View details & comments
  2) Close PR
  3) Squash-merge PR
  4) View/close linked issues
  x) Back

Choose action [1-4/x]:
```

### 🔍 Scenario 4: Viewing PR Details & Comments

```
Choose action [1-4/x]: 1

Fetching PR #42 details...
─────────────────────────────────────────

  Title:    Add user authentication
  State:    OPEN
  Author:   octocat
  Created:  2025-01-15
  Branch:   feature-auth → main
  Changes:  +142 -38 (7 files)
  Labels:   enhancement, security

  Description:
    Implements JWT-based authentication middleware
    with refresh token rotation.

─────────────────────────────────────────

Fetching comments...
  2 comment(s)

  alice (2025-01-16):
    Looks great! One small nit on the token expiry logic.

  bob (2025-01-17):
    LGTM, approved.

Reviews:

  alice — COMMENTED (2025-01-16)
    Check the edge case for expired refresh tokens.

  bob — APPROVED (2025-01-17)

─────────────────────────────────────────
```

### 🎫 Scenario 5: Viewing & Closing Linked Issues

```
Choose action [1-4/x]: 4

Fetching linked issues for PR #42...
  ✓ Found 2 linked issue(s)

Linked issues:

   1) #15   [OPEN]   Auth token expiration bug
   2) #12   [CLOSED] Add rate limiting

Close an issue?

  15) #15   Auth token expiration bug

   a) Close all open issues
   0) Skip

Enter issue # to close, 'a' for all, or 0 to skip: 15

Closing issue #15...
  ✓ Issue #15 closed: Auth token expiration bug
```

### ❌ Scenario 6: Closing a PR

```
Choose action [1-4/x]: 2

Close PR #42: Add user authentication?

  ⚠  This will close the PR without merging.

Also delete the remote branch? (y/N): y

Proceed with closing? (y/N): y

Closing PR #42...
  ✓ PR #42 closed
  ✓ Remote branch deleted

Delete local branch 'feature-auth'? (y/N): y
  ✓ Local branch 'feature-auth' deleted

╔════════════════════════════════════════╗
║     ✓ PR closed!                       ║
╚════════════════════════════════════════╝

Summary:
  • PR #42 closed: Add user authentication
  • Remote branch deleted
```

### 🟣 Scenario 7: Custom branches with draft PR

```bash
./git-shipyard.sh --base production --head hotfix-auth --draft

# Creates a draft PR from hotfix-auth → production
```

---

## 🔗 Linking Features

### 📌 Link Commits to Existing PRs

After committing in Full Mode, you're prompted to link the commit to an existing open PR. This amends the commit message with `Part of #N`:

```
Link this commit to an existing PR?

   1) #42   Add user authentication
   2) #38   Fix database pooling
   0) None (skip linking)

Select PR [0-2]: 1
  ✓ Commit linked to PR #42: Add user authentication
```

### 🎫 Link Issues to New PRs

Before PR creation, Git Shipyard fetches open issues and lets you select one. The PR body will include `Closes #N` for automatic closure on merge:

```
Fetching open issues...

Link an issue to this PR?

   1) #15   Auth token expiration bug
   2) #12   Add rate limiting
   0) None (skip linking)

Select issue [0-2]: 1
  ✓ Will link issue #15: Auth token expiration bug
```

When **no open issues exist**, you're offered to create one on the spot:

```
Fetching open issues...
  ℹ No open issues found

Create a new issue to link to this PR? (y/N): y

Enter issue title:
> Fix token refresh edge case

Enter issue body:
  1) Single line (type here)
  2) Multi-line (open editor)

Choose (1/2): 1

> Refresh tokens fail silently when expired during rotation

Creating GitHub issue...
  ✓ Issue #16 created: Fix token refresh edge case
  ✓ Will link issue #16 to this PR
```

The newly created issue is automatically linked to the PR with `Closes #16` in the body.

### 🎫 View & Close Linked Issues

In PR Management Mode, option **4** parses the PR body for linked issues using GitHub's closing keywords:

- `Closes #N`
- `Fixes #N`
- `Resolves #N`
- `Part of #N`

Each linked issue is displayed with its current state (OPEN/CLOSED), and you can close individual issues or all open issues at once.

### 📋 Standalone Issue Creation

At startup, Git Shipyard offers to create a standalone GitHub issue before any git operations run. This collects a title, overview (single-line or editor), and type label:

`enhancement` · `bug` · `feature` · `docs` · `refactor`

> 💡 **Tip:** Place a template at `~/.config/issue-template.md` to pre-populate the issue body in your editor.

---

## ⚙️ Configuration

### 🌿 Default Branches

Edit lines 10–11 in `git-shipyard.sh` to change the permanent defaults:

```bash
BASE_BRANCH="main"    # Target branch for PRs
HEAD_BRANCH="dev"     # Source branch for PRs
```

Or override per invocation with `--base` and `--head` flags.

### 🖊️ Editor Preference

For multi-line commit messages and issue bodies, Git Shipyard checks (in order):

1. `git config core.editor`
2. `$VISUAL`
3. `$EDITOR`
4. `nano` → `vim` → `vi` (fallback chain)

---

## 🧪 Testing

Tests use [BATS](https://github.com/bats-core/bats-core) (Bash Automated Testing System) with isolated temporary git repositories per test case.

```bash
# Run all tests
bats test/git-shipyard.bats

# Run a specific test by name
bats test/git-shipyard.bats --filter "test name pattern"
```

### Test Coverage

The test suite covers:

- **Argument parsing** — `--base`, `--head`, `--draft`, `--help`, missing values, unknown flags
- **Mode detection** — Full, PR-only, and PR management mode triggers
- **PR Management** — Action menu validation, PR selection, exit handling
- **View PR details** — Metadata display, comment rendering, review state color-coding
- **Close PR** — Cancellation, success/failure, branch deletion, summary
- **Squash-merge PR** — Confirmation, conflict detection, branch cleanup, dev environment reset
- **Linked issues** — Keyword parsing (case-insensitive), deduplication, state display, close all/single/skip
- **Issue linking** — Selection, creation when none exist, empty title handling
- **Sync** — Up-to-date detection, clean merge, fetch failure, conflict listing with instructions
- **Merge recovery** — In-progress merge detection, conflict file listing
- **Issue creation** — Title/body collection, template loading, `gh` failure handling

### 🔍 Linting

```bash
shellcheck git-shipyard.sh
```

---

## 🏗️ Project Structure

```
git_shipyard/
├── git-shipyard.sh          # The entire application (single file)
├── test/
│   └── git-shipyard.bats    # BATS test suite (133 tests)
├── CLAUDE.md                 # Claude Code guidance
├── README.md                 # You are here
└── ...
```

### 🧬 Function Reference

| Function | Purpose |
|----------|---------|
| `main()` | Entry point — pre-flight checks, mode detection, workflow dispatch |
| `get_commit_message()` | Collect commit message (single-line or editor) |
| `link_to_pr()` | Amend commit with `Part of #N` to link to existing PR |
| `select_issue()` | Pre-PR issue selection; creates issue when none exist |
| `_create_issue_for_pr()` | Internal helper to create an issue and set it for PR linking |
| `sync_with_base()` | Fetch + merge base branch into head before PR creation |
| `check_merge_in_progress()` | Detect and resume in-progress merges from prior sync |
| `pr_management_mode()` | PR selection → action menu dispatch |
| `view_pr_details()` | Display PR metadata, comments, and reviews |
| `close_pr()` | Close PR without merging, optional branch cleanup |
| `squash_merge_pr()` | Squash-merge via GitHub API, cleanup, reset dev environment |
| `view_linked_issues()` | Parse PR body for issue refs, display state, offer to close |
| `reset_dev_environment()` | Pull latest base, recreate fresh head branch |
| `prompt_issue_creation()` | Standalone issue creation at startup |

### 🧬 Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| 📄 **Single-file design** | Zero build system — just copy one script and go |
| 🛡️ **Source guard pattern** | BATS tests source functions without executing `main()` |
| 🔍 **Auto-detection** | Repository state determines the workflow, not user flags |
| 🔄 **Action menu loops** | View and linked-issues return to menu; close and merge exit |
| ⚓ **GitHub-only** | Hardcoded to `gh` CLI for simplicity and reliability |
| 🎯 **Stages everything** | Uses `git add .` — simple, predictable behavior |
| 🌐 **`origin` remote** | Default remote; keeps the script focused |
| 🧹 **Reset after merge only** | `reset_dev_environment()` runs inside `squash_merge_pr()`, not before the menu |

---

## ⚠️ Limitations

| Limitation | Details |
|------------|---------|
| 🐙 **GitHub only** | Relies on the `gh` CLI; no GitLab / Bitbucket support |
| 🌐 **`origin` remote** | Hardcoded remote name; not currently configurable |
| 📂 **Stages all changes** | `git add .` with no selective / interactive staging |
| 🔀 **Squash-merge only** | PR Management uses squash-merge; no regular merge or rebase option |
| 🎫 **Keyword-based issue detection** | Linked issues are parsed from PR body text, not GitHub's API linking |

---

## 🔧 Troubleshooting

### ❌ "Not authenticated with GitHub"

```bash
gh auth login
```

### ❌ "No 'origin' remote found"

```bash
git remote add origin https://github.com/username/repo.git
```

### ❌ "PR already exists for this branch"

No action needed — Git Shipyard automatically opens the existing PR in your browser.

### ❌ "Merge conflicts must be resolved"

1. Resolve the conflicts in the listed files
2. Stage them: `git add <resolved-file>`
3. Re-run `./git-shipyard.sh` — it detects the in-progress merge and resumes automatically

### ❌ "Cannot run on base branch"

Switch to a feature branch first:

```bash
git checkout -b my-feature
```

### ❌ "No linked issues found in PR body"

Issues are detected from the PR description using closing keywords. Add one of these to your PR body:

- `Closes #N`
- `Fixes #N`
- `Resolves #N`
- `Part of #N`

---

## 🤝 Contributing

Contributions are welcome! This is a single-file utility, so modifications are straightforward:

1. 🍴 Fork the repository
2. 🔧 Make your changes to `git-shipyard.sh`
3. 🧪 Run the test suite: `bats test/git-shipyard.bats`
4. 🔍 Lint with: `shellcheck git-shipyard.sh`
5. 📤 Submit a pull request

When adding new workflow steps, follow the existing pattern:

```bash
echo -e "${BLUE}Action description...${NC}"
if ! your_command; then
    error_exit "Failure message."
fi
echo -e "  ${GREEN}✓${NC} Success message"
```

---

## 📄 License

MIT License — feel free to use and modify as needed.

---

<p align="center">
  🚢 <strong>Built to ship code faster.</strong>
</p>