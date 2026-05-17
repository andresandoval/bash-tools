#!/bin/bash

currentPath="$(dirname "$(realpath "$0")")"

targetPath="$HOME/.bashrc.d"
mkdir -p "$targetPath"

safeLink() {
  sh="$currentPath/$1.sh"
  link="$targetPath/$1"
  if [ -L "$link" ]; then
    unlink "$link"
  fi
  ln -s  "$sh" "$link"
}

# aliases
safeLink "aliases"

# environment variables
safeLink "env"