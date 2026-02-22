#!/bin/bash

# ============================================
#   🔧  Git Branch Management Tool  🔧
# ============================================

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║                                          ║"
echo "║   🔧  Git Branch Management Tool  🔧      ║"
echo "║                                          ║"
echo "║   Delete or create branches safely       ║"
echo "║                                          ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Check if we're inside a git repository
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "❌ ERROR: Not inside a git repository."
    echo "👉 Please navigate to a git repository and try again."
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║        👋 Goodbye! See you later!        ║"
    echo "╚══════════════════════════════════════════╝"
    exit 1
fi

echo "📂 Repository: $(basename $(git rev-parse --show-toplevel))"
current_branch=$(git branch --show-current)
echo "🌿 Current branch: $current_branch"
echo ""

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "⚠️  WARNING: You have uncommitted changes."
    echo "👉 Please commit or stash them before running this script."
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║        👋 Goodbye! See you later!        ║"
    echo "╚══════════════════════════════════════════╝"
    exit 1
fi

# Build array of branches
branches=()
while IFS= read -r branch; do
    # Strip leading whitespace and the * marker for current branch
    clean_branch=$(echo "$branch" | sed 's/^[* ]*//')
    branches+=("$clean_branch")
done < <(git branch --list)

# Check if any branches exist
if [ ${#branches[@]} -eq 0 ]; then
    echo "❌ ERROR: No branches found in this repository."
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║        👋 Goodbye! See you later!        ║"
    echo "╚══════════════════════════════════════════╝"
    exit 1
fi

# Display numbered branch list
echo "📋 Available branches:"
echo ""
for i in "${!branches[@]}"; do
    num=$((i + 1))
    branch="${branches[$i]}"
    if [ "$branch" == "$current_branch" ]; then
        echo "   $num) $branch  ← (current)"
    else
        echo "   $num) $branch"
    fi
done

# Add create new branch option as the last number
create_option=$(( ${#branches[@]} + 1 ))
echo ""
echo "   $create_option) 🌱 Create a new branch"
echo ""

# Ask user to pick a number
read -p "🔢 Enter your choice (1-$create_option): " selection

# Validate input is not empty
if [ -z "$selection" ]; then
    echo ""
    echo "❌ ERROR: No selection made."
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║        👋 Goodbye! See you later!        ║"
    echo "╚══════════════════════════════════════════╝"
    exit 1
fi

# Validate input is a number
if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
    echo ""
    echo "❌ ERROR: Invalid input. Please enter a number."
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║        👋 Goodbye! See you later!        ║"
    echo "╚══════════════════════════════════════════╝"
    exit 1
fi

# Validate input is within range
if [ "$selection" -lt 1 ] || [ "$selection" -gt "$create_option" ]; then
    echo ""
    echo "❌ ERROR: Invalid selection. Please choose a number between 1 and $create_option."
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║        👋 Goodbye! See you later!        ║"
    echo "╚══════════════════════════════════════════╝"
    exit 1
fi

# ============================================
# Handle CREATE NEW BRANCH
# ============================================
if [ "$selection" -eq "$create_option" ]; then
    echo ""
    read -p "🌱 Enter the name for the new branch: " new_branch_name

    # Validate input is not empty
    if [ -z "$new_branch_name" ]; then
        echo ""
        echo "❌ ERROR: No branch name provided."
        echo ""
        echo "╔══════════════════════════════════════════╗"
        echo "║        👋 Goodbye! See you later!        ║"
        echo "╚══════════════════════════════════════════╝"
        exit 1
    fi

    # Check if branch already exists locally
    if git show-ref --verify --quiet refs/heads/"$new_branch_name"; then
        echo ""
        echo "❌ ERROR: Branch '$new_branch_name' already exists locally."
        echo ""
        echo "╔══════════════════════════════════════════╗"
        echo "║        👋 Goodbye! See you later!        ║"
        echo "╚══════════════════════════════════════════╝"
        exit 1
    fi

    # Confirm creation
    echo ""
    echo "📝 Summary of actions:"
    echo "   🌱 Create new branch: $new_branch_name"
    echo "   🔄 Switch to: $new_branch_name"
    echo ""
    read -p "⚠️  Are you sure you want to continue? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo ""
        echo "🚫 Aborted. No changes were made."
        echo ""
        echo "╔══════════════════════════════════════════╗"
        echo "║        👋 Goodbye! See you later!        ║"
        echo "╚══════════════════════════════════════════╝"
        exit 0
    fi

    echo ""
    echo "🌱 Creating branch '$new_branch_name'..."
    git checkout -b "$new_branch_name"
    if [ $? -ne 0 ]; then
        echo "❌ ERROR: Failed to create branch '$new_branch_name'."
        echo ""
        echo "╔══════════════════════════════════════════╗"
        echo "║        👋 Goodbye! See you later!        ║"
        echo "╚══════════════════════════════════════════╝"
        exit 1
    fi

    echo ""
    echo "🎉 All done!"
    echo "   ✅ Branch '$new_branch_name' created and checked out."
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║     👋 Goodbye! Happy coding! 🚀        ║"
    echo "╚══════════════════════════════════════════╝"
    exit 0
fi

# ============================================
# Handle DELETE BRANCH
# ============================================

# Get the selected branch name
branch_index=$((selection - 1))
branch_name="${branches[$branch_index]}"

echo ""
echo "🗑️  You selected: $branch_name"

# Prevent deletion of main/master branches
if [[ "$branch_name" == "main" || "$branch_name" == "master" ]]; then
    echo ""
    echo "🚫 ERROR: Cannot delete the '$branch_name' branch. That's a protected branch!"
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║        👋 Goodbye! See you later!        ║"
    echo "╚══════════════════════════════════════════╝"
    exit 1
fi

# Notify if on the branch being deleted
if [ "$branch_name" == "$current_branch" ]; then
    echo "⚠️  You are currently on the '$branch_name' branch."
    echo "👉 Will switch to main before deleting."
fi

# Check if local branch exists
LOCAL_EXISTS=false
if git show-ref --verify --quiet refs/heads/"$branch_name"; then
    LOCAL_EXISTS=true
    echo "✅ Local branch '$branch_name' found."
else
    echo "⚠️  Local branch '$branch_name' does not exist."
fi

# Check if remote branch exists
REMOTE_EXISTS=false
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
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║        👋 Goodbye! See you later!        ║"
    echo "╚══════════════════════════════════════════╝"
    exit 1
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
read -p "⚠️  Are you sure you want to continue? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo ""
    echo "🚫 Aborted. No branches were deleted."
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║        👋 Goodbye! See you later!        ║"
    echo "╚══════════════════════════════════════════╝"
    exit 0
fi

echo ""

# Switch to main if on the branch being deleted
if [ "$branch_name" == "$current_branch" ]; then
    echo "🔄 Switching to main branch..."
    git checkout main
    if [ $? -ne 0 ]; then
        echo "❌ ERROR: Failed to checkout main branch."
        echo ""
        echo "╔══════════════════════════════════════════╗"
        echo "║        👋 Goodbye! See you later!        ║"
        echo "╚══════════════════════════════════════════╝"
        exit 1
    fi
    echo "✅ Switched to main."
    echo ""
fi

# Delete local branch
if [ "$LOCAL_EXISTS" = true ]; then
    echo "🗑️  Deleting local branch '$branch_name'..."
    git branch -D "$branch_name"
    if [ $? -ne 0 ]; then
        echo "❌ ERROR: Failed to delete local branch '$branch_name'."
        echo ""
        echo "╔══════════════════════════════════════════╗"
        echo "║        👋 Goodbye! See you later!        ║"
        echo "╚══════════════════════════════════════════╝"
        exit 1
    fi
    echo "✅ Local branch '$branch_name' deleted."
    echo ""
fi

# Delete remote branch
if [ "$REMOTE_EXISTS" = true ]; then
    echo "🗑️  Deleting remote branch 'origin/$branch_name'..."
    git push origin --delete "$branch_name"
    if [ $? -ne 0 ]; then
        echo "❌ ERROR: Failed to delete remote branch '$branch_name'."
        echo ""
        echo "╔══════════════════════════════════════════╗"
        echo "║        👋 Goodbye! See you later!        ║"
        echo "╚══════════════════════════════════════════╝"
        exit 1
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
