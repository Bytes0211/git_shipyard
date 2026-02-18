#!/usr/bin/env bash

# Test Helper Functions
# Common utilities and setup/teardown functions for BATS tests

# Create a temporary directory for test files
setup_test_dir() {
    TEST_TEMP_DIR="$(mktemp -d)"
    export TEST_TEMP_DIR
}

# Clean up temporary directory
teardown_test_dir() {
    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Mock command - create a fake executable in PATH
mock_command() {
    local command_name="$1"
    local mock_script="$2"
    
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/$command_name" << EOF
#!/bin/bash
$mock_script
EOF
    chmod +x "$TEST_TEMP_DIR/bin/$command_name"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

# Create a mock file with specific content
create_mock_file() {
    local file_path="$1"
    local content="$2"
    
    mkdir -p "$(dirname "$file_path")"
    echo "$content" > "$file_path"
}

# Assert file exists
assert_file_exists() {
    local file="$1"
    [ -f "$file" ]
}

# Assert file contains string
assert_file_contains() {
    local file="$1"
    local expected="$2"
    grep -q "$expected" "$file"
}

# Assert output contains string
assert_output_contains() {
    local expected="$1"
    echo "$output" | grep -q "$expected"
}

# Assert exit code equals expected
assert_exit_code() {
    local expected="$1"
    [ "$status" -eq "$expected" ]
}

# Strip ANSI color codes from output
strip_colors() {
    echo "$1" | sed 's/\x1b\[[0-9;]*m//g'
}
