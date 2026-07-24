#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# bash-tools setup
#
# This script manages shell configuration for a repository with this structure:
#
#   aliases/       *.bash files sourced from ~/.bashrc
#   environment/   *.bash files sourced from ~/.bashrc
#   tools/         *.sh files exposed as commands through symlinks
#
# Persistent state is stored only in:
#
#   ~/.bashrc
#   ~/.local/bin/bash-tools
#
# The repository itself is treated as immutable. This script does not generate
# files, metadata, or symlinks inside the repository.
# ==============================================================================

# Legacy delimiters. The script no longer writes this block; it only reads it
# once as a migration fallback so an existing selection survives the move to the
# managed file below. Removing a pre-existing block from ~/.bashrc is manual.
readonly MANAGED_START="# >>> bash-tools managed block >>>"
readonly MANAGED_END="# <<< bash-tools managed block <<<"
readonly WRAPPER_MARKER="# bash-tools managed wrapper"
readonly MANAGED_SOURCE_MARKER="# bash-tools managed source"

readonly BASHRC_FILE="${HOME}/.bashrc"
readonly TOOLS_BIN_DIR="${HOME}/.local/bin/bash-tools"

# The managed shell configuration lives in its own bashrc-style file inside the
# tools directory. ~/.bashrc only sources it (see ensure_bashrc_source). The dir
# is on PATH, but a non-executable dotfile here is ignored by command lookup.
readonly BASH_TOOLS_RC_FILE="${TOOLS_BIN_DIR}/.bashrc"

# BASH_TOOLS_HOME is the canonical repository root used by this script and by the
# generated ~/.bashrc block. If the variable is not already defined, infer it from
# this setup.sh location.
if [[ -z "${BASH_TOOLS_HOME:-}" ]]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    export BASH_TOOLS_HOME="${SCRIPT_DIR}"
fi

readonly REPO_ROOT="${BASH_TOOLS_HOME}"
readonly ALIASES_DIR="${REPO_ROOT}/aliases"
readonly ENVIRONMENT_DIR="${REPO_ROOT}/environment"
readonly FUNCTIONS_DIR="${REPO_ROOT}/functions"
readonly TOOLS_DIR="${REPO_ROOT}/tools"

# Global arrays populated during execution.
declare -a CURRENT_ALIAS_FILES=()
declare -a CURRENT_ENVIRONMENT_FILES=()
declare -a CURRENT_FUNCTION_FILES=()
declare -a CURRENT_TOOL_FILES=()

declare -a PREVIOUS_INVENTORY=()
declare -a PREVIOUS_ENABLED_SOURCES=()
declare -a PREVIOUS_ENABLED_TOOLS=()

declare -a SELECTED_SOURCES=()
declare -a SELECTED_TOOLS=()

# ------------------------------------------------------------------------------
# Basic logging helpers.
# ------------------------------------------------------------------------------

info() {
    printf 'INFO: %s\n' "$*"
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

error() {
    printf 'ERROR: %s\n' "$*" >&2
}

is_windows() {
    [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* || "${OS:-}" == "Windows_NT" ]]
}

# ------------------------------------------------------------------------------
# Dependency management.
#
# The script prefers whiptail or dialog for a checkbox-style terminal UI. If
# neither is available, it warns with an install hint for the detected platform
# and falls back to the built-in text selector. Nothing is installed
# automatically.
# ------------------------------------------------------------------------------

install_ui_dependency() {
    if command -v whiptail >/dev/null 2>&1 || command -v dialog >/dev/null 2>&1; then
        return 0
    fi

    warn "No checkbox UI dependency found (whiptail or dialog)."

    if command -v pacman >/dev/null 2>&1; then
        # On Arch, CachyOS, and Manjaro, whiptail is provided by libnewt.
        warn "To enable the checkbox UI, install it manually: sudo pacman -S libnewt"
    elif command -v apt-get >/dev/null 2>&1; then
        warn "To enable the checkbox UI, install it manually: sudo apt-get install whiptail"
    elif command -v dnf >/dev/null 2>&1; then
        warn "To enable the checkbox UI, install it manually: sudo dnf install newt"
    elif command -v zypper >/dev/null 2>&1; then
        warn "To enable the checkbox UI, install it manually: sudo zypper install newt"
    elif command -v apk >/dev/null 2>&1; then
        warn "To enable the checkbox UI, install it manually: sudo apk add newt"
    elif is_windows; then
        warn "No native whiptail/dialog package is available on Windows (Git Bash / MSYS / Cygwin)."
    else
        warn "Install 'whiptail' or 'dialog' using your system package manager to enable the checkbox UI."
    fi

    info "Continuing with the built-in text-based selector."
    return 0
}

# ------------------------------------------------------------------------------
# Validate expected repository structure.
# ------------------------------------------------------------------------------

validate_repository() {
    if [[ ! -d "${REPO_ROOT}" ]]; then
        error "BASH_TOOLS_HOME does not point to an existing directory: ${REPO_ROOT}"
        exit 1
    fi

    for dir in "${ALIASES_DIR}" "${ENVIRONMENT_DIR}" "${FUNCTIONS_DIR}" "${TOOLS_DIR}"; do
        if [[ ! -d "${dir}" ]]; then
            error "Required directory does not exist: ${dir}"
            exit 1
        fi
    done
}

# ------------------------------------------------------------------------------
# Read available files from the repository.
#
# Only filenames are stored in these arrays, not full paths. The folder name is
# added later when generating managed entries such as aliases/foo.bash.
# ------------------------------------------------------------------------------

load_current_files() {
    mapfile -t CURRENT_ALIAS_FILES < <(
        find "${ALIASES_DIR}" -maxdepth 1 -type f -name '*.bash' -printf '%f\n' | sort
    )

    mapfile -t CURRENT_ENVIRONMENT_FILES < <(
        find "${ENVIRONMENT_DIR}" -maxdepth 1 -type f -name '*.bash' -printf '%f\n' | sort
    )

    mapfile -t CURRENT_FUNCTION_FILES < <(
        find "${FUNCTIONS_DIR}" -maxdepth 1 -type f -name '*.bash' -printf '%f\n' | sort
    )

    mapfile -t CURRENT_TOOL_FILES < <(
        find "${TOOLS_DIR}" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' | sort
    )
}

# ------------------------------------------------------------------------------
# Extract the existing managed block from ~/.bashrc, if present.
# ------------------------------------------------------------------------------

extract_managed_block() {
    if [[ ! -f "${BASHRC_FILE}" ]]; then
        return 0
    fi

    awk \
        -v start="${MANAGED_START}" \
        -v end="${MANAGED_END}" \
        '
        $0 == start { in_block = 1; next }
        $0 == end { in_block = 0; next }
        in_block { print }
        ' \
        "${BASHRC_FILE}"
}

legacy_block_exists() {
    [[ -f "${BASHRC_FILE}" ]] && grep -Fxq "${MANAGED_START}" "${BASHRC_FILE}"
}

# True when there is any prior state to read: the managed file, or (for one-time
# migration) a legacy block still present in ~/.bashrc.
managed_state_exists() {
    [[ -f "${BASH_TOOLS_RC_FILE}" ]] || legacy_block_exists
}

# Print the content the previous-state parser reads. Prefers the managed file;
# falls back to the legacy ~/.bashrc block so an existing selection is preserved
# on the first run after the move.
read_managed_state() {
    if [[ -f "${BASH_TOOLS_RC_FILE}" ]]; then
        cat -- "${BASH_TOOLS_RC_FILE}"
    else
        extract_managed_block
    fi
}

# ------------------------------------------------------------------------------
# Load previous state from the managed ~/.bashrc block and from existing symlinks.
#
# The inventory comments make it possible to detect files that are newly added or
# removed without writing metadata into the repository.
# ------------------------------------------------------------------------------

load_previous_state() {
    local block
    block="$(read_managed_state || true)"

    PREVIOUS_INVENTORY=()
    PREVIOUS_ENABLED_SOURCES=()
    PREVIOUS_ENABLED_TOOLS=()

    while IFS= read -r line; do
        if [[ "${line}" =~ ^#\ bash-tools\ inventory:\ (.+)$ ]]; then
            PREVIOUS_INVENTORY+=("${BASH_REMATCH[1]}")
        fi

        if [[ "${line}" =~ source\ \"\$BASH_TOOLS_HOME/(aliases|environment|functions)/([^\"]+)\" ]]; then
            PREVIOUS_ENABLED_SOURCES+=("${BASH_REMATCH[1]}/${BASH_REMATCH[2]}")
        fi
    done <<< "${block}"

    if [[ -d "${TOOLS_BIN_DIR}" ]]; then
        while IFS= read -r entry_path; do
            local managed_target
            local filename

            # Never treat our own managed config file as a tool entry.
            [[ "${entry_path}" == "${BASH_TOOLS_RC_FILE}" ]] && continue

            managed_target="$(read_managed_target "${entry_path}")"

            if [[ -n "${managed_target}" ]]; then
                filename="$(basename -- "${managed_target}")"
                PREVIOUS_ENABLED_TOOLS+=("tools/${filename}")
            fi
        done < <(find "${TOOLS_BIN_DIR}" -maxdepth 1 \( -type l -o -type f \) -print | sort)
    fi
}

# ------------------------------------------------------------------------------
# Utility membership checks.
# ------------------------------------------------------------------------------

array_contains() {
    local needle="$1"
    shift

    local item
    for item in "$@"; do
        if [[ "${item}" == "${needle}" ]]; then
            return 0
        fi
    done

    return 1
}

current_inventory() {
    local file

    for file in "${CURRENT_ALIAS_FILES[@]}"; do
        printf 'aliases/%s\n' "${file}"
    done

    for file in "${CURRENT_ENVIRONMENT_FILES[@]}"; do
        printf 'environment/%s\n' "${file}"
    done

    for file in "${CURRENT_FUNCTION_FILES[@]}"; do
        printf 'functions/%s\n' "${file}"
    done

    for file in "${CURRENT_TOOL_FILES[@]}"; do
        printf 'tools/%s\n' "${file}"
    done
}

# ------------------------------------------------------------------------------
# Display all available files grouped by folder.
#
# This is only informational. The actual selection UI is a single checklist.
# ------------------------------------------------------------------------------

print_available_files() {
    local file

    printf '\nAvailable aliases:\n'
    if [[ "${#CURRENT_ALIAS_FILES[@]}" -eq 0 ]]; then
        printf '  none\n'
    else
        for file in "${CURRENT_ALIAS_FILES[@]}"; do
            printf '  - %s\n' "${file}"
        done
    fi

    printf '\nAvailable environment files:\n'
    if [[ "${#CURRENT_ENVIRONMENT_FILES[@]}" -eq 0 ]]; then
        printf '  none\n'
    else
        for file in "${CURRENT_ENVIRONMENT_FILES[@]}"; do
            printf '  - %s\n' "${file}"
        done
    fi

    printf '\nAvailable functions:\n'
    if [[ "${#CURRENT_FUNCTION_FILES[@]}" -eq 0 ]]; then
        printf '  none\n'
    else
        for file in "${CURRENT_FUNCTION_FILES[@]}"; do
            printf '  - %s\n' "${file}"
        done
    fi

    printf '\nAvailable tools:\n'
    if [[ "${#CURRENT_TOOL_FILES[@]}" -eq 0 ]]; then
        printf '  none\n'
    else
        for file in "${CURRENT_TOOL_FILES[@]}"; do
            printf '  - %s -> %s/%s\n' "${file}" "${TOOLS_BIN_DIR}" "${file%.sh}"
        done
    fi

    printf '\n'
}

# ------------------------------------------------------------------------------
# Show alerts about new and removed files.
# ------------------------------------------------------------------------------

display_change_alerts() {
    if ! managed_state_exists; then
        return 0
    fi

    local -a current=()
    local item

    mapfile -t current < <(current_inventory)

    local found_new=false
    local found_removed=false

    for item in "${current[@]}"; do
        if ! array_contains "${item}" "${PREVIOUS_INVENTORY[@]}"; then
            if [[ "${found_new}" == false ]]; then
                printf '\nNewly detected files:\n'
                found_new=true
            fi

            printf '  + %s\n' "${item}"
        fi
    done

    for item in "${PREVIOUS_INVENTORY[@]}"; do
        if ! array_contains "${item}" "${current[@]}"; then
            if [[ "${found_removed}" == false ]]; then
                printf '\nRemoved files detected:\n'
                found_removed=true
            fi

            printf '  - %s\n' "${item}"
        fi
    done

    if [[ "${found_new}" == true || "${found_removed}" == true ]]; then
        printf '\n'
    fi
}

# ------------------------------------------------------------------------------
# Build checklist options.
#
# The UI is intentionally a single checklist, but the item labels include their
# folder prefix:
#
#   aliases/foo.bash
#   environment/java.bash
#   tools/git-prune.sh
#
# Each option is represented as:
#
#   tag description default_state
# ------------------------------------------------------------------------------

build_checklist_options() {
    local file
    local tag
    local state

    for file in "${CURRENT_ALIAS_FILES[@]}"; do
        tag="aliases/${file}"
        state="OFF"

        if array_contains "${tag}" "${PREVIOUS_ENABLED_SOURCES[@]}"; then
            state="ON"
        fi

        printf '%s\t%s\t%s\n' "${tag}" "source from ~/.bashrc" "${state}"
    done

    for file in "${CURRENT_ENVIRONMENT_FILES[@]}"; do
        tag="environment/${file}"
        state="OFF"

        if array_contains "${tag}" "${PREVIOUS_ENABLED_SOURCES[@]}"; then
            state="ON"
        fi

        printf '%s\t%s\t%s\n' "${tag}" "source from ~/.bashrc" "${state}"
    done

    for file in "${CURRENT_FUNCTION_FILES[@]}"; do
        tag="functions/${file}"
        state="OFF"

        if array_contains "${tag}" "${PREVIOUS_ENABLED_SOURCES[@]}"; then
            state="ON"
        fi

        printf '%s\t%s\t%s\n' "${tag}" "source from ~/.bashrc" "${state}"
    done

    for file in "${CURRENT_TOOL_FILES[@]}"; do
        tag="tools/${file}"
        state="OFF"

        if array_contains "${tag}" "${PREVIOUS_ENABLED_TOOLS[@]}"; then
            state="ON"
        fi

        printf '%s\t%s\t%s\n' "${tag}" "symlink as ${file%.sh}" "${state}"
    done
}

# ------------------------------------------------------------------------------
# Preferred checkbox UI using whiptail or dialog when available.
# ------------------------------------------------------------------------------

select_with_checkbox_ui() {
    local ui_command="$1"

    local -a options=()
    local line
    local tag
    local description
    local state

    while IFS=$'\t' read -r tag description state; do
        options+=("${tag}" "${description}" "${state}")
    done < <(build_checklist_options)

    if [[ "${#options[@]}" -eq 0 ]]; then
        warn "No files found under aliases/, environment/, functions/, or tools/."
        return 0
    fi

    local output

    if [[ "${ui_command}" == "whiptail" ]]; then
        output="$(
            whiptail \
                --title "bash-tools setup" \
                --checklist "Select files to enable. Unchecked files will be disabled." \
                25 100 15 \
                "${options[@]}" \
                3>&1 1>&2 2>&3
        )"
    else
        output="$(
            dialog \
                --title "bash-tools setup" \
                --checklist "Select files to enable. Unchecked files will be disabled." \
                25 100 15 \
                "${options[@]}" \
                3>&1 1>&2 2>&3
        )"
    fi

    parse_selected_items "${output}"
}

# ------------------------------------------------------------------------------
# Fallback interactive selector for systems without whiptail/dialog.
#
# This is not as polished as a checkbox TUI, but it keeps the script dependency
# free and still allows individual enable/disable behavior.
# ------------------------------------------------------------------------------

select_with_fallback_menu() {
    local -a items=()
    local -a states=()

    local line
    local tag
    local description
    local state

    while IFS=$'\t' read -r tag description state; do
        items+=("${tag}")
        states+=("${state}")
    done < <(build_checklist_options)

    if [[ "${#items[@]}" -eq 0 ]]; then
        warn "No files found under aliases/, environment/, or tools/."
        return 0
    fi

    while true; do
        printf '\nSelect files to enable or disable:\n\n'

        local index
        for index in "${!items[@]}"; do
            local marker=' '
            if [[ "${states[index]}" == "ON" ]]; then
                marker='x'
            fi

            printf '  %2d) [%s] %s\n' "$((index + 1))" "${marker}" "${items[index]}"
        done

        printf '\nCommands:\n'
        printf '  number  Toggle item\n'
        printf '  a       Apply changes\n'
        printf '  q       Quit without applying\n\n'

        read -r -p "Choice: " choice

        case "${choice}" in
            a|A)
                break
                ;;
            q|Q)
                info "No changes applied."
                exit 0
                ;;
            ''|*[!0-9]*)
                warn "Invalid choice."
                ;;
            *)
                local selected_index=$((choice - 1))

                if (( selected_index < 0 || selected_index >= ${#items[@]} )); then
                    warn "Invalid item number."
                    continue
                fi

                if [[ "${states[selected_index]}" == "ON" ]]; then
                    states[selected_index]="OFF"
                else
                    states[selected_index]="ON"
                fi
                ;;
        esac
    done

    local selected_output=""
    for index in "${!items[@]}"; do
        if [[ "${states[index]}" == "ON" ]]; then
            selected_output+="${items[index]} "
        fi
    done

    parse_selected_items "${selected_output}"
}

# ------------------------------------------------------------------------------
# Parse selected item output from whiptail/dialog/fallback.
# ------------------------------------------------------------------------------

parse_selected_items() {
    local raw_output="$1"

    SELECTED_SOURCES=()
    SELECTED_TOOLS=()

    # whiptail usually returns quoted items. Remove quotes to simplify parsing.
    raw_output="${raw_output//\"/}"

    local item
    for item in ${raw_output}; do
        case "${item}" in
            aliases/*.bash|environment/*.bash|functions/*.bash)
                SELECTED_SOURCES+=("${item}")
                ;;
            tools/*.sh)
                SELECTED_TOOLS+=("${item}")
                ;;
            *)
                warn "Ignoring unexpected selection: ${item}"
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Select files to enable.
# ------------------------------------------------------------------------------

select_files() {
    if command -v whiptail >/dev/null 2>&1; then
        select_with_checkbox_ui "whiptail"
    elif command -v dialog >/dev/null 2>&1; then
        select_with_checkbox_ui "dialog"
    else
        warn "No supported checkbox UI tool is available."
        warn "Expected either whiptail or dialog."
        warn "Falling back to a basic selector."
        select_with_fallback_menu
    fi
}

# ------------------------------------------------------------------------------
# Reconcile ~/.local/bin/bash-tools entries.
#
# On Linux/macOS, each enabled tool is exposed as a symlink. On Windows (Git
# Bash / MSYS / Cygwin), where ln -s often silently copies files, a small bash
# wrapper script is written instead. The wrapper carries a marker comment plus
# a "# Source:" line so subsequent runs can identify and clean up entries this
# script previously created.
#
# Rules:
#   - selected tools get an entry (symlink or wrapper)
#   - unselected tools lose managed entries
#   - removed repository files lose obsolete entries
#   - unrelated files/symlinks are not touched
# ------------------------------------------------------------------------------

# Returns the source path inside TOOLS_DIR if the given path is a managed entry
# (either a symlink we created or a wrapper script we wrote). Prints nothing
# when the path is not managed by this script.
read_managed_target() {
    local path="$1"

    if [[ -L "${path}" ]]; then
        local link_target
        link_target="$(readlink "${path}")"
        if [[ "${link_target}" == "${TOOLS_DIR}/"* ]]; then
            printf '%s\n' "${link_target}"
        fi
        return 0
    fi

    if [[ -f "${path}" ]]; then
        if grep -Fq "${WRAPPER_MARKER}" "${path}" 2>/dev/null; then
            local source_line
            source_line="$(grep -m1 '^# Source: ' "${path}" 2>/dev/null || true)"
            source_line="${source_line#"# Source: "}"
            if [[ "${source_line}" == "${TOOLS_DIR}/"* ]]; then
                printf '%s\n' "${source_line}"
            fi
        fi
    fi
}

create_tool_wrapper() {
    local source_path="$1"
    local destination_path="$2"

    cat > "${destination_path}" <<WRAPPER_EOF
#!/usr/bin/env bash
${WRAPPER_MARKER}
# Source: ${source_path}
exec bash "${source_path}" "\$@"
WRAPPER_EOF

    chmod +x "${destination_path}" 2>/dev/null || true
}

reconcile_tool_symlinks() {
    mkdir -p "${TOOLS_BIN_DIR}"

    local entry_path
    local managed_target

    # Remove obsolete managed entries first.
    if [[ -d "${TOOLS_BIN_DIR}" ]]; then
        while IFS= read -r entry_path; do
            # Never treat our own managed config file as a tool entry.
            [[ "${entry_path}" == "${BASH_TOOLS_RC_FILE}" ]] && continue

            managed_target="$(read_managed_target "${entry_path}")"

            if [[ -z "${managed_target}" ]]; then
                continue
            fi

            local target_file
            local repo_relative_tool

            target_file="$(basename -- "${managed_target}")"
            repo_relative_tool="tools/${target_file}"

            if [[ ! -f "${managed_target}" ]] || ! array_contains "${repo_relative_tool}" "${SELECTED_TOOLS[@]}"; then
                rm -f -- "${entry_path}"
                info "Removed obsolete tool entry: ${entry_path}"
            fi
        done < <(find "${TOOLS_BIN_DIR}" -maxdepth 1 \( -type l -o -type f \) -print | sort)
    fi

    # Create or refresh selected tool entries.
    local selected_tool
    local filename
    local command_name
    local source_path
    local destination_path

    for selected_tool in "${SELECTED_TOOLS[@]}"; do
        filename="$(basename -- "${selected_tool}")"
        command_name="${filename%.sh}"

        source_path="${TOOLS_DIR}/${filename}"
        destination_path="${TOOLS_BIN_DIR}/${command_name}"

        if [[ ! -f "${source_path}" ]]; then
            warn "Selected tool no longer exists, skipping: ${source_path}"
            continue
        fi

        if [[ ! -x "${source_path}" ]]; then
            warn "Tool is not executable: ${source_path}"
            warn "The command may fail until the file has execute permission."
        fi

        # If something already exists at the destination, only replace it when
        # we recognize it as one of our own managed entries.
        if [[ -e "${destination_path}" || -L "${destination_path}" ]]; then
            local existing_managed_target
            existing_managed_target="$(read_managed_target "${destination_path}")"

            if [[ -z "${existing_managed_target}" ]]; then
                warn "Cannot replace unrelated file at: ${destination_path}"
                continue
            fi

            rm -f -- "${destination_path}"
        fi

        if is_windows; then
            create_tool_wrapper "${source_path}" "${destination_path}"
            info "Enabled tool command (wrapper): ${command_name}"
        else
            ln -sfn -- "${source_path}" "${destination_path}"
            info "Enabled tool command: ${command_name}"
        fi
    done
}

# ------------------------------------------------------------------------------
# Generate the managed configuration file content.
#
# This is a standalone bashrc-style file (written to BASH_TOOLS_RC_FILE) that
# ~/.bashrc sources. The file itself is the boundary, so no delimiters are used.
# ------------------------------------------------------------------------------

generate_managed_file() {
    local escaped_repo_root
    escaped_repo_root="$(printf '%q' "${REPO_ROOT}")"

    printf '# This file is generated by bash-tools/setup.sh and is overwritten on\n'
    printf '# every run. It is sourced from ~/.bashrc. Edit the repository files,\n'
    printf '# not this file.\n'
    printf '\n'

    printf '# Repository root used by all managed entries.\n'
    printf 'export BASH_TOOLS_HOME=%s\n' "${escaped_repo_root}"
    printf '\n'

    printf '# Expose enabled tools as real shell commands.\n'
    printf 'if [[ ":$PATH:" != *":$HOME/.local/bin/bash-tools:"* ]]; then\n'
    printf '    export PATH="$HOME/.local/bin/bash-tools:$PATH"\n'
    printf 'fi\n'
    printf '\n'

    printf '# Enabled aliases and environment files.\n'

    local selected_source
    for selected_source in "${SELECTED_SOURCES[@]}"; do
        printf '[[ -f "$BASH_TOOLS_HOME/%s" ]] && source "$BASH_TOOLS_HOME/%s"\n' \
            "${selected_source}" \
            "${selected_source}"
    done

    printf '\n'
    printf '# Known repository inventory. Used only to detect newly added or removed files.\n'

    local item
    while IFS= read -r item; do
        printf '# bash-tools inventory: %s\n' "${item}"
    done < <(current_inventory)
}

# ------------------------------------------------------------------------------
# Write the managed configuration file.
#
# The whole file is regenerated and replaced atomically on every run.
# ------------------------------------------------------------------------------

write_managed_file() {
    mkdir -p "${TOOLS_BIN_DIR}"

    local temp_file
    temp_file="$(mktemp)"

    generate_managed_file > "${temp_file}"

    mv -- "${temp_file}" "${BASH_TOOLS_RC_FILE}"
    info "Updated ${BASH_TOOLS_RC_FILE}"
}

# ------------------------------------------------------------------------------
# Ensure ~/.bashrc sources the managed file.
#
# Adds a single, marked source line if it is not already present. This is
# idempotent and does not touch any pre-existing legacy managed block, which is
# cleaned up manually.
# ------------------------------------------------------------------------------

ensure_bashrc_source() {
    touch "${BASHRC_FILE}"

    if grep -Fxq "${MANAGED_SOURCE_MARKER}" "${BASHRC_FILE}"; then
        return 0
    fi

    {
        printf '\n'
        printf '%s\n' "${MANAGED_SOURCE_MARKER}"
        printf '[[ -f "$HOME/.local/bin/bash-tools/.bashrc" ]] && source "$HOME/.local/bin/bash-tools/.bashrc"\n'
    } >> "${BASHRC_FILE}"

    info "Added source line to ${BASHRC_FILE}"
}

# ------------------------------------------------------------------------------
# Print post-setup hints.
#
# A selectable file may ship a sibling "<filename>.hint" Markdown file holding
# follow-up steps that live outside the shell (e.g. Windows Terminal settings
# for environment/wsl-terminal.bash). The hints of all currently enabled items
# are printed after the closing message on every run, so they also serve as
# reminders. When no enabled item has a hint, nothing is printed.
# ------------------------------------------------------------------------------

print_post_setup_hints() {
    local item hint_file line printed_header=0

    for item in "${SELECTED_SOURCES[@]}" "${SELECTED_TOOLS[@]}"; do
        hint_file="${REPO_ROOT}/${item}.hint"
        [[ -f "${hint_file}" ]] || continue

        if (( printed_header == 0 )); then
            printf '\nHints:\n'
            printed_header=1
        fi

        printf '\n  %s:\n' "${item##*/}"
        while IFS= read -r line || [[ -n "${line}" ]]; do
            printf '    %s\n' "${line}"
        done < "${hint_file}"
    done
}

# ------------------------------------------------------------------------------
# Main execution flow.
# ------------------------------------------------------------------------------

main() {
    install_ui_dependency

    validate_repository
    mkdir -p "${TOOLS_BIN_DIR}"

    load_current_files
    load_previous_state

    print_available_files
    display_change_alerts

    select_files

    reconcile_tool_symlinks
    write_managed_file
    ensure_bashrc_source

    printf '\nDone.\n'
    printf 'Open a new shell or run:\n'
    printf '  source ~/.bashrc\n'

    print_post_setup_hints
}

main "$@"