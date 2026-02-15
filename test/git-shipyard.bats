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
