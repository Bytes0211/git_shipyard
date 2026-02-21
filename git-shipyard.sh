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
            if [ -z "$2" ] || [[ "$2" == --* ]]; then
                echo "Error: --base requires a branch name"
                exit 1
            fi
            BASE_BRANCH="$2"
            shift 2
            ;;
        --head)
            if [ -z "$2" ] || [[ "$2" == --* ]]; then
                echo "Error: --head requires a branch name"
                exit 1
            fi
            HEAD_BRANCH="$2"
            shift 2
            ;;
        --draft)
            DRAFT_PR=true
            shift
            ;;
        --help|-h)
            echo "Usage: git-shipyard.sh [--base <branch>] [--head <branch>] [--draft]"
            echo "  --base   Base branch for PR (default: main)"
            echo "  --head   Head branch for PR (default: dev)"
            echo "  --draft  Create PR as draft"
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

# Spinner function (uses bash arithmetic to avoid spawning awk processes)
spinner() {
    local pid=$1
    local spinstr='|/-\\'
    local i=0
    local duration=${2:-20}  # iterations, not seconds
    
    while (( i < duration )); do
        local char=${spinstr:i%4:1}
        printf " [%c]  " "$char"
        sleep 0.1
        printf "\b\b\b\b\b\b"
        ((i++))
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

# Check if in detached HEAD state
check_not_detached() {
    if ! git symbolic-ref --short HEAD &>/dev/null; then
        error_exit "Cannot run in detached HEAD state. Checkout a branch first."
    fi
}

# Check if on base branch (would cause main..main = 0 commits)
check_not_on_base_branch() {
    local current_branch
    current_branch=$(git symbolic-ref --short HEAD 2>/dev/null)
    if [ "$current_branch" = "$BASE_BRANCH" ]; then
        error_exit "Cannot run on base branch '$BASE_BRANCH'. Checkout a feature branch first."
    fi
}

# F1: Auto-sync HEAD_BRANCH with BASE_BRANCH before workflow begins
sync_dev_with_main() {
    echo -e "${BLUE}Syncing ${HEAD_BRANCH} with ${BASE_BRANCH}...${NC}"

    local stashed=false

    # Stash uncommitted changes if present
    if has_uncommitted_changes; then
        echo -e "${BLUE}  Stashing uncommitted changes...${NC}"
        if ! git stash push -m "git-shipyard: auto-stash before sync" --include-untracked; then
            error_exit "Failed to stash changes before sync."
        fi
        echo -e "  ${GREEN}✓${NC} Changes stashed"
        stashed=true
    fi

    # Pull latest BASE_BRANCH into HEAD_BRANCH
    echo -e "${BLUE}  Pulling latest ${BASE_BRANCH}...${NC}"
    local pull_output
    pull_output=$(git pull origin "${BASE_BRANCH}" 2>&1)
    local pull_exit=$?

    if [ $pull_exit -ne 0 ]; then
        if [ "$stashed" = true ]; then
            echo -e "  ${YELLOW}ℹ${NC} Your stash is intact. Run: git stash pop"
        fi
        error_exit "Failed to pull ${BASE_BRANCH}. Check your connection and try again."
    fi

    if echo "$pull_output" | grep -qi "already up to date"; then
        echo -e "  ${GREEN}✓${NC} ${HEAD_BRANCH} is already up to date with ${BASE_BRANCH}"
    else
        echo -e "  ${GREEN}✓${NC} Pulled latest ${BASE_BRANCH} into ${HEAD_BRANCH}"
    fi

    # Restore stashed changes
    if [ "$stashed" = true ]; then
        echo -e "${BLUE}  Restoring stashed changes...${NC}"
        local stash_pop_output
        stash_pop_output=$(git stash pop 2>&1)
        local stash_pop_exit=$?

        if [ $stash_pop_exit -ne 0 ]; then
            echo -e "  ${RED}✗${NC} Stash pop produced conflicts"
            echo -e "  ${YELLOW}ℹ${NC} Your stash is still intact. Resolve conflicts manually:"
            echo -e "  ${YELLOW}ℹ${NC}   git stash show -p    # view stash contents"
            echo -e "  ${YELLOW}ℹ${NC}   git stash pop        # retry after resolving"
            error_exit "Stash pop conflicts detected. Resolve manually and re-run."
        fi
        echo -e "  ${GREEN}✓${NC} Stashed changes restored"
    fi

    echo ""
}

# Get preferred editor
get_editor() {
    local editor
    editor=$(git config core.editor 2>/dev/null)
    [ -n "$editor" ] && echo "$editor" && return
    [ -n "$VISUAL" ] && echo "$VISUAL" && return
    [ -n "$EDITOR" ] && echo "$EDITOR" && return
    # Fallback to common editors
    command -v nano &>/dev/null && echo "nano" && return
    command -v vim &>/dev/null && echo "vim" && return
    command -v vi &>/dev/null && echo "vi" && return
    echo "nano"  # Final fallback
}

# Format commit message preview (truncate multi-line)
format_message_preview() {
    local msg="$1"
    local first_line
    first_line=$(echo "$msg" | head -1)
    local line_count
    line_count=$(echo "$msg" | wc -l)
    
    if [ "$line_count" -gt 1 ]; then
        echo "${first_line} (+$((line_count - 1)) more lines)"
    else
        echo "$first_line"
    fi
}

# Prompt for commit message (single-line or multi-line via editor)
get_commit_message() {
    echo -e "${YELLOW}Enter your commit message:${NC}"
    
    # If not interactive (piped input), use simple single-line mode
    if [ ! -t 0 ]; then
        read -r -p "> " COMMIT_MESSAGE
        return
    fi
    
    echo -e "  ${CYAN}1)${NC} Single line (type here)"
    echo -e "  ${CYAN}2)${NC} Multi-line (open editor)"
    echo ""
    
    local choice
    while true; do
        read -r -p "Choose (1/2): " choice
        case $choice in
            1)
                echo ""
                read -r -p "> " COMMIT_MESSAGE
                break
                ;;
            2)
                local editor
                editor=$(get_editor)
                local tmpfile
                tmpfile=$(mktemp)
                
                # Add template
                echo "" > "$tmpfile"
                echo "" >> "$tmpfile"
                echo "# Enter your commit message above." >> "$tmpfile"
                echo "# Lines starting with '#' will be ignored." >> "$tmpfile"
                
                echo -e "Opening editor (${editor})..."
                $editor "$tmpfile"
                
                # Read and clean message (remove comments and trailing whitespace)
                COMMIT_MESSAGE=$(grep -v '^#' "$tmpfile" | sed -e 's/[[:space:]]*$//' | sed '/^$/N;/^\n$/d')
                rm -f "$tmpfile"
                break
                ;;
            *)
                echo -e "${RED}Invalid choice. Enter 1 or 2.${NC}"
                ;;
        esac
    done
}

# Prompt user to link commit to an existing PR
link_to_pr() {
    local commit_msg="$1"
    
    echo ""
    echo -e "${BLUE}Fetching open pull requests...${NC}"
    
    # Get open PRs as JSON and parse them
    local pr_list
    pr_list=$(gh pr list --state open --json number,title --limit 20 2>/dev/null)
    
    if [ -z "$pr_list" ] || [ "$pr_list" = "[]" ]; then
        echo -e "  ${YELLOW}ℹ${NC} No open pull requests found"
        return 1
    fi
    
    # Parse PR numbers and titles into arrays
    local pr_numbers=()
    local pr_titles=()
    while IFS= read -r line; do
        pr_numbers+=("$line")
    done < <(echo "$pr_list" | jq -r '.[].number')
    
    while IFS= read -r line; do
        pr_titles+=("$line")
    done < <(echo "$pr_list" | jq -r '.[].title')
    
    local pr_count=${#pr_numbers[@]}
    
    echo ""
    echo -e "${YELLOW}Link this commit to an existing PR?${NC}"
    echo ""
    
    # Display PR options
    for i in "${!pr_numbers[@]}"; do
        printf "  ${CYAN}%2d)${NC} #%-4s %s\n" "$((i + 1))" "${pr_numbers[$i]}" "${pr_titles[$i]}"
    done
    echo ""
    printf "  ${CYAN}%2d)${NC} None (skip linking)\n" "0"
    echo ""
    
    # Get user selection
    local selection
    while true; do
        read -r -p "Select PR [0-${pr_count}]: " selection
        
        # Validate input
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 0 ] && [ "$selection" -le "$pr_count" ]; then
            break
        fi
        echo -e "${RED}Invalid selection. Please enter a number between 0 and ${pr_count}.${NC}"
    done
    
    # Handle selection
    if [ "$selection" -eq 0 ]; then
        echo -e "  ${YELLOW}ℹ${NC} Skipping PR link"
        return 1
    fi
    
    local selected_pr=${pr_numbers[$((selection - 1))]}
    local selected_title=${pr_titles[$((selection - 1))]}
    
    echo ""
    echo -e "${BLUE}Linking commit to PR #${selected_pr}...${NC}"
    echo -e "  ${YELLOW}⚠${NC}  Warning: This will amend the commit and change its SHA"
    
    # Store original commit hash for potential revert
    local original_hash
    original_hash=$(git rev-parse HEAD)
    
    # Amend the commit message to include PR reference
    local new_message="${commit_msg}

Part of #${selected_pr}"
    
    if ! git commit --amend -m "$new_message"; then
        echo -e "  ${RED}✗${NC} Failed to amend commit"
        echo -e "  ${YELLOW}ℹ${NC} Original commit preserved at: ${original_hash}"
        return 1
    fi
    
    echo -e "  ${GREEN}✓${NC} Commit linked to PR #${selected_pr}: ${selected_title}"
    return 0
}

# Prompt user to link an issue to the PR
# Sets global SELECTED_ISSUE variable
SELECTED_ISSUE=""
select_issue() {
    SELECTED_ISSUE=""
    
    echo ""
    echo -e "${BLUE}Fetching open issues...${NC}"
    
    # Get open issues as JSON and parse them
    local issue_list
    issue_list=$(gh issue list --state open --json number,title --limit 20 2>/dev/null)
    
    if [ -z "$issue_list" ] || [ "$issue_list" = "[]" ]; then
        echo -e "  ${YELLOW}ℹ${NC} No open issues found"
        return 1
    fi
    
    # Parse issue numbers and titles into arrays
    local issue_numbers=()
    local issue_titles=()
    while IFS= read -r line; do
        issue_numbers+=("$line")
    done < <(echo "$issue_list" | jq -r '.[].number')
    
    while IFS= read -r line; do
        issue_titles+=("$line")
    done < <(echo "$issue_list" | jq -r '.[].title')
    
    local issue_count=${#issue_numbers[@]}
    
    echo ""
    echo -e "${YELLOW}Link an issue to this PR?${NC}"
    echo ""
    
    # Display issue options
    for i in "${!issue_numbers[@]}"; do
        printf "  ${CYAN}%2d)${NC} #%-4s %s\n" "$((i + 1))" "${issue_numbers[$i]}" "${issue_titles[$i]}"
    done
    echo ""
    printf "  ${CYAN}%2d)${NC} None (skip linking)\n" "0"
    echo ""
    
    # Get user selection
    local selection
    while true; do
        read -r -p "Select issue [0-${issue_count}]: " selection
        
        # Validate input
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 0 ] && [ "$selection" -le "$issue_count" ]; then
            break
        fi
        echo -e "${RED}Invalid selection. Please enter a number between 0 and ${issue_count}.${NC}"
    done
    
    # Handle selection
    if [ "$selection" -eq 0 ]; then
        echo -e "  ${YELLOW}ℹ${NC} Skipping issue link"
        return 1
    fi
    
    SELECTED_ISSUE=${issue_numbers[$((selection - 1))]}
    local selected_title=${issue_titles[$((selection - 1))]}
    
    echo -e "  ${GREEN}✓${NC} Will link issue #${SELECTED_ISSUE}: ${selected_title}"
    return 0
}

# Main script
main() {
    # Trap for unexpected errors (inside main for source guard compatibility)
    trap 'error_exit "An unexpected error occurred."' ERR
    
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
    
    check_command "jq"
    echo -e "  ${GREEN}✓${NC} jq found"
    
    check_git_repo
    echo -e "  ${GREEN}✓${NC} Inside git repository"
    
    check_not_detached
    echo -e "  ${GREEN}✓${NC} On a valid branch"
    
    check_not_on_base_branch
    echo -e "  ${GREEN}✓${NC} Not on base branch"
    
    check_gh_auth
    echo -e "  ${GREEN}✓${NC} GitHub authenticated"
    
    check_remote
    echo -e "  ${GREEN}✓${NC} Remote 'origin' configured"

    # F1: Auto-sync dev with main before mode detection
    sync_dev_with_main

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
        COMMIT_MESSAGE=""
        get_commit_message
        commit_message="$COMMIT_MESSAGE"
        
        # Validate commit message
        if [ -z "$commit_message" ]; then
            error_exit "Commit message cannot be empty."
        fi
        
        # Flush any remaining input (handles pasted multi-line text)
        # Only flush if running interactively (not piped)
        if [ -t 0 ]; then
            read -r -t 0.1 -n 10000 discard 2>/dev/null || true
        fi
        
        # Format preview for multi-line messages
        local message_preview
        message_preview=$(format_message_preview "$commit_message")
        
        # Confirm action
        echo ""
        echo -e "${BLUE}The following actions will be performed:${NC}"
        echo -e "  1. Stage all changes (git add .)"
        echo -e "  2. Commit with message: ${CYAN}\"$message_preview\"${NC}"
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
            echo -e "  ${RED}✗${NC} Commit failed"
            echo -e "  ${YELLOW}ℹ${NC} Your changes are still staged. To unstage: git reset HEAD"
            error_exit "Commit failed. Check your commit message."
        fi
        echo -e "  ${GREEN}✓${NC} Changes committed"
        
        # Offer to link commit to existing PR
        link_to_pr "$commit_message" || true
        
        echo -e "${BLUE}Pushing to origin/${HEAD_BRANCH}...${NC}"
        local push_output
        if ! push_output=$(git push -u origin "${HEAD_BRANCH}" 2>&1); then
            if echo "$push_output" | grep -q "rejected\|non-fast-forward"; then
                echo -e "  ${RED}✗${NC} Push rejected - remote has changes you don't have locally"
                echo -e "  ${YELLOW}ℹ${NC} Try: git pull --rebase origin ${HEAD_BRANCH}"
                error_exit "Push failed due to remote changes."
            else
                echo -e "  ${RED}✗${NC} Push failed"
                echo "$push_output" >&2
                error_exit "Push failed. Check remote configuration."
            fi
        fi
        echo -e "  ${GREEN}✓${NC} Pushed to origin/${HEAD_BRANCH}"
    else
        # PR only: push if needed, then create PR
        echo -e "${BLUE}Pushing to origin/${HEAD_BRANCH}...${NC}"
        local push_output
        if ! push_output=$(git push -u origin "${HEAD_BRANCH}" 2>&1); then
            if echo "$push_output" | grep -q "Everything up-to-date"; then
                echo -e "  ${YELLOW}ℹ${NC} Already up to date"
            elif echo "$push_output" | grep -q "rejected\|non-fast-forward"; then
                echo -e "  ${RED}✗${NC} Push rejected - remote has changes you don't have locally"
                echo -e "  ${YELLOW}ℹ${NC} Try: git pull --rebase origin ${HEAD_BRANCH}"
                error_exit "Push failed due to remote changes."
            else
                echo -e "  ${YELLOW}ℹ${NC} Already up to date or pushed"
            fi
        else
            echo -e "  ${GREEN}✓${NC} Pushed to origin/${HEAD_BRANCH}"
        fi
    fi
    
    # Offer to link an issue to the PR
    select_issue || true
    
    echo -e "${BLUE}Creating pull request...${NC}"
    echo -e "${YELLOW}─────────────────────────────────────────${NC}"
    
    # Build PR create command with optional issue link
    local pr_create_failed=false
    if [ -n "$SELECTED_ISSUE" ]; then
        # Use explicit --title and --body (not --fill) for clarity
        local pr_title commit_count
        commit_count=$(git rev-list --count "${BASE_BRANCH}".."${HEAD_BRANCH}" 2>/dev/null || echo "1")
        if [ "$commit_count" -eq 1 ]; then
            pr_title=$(git log -1 --format="%s" "${HEAD_BRANCH}" 2>/dev/null)
        else
            # Multi-commit: use branch name formatted as title
            pr_title=$(echo "${HEAD_BRANCH}" | sed 's/[-_]/ /g; s/\b\w/\u&/g')
        fi
        local auto_body
        auto_body=$(git log --format="%B" "${BASE_BRANCH}".."${HEAD_BRANCH}" 2>/dev/null | head -100)
        local full_body="${auto_body}

Closes #${SELECTED_ISSUE}"
        local pr_cmd=(gh pr create --base "${BASE_BRANCH}" --head "${HEAD_BRANCH}" --title "$pr_title" --body "$full_body")
        [ "${DRAFT_PR:-false}" = true ] && pr_cmd+=(--draft)
        if ! "${pr_cmd[@]}"; then
            pr_create_failed=true
        fi
    else
        local pr_cmd=(gh pr create --base "${BASE_BRANCH}" --head "${HEAD_BRANCH}" --fill)
        [ "${DRAFT_PR:-false}" = true ] && pr_cmd+=(--draft)
        if ! "${pr_cmd[@]}"; then
            pr_create_failed=true
        fi
    fi
    
    if [ "$pr_create_failed" = true ]; then
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
    if [ -n "$SELECTED_ISSUE" ]; then
        echo -e "  • Linked to issue #${SELECTED_ISSUE} (closes on merge)"
    fi
    echo ""
    echo -e "${YELLOW}Goodbye!${NC}"
}

# Source guard: only run main when executed directly (not sourced)
# This allows tests to source the script and test functions individually
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
