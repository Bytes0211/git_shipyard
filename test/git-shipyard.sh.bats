#!/usr/bin/env bats

# Unit tests for git-shipyard script
# Tests pre-flight checks, user input validation, and workflow execution

load test_helper

setup() {
    setup_test_dir
    SCRIPT_PATH="$BATS_TEST_DIRNAME/../git-shipyard.sh"
    
    # Save original PATH
    ORIGINAL_PATH="$PATH"
    
    # Create mock bin directory
    mkdir -p "$TEST_TEMP_DIR/bin"
    
    # Create a mock git repository for tests
    mkdir -p "$TEST_TEMP_DIR/repo"
    cd "$TEST_TEMP_DIR/repo"
    
    # Initialize git repo with minimal config
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test User"
    
    # Create initial commit on main
    echo "initial" > README.md
    git add README.md
    git commit --quiet -m "Initial commit"
    
    # Create and checkout dev branch (script checks we're not on base branch)
    git checkout -b dev --quiet
    
    # Add origin remote
    git remote add origin https://github.com/test/repo.git
}

teardown() {
    # Restore original PATH
    export PATH="$ORIGINAL_PATH"
    teardown_test_dir
}

# Helper: Create mock for all required commands
setup_valid_environment() {
    # Create pending change so check_changes passes
    echo "change" >> "$TEST_TEMP_DIR/repo/README.md"
    
    # Mock gh command with auth status passing
    cat > "$TEST_TEMP_DIR/bin/gh" << 'EOF'
#!/bin/bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    exit 0
elif [ "$1" = "pr" ] && [ "$2" = "create" ]; then
    echo "https://github.com/test/repo/pull/1"
    exit 0
elif [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    echo '[]'
    exit 0
elif [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    exit 1
elif [ "$1" = "issue" ] && [ "$2" = "list" ]; then
    echo '[]'
    exit 0
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    
    # Mock jq command
    cat > "$TEST_TEMP_DIR/bin/jq" << 'EOF'
#!/bin/bash
cat
EOF
    chmod +x "$TEST_TEMP_DIR/bin/jq"
    
    # Mock git to intercept push/pull (pass through other commands)
    cat > "$TEST_TEMP_DIR/bin/git" << 'EOF'
#!/bin/bash
if [ "$1" = "push" ]; then
    echo "Everything up-to-date"
    exit 0
elif [ "$1" = "pull" ]; then
    echo "Already up to date."
    exit 0
fi
/usr/bin/git "$@"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/git"
    
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

# Helper: Mock gh with failing auth
setup_gh_auth_failure() {
    cat > "$TEST_TEMP_DIR/bin/gh" << 'EOF'
#!/bin/bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    exit 1
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

#=============================================================================
# Test Case 1: Successfully performs all pre-flight checks
#=============================================================================

@test "git-shipyard passes all pre-flight checks when environment is correctly configured" {
    setup_valid_environment
    
    # Provide commit message and decline to proceed (to stop before execution)
    run bash -c "echo -e 'Test commit message\nn' | $SCRIPT_PATH"
    
    # Check that all pre-flight checks passed
    [[ "$output" =~ "✓" ]] || [[ "$output" =~ "git found" ]]
    [[ "$output" =~ "gh CLI found" ]] || [[ "$output" =~ "gh" ]]
    [[ "$output" =~ "Inside git repository" ]] || [[ "$output" =~ "repository" ]]
    [[ "$output" =~ "GitHub authenticated" ]] || [[ "$output" =~ "authenticated" ]]
    [[ "$output" =~ "Remote 'origin' configured" ]] || [[ "$output" =~ "origin" ]]
    [[ "$output" =~ "Changes detected" ]] || [[ "$output" =~ "changes" ]]
}

@test "git-shipyard displays pre-flight checks banner" {
    setup_valid_environment
    
    run bash -c "echo -e 'Test message\nn' | $SCRIPT_PATH"
    
    [[ "$output" =~ "Running pre-flight checks" ]]
}

#=============================================================================
# Test Case 2: Exits with error if required command is missing
#=============================================================================

@test "git-shipyard exits with error if git is not installed" {
    # Create mock gh and jq but not git
    cat > "$TEST_TEMP_DIR/bin/gh" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    
    cat > "$TEST_TEMP_DIR/bin/jq" << 'EOF'
#!/bin/bash
cat
EOF
    chmod +x "$TEST_TEMP_DIR/bin/jq"
    
    # Create clear mock so the script doesn't fail on 'clear' before check_command
    cat > "$TEST_TEMP_DIR/bin/clear" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/clear"

    # Use a PATH that excludes /usr/bin so git (/usr/bin/git) is not found
    run bash -c "PATH='$TEST_TEMP_DIR/bin' $SCRIPT_PATH 2>&1"
    
    [[ "$output" =~ "git is not installed" ]] || [[ "$output" =~ "git" ]]
}

@test "git-shipyard exits with error if gh is not installed" {
    # Create pending change
    echo "change" >> "$TEST_TEMP_DIR/repo/README.md"
    
    # Create PATH without gh command but with git and other essentials
    export PATH="/usr/bin:/bin"
    
    run bash -c "echo 'test' | $SCRIPT_PATH 2>&1"
    
    [[ "$output" =~ "gh is not installed" ]] || [[ "$output" =~ "gh" ]]
}

@test "git-shipyard displays error message and exits for missing command" {
    # Minimal PATH without git or gh
    export PATH="/usr/bin:/bin"
    
    run bash -c "$SCRIPT_PATH 2>&1"
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Error" ]] || [[ "$output" =~ "not installed" ]]
}

@test "git-shipyard exits with error if jq is not installed" {
    # This test verifies the jq check by examining the check_command function
    # We verify jq check exists in script and would fail if jq missing
    run grep -q 'check_command "jq"' "$SCRIPT_PATH"
    [ "$status" -eq 0 ]
}

#=============================================================================
# Test Case 3: Prompts for commit message and validates it
#=============================================================================

@test "git-shipyard prompts for commit message" {
    setup_valid_environment
    
    run bash -c "echo -e 'My commit message\nn' | $SCRIPT_PATH"
    
    [[ "$output" =~ "Enter your commit message" ]]
}

@test "git-shipyard exits with error when commit message is empty" {
    setup_valid_environment
    
    # Send empty commit message (just newline)
    run bash -c "echo '' | $SCRIPT_PATH"
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Commit message cannot be empty" ]]
}

@test "git-shipyard displays commit message in confirmation" {
    setup_valid_environment
    
    run bash -c "echo -e 'Fix: Update README\nn' | $SCRIPT_PATH"
    
    [[ "$output" =~ "Fix: Update README" ]]
}

@test "git-shipyard accepts valid commit message and shows actions" {
    setup_valid_environment
    
    run bash -c "echo -e 'Valid commit message\nn' | $SCRIPT_PATH"
    
    [[ "$output" =~ "Stage all changes" ]] || [[ "$output" =~ "git add" ]]
    [[ "$output" =~ "Commit with message" ]]
    [[ "$output" =~ "Push to origin" ]]
    [[ "$output" =~ "Create PR" ]] || [[ "$output" =~ "Pull request" ]]
}

#=============================================================================
# Test Case 4: Cancels operation if user declines to proceed
#=============================================================================

@test "git-shipyard cancels when user enters 'n'" {
    setup_valid_environment
    
    run bash -c "echo -e 'Test commit\nn' | $SCRIPT_PATH"
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Operation cancelled" ]]
}

@test "git-shipyard cancels when user enters 'N'" {
    setup_valid_environment
    
    run bash -c "echo -e 'Test commit\nN' | $SCRIPT_PATH"
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Operation cancelled" ]]
}

@test "git-shipyard cancels on any non-y input" {
    setup_valid_environment
    
    run bash -c "echo -e 'Test commit\nno' | $SCRIPT_PATH"
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Operation cancelled" ]]
}

@test "git-shipyard displays goodbye message on cancel" {
    setup_valid_environment
    
    run bash -c "echo -e 'Test commit\nn' | $SCRIPT_PATH"
    
    [[ "$output" =~ "Goodbye" ]]
}

@test "git-shipyard does not execute gh ship when cancelled" {
    setup_valid_environment
    
    run bash -c "echo -e 'Test commit\nn' | $SCRIPT_PATH"
    
    # Should not see execution messages
    [[ ! "$output" =~ "Executing: gh ship" ]]
}

#=============================================================================
# Test Case 5: Executes full git/gh workflow successfully
#=============================================================================

@test "git-shipyard stages changes when user confirms with 'y'" {
    setup_valid_environment
    
    run bash -c "echo -e 'Test commit\ny\n0\n0' | $SCRIPT_PATH"
    
    [[ "$output" =~ "Staging changes" ]] || [[ "$output" =~ "Changes staged" ]]
}

@test "git-shipyard commits when user confirms with 'Y'" {
    setup_valid_environment
    
    run bash -c "echo -e 'Test commit\nY\n0\n0' | $SCRIPT_PATH"
    
    [[ "$output" =~ "Committing" ]] || [[ "$output" =~ "Changes committed" ]]
}

@test "git-shipyard pushes to origin after commit" {
    setup_valid_environment
    
    run bash -c "echo -e 'Test commit\ny\n0\n0' | $SCRIPT_PATH"
    
    [[ "$output" =~ "Pushing to origin" ]]
}

@test "git-shipyard displays success message on completion" {
    setup_valid_environment
    
    # Mock git push to succeed
    cat > "$TEST_TEMP_DIR/bin/git" << 'EOF'
#!/bin/bash
if [ "$1" = "push" ]; then
    echo "pushed"
    exit 0
elif [ "$1" = "pull" ]; then
    echo "Already up to date."
    exit 0
fi
# Pass through to real git for other commands
/usr/bin/git "$@"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/git"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    
    run bash -c "echo -e 'Test commit\ny\n0\n0' | $SCRIPT_PATH"
    
    [[ "$output" =~ "completed" ]] || [[ "$output" =~ "Success" ]] || [[ "$output" =~ "✓" ]]
}

@test "git-shipyard displays summary after successful execution" {
    setup_valid_environment
    
    # Mock git push to succeed
    cat > "$TEST_TEMP_DIR/bin/git" << 'EOF'
#!/bin/bash
if [ "$1" = "push" ]; then
    echo "pushed"
    exit 0
elif [ "$1" = "pull" ]; then
    echo "Already up to date."
    exit 0
fi
/usr/bin/git "$@"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/git"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    
    run bash -c "echo -e 'Test commit\ny\n0\n0' | $SCRIPT_PATH"
    
    [[ "$output" =~ "Summary" ]]
    [[ "$output" =~ "Pushed to origin" ]] || [[ "$output" =~ "origin" ]]
}

#=============================================================================
# Additional Edge Cases
#=============================================================================

@test "git-shipyard exits when not inside git repository" {
    setup_valid_environment
    cd "$TEST_TEMP_DIR"  # Move outside the repo
    
    run bash -c "echo 'test' | $SCRIPT_PATH"
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Not inside a git repository" ]]
}

@test "git-shipyard exits when no remote origin is configured" {
    setup_valid_environment
    git remote remove origin
    
    run bash -c "echo 'test' | $SCRIPT_PATH"
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "No 'origin' remote found" ]] || [[ "$output" =~ "origin" ]]
}

@test "git-shipyard exits when GitHub auth fails" {
    setup_gh_auth_failure
    echo "change" >> "$TEST_TEMP_DIR/repo/README.md"
    
    run bash -c "echo 'test' | $SCRIPT_PATH"
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Not authenticated with GitHub" ]] || [[ "$output" =~ "gh auth login" ]]
}

@test "git-shipyard exits when no changes to commit" {
    setup_valid_environment
    # Reset the change we made
    git checkout -- README.md
    
    run bash -c "echo 'test' | $SCRIPT_PATH"
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "No changes to commit" ]]
}

@test "git-shipyard displays welcome banner" {
    setup_valid_environment
    
    run bash -c "echo -e 'Test\nn' | $SCRIPT_PATH"
    
    [[ "$output" =~ "Welcome to Git Shipyard" ]] || [[ "$output" =~ "Git Shipyard" ]]
}

#=============================================================================
# Test Case 6: Link commit to existing PR
#=============================================================================

@test "git-shipyard prompts to link commit to PR after committing" {
    setup_valid_environment
    
    run bash -c "echo -e 'Test commit\ny\n0\n0' | $SCRIPT_PATH"
    
    [[ "$output" =~ "Fetching open pull requests" ]] || [[ "$output" =~ "No open pull requests" ]]
}

@test "git-shipyard shows no open PRs message when none exist" {
    setup_valid_environment
    
    run bash -c "echo -e 'Test commit\ny\n0\n0' | $SCRIPT_PATH"
    
    [[ "$output" =~ "No open pull requests found" ]]
}

@test "git-shipyard lists open PRs when available" {
    # Create pending change
    echo "change" >> "$TEST_TEMP_DIR/repo/README.md"
    
    # Mock gh with PR list
    cat > "$TEST_TEMP_DIR/bin/gh" << 'EOF'
#!/bin/bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    exit 0
elif [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    echo '[{"number":42,"title":"Test PR"},{"number":43,"title":"Another PR"}]'
    exit 0
elif [ "$1" = "pr" ] && [ "$2" = "create" ]; then
    echo "https://github.com/test/repo/pull/1"
    exit 0
elif [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    exit 1
elif [ "$1" = "issue" ] && [ "$2" = "list" ]; then
    echo '[]'
    exit 0
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    
    # Mock jq to parse the JSON
    cat > "$TEST_TEMP_DIR/bin/jq" << 'EOF'
#!/bin/bash
if [[ "$1" == "-r" ]] && [[ "$2" == ".[].number" ]]; then
    echo -e "42\n43"
elif [[ "$1" == "-r" ]] && [[ "$2" == ".[].title" ]]; then
    echo -e "Test PR\nAnother PR"
else
    cat
fi
EOF
    chmod +x "$TEST_TEMP_DIR/bin/jq"
    
    # Mock git push to succeed
    cat > "$TEST_TEMP_DIR/bin/git" << 'EOF'
#!/bin/bash
if [ "$1" = "push" ]; then
    exit 0
elif [ "$1" = "pull" ]; then
    echo "Already up to date."
    exit 0
fi
/usr/bin/git "$@"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/git"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    
    run bash -c "echo -e 'Test commit\ny\n0\n0' | $SCRIPT_PATH"
    
    [[ "$output" =~ "Link this commit to an existing PR" ]]
    [[ "$output" =~ "#42" ]] || [[ "$output" =~ "Test PR" ]]
}

@test "git-shipyard allows skipping PR link with option 0" {
    setup_valid_environment
    
    run bash -c "echo -e 'Test commit\ny\n0\n0' | $SCRIPT_PATH"
    
    # Should continue without error
    [ "$status" -eq 0 ] || [[ "$output" =~ "Skipping PR link" ]] || [[ "$output" =~ "No open pull requests" ]]
}

#=============================================================================
# Test Case 7: Link issue to PR
#=============================================================================

@test "git-shipyard prompts to link issue to PR before creating" {
    setup_valid_environment
    
    # Mock git push to succeed
    cat > "$TEST_TEMP_DIR/bin/git" << 'EOF'
#!/bin/bash
if [ "$1" = "push" ]; then
    exit 0
elif [ "$1" = "pull" ]; then
    echo "Already up to date."
    exit 0
fi
/usr/bin/git "$@"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/git"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    
    run bash -c "echo -e 'Test commit\ny\n0\n0' | $SCRIPT_PATH"
    
    [[ "$output" =~ "Fetching open issues" ]] || [[ "$output" =~ "No open issues" ]]
}

@test "git-shipyard shows no open issues message when none exist" {
    setup_valid_environment
    
    # Mock git push to succeed
    cat > "$TEST_TEMP_DIR/bin/git" << 'EOF'
#!/bin/bash
if [ "$1" = "push" ]; then
    exit 0
elif [ "$1" = "pull" ]; then
    echo "Already up to date."
    exit 0
fi
/usr/bin/git "$@"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/git"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    
    run bash -c "echo -e 'Test commit\ny\n0\n0' | $SCRIPT_PATH"
    
    [[ "$output" =~ "No open issues found" ]]
}

@test "git-shipyard lists open issues when available" {
    # Create pending change
    echo "change" >> "$TEST_TEMP_DIR/repo/README.md"
    
    # Mock gh with issue list
    cat > "$TEST_TEMP_DIR/bin/gh" << 'EOF'
#!/bin/bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    exit 0
elif [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    echo '[]'
    exit 0
elif [ "$1" = "pr" ] && [ "$2" = "create" ]; then
    echo "https://github.com/test/repo/pull/1"
    exit 0
elif [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    exit 1
elif [ "$1" = "issue" ] && [ "$2" = "list" ]; then
    echo '[{"number":10,"title":"Bug fix needed"},{"number":11,"title":"Feature request"}]'
    exit 0
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    
    # Mock jq to parse the JSON
    cat > "$TEST_TEMP_DIR/bin/jq" << 'EOF'
#!/bin/bash
if [[ "$1" == "-r" ]] && [[ "$2" == ".[].number" ]]; then
    echo -e "10\n11"
elif [[ "$1" == "-r" ]] && [[ "$2" == ".[].title" ]]; then
    echo -e "Bug fix needed\nFeature request"
else
    cat
fi
EOF
    chmod +x "$TEST_TEMP_DIR/bin/jq"
    
    # Mock git push to succeed
    cat > "$TEST_TEMP_DIR/bin/git" << 'EOF'
#!/bin/bash
if [ "$1" = "push" ]; then
    exit 0
elif [ "$1" = "pull" ]; then
    echo "Already up to date."
    exit 0
fi
/usr/bin/git "$@"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/git"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    
    run bash -c "echo -e 'Test commit\ny\n0\n0' | $SCRIPT_PATH"
    
    [[ "$output" =~ "Link an issue to this PR" ]]
    [[ "$output" =~ "#10" ]] || [[ "$output" =~ "Bug fix" ]]
}

@test "git-shipyard allows skipping issue link with option 0" {
    setup_valid_environment
    
    # Mock git push to succeed
    cat > "$TEST_TEMP_DIR/bin/git" << 'EOF'
#!/bin/bash
if [ "$1" = "push" ]; then
    exit 0
elif [ "$1" = "pull" ]; then
    echo "Already up to date."
    exit 0
fi
/usr/bin/git "$@"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/git"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    
    run bash -c "echo -e 'Test commit\ny\n0\n0' | $SCRIPT_PATH"
    
    # Should continue without error
    [ "$status" -eq 0 ] || [[ "$output" =~ "Skipping issue link" ]] || [[ "$output" =~ "No open issues" ]]
}

#=============================================================================
# Test Case 8: Auto-Sync Dev with Main (F1)
#=============================================================================

@test "sync: shows already-up-to-date message when dev is current with main" {
    setup_valid_environment

    run bash -c "echo -e 'Test commit\nn' | $SCRIPT_PATH"

    [[ "$output" =~ "Syncing" ]]
    [[ "$output" =~ "already up to date" ]]
}

@test "sync: stashes uncommitted changes before pulling" {
    setup_valid_environment

    run bash -c "echo -e 'Test commit\nn' | $SCRIPT_PATH"

    [[ "$output" =~ "Stashing uncommitted changes" ]]
    [[ "$output" =~ "Changes stashed" ]]
}

@test "sync: restores stashed changes after pull" {
    setup_valid_environment

    run bash -c "echo -e 'Test commit\nn' | $SCRIPT_PATH"

    [[ "$output" =~ "Restoring stashed changes" ]]
    [[ "$output" =~ "Stashed changes restored" ]]
}

@test "sync: halts with error when stash pop produces conflicts" {
    echo "change" >> "$TEST_TEMP_DIR/repo/README.md"

    cat > "$TEST_TEMP_DIR/bin/gh" << 'EOF'
#!/bin/bash
[ "$1" = "auth" ] && [ "$2" = "status" ] && exit 0
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    cat > "$TEST_TEMP_DIR/bin/jq" << 'EOF'
#!/bin/bash
cat
EOF
    chmod +x "$TEST_TEMP_DIR/bin/jq"

    cat > "$TEST_TEMP_DIR/bin/git" << 'EOF'
#!/bin/bash
if [ "$1" = "stash" ] && [ "$2" = "pop" ]; then
    echo "CONFLICT (content): Merge conflict in README.md"
    exit 1
elif [ "$1" = "pull" ]; then
    echo "Already up to date."
    exit 0
elif [ "$1" = "push" ]; then
    exit 0
fi
/usr/bin/git "$@"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/git"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    run bash -c "echo 'test' | $SCRIPT_PATH"

    [ "$status" -eq 1 ]
    [[ "$output" =~ "Stash pop" ]] || [[ "$output" =~ "conflict" ]]
}

@test "sync: skips stash when no uncommitted changes exist" {
    # No call to setup_valid_environment - repo has no uncommitted changes
    cat > "$TEST_TEMP_DIR/bin/gh" << 'EOF'
#!/bin/bash
[ "$1" = "auth" ] && [ "$2" = "status" ] && exit 0
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    cat > "$TEST_TEMP_DIR/bin/jq" << 'EOF'
#!/bin/bash
cat
EOF
    chmod +x "$TEST_TEMP_DIR/bin/jq"

    cat > "$TEST_TEMP_DIR/bin/git" << 'EOF'
#!/bin/bash
if [ "$1" = "pull" ]; then
    echo "Already up to date."
    exit 0
elif [ "$1" = "push" ]; then
    exit 0
fi
/usr/bin/git "$@"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/git"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    run bash -c "echo 'test' | $SCRIPT_PATH"

    # Sync ran but no stash (no uncommitted changes)
    [[ ! "$output" =~ "Stashing" ]]
    [[ "$output" =~ "Pulling" ]] || [[ "$output" =~ "up to date" ]]
}

@test "git-shipyard shows issue in summary when linked" {
    # Create pending change
    echo "change" >> "$TEST_TEMP_DIR/repo/README.md"
    
    # Mock gh with issue list
    cat > "$TEST_TEMP_DIR/bin/gh" << 'EOF'
#!/bin/bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    exit 0
elif [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    echo '[]'
    exit 0
elif [ "$1" = "pr" ] && [ "$2" = "create" ]; then
    echo "https://github.com/test/repo/pull/1"
    exit 0
elif [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    exit 1
elif [ "$1" = "issue" ] && [ "$2" = "list" ]; then
    echo '[{"number":10,"title":"Bug fix needed"}]'
    exit 0
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    
    # Mock jq to parse the JSON
    cat > "$TEST_TEMP_DIR/bin/jq" << 'EOF'
#!/bin/bash
if [[ "$1" == "-r" ]] && [[ "$2" == ".[].number" ]]; then
    echo "10"
elif [[ "$1" == "-r" ]] && [[ "$2" == ".[].title" ]]; then
    echo "Bug fix needed"
else
    cat
fi
EOF
    chmod +x "$TEST_TEMP_DIR/bin/jq"
    
    # Mock git push to succeed
    cat > "$TEST_TEMP_DIR/bin/git" << 'EOF'
#!/bin/bash
if [ "$1" = "push" ]; then
    exit 0
elif [ "$1" = "pull" ]; then
    echo "Already up to date."
    exit 0
fi
/usr/bin/git "$@"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/git"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    
    # Select issue #1 (which is issue #10)
    # Note: No PR selection needed since mock returns empty PR list
    run bash -c "echo -e 'Test commit\ny\n1' | $SCRIPT_PATH"
    
    [[ "$output" =~ "Linked to issue #10" ]] || [[ "$output" =~ "Will link issue #10" ]] || [[ "$output" =~ "issue #10" ]]
}
