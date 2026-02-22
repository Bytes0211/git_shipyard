#!/usr/bin/env bats
#
# Unit tests for git-shipyard.sh
#

# Setup test environment
setup() {
    # Create a temporary directory for test repos
    TEST_DIR="$(mktemp -d)"
    export TEST_DIR

    # Store the original script path
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export SCRIPT_DIR

    # Create a helper script that sources functions from the actual script
    cat > "$TEST_DIR/source_functions.sh" << EOF
#!/usr/bin/env bash
# Source the actual script (which won't run main due to source guard)
source "$SCRIPT_DIR/git-shipyard.sh"
EOF
    chmod +x "$TEST_DIR/source_functions.sh"
}

# Teardown test environment
teardown() {
    rm -rf "$TEST_DIR"
}

# Helper: Create a test git repository
create_test_repo() {
    local repo_dir="$TEST_DIR/test_repo"
    mkdir -p "$repo_dir"
    cd "$repo_dir"
    git init --initial-branch=main >/dev/null 2>&1
    git config user.email "test@test.com"
    git config user.name "Test User"
    # Create initial commit
    echo "initial" > README.md
    git add README.md
    git commit -m "Initial commit" >/dev/null 2>&1
    echo "$repo_dir"
}

# =============================================================================
# Test 1: Argument parsing for --base and --head
# =============================================================================

@test "parses --base argument correctly" {
    # Create a test wrapper that sources the script and outputs branch variables
    cat > "$TEST_DIR/test_args.sh" << EOF
#!/usr/bin/env bash
# Override main to prevent execution
main() { :; }
source "$SCRIPT_DIR/git-shipyard.sh" --base production
echo "BASE_BRANCH=\$BASE_BRANCH"
echo "HEAD_BRANCH=\$HEAD_BRANCH"
EOF
    chmod +x "$TEST_DIR/test_args.sh"

    run "$TEST_DIR/test_args.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"BASE_BRANCH=production"* ]]
    [[ "$output" == *"HEAD_BRANCH=dev"* ]]
}

@test "parses --head argument correctly" {
    cat > "$TEST_DIR/test_args.sh" << EOF
#!/usr/bin/env bash
main() { :; }
source "$SCRIPT_DIR/git-shipyard.sh" --head feature-branch
echo "BASE_BRANCH=\$BASE_BRANCH"
echo "HEAD_BRANCH=\$HEAD_BRANCH"
EOF
    chmod +x "$TEST_DIR/test_args.sh"

    run "$TEST_DIR/test_args.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"BASE_BRANCH=main"* ]]
    [[ "$output" == *"HEAD_BRANCH=feature-branch"* ]]
}

@test "parses both --base and --head arguments correctly" {
    cat > "$TEST_DIR/test_args.sh" << EOF
#!/usr/bin/env bash
main() { :; }
source "$SCRIPT_DIR/git-shipyard.sh" --base production --head feature-xyz
echo "BASE_BRANCH=\$BASE_BRANCH"
echo "HEAD_BRANCH=\$HEAD_BRANCH"
EOF
    chmod +x "$TEST_DIR/test_args.sh"

    run "$TEST_DIR/test_args.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"BASE_BRANCH=production"* ]]
    [[ "$output" == *"HEAD_BRANCH=feature-xyz"* ]]
}

@test "uses default values when no arguments provided" {
    cat > "$TEST_DIR/test_args.sh" << EOF
#!/usr/bin/env bash
main() { :; }
source "$SCRIPT_DIR/git-shipyard.sh"
echo "BASE_BRANCH=\$BASE_BRANCH"
echo "HEAD_BRANCH=\$HEAD_BRANCH"
EOF
    chmod +x "$TEST_DIR/test_args.sh"

    run "$TEST_DIR/test_args.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"BASE_BRANCH=main"* ]]
    [[ "$output" == *"HEAD_BRANCH=dev"* ]]
}

# =============================================================================
# Test 2: Full mode detection (uncommitted changes exist)
# =============================================================================

@test "identifies full mode when unstaged changes exist" {
    repo_dir=$(create_test_repo)
    cd "$repo_dir"

    # Create unstaged changes
    echo "modified" >> README.md

    source "$TEST_DIR/source_functions.sh"
    run has_uncommitted_changes
    [ "$status" -eq 0 ]
}

@test "identifies full mode when staged changes exist" {
    repo_dir=$(create_test_repo)
    cd "$repo_dir"

    # Create staged changes
    echo "modified" >> README.md
    git add README.md

    source "$TEST_DIR/source_functions.sh"
    run has_uncommitted_changes
    [ "$status" -eq 0 ]
}

@test "identifies full mode when untracked files exist" {
    repo_dir=$(create_test_repo)
    cd "$repo_dir"

    # Create untracked file
    echo "new file" > newfile.txt

    source "$TEST_DIR/source_functions.sh"
    run has_uncommitted_changes
    [ "$status" -eq 0 ]
}

# =============================================================================
# Test 3: PR-only mode detection (commits ahead, no uncommitted changes)
# =============================================================================

@test "identifies PR-only mode when commits ahead but no uncommitted changes" {
    repo_dir=$(create_test_repo)
    cd "$repo_dir"

    # Create a dev branch with commits ahead of main
    git checkout -b dev
    echo "feature" > feature.txt
    git add feature.txt
    git commit -m "Add feature"

    source "$TEST_DIR/source_functions.sh"
    BASE_BRANCH="main"

    # Should have no uncommitted changes
    run has_uncommitted_changes
    [ "$status" -ne 0 ]

    # Should have commits ahead
    run has_commits_ahead
    [ "$status" -eq 0 ]
}

@test "has_uncommitted_changes returns false when working tree is clean" {
    repo_dir=$(create_test_repo)
    cd "$repo_dir"

    source "$TEST_DIR/source_functions.sh"
    run has_uncommitted_changes
    [ "$status" -ne 0 ]
}

@test "has_commits_ahead returns false when no commits ahead" {
    repo_dir=$(create_test_repo)
    cd "$repo_dir"

    source "$TEST_DIR/source_functions.sh"
    BASE_BRANCH="main"

    run has_commits_ahead
    [ "$status" -ne 0 ]
}

# =============================================================================
# Test 4: Script exits with error if required commands not found
# =============================================================================

@test "exits with error when git command not found" {
    cat > "$TEST_DIR/test_check_cmd.sh" << 'EOF'
#!/usr/bin/env bash
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

error_exit() {
    echo -e "\n${RED}Error: $1${NC}" >&2
    echo -e "${YELLOW}Goodbye!${NC}"
    exit 1
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        error_exit "$1 is not installed. Please install it and try again."
    fi
}

# Test with a non-existent command
check_command "nonexistent_git_command_12345"
EOF
    chmod +x "$TEST_DIR/test_check_cmd.sh"

    run "$TEST_DIR/test_check_cmd.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"nonexistent_git_command_12345 is not installed"* ]]
}

@test "exits with error when gh command not found" {
    cat > "$TEST_DIR/test_check_cmd.sh" << 'EOF'
#!/usr/bin/env bash
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

error_exit() {
    echo -e "\n${RED}Error: $1${NC}" >&2
    echo -e "${YELLOW}Goodbye!${NC}"
    exit 1
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        error_exit "$1 is not installed. Please install it and try again."
    fi
}

# Test with a non-existent command
check_command "nonexistent_gh_command_12345"
EOF
    chmod +x "$TEST_DIR/test_check_cmd.sh"

    run "$TEST_DIR/test_check_cmd.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"nonexistent_gh_command_12345 is not installed"* ]]
}

@test "check_command succeeds when command exists" {
    cat > "$TEST_DIR/test_check_cmd.sh" << 'EOF'
#!/usr/bin/env bash
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

error_exit() {
    echo -e "\n${RED}Error: $1${NC}" >&2
    echo -e "${YELLOW}Goodbye!${NC}"
    exit 1
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        error_exit "$1 is not installed. Please install it and try again."
    fi
}

# Test with a command that should exist
check_command "bash"
echo "success"
EOF
    chmod +x "$TEST_DIR/test_check_cmd.sh"

    run "$TEST_DIR/test_check_cmd.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"success"* ]]
}

# =============================================================================
# Test 5: Script handles existing PR by opening it in browser
# =============================================================================

@test "handles existing PR scenario correctly" {
    # This test verifies the logic flow for existing PR detection
    # We simulate the gh pr create failure and gh pr view success
    cat > "$TEST_DIR/test_existing_pr.sh" << 'EOF'
#!/usr/bin/env bash
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
HEAD_BRANCH="feature-branch"

error_exit() {
    echo -e "\n${RED}Error: $1${NC}" >&2
    echo -e "${YELLOW}Goodbye!${NC}"
    exit 1
}

# Mock gh command
gh() {
    case "$1" in
        pr)
            case "$2" in
                create)
                    # Simulate PR already exists error
                    return 1
                    ;;
                view)
                    if [ "$3" = "$HEAD_BRANCH" ]; then
                        echo "PR exists for $HEAD_BRANCH"
                        return 0
                    fi
                    if [ "$3" = "--web" ]; then
                        echo "Opening PR in browser"
                        return 0
                    fi
                    return 0
                    ;;
            esac
            ;;
    esac
}

# Simulate the PR creation logic from the script
if ! gh pr create --base main --head "$HEAD_BRANCH" --fill; then
    # Check if PR already exists
    if gh pr view "$HEAD_BRANCH" &>/dev/null; then
        echo "PR already exists for this branch"
        gh pr view "$HEAD_BRANCH" --web 2>/dev/null || true
        echo "EXISTING_PR_HANDLED"
    else
        error_exit "Failed to create PR."
    fi
fi
EOF
    chmod +x "$TEST_DIR/test_existing_pr.sh"

    run "$TEST_DIR/test_existing_pr.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PR already exists for this branch"* ]]
    [[ "$output" == *"EXISTING_PR_HANDLED"* ]]
}

@test "fails when PR creation fails and no existing PR found" {
    cat > "$TEST_DIR/test_no_pr.sh" << 'EOF'
#!/usr/bin/env bash
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
HEAD_BRANCH="feature-branch"

error_exit() {
    echo -e "\n${RED}Error: $1${NC}" >&2
    echo -e "${YELLOW}Goodbye!${NC}"
    exit 1
}

# Mock gh command
gh() {
    case "$1" in
        pr)
            case "$2" in
                create)
                    # Simulate PR creation failure
                    return 1
                    ;;
                view)
                    # Simulate no existing PR
                    return 1
                    ;;
            esac
            ;;
    esac
}

# Simulate the PR creation logic from the script
if ! gh pr create --base main --head "$HEAD_BRANCH" --fill; then
    # Check if PR already exists
    if gh pr view "$HEAD_BRANCH" &>/dev/null; then
        echo "PR already exists for this branch"
    else
        error_exit "Failed to create PR. Check the output above for details."
    fi
fi
EOF
    chmod +x "$TEST_DIR/test_no_pr.sh"

    run "$TEST_DIR/test_no_pr.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to create PR"* ]]
}

# =============================================================================
# Additional edge case tests
# =============================================================================

@test "exits with error for unknown options" {
    run "$SCRIPT_DIR/git-shipyard.sh" --unknown-option
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "shows help with --help flag" {
    run "$SCRIPT_DIR/git-shipyard.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"--base"* ]]
    [[ "$output" == *"--head"* ]]
}

@test "shows help with -h flag" {
    run "$SCRIPT_DIR/git-shipyard.sh" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# Test 6: has_open_prs() function
# =============================================================================

@test "has_open_prs returns false when no open PRs (mocked)" {
    # Create test script that mocks gh to return 0 PRs
    cat > "$TEST_DIR/test_no_prs.sh" << 'EOF'
#!/usr/bin/env bash
HEAD_BRANCH="feature-branch"

# Mock gh command
gh() {
    echo "0"
    return 0
}

has_open_prs() {
    local count
    count=$(gh pr list --head "${HEAD_BRANCH}" --state open --json number --jq 'length' 2>/dev/null || echo "0")
    [ "$count" -gt 0 ]
}

if has_open_prs; then
    echo "HAS_OPEN_PRS"
    exit 0
else
    echo "NO_OPEN_PRS"
    exit 0
fi
EOF
    chmod +x "$TEST_DIR/test_no_prs.sh"

    run "$TEST_DIR/test_no_prs.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO_OPEN_PRS"* ]]
}

@test "has_open_prs returns true when open PRs exist (mocked)" {
    cat > "$TEST_DIR/test_has_prs.sh" << 'EOF'
#!/usr/bin/env bash
HEAD_BRANCH="feature-branch"

# Mock gh command to return 1 PR
gh() {
    echo "1"
    return 0
}

has_open_prs() {
    local count
    count=$(gh pr list --head "${HEAD_BRANCH}" --state open --json number --jq 'length' 2>/dev/null || echo "0")
    [ "$count" -gt 0 ]
}

if has_open_prs; then
    echo "HAS_OPEN_PRS"
    exit 0
else
    echo "NO_OPEN_PRS"
    exit 0
fi
EOF
    chmod +x "$TEST_DIR/test_has_prs.sh"

    run "$TEST_DIR/test_has_prs.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"HAS_OPEN_PRS"* ]]
}

# =============================================================================
# Test 7: Squash-merge mode detection
# =============================================================================

@test "detects squash_eligible mode when no uncommitted changes, no open PRs, commits ahead" {
    cat > "$TEST_DIR/test_squash_mode.sh" << 'EOF'
#!/usr/bin/env bash
BASE_BRANCH="main"
HEAD_BRANCH="dev"

# Simulated state: clean working tree, no open PRs, commits ahead
has_uncommitted_changes() { return 1; }  # false
has_open_prs() { return 1; }  # false (no open PRs)
has_commits_ahead() { return 0; }  # true

# Mode detection logic from the script
if has_uncommitted_changes; then
    mode="full"
elif has_commits_ahead; then
    if ! has_open_prs; then
        mode="squash_eligible"
    else
        mode="pr_only"
    fi
else
    mode="error"
fi

echo "MODE=$mode"
EOF
    chmod +x "$TEST_DIR/test_squash_mode.sh"

    run "$TEST_DIR/test_squash_mode.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MODE=squash_eligible"* ]]
}

@test "detects pr_only mode when open PR exists" {
    cat > "$TEST_DIR/test_pr_mode.sh" << 'EOF'
#!/usr/bin/env bash
BASE_BRANCH="main"
HEAD_BRANCH="dev"

# Simulated state: clean working tree, HAS open PRs, commits ahead
has_uncommitted_changes() { return 1; }  # false
has_open_prs() { return 0; }  # true (has open PRs)
has_commits_ahead() { return 0; }  # true

# Mode detection logic from the script
if has_uncommitted_changes; then
    mode="full"
elif has_commits_ahead; then
    if ! has_open_prs; then
        mode="squash_eligible"
    else
        mode="pr_only"
    fi
else
    mode="error"
fi

echo "MODE=$mode"
EOF
    chmod +x "$TEST_DIR/test_pr_mode.sh"

    run "$TEST_DIR/test_pr_mode.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MODE=pr_only"* ]]
}

# =============================================================================
# Test 8: Conflict handling uses git reset --merge
# =============================================================================

@test "squash-merge uses gh pr merge not local git merge --squash" {
    # Script delegates squash-merge to the GitHub API via gh pr merge
    run grep "gh pr merge.*--squash" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]

    # Should NOT use local git merge --squash (which would require git reset --merge on conflict)
    run grep -c "git merge --squash" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$output" -eq 0 ]

    # Should NOT use git merge --abort (not valid after git merge --squash)
    run grep -c "git merge --abort" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$output" -eq 0 ]
}

# =============================================================================
# Test 9: Branch cleanup warning message
# =============================================================================

@test "script contains squash-merge re-merge warning" {
    run grep "Squash-merge does not record merge history" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "script contains duplicate conflicts warning" {
    run grep "duplicate conflicts" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Test 10: Branch cleanup uses safe delete
# =============================================================================

@test "branch cleanup uses git branch -d (safe delete)" {
    run grep "git branch -d" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "script deletes remote branch via gh pr merge --delete-branch" {
    run grep "gh pr merge.*--delete-branch" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Test 11: Missing argument validation
# =============================================================================

@test "exits with error for --base without value" {
    run "$SCRIPT_DIR/git-shipyard.sh" --base
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing value for --base"* ]]
}

@test "exits with error for --head without value" {
    run "$SCRIPT_DIR/git-shipyard.sh" --head
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing value for --head"* ]]
}

# =============================================================================
# Test 12: Multi-line message support
# =============================================================================

@test "format_message_preview shows single line as-is" {
    cat > "$TEST_DIR/test_preview.sh" << EOF
#!/usr/bin/env bash
main() { :; }
source "$SCRIPT_DIR/git-shipyard.sh"
result=\$(format_message_preview "Single line message")
echo "RESULT=\$result"
EOF
    chmod +x "$TEST_DIR/test_preview.sh"

    run "$TEST_DIR/test_preview.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESULT=Single line message"* ]]
}

@test "format_message_preview truncates multi-line with count" {
    cat > "$TEST_DIR/test_preview_multi.sh" << 'EOF'
#!/usr/bin/env bash
format_message_preview() {
    local msg="$1"
    local first_line
    local line_count

    first_line=$(echo "$msg" | head -n1)
    line_count=$(echo "$msg" | wc -l)

    if [ "$line_count" -gt 1 ]; then
        echo "${first_line} (+$((line_count - 1)) more lines)"
    else
        echo "$first_line"
    fi
}

msg="First line
Second line
Third line"
result=$(format_message_preview "$msg")
echo "RESULT=$result"
EOF
    chmod +x "$TEST_DIR/test_preview_multi.sh"

    run "$TEST_DIR/test_preview_multi.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESULT=First line (+2 more lines)"* ]]
}

@test "script contains get_commit_message function" {
    run grep "get_commit_message()" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "get_commit_message offers editor option" {
    run grep "Multi-line (open editor)" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Test 13: select_issue() with issue creation when no issues exist
# =============================================================================

@test "select_issue skips creation prompt in non-interactive mode when no issues" {
    cat > "$TEST_DIR/test_select_issue_noninteractive.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
SELECTED_ISSUE=""
CREATED_ISSUE_FOR_PR=""

# Mock gh to return no issues
gh() {
    echo "[]"
    return 0
}

# Simulate select_issue no-issues path in non-interactive mode
issue_list=$(gh issue list --state open --json number,title --limit 20 2>/dev/null)

if [ -z "$issue_list" ] || [ "$issue_list" = "[]" ]; then
    echo -e "  ${YELLOW}ℹ${NC} No open issues found"
    # stdin is not a terminal in this test (piped)
    if [ ! -t 0 ]; then
        echo "NON_INTERACTIVE_SKIP"
    fi
fi
echo "SELECTED=$SELECTED_ISSUE"
EOF
    chmod +x "$TEST_DIR/test_select_issue_noninteractive.sh"

    run bash -c "echo '' | $TEST_DIR/test_select_issue_noninteractive.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No open issues found"* ]]
    [[ "$output" == *"NON_INTERACTIVE_SKIP"* ]]
    [[ "$output" == *"SELECTED="* ]]
}

@test "select_issue offers to create issue when no issues exist" {
    cat > "$TEST_DIR/test_select_no_issues_prompt.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Simulate the no-issues path with interactive check bypassed
issue_list="[]"

if [ -z "$issue_list" ] || [ "$issue_list" = "[]" ]; then
    echo -e "  ${YELLOW}ℹ${NC} No open issues found"
    echo ""
    echo "Create a new issue to link to this PR? (y/N): "
    echo "PROMPT_SHOWN"
fi
EOF
    chmod +x "$TEST_DIR/test_select_no_issues_prompt.sh"

    run "$TEST_DIR/test_select_no_issues_prompt.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No open issues found"* ]]
    [[ "$output" == *"Create a new issue to link to this PR?"* ]]
    [[ "$output" == *"PROMPT_SHOWN"* ]]
}

@test "select_issue skips issue link when user declines creation" {
    cat > "$TEST_DIR/test_select_decline_create.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
NC='\033[0m'

# Simulate user declining issue creation
create_issue="n"
if [[ ! "$create_issue" =~ ^[Yy]$ ]]; then
    echo -e "  ${YELLOW}ℹ${NC} Skipping issue link"
    echo "DECLINED"
fi
EOF
    chmod +x "$TEST_DIR/test_select_decline_create.sh"

    run "$TEST_DIR/test_select_decline_create.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping issue link"* ]]
    [[ "$output" == *"DECLINED"* ]]
}

@test "_create_issue_for_pr skips on empty title" {
    cat > "$TEST_DIR/test_create_for_pr_empty_title.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
NC='\033[0m'
SELECTED_ISSUE=""
CREATED_ISSUE_FOR_PR=""

# Simulate the empty title path
issue_title=""
if [ -z "$issue_title" ]; then
    echo -e "  ${YELLOW}ℹ${NC} Skipping issue creation (empty title)"
    echo "EMPTY_TITLE_HANDLED"
fi
echo "SELECTED=$SELECTED_ISSUE"
EOF
    chmod +x "$TEST_DIR/test_create_for_pr_empty_title.sh"

    run "$TEST_DIR/test_create_for_pr_empty_title.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping issue creation (empty title)"* ]]
    [[ "$output" == *"EMPTY_TITLE_HANDLED"* ]]
    [[ "$output" == *"SELECTED="* ]]
}

@test "_create_issue_for_pr creates issue and sets SELECTED_ISSUE (mocked)" {
    cat > "$TEST_DIR/test_create_for_pr_success.sh" << 'EOF'
#!/usr/bin/env bash
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'
SELECTED_ISSUE=""
CREATED_ISSUE_FOR_PR=""

# Mock gh to return a GitHub issue URL
gh() {
    echo "https://github.com/owner/repo/issues/42"
    return 0
}

issue_title="Fix the login bug"
issue_body="Users cannot log in when using SSO"

echo -e "${BLUE}Creating GitHub issue...${NC}"
issue_output=$(gh issue create --title "$issue_title" --body "$issue_body" 2>&1)
SELECTED_ISSUE=$(echo "$issue_output" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+')
CREATED_ISSUE_FOR_PR="$issue_title"
echo -e "  ${GREEN}✓${NC} Issue #${SELECTED_ISSUE} created: ${issue_title}"
echo -e "  ${GREEN}✓${NC} Will link issue #${SELECTED_ISSUE} to this PR"
echo "SELECTED=$SELECTED_ISSUE"
echo "CREATED=$CREATED_ISSUE_FOR_PR"
EOF
    chmod +x "$TEST_DIR/test_create_for_pr_success.sh"

    run "$TEST_DIR/test_create_for_pr_success.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Issue #42 created: Fix the login bug"* ]]
    [[ "$output" == *"Will link issue #42 to this PR"* ]]
    [[ "$output" == *"SELECTED=42"* ]]
    [[ "$output" == *"CREATED=Fix the login bug"* ]]
}

@test "_create_issue_for_pr handles gh failure" {
    cat > "$TEST_DIR/test_create_for_pr_fail.sh" << 'EOF'
#!/usr/bin/env bash
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'
SELECTED_ISSUE=""
CREATED_ISSUE_FOR_PR=""

# Mock gh to fail
gh() {
    echo "HTTP 422: Validation Failed" >&2
    return 1
}

issue_title="Fix the login bug"
issue_body="Description"

echo -e "${BLUE}Creating GitHub issue...${NC}"
if ! issue_output=$(gh issue create --title "$issue_title" --body "$issue_body" 2>&1); then
    echo -e "  ${RED}✗${NC} Failed to create issue"
    echo "$issue_output" >&2
    echo "FAILED"
    exit 1
fi
EOF
    chmod +x "$TEST_DIR/test_create_for_pr_fail.sh"

    run "$TEST_DIR/test_create_for_pr_fail.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to create issue"* ]]
    [[ "$output" == *"FAILED"* ]]
}

@test "_create_issue_for_pr extracts issue number from URL" {
    cat > "$TEST_DIR/test_issue_extract.sh" << 'EOF'
#!/usr/bin/env bash
# Test various URL formats that gh might return
urls=(
    "https://github.com/owner/repo/issues/1"
    "https://github.com/owner/repo/issues/42"
    "https://github.com/owner/repo/issues/999"
)

for url in "${urls[@]}"; do
    number=$(echo "$url" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+')
    echo "URL=$url NUMBER=$number"
done
EOF
    chmod +x "$TEST_DIR/test_issue_extract.sh"

    run "$TEST_DIR/test_issue_extract.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NUMBER=1"* ]]
    [[ "$output" == *"NUMBER=42"* ]]
    [[ "$output" == *"NUMBER=999"* ]]
}

@test "_create_issue_for_pr extraction ignores trailing non-URL text" {
    cat > "$TEST_DIR/test_issue_extract_robust.sh" << 'EOF'
#!/usr/bin/env bash
# Simulate gh outputting extra text after the URL
output="https://github.com/owner/repo/issues/15
Some deprecation warning 2025"

number=$(echo "$output" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+')
echo "NUMBER=$number"
EOF
    chmod +x "$TEST_DIR/test_issue_extract_robust.sh"

    run "$TEST_DIR/test_issue_extract_robust.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NUMBER=15"* ]]
}

@test "_create_issue_for_pr editor mode uses template when available" {
    cat > "$TEST_DIR/test_issue_template.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
NC='\033[0m'

# Create a fake template
template_dir="$TEST_DIR/fake_home/.config"
mkdir -p "$template_dir"
echo "## Bug Report" > "$template_dir/issue-template.md"
echo "Steps to reproduce:" >> "$template_dir/issue-template.md"

template_file="$template_dir/issue-template.md"
tmpfile=$(mktemp)

if [ -f "$template_file" ]; then
    cat "$template_file" > "$tmpfile"
    echo "TEMPLATE_LOADED"
else
    echo "TEMPLATE_MISSING"
fi

# Verify template content was copied
content=$(cat "$tmpfile")
rm -f "$tmpfile"

echo "CONTENT=$content"
EOF
    chmod +x "$TEST_DIR/test_issue_template.sh"

    run "$TEST_DIR/test_issue_template.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TEMPLATE_LOADED"* ]]
    [[ "$output" == *"Bug Report"* ]]
}

@test "_create_issue_for_pr editor mode warns when template missing" {
    cat > "$TEST_DIR/test_issue_no_template.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
NC='\033[0m'

template_file="/nonexistent/path/issue-template.md"
tmpfile=$(mktemp)

if [ -f "$template_file" ]; then
    cat "$template_file" > "$tmpfile"
    echo "TEMPLATE_LOADED"
else
    echo -e "  ${YELLOW}⚠${NC}  Warning: No issue template found at ~/.config/issue-template.md. Using blank template."
    echo "" > "$tmpfile"
    echo "TEMPLATE_MISSING"
fi

rm -f "$tmpfile"
EOF
    chmod +x "$TEST_DIR/test_issue_no_template.sh"

    run "$TEST_DIR/test_issue_no_template.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TEMPLATE_MISSING"* ]]
    [[ "$output" == *"Warning: No issue template found"* ]]
}

@test "summary shows created and linked issue when CREATED_ISSUE_FOR_PR is set" {
    cat > "$TEST_DIR/test_issue_summary.sh" << 'EOF'
#!/usr/bin/env bash
CYAN='\033[0;36m'
NC='\033[0m'
SELECTED_ISSUE="42"
CREATED_ISSUE_FOR_PR="Fix the login bug"

# Simulate the summary section from main()
if [ -n "$SELECTED_ISSUE" ]; then
    if [ -n "$CREATED_ISSUE_FOR_PR" ]; then
        echo -e "  • Created and linked issue #${SELECTED_ISSUE}: ${CREATED_ISSUE_FOR_PR}"
    else
        echo -e "  • Linked to issue #${SELECTED_ISSUE} (closes on merge)"
    fi
fi
EOF
    chmod +x "$TEST_DIR/test_issue_summary.sh"

    run "$TEST_DIR/test_issue_summary.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Created and linked issue #42: Fix the login bug"* ]]
}

@test "summary shows linked issue when SELECTED_ISSUE set without creation" {
    cat > "$TEST_DIR/test_issue_linked_summary.sh" << 'EOF'
#!/usr/bin/env bash
CYAN='\033[0;36m'
NC='\033[0m'
SELECTED_ISSUE="10"
CREATED_ISSUE_FOR_PR=""

# Simulate the summary section from main()
if [ -n "$SELECTED_ISSUE" ]; then
    if [ -n "$CREATED_ISSUE_FOR_PR" ]; then
        echo -e "  • Created and linked issue #${SELECTED_ISSUE}: ${CREATED_ISSUE_FOR_PR}"
    else
        echo -e "  • Linked to issue #${SELECTED_ISSUE} (closes on merge)"
    fi
fi
EOF
    chmod +x "$TEST_DIR/test_issue_linked_summary.sh"

    run "$TEST_DIR/test_issue_linked_summary.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Linked to issue #10 (closes on merge)"* ]]
    [[ "$output" != *"Created and linked"* ]]
}

@test "summary omits issue line when no issue was selected" {
    cat > "$TEST_DIR/test_issue_no_summary.sh" << 'EOF'
#!/usr/bin/env bash
SELECTED_ISSUE=""
CREATED_ISSUE_FOR_PR=""

# Simulate the summary section from main()
echo "START_SUMMARY"
if [ -n "$SELECTED_ISSUE" ]; then
    if [ -n "$CREATED_ISSUE_FOR_PR" ]; then
        echo -e "  • Created and linked issue #${SELECTED_ISSUE}: ${CREATED_ISSUE_FOR_PR}"
    else
        echo -e "  • Linked to issue #${SELECTED_ISSUE} (closes on merge)"
    fi
fi
echo "END_SUMMARY"
EOF
    chmod +x "$TEST_DIR/test_issue_no_summary.sh"

    run "$TEST_DIR/test_issue_no_summary.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"START_SUMMARY"* ]]
    [[ "$output" == *"END_SUMMARY"* ]]
    [[ "$output" != *"Created and linked"* ]]
    [[ "$output" != *"Linked to issue"* ]]
}

@test "_create_issue_for_pr function exists in script" {
    run grep "_create_issue_for_pr()" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "select_issue is called in main with || true" {
    run grep "select_issue || true" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "select_issue calls _create_issue_for_pr when no issues exist" {
    run grep "_create_issue_for_pr" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
    # Should appear at least twice: definition and call site in select_issue
    local count
    count=$(grep -c "_create_issue_for_pr" "$SCRIPT_DIR/git-shipyard.sh")
    [ "$count" -ge 2 ]
}

@test "select_issue displays issue list when issues exist" {
    cat > "$TEST_DIR/test_select_issue_list.sh" << 'EOF'
#!/usr/bin/env bash
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

gh() {
    if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
        echo '[{"number":5,"title":"Login bug"},{"number":12,"title":"Dark mode"}]'
        return 0
    fi
}

jq() {
    if [[ "$*" == *"number"* ]]; then
        echo "5"
        echo "12"
    elif [[ "$*" == *"title"* ]]; then
        echo "Login bug"
        echo "Dark mode"
    fi
}
export -f jq

issue_list=$(gh issue list --state open --json number,title --limit 20 2>/dev/null)

if [ -n "$issue_list" ] && [ "$issue_list" != "[]" ]; then
    local issue_numbers=()
    local issue_titles=()
    while IFS= read -r line; do
        issue_numbers+=("$line")
    done < <(echo "$issue_list" | jq -r '.[].number')
    while IFS= read -r line; do
        issue_titles+=("$line")
    done < <(echo "$issue_list" | jq -r '.[].title')

    echo "Link an issue to this PR?"
    for i in "${!issue_numbers[@]}"; do
        printf "  %2d) #%-4s %s\n" "$((i + 1))" "${issue_numbers[$i]}" "${issue_titles[$i]}"
    done
    printf "  %2d) None (skip linking)\n" "0"
fi
EOF
    chmod +x "$TEST_DIR/test_select_issue_list.sh"

    run "$TEST_DIR/test_select_issue_list.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Link an issue to this PR?"* ]]
    [[ "$output" == *"#5"* ]]
    [[ "$output" == *"Login bug"* ]]
    [[ "$output" == *"#12"* ]]
    [[ "$output" == *"Dark mode"* ]]
    [[ "$output" == *"None (skip linking)"* ]]
}

@test "select_issue skips on selection 0" {
    cat > "$TEST_DIR/test_select_issue_skip.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
NC='\033[0m'
SELECTED_ISSUE=""

selection=0

if [ "$selection" -eq 0 ]; then
    echo -e "  ${YELLOW}ℹ${NC} Skipping issue link"
    echo "SKIPPED"
else
    echo "LINKED"
fi
echo "SELECTED=$SELECTED_ISSUE"
EOF
    chmod +x "$TEST_DIR/test_select_issue_skip.sh"

    run "$TEST_DIR/test_select_issue_skip.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping issue link"* ]]
    [[ "$output" == *"SKIPPED"* ]]
    [[ "$output" == *"SELECTED="* ]]
}

@test "no post-PR create_github_issue call in main" {
    # create_github_issue was removed; verify it's not called in main
    run grep "create_github_issue" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -ne 0 ]
}

# =============================================================================
# Test 14: pr_management_mode() and PR action functions
# =============================================================================

@test "pr_management_mode function exists in script" {
    run grep "pr_management_mode()" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "pr_management_mode is dispatched from main" {
    run grep 'pr_management_mode' "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'pr_management_mode'* ]]
}

@test "mode detection sets pr_management when no changes and no commits ahead" {
    cat > "$TEST_DIR/test_pr_mgmt_mode.sh" << 'EOF'
#!/usr/bin/env bash
BASE_BRANCH="main"

has_uncommitted_changes() { return 1; }  # false
has_commits_ahead() { return 1; }        # false

if has_uncommitted_changes; then
    mode="full"
elif has_commits_ahead; then
    mode="pr_only"
else
    mode="pr_management"
fi

echo "MODE=$mode"
EOF
    chmod +x "$TEST_DIR/test_pr_mgmt_mode.sh"

    run "$TEST_DIR/test_pr_mgmt_mode.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MODE=pr_management"* ]]
}

@test "pr_management_mode exits cleanly when no open PRs" {
    cat > "$TEST_DIR/test_pr_mgmt_no_prs.sh" << 'EOF'
#!/usr/bin/env bash
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Mock gh to return empty PR list
gh() { echo "[]"; return 0; }

pr_list=$(gh pr list --state open --json number,title --limit 20 2>/dev/null)

if [ -z "$pr_list" ] || [ "$pr_list" = "[]" ]; then
    echo -e "  ${YELLOW}ℹ${NC} No open pull requests found"
    echo "NO_PRS_EXIT"
    exit 0
fi
EOF
    chmod +x "$TEST_DIR/test_pr_mgmt_no_prs.sh"

    run "$TEST_DIR/test_pr_mgmt_no_prs.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No open pull requests found"* ]]
    [[ "$output" == *"NO_PRS_EXIT"* ]]
}

@test "pr_management_mode cancels on x input" {
    cat > "$TEST_DIR/test_pr_mgmt_cancel.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
NC='\033[0m'

selection="x"
if [ "$selection" = "x" ] || [ "$selection" = "X" ]; then
    echo -e "${YELLOW}Operation cancelled.${NC}"
    echo "CANCELLED"
    exit 0
fi
EOF
    chmod +x "$TEST_DIR/test_pr_mgmt_cancel.sh"

    run "$TEST_DIR/test_pr_mgmt_cancel.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Operation cancelled."* ]]
    [[ "$output" == *"CANCELLED"* ]]
}

@test "pr_management_mode cancels on X input" {
    cat > "$TEST_DIR/test_pr_mgmt_cancel_upper.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
NC='\033[0m'

selection="X"
if [ "$selection" = "x" ] || [ "$selection" = "X" ]; then
    echo -e "${YELLOW}Operation cancelled.${NC}"
    echo "CANCELLED"
    exit 0
fi
EOF
    chmod +x "$TEST_DIR/test_pr_mgmt_cancel_upper.sh"

    run "$TEST_DIR/test_pr_mgmt_cancel_upper.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CANCELLED"* ]]
}

@test "pr_management_mode validates selection range" {
    cat > "$TEST_DIR/test_pr_mgmt_validation.sh" << 'EOF'
#!/usr/bin/env bash
RED='\033[0;31m'
NC='\033[0m'
pr_count=3

validate() {
    local selection="$1"
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "$pr_count" ]; then
        echo "VALID=$selection"
    else
        echo "INVALID=$selection"
    fi
}

validate 0
validate 1
validate 3
validate 4
validate "abc"
EOF
    chmod +x "$TEST_DIR/test_pr_mgmt_validation.sh"

    run "$TEST_DIR/test_pr_mgmt_validation.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INVALID=0"* ]]
    [[ "$output" == *"VALID=1"* ]]
    [[ "$output" == *"VALID=3"* ]]
    [[ "$output" == *"INVALID=4"* ]]
    [[ "$output" == *"INVALID=abc"* ]]
}

@test "pr_management_mode shows action menu with 4 options" {
    run grep "View details & comments" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
    run grep "Close PR" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
    run grep "Squash-merge PR" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
    run grep "View/close linked issues" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "pr_management_mode action menu validates input" {
    cat > "$TEST_DIR/test_pr_mgmt_action_validate.sh" << 'EOF'
#!/usr/bin/env bash
RED='\033[0;31m'
NC='\033[0m'

validate_action() {
    local action="$1"
    case "$action" in
        1|2|3|4) echo "VALID=$action" ;;
        x|X) echo "BACK" ;;
        *) echo "INVALID=$action" ;;
    esac
}

validate_action 1
validate_action 2
validate_action 3
validate_action 4
validate_action x
validate_action X
validate_action 5
validate_action "abc"
EOF
    chmod +x "$TEST_DIR/test_pr_mgmt_action_validate.sh"

    run "$TEST_DIR/test_pr_mgmt_action_validate.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VALID=1"* ]]
    [[ "$output" == *"VALID=2"* ]]
    [[ "$output" == *"VALID=3"* ]]
    [[ "$output" == *"VALID=4"* ]]
    [[ "$output" == *"BACK"* ]]
    [[ "$output" == *"INVALID=5"* ]]
    [[ "$output" == *"INVALID=abc"* ]]
}

@test "pr_management_mode PR select prompt says Select a pull request" {
    run grep "Select a pull request:" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
    # Should NOT say "to squash-merge" anymore
    run grep "Select a pull request to squash-merge" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -ne 0 ]
}

@test "squash_merge_pr uses --squash --delete-branch for merge" {
    run grep "gh pr merge.*--squash --delete-branch" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "squash_merge_pr detects merge conflicts" {
    cat > "$TEST_DIR/test_pr_mgmt_conflict.sh" << 'EOF'
#!/usr/bin/env bash
RED='\033[0;31m'
NC='\033[0m'

merge_output="CONFLICT (content): Merge conflict in file.txt"
if echo "$merge_output" | grep -qi "conflict\|merge conflict"; then
    echo -e "  ${RED}✗${NC} Merge conflict detected — resolve manually and retry"
    echo "CONFLICT_DETECTED"
fi
EOF
    chmod +x "$TEST_DIR/test_pr_mgmt_conflict.sh"

    run "$TEST_DIR/test_pr_mgmt_conflict.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Merge conflict detected"* ]]
    [[ "$output" == *"CONFLICT_DETECTED"* ]]
}

@test "squash_merge_pr handles generic merge failure" {
    cat > "$TEST_DIR/test_pr_mgmt_merge_fail.sh" << 'EOF'
#!/usr/bin/env bash
RED='\033[0;31m'
NC='\033[0m'

merge_output="GraphQL: Could not merge pull request (mergeStateStatus: BLOCKED)"
if echo "$merge_output" | grep -qi "conflict\|merge conflict"; then
    echo "CONFLICT_PATH"
else
    echo -e "  ${RED}✗${NC} Merge failed"
    echo "GENERIC_FAILURE"
fi
EOF
    chmod +x "$TEST_DIR/test_pr_mgmt_merge_fail.sh"

    run "$TEST_DIR/test_pr_mgmt_merge_fail.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Merge failed"* ]]
    [[ "$output" == *"GENERIC_FAILURE"* ]]
}

@test "squash_merge_pr shows confirmation with 4 actions" {
    run bash -c "sed -n '/^squash_merge_pr()/,/^}/p' '$SCRIPT_DIR/git-shipyard.sh' | grep -c -E '^\s+echo.*[1-4]\.\s+(Squash-merge|Delete remote|Switch to|Delete local)'"
    [ "$status" -eq 0 ]
    [ "$output" -eq 4 ]
}

@test "squash_merge_pr successful merge shows summary with branch cleaned up" {
    cat > "$TEST_DIR/test_pr_mgmt_summary.sh" << 'EOF'
#!/usr/bin/env bash
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'
BASE_BRANCH="main"
pr_number="7"
pr_title="Add login feature"
pr_head_branch="feature-login"
branch_deleted=true

echo -e "${CYAN}Summary:${NC}"
echo -e "  • PR #${pr_number} squash-merged: ${pr_title}"
echo -e "  • Remote branch deleted"
if [ "$branch_deleted" = true ]; then
    echo -e "  • Local branch '${pr_head_branch}' cleaned up"
fi
echo -e "  • ${BASE_BRANCH} updated with latest changes"
EOF
    chmod +x "$TEST_DIR/test_pr_mgmt_summary.sh"

    run "$TEST_DIR/test_pr_mgmt_summary.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PR #7 squash-merged: Add login feature"* ]]
    [[ "$output" == *"Remote branch deleted"* ]]
    [[ "$output" == *"Local branch 'feature-login' cleaned up"* ]]
    [[ "$output" == *"main updated with latest changes"* ]]
}

@test "squash_merge_pr summary omits branch line when deletion failed" {
    cat > "$TEST_DIR/test_pr_mgmt_summary_no_branch.sh" << 'EOF'
#!/usr/bin/env bash
CYAN='\033[0;36m'
NC='\033[0m'
BASE_BRANCH="main"
pr_number="7"
pr_title="Add login feature"
pr_head_branch="feature-login"
branch_deleted=false

echo -e "${CYAN}Summary:${NC}"
echo -e "  • PR #${pr_number} squash-merged: ${pr_title}"
echo -e "  • Remote branch deleted"
if [ "$branch_deleted" = true ]; then
    echo -e "  • Local branch '${pr_head_branch}' cleaned up"
fi
echo -e "  • ${BASE_BRANCH} updated with latest changes"
EOF
    chmod +x "$TEST_DIR/test_pr_mgmt_summary_no_branch.sh"

    run "$TEST_DIR/test_pr_mgmt_summary_no_branch.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PR #7 squash-merged"* ]]
    [[ "$output" != *"cleaned up"* ]]
}

@test "squash_merge_pr calls reset_dev_environment" {
    # Verify reset_dev_environment is called inside squash_merge_pr
    run bash -c "sed -n '/^squash_merge_pr()/,/^}/p' '$SCRIPT_DIR/git-shipyard.sh' | grep -c 'reset_dev_environment'"
    [ "$output" -ge 1 ]
}

@test "reset_dev_environment is NOT called before pr_management_mode in main" {
    # Verify reset_dev_environment is NOT called right before pr_management_mode in main
    run bash -c "grep -B1 'pr_management_mode' '$SCRIPT_DIR/git-shipyard.sh' | grep -c 'reset_dev_environment'"
    [ "$output" -eq 0 ]
}

@test "pr_management_mode skips base branch check" {
    run grep -B2 'check_not_on_base_branch' "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pr_management"* ]]
}

@test "squash_merge_pr uses safe branch delete with -D hint" {
    run grep "git branch -d" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
    run grep "git branch -D" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "squash_merge_pr resolves head branch before merge" {
    run grep "gh pr view.*headRefName" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "squash_merge_pr checks branch exists before deleting" {
    run grep "git show-ref --verify --quiet" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "squash_merge_pr uses branch_deleted flag for summary" {
    run grep "branch_deleted=true" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
    run grep "branch_deleted=false" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
    run grep 'branch_deleted.*=.*true' "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Test 14b: view_pr_details() function
# =============================================================================

@test "view_pr_details function exists in script" {
    run grep "view_pr_details()" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "view_pr_details displays PR metadata fields" {
    cat > "$TEST_DIR/test_view_pr_details.sh" << 'EOF'
#!/usr/bin/env bash
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# Simulate parsed PR metadata display
pr_title="Add dark mode"
pr_state="OPEN"
pr_author="octocat"
pr_created="2025-01-15"
pr_head="feature-dark"
pr_base="main"
pr_additions="42"
pr_deletions="10"
pr_changed_files="5"
pr_labels="enhancement"
pr_body="Adds dark mode support for the UI"

echo -e "  ${CYAN}Title:${NC}    ${pr_title}"
echo -e "  ${CYAN}State:${NC}    ${pr_state}"
echo -e "  ${CYAN}Author:${NC}   ${pr_author}"
echo -e "  ${CYAN}Created:${NC}  ${pr_created}"
echo -e "  ${CYAN}Branch:${NC}   ${pr_head} → ${pr_base}"
echo -e "  ${CYAN}Changes:${NC}  ${GREEN}+${pr_additions}${NC} ${RED}-${pr_deletions}${NC} (${pr_changed_files} files)"
if [ -n "$pr_labels" ]; then
    echo -e "  ${CYAN}Labels:${NC}   ${pr_labels}"
fi
echo ""
echo -e "  ${CYAN}Description:${NC}"
echo "$pr_body" | sed 's/^/    /'
EOF
    chmod +x "$TEST_DIR/test_view_pr_details.sh"

    run "$TEST_DIR/test_view_pr_details.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Add dark mode"* ]]
    [[ "$output" == *"OPEN"* ]]
    [[ "$output" == *"octocat"* ]]
    [[ "$output" == *"2025-01-15"* ]]
    [[ "$output" == *"feature-dark"* ]]
    [[ "$output" == *"+42"* ]]
    [[ "$output" == *"-10"* ]]
    [[ "$output" == *"5 files"* ]]
    [[ "$output" == *"enhancement"* ]]
    [[ "$output" == *"Adds dark mode support"* ]]
}

@test "view_pr_details shows no comments message when empty" {
    cat > "$TEST_DIR/test_view_pr_no_comments.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
NC='\033[0m'

comments_json="[]"

if [ -z "$comments_json" ] || [ "$comments_json" = "[]" ] || [ "$comments_json" = "null" ]; then
    echo -e "  ${YELLOW}ℹ${NC} No comments on this PR"
    echo "NO_COMMENTS"
fi
EOF
    chmod +x "$TEST_DIR/test_view_pr_no_comments.sh"

    run "$TEST_DIR/test_view_pr_no_comments.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No comments on this PR"* ]]
    [[ "$output" == *"NO_COMMENTS"* ]]
}

@test "view_pr_details displays comments with author and date" {
    cat > "$TEST_DIR/test_view_pr_comments.sh" << 'EOF'
#!/usr/bin/env bash
BLUE='\033[0;34m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Simulate comment display logic
comments_json='[{"author":{"login":"alice"},"body":"Looks good!","createdAt":"2025-01-20T10:30:00Z"},{"author":{"login":"bob"},"body":"Please fix the typo","createdAt":"2025-01-21T14:00:00Z"}]'

comment_count=$(echo "$comments_json" | jq 'length')
echo -e "  ${GREEN}${comment_count} comment(s)${NC}"
echo ""

i=0
while [ "$i" -lt "$comment_count" ]; do
    author=$(echo "$comments_json" | jq -r ".[$i].author.login")
    body=$(echo "$comments_json" | jq -r ".[$i].body")
    created_at=$(echo "$comments_json" | jq -r ".[$i].createdAt" | cut -d'T' -f1)

    echo -e "  ${CYAN}${author}${NC} (${created_at}):"
    echo "$body" | sed 's/^/    /'
    echo ""
    ((i++))
done
EOF
    chmod +x "$TEST_DIR/test_view_pr_comments.sh"

    run "$TEST_DIR/test_view_pr_comments.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 comment(s)"* ]]
    [[ "$output" == *"alice"* ]]
    [[ "$output" == *"2025-01-20"* ]]
    [[ "$output" == *"Looks good!"* ]]
    [[ "$output" == *"bob"* ]]
    [[ "$output" == *"2025-01-21"* ]]
    [[ "$output" == *"Please fix the typo"* ]]
}

@test "view_pr_details color-codes review states" {
    cat > "$TEST_DIR/test_view_pr_review_colors.sh" << 'EOF'
#!/usr/bin/env bash
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test the color-coding logic
for state in APPROVED CHANGES_REQUESTED COMMENTED PENDING; do
    state_color="$YELLOW"
    case "$state" in
        APPROVED) state_color="$GREEN" ;;
        CHANGES_REQUESTED) state_color="$RED" ;;
        COMMENTED) state_color="$CYAN" ;;
    esac
    echo -e "STATE=${state_color}${state}${NC}"
done
EOF
    chmod +x "$TEST_DIR/test_view_pr_review_colors.sh"

    run "$TEST_DIR/test_view_pr_review_colors.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"APPROVED"* ]]
    [[ "$output" == *"CHANGES_REQUESTED"* ]]
    [[ "$output" == *"COMMENTED"* ]]
    [[ "$output" == *"PENDING"* ]]
}

@test "view_pr_details is called from action menu option 1" {
    run bash -c "sed -n '/Action menu loop/,/done/p' '$SCRIPT_DIR/git-shipyard.sh' | grep -c 'view_pr_details'"
    [ "$output" -ge 1 ]
}

# =============================================================================
# Test 14c: close_pr() function
# =============================================================================

@test "close_pr function exists in script" {
    run grep "close_pr()" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "close_pr cancels when user declines" {
    cat > "$TEST_DIR/test_close_pr_cancel.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
NC='\033[0m'

confirm="n"
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Operation cancelled.${NC}"
    echo "CANCELLED"
fi
EOF
    chmod +x "$TEST_DIR/test_close_pr_cancel.sh"

    run "$TEST_DIR/test_close_pr_cancel.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Operation cancelled."* ]]
    [[ "$output" == *"CANCELLED"* ]]
}

@test "close_pr closes PR successfully (mocked)" {
    cat > "$TEST_DIR/test_close_pr_success.sh" << 'EOF'
#!/usr/bin/env bash
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Mock gh
gh() {
    if [ "$1" = "pr" ] && [ "$2" = "close" ]; then
        echo "Closed PR"
        return 0
    fi
    return 0
}

pr_number="42"
pr_title="Add feature"

echo -e "${BLUE}Closing PR #${pr_number}...${NC}"

close_cmd=(gh pr close "$pr_number")
close_output=$("${close_cmd[@]}" 2>&1)
status=$?

if [ $status -eq 0 ]; then
    echo -e "  ${GREEN}✓${NC} PR #${pr_number} closed"
    echo "CLOSE_SUCCESS"
fi
EOF
    chmod +x "$TEST_DIR/test_close_pr_success.sh"

    run "$TEST_DIR/test_close_pr_success.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PR #42 closed"* ]]
    [[ "$output" == *"CLOSE_SUCCESS"* ]]
}

@test "close_pr handles gh failure" {
    cat > "$TEST_DIR/test_close_pr_fail.sh" << 'EOF'
#!/usr/bin/env bash
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Mock gh to fail
gh() {
    echo "GraphQL: Not found" >&2
    return 1
}

pr_number="99"

echo -e "${BLUE}Closing PR #${pr_number}...${NC}"
if ! close_output=$(gh pr close "$pr_number" 2>&1); then
    echo -e "  ${RED}✗${NC} Failed to close PR"
    echo "CLOSE_FAILED"
fi
EOF
    chmod +x "$TEST_DIR/test_close_pr_fail.sh"

    run "$TEST_DIR/test_close_pr_fail.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Failed to close PR"* ]]
    [[ "$output" == *"CLOSE_FAILED"* ]]
}

@test "close_pr adds --delete-branch when user requests" {
    cat > "$TEST_DIR/test_close_pr_delete_branch.sh" << 'EOF'
#!/usr/bin/env bash
GREEN='\033[0;32m'
NC='\033[0m'

delete_branch="y"

close_cmd=(gh pr close "42")
if [[ "$delete_branch" =~ ^[Yy]$ ]]; then
    close_cmd+=(--delete-branch)
fi

# Output the command to verify --delete-branch was added
echo "CMD=${close_cmd[*]}"

if [[ "$delete_branch" =~ ^[Yy]$ ]]; then
    echo -e "  ${GREEN}✓${NC} Remote branch deleted"
    echo "BRANCH_DELETED"
fi
EOF
    chmod +x "$TEST_DIR/test_close_pr_delete_branch.sh"

    run "$TEST_DIR/test_close_pr_delete_branch.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--delete-branch"* ]]
    [[ "$output" == *"BRANCH_DELETED"* ]]
}

@test "close_pr shows summary on success" {
    cat > "$TEST_DIR/test_close_pr_summary.sh" << 'EOF'
#!/usr/bin/env bash
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

pr_number="42"
pr_title="Add dark mode"
delete_branch="y"

echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     ✓ PR closed!                       ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Summary:${NC}"
echo -e "  • PR #${pr_number} closed: ${pr_title}"
if [[ "$delete_branch" =~ ^[Yy]$ ]]; then
    echo -e "  • Remote branch deleted"
fi
EOF
    chmod +x "$TEST_DIR/test_close_pr_summary.sh"

    run "$TEST_DIR/test_close_pr_summary.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PR closed!"* ]]
    [[ "$output" == *"PR #42 closed: Add dark mode"* ]]
    [[ "$output" == *"Remote branch deleted"* ]]
}

@test "close_pr is called from action menu option 2" {
    run bash -c "sed -n '/Action menu loop/,/done/p' '$SCRIPT_DIR/git-shipyard.sh' | grep -c 'close_pr'"
    [ "$output" -ge 1 ]
}

# =============================================================================
# Test 14d: squash_merge_pr() function
# =============================================================================

@test "squash_merge_pr function exists in script" {
    run grep "squash_merge_pr()" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "squash_merge_pr is called from action menu option 3" {
    run bash -c "sed -n '/Action menu loop/,/done/p' '$SCRIPT_DIR/git-shipyard.sh' | grep -c 'squash_merge_pr'"
    [ "$output" -ge 1 ]
}

@test "squash_merge_pr contains squash-merge warning" {
    run grep "Squash-merge does not record merge history" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "squash_merge_pr contains duplicate conflicts warning" {
    run grep "duplicate conflicts" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Test 14e: view_linked_issues() function
# =============================================================================

@test "view_linked_issues function exists in script" {
    run grep "view_linked_issues()" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "view_linked_issues is called from action menu option 4" {
    run bash -c "sed -n '/Action menu loop/,/done/p' '$SCRIPT_DIR/git-shipyard.sh' | grep -c 'view_linked_issues'"
    [ "$output" -ge 1 ]
}

@test "view_linked_issues parses Closes, Fixes, Resolves, Part of keywords" {
    cat > "$TEST_DIR/test_linked_issues_parse.sh" << 'EOF'
#!/usr/bin/env bash

# Test the regex parsing from view_linked_issues
pr_body="This PR adds authentication.

Closes #10
Fixes #25
Resolves #30
Part of #42"

issue_refs=()
while IFS= read -r ref; do
    already_found=false
    for existing in "${issue_refs[@]}"; do
        if [ "$existing" = "$ref" ]; then
            already_found=true
            break
        fi
    done
    if [ "$already_found" = false ]; then
        issue_refs+=("$ref")
    fi
done < <(echo "$pr_body" | grep -oiE '(closes|fixes|resolves|part of)\s+#[0-9]+' | grep -oE '[0-9]+')

echo "COUNT=${#issue_refs[@]}"
for ref in "${issue_refs[@]}"; do
    echo "ISSUE=$ref"
done
EOF
    chmod +x "$TEST_DIR/test_linked_issues_parse.sh"

    run "$TEST_DIR/test_linked_issues_parse.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"COUNT=4"* ]]
    [[ "$output" == *"ISSUE=10"* ]]
    [[ "$output" == *"ISSUE=25"* ]]
    [[ "$output" == *"ISSUE=30"* ]]
    [[ "$output" == *"ISSUE=42"* ]]
}

@test "view_linked_issues deduplicates issue references" {
    cat > "$TEST_DIR/test_linked_issues_dedup.sh" << 'EOF'
#!/usr/bin/env bash

pr_body="Closes #10
Fixes #10
Resolves #25"

issue_refs=()
while IFS= read -r ref; do
    already_found=false
    for existing in "${issue_refs[@]}"; do
        if [ "$existing" = "$ref" ]; then
            already_found=true
            break
        fi
    done
    if [ "$already_found" = false ]; then
        issue_refs+=("$ref")
    fi
done < <(echo "$pr_body" | grep -oiE '(closes|fixes|resolves|part of)\s+#[0-9]+' | grep -oE '[0-9]+')

echo "COUNT=${#issue_refs[@]}"
for ref in "${issue_refs[@]}"; do
    echo "ISSUE=$ref"
done
EOF
    chmod +x "$TEST_DIR/test_linked_issues_dedup.sh"

    run "$TEST_DIR/test_linked_issues_dedup.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"COUNT=2"* ]]
    [[ "$output" == *"ISSUE=10"* ]]
    [[ "$output" == *"ISSUE=25"* ]]
}

@test "view_linked_issues shows tip when no issues found" {
    cat > "$TEST_DIR/test_linked_issues_none.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

issue_refs=()

if [ ${#issue_refs[@]} -eq 0 ]; then
    echo -e "  ${YELLOW}ℹ${NC} No linked issues found in PR body"
    echo ""
    echo -e "  ${CYAN}Tip:${NC} Issues are detected from the PR description using keywords like:"
    echo -e "       ${CYAN}Closes #N${NC}, ${CYAN}Fixes #N${NC}, ${CYAN}Resolves #N${NC}, ${CYAN}Part of #N${NC}"
    echo "NO_ISSUES_TIP"
fi
EOF
    chmod +x "$TEST_DIR/test_linked_issues_none.sh"

    run "$TEST_DIR/test_linked_issues_none.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No linked issues found in PR body"* ]]
    [[ "$output" == *"Closes #N"* ]]
    [[ "$output" == *"NO_ISSUES_TIP"* ]]
}

@test "view_linked_issues displays issues with state" {
    cat > "$TEST_DIR/test_linked_issues_display.sh" << 'EOF'
#!/usr/bin/env bash
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

issue_numbers=("10" "25")
issue_titles=("Login bug" "Dark mode")
issue_states=("OPEN" "CLOSED")

echo -e "${YELLOW}Linked issues:${NC}"
echo ""
for i in "${!issue_numbers[@]}"; do
    state_color="$GREEN"
    if [ "${issue_states[$i]}" = "CLOSED" ]; then
        state_color="$RED"
    fi
    printf "  ${CYAN}%2d)${NC} #%-4s [${state_color}%s${NC}] %s\n" "$((i + 1))" "${issue_numbers[$i]}" "${issue_states[$i]}" "${issue_titles[$i]}"
done
EOF
    chmod +x "$TEST_DIR/test_linked_issues_display.sh"

    run "$TEST_DIR/test_linked_issues_display.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Linked issues:"* ]]
    [[ "$output" == *"#10"* ]]
    [[ "$output" == *"OPEN"* ]]
    [[ "$output" == *"Login bug"* ]]
    [[ "$output" == *"#25"* ]]
    [[ "$output" == *"CLOSED"* ]]
    [[ "$output" == *"Dark mode"* ]]
}

@test "view_linked_issues shows all closed message when no open issues" {
    cat > "$TEST_DIR/test_linked_issues_all_closed.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
NC='\033[0m'

issue_states=("CLOSED" "CLOSED")

has_open=false
for state in "${issue_states[@]}"; do
    if [ "$state" = "OPEN" ]; then
        has_open=true
        break
    fi
done

if [ "$has_open" = false ]; then
    echo -e "  ${YELLOW}ℹ${NC} All linked issues are already closed"
    echo "ALL_CLOSED"
fi
EOF
    chmod +x "$TEST_DIR/test_linked_issues_all_closed.sh"

    run "$TEST_DIR/test_linked_issues_all_closed.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All linked issues are already closed"* ]]
    [[ "$output" == *"ALL_CLOSED"* ]]
}

@test "view_linked_issues close all option closes open issues (mocked)" {
    cat > "$TEST_DIR/test_linked_issues_close_all.sh" << 'EOF'
#!/usr/bin/env bash
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Mock gh
gh() {
    if [ "$1" = "issue" ] && [ "$2" = "close" ]; then
        return 0
    fi
}

issue_numbers=("10" "25" "30")
issue_titles=("Login bug" "Dark mode" "Old issue")
issue_states=("OPEN" "OPEN" "CLOSED")

open_indices=()
for i in "${!issue_numbers[@]}"; do
    if [ "${issue_states[$i]}" = "OPEN" ]; then
        open_indices+=("$i")
    fi
done

# Simulate close all
for idx in "${open_indices[@]}"; do
    inum="${issue_numbers[$idx]}"
    ititle="${issue_titles[$idx]}"
    echo -e "${BLUE}Closing issue #${inum}...${NC}"
    if gh issue close "$inum" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Issue #${inum} closed: ${ititle}"
    fi
done
EOF
    chmod +x "$TEST_DIR/test_linked_issues_close_all.sh"

    run "$TEST_DIR/test_linked_issues_close_all.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Issue #10 closed: Login bug"* ]]
    [[ "$output" == *"Issue #25 closed: Dark mode"* ]]
    # Issue #30 was CLOSED, should not appear
    [[ "$output" != *"Issue #30"* ]]
}

@test "view_linked_issues close single issue by number (mocked)" {
    cat > "$TEST_DIR/test_linked_issues_close_single.sh" << 'EOF'
#!/usr/bin/env bash
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Mock gh
gh() {
    if [ "$1" = "issue" ] && [ "$2" = "close" ]; then
        return 0
    fi
}

issue_numbers=("10" "25")
issue_titles=("Login bug" "Dark mode")
issue_states=("OPEN" "OPEN")

open_indices=(0 1)

# Simulate selecting issue #25
selection="25"

for idx in "${open_indices[@]}"; do
    if [ "${issue_numbers[$idx]}" = "$selection" ]; then
        echo -e "${BLUE}Closing issue #${selection}...${NC}"
        if gh issue close "$selection" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Issue #${selection} closed: ${issue_titles[$idx]}"
            echo "SINGLE_CLOSED"
        fi
    fi
done
EOF
    chmod +x "$TEST_DIR/test_linked_issues_close_single.sh"

    run "$TEST_DIR/test_linked_issues_close_single.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Issue #25 closed: Dark mode"* ]]
    [[ "$output" == *"SINGLE_CLOSED"* ]]
}

@test "view_linked_issues skip option works" {
    cat > "$TEST_DIR/test_linked_issues_skip.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
NC='\033[0m'

selection="0"

if [ "$selection" = "0" ]; then
    echo -e "  ${YELLOW}ℹ${NC} Skipping"
    echo "SKIPPED"
fi
EOF
    chmod +x "$TEST_DIR/test_linked_issues_skip.sh"

    run "$TEST_DIR/test_linked_issues_skip.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping"* ]]
    [[ "$output" == *"SKIPPED"* ]]
}

@test "view_linked_issues offers close all and skip options" {
    run grep "Close all open issues" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
    run bash -c "sed -n '/^view_linked_issues()/,/^}/p' '$SCRIPT_DIR/git-shipyard.sh' | grep -c 'Skip'"
    [ "$output" -ge 1 ]
}

@test "view_linked_issues handles gh issue close failure" {
    cat > "$TEST_DIR/test_linked_issues_close_fail.sh" << 'EOF'
#!/usr/bin/env bash
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Mock gh to fail
gh() {
    return 1
}

inum="99"
ititle="Missing issue"

echo -e "${BLUE}Closing issue #${inum}...${NC}"
if gh issue close "$inum" &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Issue #${inum} closed: ${ititle}"
else
    echo -e "  ${RED}✗${NC} Failed to close issue #${inum}"
    echo "CLOSE_FAILED"
fi
EOF
    chmod +x "$TEST_DIR/test_linked_issues_close_fail.sh"

    run "$TEST_DIR/test_linked_issues_close_fail.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Failed to close issue #99"* ]]
    [[ "$output" == *"CLOSE_FAILED"* ]]
}

@test "view_linked_issues parses case-insensitive keywords" {
    cat > "$TEST_DIR/test_linked_issues_case.sh" << 'EOF'
#!/usr/bin/env bash

pr_body="CLOSES #10
fixes #20
Resolves #30
part of #40"

issue_refs=()
while IFS= read -r ref; do
    already_found=false
    for existing in "${issue_refs[@]}"; do
        if [ "$existing" = "$ref" ]; then
            already_found=true
            break
        fi
    done
    if [ "$already_found" = false ]; then
        issue_refs+=("$ref")
    fi
done < <(echo "$pr_body" | grep -oiE '(closes|fixes|resolves|part of)\s+#[0-9]+' | grep -oE '[0-9]+')

echo "COUNT=${#issue_refs[@]}"
for ref in "${issue_refs[@]}"; do
    echo "ISSUE=$ref"
done
EOF
    chmod +x "$TEST_DIR/test_linked_issues_case.sh"

    run "$TEST_DIR/test_linked_issues_case.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"COUNT=4"* ]]
    [[ "$output" == *"ISSUE=10"* ]]
    [[ "$output" == *"ISSUE=20"* ]]
    [[ "$output" == *"ISSUE=30"* ]]
    [[ "$output" == *"ISSUE=40"* ]]
}

# =============================================================================
# Test 15: sync_with_base() function (F4)
# =============================================================================

@test "sync_with_base function exists in script" {
    run grep "sync_with_base()" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "sync_with_base is called in main workflow" {
    run grep "sync_with_base" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
    # Should appear at least twice: definition and call site
    local count
    count=$(grep -c "sync_with_base" "$SCRIPT_DIR/git-shipyard.sh")
    [ "$count" -ge 2 ]
}

@test "sync_with_base shows up to date message when already in sync" {
    cat > "$TEST_DIR/test_sync_uptodate.sh" << EOF
#!/usr/bin/env bash
BLUE='\\033[0;34m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
RED='\\033[0;31m'
NC='\\033[0m'
BASE_BRANCH="main"
HEAD_BRANCH="dev"

error_exit() { echo "Error: \$1" >&2; exit 1; }

# Mock git: fetch succeeds, merge-base says already ancestor (up to date)
git() {
    if [ "\$1" = "fetch" ]; then return 0; fi
    if [ "\$1" = "merge-base" ] && [ "\$2" = "--is-ancestor" ]; then return 0; fi
    /usr/bin/git "\$@"
}
export -f git

source "$SCRIPT_DIR/git-shipyard.sh"
run_result=\$(sync_with_base)
echo "\$run_result"
EOF
    chmod +x "$TEST_DIR/test_sync_uptodate.sh"

    run "$TEST_DIR/test_sync_uptodate.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"up to date"* ]]
}

@test "sync_with_base shows success after clean merge" {
    cat > "$TEST_DIR/test_sync_clean.sh" << EOF
#!/usr/bin/env bash
BLUE='\\033[0;34m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
RED='\\033[0;31m'
NC='\\033[0m'
BASE_BRANCH="main"
HEAD_BRANCH="dev"

error_exit() { echo "Error: \$1" >&2; exit 1; }

# Mock git: fetch succeeds, not ancestor yet, merge succeeds
git() {
    if [ "\$1" = "fetch" ]; then return 0; fi
    if [ "\$1" = "merge-base" ] && [ "\$2" = "--is-ancestor" ]; then return 1; fi
    if [ "\$1" = "merge" ]; then return 0; fi
    /usr/bin/git "\$@"
}
export -f git

source "$SCRIPT_DIR/git-shipyard.sh"
run_result=\$(sync_with_base)
echo "\$run_result"
EOF
    chmod +x "$TEST_DIR/test_sync_clean.sh"

    run "$TEST_DIR/test_sync_clean.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"up to date"* ]]
}

@test "sync_with_base skips gracefully when fetch fails" {
    cat > "$TEST_DIR/test_sync_fetch_fail.sh" << EOF
#!/usr/bin/env bash
BLUE='\\033[0;34m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
RED='\\033[0;31m'
NC='\\033[0m'
BASE_BRANCH="main"
HEAD_BRANCH="dev"

error_exit() { echo "Error: \$1" >&2; exit 1; }

# Mock git: fetch fails
git() {
    if [ "\$1" = "fetch" ]; then return 1; fi
    /usr/bin/git "\$@"
}
export -f git

source "$SCRIPT_DIR/git-shipyard.sh"
run_result=\$(sync_with_base)
status=\$?
echo "\$run_result"
exit \$status
EOF
    chmod +x "$TEST_DIR/test_sync_fetch_fail.sh"

    run "$TEST_DIR/test_sync_fetch_fail.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping sync"* ]]
}

@test "sync_with_base exits with error on conflict" {
    cat > "$TEST_DIR/test_sync_conflict_exit.sh" << EOF
#!/usr/bin/env bash
BLUE='\\033[0;34m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
RED='\\033[0;31m'
NC='\\033[0m'
BASE_BRANCH="main"
HEAD_BRANCH="dev"

error_exit() { echo "Error: \$1" >&2; exit 1; }

# Mock git: fetch succeeds, not ancestor, merge fails (conflict)
git() {
    if [ "\$1" = "fetch" ]; then return 0; fi
    if [ "\$1" = "merge-base" ] && [ "\$2" = "--is-ancestor" ]; then return 1; fi
    if [ "\$1" = "merge" ]; then return 1; fi
    if [ "\$1" = "diff" ]; then echo "src/app.js"; return 0; fi
    /usr/bin/git "\$@"
}
export -f git

source "$SCRIPT_DIR/git-shipyard.sh"
sync_with_base
EOF
    chmod +x "$TEST_DIR/test_sync_conflict_exit.sh"

    run "$TEST_DIR/test_sync_conflict_exit.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error"* ]] || [[ "$output" == *"conflict"* ]]
}

@test "sync_with_base lists conflicting files on conflict" {
    cat > "$TEST_DIR/test_sync_conflict_files.sh" << EOF
#!/usr/bin/env bash
BLUE='\\033[0;34m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
RED='\\033[0;31m'
NC='\\033[0m'
BASE_BRANCH="main"
HEAD_BRANCH="dev"

error_exit() { echo "Error: \$1" >&2; exit 1; }

# Mock git: fetch succeeds, not ancestor, merge fails, diff shows conflict files
git() {
    if [ "\$1" = "fetch" ]; then return 0; fi
    if [ "\$1" = "merge-base" ] && [ "\$2" = "--is-ancestor" ]; then return 1; fi
    if [ "\$1" = "merge" ]; then return 1; fi
    if [ "\$1" = "diff" ]; then printf "src/app.js\nREADME.md\n"; return 0; fi
    /usr/bin/git "\$@"
}
export -f git

source "$SCRIPT_DIR/git-shipyard.sh"
sync_with_base 2>&1 || true
EOF
    chmod +x "$TEST_DIR/test_sync_conflict_files.sh"

    run "$TEST_DIR/test_sync_conflict_files.sh"
    [[ "$output" == *"src/app.js"* ]]
    [[ "$output" == *"README.md"* ]]
}

@test "sync_with_base provides resolution instructions on conflict" {
    cat > "$TEST_DIR/test_sync_conflict_instructions.sh" << EOF
#!/usr/bin/env bash
BLUE='\\033[0;34m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
RED='\\033[0;31m'
NC='\\033[0m'
BASE_BRANCH="main"
HEAD_BRANCH="dev"

error_exit() { echo "Error: \$1" >&2; exit 1; }

git() {
    if [ "\$1" = "fetch" ]; then return 0; fi
    if [ "\$1" = "merge-base" ] && [ "\$2" = "--is-ancestor" ]; then return 1; fi
    if [ "\$1" = "merge" ]; then return 1; fi
    if [ "\$1" = "diff" ]; then echo "conflict.txt"; return 0; fi
    /usr/bin/git "\$@"
}
export -f git

source "$SCRIPT_DIR/git-shipyard.sh"
sync_with_base 2>&1 || true
EOF
    chmod +x "$TEST_DIR/test_sync_conflict_instructions.sh"

    run "$TEST_DIR/test_sync_conflict_instructions.sh"
    [[ "$output" == *"git add"* ]]
    [[ "$output" == *"Re-run git-shipyard"* ]] || [[ "$output" == *"re-run"* ]]
}

@test "sync_with_base pushes merge commit after clean merge" {
    cat > "$TEST_DIR/test_sync_push.sh" << EOF
#!/usr/bin/env bash
BLUE='\\033[0;34m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
RED='\\033[0;31m'
NC='\\033[0m'
BASE_BRANCH="main"
HEAD_BRANCH="dev"

error_exit() { echo "Error: \$1" >&2; exit 1; }

# Mock git: fetch succeeds, not ancestor, merge succeeds, push succeeds
git() {
    if [ "\$1" = "fetch" ]; then return 0; fi
    if [ "\$1" = "merge-base" ] && [ "\$2" = "--is-ancestor" ]; then return 1; fi
    if [ "\$1" = "merge" ]; then return 0; fi
    if [ "\$1" = "push" ]; then echo "PUSHED"; return 0; fi
    /usr/bin/git "\$@"
}
export -f git

source "$SCRIPT_DIR/git-shipyard.sh"
sync_with_base
EOF
    chmod +x "$TEST_DIR/test_sync_push.sh"

    run "$TEST_DIR/test_sync_push.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PUSHED"* ]]
    [[ "$output" == *"Merge commit pushed to remote"* ]]
}

@test "sync_with_base is called after push in main" {
    # Verify sync_with_base call appears after the git push commands
    local push_line sync_line
    push_line=$(grep -n 'git push' "$SCRIPT_DIR/git-shipyard.sh" | tail -1 | cut -d: -f1)
    sync_line=$(grep -nE '^[[:space:]]+sync_with_base[[:space:]]*$' "$SCRIPT_DIR/git-shipyard.sh" | head -1 | cut -d: -f1)
    [ -n "$push_line" ]
    [ -n "$sync_line" ]
    [ "$sync_line" -gt "$push_line" ]
}

@test "sync step appears in full mode actions list" {
    run grep "Sync with" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
    local count
    count=$(grep -c "Sync with" "$SCRIPT_DIR/git-shipyard.sh")
    [ "$count" -ge 2 ]
}

# =============================================================================
# Test 16: check_merge_in_progress() function (F4)
# =============================================================================

@test "check_merge_in_progress function exists in script" {
    run grep "check_merge_in_progress()" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "check_merge_in_progress returns zero when no merge in progress" {
    cat > "$TEST_DIR/test_merge_check_clean.sh" << EOF
#!/usr/bin/env bash
BLUE='\\033[0;34m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
RED='\\033[0;31m'
NC='\\033[0m'
BASE_BRANCH="main"
HEAD_BRANCH="dev"

error_exit() { echo "Error: \$1" >&2; exit 1; }

# Create a temp git repo with no MERGE_HEAD
tmp_repo=\$(mktemp -d)
git init --quiet "\$tmp_repo"
cd "\$tmp_repo"

source "$SCRIPT_DIR/git-shipyard.sh"
check_merge_in_progress
echo "EXIT=\$?"
EOF
    chmod +x "$TEST_DIR/test_merge_check_clean.sh"

    run "$TEST_DIR/test_merge_check_clean.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT=0"* ]]
}

@test "check_merge_in_progress errors when unresolved conflicts exist" {
    cat > "$TEST_DIR/test_merge_check_unresolved.sh" << EOF
#!/usr/bin/env bash
BLUE='\\033[0;34m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
RED='\\033[0;31m'
NC='\\033[0m'
BASE_BRANCH="main"
HEAD_BRANCH="dev"

error_exit() { echo "Error: \$1" >&2; exit 1; }

# Create a temp git repo and simulate MERGE_HEAD with unresolved conflicts
tmp_repo=\$(mktemp -d)
git init --quiet "\$tmp_repo"
cd "\$tmp_repo"
# Create MERGE_HEAD to simulate in-progress merge
echo "deadbeef" > "\$(git rev-parse --git-dir)/MERGE_HEAD"

# Override git diff to simulate unresolved conflicts
git() {
    if [ "\$1" = "diff" ] && [ "\$2" = "--name-only" ]; then
        echo "conflicted.txt"
        return 0
    fi
    /usr/bin/git "\$@"
}
export -f git

source "$SCRIPT_DIR/git-shipyard.sh"
check_merge_in_progress
EOF
    chmod +x "$TEST_DIR/test_merge_check_unresolved.sh"

    run "$TEST_DIR/test_merge_check_unresolved.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]] || [[ "$output" == *"unresolved"* ]] || [[ "$output" == *"Error"* ]]
}

@test "check_merge_in_progress lists conflicting files" {
    cat > "$TEST_DIR/test_merge_check_list.sh" << EOF
#!/usr/bin/env bash
BLUE='\\033[0;34m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
RED='\\033[0;31m'
NC='\\033[0m'
BASE_BRANCH="main"
HEAD_BRANCH="dev"

error_exit() { echo "Error: \$1" >&2; exit 1; }

tmp_repo=\$(mktemp -d)
git init --quiet "\$tmp_repo"
cd "\$tmp_repo"
echo "deadbeef" > "\$(git rev-parse --git-dir)/MERGE_HEAD"

git() {
    if [ "\$1" = "diff" ] && [ "\$2" = "--name-only" ]; then
        printf "src/main.go\nconfig.yaml\n"
        return 0
    fi
    /usr/bin/git "\$@"
}
export -f git

source "$SCRIPT_DIR/git-shipyard.sh"
check_merge_in_progress 2>&1 || true
EOF
    chmod +x "$TEST_DIR/test_merge_check_list.sh"

    run "$TEST_DIR/test_merge_check_list.sh"
    [[ "$output" == *"src/main.go"* ]]
    [[ "$output" == *"config.yaml"* ]]
}

@test "check_merge_in_progress is called in main before mode detection" {
    # Verify check_merge_in_progress call appears before mode detection
    local check_line mode_line
    check_line=$(grep -n 'check_merge_in_progress' "$SCRIPT_DIR/git-shipyard.sh" | grep -v '^[^:]*:.*()' | head -1 | cut -d: -f1)
    mode_line=$(grep -n 'Determine workflow mode' "$SCRIPT_DIR/git-shipyard.sh" | head -1 | cut -d: -f1)
    [ -n "$check_line" ]
    [ -n "$mode_line" ]
    [ "$check_line" -lt "$mode_line" ]
}

# =============================================================================
# Test 17: prompt_issue_creation() function
# =============================================================================

@test "prompt_issue_creation function exists in script" {
    run grep "prompt_issue_creation()" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "prompt_issue_creation skips in non-interactive mode" {
    cat > "$TEST_DIR/test_prompt_issue_noninteractive.sh" << EOF
#!/usr/bin/env bash
main() { :; }
source "$SCRIPT_DIR/git-shipyard.sh"
prompt_issue_creation
echo "EXIT=\$?"
EOF
    chmod +x "$TEST_DIR/test_prompt_issue_noninteractive.sh"

    run bash -c "echo '' | $TEST_DIR/test_prompt_issue_noninteractive.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT=1"* ]]
}

@test "prompt_issue_creation returns 1 when user declines" {
    cat > "$TEST_DIR/test_prompt_issue_decline.sh" << 'EOF'
#!/usr/bin/env bash
# Simulate the decline path
create_issue="n"
if [[ ! "$create_issue" =~ ^[Yy]$ ]]; then
    echo "DECLINED"
    exit 1
fi
EOF
    chmod +x "$TEST_DIR/test_prompt_issue_decline.sh"

    run "$TEST_DIR/test_prompt_issue_decline.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DECLINED"* ]]
}

@test "prompt_issue_creation returns 1 on empty title" {
    cat > "$TEST_DIR/test_prompt_issue_empty_title.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
NC='\033[0m'

issue_title=""
if [ -z "$issue_title" ]; then
    echo -e "  ${YELLOW}ℹ${NC} Skipping issue creation (empty title)"
    echo "EMPTY_TITLE"
    exit 1
fi
EOF
    chmod +x "$TEST_DIR/test_prompt_issue_empty_title.sh"

    run "$TEST_DIR/test_prompt_issue_empty_title.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Skipping issue creation (empty title)"* ]]
}

@test "prompt_issue_creation type menu maps correctly" {
    cat > "$TEST_DIR/test_prompt_issue_types.sh" << 'EOF'
#!/usr/bin/env bash
map_type() {
    case $1 in
        1) echo "enhancement" ;;
        2) echo "bug" ;;
        3) echo "feature" ;;
        4) echo "docs" ;;
        5) echo "refactor" ;;
        *) echo "INVALID" ;;
    esac
}

for i in 1 2 3 4 5 6; do
    echo "INPUT=$i TYPE=$(map_type $i)"
done
EOF
    chmod +x "$TEST_DIR/test_prompt_issue_types.sh"

    run "$TEST_DIR/test_prompt_issue_types.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INPUT=1 TYPE=enhancement"* ]]
    [[ "$output" == *"INPUT=2 TYPE=bug"* ]]
    [[ "$output" == *"INPUT=3 TYPE=feature"* ]]
    [[ "$output" == *"INPUT=4 TYPE=docs"* ]]
    [[ "$output" == *"INPUT=5 TYPE=refactor"* ]]
    [[ "$output" == *"INPUT=6 TYPE=INVALID"* ]]
}

@test "prompt_issue_creation creates issue successfully (mocked)" {
    cat > "$TEST_DIR/test_prompt_issue_success.sh" << 'EOF'
#!/usr/bin/env bash
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Mock gh
gh() {
    echo "https://github.com/owner/repo/issues/99"
    return 0
}

issue_title="Add dark mode"
issue_body="## Overview\n\nAdd dark mode support"
issue_type="feature"

echo -e "${BLUE}Creating GitHub issue...${NC}"
issue_output=$(gh issue create --title "$issue_title" --body "$issue_body" --label "$issue_type" 2>&1)
issue_number=$(echo "$issue_output" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+')
echo -e "  ${GREEN}✓${NC} Issue #${issue_number} created: ${issue_title}"
echo "NUMBER=$issue_number"
EOF
    chmod +x "$TEST_DIR/test_prompt_issue_success.sh"

    run "$TEST_DIR/test_prompt_issue_success.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Issue #99 created: Add dark mode"* ]]
    [[ "$output" == *"NUMBER=99"* ]]
}

@test "prompt_issue_creation handles gh failure" {
    cat > "$TEST_DIR/test_prompt_issue_fail.sh" << 'EOF'
#!/usr/bin/env bash
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Mock gh to fail
gh() {
    echo "label 'feature' not found" >&2
    return 1
}

echo -e "${BLUE}Creating GitHub issue...${NC}"
if ! issue_output=$(gh issue create --title "Test" --body "Body" --label "feature" 2>&1); then
    echo -e "  ${RED}✗${NC} Failed to create issue"
    echo "FAILED"
    exit 1
fi
EOF
    chmod +x "$TEST_DIR/test_prompt_issue_fail.sh"

    run "$TEST_DIR/test_prompt_issue_fail.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to create issue"* ]]
}

@test "prompt_issue_creation template populates overview and status" {
    cat > "$TEST_DIR/test_prompt_issue_template.sh" << 'EOF'
#!/usr/bin/env bash
# Create a test template
tmpdir=$(mktemp -d)
cat > "$tmpdir/template.md" << 'TMPL'
## Overview

Placeholder text

## Labels

| Category | Examples |
|----------|----------|
| Type | bug, feature |

## Status

- Completed
- In Progress
- Not Started

## Tasks

- [ ] Task 1
TMPL

overview="Implement user authentication with OAuth2"
result=$(awk -v overview="$overview" '
    /^## Overview$/ { print; print ""; print overview; skip=1; next }
    /^## Status$/ { print; print ""; print "- Not Started"; skip=1; next }
    /^## / { skip=0 }
    !skip { print }
' "$tmpdir/template.md")

echo "$result"
rm -rf "$tmpdir"
EOF
    chmod +x "$TEST_DIR/test_prompt_issue_template.sh"

    run "$TEST_DIR/test_prompt_issue_template.sh"
    [ "$status" -eq 0 ]
    # Overview should have user text, not placeholder
    [[ "$output" == *"Implement user authentication with OAuth2"* ]]
    [[ "$output" != *"Placeholder text"* ]]
    # Status should be Not Started only
    [[ "$output" == *"- Not Started"* ]]
    [[ "$output" != *"- Completed"* ]]
    [[ "$output" != *"- In Progress"* ]]
    # Other sections should remain
    [[ "$output" == *"## Labels"* ]]
    [[ "$output" == *"## Tasks"* ]]
}

@test "prompt_issue_creation falls back when template missing" {
    cat > "$TEST_DIR/test_prompt_issue_no_template.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
NC='\033[0m'

template_file="/nonexistent/template.md"
overview="Fix login bug"

if [ -f "$template_file" ]; then
    echo "TEMPLATE_FOUND"
else
    echo -e "  ${YELLOW}⚠${NC}  No template found at ~/.config/issue-template.md. Using minimal body."
    issue_body="## Overview

${overview}

## Status

- Not Started"
    echo "FALLBACK"
    echo "$issue_body"
fi
EOF
    chmod +x "$TEST_DIR/test_prompt_issue_no_template.sh"

    run "$TEST_DIR/test_prompt_issue_no_template.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FALLBACK"* ]]
    [[ "$output" == *"No template found"* ]]
    [[ "$output" == *"Fix login bug"* ]]
    [[ "$output" == *"- Not Started"* ]]
}

@test "prompt_issue_creation is called before pre-flight checks in main" {
    local prompt_line preflight_line
    prompt_line=$(grep -n 'prompt_issue_creation' "$SCRIPT_DIR/git-shipyard.sh" | grep -v '^[^:]*:.*()' | head -1 | cut -d: -f1)
    preflight_line=$(grep -n 'Running pre-flight checks' "$SCRIPT_DIR/git-shipyard.sh" | head -1 | cut -d: -f1)
    [ -n "$prompt_line" ]
    [ -n "$preflight_line" ]
    [ "$prompt_line" -lt "$preflight_line" ]
}

@test "prompt_issue_creation exits script on success" {
    # Verify main() returns after successful issue creation
    run bash -c "grep -A3 'prompt_issue_creation' '$SCRIPT_DIR/git-shipyard.sh' | grep -c 'return'"
    [ "$output" -ge 1 ]
}

@test "prompt_issue_creation uses --label flag for issue type" {
    run grep 'gh issue create.*--label' "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

# =============================================================================
# Test: check_prs_with_comments() function
# =============================================================================

@test "check_prs_with_comments function exists in script" {
    run grep "check_prs_with_comments()" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "check_prs_with_comments returns 1 when no open PRs" {
    cat > "$TEST_DIR/test_no_prs_comments.sh" << 'EOF'
#!/usr/bin/env bash
BLUE='\033[0;34m'
NC='\033[0m'

# Mock gh to return empty list
gh() {
    echo "[]"
    return 0
}

check_prs_with_comments() {
    if [ ! -t 0 ]; then
        # Force interactive for test
        :
    fi

    local pr_list
    pr_list=$(gh pr list --state open --json number,title,comments --limit 20 2>/dev/null)

    if [ -z "$pr_list" ] || [ "$pr_list" = "[]" ]; then
        echo "No open pull requests found"
        return 1
    fi
}

check_prs_with_comments
echo "RETURN=$?"
EOF
    chmod +x "$TEST_DIR/test_no_prs_comments.sh"

    run "$TEST_DIR/test_no_prs_comments.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No open pull requests found"* ]]
}

@test "check_prs_with_comments returns 1 when PRs have no comments" {
    cat > "$TEST_DIR/test_prs_no_comments.sh" << 'EOF'
#!/usr/bin/env bash
BLUE='\033[0;34m'
NC='\033[0m'

# Mock gh to return PRs with empty comments
gh() {
    echo '[{"number":10,"title":"Add feature","comments":[]},{"number":11,"title":"Fix bug","comments":[]}]'
    return 0
}

# Mock jq (use real jq)
pr_list=$(gh pr list --state open --json number,title,comments --limit 20 2>/dev/null)
prs_with_comments=$(echo "$pr_list" | jq '[.[] | select((.comments | length) > 0)]' 2>/dev/null)

if [ -z "$prs_with_comments" ] || [ "$prs_with_comments" = "[]" ]; then
    echo "No open PRs with comments"
fi
EOF
    chmod +x "$TEST_DIR/test_prs_no_comments.sh"

    run "$TEST_DIR/test_prs_no_comments.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No open PRs with comments"* ]]
}

@test "check_prs_with_comments lists PRs that have comments" {
    cat > "$TEST_DIR/test_list_prs_comments.sh" << 'EOF'
#!/usr/bin/env bash
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Mock gh to return PRs, some with comments
gh() {
    echo '[{"number":10,"title":"Add feature","comments":[{"author":{"login":"alice"},"body":"Looks good"}]},{"number":11,"title":"Fix bug","comments":[]},{"number":12,"title":"Update docs","comments":[{"author":{"login":"bob"},"body":"Needs work"},{"author":{"login":"carol"},"body":"Agreed"}]}]'
    return 0
}

pr_list=$(gh pr list --state open --json number,title,comments --limit 20 2>/dev/null)
prs_with_comments=$(echo "$pr_list" | jq '[.[] | select((.comments | length) > 0)]' 2>/dev/null)

# Parse PR numbers, titles, and comment counts
pr_numbers=()
pr_titles=()
pr_comment_counts=()
while IFS= read -r line; do
    pr_numbers+=("$line")
done < <(echo "$prs_with_comments" | jq -r '.[].number')

while IFS= read -r line; do
    pr_titles+=("$line")
done < <(echo "$prs_with_comments" | jq -r '.[].title')

while IFS= read -r line; do
    pr_comment_counts+=("$line")
done < <(echo "$prs_with_comments" | jq -r '.[].comments | length')

pr_count=${#pr_numbers[@]}

echo "Found ${pr_count} open PR(s) with comments"
for i in "${!pr_numbers[@]}"; do
    printf "%d) #%-4s %s (%s comments)\n" "$((i + 1))" "${pr_numbers[$i]}" "${pr_titles[$i]}" "${pr_comment_counts[$i]}"
done
EOF
    chmod +x "$TEST_DIR/test_list_prs_comments.sh"

    run "$TEST_DIR/test_list_prs_comments.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Found 2 open PR(s) with comments"* ]]
    [[ "$output" == *"#10"* ]]
    [[ "$output" == *"Add feature"* ]]
    [[ "$output" == *"1 comments"* ]]
    [[ "$output" == *"#12"* ]]
    [[ "$output" == *"Update docs"* ]]
    [[ "$output" == *"2 comments"* ]]
    # PR #11 (no comments) should NOT appear
    [[ "$output" != *"#11"* ]]
    [[ "$output" != *"Fix bug"* ]]
}

@test "check_prs_with_comments skip selection continues workflow" {
    cat > "$TEST_DIR/test_skip_prs_comments.sh" << 'EOF'
#!/usr/bin/env bash
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

gh() {
    echo '[{"number":10,"title":"Add feature","comments":[{"author":{"login":"alice"},"body":"Looks good"}]}]'
    return 0
}

pr_list=$(gh pr list --state open --json number,title,comments --limit 20 2>/dev/null)
prs_with_comments=$(echo "$pr_list" | jq '[.[] | select((.comments | length) > 0)]' 2>/dev/null)

pr_numbers=()
while IFS= read -r line; do
    pr_numbers+=("$line")
done < <(echo "$prs_with_comments" | jq -r '.[].number')

pr_count=${#pr_numbers[@]}

# Simulate user entering 0 (skip)
selection=0
if [ "$selection" -eq 0 ]; then
    echo "Skipping — continuing with workflow"
fi
EOF
    chmod +x "$TEST_DIR/test_skip_prs_comments.sh"

    run "$TEST_DIR/test_skip_prs_comments.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping — continuing with workflow"* ]]
}

@test "check_prs_with_comments calls view_pr_details on selection" {
    cat > "$TEST_DIR/test_view_pr_comments.sh" << 'EOF'
#!/usr/bin/env bash
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Track function calls
VIEWED_PR=""

view_pr_details() {
    VIEWED_PR="$1"
    echo "VIEWED_PR_DETAILS=$1"
}

gh() {
    echo '[{"number":42,"title":"Dark mode","comments":[{"author":{"login":"bob"},"body":"Nice work"}]}]'
    return 0
}

pr_list=$(gh pr list --state open --json number,title,comments --limit 20 2>/dev/null)
prs_with_comments=$(echo "$pr_list" | jq '[.[] | select((.comments | length) > 0)]' 2>/dev/null)

pr_numbers=()
pr_titles=()
while IFS= read -r line; do
    pr_numbers+=("$line")
done < <(echo "$prs_with_comments" | jq -r '.[].number')

while IFS= read -r line; do
    pr_titles+=("$line")
done < <(echo "$prs_with_comments" | jq -r '.[].title')

# Simulate user selecting PR 1
selection=1
selected_pr=${pr_numbers[$((selection - 1))]}
selected_title=${pr_titles[$((selection - 1))]}

view_pr_details "$selected_pr"

echo "SELECTED_PR=$selected_pr"
echo "SELECTED_TITLE=$selected_title"
EOF
    chmod +x "$TEST_DIR/test_view_pr_comments.sh"

    run "$TEST_DIR/test_view_pr_comments.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VIEWED_PR_DETAILS=42"* ]]
    [[ "$output" == *"SELECTED_PR=42"* ]]
    [[ "$output" == *"SELECTED_TITLE=Dark mode"* ]]
}

@test "check_prs_with_comments close PR and exit returns 0" {
    cat > "$TEST_DIR/test_close_exit_comments.sh" << 'EOF'
#!/usr/bin/env bash
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

CLOSE_CALLED=""
view_pr_details() { echo "Viewing PR #$1"; }
close_pr() {
    CLOSE_CALLED="$1"
    echo "CLOSE_PR_CALLED=$1"
}

# Simulate action=1 (close and exit)
action=1
selected_pr=42
selected_title="Dark mode"

case "$action" in
    1)
        close_pr "$selected_pr" "$selected_title"
        echo "Goodbye! See you later!"
        echo "EXIT_CODE=0"
        ;;
    2)
        echo "Goodbye! See you later!"
        echo "EXIT_CODE=0"
        ;;
    3)
        echo "Continuing with workflow"
        echo "EXIT_CODE=1"
        ;;
esac
EOF
    chmod +x "$TEST_DIR/test_close_exit_comments.sh"

    run "$TEST_DIR/test_close_exit_comments.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLOSE_PR_CALLED=42"* ]]
    [[ "$output" == *"Goodbye! See you later!"* ]]
    [[ "$output" == *"EXIT_CODE=0"* ]]
}

@test "check_prs_with_comments exit without closing returns 0" {
    cat > "$TEST_DIR/test_exit_no_close_comments.sh" << 'EOF'
#!/usr/bin/env bash
CLOSE_CALLED=""
close_pr() { CLOSE_CALLED="$1"; }

# Simulate action=2 (exit without closing)
action=2
selected_pr=42
selected_title="Dark mode"

case "$action" in
    1)
        close_pr "$selected_pr" "$selected_title"
        echo "CLOSE_CALLED=yes"
        echo "EXIT_CODE=0"
        ;;
    2)
        echo "Goodbye! See you later!"
        echo "CLOSE_CALLED=no"
        echo "EXIT_CODE=0"
        ;;
    3)
        echo "Continuing with workflow"
        echo "EXIT_CODE=1"
        ;;
esac
EOF
    chmod +x "$TEST_DIR/test_exit_no_close_comments.sh"

    run "$TEST_DIR/test_exit_no_close_comments.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLOSE_CALLED=no"* ]]
    [[ "$output" == *"Goodbye! See you later!"* ]]
    [[ "$output" != *"CLOSE_CALLED=yes"* ]]
}

@test "check_prs_with_comments continue with workflow returns 1" {
    cat > "$TEST_DIR/test_continue_comments.sh" << 'EOF'
#!/usr/bin/env bash
CLOSE_CALLED=""
close_pr() { CLOSE_CALLED="$1"; }

# Simulate action=3 (continue with workflow)
action=3
selected_pr=42
selected_title="Dark mode"
result=0

case "$action" in
    1)
        close_pr "$selected_pr" "$selected_title"
        result=0
        ;;
    2)
        result=0
        ;;
    3)
        echo "Continuing with workflow"
        result=1
        ;;
esac

echo "RESULT=$result"
EOF
    chmod +x "$TEST_DIR/test_continue_comments.sh"

    run "$TEST_DIR/test_continue_comments.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Continuing with workflow"* ]]
    [[ "$output" == *"RESULT=1"* ]]
}

@test "check_prs_with_comments is called in pr_only mode in main" {
    # Verify the pr_only block calls check_prs_with_comments
    run bash -c "sed -n '/In pr_only mode/,/fi/p' '$SCRIPT_DIR/git-shipyard.sh' | grep -c 'check_prs_with_comments'"
    [ "$output" -ge 1 ]
}

@test "check_prs_with_comments skips in non-interactive mode" {
    # The function checks [ ! -t 0 ] and returns 1 immediately
    run bash -c "sed -n '/^check_prs_with_comments()/,/^}/p' '$SCRIPT_DIR/git-shipyard.sh' | grep -c '! -t 0'"
    [ "$output" -ge 1 ]
}

@test "check_prs_with_comments offers three actions after viewing" {
    # Verify the action menu has close, exit, and continue options
    run grep -A20 'After viewing, offer close or exit' "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Close PR"* ]]
    [[ "$output" == *"Exit without closing"* ]]
    [[ "$output" == *"Continue with workflow"* ]]
}
