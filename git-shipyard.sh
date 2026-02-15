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
            [[ -n "${2:-}" ]] || { echo "Error: Missing value for --base"; exit 1; }
            BASE_BRANCH="$2"
            shift 2
            ;;
        --head)
            [[ -n "${2:-}" ]] || { echo "Error: Missing value for --head"; exit 1; }
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
    local delay=0.1
    local spinstr='|/-\'
    local elapsed=0
    local duration=${1:-2}
    
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

# Check if there are open PRs for the head branch
has_open_prs() {
    local count
    count=$(gh pr list --head "${HEAD_BRANCH}" --state open --json number --jq 'length' 2>/dev/null || echo "0")
    [ "$count" -gt 0 ]
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
    # Trap for unexpected errors (only active during main execution)
    trap 'error_exit "An unexpected error occurred."' ERR
    
    echo ""
    
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
        # Check if eligible for squash-merge (no open PRs)
        if ! has_open_prs; then
            mode="squash_eligible"
            echo -e "  ${GREEN}✓${NC} Commits ahead of ${BASE_BRANCH} (no open PRs)"
        else
            mode="pr_only"
            echo -e "  ${GREEN}✓${NC} Commits ahead of ${BASE_BRANCH} (open PR exists)"
        fi
    else
        error_exit "No changes to commit and no commits ahead of ${BASE_BRANCH}."
    fi
    
    echo ""
    
    # Handle squash-eligible mode - prompt user for choice
    if [ "$mode" = "squash_eligible" ]; then
        echo -e "${BLUE}No uncommitted changes detected.${NC}"
        echo -e "${BLUE}No open PRs for ${HEAD_BRANCH}.${NC}"
        echo -e "${BLUE}Your branch is ahead of ${BASE_BRANCH}.${NC}"
        echo ""
        echo -e "${YELLOW}How would you like to proceed?${NC}"
        echo -e "  1. Create a Pull Request (existing workflow)"
        echo -e "  2. Squash-merge into ${BASE_BRANCH}"
        echo ""
        
        while true; do
            read -r -p "Choose (1/2): " choice
            case "$choice" in
                1)
                    mode="pr_only"
                    break
                    ;;
                2)
                    mode="squash_merge"
                    break
                    ;;
                *)
                    echo -e "${RED}Invalid choice. Please enter 1 or 2.${NC}"
                    ;;
            esac
        done
        echo ""
    fi
    
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
    elif [ "$mode" = "squash_merge" ]; then
        # Squash-merge mode - prompt for commit message
        echo -e "${YELLOW}Enter squash-merge commit message:${NC}"
        read -r -p "> " squash_message
        
        if [ -z "$squash_message" ]; then
            error_exit "Commit message cannot be empty."
        fi
        
        # Flush any remaining input
        read -r -t 0.1 -n 10000 discard 2>/dev/null || true
        
        echo ""
        echo -e "${BLUE}The following actions will be performed:${NC}"
        echo -e "  1. Switch to ${BASE_BRANCH}"
        echo -e "  2. Squash-merge ${HEAD_BRANCH} into ${BASE_BRANCH}"
        echo -e "  3. Commit with message: ${CYAN}\"$squash_message\"${NC}"
        echo -e "  4. Push ${BASE_BRANCH} to origin"
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
    spinner 2
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
    elif [ "$mode" = "squash_merge" ]; then
        # Squash-merge workflow
        local original_branch="$HEAD_BRANCH"
        
        echo -e "${BLUE}Switching to ${BASE_BRANCH}...${NC}"
        if ! git checkout "${BASE_BRANCH}"; then
            error_exit "Failed to switch to ${BASE_BRANCH}."
        fi
        echo -e "  ${GREEN}✓${NC} Switched to ${BASE_BRANCH}"
        
        echo -e "${BLUE}Squash-merging ${original_branch}...${NC}"
        if ! git merge --squash "${original_branch}" 2>/dev/null; then
            # Merge conflict detected
            echo -e "  ${RED}✗${NC} Merge conflicts detected"
            echo ""
            echo -e "${YELLOW}Unable to squash-merge automatically.${NC}"
            read -r -p "Would you like to create a Pull Request instead? (y/N): " pr_fallback
            
            # Abort the merge using reset (--squash doesn't set MERGE_HEAD)
            git reset --merge
            git checkout "${original_branch}"
            
            if [[ "$pr_fallback" =~ ^[Yy]$ ]]; then
                echo ""
                echo -e "${BLUE}Falling back to PR workflow...${NC}"
                mode="pr_only"
                # Continue to PR creation below
            else
                echo ""
                echo -e "${YELLOW}Squash-merge aborted. Returned to ${original_branch}.${NC}"
                echo -e "${YELLOW}Goodbye!${NC}"
                exit 0
            fi
        else
            echo -e "  ${GREEN}✓${NC} Squash-merge prepared"
            
            echo -e "${BLUE}Committing squash-merge...${NC}"
            if ! git commit -m "$squash_message"; then
                error_exit "Commit failed."
            fi
            echo -e "  ${GREEN}✓${NC} Committed"
            
            echo -e "${BLUE}Pushing ${BASE_BRANCH} to origin...${NC}"
            if ! git push origin "${BASE_BRANCH}"; then
                error_exit "Push failed. Check remote configuration."
            fi
            echo -e "  ${GREEN}✓${NC} Pushed to origin/${BASE_BRANCH}"
            
            echo ""
            echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
            echo -e "${GREEN}║     ✓ Squash-merge completed!          ║${NC}"
            echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
            echo ""
            
            # Branch cleanup prompt
            read -r -p "Delete feature branch '${original_branch}'? (y/N): " delete_branch
            
            if [[ "$delete_branch" =~ ^[Yy]$ ]]; then
                echo ""
                echo -e "${BLUE}Deleting local branch ${original_branch}...${NC}"
                if ! git branch -d "${original_branch}"; then
                    echo -e "  ${YELLOW}⚠${NC} Could not delete local branch (may need -D)"
                else
                    echo -e "  ${GREEN}✓${NC} Local branch deleted"
                fi
                
                echo -e "${BLUE}Deleting remote branch ${original_branch}...${NC}"
                if ! git push origin --delete "${original_branch}" 2>/dev/null; then
                    echo -e "  ${YELLOW}⚠${NC} Could not delete remote branch (may not exist)"
                else
                    echo -e "  ${GREEN}✓${NC} Remote branch deleted"
                fi
            else
                # Return to feature branch and warn about re-merge issues
                git checkout "${original_branch}"
                echo ""
                echo -e "  ${YELLOW}⚠${NC} Note: Squash-merge does not record merge history."
                echo -e "    Re-merging this branch later may cause duplicate conflicts."
            fi
            
            echo ""
            echo -e "${CYAN}Summary:${NC}"
            echo -e "  • Squash-merged ${original_branch} into ${BASE_BRANCH}"
            echo -e "  • Pushed to origin/${BASE_BRANCH}"
            echo ""
            echo -e "${YELLOW}Goodbye!${NC}"
            exit 0
        fi
    fi
    
    # PR workflow (for full, pr_only, or squash_merge fallback)
    if [ "$mode" = "pr_only" ]; then
        # PR only: push if needed, then create PR
        echo -e "${BLUE}Pushing to origin/${HEAD_BRANCH}...${NC}"
        if ! git push -u origin "${HEAD_BRANCH}"; then
            error_exit "Push failed. Check remote configuration."
        fi
        echo -e "  ${GREEN}✓${NC} Pushed to origin/${HEAD_BRANCH}"
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

# Run main function only when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
