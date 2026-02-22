# 🚢 Git Shipyard

**Ship your code in one command.** Git Shipyard is an interactive Bash utility that automates the entire Git workflow — staging, committing, pushing, and creating GitHub pull requests — in a single interactive session.

![git-shipyard screenshot](screenshot.png)

---

## ✨ Features

- 🚀 **One-command workflow** — Stage, commit, push, and create a PR in one go
- 🧠 **Smart mode detection** — Automatically adapts to your repository state:
  - 📝 **Full Mode** — uncommitted changes → stage → commit → push → PR
  - 📤 **PR-Only Mode** — already committed → push → PR
  - 🔀 **PR Management Mode** — clean tree → squash-merge open PRs
- 🔗 **PR linking** — Link commits to existing open PRs (`Part of #N`)
- 🎫 **Issue linking** — Link GitHub issues to new PRs (`Closes #N` for auto-close on merge)
- 📋 **Issue creation** — Create GitHub issues before or after the workflow, with optional PR linking
- 🔄 **Base branch sync** — Automatically merges latest base into head before PR creation
- 📝 **Multi-line commit messages** — Single-line input or open your preferred editor
- ✅ **Pre-flight checks** — Validates your entire environment before touching anything
- 🎨 **Beautiful CLI** — Color-coded output with progress indicators and spinners
- 🛡️ **Safe by default** — Confirmation prompts before every destructive operation
- 🧹 **Branch cleanup** — Automatic branch deletion after squash-merge
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
Stage All → Commit → Link to PR (opt.) → Push → Sync with Base → Link Issue (opt.) → Create PR → Create Issue (opt.)
```

#### 📤 PR-Only Mode

> **Triggered when:** No uncommitted changes, but commits ahead of base

```
Push → Sync with Base → Link Issue (opt.) → Create PR → Create Issue (opt.)
```

#### 🔀 PR Management Mode

> **Triggered when:** Clean working tree, no commits ahead of base

```
Reset Dev Environment → Select Open PR → Squash-Merge → Cleanup Branches
```

### 🔄 Base Branch Sync

Before creating a PR, Git Shipyard automatically:

1. 📥 Fetches the latest base branch from `origin`
2. 🔀 Merges it into your head branch (if needed)
3. 📤 Pushes the merge commit

If there are **merge conflicts**, the script lists the conflicting files and exits with clear resolution instructions. On your next run, it detects the in-progress merge and resumes automatically ✨

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

Preparing to ship...
  ✓ Ready

Staging changes...
  ✓ Changes staged
Committing...
  ✓ Changes committed
Pushing to origin/dev...
  ✓ Pushed to origin/dev
Syncing dev with main before PR...
  ✓ dev is up to date with main
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

### 🔵 Scenario 3: PR Management (squash-merge)

```
$ ./git-shipyard.sh

  ✓ Clean working tree — entering PR Management Mode

Resetting local dev environment...
  ✓ Switched to main
  ✓ main is up to date
  ✓ Fresh dev created from main

Fetching open pull requests...

Select a pull request to squash-merge:

   1) #42   Add user authentication
   2) #38   Fix database connection pooling

   x) Exit

Select PR [1-2/x]: 1

Proceed? (y/N): y

  ✓ PR #42 squash-merged and remote branch deleted
  ✓ Switched to main and pulled latest
  ✓ Local branch 'dev' deleted
```

### 🟣 Scenario 4: Custom branches with draft PR

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

Before PR creation, you can select an open GitHub issue. The PR body will include `Closes #N` for automatic closure on merge:

```
Link an issue to this PR?

   1) #15   Auth token expiration bug
   2) #12   Add rate limiting

   0) None (skip linking)

Select issue [0-2]: 1
  ✓ Will link issue #15: Auth token expiration bug
```

### 📋 Create Issues On-the-Fly

Git Shipyard offers issue creation at two points:

- 🏁 **Before the workflow** — Create a standalone issue and exit (no git operations run)
- 🏁 **After PR creation** — Create an issue and optionally link it to an existing open PR

Both flows collect a title, body (single-line or editor), and type label:

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

### 🔍 Linting

```bash
shellcheck git-shipyard.sh
```

---

## 🏗️ Project Structure

```
git_shipyard/
├── git-shipyard.sh          # 🚢 The entire application (single file)
├── test/
│   ├── git-shipyard.bats    # 🧪 BATS test suite
│   └── test_helper.bash     # 🔧 Test utilities
├── process-flow.md           # 📊 Mermaid flowchart of all execution paths
├── screenshot.png            # 📸 Terminal screenshot
├── CLAUDE.md                 # 🤖 Claude Code guidance
├── AGENTS.md                 # 🤖 Warp AI guidance
└── README.md                 # 📖 You are here
```

### 🧬 Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| 📄 **Single-file design** | Zero build system — just copy one script and go |
| 🛡️ **Source guard pattern** | BATS tests source functions without executing `main()` |
| 🔍 **Auto-detection** | Repository state determines the workflow, not user flags |
| ⚓ **GitHub-only** | Hardcoded to `gh` CLI for simplicity and reliability |
| 🎯 **Stages everything** | Uses `git add .` — simple, predictable behavior |
| 🌐 **`origin` remote** | Default remote; keeps the script focused |

---

## ⚠️ Limitations

| Limitation | Details |
|------------|---------|
| 🐙 **GitHub only** | Relies on the `gh` CLI; no GitLab / Bitbucket support |
| 🌐 **`origin` remote** | Hardcoded remote name; not currently configurable |
| 📂 **Stages all changes** | `git add .` with no selective / interactive staging |
| 🔀 **Squash-merge** | Does not preserve individual commit history on the base branch |

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

No action needed — Git Shipyard automatically opens the existing PR in your browser 🌐

### ❌ "Merge conflicts must be resolved"

1. Resolve the conflicts in the listed files
2. Stage them: `git add <resolved-file>`
3. Re-run `./git-shipyard.sh` — it detects the in-progress merge and resumes ✨

### ❌ "Cannot run on base branch"

Switch to a feature branch first:

```bash
git checkout -b my-feature
```

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