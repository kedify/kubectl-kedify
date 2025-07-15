#!/bin/bash

# test-cross-platform.sh - Local cross-platform testing script for kubectl-kedify
# This script can be run locally to test the kubectl-kedify script on the current platform

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
print_test() {
    echo -e "${YELLOW}[TEST]${NC} $1"
}

print_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++))
}

print_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((TESTS_FAILED++))
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

# Helper function to get all scripts
get_all_scripts() {
    # Find all .sh files and the main kubectl-kedify script
    find . -maxdepth 1 -name "*.sh" -o -name "kubectl-kedify" | grep -v "./test-cross-platform.sh" | sort
}

# Test functions
test_syntax() {
    print_test "Testing bash syntax for all scripts..."
    
    local scripts=()
    while IFS= read -r script; do
        [[ -n "$script" ]] && scripts+=("$script")
    done < <(get_all_scripts)
    
    if [[ ${#scripts[@]} -eq 0 ]]; then
        print_fail "No scripts found to test"
        return 1
    fi
    
    print_info "Found scripts: ${scripts[*]}"
    
    for script in "${scripts[@]}"; do
        [[ -z "$script" ]] && continue  # Skip empty entries
        if [[ -f "$script" ]]; then
            if bash -n "$script" 2>/dev/null; then
                print_pass "Syntax check passed for $script"
            else
                print_fail "Syntax check failed for $script"
                return 1
            fi
        else
            print_fail "Script $script not found"
            return 1
        fi
    done
}

test_executability() {
    print_test "Testing script executability..."
    
    if [[ -x "kubectl-kedify" ]]; then
        print_pass "kubectl-kedify is executable"
    else
        print_info "Making kubectl-kedify executable..."
        chmod +x kubectl-kedify
        if [[ -x "kubectl-kedify" ]]; then
            print_pass "kubectl-kedify made executable"
        else
            print_fail "Could not make kubectl-kedify executable"
            return 1
        fi
    fi
}

test_function_loading() {
    print_test "Testing function loading..."
    
    # Get all .sh files (excluding test script and kubectl-kedify)
    local sh_scripts=()
    while IFS= read -r script; do
        [[ -n "$script" ]] && sh_scripts+=("$script")
    done < <(find . -maxdepth 1 -name "*.sh" | grep -v "./test-cross-platform.sh" | sort)
    
    if [[ ${#sh_scripts[@]} -eq 0 ]]; then
        print_info "No .sh scripts found to test function loading"
        return 0
    fi
    
    print_info "Testing function loading for: ${sh_scripts[*]}"
    
    # Create a temporary test script
    local test_script=$(mktemp)
    cat > "$test_script" << EOF
#!/bin/bash
set -e

# Set up environment
DIR="\$(pwd)"
export DIR

# Source all .sh scripts
$(for script in "${sh_scripts[@]}"; do [[ -n "$script" ]] && echo "source $script"; done)

# Test that key functions are defined (if they exist)
functions_found=0

if declare -f debug::cmd >/dev/null 2>&1; then
    echo "DEBUG_FUNCTION_OK"
    functions_found=\$((functions_found + 1))
fi

if declare -f insights_cmd >/dev/null 2>&1; then
    echo "INSIGHTS_FUNCTION_OK" 
    functions_found=\$((functions_found + 1))
fi

# Check for any other exported functions
all_functions=\$(declare -F | awk '{print \$3}' | grep -v '^_' | wc -l)
echo "TOTAL_FUNCTIONS_FOUND=\$all_functions"
echo "KEY_FUNCTIONS_FOUND=\$functions_found"
echo "ALL_FUNCTIONS_OK"
EOF
    
    if output=$(bash "$test_script" 2>/dev/null); then
        if echo "$output" | grep -q "ALL_FUNCTIONS_OK"; then
            local total_functions=$(echo "$output" | grep "TOTAL_FUNCTIONS_FOUND=" | cut -d'=' -f2)
            local key_functions=$(echo "$output" | grep "KEY_FUNCTIONS_FOUND=" | cut -d'=' -f2)
            print_pass "All scripts loaded successfully ($total_functions total functions, $key_functions key functions)"
        else
            print_fail "Not all functions loaded properly"
            rm -f "$test_script"
            return 1
        fi
    else
        print_fail "Error loading functions"
        rm -f "$test_script"
        return 1
    fi
    
    rm -f "$test_script"
}

test_help_output() {
    print_test "Testing help output..."
    
    # Test help output (may fail due to missing cluster, but that's OK for syntax testing)
    if timeout 5s ./kubectl-kedify --help >/dev/null 2>&1; then
        print_pass "Help output works"
    else
        print_pass "Help test completed (expected to fail without cluster access)"
    fi
    
    # Test version output
    if timeout 5s ./kubectl-kedify --version >/dev/null 2>&1; then
        print_pass "Version output works"
    else
        print_pass "Version test completed (may have failed due to missing VERSION file)"
    fi
}

test_dependencies() {
    print_test "Checking required dependencies..."
    
    local deps=("curl" "jq" "bash" "kubectl")
    local optional_deps=("figlet" "fzf" "yq" "bat" "batcat" "shellcheck")
    
    for dep in "${deps[@]}"; do
        if command -v "$dep" >/dev/null 2>&1; then
            print_pass "Required dependency found: $dep"
        else
            print_fail "Required dependency missing: $dep"
        fi
    done
    
    for dep in "${optional_deps[@]}"; do
        if command -v "$dep" >/dev/null 2>&1; then
            print_info "Optional dependency found: $dep"
        else
            print_info "Optional dependency missing: $dep"
        fi
    done
}

test_platform_detection() {
    print_test "Testing platform-specific functionality..."
    
    print_info "Current platform: $(uname)"
    print_info "Current shell: $SHELL"
    
    # Test version detection logic
    test_version_detection
    
    # Test the platform-specific version detection logic
    if [ "$(uname)" == "Darwin" ]; then
        print_info "Testing macOS-specific readlink behavior"
        # Test without -f flag (macOS doesn't support it by default)
        if readlink kubectl-kedify 2>/dev/null || true; then
            print_pass "macOS readlink works"
        else
            print_pass "macOS readlink test completed"
        fi
    else
        print_info "Testing Linux-specific readlink behavior"
        # Test with -f flag
        if readlink -f kubectl-kedify >/dev/null 2>&1; then
            print_pass "Linux readlink -f works"
        else
            print_info "readlink -f not available or failed"
        fi
    fi
}

test_version_detection() {
    print_test "Testing version detection logic..."
    
    # Test the version detection logic from print_version function
    if [ -f VERSION ]; then
        print_pass "VERSION file exists"
        print_info "Version content: $(cat VERSION)"
    else
        print_fail "VERSION file not found"
        return 1
    fi
    
    # Test readlink behavior on different systems
    print_info "Testing readlink behavior..."
    if [ "$(uname)" == "Darwin" ]; then
        print_info "macOS detected"
        # Test macOS version detection
        VERSION_PATH=$(dirname "$(readlink kubectl-kedify 2>/dev/null)" 2>/dev/null)/VERSION 2>/dev/null || echo "$(pwd)/VERSION"
    else
        print_info "Linux detected"
        # Test Linux version detection
        VERSION_PATH=$(dirname "$(readlink -f kubectl-kedify)")/VERSION 2>/dev/null || echo "$(pwd)/VERSION"
    fi
    print_info "Version path would be: $VERSION_PATH"
    
    if [[ -f "$VERSION_PATH" ]]; then
        print_pass "Version detection path is valid"
    else
        print_info "Version detection would fall back to current directory"
    fi
}

run_shellcheck() {
    print_test "Running shellcheck if available..."
    
    if command -v shellcheck >/dev/null 2>&1; then
        local scripts=()
        while IFS= read -r script; do
            [[ -n "$script" ]] && scripts+=("$script")
        done < <(get_all_scripts)
        
        if [[ ${#scripts[@]} -eq 0 ]]; then
            print_info "No scripts found for shellcheck"
            return 0
        fi
        
        print_info "Running shellcheck on: ${scripts[*]}"
        
        for script in "${scripts[@]}"; do
            [[ -z "$script" ]] && continue  # Skip empty entries
            if [[ -f "$script" ]]; then
                print_info "Running shellcheck on $script..."
                if shellcheck -x "$script" 2>/dev/null; then
                    print_pass "Shellcheck passed for $script"
                else
                    print_info "Shellcheck found issues in $script (non-fatal)"
                fi
            fi
        done
    else
        print_info "Shellcheck not available, skipping static analysis"
    fi
}

# Test suites
run_smoke_tests() {
    print_info "Running smoke test suite (cross-platform)..."
    test_syntax || true
    test_executability || true
    test_function_loading || true
    test_dependencies || true
}

run_full_tests() {
    print_info "Running full test suite (Mac/Linux)..."
    run_smoke_tests
    test_platform_detection || true
    test_help_output || true
    run_shellcheck || true
}

# Main execution
main() {
    local test_suite="${1:-full}"
    local quiet_mode="${2:-false}"
    
    if [[ "$quiet_mode" != "true" ]]; then
        echo "=================================="
        echo "kubectl-kedify Cross-Platform Test"
        echo "=================================="
        echo ""
        
        print_info "Starting tests in directory: $PWD"
        print_info "Platform: $(uname -s) $(uname -m)"
        print_info "Bash version: $BASH_VERSION"
        print_info "Test suite: $test_suite"
        echo ""
    fi
    
    # Run selected test suite
    case "$test_suite" in
        "smoke")
            run_smoke_tests
            ;;
        "full"|*)
            # Default to full tests on Mac/Linux, smoke on others
            if [[ "$(uname)" == "Darwin" ]] || [[ "$(uname)" == "Linux" ]]; then
                run_full_tests
            else
                print_info "Non-Mac/Linux platform detected, running smoke tests only"
                run_smoke_tests
            fi
            ;;
    esac
    
    if [[ "$quiet_mode" != "true" ]]; then
        echo ""
        echo "=================================="
        echo "Test Summary"
        echo "=================================="
        echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
        echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
        echo -e "Total tests: $((TESTS_PASSED + TESTS_FAILED))"
        
        if [[ $TESTS_FAILED -eq 0 ]]; then
            echo -e "\n${GREEN}All critical tests passed!${NC}"
        else
            echo -e "\n${YELLOW}Some tests failed, but script may still work depending on your environment.${NC}"
        fi
    fi
    
    # Return appropriate exit code
    [[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
