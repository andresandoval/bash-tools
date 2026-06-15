#!/usr/bin/env bash

set -euo pipefail

show_help() {
  cat <<EOF
Usage:
  $(basename "$0") <input.pdf> <deterioration> <mode>

Description:
  Ages a PDF to make it look like an old scan, photocopy, or low-quality
  black-and-white document.

Arguments:
  input.pdf       Input PDF file.
  deterioration  Deterioration percentage from 0 to 100.
  mode           Aging style.

Available modes:
  bw-lowres       Black-and-white low-resolution PDF.
  old-copy        Old photocopy style with grayscale, noise, and blur.
  bad-scan        Very degraded scanned document style.

Output:
  Creates a PDF with the same filename plus:
    _old_<deterioration>_<mode>.pdf

Examples:
  $(basename "$0") document.pdf 40 bw-lowres
  $(basename "$0") document.pdf 60 old-copy
  $(basename "$0") document.pdf 85 bad-scan

Output example:
  document_old_60_old-copy.pdf

Requirements:
  - poppler-utils: pdftoppm
  - imagemagick: magick
  - ghostscript

Install examples:
  Fedora:
    sudo dnf install poppler-utils ImageMagick ghostscript

  Ubuntu/Debian:
    sudo apt install poppler-utils imagemagick ghostscript

  Arch:
    sudo pacman -S poppler imagemagick ghostscript
EOF
}

fail() {
  echo "Error: $1" >&2
  exit 1
}

check_dependencies() {
  local required_commands=("pdftoppm" "magick")

  for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      fail "Required command not found: $command_name"
    fi
  done
}

validate_input() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
    exit 0
  fi

  if [[ $# -ne 3 ]]; then
    show_help
    exit 1
  fi

  if [[ ! -f "$INPUT_FILE" ]]; then
    fail "Input file does not exist: $INPUT_FILE"
  fi

  if [[ "${INPUT_FILE,,}" != *.pdf ]]; then
    fail "Input file must be a PDF."
  fi

  if ! [[ "$DETERIORATION" =~ ^[0-9]+$ ]]; then
    fail "Deterioration must be a number from 0 to 100."
  fi

  if (( DETERIORATION < 0 || DETERIORATION > 100 )); then
    fail "Deterioration must be between 0 and 100."
  fi

  case "$MODE" in
    bw-lowres|old-copy|bad-scan)
      ;;
    *)
      fail "Invalid mode: $MODE. Use one of: bw-lowres, old-copy, bad-scan"
      ;;
  esac
}

calculate_common_values() {
  DPI=$(( 180 - DETERIORATION ))
  if (( DPI < 70 )); then
    DPI=70
  fi

  NOISE=$(awk "BEGIN { printf \"%.2f\", 0.05 + ($DETERIORATION / 100) * 0.75 }")
  BLUR=$(awk "BEGIN { printf \"%.2f\", 0.10 + ($DETERIORATION / 100) * 1.20 }")

  DOWN_SCALE=$(( 100 - (DETERIORATION / 2) ))
  if (( DOWN_SCALE < 45 )); then
    DOWN_SCALE=45
  fi

  UP_SCALE=$(( 10000 / DOWN_SCALE ))

  THRESHOLD=$(( 75 - (DETERIORATION / 2) ))
  if (( THRESHOLD < 35 )); then
    THRESHOLD=35
  fi

  ROTATION=$(awk "BEGIN { printf \"%.2f\", ($DETERIORATION / 100) * 0.6 }")
  JPEG_QUALITY=$(( 95 - DETERIORATION / 2 ))
  if (( JPEG_QUALITY < 35 )); then
    JPEG_QUALITY=35
  fi
}

process_bw_lowres() {
  local image="$1"

  magick "$image" \
    -colorspace Gray \
    -resize "${DOWN_SCALE}%" \
    -resize "${UP_SCALE}%" \
    -attenuate "$NOISE" +noise Gaussian \
    -blur "0x$BLUR" \
    -threshold "${THRESHOLD}%" \
    "$image"
}

process_old_copy() {
  local image="$1"

  local old_copy_noise
  local old_copy_blur

  old_copy_noise=$(awk "BEGIN { printf \"%.2f\", $NOISE * 0.70 }")
  old_copy_blur=$(awk "BEGIN { printf \"%.2f\", $BLUR * 0.80 }")

  magick "$image" \
    -colorspace Gray \
    -normalize \
    -contrast \
    -attenuate "$old_copy_noise" +noise Gaussian \
    -blur "0x$old_copy_blur" \
    -resize "${DOWN_SCALE}%" \
    -resize "${UP_SCALE}%" \
    -quality "$JPEG_QUALITY" \
    "$image"
}

process_bad_scan() {
  local image="$1"

  local bad_scan_noise
  local bad_scan_blur
  local bad_scan_threshold

  bad_scan_noise=$(awk "BEGIN { printf \"%.2f\", $NOISE * 1.15 }")
  bad_scan_blur=$(awk "BEGIN { printf \"%.2f\", $BLUR * 1.25 }")
  bad_scan_threshold=$(( THRESHOLD - 5 ))

  if (( bad_scan_threshold < 30 )); then
    bad_scan_threshold=30
  fi

  magick "$image" \
    -colorspace Gray \
    -normalize \
    -attenuate "$bad_scan_noise" +noise Gaussian \
    -blur "0x$bad_scan_blur" \
    -resize "${DOWN_SCALE}%" \
    -resize "${UP_SCALE}%" \
    -threshold "${bad_scan_threshold}%" \
    -rotate "$ROTATION" \
    "$image"
}

process_image() {
  local image="$1"

  case "$MODE" in
    bw-lowres)
      process_bw_lowres "$image"
      ;;
    old-copy)
      process_old_copy "$image"
      ;;
    bad-scan)
      process_bad_scan "$image"
      ;;
  esac
}

INPUT_FILE="${1:-}"
DETERIORATION="${2:-}"
MODE="${3:-}"

validate_input "$@"
check_dependencies
calculate_common_values

INPUT_DIR="$(dirname "$INPUT_FILE")"
INPUT_BASE="$(basename "$INPUT_FILE" .pdf)"
OUTPUT_FILE="${INPUT_DIR}/${INPUT_BASE}_old_${DETERIORATION}_${MODE}.pdf"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Input file:     $INPUT_FILE"
echo "Output file:    $OUTPUT_FILE"
echo "Deterioration:  ${DETERIORATION}%"
echo "Mode:           $MODE"
echo "DPI:            $DPI"
echo "Noise:          $NOISE"
echo "Blur:           $BLUR"
echo "Downscale:      ${DOWN_SCALE}%"
echo "Upscale:        ${UP_SCALE}%"
echo "Threshold:      ${THRESHOLD}%"
echo

echo "Rendering PDF pages..."
pdftoppm -r "$DPI" "$INPUT_FILE" "$WORK_DIR/page" -png

echo "Applying aging effect..."
for image in "$WORK_DIR"/*.png; do
  process_image "$image"
done

echo "Rebuilding PDF..."
magick "$WORK_DIR"/*.png "$OUTPUT_FILE"

echo "Done: $OUTPUT_FILE"
