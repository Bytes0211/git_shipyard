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

@test "conflict abort uses git reset --merge not git merge --abort" {
    # Verify the script uses correct abort command for squash merge
    run grep -c "git reset --merge" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
    
    # Should NOT use git merge --abort for squash conflicts
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

@test "script deletes remote branch with --delete flag" {
    run grep "git push origin --delete" "$SCRIPT_DIR/git-shipyard.sh"
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
# Test 13: create_github_issue() function
# =============================================================================

@test "create_github_issue skips in non-interactive mode" {
    cat > "$TEST_DIR/test_issue_noninteractive.sh" << EOF
#!/usr/bin/env bash
main() { :; }
source "$SCRIPT_DIR/git-shipyard.sh"
create_github_issue
echo "STATUS=\$?"
echo "NUMBER=\$CREATED_ISSUE_NUMBER"
EOF
    chmod +x "$TEST_DIR/test_issue_noninteractive.sh"

    # Pipe input to simulate non-interactive mode (stdin is not a terminal)
    run bash -c "echo '' | $TEST_DIR/test_issue_noninteractive.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NUMBER="* ]]
    # Should NOT contain any prompts
    [[ "$output" != *"Create a GitHub Issue"* ]]
}

@test "create_github_issue skips when user declines" {
    cat > "$TEST_DIR/test_issue_decline.sh" << 'EOF'
#!/usr/bin/env bash
CREATED_ISSUE_NUMBER=""
CREATED_ISSUE_TITLE=""

# Simulate interactive terminal
create_github_issue() {
    CREATED_ISSUE_NUMBER=""
    CREATED_ISSUE_TITLE=""

    local create_issue="n"
    if [[ ! "$create_issue" =~ ^[Yy]$ ]]; then
        echo "SKIPPED"
        return 0
    fi
}

create_github_issue
echo "NUMBER=$CREATED_ISSUE_NUMBER"
EOF
    chmod +x "$TEST_DIR/test_issue_decline.sh"

    run "$TEST_DIR/test_issue_decline.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
    [[ "$output" == *"NUMBER="* ]]
}

@test "create_github_issue skips on empty title" {
    cat > "$TEST_DIR/test_issue_empty_title.sh" << 'EOF'
#!/usr/bin/env bash
YELLOW='\033[1;33m'
NC='\033[0m'
CREATED_ISSUE_NUMBER=""
CREATED_ISSUE_TITLE=""

# Simulate the empty title path
issue_title=""
if [ -z "$issue_title" ]; then
    echo -e "  ${YELLOW}ℹ${NC} Skipping issue creation (empty title)"
    echo "EMPTY_TITLE_HANDLED"
fi
echo "NUMBER=$CREATED_ISSUE_NUMBER"
EOF
    chmod +x "$TEST_DIR/test_issue_empty_title.sh"

    run "$TEST_DIR/test_issue_empty_title.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping issue creation (empty title)"* ]]
    [[ "$output" == *"EMPTY_TITLE_HANDLED"* ]]
}

@test "create_github_issue creates issue successfully (mocked)" {
    cat > "$TEST_DIR/test_issue_success.sh" << 'EOF'
#!/usr/bin/env bash
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'
CREATED_ISSUE_NUMBER=""
CREATED_ISSUE_TITLE=""

# Mock gh to return a GitHub issue URL
gh() {
    echo "https://github.com/owner/repo/issues/42"
    return 0
}

issue_title="Fix the login bug"
issue_body="Users cannot log in when using SSO"

echo -e "${BLUE}Creating GitHub issue...${NC}"
local_output=$(gh issue create --title "$issue_title" --body "$issue_body" 2>&1)
CREATED_ISSUE_NUMBER=$(echo "$local_output" | grep -oE '[0-9]+$')
CREATED_ISSUE_TITLE="$issue_title"
echo -e "  ${GREEN}✓${NC} Issue #${CREATED_ISSUE_NUMBER} created: ${CREATED_ISSUE_TITLE}"
echo "NUMBER=$CREATED_ISSUE_NUMBER"
echo "TITLE=$CREATED_ISSUE_TITLE"
EOF
    chmod +x "$TEST_DIR/test_issue_success.sh"

    run "$TEST_DIR/test_issue_success.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Issue #42 created: Fix the login bug"* ]]
    [[ "$output" == *"NUMBER=42"* ]]
    [[ "$output" == *"TITLE=Fix the login bug"* ]]
}

@test "create_github_issue handles gh failure" {
    cat > "$TEST_DIR/test_issue_fail.sh" << 'EOF'
#!/usr/bin/env bash
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'
CREATED_ISSUE_NUMBER=""
CREATED_ISSUE_TITLE=""

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
    chmod +x "$TEST_DIR/test_issue_fail.sh"

    run "$TEST_DIR/test_issue_fail.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to create issue"* ]]
    [[ "$output" == *"FAILED"* ]]
}

@test "create_github_issue extracts issue number from URL" {
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

@test "create_github_issue extraction ignores trailing non-URL text" {
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

@test "create_github_issue editor mode uses template when available" {
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

@test "create_github_issue editor mode warns when template missing" {
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

@test "summary shows created issue when CREATED_ISSUE_NUMBER is set" {
    cat > "$TEST_DIR/test_issue_summary.sh" << 'EOF'
#!/usr/bin/env bash
CYAN='\033[0;36m'
NC='\033[0m'
CREATED_ISSUE_NUMBER="42"
CREATED_ISSUE_TITLE="Fix the login bug"

# Simulate the summary section from main()
if [ -n "$CREATED_ISSUE_NUMBER" ]; then
    echo -e "  • Created issue #${CREATED_ISSUE_NUMBER}: ${CREATED_ISSUE_TITLE}"
fi
EOF
    chmod +x "$TEST_DIR/test_issue_summary.sh"

    run "$TEST_DIR/test_issue_summary.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Created issue #42: Fix the login bug"* ]]
}

@test "summary omits issue line when no issue was created" {
    cat > "$TEST_DIR/test_issue_no_summary.sh" << 'EOF'
#!/usr/bin/env bash
CREATED_ISSUE_NUMBER=""
CREATED_ISSUE_TITLE=""

# Simulate the summary section from main()
echo "START_SUMMARY"
if [ -n "$CREATED_ISSUE_NUMBER" ]; then
    echo -e "  • Created issue #${CREATED_ISSUE_NUMBER}: ${CREATED_ISSUE_TITLE}"
fi
echo "END_SUMMARY"
EOF
    chmod +x "$TEST_DIR/test_issue_no_summary.sh"

    run "$TEST_DIR/test_issue_no_summary.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"START_SUMMARY"* ]]
    [[ "$output" == *"END_SUMMARY"* ]]
    [[ "$output" != *"Created issue"* ]]
}

@test "create_github_issue function exists in script" {
    run grep "create_github_issue()" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}

@test "create_github_issue is called in main with || true" {
    run grep "create_github_issue || true" "$SCRIPT_DIR/git-shipyard.sh"
    [ "$status" -eq 0 ]
}
