#!/usr/bin/env bash

PACKAGES=(zen-browser-bin firefox waterfox librewolf chromium google-chrome brave-bin)

require_pacman() {
  command -v pacman >/dev/null 2>&1 || { echo "pacman not found. This is for Arch Linux." >&2; exit 1; }
}

show_menu() {
  echo "Choose one browser to install (enter the number):"
  for i in "${!PACKAGES[@]}"; do
    printf "  %2d) %s\n" $((i+1)) "${PACKAGES[$i]}"
  done
  echo "  s) Skip"
}

main() {
  require_pacman
  show_menu
  read -rp "Selection: " choice

  if [[ "$choice" =~ ^[sS]$ ]]; then
    echo "Skipped."
    exit 0
  fi

  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    echo "Invalid selection." >&2
    exit 1
  fi

  idx=$((choice-1))
  if (( idx < 0 || idx >= ${#PACKAGES[@]} )); then
    echo "Selection out of range." >&2
    exit 1
  fi

  pkg="${PACKAGES[$idx]}"
  echo "Installing: $pkg"
  sudo pacman -Sy --noconfirm --needed "$pkg"
  echo "Done."
}


main "$@"
