#!/bin/bash
# Symlink practice maps into PrismLauncher instance saves folders.
set -euo pipefail

# -- Edit these if needed --
INSTANCE_DIR="$HOME/.local/share/PrismLauncher/instances"
PRACTICE_MAPS_DIR="$HOME/.config/speedrun/maps"
INSTANCES=()               # leave empty to pick interactively
PRACTICE_MAPS=()           # leave empty to pick interactively
# ---------------------------


confirm() { echo -n "$1 [y/N] "; read -r a; [[ "$a" =~ ^[Yy]$ ]]; }

saves_path() {
    local base="$INSTANCE_DIR/$1"
    if [ -d "$base/.minecraft/saves" ] || [ -L "$base/.minecraft/saves" ]; then
        echo "$base/.minecraft/saves"
    else
        echo "$base/minecraft/saves"
    fi
}

# Parse selection like "1-3, 5, 7" into indices
# Usage: pick "header" array_of_items -> selected items in PICKED
PICKED=()
pick() {
    local header="$1"; shift
    local items=("$@")
    PICKED=()

    if [ ${#items[@]} -eq 0 ]; then echo "Nothing found."; return 1; fi

    echo "$header"
    for ((i=0; i<${#items[@]}; i++)); do
        echo "  $((i+1)). ${items[$i]}"
    done
    echo -n "Select (e.g. 1-3, 5 or 'all') [all]: "
    read -r sel
    sel="${sel:-all}"

    if [ "$sel" = "all" ]; then
        PICKED=("${items[@]}")
        return 0
    fi

    # Parse comma-separated, each can be a range
    IFS=',' read -ra parts <<< "$sel"
    for part in "${parts[@]}"; do
        part="$(echo "$part" | tr -d ' ')"
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for ((n=${BASH_REMATCH[1]}; n<=${BASH_REMATCH[2]}; n++)); do
                if [ "$n" -ge 1 ] && [ "$n" -le ${#items[@]} ]; then
                    PICKED+=("${items[$((n-1))]}")
                fi
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            if [ "$part" -ge 1 ] && [ "$part" -le ${#items[@]} ]; then
                PICKED+=("${items[$((part-1))]}")
            fi
        fi
    done
    if [ ${#PICKED[@]} -eq 0 ]; then echo "No valid selection."; return 1; fi
}

detect_instances() {
    if [ ${#INSTANCES[@]} -gt 0 ]; then return 0; fi
    local found=()
    while IFS= read -r d; do
        found+=("$(basename "$d")")
    done < <(find "$INSTANCE_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
    pick "Instances:" "${found[@]}" || return 1
    INSTANCES=("${PICKED[@]}")
}

detect_maps() {
    if [ ${#PRACTICE_MAPS[@]} -gt 0 ]; then return 0; fi
    if [ ! -d "$PRACTICE_MAPS_DIR" ]; then echo "Maps directory not found: $PRACTICE_MAPS_DIR"; return 1; fi
    local found=()
    while IFS= read -r d; do
        found+=("$(basename "$d")")
    done < <(find "$PRACTICE_MAPS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
    pick "Practice maps:" "${found[@]}" || return 1
    PRACTICE_MAPS=("${PICKED[@]}")
}

prefix_maps() {
    if [ ! -d "$PRACTICE_MAPS_DIR" ]; then return 0; fi
    for ((i=0; i<${#PRACTICE_MAPS[@]}; i++)); do
        local map="${PRACTICE_MAPS[$i]}"
        if [[ "$map" != Z* ]] && [ -e "$PRACTICE_MAPS_DIR/$map" ]; then
            local new="Z_$map"
            mv "$PRACTICE_MAPS_DIR/$map" "$PRACTICE_MAPS_DIR/$new"
            PRACTICE_MAPS[$i]="$new"
            echo "Renamed: $map -> $new"
        fi
    done
}

cmd_link() {
    detect_instances || return 1
    detect_maps || return 1
    prefix_maps

    for inst in "${INSTANCES[@]}"; do
        if [ ! -d "$INSTANCE_DIR/$inst" ]; then echo "Instance not found: $inst (skip)"; continue; fi
        local saves; saves="$(saves_path "$inst")"
        mkdir -p "$saves"

        for map in "${PRACTICE_MAPS[@]}"; do
            if [ ! -e "$PRACTICE_MAPS_DIR/$map" ]; then continue; fi
            ln -sf "$PRACTICE_MAPS_DIR/$map" "$saves/"
        done
        echo "$inst: linked ${#PRACTICE_MAPS[@]} map(s)"
    done
}

cmd_unlink() {
    detect_instances || return 1
    detect_maps || return 1

    for inst in "${INSTANCES[@]}"; do
        local saves; saves="$(saves_path "$inst")"
        for map in "${PRACTICE_MAPS[@]}"; do
            if [ -L "$saves/$map" ]; then rm "$saves/$map"; fi
        done
        echo "$inst: unlinked"
    done
}

cmd_status() {
    detect_instances || return 1
    detect_maps || return 1

    echo "Maps dir: $PRACTICE_MAPS_DIR"
    echo "Maps (${#PRACTICE_MAPS[@]}):"
    for map in "${PRACTICE_MAPS[@]}"; do
        if [ -e "$PRACTICE_MAPS_DIR/$map" ]; then echo "  $map"; else echo "  $map (not found)"; fi
    done
    echo "Instances (${#INSTANCES[@]}):"
    for inst in "${INSTANCES[@]}"; do
        local saves; saves="$(saves_path "$inst")"
        local linked=0
        for map in "${PRACTICE_MAPS[@]}"; do
            if [ -L "$saves/$map" ]; then ((linked++)) || true; fi
        done
        echo "  $inst: $linked/${#PRACTICE_MAPS[@]} maps linked"
    done
}

usage() {
    cat << EOF
symlink.sh — Symlink practice maps into instance saves folders

Usage: $0 <command>

  link      Symlink practice maps into each instance's saves/
  unlink    Remove practice map symlinks
  status    Show current state

Instances and maps are picked interactively, or set them at the top of this script.
EOF
}

case "${1:-}" in
    link)           cmd_link ;;
    unlink)         cmd_unlink ;;
    status)         cmd_status ;;
    help|--help|-h) usage ;;
    *)              usage; exit 1 ;;
esac
