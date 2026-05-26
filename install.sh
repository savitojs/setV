#!/usr/bin/env bash
# setV - Installation script
#
# License: GNU GPL v3, See LICENSE file.
#
# Usage:
#   ./install.sh              Install from local copy
#   ./install.sh --uninstall  Remove setv from shell configs
#
# This script is idempotent - safe to run multiple times.

set -euo pipefail

# --- Colors ---
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'
    GREEN=$'\033[0;32m'
    RED=$'\033[0;31m'
    BLUE=$'\033[0;34m'
    DIM=$'\033[2m'
    RESET=$'\033[0m'
else
    BOLD="" GREEN="" RED="" BLUE="" DIM="" RESET=""
fi

msg()  { echo -e "${GREEN}>>>${RESET} $*"; }
err()  { echo -e "${RED}error:${RESET} $*" >&2; }
warn() { echo -e "${RED}warning:${RESET} $*" >&2; }

SETV_SOURCE="${HOME}/.setv.sh"
SETV_ENV_DIR="${HOME}/.virtualenvs"
SETV_MARKER="# setv - Python virtual environment manager"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Uninstall ---

do_uninstall() {
    msg "Uninstalling setv..."

    # Remove source file
    if [[ -f "$SETV_SOURCE" ]]; then
        rm -f "$SETV_SOURCE"
        msg "Removed ${BLUE}$SETV_SOURCE${RESET}"
    fi

    # Remove from shell configs
    local rc_files=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc")
    for rc in "${rc_files[@]}"; do
        if [[ -f "$rc" ]] && grep -q "$SETV_MARKER" "$rc"; then
            # Remove the setv block (marker line + source line)
            # Use grep -v for portability (sed -i differs between GNU and BSD)
            local tmp_rc
            tmp_rc=$(mktemp)
            grep -v -F "$SETV_MARKER" "$rc" | grep -v "^source.*\.setv\.sh" > "$tmp_rc"
            mv "$tmp_rc" "$rc"
            msg "Cleaned ${BLUE}$rc${RESET}"
        fi
    done

    msg "Uninstalled. Virtual environments in ${DIM}$SETV_ENV_DIR${RESET} were not removed."
    echo "  To remove them: rm -rf $SETV_ENV_DIR"
}

# --- Install ---

do_install() {
    local source_file="$SCRIPT_DIR/setv.sh"

    # Verify source exists
    if [[ ! -f "$source_file" ]]; then
        err "setv.sh not found in $SCRIPT_DIR"
        err "Run this script from the setV project directory."
        exit 1
    fi

    echo ""
    echo "  ${BOLD}setV Installer${RESET}"
    echo ""

    # Create virtualenvs directory
    if [[ ! -d "$SETV_ENV_DIR" ]]; then
        mkdir -p "$SETV_ENV_DIR"
        msg "Created ${BLUE}$SETV_ENV_DIR${RESET}"
    else
        msg "Found ${BLUE}$SETV_ENV_DIR${RESET}"
    fi

    # Migration: detect old ~/virtualenvs
    if [[ -d "$HOME/virtualenvs" && "$SETV_ENV_DIR" == "$HOME/.virtualenvs" ]]; then
        warn "Found old ${BLUE}~/virtualenvs${RESET} directory"
        echo "  Your existing environments can be migrated:"
        echo "  ${DIM}mv ~/virtualenvs/* ~/.virtualenvs/ && rmdir ~/virtualenvs${RESET}"
        echo ""
    fi

    # Copy setv.sh to home
    cp "$source_file" "$SETV_SOURCE"
    chmod 644 "$SETV_SOURCE"
    msg "Installed ${BLUE}$SETV_SOURCE${RESET}"

    # Configure shell RC files (idempotent)
    local configured=false

    # Bash
    for rc in "$HOME/.bashrc" "$HOME/.bash_profile"; do
        if [[ -f "$rc" ]]; then
            if grep -q "$SETV_MARKER" "$rc"; then
                msg "Already configured in ${BLUE}$rc${RESET}"
            else
                {
                    echo ""
                    echo "$SETV_MARKER"
                    echo "source $SETV_SOURCE"
                } >> "$rc"
                msg "Added to ${BLUE}$rc${RESET}"
            fi
            configured=true
            break  # Only add to one bash config
        fi
    done

    # Zsh
    if [[ -f "$HOME/.zshrc" ]]; then
        if grep -q "$SETV_MARKER" "$HOME/.zshrc"; then
            msg "Already configured in ${BLUE}$HOME/.zshrc${RESET}"
        else
            {
                echo ""
                echo "$SETV_MARKER"
                echo "source $SETV_SOURCE"
            } >> "$HOME/.zshrc"
            msg "Added to ${BLUE}$HOME/.zshrc${RESET}"
        fi
        configured=true
    fi

    if [[ "$configured" == false ]]; then
        warn "No shell config found (.bashrc, .bash_profile, .zshrc)"
        echo "  Add this to your shell config manually:"
        echo "  ${DIM}source $SETV_SOURCE${RESET}"
    fi

    # Check for uv
    echo ""
    if command -v uv &>/dev/null; then
        local uv_ver
        uv_ver=$(uv --version 2>/dev/null || echo "unknown")
        msg "Found ${BOLD}uv${RESET} ($uv_ver) - will be used as default backend"
    else
        msg "uv not found - using stdlib venv as backend"
        echo "  ${DIM}Install uv for faster environment creation: curl -LsSf https://astral.sh/uv/install.sh | sh${RESET}"
    fi

    # Done
    echo ""
    msg "${BOLD}Installation complete!${RESET}"
    echo ""
    echo "  Reload your shell:"
    if [[ -f "$HOME/.zshrc" ]]; then
        echo "    ${DIM}source ~/.zshrc${RESET}"
    elif [[ -f "$HOME/.bashrc" ]]; then
        echo "    ${DIM}source ~/.bashrc${RESET}"
    fi
    echo ""
    echo "  Quick start:"
    echo "    ${DIM}setv -n myproject       # create environment${RESET}"
    echo "    ${DIM}setv myproject           # activate${RESET}"
    echo "    ${DIM}setv -l                  # list all${RESET}"
    echo "    ${DIM}setv --help              # full help${RESET}"
    echo ""
}

# --- Main ---

case "${1:-}" in
    --uninstall|-u)
        do_uninstall
        ;;
    --help|-h)
        echo "Usage: $0 [--uninstall]"
        echo "  Install or uninstall setv 3.0"
        ;;
    *)
        do_install
        ;;
esac
