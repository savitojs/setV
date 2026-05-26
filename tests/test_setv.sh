#!/usr/bin/env bash
# setV test suite - runs in both bash and zsh
#
# Usage:
#   ./tests/test_setv.sh          # run with current shell
#   bash ./tests/test_setv.sh     # bash only
#   zsh ./tests/test_setv.sh      # zsh only

set -euo pipefail

# --- Test framework ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SETV_SRC="$SCRIPT_DIR/../setv.sh"
TEST_VENV_DIR=$(mktemp -d)
_TEST_OUT=$(mktemp)
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAIL_NAMES=()

# Detect shell
if [[ -n "${ZSH_VERSION:-}" ]]; then
    SHELL_NAME="zsh"
else
    SHELL_NAME="bash"
fi

# Colors
if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'
    RED=$'\033[0;31m'
    YELLOW=$'\033[0;33m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RESET=$'\033[0m'
else
    GREEN="" RED="" YELLOW="" BOLD="" DIM="" RESET=""
fi

assert_ok() {
    local desc="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    if eval "$2" 2>/dev/null; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} $desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAIL_NAMES+=("$desc")
        echo -e "  ${RED}FAIL${RESET} $desc"
    fi
}

assert_fail() {
    local desc="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    if eval "$2" 2>/dev/null; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAIL_NAMES+=("$desc")
        echo -e "  ${RED}FAIL${RESET} $desc ${DIM}(expected failure)${RESET}"
    else
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} $desc"
    fi
}

assert_contains() {
    local desc="$1"
    local output="$2"
    local expected="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$output" | grep -q "$expected" 2>/dev/null; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} $desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAIL_NAMES+=("$desc")
        echo -e "  ${RED}FAIL${RESET} $desc ${DIM}(expected '$expected')${RESET}"
    fi
}

# capture_run: Run a setv command in the current shell (preserving side
# effects like VIRTUAL_ENV), capturing combined stdout+stderr to $out.
# Usage:  capture_run setv -n test_create
#         capture_run_expect_fail setv nonexistent
capture_run() {
    "$@" > "$_TEST_OUT" 2>&1 || true
    out=$(<"$_TEST_OUT")
}

# --- Setup ---

setup() {
    export SETV_VIRTUAL_DIR_PATH="$TEST_VENV_DIR"
    export SETV_AUTO_ACTIVATE=false  # disable cd hook during tests
    # shellcheck disable=SC1090
    source "$SETV_SRC" 2>/dev/null
}

cleanup() {
    deactivate 2>/dev/null || true
    rm -rf "$TEST_VENV_DIR" "$_TEST_OUT"
}

trap cleanup EXIT

# --- Tests ---

echo ""
echo "${BOLD}setV Test Suite${RESET} ${DIM}($SHELL_NAME)${RESET}"
echo "${DIM}Environment: $TEST_VENV_DIR${RESET}"
echo ""

setup

# -- Version & Help --
echo "${YELLOW}Version & Help${RESET}"

capture_run setv --version
assert_contains "version output" "$out" "setv 3"

capture_run setv --help
assert_contains "help shows BASICS" "$out" "BASICS"
assert_contains "help shows BACKUP" "$out" "BACKUP"
assert_contains "help shows CONFIG" "$out" "CONFIG"

capture_run setv --backend
assert_contains "backend detection" "$out" "Backend:"

# -- Create --
echo ""
echo "${YELLOW}Create${RESET}"

capture_run setv -n test_create
assert_contains "create with uv/venv" "$out" "Activated test_create"
assert_ok "env directory exists" "[[ -d '$TEST_VENV_DIR/test_create' ]]"
assert_ok "python binary exists" "[[ -x '$TEST_VENV_DIR/test_create/bin/python' ]]"
assert_ok "VIRTUAL_ENV is set" "[[ -n '${VIRTUAL_ENV:-}' ]]"
deactivate 2>/dev/null || true

capture_run setv -n test_create
assert_contains "create duplicate fails" "$out" "already exists"

capture_run setv -n '../evil'
assert_contains "path traversal rejected" "$out" "Invalid"

capture_run setv -n
assert_contains "create without name fails" "$out" "Missing"

# -- Activate --
echo ""
echo "${YELLOW}Activate${RESET}"

capture_run setv test_create
assert_contains "activate existing env" "$out" "Activated test_create"
assert_ok "VIRTUAL_ENV set correctly" "[[ '${VIRTUAL_ENV:-}' == '$TEST_VENV_DIR/test_create' ]]"
deactivate 2>/dev/null || true

capture_run setv nonexistent
assert_contains "activate nonexistent fails" "$out" "does not exist"

# -- List --
echo ""
echo "${YELLOW}List${RESET}"

capture_run setv -l
assert_contains "list shows env" "$out" "test_create"
assert_contains "list shows ENVIRONMENT header" "$out" "ENVIRONMENT"

# -- Info --
echo ""
echo "${YELLOW}Info${RESET}"

capture_run setv -i test_create
assert_contains "info shows name" "$out" "test_create"
assert_contains "info shows path" "$out" "$TEST_VENV_DIR/test_create"
assert_contains "info shows python" "$out" "Python"
assert_contains "info shows backend" "$out" "Backend:"
assert_contains "info shows size" "$out" "Size:"

# -- Link / Unlink / cd --
echo ""
echo "${YELLOW}Project Linking${RESET}"

capture_run setv --link test_create
assert_contains "link project" "$out" "Linked"
assert_ok "link file exists" "[[ -f '$TEST_VENV_DIR/.setv/test_create.link' ]]"

capture_run setv -i test_create
assert_contains "info shows project link" "$out" "Project:"

capture_run setv --unlink test_create
assert_contains "unlink project" "$out" "Unlinked"
assert_ok "link file removed" "[[ ! -f '$TEST_VENV_DIR/.setv/test_create.link' ]]"

# -- Freeze --
echo ""
echo "${YELLOW}Freeze${RESET}"

capture_run setv test_create
# install a package to freeze (use --python to target the venv explicitly)
if command -v uv &>/dev/null; then
    uv pip install --python "$TEST_VENV_DIR/test_create/bin/python" six &>/dev/null || true
else
    "$TEST_VENV_DIR/test_create/bin/pip" install six &>/dev/null || true
fi

capture_run setv freeze
assert_contains "freeze shows packages" "$out" "six"

capture_run setv freeze test_create
assert_contains "freeze by name" "$out" "six"

# -- Auto-freeze on deactivate --
echo ""
echo "${YELLOW}Auto-freeze${RESET}"

deactivate 2>/dev/null || true
assert_ok "requirements file created" "[[ -f '$TEST_VENV_DIR/.setv/test_create.requirements.txt' ]]"

out=$(cat "$TEST_VENV_DIR/.setv/test_create.requirements.txt" 2>/dev/null) || true
assert_contains "auto-freeze saved six" "$out" "six"

# -- Backup --
echo ""
echo "${YELLOW}Backup${RESET}"

backup_dir=$(mktemp -d)
capture_run setv backup "$backup_dir"
assert_contains "backup success message" "$out" "Backed up"
assert_ok "manifest exists" "[[ -f '$backup_dir/manifest.json' ]]"
assert_ok "requirements in backup" "[[ -f '$backup_dir/test_create.requirements.txt' ]]"

manifest=$(cat "$backup_dir/manifest.json" 2>/dev/null) || true
assert_contains "manifest has env name" "$manifest" "test_create"
assert_contains "manifest has python version" "$manifest" "python"

# -- Delete --
echo ""
echo "${YELLOW}Delete${RESET}"

echo "y" | setv -d test_create > "$_TEST_OUT" 2>&1 || true
out=$(<"$_TEST_OUT")
assert_contains "delete confirms" "$out" "Deleted"
assert_ok "env directory removed" "[[ ! -d '$TEST_VENV_DIR/test_create' ]]"

# -- Restore --
echo ""
echo "${YELLOW}Restore${RESET}"

capture_run setv restore "$backup_dir"
assert_contains "restore success" "$out" "restored"
assert_ok "env recreated" "[[ -d '$TEST_VENV_DIR/test_create' ]]"

deactivate 2>/dev/null || true
capture_run setv freeze test_create
assert_contains "packages restored" "$out" "six"

rm -rf "$backup_dir"

# -- Doctor --
echo ""
echo "${YELLOW}Doctor${RESET}"

capture_run setv doctor
assert_contains "doctor shows env" "$out" "test_create"
assert_contains "doctor shows OK" "$out" "OK"

# -- Rebuild --
echo ""
echo "${YELLOW}Rebuild${RESET}"

# Break the env
rm -f "$TEST_VENV_DIR/test_create/bin/python" "$TEST_VENV_DIR/test_create/bin/python3"

capture_run setv doctor
assert_contains "doctor detects broken" "$out" "BROKEN"

capture_run setv rebuild test_create
assert_contains "rebuild succeeds" "$out" "rebuilt"
assert_contains "rebuild restores packages" "$out" "Restored"

deactivate 2>/dev/null || true
capture_run setv doctor
assert_contains "doctor shows fixed" "$out" "OK"

capture_run setv freeze test_create
assert_contains "packages survived rebuild" "$out" "six"

# -- Tmp env --
echo ""
echo "${YELLOW}Temporary Environment${RESET}"

deactivate 2>/dev/null || true
capture_run setv --tmp
assert_contains "tmp env created" "$out" "Activated tmp_"
assert_ok "tmp env VIRTUAL_ENV set" "[[ -n '${VIRTUAL_ENV:-}' ]]"
tmp_name=$(basename "${VIRTUAL_ENV:-none}")
assert_ok "tmp env directory exists" "[[ -d '$TEST_VENV_DIR/$tmp_name' ]]"

deactivate 2>/dev/null || true
assert_ok "tmp env deleted on deactivate" "[[ ! -d '$TEST_VENV_DIR/$tmp_name' ]]"

# -- Run without activate --
echo ""
echo "${YELLOW}Run Without Activate${RESET}"

deactivate 2>/dev/null || true
capture_run setv --run test_create -- python --version
assert_contains "run shows python version" "$out" "Python"
assert_ok "shell not activated after run" "[[ -z '${VIRTUAL_ENV:-}' ]]"

capture_run setv --run test_create -- python -c 'import sys; print(sys.prefix)'
assert_contains "run uses correct env" "$out" "test_create"

capture_run setv --run nonexistent -- python --version
assert_contains "run nonexistent fails" "$out" "does not exist"

# -- Auto-activate --
echo ""
echo "${YELLOW}Auto-activate (cd hook)${RESET}"

export SETV_AUTO_ACTIVATE=true
auto_dir=$(mktemp -d)
echo "test_create" > "$auto_dir/.setv"

# Simulate cd hook
PWD="$auto_dir" _setv_chdir_hook 2>/dev/null || true
assert_ok "auto-activate triggered" "[[ '${VIRTUAL_ENV:-}' == '$TEST_VENV_DIR/test_create' ]]"

PWD="/tmp" _setv_chdir_hook 2>/dev/null || true
assert_ok "auto-deactivate triggered" "[[ -z '${VIRTUAL_ENV:-}' ]]"

rm -rf "$auto_dir"

# -- Empty list --
echo ""
echo "${YELLOW}Edge Cases${RESET}"

deactivate 2>/dev/null || true
echo "y" | setv -d test_create 2>/dev/null || true

capture_run setv -l
assert_contains "empty list message" "$out" "No virtual environments"

capture_run setv --bogus
assert_contains "unknown option error" "$out" "Unknown option"

# --- Summary ---

echo ""
echo "─────────────────────────────"
echo -e "${BOLD}Results ($SHELL_NAME):${RESET} $TESTS_RUN tests, ${GREEN}$TESTS_PASSED passed${RESET}, ${RED}$TESTS_FAILED failed${RESET}"

if [[ ${#FAIL_NAMES[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}Failed tests:${RESET}"
    for f in "${FAIL_NAMES[@]}"; do
        echo -e "  - $f"
    done
fi

echo ""
exit $TESTS_FAILED
