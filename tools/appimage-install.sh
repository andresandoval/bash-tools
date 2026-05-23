#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_USER_INSTALL_ROOT="${HOME}/.local/opt/appimages"
readonly DEFAULT_USER_DESKTOP_DIR="${HOME}/.local/share/applications"
readonly DEFAULT_SYSTEM_INSTALL_ROOT="/opt/appimages"
readonly DEFAULT_SYSTEM_DESKTOP_DIR="/usr/share/applications"

APPIMAGE_PATH=""
APP_NAME=""
APP_ID=""
INSTALL_ROOT="$DEFAULT_USER_INSTALL_ROOT"
DESKTOP_DIR="$DEFAULT_USER_DESKTOP_DIR"
SYSTEM_INSTALL=false
INSTALL_DEPS=false
FORCE=false
NO_DESKTOP_DB_UPDATE=false

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}

show_help() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [options] <file.AppImage>

Description:
  Install an AppImage as a desktop application.

  By default, installation is user-local:
    AppImage:  ~/.local/opt/appimages/<app-id>/
    Desktop:   ~/.local/share/applications/<app-id>.desktop

Options:
  -n, --name <name>
      Display name for the application.
      If omitted, the script tries to read it from the extracted .desktop file.

  -i, --id <id>
      Application ID / folder name / desktop filename.
      If omitted, it is generated from the app name or AppImage filename.

  --install-root <path>
      Custom root directory where the AppImage and icon will be installed.

  --desktop-dir <path>
      Custom directory where the .desktop file will be installed.

  --system
      Install system-wide:
        AppImage:  /opt/appimages/<app-id>/
        Desktop:   /usr/share/applications/<app-id>.desktop

      This uses sudo for privileged file operations.

  --install-deps
      Install optional helper dependencies before running.
      Supported package managers:
        pacman, apt, dnf, zypper

  -f, --force
      Overwrite an existing installation.

  --no-desktop-db-update
      Do not run update-desktop-database after installing.

  -h, --help
      Show this help message.

Examples:
  $SCRIPT_NAME ~/Downloads/Cura.AppImage

  $SCRIPT_NAME --name "UltiMaker Cura" ~/Downloads/UltiMaker-Cura.AppImage

  $SCRIPT_NAME --id ultimaker-cura --name "UltiMaker Cura" ~/Downloads/UltiMaker-Cura.AppImage

  $SCRIPT_NAME --system ~/Downloads/MyApp.AppImage

  $SCRIPT_NAME --install-deps ~/Downloads/MyApp.AppImage
EOF
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_privileged() {
  if [[ "$SYSTEM_INSTALL" == true ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

install_dependencies() {
  local packages=(
    desktop-file-utils
  )

  log_info "Installing dependencies: ${packages[*]}"

  if command_exists pacman; then
    sudo pacman -S --needed --noconfirm "${packages[@]}"
  elif command_exists apt-get; then
    sudo apt-get update
    sudo apt-get install -y "${packages[@]}"
  elif command_exists dnf; then
    sudo dnf install -y "${packages[@]}"
  elif command_exists zypper; then
    sudo zypper install -y "${packages[@]}"
  else
    die "Unsupported package manager. Install these manually: ${packages[*]}"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--name)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        APP_NAME="$2"
        shift 2
        ;;
      -i|--id)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        APP_ID="$2"
        shift 2
        ;;
      --install-root)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        INSTALL_ROOT="$2"
        shift 2
        ;;
      --desktop-dir)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        DESKTOP_DIR="$2"
        shift 2
        ;;
      --system)
        SYSTEM_INSTALL=true
        INSTALL_ROOT="$DEFAULT_SYSTEM_INSTALL_ROOT"
        DESKTOP_DIR="$DEFAULT_SYSTEM_DESKTOP_DIR"
        shift
        ;;
      --install-deps)
        INSTALL_DEPS=true
        shift
        ;;
      -f|--force)
        FORCE=true
        shift
        ;;
      --no-desktop-db-update)
        NO_DESKTOP_DB_UPDATE=true
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        if [[ -n "$APPIMAGE_PATH" ]]; then
          die "Only one AppImage file can be provided."
        fi

        APPIMAGE_PATH="$1"
        shift
        ;;
    esac
  done

  [[ -n "$APPIMAGE_PATH" ]] || die "Missing AppImage file path."
}

sanitize_id() {
  local value="$1"

  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | sed -E 's/[^a-z0-9._-]+/-/g')"
  value="$(printf '%s' "$value" | sed -E 's/^-+|-+$//g')"

  [[ -n "$value" ]] || value="appimage-app"

  printf '%s' "$value"
}

read_desktop_value() {
  local desktop_file="$1"
  local key="$2"

  awk -F '=' -v key="$key" '
    $1 == key {
      print substr($0, index($0, "=") + 1)
      exit
    }
  ' "$desktop_file"
}

find_desktop_file() {
  local extracted_dir="$1"

  find "$extracted_dir" -type f -name '*.desktop' | head -n 1
}

find_icon_file() {
  local extracted_dir="$1"
  local desktop_file="$2"
  local icon_value="$3"

  if [[ -z "$icon_value" ]]; then
    return 1
  fi

  if [[ "$icon_value" == /* && -f "$icon_value" ]]; then
    printf '%s' "$icon_value"
    return 0
  fi

  local icon_basename
  icon_basename="$(basename "$icon_value")"

  if [[ "$icon_basename" == *.* ]]; then
    local found_with_extension
    found_with_extension="$(
      find "$extracted_dir" -type f -name "$icon_basename" | head -n 1
    )"

    if [[ -n "$found_with_extension" ]]; then
      printf '%s' "$found_with_extension"
      return 0
    fi
  fi

  local found_by_name
  found_by_name="$(
    find "$extracted_dir" -type f \( \
      -name "${icon_value}.png" -o \
      -name "${icon_value}.svg" -o \
      -name "${icon_value}.xpm" -o \
      -name "${icon_value}.ico" \
    \) | head -n 1
  )"

  if [[ -n "$found_by_name" ]]; then
    printf '%s' "$found_by_name"
    return 0
  fi

  local desktop_dir
  desktop_dir="$(dirname "$desktop_file")"

  local found_near_desktop
  found_near_desktop="$(
    find "$desktop_dir" -maxdepth 3 -type f \( \
      -name '*.png' -o \
      -name '*.svg' -o \
      -name '*.xpm' -o \
      -name '*.ico' \
    \) | head -n 1
  )"

  if [[ -n "$found_near_desktop" ]]; then
    printf '%s' "$found_near_desktop"
    return 0
  fi

  return 1
}

replace_or_add_desktop_key() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -qE "^${key}=" "$file"; then
    sed -i -E "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

ensure_desktop_entry_defaults() {
  local desktop_file="$1"

  grep -q '^Type=' "$desktop_file" || printf 'Type=Application\n' >> "$desktop_file"
  grep -q '^Terminal=' "$desktop_file" || printf 'Terminal=false\n' >> "$desktop_file"
  grep -q '^Categories=' "$desktop_file" || printf 'Categories=Utility;\n' >> "$desktop_file"
}

install_appimage() {
  local source_appimage
  source_appimage="$(realpath "$APPIMAGE_PATH")"

  [[ -f "$source_appimage" ]] || die "File does not exist: $APPIMAGE_PATH"
  [[ "$source_appimage" == *.AppImage || "$source_appimage" == *.appimage ]] || \
    log_warn "File does not end with .AppImage: $source_appimage"

  chmod +x "$source_appimage"

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  cleanup() {
    rm -rf "$tmp_dir"
  }

  trap cleanup EXIT

  log_info "Extracting AppImage metadata..."

  (
    cd "$tmp_dir"
    "$source_appimage" --appimage-extract >/dev/null
  ) || die "Failed to extract AppImage. The file may be invalid or unsupported."

  local extracted_dir="${tmp_dir}/squashfs-root"
  [[ -d "$extracted_dir" ]] || die "Extraction completed, but squashfs-root was not found."

  local desktop_source
  desktop_source="$(find_desktop_file "$extracted_dir")"
  [[ -n "$desktop_source" ]] || die "No .desktop file found inside the AppImage."

  local desktop_name
  desktop_name="$(read_desktop_value "$desktop_source" "Name")"

  if [[ -z "$APP_NAME" ]]; then
    if [[ -n "$desktop_name" ]]; then
      APP_NAME="$desktop_name"
    else
      APP_NAME="$(basename "$source_appimage")"
      APP_NAME="${APP_NAME%.*}"
    fi
  fi

  if [[ -z "$APP_ID" ]]; then
    APP_ID="$(sanitize_id "$APP_NAME")"
  else
    APP_ID="$(sanitize_id "$APP_ID")"
  fi

  local install_dir="${INSTALL_ROOT}/${APP_ID}"
  local appimage_filename
  appimage_filename="$(basename "$source_appimage")"

  local installed_appimage="${install_dir}/${appimage_filename}"
  local installed_desktop="${DESKTOP_DIR}/${APP_ID}.desktop"

  if [[ -e "$install_dir" && "$FORCE" != true ]]; then
    die "Installation already exists: $install_dir. Use --force to overwrite."
  fi

  if [[ -e "$installed_desktop" && "$FORCE" != true ]]; then
    die "Desktop entry already exists: $installed_desktop. Use --force to overwrite."
  fi

  log_info "Installing AppImage..."
  run_privileged mkdir -p "$install_dir"
  run_privileged cp "$source_appimage" "$installed_appimage"
  run_privileged chmod +x "$installed_appimage"

  local desktop_working_copy="${tmp_dir}/${APP_ID}.desktop"
  cp "$desktop_source" "$desktop_working_copy"

  local icon_value
  icon_value="$(read_desktop_value "$desktop_working_copy" "Icon")"

  local installed_icon=""
  local icon_source=""

  if icon_source="$(find_icon_file "$extracted_dir" "$desktop_source" "$icon_value")"; then
    local icon_extension
    icon_extension="${icon_source##*.}"

    installed_icon="${install_dir}/${APP_ID}.${icon_extension}"

    log_info "Installing icon..."
    run_privileged cp "$icon_source" "$installed_icon"
  else
    log_warn "No icon file found. The desktop entry may use a missing icon."
  fi

  replace_or_add_desktop_key "$desktop_working_copy" "Name" "$APP_NAME"
  replace_or_add_desktop_key "$desktop_working_copy" "Exec" "$installed_appimage"

  if [[ -n "$installed_icon" ]]; then
    replace_or_add_desktop_key "$desktop_working_copy" "Icon" "$installed_icon"
  fi

  ensure_desktop_entry_defaults "$desktop_working_copy"

  if command_exists desktop-file-validate; then
    if ! desktop-file-validate "$desktop_working_copy"; then
      log_warn "desktop-file-validate reported issues, but installation will continue."
    fi
  fi

  log_info "Installing desktop entry..."
  run_privileged mkdir -p "$DESKTOP_DIR"
  run_privileged cp "$desktop_working_copy" "$installed_desktop"

  if [[ "$NO_DESKTOP_DB_UPDATE" != true ]] && command_exists update-desktop-database; then
    log_info "Updating desktop database..."
    if [[ "$SYSTEM_INSTALL" == true ]]; then
      sudo update-desktop-database "$DESKTOP_DIR" || log_warn "Failed to update desktop database."
    else
      update-desktop-database "$DESKTOP_DIR" || log_warn "Failed to update desktop database."
    fi
  fi

  log_info "Installed successfully."
  printf '\n'
  printf 'Application: %s\n' "$APP_NAME"
  printf 'App ID:      %s\n' "$APP_ID"
  printf 'AppImage:    %s\n' "$installed_appimage"
  printf 'Desktop:     %s\n' "$installed_desktop"

  if [[ -n "$installed_icon" ]]; then
    printf 'Icon:        %s\n' "$installed_icon"
  fi
}

main() {
  parse_args "$@"

  if [[ "$INSTALL_DEPS" == true ]]; then
    install_dependencies
  fi

  install_appimage
}

main "$@"