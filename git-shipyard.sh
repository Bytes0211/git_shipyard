#!/usr/bin/env bash
#
# Git Shipyard
# Interactive script to stage, commit, push, and create a PR in one step
#

set -o pipefail

# Branch configuration (can be overridden with --base and --head)
BASE_BRANCH="main"
HEAD_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --base)
            if [ -z "$2" ] || [[ "$2" == --* ]]; then
                echo "❌ Error: Missing value for --base"
                exit 1
            fi
            BASE_BRANCH="$2"
            shift 2
            ;;
        --head)
            if [ -z "$2" ] || [[ "$2" == --* ]]; then
                echo "❌ Error: Missing value for --head"
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
            echo "  --head   Head branch for PR (default: current branch)"
            echo "  --draft  Create PR as draft"
            exit 0
            ;;
        *)
            echo "❌ Unknown option: $1"
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
    echo -e "\n❌ ${RED}Error: $1${NC}" >&2
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║        👋 Goodbye! See you later!        ║"
    echo "╚══════════════════════════════════════════╝"
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

# Check if there are open PRs for the current head branch
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
    echo -e "✏️  ${YELLOW}Enter your commit message:${NC}"

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
                echo -e "❌ ${RED}Invalid choice. Enter 1 or 2.${NC}"
                ;;
        esac
    done
}

# Prompt user to link commit to an existing PR
link_to_pr() {
    local commit_msg="$1"

    echo ""
    echo -e "📡 ${BLUE}Fetching open pull requests...${NC}"

    # Get open PRs as JSON and parse them
    local pr_list
    pr_list=$(gh pr list --state open --json number,title --limit 20 2>/dev/null)

    if [ -z "$pr_list" ] || [ "$pr_list" = "[]" ]; then
        echo -e "  ℹ️  No open pull requests found"
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
    echo -e "🔗 ${YELLOW}Link this commit to an existing PR?${NC}"
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
        read -r -p "🔢 Select PR [0-${pr_count}]: " selection

        # Validate input
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 0 ] && [ "$selection" -le "$pr_count" ]; then
            break
        fi
        echo -e "❌ ${RED}Invalid selection. Please enter a number between 0 and ${pr_count}.${NC}"
    done

    # Handle selection
    if [ "$selection" -eq 0 ]; then
        echo -e "  ℹ️  Skipping PR link"
        return 1
    fi

    local selected_pr=${pr_numbers[$((selection - 1))]}
    local selected_title=${pr_titles[$((selection - 1))]}

    echo ""
    echo -e "🔗 ${BLUE}Linking commit to PR #${selected_pr}...${NC}"
    echo -e "  ⚠️  Warning: This will amend the commit and change its SHA"

    # Store original commit hash for potential revert
    local original_hash
    original_hash=$(git rev-parse HEAD)

    # Amend the commit message to include PR reference
    local new_message="${commit_msg}

Part of #${selected_pr}"

    if ! git commit --amend -m "$new_message"; then
        echo -e "  ❌ Failed to amend commit"
        echo -e "  ℹ️  Original commit preserved at: ${original_hash}"
        return 1
    fi

    echo -e "  ✅ Commit linked to PR #${selected_pr}: ${selected_title}"
    return 0
}

# Prompt user to link an issue to the PR
# Sets global SELECTED_ISSUE variable
# When issues exist: display list and let user pick one or skip
# When no issues exist: offer to create a new issue to link to the PR
SELECTED_ISSUE=""
SELECTED_ISSUE_TITLE=""
CREATED_ISSUE_FOR_PR=""
select_issue() {
    SELECTED_ISSUE=""
    SELECTED_ISSUE_TITLE=""
    CREATED_ISSUE_FOR_PR=""

    echo ""
    echo -e "📡 ${BLUE}Fetching open issues...${NC}"

    # Get open issues as JSON and parse them
    local issue_list
    issue_list=$(gh issue list --state open --json number,title --limit 20 2>/dev/null)

    if [ -z "$issue_list" ] || [ "$issue_list" = "[]" ]; then
        echo -e "  ℹ️  No open issues found"

        # Skip creation prompt in non-interactive mode
        if [ ! -t 0 ]; then
            return 1
        fi

        # Offer to create a new issue to link to the PR
        echo ""
        local create_issue
        read -r -p "🌱 Create a new issue to link to this PR? (y/N): " create_issue
        if [[ ! "$create_issue" =~ ^[Yy]$ ]]; then
            echo -e "  ℹ️  Skipping issue link"
            return 1
        fi

        _create_issue_for_pr
        return $?
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
    echo -e "🔗 ${YELLOW}Link an issue to this PR?${NC}"
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
        read -r -p "🔢 Select issue [0-${issue_count}]: " selection

        # Validate input
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 0 ] && [ "$selection" -le "$issue_count" ]; then
            break
        fi
        echo -e "❌ ${RED}Invalid selection. Please enter a number between 0 and ${issue_count}.${NC}"
    done

    # Handle selection
    if [ "$selection" -eq 0 ]; then
        echo -e "  ℹ️  Skipping issue link"
        return 1
    fi

    SELECTED_ISSUE=${issue_numbers[$((selection - 1))]}
    SELECTED_ISSUE_TITLE=${issue_titles[$((selection - 1))]}

    echo -e "  ✅ Will link issue #${SELECTED_ISSUE}: ${SELECTED_ISSUE_TITLE}"
    return 0
}

# Internal helper: create a new GitHub issue and set SELECTED_ISSUE
# Called by select_issue() when no open issues exist
_create_issue_for_pr() {
    # Prompt for issue title
    echo ""
    echo -e "✏️  ${YELLOW}Enter issue title:${NC}"
    local issue_title
    read -r -p "> " issue_title

    if [ -z "$issue_title" ]; then
        echo -e "  ℹ️  Skipping issue creation (empty title)"
        return 1
    fi

    # Prompt for issue body
    echo ""
    echo -e "✏️  ${YELLOW}Enter issue body:${NC}"
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

                local template_file="$HOME/.config/issue-template.md"
                if [ -f "$template_file" ]; then
                    cat "$template_file" > "$tmpfile"
                else
                    echo -e "  ⚠️  Warning: No issue template found at ~/.config/issue-template.md. Using blank template."
                    echo "" > "$tmpfile"
                fi

                echo -e "Opening editor (${editor})..."
                $editor "$tmpfile"

                issue_body=$(grep -v '^#' "$tmpfile" | sed -e 's/[[:space:]]*$//' | sed '/^$/N;/^\n$/d')
                rm -f "$tmpfile"
                break
                ;;
            *)
                echo -e "❌ ${RED}Invalid choice. Enter 1 or 2.${NC}"
                ;;
        esac
    done

    # Create the issue
    echo ""
    echo -e "🌱 ${BLUE}Creating GitHub issue...${NC}"
    local issue_output
    if ! issue_output=$(gh issue create --title "$issue_title" --body "$issue_body" 2>&1); then
        echo -e "  ❌ Failed to create issue"
        echo "$issue_output" >&2
        return 1
    fi

    # Extract issue number from the returned URL
    SELECTED_ISSUE=$(echo "$issue_output" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+')
    SELECTED_ISSUE_TITLE="$issue_title"
    CREATED_ISSUE_FOR_PR="$issue_title"
    echo -e "  ✅ Issue #${SELECTED_ISSUE} created: ${issue_title}"
    echo -e "  ✅ Will link issue #${SELECTED_ISSUE} to this PR"
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
        echo -e "❌ ${RED}A merge is in progress with unresolved conflicts:${NC}"
        echo ""
        while IFS= read -r file; do
            echo -e "  ❌ $file"
        done <<< "$unresolved"
        echo ""
        echo -e "👉 ${YELLOW}To continue:${NC}"
        echo -e "  1. Resolve the conflicts in the files listed above"
        echo -e "  2. Run: git add <resolved-file>"
        echo -e "  3. Re-run git-shipyard"
        echo ""
        error_exit "Resolve merge conflicts before continuing."
    fi

    # All conflicts resolved — complete the merge
    echo -e "🔀 ${BLUE}Completing merge after conflict resolution...${NC}"
    if ! git commit --no-edit; then
        error_exit "Failed to complete merge commit."
    fi
    echo -e "  ✅ Merge committed — ${HEAD_BRANCH} is up to date with ${BASE_BRANCH}"

    # Push the merge commit so it reaches the remote before PR creation
    echo -e "🚀 ${BLUE}Pushing merge commit to origin/${HEAD_BRANCH}...${NC}"
    if ! git push origin "${HEAD_BRANCH}" 2>/dev/null; then
        error_exit "Failed to push merge commit to remote."
    fi
    echo -e "  ✅ Merge commit pushed to remote"
    echo ""
}

# Sync HEAD_BRANCH with BASE_BRANCH before creating a PR
# Fetches latest base, merges it in; on conflict lists files and exits with instructions
# Sets global SYNC_RESULT for summary display: "synced", "up_to_date", or "skipped"
SYNC_RESULT=""
sync_with_base() {
    SYNC_RESULT=""
    echo ""
    echo -e "🔄 ${BLUE}Syncing ${HEAD_BRANCH} with ${BASE_BRANCH} before PR...${NC}"

    # Fetch latest base branch from remote
    if ! git fetch origin "${BASE_BRANCH}" 2>/dev/null; then
        echo -e "  ⚠️  Could not fetch ${BASE_BRANCH} — skipping sync"
        SYNC_RESULT="skipped"
        return 0
    fi

    # Check if head already contains all base commits (already up to date)
    if git merge-base --is-ancestor "origin/${BASE_BRANCH}" HEAD 2>/dev/null; then
        echo -e "  ✅ ${HEAD_BRANCH} is up to date with ${BASE_BRANCH}"
        SYNC_RESULT="up_to_date"
        return 0
    fi

    # Merge base into head to catch any new changes
    echo -e "🔀 ${BLUE}Merging origin/${BASE_BRANCH} into ${HEAD_BRANCH}...${NC}"
    if ! git merge --no-ff "origin/${BASE_BRANCH}" 2>/dev/null; then
        # Collect conflicting files
        local conflict_files
        conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null)

        echo -e "  ❌ Merge conflict with ${BASE_BRANCH}"
        echo ""
        echo -e "⚠️  ${YELLOW}Conflicting files:${NC}"
        if [ -n "$conflict_files" ]; then
            while IFS= read -r file; do
                echo -e "  ❌ $file"
            done <<< "$conflict_files"
        fi
        echo ""
        echo -e "👉 ${YELLOW}To resolve:${NC}"
        echo -e "  1. Resolve the conflicts in the files listed above"
        echo -e "  2. Run: git add <resolved-file>"
        echo -e "  3. Re-run git-shipyard to continue"
        echo ""
        error_exit "Merge conflicts must be resolved before creating a PR."
    fi

    echo -e "  ✅ ${HEAD_BRANCH} is up to date with ${BASE_BRANCH}"

    # Push the merge commit to remote so the PR includes the sync changes
    echo -e "🚀 ${BLUE}Pushing merge commit to origin/${HEAD_BRANCH}...${NC}"
    if ! git push origin "${HEAD_BRANCH}" 2>/dev/null; then
        error_exit "Failed to push merge commit to remote."
    fi
    echo -e "  ✅ Merge commit pushed to remote"
    SYNC_RESULT="synced"
}

# Reset local head branch: pull latest base branch, recreate head branch
reset_head_environment() {
    # Skip if HEAD_BRANCH is the same as BASE_BRANCH (nothing to reset)
    if [ "$HEAD_BRANCH" = "$BASE_BRANCH" ]; then
        return 0
    fi

    echo ""
    echo -e "🔄 ${BLUE}Resetting local ${HEAD_BRANCH} environment...${NC}"

    local current_branch
    current_branch=$(git symbolic-ref --short HEAD 2>/dev/null)

    # Switch to base branch if not already on it
    if [ "$current_branch" != "$BASE_BRANCH" ]; then
        echo -e "🔄 ${BLUE}Switching to ${BASE_BRANCH}...${NC}"
        if ! git checkout "$BASE_BRANCH" 2>/dev/null; then
            error_exit "Could not switch to ${BASE_BRANCH}."
        fi
        echo -e "  ✅ Switched to ${BASE_BRANCH}"
    fi

    # Pull latest base branch
    echo -e "📡 ${BLUE}Pulling latest ${BASE_BRANCH}...${NC}"
    if ! git pull origin "$BASE_BRANCH" 2>/dev/null; then
        echo -e "  ⚠️  Could not pull latest ${BASE_BRANCH}"
    else
        echo -e "  ✅ ${BASE_BRANCH} is up to date"
    fi

    # Delete local head branch if it exists
    if git show-ref --verify --quiet "refs/heads/$HEAD_BRANCH"; then
        echo -e "🗑️  ${BLUE}Deleting local branch '${HEAD_BRANCH}'...${NC}"
        if ! git branch -D "$HEAD_BRANCH" 2>/dev/null; then
            error_exit "Could not delete local branch '${HEAD_BRANCH}'."
        fi
        echo -e "  ✅ Local branch '${HEAD_BRANCH}' deleted"
    fi

    # Create fresh head branch from base
    echo -e "🌱 ${BLUE}Creating fresh ${HEAD_BRANCH} from ${BASE_BRANCH}...${NC}"
    if ! git checkout -b "$HEAD_BRANCH" 2>/dev/null; then
        error_exit "Could not create branch '${HEAD_BRANCH}'."
    fi
    echo -e "  ✅ Fresh ${HEAD_BRANCH} created from ${BASE_BRANCH}"
}

# View PR details and comments
view_pr_details() {
    local pr_number="$1"

    echo ""
    echo -e "📡 ${BLUE}Fetching PR #${pr_number} details...${NC}"
    echo -e "${YELLOW}─────────────────────────────────────────${NC}"

    # Fetch PR metadata as JSON
    local pr_json
    pr_json=$(gh pr view "$pr_number" --json title,body,state,author,labels,createdAt,headRefName,baseRefName,additions,deletions,changedFiles 2>/dev/null)

    if [ -z "$pr_json" ]; then
        echo -e "  ❌ Could not fetch PR details"
        return 1
    fi

    # Parse fields
    local pr_title pr_state pr_author pr_created pr_head pr_base pr_body
    local pr_additions pr_deletions pr_changed_files pr_labels
    pr_title=$(echo "$pr_json" | jq -r '.title')
    pr_state=$(echo "$pr_json" | jq -r '.state')
    pr_author=$(echo "$pr_json" | jq -r '.author.login')
    pr_created=$(echo "$pr_json" | jq -r '.createdAt' | cut -d'T' -f1)
    pr_head=$(echo "$pr_json" | jq -r '.headRefName')
    pr_base=$(echo "$pr_json" | jq -r '.baseRefName')
    pr_body=$(echo "$pr_json" | jq -r '.body // "(no description)"')
    pr_additions=$(echo "$pr_json" | jq -r '.additions')
    pr_deletions=$(echo "$pr_json" | jq -r '.deletions')
    pr_changed_files=$(echo "$pr_json" | jq -r '.changedFiles')
    pr_labels=$(echo "$pr_json" | jq -r '.labels[].name' 2>/dev/null | paste -sd', ' -)

    echo ""
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
    echo ""
    echo -e "${YELLOW}─────────────────────────────────────────${NC}"

    # Fetch and display comments
    echo ""
    echo -e "📡 ${BLUE}Fetching comments...${NC}"

    local comments_json
    comments_json=$(gh pr view "$pr_number" --json comments --jq '.comments' 2>/dev/null)

    if [ -z "$comments_json" ] || [ "$comments_json" = "[]" ] || [ "$comments_json" = "null" ]; then
        echo -e "  ℹ️  No comments on this PR"
    else
        local comment_count
        comment_count=$(echo "$comments_json" | jq 'length')
        echo -e "  💬 ${GREEN}${comment_count} comment(s)${NC}"
        echo ""

        # Iterate over each comment
        local i=0
        while [ "$i" -lt "$comment_count" ]; do
            local author body created_at
            author=$(echo "$comments_json" | jq -r ".[$i].author.login")
            body=$(echo "$comments_json" | jq -r ".[$i].body")
            created_at=$(echo "$comments_json" | jq -r ".[$i].createdAt" | cut -d'T' -f1)

            echo -e "  ${CYAN}${author}${NC} (${created_at}):"
            echo "$body" | sed 's/^/    /'
            echo ""
            ((i++))
        done
    fi

    # Fetch and display review comments (inline code review comments)
    local reviews_json
    reviews_json=$(gh pr view "$pr_number" --json reviews --jq '.reviews' 2>/dev/null)

    if [ -n "$reviews_json" ] && [ "$reviews_json" != "[]" ] && [ "$reviews_json" != "null" ]; then
        local review_count
        review_count=$(echo "$reviews_json" | jq '[.[] | select(.body != "")] | length')

        if [ "$review_count" -gt 0 ]; then
            echo -e "📝 ${BLUE}Reviews:${NC}"
            echo ""

            local j=0
            local total_reviews
            total_reviews=$(echo "$reviews_json" | jq 'length')
            while [ "$j" -lt "$total_reviews" ]; do
                local rev_author rev_state rev_body rev_date
                rev_author=$(echo "$reviews_json" | jq -r ".[$j].author.login")
                rev_state=$(echo "$reviews_json" | jq -r ".[$j].state")
                rev_body=$(echo "$reviews_json" | jq -r ".[$j].body")
                rev_date=$(echo "$reviews_json" | jq -r ".[$j].submittedAt" | cut -d'T' -f1)

                # Color-code review state
                local state_color="$YELLOW"
                case "$rev_state" in
                    APPROVED) state_color="$GREEN" ;;
                    CHANGES_REQUESTED) state_color="$RED" ;;
                    COMMENTED) state_color="$CYAN" ;;
                esac

                echo -e "  ${CYAN}${rev_author}${NC} — ${state_color}${rev_state}${NC} (${rev_date})"
                if [ -n "$rev_body" ] && [ "$rev_body" != "" ]; then
                    echo "$rev_body" | sed 's/^/    /'
                fi
                echo ""
                ((j++))
            done
        fi
    fi

    echo -e "${YELLOW}─────────────────────────────────────────${NC}"

    # Action prompt after viewing details
    echo ""
    echo -e "📋 ${YELLOW}Actions:${NC}"
    echo ""
    echo -e "  ${CYAN}1)${NC} 🔀 Merge & clean up"
    echo -e "  ${CYAN}2)${NC} 👈 Back"
    echo ""

    local view_action
    while true; do
        read -r -p "🔢 Choose action [1-2]: " view_action
        case "$view_action" in
            1)
                echo ""
                echo -e "📝 ${BLUE}The following actions will be performed:${NC}"
                echo -e "  1. Close PR #${pr_number} (via merge)"
                echo -e "  2. Merge ${pr_head} into ${pr_base} on GitHub"
                echo -e "  3. Delete remote branch '${pr_head}'"
                echo -e "  4. Delete local branch '${pr_head}'"
                echo -e "  5. Pull ${pr_base} from GitHub into local ${pr_base}"
                echo ""

                read -r -p "⚠️  Proceed? (y/N): " confirm
                if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    echo -e "🚫 ${YELLOW}Operation cancelled.${NC}"
                    return 0
                fi

                echo ""

                # Step 1 & 2 & 3: Merge the PR on GitHub (closes it), delete remote branch
                echo -e "🔀 ${BLUE}Merging PR #${pr_number} (${pr_head} → ${pr_base})...${NC}"
                local merge_output
                if ! merge_output=$(gh pr merge "$pr_number" --merge --delete-branch 2>&1); then
                    if echo "$merge_output" | grep -qi "conflict\|merge conflict"; then
                        echo -e "  ❌ Merge conflict detected — resolve manually and retry"
                    else
                        echo -e "  ❌ Merge failed"
                        echo "$merge_output" >&2
                    fi
                    error_exit "Failed to merge PR #${pr_number}."
                fi
                echo -e "  ✅ PR #${pr_number} merged and closed"
                echo -e "  ✅ Remote branch '${pr_head}' deleted"

                # Step 5: Switch to base branch and pull latest
                echo -e "🔄 ${BLUE}Switching to ${pr_base} and pulling latest...${NC}"
                if ! git checkout "$pr_base" 2>/dev/null; then
                    echo -e "  ⚠️  Could not switch to ${pr_base} automatically"
                else
                    if ! git pull origin "$pr_base" 2>/dev/null; then
                        echo -e "  ⚠️  Could not pull latest ${pr_base}"
                    else
                        echo -e "  ✅ Switched to ${pr_base} and pulled latest"
                    fi
                fi

                # Step 4: Delete local head branch if it exists
                local local_branch_deleted=false
                if git show-ref --verify --quiet "refs/heads/$pr_head"; then
                    echo -e "🗑️  ${BLUE}Deleting local branch '${pr_head}'...${NC}"
                    if ! git branch -d "$pr_head" 2>/dev/null; then
                        echo -e "  ⚠️  Could not delete local branch '${pr_head}'"
                        echo -e "  👉 To force delete: git branch -D ${pr_head}"
                    else
                        echo -e "  ✅ Local branch '${pr_head}' deleted"
                        local_branch_deleted=true
                    fi
                fi

                # Summary
                echo ""
                echo "╔══════════════════════════════════════════╗"
                echo "║     🎉 All actions completed!            ║"
                echo "╚══════════════════════════════════════════╝"
                echo ""
                echo -e "📝 ${CYAN}Summary:${NC}"
                echo -e "  • PR #${pr_number} merged and closed: ${pr_title}"
                echo -e "  • Remote branch '${pr_head}' deleted"
                if [ "$local_branch_deleted" = true ]; then
                    echo -e "  • Local branch '${pr_head}' deleted"
                fi
                echo -e "  • ${pr_base} updated with latest changes"
                echo ""

                # Return 2 to signal callers that merge & cleanup was performed
                return 2
                ;;
            2)
                return 0
                ;;
            *)
                echo -e "❌ ${RED}Invalid choice. Enter 1 or 2.${NC}"
                ;;
        esac
    done
}

# Close a PR without merging
close_pr() {
    local pr_number="$1"
    local pr_title="$2"

    echo ""
    echo -e "⚠️  ${YELLOW}Close PR #${pr_number}: ${pr_title}?${NC}"
    echo ""
    echo -e "  ⚠️  This will close the PR without merging."
    echo ""

    # Ask whether to also delete the branch
    local delete_branch="n"
    read -r -p "🗑️  Also delete the remote branch? (y/N): " delete_branch
    echo ""

    read -r -p "⚠️  Proceed with closing PR? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "🚫 ${YELLOW}Operation cancelled.${NC}"
        return 0
    fi

    echo ""
    echo -e "🔒 ${BLUE}Closing PR #${pr_number}...${NC}"

    local close_cmd=(gh pr close "$pr_number")
    if [[ "$delete_branch" =~ ^[Yy]$ ]]; then
        close_cmd+=(--delete-branch)
    fi

    local close_output
    if ! close_output=$("${close_cmd[@]}" 2>&1); then
        echo -e "  ❌ Failed to close PR"
        echo "$close_output" >&2
        return 1
    fi
    echo -e "  ✅ PR #${pr_number} closed"

    if [[ "$delete_branch" =~ ^[Yy]$ ]]; then
        echo -e "  ✅ Remote branch deleted"
    fi

    # Clean up local branch if it exists
    local pr_head_branch
    pr_head_branch=$(gh pr view "$pr_number" --json headRefName -q '.headRefName' 2>/dev/null)

    if [ -n "$pr_head_branch" ] && git show-ref --verify --quiet "refs/heads/$pr_head_branch"; then
        echo ""
        local delete_local
        read -r -p "🗑️  Delete local branch '${pr_head_branch}'? (y/N): " delete_local
        if [[ "$delete_local" =~ ^[Yy]$ ]]; then
            if ! git branch -d "$pr_head_branch" 2>/dev/null; then
                echo -e "  ⚠️  Could not delete local branch '${pr_head_branch}'"
                echo -e "  👉 To force delete: git branch -D ${pr_head_branch}"
            else
                echo -e "  ✅ Local branch '${pr_head_branch}' deleted"
            fi
        fi
    fi

    # Success
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║       🎉 PR closed successfully!         ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    echo -e "📝 ${CYAN}Summary:${NC}"
    echo -e "  • PR #${pr_number} closed: ${pr_title}"
    if [[ "$delete_branch" =~ ^[Yy]$ ]]; then
        echo -e "  • Remote branch deleted"
    fi
    echo ""
    return 0
}

# Squash-merge a PR (extracted from original pr_management_mode)
squash_merge_pr() {
    local pr_number="$1"
    local pr_title="$2"

    echo ""
    echo -e "📝 ${BLUE}The following actions will be performed:${NC}"
    echo -e "  1. Squash-merge PR #${pr_number}: ${pr_title}"
    echo -e "  2. Delete remote branch (--delete-branch)"
    echo -e "  3. Switch to ${BASE_BRANCH} and pull latest"
    echo -e "  4. Delete local head branch"
    echo ""
    echo -e "  ⚠️  Note: Squash-merge does not record merge history."
    echo -e "       If you keep the branch and merge again, duplicate conflicts may arise."
    echo ""

    read -r -p "⚠️  Proceed? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "🚫 ${YELLOW}Operation cancelled.${NC}"
        return 0
    fi

    echo ""

    # Resolve the PR's head branch name before merging (for local cleanup)
    local pr_head_branch
    pr_head_branch=$(gh pr view "$pr_number" --json headRefName -q '.headRefName' 2>/dev/null)

    # Squash-merge the PR (also deletes the remote branch)
    echo -e "🔀 ${BLUE}Squash-merging PR #${pr_number}...${NC}"
    local merge_output
    if ! merge_output=$(gh pr merge "$pr_number" --squash --delete-branch 2>&1); then
        if echo "$merge_output" | grep -qi "conflict\|merge conflict"; then
            echo -e "  ❌ Merge conflict detected — resolve manually and retry"
        else
            echo -e "  ❌ Merge failed"
            echo "$merge_output" >&2
        fi
        error_exit "Failed to merge PR #${pr_number}."
    fi
    echo -e "  ✅ PR #${pr_number} squash-merged and remote branch deleted"

    # Switch to base branch and pull latest
    echo -e "🔄 ${BLUE}Switching to ${BASE_BRANCH} and pulling...${NC}"
    if ! git checkout "$BASE_BRANCH" 2>/dev/null; then
        echo -e "  ⚠️  Could not switch to ${BASE_BRANCH} automatically"
    else
        if ! git pull origin "$BASE_BRANCH" 2>/dev/null; then
            echo -e "  ⚠️  Could not pull latest ${BASE_BRANCH}"
        else
            echo -e "  ✅ Switched to ${BASE_BRANCH} and pulled latest"
        fi
    fi

    # Delete local head branch if it still exists
    local branch_deleted=false
    if [ -n "$pr_head_branch" ] && git show-ref --verify --quiet "refs/heads/$pr_head_branch"; then
        echo -e "🗑️  ${BLUE}Deleting local branch '${pr_head_branch}'...${NC}"
        if ! git branch -d "$pr_head_branch" 2>/dev/null; then
            echo -e "  ⚠️  Could not delete local branch '${pr_head_branch}'"
            echo -e "  👉 To force delete: git branch -D ${pr_head_branch}"
        else
            echo -e "  ✅ Local branch '${pr_head_branch}' deleted"
            branch_deleted=true
        fi
    fi

    # Reset head branch after successful merge
    reset_head_environment

    # Success message
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║     🎉 All actions completed!            ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    echo -e "📝 ${CYAN}Summary:${NC}"
    echo -e "  • PR #${pr_number} squash-merged: ${pr_title}"
    echo -e "  • Remote branch deleted"
    if [ "$branch_deleted" = true ]; then
        echo -e "  • Local branch '${pr_head_branch}' cleaned up"
    fi
    echo -e "  • ${BASE_BRANCH} updated with latest changes"
    echo ""
    return 0
}

# View and manage issues linked to a PR
view_linked_issues() {
    local pr_number="$1"

    echo ""
    echo -e "📡 ${BLUE}Fetching linked issues for PR #${pr_number}...${NC}"

    # Fetch PR body to parse for issue references
    local pr_body
    pr_body=$(gh pr view "$pr_number" --json body -q '.body' 2>/dev/null)

    # Parse for issue references: Closes #N, Fixes #N, Resolves #N, Part of #N
    local issue_refs=()
    if [ -n "$pr_body" ]; then
        while IFS= read -r ref; do
            # Avoid duplicates
            local already_found=false
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
    fi

    if [ ${#issue_refs[@]} -eq 0 ]; then
        echo -e "  ℹ️  No linked issues found in PR body"
        echo ""
        echo -e "  👉 ${CYAN}Tip:${NC} Issues are detected from the PR description using keywords like:"
        echo -e "       ${CYAN}Closes #N${NC}, ${CYAN}Fixes #N${NC}, ${CYAN}Resolves #N${NC}, ${CYAN}Part of #N${NC}"
        return 0
    fi

    echo -e "  ✅ Found ${#issue_refs[@]} linked issue(s)"
    echo ""

    # Fetch details for each linked issue
    local issue_numbers=()
    local issue_titles=()
    local issue_states=()
    for ref in "${issue_refs[@]}"; do
        local issue_json
        issue_json=$(gh issue view "$ref" --json number,title,state 2>/dev/null)
        if [ -n "$issue_json" ]; then
            local i_number i_title i_state
            i_number=$(echo "$issue_json" | jq -r '.number')
            i_title=$(echo "$issue_json" | jq -r '.title')
            i_state=$(echo "$issue_json" | jq -r '.state')
            issue_numbers+=("$i_number")
            issue_titles+=("$i_title")
            issue_states+=("$i_state")
        fi
    done

    if [ ${#issue_numbers[@]} -eq 0 ]; then
        echo -e "  ℹ️  Could not fetch details for linked issues"
        return 0
    fi

    # Display linked issues with state
    echo -e "📋 ${YELLOW}Linked issues:${NC}"
    echo ""
    for i in "${!issue_numbers[@]}"; do
        local state_color="$GREEN"
        if [ "${issue_states[$i]}" = "CLOSED" ]; then
            state_color="$RED"
        fi
        printf "  ${CYAN}%2d)${NC} #%-4s [${state_color}%s${NC}] %s\n" "$((i + 1))" "${issue_numbers[$i]}" "${issue_states[$i]}" "${issue_titles[$i]}"
    done
    echo ""

    # Check if there are any open issues to close
    local has_open=false
    for state in "${issue_states[@]}"; do
        if [ "$state" = "OPEN" ]; then
            has_open=true
            break
        fi
    done

    if [ "$has_open" = false ]; then
        echo -e "  ℹ️  All linked issues are already closed"
        return 0
    fi

    # Offer to close open issues
    echo -e "🔒 ${YELLOW}Close an issue?${NC}"
    echo ""
    local open_indices=()
    for i in "${!issue_numbers[@]}"; do
        if [ "${issue_states[$i]}" = "OPEN" ]; then
            open_indices+=("$i")
            printf "  ${CYAN}%2d)${NC} #%-4s %s\n" "${issue_numbers[$i]}" "${issue_numbers[$i]}" "${issue_titles[$i]}"
        fi
    done
    echo ""
    echo -e "  ${CYAN} a)${NC} Close all open issues"
    echo -e "  ${CYAN} 0)${NC} Skip"
    echo ""

    local selection
    while true; do
        read -r -p "🔢 Enter issue # to close, 'a' for all, or 0 to skip: " selection

        if [ "$selection" = "0" ]; then
            echo -e "  ℹ️  Skipping"
            return 0
        fi

        if [ "$selection" = "a" ] || [ "$selection" = "A" ]; then
            # Close all open issues
            echo ""
            for idx in "${open_indices[@]}"; do
                local inum="${issue_numbers[$idx]}"
                local ititle="${issue_titles[$idx]}"
                echo -e "🔒 ${BLUE}Closing issue #${inum}...${NC}"
                if gh issue close "$inum" &>/dev/null; then
                    echo -e "  ✅ Issue #${inum} closed: ${ititle}"
                else
                    echo -e "  ❌ Failed to close issue #${inum}"
                fi
            done
            echo ""
            return 0
        fi

        # Check if selection is a valid open issue number
        if [[ "$selection" =~ ^[0-9]+$ ]]; then
            local valid=false
            for idx in "${open_indices[@]}"; do
                if [ "${issue_numbers[$idx]}" = "$selection" ]; then
                    valid=true
                    echo ""
                    echo -e "🔒 ${BLUE}Closing issue #${selection}...${NC}"
                    if gh issue close "$selection" &>/dev/null; then
                        echo -e "  ✅ Issue #${selection} closed: ${issue_titles[$idx]}"
                    else
                        echo -e "  ❌ Failed to close issue #${selection}"
                    fi
                    echo ""
                    return 0
                fi
            done
            if [ "$valid" = false ]; then
                echo -e "❌ ${RED}Not a valid open issue number. Try again.${NC}"
            fi
        else
            echo -e "❌ ${RED}Invalid input. Enter an issue #, 'a', or 0.${NC}"
        fi
    done
}

# Check for open PRs with comments during pre-flight (pr_only mode)
# Lists PRs that have comments, lets user view one, then close+exit or just exit
# Returns 0 if user chose to exit (caller should return), 1 to continue normal workflow
check_prs_with_comments() {
    # Skip in non-interactive mode
    if [ ! -t 0 ]; then
        return 1
    fi

    echo ""
    echo -e "📡 ${BLUE}Checking for open PRs with checks and comments...${NC}"

    # Fetch open PRs with their status checks and comments
    local pr_list
    pr_list=$(gh pr list --state open --json number,title,statusCheckRollup,comments --limit 20 2>/dev/null)

    if [ -z "$pr_list" ] || [ "$pr_list" = "[]" ]; then
        echo -e "  ℹ️  No open pull requests found"
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

    echo -e "  📋 Found ${pr_count} open PR(s)"
    echo ""
    echo -e "📋 ${YELLOW}Open PRs with checks and comments:${NC}"
    echo ""

    # Display PRs with checks and comments using formatted output
    local formatted_output
    formatted_output=$(echo "$pr_list" | jq -r '
      .[] | "#\(.number) \(.title)\n  Checks: \([.statusCheckRollup[]? | "\(.name): \(.conclusion // "IN_PROGRESS")"] | join(", "))\n  Comments (\(.comments | length)): \([.comments[]? | "\(.author.login): \(.body[0:50])"] | join(" | "))"
    ')

    local idx=0
    while IFS= read -r line; do
        if [[ "$line" == \#* ]]; then
            idx=$((idx + 1))
            printf "  ${CYAN}%2d)${NC} %s\n" "$idx" "$line"
        else
            printf "      %s\n" "$line"
        fi
    done <<< "$formatted_output"
    echo ""
    printf "  ${CYAN}%2d)${NC} Skip — continue with workflow\n" "0"
    echo ""

    # Get user selection
    local selection
    while true; do
        read -r -p "🔢 Select PR to view [0-${pr_count}]: " selection

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 0 ] && [ "$selection" -le "$pr_count" ]; then
            break
        fi
        echo -e "❌ ${RED}Invalid selection. Enter a number between 0 and ${pr_count}.${NC}"
    done

    # Skip — continue with normal workflow
    if [ "$selection" -eq 0 ]; then
        echo -e "  ℹ️  Skipping — continuing with workflow"
        return 1
    fi

    local selected_pr=${pr_numbers[$((selection - 1))]}
    local selected_title=${pr_titles[$((selection - 1))]}

    # View the PR details using existing function
    view_pr_details "$selected_pr"
    local view_rc=$?

    # If merge & cleanup was performed, exit
    if [ "$view_rc" -eq 2 ]; then
        echo ""
        echo "╔══════════════════════════════════════════╗"
        echo "║        👋 Goodbye! See you later!        ║"
        echo "╚══════════════════════════════════════════╝"
        return 0
    fi

    # After viewing, offer close or exit options
    echo ""
    echo -e "📋 ${YELLOW}What would you like to do?${NC}"
    echo ""
    echo -e "  ${CYAN}1)${NC} 🔒 Close PR #${selected_pr} and exit"
    echo -e "  ${CYAN}2)${NC} 👋 Exit without closing"
    echo -e "  ${CYAN}3)${NC} ▶️  Continue with workflow"
    echo ""

    local action
    while true; do
        read -r -p "🔢 Choose action [1-3]: " action

        case "$action" in
            1)
                close_pr "$selected_pr" "$selected_title"
                echo ""
                echo "╔══════════════════════════════════════════╗"
                echo "║        👋 Goodbye! See you later!        ║"
                echo "╚══════════════════════════════════════════╝"
                return 0
                ;;
            2)
                echo ""
                echo "╔══════════════════════════════════════════╗"
                echo "║        👋 Goodbye! See you later!        ║"
                echo "╚══════════════════════════════════════════╝"
                return 0
                ;;
            3)
                echo -e "  ℹ️  Continuing with workflow"
                return 1
                ;;
            *)
                echo -e "❌ ${RED}Invalid choice. Enter 1, 2, or 3.${NC}"
                ;;
        esac
    done
}

# Check if local branch is synced with remote (all commits pushed)
is_local_synced_with_remote() {
    git fetch origin "${HEAD_BRANCH}" 2>/dev/null || return 1
    local local_head remote_head
    local_head=$(git rev-parse HEAD 2>/dev/null)
    remote_head=$(git rev-parse "origin/${HEAD_BRANCH}" 2>/dev/null) || return 1
    [ "$local_head" = "$remote_head" ]
}

# Check if there's an open PR for HEAD_BRANCH → BASE_BRANCH
# Sets MERGE_READY_PR_NUMBER and MERGE_READY_PR_TITLE globals
MERGE_READY_PR_NUMBER=""
MERGE_READY_PR_TITLE=""
has_open_pr_for_branch() {
    MERGE_READY_PR_NUMBER=""
    MERGE_READY_PR_TITLE=""
    local pr_json
    pr_json=$(gh pr list --head "${HEAD_BRANCH}" --base "${BASE_BRANCH}" --state open --json number,title --limit 1 2>/dev/null)
    if [ -z "$pr_json" ] || [ "$pr_json" = "[]" ]; then
        return 1
    fi
    MERGE_READY_PR_NUMBER=$(echo "$pr_json" | jq -r '.[0].number')
    MERGE_READY_PR_TITLE=$(echo "$pr_json" | jq -r '.[0].title')
    [ -n "$MERGE_READY_PR_NUMBER" ] && [ "$MERGE_READY_PR_NUMBER" != "null" ]
}

# Check if a PR has a linked issue in its body
pr_has_linked_issue() {
    local pr_number="$1"
    local pr_body
    pr_body=$(gh pr view "$pr_number" --json body -q '.body' 2>/dev/null)
    [ -n "$pr_body" ] && echo "$pr_body" | grep -qiE '(closes|fixes|resolves|part of)\s+#[0-9]+'
}

# Merge-ready mode: merge PR, clean up branches, create new feature branch
# Called when branch is fully pushed, has an open PR with linked issue
# Returns 0 if merge was performed, 1 if user declined
merge_ready_mode() {
    local pr_number="$MERGE_READY_PR_NUMBER"
    local pr_title="$MERGE_READY_PR_TITLE"

    echo ""
    echo -e "🎯 ${GREEN}Merge-ready detected!${NC}"
    echo -e "  Branch ${CYAN}${HEAD_BRANCH}${NC} is fully pushed with an open PR and linked issue."
    echo ""
    echo -e "📝 ${BLUE}The following actions will be performed:${NC}"
    echo -e "  1. 🔀 Merge PR #${pr_number}: ${pr_title}"
    echo -e "  2. 🗑️  Delete remote branch '${HEAD_BRANCH}'"
    echo -e "  3. 🔄 Switch to ${BASE_BRANCH} and pull latest"
    echo -e "  4. 🗑️  Delete local branch '${HEAD_BRANCH}'"
    echo -e "  5. 🌱 Create a new feature branch"
    echo ""

    read -r -p "⚠️  Merge and start fresh? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "  ℹ️  Skipping merge — continuing with workflow"
        return 1
    fi

    echo ""

    # Step 1 & 2: Merge PR on GitHub and delete remote branch
    echo -e "🔀 ${BLUE}Merging PR #${pr_number} (${HEAD_BRANCH} → ${BASE_BRANCH})...${NC}"
    local merge_output
    if ! merge_output=$(gh pr merge "$pr_number" --merge --delete-branch 2>&1); then
        if echo "$merge_output" | grep -qi "conflict\|merge conflict"; then
            echo -e "  ❌ Merge conflict detected — resolve manually and retry"
        else
            echo -e "  ❌ Merge failed"
            echo "$merge_output" >&2
        fi
        error_exit "Failed to merge PR #${pr_number}."
    fi
    echo -e "  ✅ PR #${pr_number} merged and closed"
    echo -e "  ✅ Remote branch '${HEAD_BRANCH}' deleted"

    # Step 3: Switch to base branch and pull latest
    echo -e "🔄 ${BLUE}Switching to ${BASE_BRANCH} and pulling latest...${NC}"
    if ! git checkout "$BASE_BRANCH" 2>/dev/null; then
        error_exit "Could not switch to ${BASE_BRANCH}."
    fi
    if ! git pull origin "$BASE_BRANCH" 2>/dev/null; then
        echo -e "  ⚠️  Could not pull latest ${BASE_BRANCH}"
    else
        echo -e "  ✅ Switched to ${BASE_BRANCH} and pulled latest"
    fi

    # Step 4: Delete local feature branch
    local local_branch_deleted=false
    if git show-ref --verify --quiet "refs/heads/$HEAD_BRANCH"; then
        echo -e "🗑️  ${BLUE}Deleting local branch '${HEAD_BRANCH}'...${NC}"
        if ! git branch -d "$HEAD_BRANCH" 2>/dev/null; then
            echo -e "  ⚠️  Could not delete with -d, trying -D..."
            if ! git branch -D "$HEAD_BRANCH" 2>/dev/null; then
                echo -e "  ⚠️  Could not delete local branch '${HEAD_BRANCH}'"
                echo -e "  👉 To force delete: git branch -D ${HEAD_BRANCH}"
            else
                echo -e "  ✅ Local branch '${HEAD_BRANCH}' deleted"
                local_branch_deleted=true
            fi
        else
            echo -e "  ✅ Local branch '${HEAD_BRANCH}' deleted"
            local_branch_deleted=true
        fi
    fi

    # Step 5: Prompt for new feature branch
    echo ""
    echo -e "🌱 ${YELLOW}Create a new feature branch?${NC}"
    local new_branch_name
    read -r -p "🌱 Enter new branch name (or press Enter to skip): " new_branch_name

    local new_branch_created=false
    if [ -n "$new_branch_name" ]; then
        if git show-ref --verify --quiet "refs/heads/$new_branch_name"; then
            echo -e "  ⚠️  Branch '${new_branch_name}' already exists — switching to it"
            git checkout "$new_branch_name" 2>/dev/null || echo -e "  ❌ Could not switch to '${new_branch_name}'"
        else
            echo -e "🌱 ${BLUE}Creating branch '${new_branch_name}'...${NC}"
            if ! git checkout -b "$new_branch_name" 2>/dev/null; then
                echo -e "  ❌ Failed to create branch '${new_branch_name}'"
            else
                echo -e "  ✅ Branch '${new_branch_name}' created and checked out"
                new_branch_created=true
            fi
        fi
    else
        echo -e "  ℹ️  Staying on ${BASE_BRANCH}"
    fi

    # Summary
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║     🎉 All actions completed!            ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    echo -e "📝 ${CYAN}Summary:${NC}"
    echo -e "  • PR #${pr_number} merged and closed: ${pr_title}"
    echo -e "  • Remote branch '${HEAD_BRANCH}' deleted"
    if [ "$local_branch_deleted" = true ]; then
        echo -e "  • Local branch '${HEAD_BRANCH}' deleted"
    fi
    echo -e "  • ${BASE_BRANCH} updated with latest changes"
    if [ "$new_branch_created" = true ]; then
        echo -e "  • 🌱 New branch '${new_branch_name}' created"
    fi
    echo ""

    return 0
}

# PR Management Mode: select a PR and choose an action
pr_management_mode() {
    echo ""
    echo -e "📡 ${BLUE}Fetching open pull requests...${NC}"

    local pr_list
    pr_list=$(gh pr list --state open --json number,title --limit 20 2>/dev/null)

    if [ -z "$pr_list" ] || [ "$pr_list" = "[]" ]; then
        echo -e "  ℹ️  No open pull requests found"
        echo ""
        echo "╔══════════════════════════════════════════╗"
        echo "║        👋 Goodbye! See you later!        ║"
        echo "╚══════════════════════════════════════════╝"
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
    echo -e "📋 ${YELLOW}Select a pull request:${NC}"
    echo ""

    for i in "${!pr_numbers[@]}"; do
        printf "  ${CYAN}%2d)${NC} #%-4s %s\n" "$((i + 1))" "${pr_numbers[$i]}" "${pr_titles[$i]}"
    done
    echo ""
    printf "  ${CYAN}%2s)${NC} Exit\n" "x"
    echo ""

    local selection
    while true; do
        read -r -p "🔢 Select PR [1-${pr_count}/x]: " selection

        if [ "$selection" = "x" ] || [ "$selection" = "X" ]; then
            echo -e "🚫 ${YELLOW}Operation cancelled.${NC}"
            echo ""
            echo "╔══════════════════════════════════════════╗"
            echo "║        👋 Goodbye! See you later!        ║"
            echo "╚══════════════════════════════════════════╝"
            exit 0
        fi

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "$pr_count" ]; then
            break
        fi
        echo -e "❌ ${RED}Invalid selection. Enter a number between 1 and ${pr_count}, or 'x' to exit.${NC}"
    done

    local selected_pr=${pr_numbers[$((selection - 1))]}
    local selected_title=${pr_titles[$((selection - 1))]}

    # Action menu loop for the selected PR
    while true; do
        echo ""
        echo -e "${CYAN}PR #${selected_pr}: ${selected_title}${NC}"
        echo ""
        echo -e "📋 ${YELLOW}What would you like to do?${NC}"
        echo ""
        echo -e "  ${CYAN}1)${NC} 🔍 View details & comments"
        echo -e "  ${CYAN}2)${NC} 🔒 Close PR"
        echo -e "  ${CYAN}3)${NC} 🔀 Squash-merge PR"
        echo -e "  ${CYAN}4)${NC} 📋 View/close linked issues"
        echo -e "  ${CYAN}x)${NC} 👋 Back"
        echo ""

        local action
        read -r -p "🔢 Choose action [1-4/x]: " action

        case "$action" in
            1)
                view_pr_details "$selected_pr"
                if [ $? -eq 2 ]; then
                    return
                fi
                ;;
            2)
                close_pr "$selected_pr" "$selected_title"
                return
                ;;
            3)
                squash_merge_pr "$selected_pr" "$selected_title"
                return
                ;;
            4)
                view_linked_issues "$selected_pr"
                ;;
            x|X)
                echo ""
                echo "╔══════════════════════════════════════════╗"
                echo "║        👋 Goodbye! See you later!        ║"
                echo "╚══════════════════════════════════════════╝"
                return
                ;;
            *)
                echo -e "❌ ${RED}Invalid choice. Enter 1-4 or x.${NC}"
                ;;
        esac
    done
}

# Branch Management Mode: create or delete branches
# Offered at startup before issue creation prompt
# Returns 0 if branch action was performed (caller should exit), 1 otherwise (continue)
prompt_branch_management() {
    # Skip in non-interactive mode
    if [ ! -t 0 ]; then
        return 1
    fi

    local manage_branches
    read -r -p "🔧 Manage branches? (y/N): " manage_branches
    if [[ ! "$manage_branches" =~ ^[Yy]$ ]]; then
        return 1
    fi

    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║                                          ║"
    echo "║   🔧  Git Branch Management Tool  🔧      ║"
    echo "║                                          ║"
    echo "║   Delete or create branches safely       ║"
    echo "║                                          ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""

    echo "📂 Repository: $(basename "$(git rev-parse --show-toplevel)")"
    local current_branch
    current_branch=$(git branch --show-current)
    echo "🌿 Current branch: $current_branch"
    echo ""

    # Check for uncommitted changes
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "⚠️  WARNING: You have uncommitted changes."
        echo "👉 Please commit or stash them before managing branches."
        return 0
    fi

    # Build array of branches
    local branches=()
    while IFS= read -r branch; do
        local clean_branch
        clean_branch=$(echo "$branch" | sed 's/^[* ]*//')
        branches+=("$clean_branch")
    done < <(git branch --list)

    if [ ${#branches[@]} -eq 0 ]; then
        echo "❌ ERROR: No branches found in this repository."
        return 0
    fi

    # Display numbered branch list
    echo "📋 Available branches:"
    echo ""
    for i in "${!branches[@]}"; do
        local num=$((i + 1))
        local branch="${branches[$i]}"
        if [ "$branch" == "$current_branch" ]; then
            echo "   $num) $branch  ← (current)"
        else
            echo "   $num) $branch"
        fi
    done

    local create_option=$(( ${#branches[@]} + 1 ))
    echo ""
    echo "   $create_option) 🌱 Create a new branch"
    echo ""

    local selection
    read -r -p "🔢 Enter your choice (1-$create_option): " selection

    # Validate input is not empty
    if [ -z "$selection" ]; then
        echo ""
        echo "❌ ERROR: No selection made."
        return 0
    fi

    # Validate input is a number
    if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
        echo ""
        echo "❌ ERROR: Invalid input. Please enter a number."
        return 0
    fi

    # Validate input is within range
    if [ "$selection" -lt 1 ] || [ "$selection" -gt "$create_option" ]; then
        echo ""
        echo "❌ ERROR: Invalid selection. Please choose a number between 1 and $create_option."
        return 0
    fi

    # ============================================
    # Handle CREATE NEW BRANCH
    # ============================================
    if [ "$selection" -eq "$create_option" ]; then
        echo ""
        local new_branch_name
        read -r -p "🌱 Enter the name for the new branch: " new_branch_name

        # Validate input is not empty
        if [ -z "$new_branch_name" ]; then
            echo ""
            echo "❌ ERROR: No branch name provided."
            return 0
        fi

        # Check if branch already exists locally
        if git show-ref --verify --quiet refs/heads/"$new_branch_name"; then
            echo ""
            echo "❌ ERROR: Branch '$new_branch_name' already exists locally."
            return 0
        fi

        # Confirm creation
        echo ""
        echo "📝 Summary of actions:"
        echo "   🌱 Create new branch: $new_branch_name"
        echo "   🔄 Switch to: $new_branch_name"
        echo ""
        local confirm
        read -r -p "⚠️  Are you sure you want to continue? (y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo ""
            echo "🚫 Aborted. No changes were made."
            echo ""
            echo "╔══════════════════════════════════════════╗"
            echo "║        👋 Goodbye! See you later!        ║"
            echo "╚══════════════════════════════════════════╝"
            return 0
        fi

        echo ""
        echo "🌱 Creating branch '$new_branch_name'..."
        if ! git checkout -b "$new_branch_name"; then
            echo "❌ ERROR: Failed to create branch '$new_branch_name'."
            return 0
        fi

        echo ""
        echo "🎉 All done!"
        echo "   ✅ Branch '$new_branch_name' created and checked out."
        echo ""
        echo "╔══════════════════════════════════════════╗"
        echo "║     👋 Goodbye! Happy coding! 🚀        ║"
        echo "╚══════════════════════════════════════════╝"
        return 0
    fi

    # ============================================
    # Handle DELETE BRANCH
    # ============================================
    local branch_index=$((selection - 1))
    local branch_name="${branches[$branch_index]}"

    echo ""
    echo "🗑️  You selected: $branch_name"

    # Prevent deletion of main/master branches
    if [[ "$branch_name" == "main" || "$branch_name" == "master" ]]; then
        echo ""
        echo "🚫 ERROR: Cannot delete the '$branch_name' branch. That's a protected branch!"
        return 0
    fi

    # Notify if on the branch being deleted
    if [ "$branch_name" == "$current_branch" ]; then
        echo "⚠️  You are currently on the '$branch_name' branch."
        echo "👉 Will switch to main before deleting."
    fi

    # Check if local branch exists
    local LOCAL_EXISTS=false
    if git show-ref --verify --quiet refs/heads/"$branch_name"; then
        LOCAL_EXISTS=true
        echo "✅ Local branch '$branch_name' found."
    else
        echo "⚠️  Local branch '$branch_name' does not exist."
    fi

    # Check if remote branch exists
    local REMOTE_EXISTS=false
    if git ls-remote --exit-code --heads origin "$branch_name" > /dev/null 2>&1; then
        REMOTE_EXISTS=true
        echo "✅ Remote branch '$branch_name' found on origin."
    else
        echo "⚠️  Remote branch '$branch_name' does not exist on origin."
    fi

    # If neither exists, exit
    if [ "$LOCAL_EXISTS" = false ] && [ "$REMOTE_EXISTS" = false ]; then
        echo ""
        echo "❌ ERROR: Branch '$branch_name' does not exist locally or remotely."
        echo "👉 Double-check the branch name and try again."
        return 0
    fi

    # Summary of what will be deleted
    echo ""
    echo "📝 Summary of actions:"
    if [ "$LOCAL_EXISTS" = true ]; then
        echo "   🗑️  Delete local branch:  $branch_name"
    fi
    if [ "$REMOTE_EXISTS" = true ]; then
        echo "   🗑️  Delete remote branch: origin/$branch_name"
    fi
    echo ""

    # Confirmation prompt
    local confirm
    read -r -p "⚠️  Are you sure you want to continue? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo ""
        echo "🚫 Aborted. No branches were deleted."
        echo ""
        echo "╔══════════════════════════════════════════╗"
        echo "║        👋 Goodbye! See you later!        ║"
        echo "╚══════════════════════════════════════════╝"
        return 0
    fi

    echo ""

    # Switch to main if on the branch being deleted
    if [ "$branch_name" == "$current_branch" ]; then
        echo "🔄 Switching to main branch..."
        if ! git checkout main; then
            echo "❌ ERROR: Failed to checkout main branch."
            return 0
        fi
        echo "✅ Switched to main."
        echo ""
    fi

    # Delete local branch
    if [ "$LOCAL_EXISTS" = true ]; then
        echo "🗑️  Deleting local branch '$branch_name'..."
        if ! git branch -D "$branch_name"; then
            echo "❌ ERROR: Failed to delete local branch '$branch_name'."
            return 0
        fi
        echo "✅ Local branch '$branch_name' deleted."
        echo ""
    fi

    # Delete remote branch
    if [ "$REMOTE_EXISTS" = true ]; then
        echo "🗑️  Deleting remote branch 'origin/$branch_name'..."
        if ! git push origin --delete "$branch_name"; then
            echo "❌ ERROR: Failed to delete remote branch '$branch_name'."
            return 0
        fi
        echo "✅ Remote branch 'origin/$branch_name' deleted."
        echo ""
    fi

    # Success summary
    echo "🎉 All done! Here's what was deleted:"
    if [ "$LOCAL_EXISTS" = true ]; then
        echo "   ✅ Local branch:  $branch_name"
    fi
    if [ "$REMOTE_EXISTS" = true ]; then
        echo "   ✅ Remote branch: origin/$branch_name"
    fi
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║     👋 Goodbye! Happy coding! 🚀        ║"
    echo "╚══════════════════════════════════════════╝"
    return 0
}

# Prompt to create a standalone GitHub issue before the main workflow
# Returns 0 if issue was created (caller should exit), 1 otherwise (continue)
prompt_issue_creation() {
    # Skip in non-interactive mode
    if [ ! -t 0 ]; then
        return 1
    fi

    local create_issue
    read -r -p "📝 Create a GitHub Issue? (y/N): " create_issue
    if [[ ! "$create_issue" =~ ^[Yy]$ ]]; then
        return 1
    fi

    # Collect issue title
    echo ""
    echo -e "✏️  ${YELLOW}Enter issue title:${NC}"
    local issue_title
    read -r -p "> " issue_title

    if [ -z "$issue_title" ]; then
        echo -e "  ℹ️  Skipping issue creation (empty title)"
        return 1
    fi

    # Collect overview (single-line or editor, same pattern as get_commit_message)
    echo ""
    echo -e "✏️  ${YELLOW}Enter issue overview:${NC}"
    echo -e "  ${CYAN}1)${NC} Single line (type here)"
    echo -e "  ${CYAN}2)${NC} Multi-line (open editor)"
    echo ""

    local overview=""
    local choice
    while true; do
        read -r -p "Choose (1/2): " choice
        case $choice in
            1)
                echo ""
                read -r -p "> " overview
                break
                ;;
            2)
                local editor
                editor=$(get_editor)
                local tmpfile
                tmpfile=$(mktemp)

                echo "" > "$tmpfile"
                echo "" >> "$tmpfile"
                echo "# Enter your issue overview above." >> "$tmpfile"
                echo "# Lines starting with '#' will be ignored." >> "$tmpfile"

                echo -e "Opening editor (${editor})..."
                $editor "$tmpfile"

                overview=$(grep -v '^#' "$tmpfile" | sed -e 's/[[:space:]]*$//' | sed '/^$/N;/^\n$/d')
                rm -f "$tmpfile"
                break
                ;;
            *)
                echo -e "❌ ${RED}Invalid choice. Enter 1 or 2.${NC}"
                ;;
        esac
    done

    # Collect issue label from repository
    echo ""
    echo -e "📡 ${BLUE}Fetching repository labels...${NC}"
    local label_list
    label_list=$(gh label list --json name --jq '.[].name' --limit 50 2>/dev/null | sort)

    local issue_label=""
    if [ -z "$label_list" ]; then
        echo -e "  ℹ️  No labels found in repository — skipping label"
    else
        echo -e "🏷️  ${YELLOW}Select a label (optional):${NC}"

        local -a labels=()
        local i=1
        while IFS= read -r lbl; do
            labels+=("$lbl")
            echo -e "  ${CYAN}${i})${NC} ${lbl}"
            ((i++))
        done <<< "$label_list"

        local label_count=${#labels[@]}
        echo -e "  ${CYAN}$((label_count + 1)))${NC} Skip (no label)"
        echo ""

        local label_selection
        while true; do
            read -r -p "🔢 Choose (1-$((label_count + 1))): " label_selection
            if [[ "$label_selection" =~ ^[0-9]+$ ]] && [ "$label_selection" -ge 1 ] && [ "$label_selection" -le $((label_count + 1)) ]; then
                if [ "$label_selection" -le "$label_count" ]; then
                    issue_label="${labels[$((label_selection - 1))]}"
                fi
                break
            else
                echo -e "❌ ${RED}Invalid choice. Enter a number between 1 and $((label_count + 1)).${NC}"
            fi
        done
    fi

    # Build issue body from template
    local template_file="$HOME/.config/issue-template.md"
    local issue_body=""

    if [ -f "$template_file" ]; then
        # Load template, replace Overview content and Status using awk
        issue_body=$(awk -v overview="$overview" '
            /^## Overview$/ { print; print ""; print overview; skip=1; next }
            /^## Status$/ { print; print ""; print "- Not Started"; skip=1; next }
            /^## / { skip=0 }
            !skip { print }
        ' "$template_file" 2>/dev/null)

        # If awk failed, fall back to simple construction
        if [ -z "$issue_body" ]; then
            issue_body="## Overview

${overview}

## Status

- Not Started"
        fi
    else
        echo -e "  ⚠️  No template found at ~/.config/issue-template.md. Using minimal body."
        issue_body="## Overview

${overview}

## Status

- Not Started"
    fi

    # Create the issue
    echo ""
    echo -e "🌱 ${BLUE}Creating GitHub issue...${NC}"
    local issue_output
    local -a issue_cmd=(gh issue create --title "$issue_title" --body "$issue_body")
    if [ -n "$issue_label" ]; then
        issue_cmd+=(--label "$issue_label")
    fi
    if ! issue_output=$("${issue_cmd[@]}" 2>&1); then
        echo -e "  ❌ Failed to create issue"
        echo "$issue_output" >&2
        return 1
    fi

    local issue_number
    issue_number=$(echo "$issue_output" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+')
    echo -e "  ✅ Issue #${issue_number} created: ${issue_title}"

    return 0
}

# Main script
main() {
    # Trap for unexpected errors (inside main for source guard compatibility)
    trap 'error_exit "An unexpected error occurred on line $LINENO."' ERR

    clear

    # Welcome banner
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║                                          ║"
    echo "║   ⚓  Welcome to Git Shipyard  ⚓         ║"
    echo "║                                          ║"
    echo "║   Stage, commit, push & PR in one step   ║"
    echo "║                                          ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""

    # Offer to manage branches (exits after completion)
    if prompt_branch_management; then
        echo ""
        echo "╔══════════════════════════════════════════╗"
        echo "║        👋 Goodbye! See you later!        ║"
        echo "╚══════════════════════════════════════════╝"
        return
    fi

    # Offer to create a standalone GitHub issue (exits after completion)
    if prompt_issue_creation; then
        echo ""
        echo "╔══════════════════════════════════════════╗"
        echo "║        👋 Goodbye! See you later!        ║"
        echo "╚══════════════════════════════════════════╝"
        return
    fi

    echo ""

    # Pre-flight checks
    echo -e "🔍 ${BLUE}Running pre-flight checks...${NC}"

    check_command "git"
    echo -e "  ✅ git found"

    check_command "gh"
    echo -e "  ✅ gh CLI found"

    check_command "jq"
    echo -e "  ✅ jq found"

    check_git_repo
    echo -e "  ✅ Inside git repository"

    check_not_detached
    echo -e "  ✅ On a valid branch"

    # Resolve HEAD_BRANCH to current branch if not set via --head
    if [ -z "$HEAD_BRANCH" ]; then
        HEAD_BRANCH=$(git symbolic-ref --short HEAD)
    fi
    echo -e "  ✅ Head branch: ${HEAD_BRANCH}"

    check_gh_auth
    echo -e "  ✅ GitHub authenticated"

    check_remote
    echo -e "  ✅ Remote 'origin' configured"

    # Check for an in-progress merge from a prior sync attempt (before mode detection)
    check_merge_in_progress

    # Determine workflow mode
    local mode=""
    if has_uncommitted_changes; then
        mode="full"
        echo -e "  ✅ Uncommitted changes detected"
    elif has_commits_ahead; then
        if ! has_open_prs; then
            mode="squash_eligible"
            echo -e "  ✅ Commits ahead of ${BASE_BRANCH}, no open PRs (squash-eligible)"
        else
            mode="pr_only"
            echo -e "  ✅ Commits ahead of ${BASE_BRANCH} (already committed)"
        fi
    else
        mode="pr_management"
        echo -e "  ✅ Clean working tree — entering PR Management Mode"
    fi

    # Only enforce non-base-branch for modes that operate on the current branch
    if [ "$mode" != "pr_management" ]; then
        check_not_on_base_branch
        echo -e "  ✅ Not on base branch"
    fi

    # In pr_only mode, check for open PRs with comments before proceeding
    if [ "$mode" = "pr_only" ]; then
        if check_prs_with_comments; then
            return
        fi

        # Check if branch is merge-ready (fully pushed, open PR, linked issue)
        if is_local_synced_with_remote && has_open_pr_for_branch && pr_has_linked_issue "$MERGE_READY_PR_NUMBER"; then
            echo -e "  ✅ Merge-ready: PR #${MERGE_READY_PR_NUMBER} with linked issue"
            if merge_ready_mode; then
                echo "╔══════════════════════════════════════════╗"
                echo "║        👋 Goodbye! See you later!        ║"
                echo "╚══════════════════════════════════════════╝"
                return
            fi
        fi
    fi

    echo ""

    if [ "$mode" = "pr_management" ]; then
        pr_management_mode
        return
    fi

    # Squash-eligible: offer PR creation or direct squash-merge
    local squash_after_pr=false
    if [ "$mode" = "squash_eligible" ]; then
        echo -e "📋 ${YELLOW}Your branch has commits ahead with no open PR.${NC}"
        echo ""
        echo -e "  ${CYAN}1)${NC} 📋 Create a pull request"
        echo -e "  ${CYAN}2)${NC} 🔀 Squash-merge directly into ${BASE_BRANCH}"
        echo ""

        local squash_choice
        while true; do
            read -r -p "🔢 Choose (1/2): " squash_choice
            case $squash_choice in
                1)
                    mode="pr_only"
                    break
                    ;;
                2)
                    squash_after_pr=true
                    break
                    ;;
                *)
                    echo -e "❌ ${RED}Invalid choice. Enter 1 or 2.${NC}"
                    ;;
            esac
        done
        echo ""
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
        echo -e "📝 ${BLUE}The following actions will be performed:${NC}"
        echo -e "  1. 📦 Stage all changes (git add .)"
        echo -e "  2. 💾 Commit with message: ${CYAN}\"$message_preview\"${NC}"
        echo -e "  3. 🚀 Push to origin/${HEAD_BRANCH}"
        echo -e "  4. 🔄 Sync with ${BASE_BRANCH} (merge any new changes)"
        echo -e "  5. 📋 Create PR from ${HEAD_BRANCH} → ${BASE_BRANCH}"
    elif [ "$squash_after_pr" = true ]; then
        # Squash-merge mode
        echo -e "📝 ${BLUE}The following actions will be performed:${NC}"
        echo -e "  1. 🚀 Push to origin/${HEAD_BRANCH}"
        echo -e "  2. 🔄 Sync with ${BASE_BRANCH} (merge any new changes)"
        echo -e "  3. 📋 Create PR from ${HEAD_BRANCH} → ${BASE_BRANCH}"
        echo -e "  4. 🔀 Squash-merge PR into ${BASE_BRANCH}"
        echo -e "  5. 🗑️  Delete remote branch '${HEAD_BRANCH}'"
        echo -e "  6. 🔄 Switch to ${BASE_BRANCH} and pull latest"
        echo -e "  7. 🗑️  Delete local branch '${HEAD_BRANCH}'"
    else
        # PR only mode
        echo -e "📝 ${BLUE}The following actions will be performed:${NC}"
        echo -e "  1. 🚀 Push to origin/${HEAD_BRANCH} (if needed)"
        echo -e "  2. 🔄 Sync with ${BASE_BRANCH} (merge any new changes)"
        echo -e "  3. 📋 Create PR from ${HEAD_BRANCH} → ${BASE_BRANCH}"
    fi

    echo ""

    read -r -p "⚠️  Proceed? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "🚫 ${YELLOW}Operation cancelled.${NC}"
        echo ""
        echo "╔══════════════════════════════════════════╗"
        echo "║        👋 Goodbye! See you later!        ║"
        echo "╚══════════════════════════════════════════╝"
        exit 0
    fi

    echo ""

    # Spinner pause
    echo -e "⚓ ${BLUE}Preparing to ship...${NC}"
    spinner $$ 2
    echo -e "  ✅ Ready"
    echo ""

    if [ "$mode" = "full" ]; then
        # Full workflow: stage, commit, push, create PR
        echo -e "📦 ${BLUE}Staging changes...${NC}"
        if ! git add .; then
            error_exit "Failed to stage changes."
        fi
        echo -e "  ✅ Changes staged"

        echo -e "💾 ${BLUE}Committing...${NC}"
        if ! git commit -m "$commit_message"; then
            echo -e "  ❌ Commit failed"
            echo -e "  👉 Your changes are still staged. To unstage: git reset HEAD"
            error_exit "Commit failed. Check your commit message."
        fi
        echo -e "  ✅ Changes committed"

        # Offer to link commit to existing PR
        link_to_pr "$commit_message" || true

        echo -e "🚀 ${BLUE}Pushing to origin/${HEAD_BRANCH}...${NC}"
        local push_output
        if ! push_output=$(git push -u origin "${HEAD_BRANCH}" 2>&1); then
            if echo "$push_output" | grep -q "rejected\|non-fast-forward"; then
                echo -e "  ❌ Push rejected - remote has changes you don't have locally"
                echo -e "  👉 Try: git pull --rebase origin ${HEAD_BRANCH}"
                error_exit "Push failed due to remote changes."
            else
                echo -e "  ❌ Push failed"
                echo "$push_output" >&2
                error_exit "Push failed. Check remote configuration."
            fi
        fi
        echo -e "  ✅ Pushed to origin/${HEAD_BRANCH}"
    else
        # PR only: push if needed, then create PR
        echo -e "🚀 ${BLUE}Pushing to origin/${HEAD_BRANCH}...${NC}"
        local push_output
        if ! push_output=$(git push -u origin "${HEAD_BRANCH}" 2>&1); then
            if echo "$push_output" | grep -q "Everything up-to-date"; then
                echo -e "  ℹ️  Already up to date"
            elif echo "$push_output" | grep -q "rejected\|non-fast-forward"; then
                echo -e "  ❌ Push rejected - remote has changes you don't have locally"
                echo -e "  👉 Try: git pull --rebase origin ${HEAD_BRANCH}"
                error_exit "Push failed due to remote changes."
            else
                echo -e "  ℹ️  Already up to date or pushed"
            fi
        else
            echo -e "  ✅ Pushed to origin/${HEAD_BRANCH}"
        fi
    fi

    # Pre-PR sync: merge base branch into head to ensure a clean merge
    sync_with_base

    # Offer to link an issue to the PR
    select_issue || true

    # Check if a PR already exists for this branch before attempting creation
    local existing_pr_number=""
    local existing_pr_url=""
    local existing_pr_json
    existing_pr_json=$(gh pr list --head "${HEAD_BRANCH}" --base "${BASE_BRANCH}" --state open --json number,url --limit 1 2>/dev/null)
    if [ -n "$existing_pr_json" ] && [ "$existing_pr_json" != "[]" ]; then
        existing_pr_number=$(echo "$existing_pr_json" | jq -r '.[0].number')
        existing_pr_url=$(echo "$existing_pr_json" | jq -r '.[0].url')
    fi

    local pr_existed=false

    if [ -n "$existing_pr_number" ]; then
        # PR already exists — update it instead of creating a new one
        pr_existed=true
        echo -e "📋 ${BLUE}PR #${existing_pr_number} already exists for ${HEAD_BRANCH} → ${BASE_BRANCH}${NC}"
        echo -e "  🔗 ${existing_pr_url}"
        echo -e "  ✅ Changes pushed to existing PR"

        # If an issue was selected, link it to the existing PR
        if [ -n "$SELECTED_ISSUE" ]; then
            echo -e "🔗 ${BLUE}Linking issue #${SELECTED_ISSUE} to PR #${existing_pr_number}...${NC}"
            local existing_body
            existing_body=$(gh pr view "$existing_pr_number" --json body -q '.body' 2>/dev/null)

            # Only append if not already linked
            if echo "$existing_body" | grep -q "Closes #${SELECTED_ISSUE}"; then
                echo -e "  ℹ️  Issue #${SELECTED_ISSUE} is already linked"
            else
                local updated_body="${existing_body}

Closes #${SELECTED_ISSUE}"
                if gh pr edit "$existing_pr_number" --body "$updated_body" &>/dev/null; then
                    echo -e "  ✅ Issue #${SELECTED_ISSUE} linked to PR #${existing_pr_number}"
                else
                    echo -e "  ⚠️  Could not update PR body to link issue"
                fi
            fi
        fi
    else
        # No existing PR — create a new one
        echo -e "📋 ${BLUE}Creating pull request...${NC}"
        echo -e "${YELLOW}─────────────────────────────────────────${NC}"

        local pr_create_failed=false
        local commit_subject
        commit_subject=$(git log -1 --format="%s" "${HEAD_BRANCH}" 2>/dev/null)
        if [ -z "$commit_subject" ]; then
            commit_subject=$(echo "${HEAD_BRANCH}" | sed 's/[-_]/ /g; s/\b\w/\u&/g')
        fi
        local auto_body
        auto_body=$(git log --format="%B" "${BASE_BRANCH}".."${HEAD_BRANCH}" 2>/dev/null | head -100)

        if [ -n "$SELECTED_ISSUE" ]; then
            local issue_title="${SELECTED_ISSUE_TITLE}"
            if [ -z "$issue_title" ]; then
                issue_title="$commit_subject"
            fi
            local pr_title="PR - ${issue_title}"
            local full_body="${auto_body}

Closes #${SELECTED_ISSUE}"
            local pr_cmd=(gh pr create --base "${BASE_BRANCH}" --head "${HEAD_BRANCH}" --title "$pr_title" --body "$full_body")
            [ "${DRAFT_PR:-false}" = true ] && pr_cmd+=(--draft)
            if ! "${pr_cmd[@]}"; then
                pr_create_failed=true
            fi
        else
            local pr_title="PR - ${commit_subject}"
            local pr_cmd=(gh pr create --base "${BASE_BRANCH}" --head "${HEAD_BRANCH}" --title "$pr_title" --body "$auto_body")
            [ "${DRAFT_PR:-false}" = true ] && pr_cmd+=(--draft)
            if ! "${pr_cmd[@]}"; then
                pr_create_failed=true
            fi
        fi

        if [ "$pr_create_failed" = true ]; then
            error_exit "Failed to create PR. Check the output above for details."
        fi

        echo -e "${YELLOW}─────────────────────────────────────────${NC}"
    fi

    echo ""

    # If squash_after_pr, immediately squash-merge the newly created PR
    if [ "$squash_after_pr" = true ]; then
        # Find the PR we just created (or that already existed)
        local squash_pr_number=""
        if [ -n "$existing_pr_number" ]; then
            squash_pr_number="$existing_pr_number"
        else
            local squash_pr_json
            squash_pr_json=$(gh pr list --head "${HEAD_BRANCH}" --base "${BASE_BRANCH}" --state open --json number --limit 1 2>/dev/null)
            squash_pr_number=$(echo "$squash_pr_json" | jq -r '.[0].number' 2>/dev/null)
        fi

        if [ -z "$squash_pr_number" ] || [ "$squash_pr_number" = "null" ]; then
            echo -e "  ⚠️  Could not find PR to squash-merge — skipping"
        else
            echo -e "🔀 ${BLUE}Squash-merging PR #${squash_pr_number}...${NC}"
            local merge_output
            if ! merge_output=$(gh pr merge "$squash_pr_number" --squash --delete-branch 2>&1); then
                if echo "$merge_output" | grep -qi "conflict\|merge conflict"; then
                    echo -e "  ❌ Merge conflict detected — resolve manually and retry"
                else
                    echo -e "  ❌ Merge failed"
                    echo "$merge_output" >&2
                fi
                error_exit "Failed to squash-merge PR #${squash_pr_number}."
            fi
            echo -e "  ✅ PR #${squash_pr_number} squash-merged and remote branch deleted"

            # Switch to base branch and pull latest
            echo -e "🔄 ${BLUE}Switching to ${BASE_BRANCH} and pulling...${NC}"
            if ! git checkout "$BASE_BRANCH" 2>/dev/null; then
                echo -e "  ⚠️  Could not switch to ${BASE_BRANCH} automatically"
            else
                if ! git pull origin "$BASE_BRANCH" 2>/dev/null; then
                    echo -e "  ⚠️  Could not pull latest ${BASE_BRANCH}"
                else
                    echo -e "  ✅ Switched to ${BASE_BRANCH} and pulled latest"
                fi
            fi

            # Delete local head branch if it still exists
            local branch_deleted=false
            if git show-ref --verify --quiet "refs/heads/$HEAD_BRANCH"; then
                echo -e "🗑️  ${BLUE}Deleting local branch '${HEAD_BRANCH}'...${NC}"
                if ! git branch -d "$HEAD_BRANCH" 2>/dev/null; then
                    echo -e "  ⚠️  Could not delete local branch '${HEAD_BRANCH}'"
                    echo -e "  👉 To force delete: git branch -D ${HEAD_BRANCH}"
                else
                    echo -e "  ✅ Local branch '${HEAD_BRANCH}' deleted"
                    branch_deleted=true
                fi
            fi

            # Reset head environment
            reset_head_environment

            # Squash-merge summary
            echo ""
            echo "╔══════════════════════════════════════════╗"
            echo "║     🎉 All actions completed!            ║"
            echo "╚══════════════════════════════════════════╝"
            echo ""
            echo -e "📝 ${CYAN}Summary:${NC}"
            echo -e "  • 🔀 PR #${squash_pr_number} squash-merged into ${BASE_BRANCH}"
            echo -e "  • 🗑️  Remote branch '${HEAD_BRANCH}' deleted"
            if [ "$branch_deleted" = true ]; then
                echo -e "  • 🗑️  Local branch '${HEAD_BRANCH}' deleted"
            fi
            echo -e "  • 🔄 ${BASE_BRANCH} updated with latest changes"
            if [ -n "$SELECTED_ISSUE" ]; then
                if [ -n "$CREATED_ISSUE_FOR_PR" ]; then
                    echo -e "  • 🔗 Created and linked issue #${SELECTED_ISSUE}: ${CREATED_ISSUE_FOR_PR}"
                else
                    echo -e "  • 🔗 Linked to issue #${SELECTED_ISSUE} (closes on merge)"
                fi
            fi
            echo ""
            echo "╔══════════════════════════════════════════╗"
            echo "║     👋 Goodbye! Happy coding! 🚀        ║"
            echo "╚══════════════════════════════════════════╝"
            return
        fi
    fi

    # Success message
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║     🎉 All actions completed!            ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    echo -e "📝 ${CYAN}Summary:${NC}"
    if [ "$mode" = "full" ]; then
        echo -e "  • 💾 Changes staged and committed"
    fi
    echo -e "  • 🚀 Pushed to origin/${HEAD_BRANCH}"
    if [ "$SYNC_RESULT" = "synced" ]; then
        echo -e "  • 🔄 Synced ${HEAD_BRANCH} with ${BASE_BRANCH} (merged new changes)"
    elif [ "$SYNC_RESULT" = "up_to_date" ]; then
        echo -e "  • 🔄 Synced ${HEAD_BRANCH} with ${BASE_BRANCH} (already up to date)"
    fi
    if [ "$pr_existed" = true ]; then
        echo -e "  • 📋 Changes pushed to existing PR #${existing_pr_number} (${HEAD_BRANCH} → ${BASE_BRANCH})"
    else
        echo -e "  • 📋 Pull request created (${HEAD_BRANCH} → ${BASE_BRANCH})"
    fi
    if [ -n "$SELECTED_ISSUE" ]; then
        if [ -n "$CREATED_ISSUE_FOR_PR" ]; then
            echo -e "  • 🔗 Created and linked issue #${SELECTED_ISSUE}: ${CREATED_ISSUE_FOR_PR}"
        else
            echo -e "  • 🔗 Linked to issue #${SELECTED_ISSUE} (closes on merge)"
        fi
    fi
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║     👋 Goodbye! Happy coding! 🚀        ║"
    echo "╚══════════════════════════════════════════╝"
}

# Source guard: only run main when executed directly (not sourced)
# This allows tests to source the script and test functions individually
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
