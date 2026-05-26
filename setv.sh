#!/usr/bin/env bash
# shellcheck disable=SC2119,SC2120,SC2329
# setV 3.0 - Modern Python Virtual Environment Manager
#
# Original author: Sachin (psachin) <iclcoolster@gmail.com>
# Maintainer: Savitoj Singh (savsingh@redhat.com)
#
# License: GNU GPL v3, See LICENSE file
#
# Manages centralized Python virtual environments in ~/.virtualenvs/
# Auto-detects and prefers 'uv' as backend, falls back to stdlib venv.
#
# Configuration (set before sourcing this file):
#   SETV_VIRTUAL_DIR_PATH  - Environment directory (default: ~/.virtualenvs)
#   SETV_BACKEND           - Backend: auto|uv|venv (default: auto)
#   SETV_DEFAULT_PYTHON    - Default Python binary (default: python3)

SETV_VERSION="3.2.0" # x-release-please-version
SETV_REPO="savitojs/setV"

# --- Configuration with defaults ---
: "${SETV_VIRTUAL_DIR_PATH:=$HOME/.virtualenvs}"
: "${SETV_BACKEND:=auto}"
: "${SETV_DEFAULT_PYTHON:=python3}"
: "${SETV_AUTO_ACTIVATE:=true}"

# --- Internal ---
_SETV_META_DIR="${SETV_VIRTUAL_DIR_PATH}/.setv"
_SETV_AUTO_ACTIVATED=""  # tracks if current env was auto-activated

# --- Colors (disabled if not a terminal) ---
if [[ -t 1 ]]; then
    _SETV_BOLD=$'\033[1m'
    _SETV_GREEN=$'\033[0;32m'
    _SETV_RED=$'\033[0;31m'
    _SETV_YELLOW=$'\033[0;33m'
    _SETV_BLUE=$'\033[0;34m'
    _SETV_CYAN=$'\033[0;36m'
    _SETV_DIM=$'\033[2m'
    _SETV_RESET=$'\033[0m'
else
    _SETV_BOLD="" _SETV_GREEN="" _SETV_RED="" _SETV_YELLOW=""
    _SETV_BLUE="" _SETV_CYAN="" _SETV_DIM="" _SETV_RESET=""
fi

# --- Utility functions ---

_setv_msg() {
    echo -e "${_SETV_GREEN}>>>${_SETV_RESET} $*"
}

_setv_err() {
    echo -e "${_SETV_RED}error:${_SETV_RESET} $*" >&2
}

_setv_warn() {
    echo -e "${_SETV_YELLOW}warning:${_SETV_RESET} $*" >&2
}

_setv_ensure_dirs() {
    [[ -d "$SETV_VIRTUAL_DIR_PATH" ]] || mkdir -p "$SETV_VIRTUAL_DIR_PATH"
    [[ -d "$_SETV_META_DIR" ]] || mkdir -p "$_SETV_META_DIR"
}

_setv_has_uv() {
    command -v uv &>/dev/null
}

_setv_backend() {
    case "$SETV_BACKEND" in
        uv)   echo "uv" ;;
        venv) echo "venv" ;;
        auto) _setv_has_uv && echo "uv" || echo "venv" ;;
        *)    _setv_err "Unknown backend: $SETV_BACKEND"; echo "venv" ;;
    esac
}

_setv_envs() {
    [[ -d "$SETV_VIRTUAL_DIR_PATH" ]] || return
    # Prevent zsh 'no matches found' error on empty directory
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        setopt local_options nullglob
    elif [[ -n "${BASH_VERSION:-}" ]]; then
        local _had_nullglob=false
        shopt -q nullglob && _had_nullglob=true
        shopt -s nullglob
    fi
    local d
    for d in "$SETV_VIRTUAL_DIR_PATH"/*/; do
        d="${d%/}"
        d="${d##*/}"
        [[ "$d" == ".setv" ]] && continue
        echo "$d"
    done
    if [[ -n "${BASH_VERSION:-}" && "$_had_nullglob" == false ]]; then
        shopt -u nullglob
    fi
    return 0
}

_setv_env_exists() {
    [[ -n "$1" && -d "$SETV_VIRTUAL_DIR_PATH/$1" && "$1" != ".setv" ]]
}

_setv_python_version() {
    local py_bin="$SETV_VIRTUAL_DIR_PATH/$1/bin/python"
    if [[ -x "$py_bin" ]]; then
        "$py_bin" --version 2>&1 | head -1
    else
        echo "unknown"
    fi
}

# --- Braille dot spinner ---

_setv_spinner_frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧")
_SETV_SPINNER_PID=""

_setv_spinner_start() {
    [[ -t 2 ]] || return 0  # no spinner if not a terminal
    local msg="$1"
    local frames=("${_setv_spinner_frames[@]}")
    (
        local i=0
        while true; do
            printf "\r  ${_SETV_CYAN}%s${_SETV_RESET} %s" "${frames[$i]}" "$msg" >&2
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.08
        done
    ) &
    _SETV_SPINNER_PID=$!
    disown "$_SETV_SPINNER_PID" 2>/dev/null
}

_setv_spinner_stop() {
    if [[ -n "$_SETV_SPINNER_PID" ]]; then
        kill "$_SETV_SPINNER_PID" 2>/dev/null
        wait "$_SETV_SPINNER_PID" 2>/dev/null
        printf "\r\033[K" >&2
        _SETV_SPINNER_PID=""
    fi
}

_setv_env_backend() {
    local cfg="$SETV_VIRTUAL_DIR_PATH/$1/pyvenv.cfg"
    if [[ -f "$cfg" ]] && grep -qi "uv" "$cfg" 2>/dev/null; then
        echo "uv"
    else
        echo "venv"
    fi
}

# --- Core operations ---

_setv_help() {
    local be
    be=$(_setv_backend)
    echo ""
    echo -e "  ${_SETV_BOLD}setv ${SETV_VERSION}${_SETV_RESET} ${_SETV_DIM}─${_SETV_RESET} Python Virtual Environment Manager"
    echo -e "  ${_SETV_DIM}Backend: ${_SETV_CYAN}${be}${_SETV_RESET}"
    echo ""
    echo -e "  ${_SETV_GREEN}${_SETV_BOLD}BASICS${_SETV_RESET}"
    echo -e "    ${_SETV_BOLD}setv${_SETV_RESET} ${_SETV_CYAN}<name>${_SETV_RESET}                  Activate environment"
    echo -e "    ${_SETV_BOLD}setv -n${_SETV_RESET} ${_SETV_CYAN}<name>${_SETV_RESET}               Create + activate"
    echo -e "    ${_SETV_BOLD}setv -n${_SETV_RESET} ${_SETV_CYAN}<name>${_SETV_RESET} ${_SETV_BOLD}-p${_SETV_RESET} ${_SETV_CYAN}<ver>${_SETV_RESET}      Create with Python version"
    echo -e "    ${_SETV_BOLD}setv -d${_SETV_RESET} ${_SETV_CYAN}<name>${_SETV_RESET}               Delete environment"
    echo -e "    ${_SETV_BOLD}setv -l${_SETV_RESET}                        List all envs"
    echo -e "    ${_SETV_BOLD}setv -i${_SETV_RESET} ${_SETV_DIM}[name]${_SETV_RESET}                Show env details"
    echo ""
    echo -e "  ${_SETV_BLUE}${_SETV_BOLD}PROJECTS${_SETV_RESET}"
    echo -e "    ${_SETV_BOLD}setv --link${_SETV_RESET} ${_SETV_DIM}[name]${_SETV_RESET}            Link \$PWD to environment"
    echo -e "    ${_SETV_BOLD}setv --unlink${_SETV_RESET} ${_SETV_DIM}[name]${_SETV_RESET}          Remove project link"
    echo -e "    ${_SETV_BOLD}setv --cd${_SETV_RESET} ${_SETV_CYAN}<name>${_SETV_RESET}             cd to linked project"
    echo -e "    ${_SETV_BOLD}setv --init${_SETV_RESET} ${_SETV_DIM}[name]${_SETV_RESET}            Auto-activate on cd ${_SETV_DIM}(.setv file)${_SETV_RESET}"
    echo ""
    echo -e "  ${_SETV_CYAN}${_SETV_BOLD}PACKAGES${_SETV_RESET}"
    echo -e "    ${_SETV_BOLD}setv freeze${_SETV_RESET} ${_SETV_DIM}[name]${_SETV_RESET}            Export installed packages"
    echo -e "    ${_SETV_DIM}    (auto-saved on every deactivate)${_SETV_RESET}"
    echo ""
    echo -e "  ${_SETV_RED}${_SETV_BOLD}BACKUP & REPAIR${_SETV_RESET}"
    echo -e "    ${_SETV_BOLD}setv backup${_SETV_RESET} ${_SETV_DIM}[dir]${_SETV_RESET}             Export all envs ${_SETV_DIM}(default: ./setv-backup)${_SETV_RESET}"
    echo -e "    ${_SETV_BOLD}setv restore${_SETV_RESET} ${_SETV_CYAN}<dir>${_SETV_RESET}            Recreate envs from backup"
    echo -e "    ${_SETV_BOLD}setv doctor${_SETV_RESET}                    Check all envs for problems"
    echo -e "    ${_SETV_BOLD}setv rebuild${_SETV_RESET} ${_SETV_CYAN}<name>${_SETV_RESET}|${_SETV_BOLD}--all${_SETV_RESET}   Fix broken envs"
    echo ""
    echo -e "  ${_SETV_YELLOW}${_SETV_BOLD}ADVANCED${_SETV_RESET}"
    echo -e "    ${_SETV_BOLD}setv --tmp${_SETV_RESET} ${_SETV_DIM}[-p ver]${_SETV_RESET}           Throwaway env ${_SETV_DIM}(deleted on deactivate)${_SETV_RESET}"
    echo -e "    ${_SETV_BOLD}setv --run${_SETV_RESET} ${_SETV_CYAN}<name>${_SETV_RESET} ${_SETV_BOLD}--${_SETV_RESET} ${_SETV_DIM}cmd${_SETV_RESET}    Run command without activating"
    echo -e "    ${_SETV_BOLD}setv update${_SETV_RESET}                    Update to latest release"
    echo ""
    local _display_path="${SETV_VIRTUAL_DIR_PATH/#$HOME/~}"
    echo -e "  ${_SETV_DIM}${_SETV_BOLD}CONFIG${_SETV_RESET}                              ${_SETV_DIM}current${_SETV_RESET}"
    echo -e "    ${_SETV_BOLD}SETV_VIRTUAL_DIR_PATH${_SETV_RESET}           ${_SETV_DIM}${_display_path}${_SETV_RESET}"
    echo -e "    ${_SETV_BOLD}SETV_BACKEND${_SETV_RESET}                    ${_SETV_DIM}${SETV_BACKEND} (${be})${_SETV_RESET}"
    echo -e "    ${_SETV_BOLD}SETV_DEFAULT_PYTHON${_SETV_RESET}             ${_SETV_DIM}${SETV_DEFAULT_PYTHON}${_SETV_RESET}"
    echo -e "    ${_SETV_BOLD}SETV_AUTO_ACTIVATE${_SETV_RESET}              ${_SETV_DIM}${SETV_AUTO_ACTIVATE}${_SETV_RESET}"
    echo ""
}

_setv_create() {
    local name="" python_spec=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--python)
                if [[ -z "$2" || "$2" == -* ]]; then
                    _setv_err "Option $1 requires a value"
                    return 1
                fi
                python_spec="$2"; shift 2
                ;;
            -*)
                if [[ -z "$name" ]]; then
                    _setv_err "Invalid environment name: '$1' (names cannot start with a dash)"
                else
                    _setv_err "Unknown option: $1"
                fi
                return 1
                ;;
            *)
                if [[ -n "$name" ]]; then
                    _setv_err "Multiple names given: '$name' and '$1'"
                    return 1
                fi
                name="$1"; shift
                ;;
        esac
    done

    if [[ -z "$name" ]]; then
        _setv_err "Missing environment name"
        echo "Usage: setv -n <name> [-p <python-version>]"
        return 1
    fi

    # Validate name: alphanumeric, underscores, hyphens, dots (not leading)
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        _setv_err "Invalid environment name: '$name' (use letters, digits, hyphens, underscores)"
        return 1
    fi

    if _setv_env_exists "$name"; then
        _setv_err "Environment '$name' already exists"
        return 1
    fi

    _setv_ensure_dirs
    local env_path="$SETV_VIRTUAL_DIR_PATH/$name"
    local backend
    backend=$(_setv_backend)

    local spinner_label="Creating ${name}${python_spec:+ (Python $python_spec)} via ${backend}"
    local output rc

    if [[ "$backend" == "uv" ]]; then
        local uv_args=(venv "$env_path")
        if [[ -n "$python_spec" ]]; then
            uv_args+=(--python "$python_spec")
        fi
        _setv_spinner_start "$spinner_label"
        output=$(uv "${uv_args[@]}" 2>&1)
        rc=$?
        _setv_spinner_stop
        if [[ $rc -ne 0 ]]; then
            echo "$output" >&2
            _setv_err "Failed to create environment"
            return 1
        fi
    else
        local py_bin="$SETV_DEFAULT_PYTHON"
        if [[ -n "$python_spec" ]]; then
            if [[ -x "$python_spec" ]]; then
                py_bin="$python_spec"
            elif [[ "$python_spec" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
                py_bin="python${python_spec}"
            else
                py_bin="$python_spec"
            fi
        fi
        _setv_spinner_start "$spinner_label"
        output=$("$py_bin" -m venv "$env_path" 2>&1)
        rc=$?
        _setv_spinner_stop
        if [[ $rc -ne 0 ]]; then
            echo "$output" >&2
            _setv_err "Failed to create environment. Is '$py_bin' installed?"
            return 1
        fi
    fi

    _setv_activate "$name"
}

_setv_delete() {
    local name="$1"
    if [[ -z "$name" ]]; then
        _setv_err "Missing environment name"
        echo "Usage: setv -d <name>"
        return 1
    fi

    if [[ "$name" == -* ]]; then
        _setv_err "Invalid environment name: '$name' (names cannot start with a dash)"
        return 1
    fi

    if ! _setv_env_exists "$name"; then
        _setv_err "Environment '$name' does not exist"
        return 1
    fi

    echo -n "Delete environment '$name'? [y/N] "
    read -r confirm
    case "$confirm" in
        [yY]|[yY][eE][sS])
            # Deactivate if currently active
            if [[ "${VIRTUAL_ENV:-}" == "$SETV_VIRTUAL_DIR_PATH/$name" ]]; then
                _setv_warn "Deactivating '$name' before deletion"
                deactivate 2>/dev/null
            fi
            _setv_spinner_start "Removing $name"
            rm -rf "${SETV_VIRTUAL_DIR_PATH:?}/$name"
            rm -f "$_SETV_META_DIR/${name}.link"
            _setv_spinner_stop
            _setv_msg "Deleted '${_SETV_CYAN}$name${_SETV_RESET}'"
            ;;
        *)
            _setv_msg "Cancelled"
            ;;
    esac
}

_setv_activate() {
    local name="$1"
    if [[ -z "$name" ]]; then
        _setv_err "Missing environment name"
        return 1
    fi

    if [[ "$name" == -* ]]; then
        _setv_err "Invalid environment name: '$name' (names cannot start with a dash)"
        return 1
    fi

    if ! _setv_env_exists "$name"; then
        _setv_err "Environment '$name' does not exist"
        local avail
        avail=$(_setv_envs)
        if [[ -n "$avail" ]]; then
            echo "Available:"
            echo "$avail" | sed 's/^/  /'
        fi
        return 1
    fi

    local activate_script="$SETV_VIRTUAL_DIR_PATH/$name/bin/activate"
    if [[ ! -f "$activate_script" ]]; then
        _setv_err "Activation script not found for '$name'"
        return 1
    fi

    # Auto-freeze + deactivate previous env
    if [[ -n "${VIRTUAL_ENV:-}" ]]; then
        _setv_auto_freeze
        deactivate 2>/dev/null
    fi

    # shellcheck disable=SC1090
    source "$activate_script"

    # Wrap deactivate so explicit 'deactivate' also auto-freezes
    eval "$(typeset -f deactivate | sed '1s/deactivate/_setv_orig_deactivate_/')"
    deactivate() {
        _setv_auto_freeze
        _setv_orig_deactivate_ "$@"
    }

    _setv_msg "Activated ${_SETV_CYAN}$name${_SETV_RESET} ($(_setv_python_version "$name"))"
}

_setv_list() {
    _setv_ensure_dirs
    local envs=()
    while IFS= read -r e; do
        [[ -n "$e" ]] && envs+=("$e")
    done < <(_setv_envs)

    if [[ ${#envs[@]} -eq 0 ]]; then
        _setv_msg "No virtual environments in ${_SETV_DIM}$SETV_VIRTUAL_DIR_PATH${_SETV_RESET}"
        echo "Create one with: setv -n <name>"
        return 0
    fi

    printf "${_SETV_BOLD}%-20s %-16s %-8s %s${_SETV_RESET}\n" \
        "ENVIRONMENT" "PYTHON" "BACKEND" "PROJECT"
    printf "%-20s %-16s %-8s %s\n" \
        "───────────" "──────" "───────" "───────"

    local py_ver env_be linked link_file marker name

    for name in "${envs[@]}"; do
        py_ver=$(_setv_python_version "$name")
        env_be=$(_setv_env_backend "$name")
        linked=""
        link_file="$_SETV_META_DIR/${name}.link"
        if [[ -f "$link_file" ]]; then
            linked=$(cat "$link_file")
        fi

        # Mark active environment
        marker="  "
        if [[ "${VIRTUAL_ENV:-}" == "$SETV_VIRTUAL_DIR_PATH/$name" ]]; then
            marker="${_SETV_GREEN}* ${_SETV_RESET}"
        fi

        printf "${marker}%-18s %-16s %-8s %s\n" "$name" "$py_ver" "$env_be" "$linked"
    done
}

_setv_info() {
    local name="$1"
    if [[ -z "$name" ]]; then
        # If in an active env, use that
        if [[ -n "${VIRTUAL_ENV:-}" ]]; then
            name=$(basename "${VIRTUAL_ENV:-}")
        else
            _setv_err "Missing environment name"
            return 1
        fi
    fi

    if ! _setv_env_exists "$name"; then
        _setv_err "Environment '$name' does not exist"
        return 1
    fi

    local env_path="$SETV_VIRTUAL_DIR_PATH/$name"
    local py_ver
    py_ver=$(_setv_python_version "$name")
    local env_be
    env_be=$(_setv_env_backend "$name")
    local active="no"
    [[ "${VIRTUAL_ENV:-}" == "$env_path" ]] && active="${_SETV_GREEN}yes${_SETV_RESET}"

    echo ""
    echo -e "  ${_SETV_BOLD}Name:${_SETV_RESET}      $name"
    echo -e "  ${_SETV_BOLD}Path:${_SETV_RESET}      $env_path"
    echo -e "  ${_SETV_BOLD}Python:${_SETV_RESET}    $py_ver"
    echo -e "  ${_SETV_BOLD}Backend:${_SETV_RESET}   $env_be"
    echo -e "  ${_SETV_BOLD}Active:${_SETV_RESET}    $active"

    local link_file="$_SETV_META_DIR/${name}.link"
    if [[ -f "$link_file" ]]; then
        echo -e "  ${_SETV_BOLD}Project:${_SETV_RESET}   $(cat "$link_file")"
    fi

    # Package count
    local pkg_count=0
    if _setv_has_uv; then
        pkg_count=$(uv pip list --python "$env_path/bin/python" 2>/dev/null | tail -n +3 | wc -l)
    elif [[ -x "$env_path/bin/pip" ]]; then
        pkg_count=$("$env_path/bin/pip" list 2>/dev/null | tail -n +3 | wc -l)
    fi
    echo -e "  ${_SETV_BOLD}Packages:${_SETV_RESET}  $pkg_count installed"

    # Disk size
    local size
    size=$(du -sh "$env_path" 2>/dev/null | cut -f1)
    echo -e "  ${_SETV_BOLD}Size:${_SETV_RESET}      $size"
    echo ""
}

_setv_link() {
    local name="$1"
    # Default to active environment
    if [[ -z "$name" && -n "${VIRTUAL_ENV:-}" ]]; then
        name=$(basename "${VIRTUAL_ENV:-}")
    fi

    if [[ -z "$name" ]]; then
        _setv_err "No environment specified and none active"
        echo "Usage: setv --link [<name>]"
        return 1
    fi

    if ! _setv_env_exists "$name"; then
        _setv_err "Environment '$name' does not exist"
        return 1
    fi

    _setv_ensure_dirs
    echo "$PWD" > "$_SETV_META_DIR/${name}.link"
    _setv_msg "Linked ${_SETV_CYAN}$name${_SETV_RESET} -> ${_SETV_BLUE}$PWD${_SETV_RESET}"
}

_setv_unlink() {
    local name="$1"
    if [[ -z "$name" && -n "${VIRTUAL_ENV:-}" ]]; then
        name=$(basename "${VIRTUAL_ENV:-}")
    fi

    if [[ -z "$name" ]]; then
        _setv_err "No environment specified and none active"
        return 1
    fi

    local link_file="$_SETV_META_DIR/${name}.link"
    if [[ -f "$link_file" ]]; then
        rm -f "$link_file"
        _setv_msg "Unlinked ${_SETV_CYAN}$name${_SETV_RESET}"
    else
        _setv_warn "No link found for '$name'"
    fi
}

_setv_cd() {
    local name="$1"
    if [[ -z "$name" ]]; then
        _setv_err "Missing environment name"
        echo "Usage: setv --cd <name>"
        return 1
    fi

    local link_file="$_SETV_META_DIR/${name}.link"
    if [[ ! -f "$link_file" ]]; then
        _setv_err "No project linked to '$name'"
        echo "Link a project first: setv --link $name"
        return 1
    fi

    local project_dir
    project_dir=$(cat "$link_file")
    if [[ ! -d "$project_dir" ]]; then
        _setv_err "Linked directory no longer exists: $project_dir"
        return 1
    fi

    cd "$project_dir" || return 1
    _setv_msg "Changed to ${_SETV_BLUE}$project_dir${_SETV_RESET}"
}

# --- Auto-freeze: save requirements on deactivate ---

_setv_auto_freeze() {
    # Silently save pip freeze for the currently active env
    [[ -n "${VIRTUAL_ENV:-}" ]] || return 0
    local name
    name=$(basename "${VIRTUAL_ENV:-}")
    _setv_env_exists "$name" || return 0
    _setv_ensure_dirs
    local req_file="$_SETV_META_DIR/${name}.requirements.txt"
    if _setv_has_uv; then
        uv pip freeze --python "$VIRTUAL_ENV/bin/python" > "$req_file" 2>/dev/null
    elif [[ -x "$VIRTUAL_ENV/bin/pip" ]]; then
        "$VIRTUAL_ENV/bin/pip" freeze > "$req_file" 2>/dev/null
    fi
    return 0
}

# --- Freeze: manual export of packages ---

_setv_freeze() {
    local name="$1"

    # Default to active env
    if [[ -z "$name" && -n "${VIRTUAL_ENV:-}" ]]; then
        name=$(basename "${VIRTUAL_ENV:-}")
    fi

    if [[ -z "$name" ]]; then
        _setv_err "No environment specified and none active"
        echo "Usage: setv freeze [name]"
        return 1
    fi

    if ! _setv_env_exists "$name"; then
        _setv_err "Environment '$name' does not exist"
        return 1
    fi

    local env_path="$SETV_VIRTUAL_DIR_PATH/$name"
    if _setv_has_uv; then
        uv pip freeze --python "$env_path/bin/python" 2>/dev/null
    elif [[ -x "$env_path/bin/pip" ]]; then
        "$env_path/bin/pip" freeze 2>/dev/null
    else
        _setv_err "No pip or uv available to freeze '$name'"
        return 1
    fi
}

# --- Backup / Restore ---

_setv_backup() {
    local backup_dir="${1:-./setv-backup}"

    _setv_ensure_dirs
    local envs=()
    while IFS= read -r e; do
        [[ -n "$e" ]] && envs+=("$e")
    done < <(_setv_envs)

    if [[ ${#envs[@]} -eq 0 ]]; then
        _setv_err "No environments to back up"
        return 1
    fi

    mkdir -p "$backup_dir"

    # Auto-freeze active env before backup
    _setv_auto_freeze

    # Build manifest and save requirements
    local manifest="$backup_dir/manifest.json"
    local name py_ver env_be link_file linked req_src

    echo "[" > "$manifest"
    local idx=0 total=${#envs[@]}

    _setv_spinner_start "Backing up $total environments"

    for name in "${envs[@]}"; do
        py_ver=$(_setv_python_version "$name")
        env_be=$(_setv_env_backend "$name")
        linked=""
        link_file="$_SETV_META_DIR/${name}.link"
        [[ -f "$link_file" ]] && linked=$(cat "$link_file")

        # Extract just the version number (e.g. "3.12.12" from "Python 3.12.12")
        local py_num=""
        py_num=$(echo "$py_ver" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)

        # Freeze packages for this env
        req_src="$_SETV_META_DIR/${name}.requirements.txt"
        if [[ ! -f "$req_src" ]]; then
            # Generate on the fly
            local env_path="$SETV_VIRTUAL_DIR_PATH/$name"
            if _setv_has_uv; then
                uv pip freeze --python "$env_path/bin/python" > "$req_src" 2>/dev/null
            elif [[ -x "$env_path/bin/pip" ]]; then
                "$env_path/bin/pip" freeze > "$req_src" 2>/dev/null
            fi
        fi

        # Copy requirements to backup dir
        if [[ -f "$req_src" ]]; then
            cp "$req_src" "$backup_dir/${name}.requirements.txt"
        fi

        idx=$((idx + 1))
        local trailing="}"
        [[ $idx -lt $total ]] && trailing="},"

        cat >> "$manifest" <<ENTRY
  {
    "name": "$name",
    "python": "$py_num",
    "backend": "$env_be",
    "project": "$linked"
  $trailing
ENTRY
    done

    echo "]" >> "$manifest"
    _setv_spinner_stop

    _setv_msg "Backed up ${_SETV_BOLD}${#envs[@]}${_SETV_RESET} environments to ${_SETV_BLUE}$backup_dir${_SETV_RESET}"
    echo "  Manifest: $backup_dir/manifest.json"
    echo "  Restore:  setv restore $backup_dir"
}

_setv_restore() {
    local backup_dir="$1"

    if [[ -z "$backup_dir" ]]; then
        _setv_err "Missing backup directory"
        echo "Usage: setv restore <backup-dir>"
        return 1
    fi

    local manifest="$backup_dir/manifest.json"
    if [[ ! -f "$manifest" ]]; then
        _setv_err "No manifest.json found in '$backup_dir'"
        return 1
    fi

    _setv_ensure_dirs

    # Parse manifest (simple line-based parsing, no jq dependency)
    local name="" py_num="" project=""
    local total=0 restored=0 skipped=0 failed=0

    while IFS= read -r line; do
        if [[ "$line" =~ \"name\":\ *\"([^\"]+)\" ]]; then
            # shellcheck disable=SC2154
            if [[ -n "${ZSH_VERSION:-}" ]]; then name="${match[1]}"; else name="${BASH_REMATCH[1]}"; fi
        elif [[ "$line" =~ \"python\":\ *\"([^\"]+)\" ]]; then
            # shellcheck disable=SC2154
            if [[ -n "${ZSH_VERSION:-}" ]]; then py_num="${match[1]}"; else py_num="${BASH_REMATCH[1]}"; fi
        elif [[ "$line" =~ \"project\":\ *\"([^\"]*)\" ]]; then
            # shellcheck disable=SC2154
            if [[ -n "${ZSH_VERSION:-}" ]]; then project="${match[1]}"; else project="${BASH_REMATCH[1]}"; fi
        elif [[ "$line" == *"}"* && -n "$name" ]]; then
            total=$((total + 1))

            if _setv_env_exists "$name"; then
                _setv_warn "Skipping '$name' — already exists"
                skipped=$((skipped + 1))
                name="" py_num="" project=""
                continue
            fi

            echo -e "  Restoring ${_SETV_CYAN}$name${_SETV_RESET} (Python ${py_num:-default})..."

            # Create env
            local create_args=("$name")
            [[ -n "$py_num" ]] && create_args+=(-p "$py_num")

            if _setv_create "${create_args[@]}" 2>/dev/null; then
                # Deactivate (create auto-activates)
                deactivate 2>/dev/null

                # Install packages from requirements
                local req_file="$backup_dir/${name}.requirements.txt"
                if [[ -f "$req_file" && -s "$req_file" ]]; then
                    _setv_spinner_start "Installing packages for $name"
                    local env_path="$SETV_VIRTUAL_DIR_PATH/$name"
                    if _setv_has_uv; then
                        uv pip install --python "$env_path/bin/python" -r "$req_file" 2>&1
                    elif [[ -x "$env_path/bin/pip" ]]; then
                        "$env_path/bin/pip" install -r "$req_file" 2>&1
                    fi
                    _setv_spinner_stop

                    # Save requirements to meta
                    cp "$req_file" "$_SETV_META_DIR/${name}.requirements.txt"
                fi

                # Restore project link
                if [[ -n "$project" ]]; then
                    echo "$project" > "$_SETV_META_DIR/${name}.link"
                fi

                restored=$((restored + 1))
            else
                _setv_err "Failed to restore '$name'"
                failed=$((failed + 1))
            fi

            name="" py_num="" project=""
        fi
    done < "$manifest"

    echo ""
    _setv_msg "Restore complete: ${_SETV_GREEN}$restored restored${_SETV_RESET}, $skipped skipped, $failed failed (of $total total)"
}

# --- Doctor / Rebuild ---

_setv_doctor() {
    _setv_ensure_dirs
    local envs=()
    while IFS= read -r e; do
        [[ -n "$e" ]] && envs+=("$e")
    done < <(_setv_envs)

    if [[ ${#envs[@]} -eq 0 ]]; then
        _setv_msg "No environments to check"
        return 0
    fi

    local ok=0 broken=0
    local name env_status py_ver req_status

    printf "\n  ${_SETV_BOLD}%-20s %-10s %-18s %s${_SETV_RESET}\n" \
        "ENVIRONMENT" "STATUS" "PYTHON" "REQUIREMENTS"
    printf "  %-20s %-10s %-18s %s\n" \
        "───────────" "──────" "──────" "────────────"

    for name in "${envs[@]}"; do
        local env_path="$SETV_VIRTUAL_DIR_PATH/$name"
        local py_bin="$env_path/bin/python"

        # Check if Python works
        if [[ -x "$py_bin" ]] && "$py_bin" --version &>/dev/null; then
            env_status="${_SETV_GREEN}OK${_SETV_RESET}"
            py_ver=$("$py_bin" --version 2>&1 | head -1)
            ok=$((ok + 1))
        else
            env_status="${_SETV_RED}BROKEN${_SETV_RESET}"
            # Try to read the expected version from pyvenv.cfg
            py_ver="unknown"
            if [[ -f "$env_path/pyvenv.cfg" ]]; then
                local cfg_ver
                cfg_ver=$(grep -E '^version' "$env_path/pyvenv.cfg" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ')
                [[ -n "$cfg_ver" ]] && py_ver="Python $cfg_ver (missing)"
            fi
            broken=$((broken + 1))
        fi

        # Check for saved requirements
        local req_file="$_SETV_META_DIR/${name}.requirements.txt"
        if [[ -f "$req_file" ]]; then
            local pkg_count
            pkg_count=$(wc -l < "$req_file" | tr -d ' ')
            req_status="${_SETV_GREEN}saved${_SETV_RESET} (${pkg_count} pkgs)"
        else
            req_status="${_SETV_YELLOW}none${_SETV_RESET}"
        fi

        printf "  %-20s %-22b %-30b %b\n" "$name" "$env_status" "$py_ver" "$req_status"
    done

    echo ""
    if [[ $broken -gt 0 ]]; then
        _setv_msg "${_SETV_GREEN}$ok OK${_SETV_RESET}, ${_SETV_RED}$broken broken${_SETV_RESET}"
        echo "  Fix with: setv rebuild --all"
    else
        _setv_msg "All ${_SETV_GREEN}$ok${_SETV_RESET} environments healthy"
    fi
    echo ""
}

_setv_rebuild() {
    local target="$1"
    local rebuild_all=false

    if [[ "$target" == "--all" ]]; then
        rebuild_all=true
    elif [[ -z "$target" ]]; then
        _setv_err "Missing environment name or --all"
        echo "Usage: setv rebuild <name> | setv rebuild --all"
        return 1
    fi

    _setv_ensure_dirs

    local envs_to_rebuild=()

    if [[ "$rebuild_all" == true ]]; then
        # Find all broken envs
        local name
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            local py_bin="$SETV_VIRTUAL_DIR_PATH/$name/bin/python"
            if [[ ! -x "$py_bin" ]] || ! "$py_bin" --version &>/dev/null; then
                envs_to_rebuild+=("$name")
            fi
        done < <(_setv_envs)

        if [[ ${#envs_to_rebuild[@]} -eq 0 ]]; then
            _setv_msg "No broken environments found"
            return 0
        fi
        _setv_msg "Found ${_SETV_RED}${#envs_to_rebuild[@]}${_SETV_RESET} broken environments"
    else
        if ! _setv_env_exists "$target"; then
            _setv_err "Environment '$target' does not exist"
            return 1
        fi
        envs_to_rebuild+=("$target")
    fi

    local rebuilt=0 failed=0

    for name in "${envs_to_rebuild[@]}"; do
        local env_path="$SETV_VIRTUAL_DIR_PATH/$name"
        local req_file="$_SETV_META_DIR/${name}.requirements.txt"
        local link_file="$_SETV_META_DIR/${name}.link"

        # Read Python version from pyvenv.cfg before deleting
        local py_spec=""
        if [[ -f "$env_path/pyvenv.cfg" ]]; then
            local cfg_ver
            cfg_ver=$(grep -E '^version' "$env_path/pyvenv.cfg" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ')
            # Use major.minor only for version spec
            [[ -n "$cfg_ver" ]] && py_spec=$(echo "$cfg_ver" | grep -oE '^[0-9]+\.[0-9]+')
        fi

        echo -e "  Rebuilding ${_SETV_CYAN}$name${_SETV_RESET}${py_spec:+ (Python $py_spec)}..."

        # Save requirements to temp BEFORE rebuild (auto-freeze on empty env would overwrite)
        local tmp_req=""
        if [[ -f "$req_file" && -s "$req_file" ]]; then
            tmp_req=$(mktemp)
            cp "$req_file" "$tmp_req"
        fi

        # Deactivate if active
        if [[ "${VIRTUAL_ENV:-}" == "$env_path" ]]; then
            deactivate 2>/dev/null
        fi

        # Remove broken env
        rm -rf "${SETV_VIRTUAL_DIR_PATH:?}/$name"

        # Recreate
        local create_args=("$name")
        [[ -n "$py_spec" ]] && create_args+=(-p "$py_spec")

        if _setv_create "${create_args[@]}" 2>/dev/null; then
            deactivate 2>/dev/null

            # Reinstall packages from saved temp copy
            if [[ -n "$tmp_req" && -f "$tmp_req" && -s "$tmp_req" ]]; then
                _setv_spinner_start "Reinstalling packages for $name"
                if _setv_has_uv; then
                    uv pip install --python "$env_path/bin/python" -r "$tmp_req" &>/dev/null
                elif [[ -x "$env_path/bin/pip" ]]; then
                    "$env_path/bin/pip" install -r "$tmp_req" &>/dev/null
                fi
                _setv_spinner_stop
                local pkg_count
                pkg_count=$(wc -l < "$tmp_req" | tr -d ' ')
                echo -e "    Restored $pkg_count packages"
                # Update the saved requirements
                cp "$tmp_req" "$req_file"
                rm -f "$tmp_req"
            else
                _setv_warn "No saved requirements for '$name' — env recreated empty"
            fi

            rebuilt=$((rebuilt + 1))
        else
            _setv_err "Failed to rebuild '$name'"
            failed=$((failed + 1))
        fi
    done

    echo ""
    _setv_msg "Rebuild complete: ${_SETV_GREEN}$rebuilt rebuilt${_SETV_RESET}, $failed failed"
}

# --- Temporary environments ---

_setv_tmp() {
    local python_spec=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--python) python_spec="$2"; shift 2 ;;
            *) _setv_err "Unknown option: $1"; return 1 ;;
        esac
    done

    # Generate unique name
    local tmp_name
    tmp_name="tmp_$$_$(date +%s)"

    # Create the environment
    local create_args=("$tmp_name")
    [[ -n "$python_spec" ]] && create_args+=(-p "$python_spec")
    _setv_create "${create_args[@]}" || return 1

    # Save the real deactivate, wrap it to clean up tmp env on exit
    eval "$(typeset -f deactivate | sed '1s/deactivate/_setv_saved_deactivate/')"
    _SETV_TMP_ENV="$tmp_name"

    deactivate() {
        local _tmp="$_SETV_TMP_ENV"
        unset _SETV_TMP_ENV
        _setv_saved_deactivate "$@"
        if [[ -n "$_tmp" ]]; then
            rm -rf "${SETV_VIRTUAL_DIR_PATH:?}/$_tmp"
            _setv_msg "Temporary environment '${_SETV_CYAN}$_tmp${_SETV_RESET}' cleaned up"
        fi
        unset -f _setv_saved_deactivate deactivate 2>/dev/null
    }
}

# --- Run in environment without activating ---

_setv_run() {
    local name=""
    local cmd_args=()
    local found_separator=false

    # Parse: setv --run <name> -- <command...>
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then
            found_separator=true
            shift
            cmd_args=("$@")
            break
        fi
        if [[ -z "$name" ]]; then
            name="$1"
        fi
        shift
    done

    if [[ -z "$name" ]]; then
        _setv_err "Missing environment name"
        echo "Usage: setv --run <name> -- <command> [args...]"
        return 1
    fi

    if [[ "$found_separator" == false || ${#cmd_args[@]} -eq 0 ]]; then
        _setv_err "Missing command after --"
        echo "Usage: setv --run <name> -- <command> [args...]"
        return 1
    fi

    if ! _setv_env_exists "$name"; then
        _setv_err "Environment '$name' does not exist"
        return 1
    fi

    local env_bin="$SETV_VIRTUAL_DIR_PATH/$name/bin"
    if [[ ! -d "$env_bin" ]]; then
        _setv_err "Environment '$name' has no bin directory"
        return 1
    fi

    # Run with the env's bin prepended to PATH
    PATH="$env_bin:$PATH" VIRTUAL_ENV="$SETV_VIRTUAL_DIR_PATH/$name" "${cmd_args[@]}"
}

# --- Auto-activate on cd (.setv file) ---

_setv_init() {
    local name="$1"

    # Default to active environment
    if [[ -z "$name" && -n "${VIRTUAL_ENV:-}" ]]; then
        name=$(basename "${VIRTUAL_ENV:-}")
    fi

    if [[ -z "$name" ]]; then
        _setv_err "No environment specified and none active"
        echo "Usage: setv --init <name>"
        return 1
    fi

    if ! _setv_env_exists "$name"; then
        _setv_err "Environment '$name' does not exist"
        return 1
    fi

    echo "$name" > "$PWD/.setv"
    _setv_msg "Created ${_SETV_BLUE}.setv${_SETV_RESET} -> auto-activates ${_SETV_CYAN}$name${_SETV_RESET} on cd"
}

_setv_chdir_hook() {
    [[ "$SETV_AUTO_ACTIVATE" == "true" ]] || return

    if [[ -f "$PWD/.setv" ]]; then
        local env_name
        env_name=$(cat "$PWD/.setv" 2>/dev/null)
        env_name="${env_name%%[[:space:]]}"  # trim whitespace

        if [[ -n "$env_name" && "$env_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] && _setv_env_exists "$env_name"; then
            # Don't re-activate if already in this env
            if [[ "${VIRTUAL_ENV:-}" != "$SETV_VIRTUAL_DIR_PATH/$env_name" ]]; then
                _setv_activate "$env_name"
                _SETV_AUTO_ACTIVATED="$env_name"
            fi
        fi
    elif [[ -n "$_SETV_AUTO_ACTIVATED" ]]; then
        # Left an auto-activated directory, deactivate
        if [[ "${VIRTUAL_ENV:-}" == "$SETV_VIRTUAL_DIR_PATH/$_SETV_AUTO_ACTIVATED" ]]; then
            deactivate 2>/dev/null
            _setv_msg "Auto-deactivated ${_SETV_CYAN}$_SETV_AUTO_ACTIVATED${_SETV_RESET}"
        fi
        _SETV_AUTO_ACTIVATED=""
    fi
}

# Install cd hook
if [[ -n "${ZSH_VERSION:-}" ]]; then
    autoload -Uz add-zsh-hook 2>/dev/null
    if typeset -f add-zsh-hook &>/dev/null; then
        add-zsh-hook chpwd _setv_chdir_hook
    fi
elif [[ -n "${BASH_VERSION:-}" ]]; then
    # Wrap cd for bash
    if ! typeset -f _setv_original_cd &>/dev/null; then
        _setv_original_cd() { builtin cd "$@" || return; }
        cd() {
            _setv_original_cd "$@" && _setv_chdir_hook
        }
    fi
fi

# --- Self-update ---

_setv_update() {
    if ! command -v curl &>/dev/null; then
        _setv_err "curl is required for updates"
        return 1
    fi

    _setv_spinner_start "Checking for updates"
    local api_response
    api_response=$(curl -sf --connect-timeout 5 --max-time 10 \
        "https://api.github.com/repos/${SETV_REPO}/releases/latest" 2>/dev/null)
    _setv_spinner_stop

    if [[ -z "$api_response" ]]; then
        _setv_err "Could not reach GitHub. Check your connection."
        return 1
    fi

    local latest
    latest=$(echo "$api_response" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/')

    if [[ -z "$latest" ]]; then
        _setv_err "Could not determine latest version"
        return 1
    fi

    if [[ "$latest" == "$SETV_VERSION" ]]; then
        _setv_msg "Already on latest (${_SETV_GREEN}${SETV_VERSION}${_SETV_RESET})"
        return 0
    fi

    echo ""
    echo -e "  ${_SETV_YELLOW}${SETV_VERSION}${_SETV_RESET} -> ${_SETV_GREEN}${latest}${_SETV_RESET}"
    echo ""

    local target="${HOME}/.setv.sh"
    if [[ ! -f "$target" ]]; then
        _setv_warn "Installed copy not found at $target"
        echo "  Download manually: https://github.com/${SETV_REPO}/releases/latest"
        return 1
    fi

    echo -n "Update now? [Y/n] "
    read -r confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        _setv_msg "Cancelled"
        return 0
    fi

    local download_url="https://github.com/${SETV_REPO}/releases/latest/download/setv.sh"
    local tmp_script
    tmp_script=$(mktemp)

    _setv_spinner_start "Downloading v${latest}"
    if ! curl -o "$tmp_script" -sfL --connect-timeout 5 --max-time 30 "$download_url"; then
        _setv_spinner_stop
        rm -f "$tmp_script"
        _setv_err "Download failed"
        return 1
    fi
    _setv_spinner_stop

    if [[ ! -s "$tmp_script" ]] || ! head -1 "$tmp_script" | grep -q '^#!/usr/bin/env bash'; then
        rm -f "$tmp_script"
        _setv_err "Invalid download. Your installation is unchanged."
        return 1
    fi

    command mv -f "$tmp_script" "$target"
    chmod 644 "$target"
    _setv_msg "Updated to ${_SETV_GREEN}${latest}${_SETV_RESET}"
    echo "  Reload your shell: ${_SETV_DIM}source ${target}${_SETV_RESET}"
}

# --- Migration check ---
# Detect old ~/virtualenvs/ directory and suggest migration
if [[ -d "$HOME/virtualenvs" && ! -d "$HOME/.virtualenvs" && "$SETV_VIRTUAL_DIR_PATH" == "$HOME/.virtualenvs" ]]; then
    _setv_warn "Found old ~/virtualenvs/ directory. setv 3.0 defaults to ~/.virtualenvs/"
    echo "  To migrate: mv ~/virtualenvs ~/.virtualenvs"
    echo "  Or set: export SETV_VIRTUAL_DIR_PATH=\$HOME/virtualenvs"
fi

# --- Tab completion ---

if [[ -n "${ZSH_VERSION:-}" ]]; then
    # shellcheck disable=SC2034,SC2154,SC2296
    _setv_zsh_complete() {
        local -a envs opts
        envs=("${(@f)$(_setv_envs)}")
        opts=(
            '-n:Create new virtual environment'
            '--new:Create new virtual environment'
            '-d:Delete virtual environment'
            '--delete:Delete virtual environment'
            '-l:List all virtual environments'
            '--list:List all virtual environments'
            '-i:Show environment info'
            '--info:Show environment info'
            '--link:Link current directory to environment'
            '--unlink:Remove project link'
            '--cd:cd to linked project'
            '--tmp:Create temporary environment'
            '--run:Run command in environment'
            '--init:Create .setv for auto-activate'
            'freeze:Export installed packages'
            'backup:Export all envs to backup dir'
            'restore:Recreate envs from backup'
            'doctor:Check all envs for problems'
            'rebuild:Fix broken environments'
            'update:Update to latest release'
            '--backend:Show active backend'
            '--version:Show version'
            '-h:Show help'
            '--help:Show help'
        )

        if (( CURRENT == 2 )); then
            _describe 'options' opts
            _describe 'virtual environments' envs
        elif (( CURRENT == 3 )); then
            case "${words[2]}" in
                -d|--delete|-i|--info|--link|--unlink|--cd|--run|--init|freeze|rebuild)  # shellcheck disable=SC2154
                    _describe 'virtual environments' envs
                    ;;
                -n|--new)
                    _message 'environment name'
                    ;;
            esac
        elif (( CURRENT == 4 )); then
            case "${words[2]}" in
                -n|--new)
                    local -a pyopts
                    pyopts=('-p:Specify Python version')
                    _describe 'options' pyopts
                    ;;
            esac
        fi
    }
    command -v compdef &>/dev/null && compdef _setv_zsh_complete setv

elif [[ -n "${BASH_VERSION:-}" ]]; then
    _setv_bash_complete() {
        local cur prev
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"

        case "$prev" in
            -d|--delete|-i|--info|--link|--unlink|--cd|--run|--init|freeze|rebuild)
                local envs
                envs=$(_setv_envs)
                # shellcheck disable=SC2207
                COMPREPLY=($(compgen -W "$envs" -- "$cur"))
                return
                ;;
            -p|--python)
                return
                ;;
            -n|--new)
                return
                ;;
        esac

        if [[ "$cur" == -* ]]; then
            # shellcheck disable=SC2207
            COMPREPLY=($(compgen -W "-n --new -d --delete -l --list -i --info --link --unlink --cd --tmp --run --init freeze backup restore doctor rebuild update --backend --version -h --help -p --python" -- "$cur"))
        else
            local envs
            envs=$(_setv_envs)
            # shellcheck disable=SC2207
            COMPREPLY=($(compgen -W "$envs" -- "$cur"))
        fi
    }
    complete -F _setv_bash_complete setv
fi

# --- Main entry point ---

setv() {
    if [[ $# -eq 0 ]]; then
        _setv_help
        return 0
    fi

    case "$1" in
        -h|--help)
            _setv_help
            ;;
        --version)
            echo "setv $SETV_VERSION"
            ;;
        -n|--new)
            shift
            _setv_create "$@"
            ;;
        -d|--delete)
            _setv_delete "${2:-}"
            ;;
        -l|--list)
            _setv_list
            ;;
        -i|--info)
            _setv_info "${2:-}"
            ;;
        --link)
            _setv_link "${2:-}"
            ;;
        --unlink)
            _setv_unlink "${2:-}"
            ;;
        --cd)
            _setv_cd "${2:-}"
            ;;
        --tmp)
            shift
            _setv_tmp "$@"
            ;;
        --run)
            shift
            _setv_run "$@"
            ;;
        --init)
            _setv_init "${2:-}"
            ;;
        freeze)
            _setv_freeze "${2:-}"
            ;;
        backup)
            _setv_backup "${2:-}"
            ;;
        restore)
            _setv_restore "${2:-}"
            ;;
        doctor)
            _setv_doctor
            ;;
        rebuild)
            _setv_rebuild "${2:-}"
            ;;
        update)
            _setv_update
            ;;
        --backend)
            local be
            be=$(_setv_backend)
            echo "Backend: $be"
            if [[ "$be" == "uv" ]]; then
                echo "uv version: $(uv --version 2>/dev/null || echo 'unknown')"
            fi
            ;;
        -*)
            _setv_err "Unknown option: $1"
            echo "Run 'setv --help' for usage"
            return 1
            ;;
        *)
            _setv_activate "$1"
            ;;
    esac
}
