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
                echo "Error: Missing value for --base"
                exit 1
            fi
            BASE_BRANCH="$2"
            shift 2
            ;;
        --head)
            if [ -z "$2" ] || [[ "$2" == --* ]]; then
                echo "Error: Missing value for --head"
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

# Create a GitHub issue after the sync step
# Sets global CREATED_ISSUE_NUMBER and CREATED_ISSUE_TITLE variables
CREATED_ISSUE_NUMBER=""
CREATED_ISSUE_TITLE=""
create_github_issue() {
    CREATED_ISSUE_NUMBER=""
    CREATED_ISSUE_TITLE=""

    # Skip in non-interactive mode
    if [ ! -t 0 ]; then
        return 0
    fi

    echo ""
    local create_issue
    read -r -p "Create a GitHub Issue? (y/N): " create_issue
    if [[ ! "$create_issue" =~ ^[Yy]$ ]]; then
        return 0
    fi

    # Prompt for issue title (single-line)
    echo ""
    echo -e "${YELLOW}Enter issue title:${NC}"
    local issue_title
    read -r -p "> " issue_title

    if [ -z "$issue_title" ]; then
        echo -e "  ${YELLOW}ℹ${NC} Skipping issue creation (empty title)"
        return 0
    fi

    # Prompt for issue body (single-line or editor, same pattern as get_commit_message)
    echo ""
    echo -e "${YELLOW}Enter issue body:${NC}"
    echo -e "  ${CYAN}1)${NC} Single line (type here)"
    echo -e "  ${CYAN}2)${NC} Multi-line (open editor)"
    echo ""

    local issue_body=""
    local choice
    while true; do
        read -r -p "Choose (1/2): " choice
        case $choice in
            1)
                echo ""
                read -r -p "> " issue_body
                break
                ;;
            2)
                local editor
                editor=$(get_editor)
                local tmpfile
                tmpfile=$(mktemp)

                # Pre-populate editor with issue template if available
                local template_file="$HOME/.config/issue-template.md"
                if [ -f "$template_file" ]; then
                    cat "$template_file" > "$tmpfile"
                else
                    echo -e "  ${YELLOW}⚠${NC}  Warning: No issue template found at ~/.config/issue-template.md. Using blank template."
                    echo "" > "$tmpfile"
                fi

                echo -e "Opening editor (${editor})..."
                $editor "$tmpfile"

                # Read and clean body (remove comments and trailing whitespace)
                issue_body=$(grep -v '^#' "$tmpfile" | sed -e 's/[[:space:]]*$//' | sed '/^$/N;/^\n$/d')
                rm -f "$tmpfile"
                break
                ;;
            *)
                echo -e "${RED}Invalid choice. Enter 1 or 2.${NC}"
                ;;
        esac
    done

    # Create the issue
    echo ""
    echo -e "${BLUE}Creating GitHub issue...${NC}"
    local issue_output
    if ! issue_output=$(gh issue create --title "$issue_title" --body "$issue_body" 2>&1); then
        echo -e "  ${RED}✗${NC} Failed to create issue"
        echo "$issue_output" >&2
        return 1
    fi

    # Extract issue number from the returned URL (e.g. https://github.com/owner/repo/issues/42)
    CREATED_ISSUE_NUMBER=$(echo "$issue_output" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+')
    CREATED_ISSUE_TITLE="$issue_title"
    echo -e "  ${GREEN}✓${NC} Issue #${CREATED_ISSUE_NUMBER} created: ${CREATED_ISSUE_TITLE}"
    return 0
}

# Check if a merge is in progress from a previous pre-PR sync attempt
# Called early in main() before mode detection to intercept MERGE_HEAD state
check_merge_in_progress() {
    local git_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null)

    # No merge in progress — nothing to do
    [ -f "${git_dir}/MERGE_HEAD" ] || return 0

    # Check for unresolved conflicts
    local unresolved
    unresolved=$(git diff --name-only --diff-filter=U 2>/dev/null)

    if [ -n "$unresolved" ]; then
        echo -e "${RED}A merge is in progress with unresolved conflicts:${NC}"
        echo ""
        while IFS= read -r file; do
            echo -e "  ${RED}•${NC} $file"
        done <<< "$unresolved"
        echo ""
        echo -e "${YELLOW}To continue:${NC}"
        echo -e "  1. Resolve the conflicts in the files listed above"
        echo -e "  2. Run: git add <resolved-file>"
        echo -e "  3. Re-run git-shipyard"
        echo ""
        error_exit "Resolve merge conflicts before continuing."
    fi

    # All conflicts resolved — complete the merge
    echo -e "${BLUE}Completing merge after conflict resolution...${NC}"
    if ! git commit --no-edit; then
        error_exit "Failed to complete merge commit."
    fi
    echo -e "  ${GREEN}✓${NC} Merge committed — ${HEAD_BRANCH} is up to date with ${BASE_BRANCH}"

    # Push the merge commit so it reaches the remote before PR creation
    echo -e "${BLUE}Pushing merge commit to origin/${HEAD_BRANCH}...${NC}"
    if ! git push origin "${HEAD_BRANCH}" 2>/dev/null; then
        error_exit "Failed to push merge commit to remote."
    fi
    echo -e "  ${GREEN}✓${NC} Merge commit pushed to remote"
    echo ""
}

# Sync HEAD_BRANCH with BASE_BRANCH before creating a PR
# Fetches latest base, merges it in; on conflict lists files and exits with instructions
# Sets global SYNC_RESULT for summary display: "synced", "up_to_date", or "skipped"
SYNC_RESULT=""
sync_with_base() {
    SYNC_RESULT=""
    echo ""
    echo -e "${BLUE}Syncing ${HEAD_BRANCH} with ${BASE_BRANCH} before PR...${NC}"

    # Fetch latest base branch from remote
    if ! git fetch origin "${BASE_BRANCH}" 2>/dev/null; then
        echo -e "  ${YELLOW}⚠${NC}  Could not fetch ${BASE_BRANCH} — skipping sync"
        SYNC_RESULT="skipped"
        return 0
    fi

    # Check if head already contains all base commits (already up to date)
    if git merge-base --is-ancestor "origin/${BASE_BRANCH}" HEAD 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} ${HEAD_BRANCH} is up to date with ${BASE_BRANCH}"
        SYNC_RESULT="up_to_date"
        return 0
    fi

    # Merge base into head to catch any new changes
    echo -e "${BLUE}Merging origin/${BASE_BRANCH} into ${HEAD_BRANCH}...${NC}"
    if ! git merge --no-ff "origin/${BASE_BRANCH}" 2>/dev/null; then
        # Collect conflicting files
        local conflict_files
        conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null)

        echo -e "  ${RED}✗${NC} Merge conflict with ${BASE_BRANCH}"
        echo ""
        echo -e "${YELLOW}Conflicting files:${NC}"
        if [ -n "$conflict_files" ]; then
            while IFS= read -r file; do
                echo -e "  ${RED}•${NC} $file"
            done <<< "$conflict_files"
        fi
        echo ""
        echo -e "${YELLOW}To resolve:${NC}"
        echo -e "  1. Resolve the conflicts in the files listed above"
        echo -e "  2. Run: git add <resolved-file>"
        echo -e "  3. Re-run git-shipyard to continue"
        echo ""
        error_exit "Merge conflicts must be resolved before creating a PR."
    fi

    echo -e "  ${GREEN}✓${NC} ${HEAD_BRANCH} is up to date with ${BASE_BRANCH}"

    # Push the merge commit to remote so the PR includes the sync changes
    echo -e "${BLUE}Pushing merge commit to origin/${HEAD_BRANCH}...${NC}"
    if ! git push origin "${HEAD_BRANCH}" 2>/dev/null; then
        error_exit "Failed to push merge commit to remote."
    fi
    echo -e "  ${GREEN}✓${NC} Merge commit pushed to remote"
    SYNC_RESULT="synced"
}

# PR Management Mode:
pr_management_mode() {
    echo ""
    echo -e "${BLUE}Fetching open pull requests...${NC}"

    local pr_list
    pr_list=$(gh pr list --state open --json number,title --limit 20 2>/dev/null)

    if [ -z "$pr_list" ] || [ "$pr_list" = "[]" ]; then
        echo -e "  ${YELLOW}ℹ${NC} No open pull requests found"
        echo ""
        echo -e "${YELLOW}Goodbye!${NC}"
        exit 0
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
    echo -e "${YELLOW}Select a pull request to squash-merge:${NC}"
    echo ""

    for i in "${!pr_numbers[@]}"; do
        printf "  ${CYAN}%2d)${NC} #%-4s %s\n" "$((i + 1))" "${pr_numbers[$i]}" "${pr_titles[$i]}"
    done
    echo ""
    printf "  ${CYAN}%2s)${NC} Exit\n" "x"
    echo ""

    local selection
    while true; do
        read -r -p "Select PR [1-${pr_count}/x]: " selection

        if [ "$selection" = "x" ] || [ "$selection" = "X" ]; then
            echo -e "${YELLOW}Operation cancelled.${NC}"
            echo -e "${YELLOW}Goodbye!${NC}"
            exit 0
        fi

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "$pr_count" ]; then
            break
        fi
        echo -e "${RED}Invalid selection. Enter a number between 1 and ${pr_count}, or 'x' to exit.${NC}"
    done

    local selected_pr=${pr_numbers[$((selection - 1))]}
    local selected_title=${pr_titles[$((selection - 1))]}

    echo ""
    echo -e "${BLUE}The following actions will be performed:${NC}"
    echo -e "  1. Squash-merge PR #${selected_pr}: ${selected_title}"
    echo -e "  2. Delete remote branch (--delete-branch)"
    echo -e "  3. Switch to ${BASE_BRANCH} and pull latest"
    echo -e "  4. Delete local head branch"
    echo ""
    echo -e "  ${YELLOW}⚠${NC}  Note: Squash-merge does not record merge history."
    echo -e "       If you keep the branch and merge again, duplicate conflicts may arise."
    echo ""

    read -r -p "Proceed? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        echo -e "${YELLOW}Goodbye!${NC}"
        exit 0
    fi

    echo ""

    # Resolve the PR's head branch name before merging (for local cleanup)
    local pr_head_branch
    pr_head_branch=$(gh pr view "$selected_pr" --json headRefName -q '.headRefName' 2>/dev/null)

    # Squash-merge the PR (also deletes the remote branch)
    echo -e "${BLUE}Squash-merging PR #${selected_pr}...${NC}"
    local merge_output
    if ! merge_output=$(gh pr merge "$selected_pr" --squash --delete-branch 2>&1); then
        if echo "$merge_output" | grep -qi "conflict\|merge conflict"; then
            echo -e "  ${RED}✗${NC} Merge conflict detected — resolve manually and retry"
        else
            echo -e "  ${RED}✗${NC} Merge failed"
            echo "$merge_output" >&2
        fi
        error_exit "Failed to merge PR #${selected_pr}."
    fi
    echo -e "  ${GREEN}✓${NC} PR #${selected_pr} squash-merged and remote branch deleted"

    # Switch to base branch and pull latest
    echo -e "${BLUE}Switching to ${BASE_BRANCH} and pulling...${NC}"
    if ! git checkout "$BASE_BRANCH" 2>/dev/null; then
        echo -e "  ${YELLOW}⚠${NC}  Could not switch to ${BASE_BRANCH} automatically"
    else
        if ! git pull origin "$BASE_BRANCH" 2>/dev/null; then
            echo -e "  ${YELLOW}⚠${NC}  Could not pull latest ${BASE_BRANCH}"
        else
            echo -e "  ${GREEN}✓${NC} Switched to ${BASE_BRANCH} and pulled latest"
        fi
    fi

    # Delete local head branch if it still exists
    local branch_deleted=false
    if [ -n "$pr_head_branch" ] && git show-ref --verify --quiet "refs/heads/$pr_head_branch"; then
        echo -e "${BLUE}Deleting local branch '${pr_head_branch}'...${NC}"
        if ! git branch -d "$pr_head_branch" 2>/dev/null; then
            echo -e "  ${YELLOW}⚠${NC}  Could not delete local branch '${pr_head_branch}'"
            echo -e "  ${YELLOW}ℹ${NC} To force delete: git branch -D ${pr_head_branch}"
        else
            echo -e "  ${GREEN}✓${NC} Local branch '${pr_head_branch}' deleted"
            branch_deleted=true
        fi
    fi

    # Success message
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     ✓ All actions completed!           ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Summary:${NC}"
    echo -e "  • PR #${selected_pr} squash-merged: ${selected_title}"
    echo -e "  • Remote branch deleted"
    if [ "$branch_deleted" = true ]; then
        echo -e "  • Local branch '${pr_head_branch}' cleaned up"
    fi
    echo -e "  • ${BASE_BRANCH} updated with latest changes"
    echo ""
    echo -e "${YELLOW}Goodbye!${NC}"
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
    
    check_gh_auth
    echo -e "  ${GREEN}✓${NC} GitHub authenticated"
    
    check_remote
    echo -e "  ${GREEN}✓${NC} Remote 'origin' configured"

    # Check for an in-progress merge from a prior sync attempt (before mode detection)
    check_merge_in_progress

    # Determine workflow mode
    local mode=""
    if has_uncommitted_changes; then
        mode="full"
        echo -e "  ${GREEN}✓${NC} Uncommitted changes detected"
    elif has_commits_ahead; then
        mode="pr_only"
        echo -e "  ${GREEN}✓${NC} Commits ahead of ${BASE_BRANCH} (already committed)"
    else
        mode="pr_management"
        echo -e "  ${GREEN}✓${NC} Clean working tree — entering PR Management Mode"
    fi

    # Only enforce non-base-branch for modes that operate on the current branch
    if [ "$mode" != "pr_management" ]; then
        check_not_on_base_branch
        echo -e "  ${GREEN}✓${NC} Not on base branch"
    fi

    echo ""

    if [ "$mode" = "pr_management" ]; then
        pr_management_mode
        return
    fi
    
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
        echo -e "  4. Sync with ${BASE_BRANCH} (merge any new changes)"
        echo -e "  5. Create PR from ${HEAD_BRANCH} → ${BASE_BRANCH}"
    else
        # PR only mode
        echo -e "${BLUE}The following actions will be performed:${NC}"
        echo -e "  1. Push to origin/${HEAD_BRANCH} (if needed)"
        echo -e "  2. Sync with ${BASE_BRANCH} (merge any new changes)"
        echo -e "  3. Create PR from ${HEAD_BRANCH} → ${BASE_BRANCH}"
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

    # Pre-PR sync: merge base branch into head to ensure a clean merge
    sync_with_base

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

    # Offer to create a new GitHub issue
    create_github_issue || true

    # Success message
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     ✓ All actions completed!           ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Summary:${NC}"
    if [ "$mode" = "full" ]; then
        echo -e "  • Changes staged and committed"
    fi
    echo -e "  • Pushed to origin/${HEAD_BRANCH}"
    if [ "$SYNC_RESULT" = "synced" ]; then
        echo -e "  • Synced ${HEAD_BRANCH} with ${BASE_BRANCH} (merged new changes)"
    elif [ "$SYNC_RESULT" = "up_to_date" ]; then
        echo -e "  • Synced ${HEAD_BRANCH} with ${BASE_BRANCH} (already up to date)"
    fi
    echo -e "  • Pull request created (${HEAD_BRANCH} → ${BASE_BRANCH})"
    if [ -n "$SELECTED_ISSUE" ]; then
        echo -e "  • Linked to issue #${SELECTED_ISSUE} (closes on merge)"
    fi
    if [ -n "$CREATED_ISSUE_NUMBER" ]; then
        echo -e "  • Created issue #${CREATED_ISSUE_NUMBER}: ${CREATED_ISSUE_TITLE}"
    fi
    echo ""
    echo -e "${YELLOW}Goodbye!${NC}"
}

# Source guard: only run main when executed directly (not sourced)
# This allows tests to source the script and test functions individually
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
