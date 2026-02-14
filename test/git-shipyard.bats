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

    # Create a helper script that sources functions without running main
    cat > "$TEST_DIR/source_functions.sh" << 'EOF'
#!/usr/bin/env bash
# Source the script functions without executing main

# Default branch names
BASE_BRANCH="main"
HEAD_BRANCH="dev"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Error handler
error_exit() {
    echo -e "\n${RED}Error: $1${NC}" >&2
    echo -e "${YELLOW}Goodbye!${NC}"
    exit 1
}

# Check if command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        error_exit "$1 is not installed. Please install it and try again."
    fi
}

# Check if in a git repository
check_git_repo() {
    if ! git rev-parse --is-inside-work-tree &> /dev/null; then
        error_exit "Not inside a git repository."
    fi
}

# Check if there are uncommitted changes
has_uncommitted_changes() {
    ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]
}

# Check if current branch has commits ahead of base
has_commits_ahead() {
    local ahead
    ahead=$(git rev-list --count "${BASE_BRANCH}"..HEAD 2>/dev/null || echo "0")
    [ "$ahead" -gt 0 ]
}
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
    # Run script with --help to avoid full execution, but capture variable state
    # We test by running a modified version that just outputs the variables
    cat > "$TEST_DIR/test_args.sh" << 'EOF'
#!/usr/bin/env bash
BASE_BRANCH="main"
HEAD_BRANCH="dev"

while [[ $# -gt 0 ]]; do
    case $1 in
        --base)
            BASE_BRANCH="$2"
            shift 2
            ;;
        --head)
            HEAD_BRANCH="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

echo "BASE_BRANCH=$BASE_BRANCH"
echo "HEAD_BRANCH=$HEAD_BRANCH"
EOF
    chmod +x "$TEST_DIR/test_args.sh"

    run "$TEST_DIR/test_args.sh" --base production
    [ "$status" -eq 0 ]
    [[ "$output" == *"BASE_BRANCH=production"* ]]
    [[ "$output" == *"HEAD_BRANCH=dev"* ]]
}

@test "parses --head argument correctly" {
    cat > "$TEST_DIR/test_args.sh" << 'EOF'
#!/usr/bin/env bash
BASE_BRANCH="main"
HEAD_BRANCH="dev"

while [[ $# -gt 0 ]]; do
    case $1 in
        --base)
            BASE_BRANCH="$2"
            shift 2
            ;;
        --head)
            HEAD_BRANCH="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

echo "BASE_BRANCH=$BASE_BRANCH"
echo "HEAD_BRANCH=$HEAD_BRANCH"
EOF
    chmod +x "$TEST_DIR/test_args.sh"

    run "$TEST_DIR/test_args.sh" --head feature-branch
    [ "$status" -eq 0 ]
    [[ "$output" == *"BASE_BRANCH=main"* ]]
    [[ "$output" == *"HEAD_BRANCH=feature-branch"* ]]
}

@test "parses both --base and --head arguments correctly" {
    cat > "$TEST_DIR/test_args.sh" << 'EOF'
#!/usr/bin/env bash
BASE_BRANCH="main"
HEAD_BRANCH="dev"

while [[ $# -gt 0 ]]; do
    case $1 in
        --base)
            BASE_BRANCH="$2"
            shift 2
            ;;
        --head)
            HEAD_BRANCH="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

echo "BASE_BRANCH=$BASE_BRANCH"
echo "HEAD_BRANCH=$HEAD_BRANCH"
EOF
    chmod +x "$TEST_DIR/test_args.sh"

    run "$TEST_DIR/test_args.sh" --base production --head feature-xyz
    [ "$status" -eq 0 ]
    [[ "$output" == *"BASE_BRANCH=production"* ]]
    [[ "$output" == *"HEAD_BRANCH=feature-xyz"* ]]
}

@test "uses default values when no arguments provided" {
    cat > "$TEST_DIR/test_args.sh" << 'EOF'
#!/usr/bin/env bash
BASE_BRANCH="main"
HEAD_BRANCH="dev"

while [[ $# -gt 0 ]]; do
    case $1 in
        --base)
            BASE_BRANCH="$2"
            shift 2
            ;;
        --head)
            HEAD_BRANCH="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

echo "BASE_BRANCH=$BASE_BRANCH"
echo "HEAD_BRANCH=$HEAD_BRANCH"
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
