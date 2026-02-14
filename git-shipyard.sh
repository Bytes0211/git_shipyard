#!/usr/bin/env bash
#
# Git Shipyard
# Interactive script to stage, commit, push, and create a PR in one step
#

set -o pipefail

# Default branch names (can be overridden with --base and --head)
BASE_BRANCH="main"
HEAD_BRANCH="dev"

# Parse arguments
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
        --help|-h)
            echo "Usage: git-shipyard.sh [--base <branch>] [--head <branch>]"
            echo "  --base  Base branch for PR (default: main)"
            echo "  --head  Head branch for PR (default: dev)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Spinner function
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    local elapsed=0
    local duration=${2:-2}
    
    while (( $(awk "BEGIN {print ($elapsed < $duration)}") )); do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
        elapsed=$(awk "BEGIN {print $elapsed + $delay}")
    done
    printf "    \b\b\b\b"
}

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

# Check GitHub authentication
check_gh_auth() {
    if ! gh auth status &> /dev/null; then
        error_exit "Not authenticated with GitHub. Run 'gh auth login' first."
    fi
}

# Check if remote exists
check_remote() {
    if ! git remote get-url origin &> /dev/null; then
        error_exit "No 'origin' remote found. Please add a remote repository."
    fi
}

# Main script
main() {
    clear
    
    # Welcome banner
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      ${GREEN}Welcome to Git Shipyard${CYAN}             ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    # Pre-flight checks
    echo -e "${BLUE}Running pre-flight checks...${NC}"
    
    check_command "git"
    echo -e "  ${GREEN}✓${NC} git found"
    
    check_command "gh"
    echo -e "  ${GREEN}✓${NC} gh CLI found"
    
    check_git_repo
    echo -e "  ${GREEN}✓${NC} Inside git repository"
    
    check_gh_auth
    echo -e "  ${GREEN}✓${NC} GitHub authenticated"
    
    check_remote
    echo -e "  ${GREEN}✓${NC} Remote 'origin' configured"
    
    # Determine workflow mode
    local mode=""
    if has_uncommitted_changes; then
        mode="full"
        echo -e "  ${GREEN}✓${NC} Uncommitted changes detected"
    elif has_commits_ahead; then
        mode="pr_only"
        echo -e "  ${GREEN}✓${NC} Commits ahead of ${BASE_BRANCH} (already committed)"
    else
        error_exit "No changes to commit and no commits ahead of main."
    fi
    
    echo ""
    
    if [ "$mode" = "full" ]; then
        # Prompt for commit message
        echo -e "${YELLOW}Enter your commit message:${NC}"
        read -r -p "> " commit_message
        
        # Validate commit message
        if [ -z "$commit_message" ]; then
            error_exit "Commit message cannot be empty."
        fi
        
        # Flush any remaining input (handles pasted multi-line text)
        read -r -t 0.1 -n 10000 discard 2>/dev/null || true
        
        # Confirm action
        echo ""
        echo -e "${BLUE}The following actions will be performed:${NC}"
        echo -e "  1. Stage all changes (git add .)"
        echo -e "  2. Commit with message: ${CYAN}\"$commit_message\"${NC}"
        echo -e "  3. Push to origin/${HEAD_BRANCH}"
        echo -e "  4. Create PR from ${HEAD_BRANCH} → ${BASE_BRANCH}"
    else
        # PR only mode
        echo -e "${BLUE}The following actions will be performed:${NC}"
        echo -e "  1. Push to origin/${HEAD_BRANCH} (if needed)"
        echo -e "  2. Create PR from ${HEAD_BRANCH} → ${BASE_BRANCH}"
    fi
    
    echo ""
    
    read -r -p "Proceed? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        echo -e "${YELLOW}Goodbye!${NC}"
        exit 0
    fi
    
    echo ""
    
    # Spinner pause
    echo -e "${BLUE}Preparing to ship...${NC}"
    spinner $$ 2
    echo -e "  ${GREEN}✓${NC} Ready"
    echo ""
    
    if [ "$mode" = "full" ]; then
        # Full workflow: stage, commit, push, create PR
        echo -e "${BLUE}Staging changes...${NC}"
        if ! git add .; then
            error_exit "Failed to stage changes."
        fi
        echo -e "  ${GREEN}✓${NC} Changes staged"
        
        echo -e "${BLUE}Committing...${NC}"
        if ! git commit -m "$commit_message"; then
            error_exit "Commit failed. Check your commit message."
        fi
        echo -e "  ${GREEN}✓${NC} Changes committed"
        
        echo -e "${BLUE}Pushing to origin/${HEAD_BRANCH}...${NC}"
        if ! git push -u origin "${HEAD_BRANCH}"; then
            error_exit "Push failed. Check remote configuration."
        fi
        echo -e "  ${GREEN}✓${NC} Pushed to origin/${HEAD_BRANCH}"
    else
        # PR only: push if needed, then create PR
        echo -e "${BLUE}Pushing to origin/${HEAD_BRANCH}...${NC}"
        if ! git push -u origin "${HEAD_BRANCH}" 2>/dev/null; then
            echo -e "  ${YELLOW}ℹ${NC} Already up to date or pushed"
        else
            echo -e "  ${GREEN}✓${NC} Pushed to origin/${HEAD_BRANCH}"
        fi
    fi
    
    echo -e "${BLUE}Creating pull request...${NC}"
    echo -e "${YELLOW}─────────────────────────────────────────${NC}"
    
    if ! gh pr create --base "${BASE_BRANCH}" --head "${HEAD_BRANCH}" --fill; then
        # Check if PR already exists
        if gh pr view "${HEAD_BRANCH}" &>/dev/null; then
            echo -e "${YELLOW}─────────────────────────────────────────${NC}"
            echo -e "  ${YELLOW}ℹ${NC} PR already exists for this branch"
            gh pr view "${HEAD_BRANCH}" --web 2>/dev/null || true
        else
            error_exit "Failed to create PR. Check the output above for details."
        fi
    fi
    
    echo -e "${YELLOW}─────────────────────────────────────────${NC}"
    echo ""
    
    # Success message
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     ✓ All actions completed!           ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Summary:${NC}"
    if [ "$mode" = "full" ]; then
        echo -e "  • Changes staged and committed"
    fi
    echo -e "  • Pushed to origin/${HEAD_BRANCH}"
    echo -e "  • Pull request created (${HEAD_BRANCH} → ${BASE_BRANCH})"
    echo ""
    echo -e "${YELLOW}Goodbye!${NC}"
}

# Trap for unexpected errors
trap 'error_exit "An unexpected error occurred."' ERR

# Run main function
main "$@"
