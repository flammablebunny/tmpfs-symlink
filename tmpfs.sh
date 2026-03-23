#!/bin/bash
# MCSR TMPFS manager. Symlink worlds into RAM for faster resets - Can also fix terrain loading or TPS issues.
set -euo pipefail

# -- Script Variables. (reccomened to keep as default, feel free to edit) --
TMPFS_TARGET="/tmp"
TMPFS_SIZE="4g"
MC_DIR="/tmp/mc"
INSTANCE_DIR="$HOME/.local/share/PrismLauncher/instances"   # change if using a different launcher like MCSR Launcher
INSTANCES=()                                                # leave empty to pick interactively
PRACTICE_MAPS_DIR="$HOME/.config/speedrun/maps"             # where all you practice maps will be symlinked to. change this dir to wherever you are going to store your practice maps.
PRACTICE_MAPS=()                                            # leave empty to pick interactively
ADW_INTERVAL=300           # seconds between cleanup runs
ADW_IGNORE_PREFIX="Z"      # worlds starting with this are never deleted
SYSTEMD_SCOPE="system"     # "system" (needs root) or "user" (no root)
# -----------------

# ONLY EDIT THIS IF YOU PROPERLY UNDERSTAND HOW TMPFS WORKS. INCREASE IF WANTED, IT IS NOT RECCOMENED TO DECREASE THIS.

ADW_KEEP=1000                                               # worlds to keep (reccomened to do atleast 1000 or more)

# A.7.8.a) If SeedQueue is used and 5 previous world files must be sent, all world files generated after the run must also be submitted.


SCRIPTS="$HOME/.local/share/tmpfs-mc/scripts"

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
    echo -n "Select (e.g. 1-3, 5 or press ENTER for all): "
    read -r sel
    sel="${sel:-all}"

    if [ "$sel" = "all" ]; then
        PICKED=("${items[@]}")
        return 0
    fi

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
    if [ ! -d "$PRACTICE_MAPS_DIR" ]; then return 0; fi
    local found=()
    while IFS= read -r d; do
        found+=("$(basename "$d")")
    done < <(find "$PRACTICE_MAPS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
    if [ ${#found[@]} -eq 0 ]; then return 0; fi
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

# -- enable / disable --
cmd_enable() {
    local fstab_line="tmpfs ${TMPFS_TARGET} tmpfs defaults,size=${TMPFS_SIZE} 0 0"

    if ! grep -qF "tmpfs ${TMPFS_TARGET} tmpfs" /etc/fstab 2>/dev/null; then
        echo "Adding fstab entry for $TMPFS_TARGET ($TMPFS_SIZE)"
        sudo bash -c "printf '\\n# MCSR tmpfs\\n${fstab_line}\\n' >> /etc/fstab"
    fi

    if ! mountpoint -q "$TMPFS_TARGET" 2>/dev/null; then
        sudo mount -t tmpfs -o "size=${TMPFS_SIZE}" tmpfs "$TMPFS_TARGET"
        echo "Mounted tmpfs at $TMPFS_TARGET"
    fi

    mkdir -p "$MC_DIR"
    cmd_link
    echo "TMPFS enabled"
}

cmd_disable() {
    confirm "Unmount $TMPFS_TARGET and remove fstab entry? Data in tmpfs will be lost." || return 0

    if mountpoint -q "$TMPFS_TARGET" 2>/dev/null; then
        local ft; ft="$(df -T "$TMPFS_TARGET" | tail -1 | awk '{print $2}')"
        if [ "$ft" = "tmpfs" ]; then sudo umount "$TMPFS_TARGET"; fi
    fi

    if grep -qF "tmpfs ${TMPFS_TARGET} tmpfs" /etc/fstab 2>/dev/null; then
        local esc="${TMPFS_TARGET//\//\\/}"
        sudo bash -c "sed -i '/# MCSR tmpfs/d' /etc/fstab && sed -i '/tmpfs ${esc} tmpfs/d' /etc/fstab"
    fi
    echo "TMPFS disabled"
}

# -- link & unlink --
cmd_link() {
    detect_instances || return 1
    local idx=1
    for inst in "${INSTANCES[@]}"; do
        local mc="$MC_DIR/$idx" saves; saves="$(saves_path "$inst")"
        if [ ! -d "$INSTANCE_DIR/$inst" ]; then echo "Not found: $inst (skip)"; ((idx++)) || true; continue; fi
        mkdir -p "$mc"

        if [ -L "$saves" ]; then
            if [ "$(readlink "$saves")" = "$mc" ]; then ((idx++)) || true; continue; fi
            rm "$saves"
        elif [ -d "$saves" ]; then
            confirm "Delete existing saves in $saves?" || { ((idx++)) || true; continue; }
            rm -rf "$saves"
        else
            mkdir -p "$(dirname "$saves")"
        fi

        ln -s "$mc" "$saves"
        echo "$idx: $inst -> $mc"
        ((idx++)) || true
    done
    chown "$(logname 2>/dev/null || id -un)" -R "$MC_DIR" 2>/dev/null || true
    cmd_link_maps
}

cmd_unlink() {
    detect_instances || return 1
    for inst in "${INSTANCES[@]}"; do
        local saves; saves="$(saves_path "$inst")"
        if [ -L "$saves" ]; then rm "$saves"; mkdir -p "$saves"; echo "Restored: $inst"; fi
    done
}

cmd_link_maps() {
    detect_maps || return 0
    if [ ${#PRACTICE_MAPS[@]} -eq 0 ]; then return 0; fi
    prefix_maps
    local count=${#INSTANCES[@]}
    for ((k=1; k<=count; k++)); do
        mkdir -p "$MC_DIR/$k"
        for map in "${PRACTICE_MAPS[@]}"; do
            if [ ! -e "$PRACTICE_MAPS_DIR/$map" ]; then echo "Map not found: $map"; continue; fi
            ln -sf "$PRACTICE_MAPS_DIR/$map" "$MC_DIR/$k/"
        done
    done
    echo "Practice maps linked"
}

cmd_unlink_maps() {
    detect_maps || return 0
    local count=${#INSTANCES[@]}
    for ((k=1; k<=count; k++)); do
        for map in "${PRACTICE_MAPS[@]}"; do
            if [ -L "$MC_DIR/$k/$map" ]; then rm "$MC_DIR/$k/$map"; fi
        done
    done
    echo "Practice maps unlinked"
}

# -- ADW --
cmd_adw_install() {
    detect_instances || return 1
    local count=${#INSTANCES[@]}
    mkdir -p "$SCRIPTS"

    cat > "$SCRIPTS/adw-cleanup.sh" << SCRIPT
#!/bin/bash
set -euo pipefail
for i in \$(seq 1 $count); do
    D="$MC_DIR/\$i"; [ -d "\$D" ] || continue
    while IFS= read -r s; do rm -rf "\$D/\$s"
    done < <(ls "\$D" -t1 2>/dev/null | grep -v "^$ADW_IGNORE_PREFIX" | tail -n "+$((ADW_KEEP + 1))")
done
SCRIPT
    chmod +x "$SCRIPTS/adw-cleanup.sh"

    local svc="[Unit]
Description=MCSR ADW cleanup
[Service]
Type=oneshot
ExecStart=$SCRIPTS/adw-cleanup.sh"

    local tmr="[Unit]
Description=MCSR ADW timer
[Timer]
OnBootSec=30s
OnUnitActiveSec=${ADW_INTERVAL}s
AccuracySec=5s
[Install]
WantedBy=timers.target"

    if [ "$SYSTEMD_SCOPE" = "user" ]; then
        mkdir -p "$HOME/.config/systemd/user"
        echo "$svc" > "$HOME/.config/systemd/user/mc-tmpfs-adw.service"
        echo "$tmr" > "$HOME/.config/systemd/user/mc-tmpfs-adw.timer"
        systemctl --user daemon-reload
        systemctl --user enable --now mc-tmpfs-adw.timer
    else
        local u; u="$(logname 2>/dev/null || id -un)"
        svc="[Unit]
Description=MCSR ADW cleanup
[Service]
Type=oneshot
User=$u
ExecStart=$SCRIPTS/adw-cleanup.sh"
        local ts tt; ts="$(mktemp)"; tt="$(mktemp)"
        echo "$svc" > "$ts"; echo "$tmr" > "$tt"
        sudo bash -c "cp '$ts' /etc/systemd/system/mc-tmpfs-adw.service && cp '$tt' /etc/systemd/system/mc-tmpfs-adw.timer && rm '$ts' '$tt' && systemctl daemon-reload && systemctl enable --now mc-tmpfs-adw.timer"
    fi
    echo "ADW timer installed (every ${ADW_INTERVAL}s, keep $ADW_KEEP, ignore ${ADW_IGNORE_PREFIX}*)"
}

cmd_adw_remove() {
    if [ "$SYSTEMD_SCOPE" = "user" ]; then
        systemctl --user disable --now mc-tmpfs-adw.timer 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user"/mc-tmpfs-adw.{service,timer}
        systemctl --user daemon-reload
    else
        sudo bash -c "systemctl disable --now mc-tmpfs-adw.timer 2>/dev/null; rm -f /etc/systemd/system/mc-tmpfs-adw.{service,timer}; systemctl daemon-reload" || true
    fi
    echo "ADW timer removed"
}

cmd_adw_run() {
    if [ ! -x "$SCRIPTS/adw-cleanup.sh" ]; then echo "Run adw-install first"; return 1; fi
    bash "$SCRIPTS/adw-cleanup.sh"
    echo "Cleanup done"
}

# -- startup service --
cmd_service_install() {
    detect_instances || return 1
    detect_maps || true
    local count=${#INSTANCES[@]}
    mkdir -p "$SCRIPTS"

    local u; u="$(logname 2>/dev/null || id -un)"
    {
        echo '#!/bin/bash'
        echo 'set -e'
        echo "for k in \$(seq 1 $count); do"
        echo "  mkdir -p \"$MC_DIR/\$k\""
        for map in "${PRACTICE_MAPS[@]}"; do
            echo "  ln -sf \"$PRACTICE_MAPS_DIR/$map\" \"$MC_DIR/\$k/\""
        done
        echo "done"
        echo "chown $u -R \"$MC_DIR\" 2>/dev/null || true"
    } > "$SCRIPTS/mc-startup.sh"
    chmod +x "$SCRIPTS/mc-startup.sh"

    if [ "$SYSTEMD_SCOPE" = "user" ]; then
        mkdir -p "$HOME/.config/systemd/user"
        cat > "$HOME/.config/systemd/user/mc-tmpfs-startup.service" << EOF
[Unit]
Description=MCSR TMPFS startup
After=local-fs.target
[Service]
Type=oneshot
ExecStart=$SCRIPTS/mc-startup.sh
RemainAfterExit=yes
[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now mc-tmpfs-startup.service
    else
        local svc="[Unit]
Description=MCSR TMPFS startup
After=multi-user.target
[Service]
Type=oneshot
User=$u
ExecStart=$SCRIPTS/mc-startup.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target"
        local ts; ts="$(mktemp)"; echo "$svc" > "$ts"
        sudo bash -c "cp '$ts' /etc/systemd/system/mc-tmpfs-startup.service && rm '$ts' && systemctl daemon-reload && systemctl enable --now mc-tmpfs-startup.service"
    fi
    echo "Startup service installed"
}

cmd_service_remove() {
    if [ "$SYSTEMD_SCOPE" = "user" ]; then
        systemctl --user disable --now mc-tmpfs-startup.service 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/mc-tmpfs-startup.service"
        systemctl --user daemon-reload
    else
        sudo bash -c "systemctl disable --now mc-tmpfs-startup.service 2>/dev/null; rm -f /etc/systemd/system/mc-tmpfs-startup.service; systemctl daemon-reload" || true
    fi
    echo "Startup service removed"
}

# -- status --
cmd_status() {
    # Auto-detect all instances without prompting
    if [ ${#INSTANCES[@]} -eq 0 ] && [ -d "$INSTANCE_DIR" ]; then
        while IFS= read -r d; do
            INSTANCES+=("$(basename "$d")")
        done < <(find "$INSTANCE_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
    fi

    echo "=== TMPFS ==="
    if mountpoint -q "$TMPFS_TARGET" 2>/dev/null; then
        local ft used total
        ft="$(df -T "$TMPFS_TARGET" | tail -1 | awk '{print $2}')"
        used="$(df -h "$TMPFS_TARGET" | tail -1 | awk '{print $3}')"
        total="$(df -h "$TMPFS_TARGET" | tail -1 | awk '{print $2}')"
        echo "  $TMPFS_TARGET: $ft ($used/$total used)"
    else
        echo "  $TMPFS_TARGET: not mounted"
    fi
    if grep -qF "tmpfs ${TMPFS_TARGET} tmpfs" /etc/fstab 2>/dev/null; then
        echo "  fstab: yes"
    else
        echo "  fstab: no"
    fi
    echo "  MC dir: $MC_DIR"

    echo "=== Instances (${#INSTANCES[@]}) ==="
    local idx=1
    for inst in "${INSTANCES[@]}"; do
        local saves; saves="$(saves_path "$inst")"
        if [ -L "$saves" ]; then
            local t wc=0; t="$(readlink "$saves")"
            if [ -d "$t" ]; then wc="$(find "$t" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)"; fi
            echo "  $idx. $inst -> $t ($wc worlds)"
        else
            echo "  $idx. $inst (not linked)"
        fi
        ((idx++)) || true
    done

    echo "=== Practice maps (${#PRACTICE_MAPS[@]}) ==="
    for map in "${PRACTICE_MAPS[@]}"; do
        if [ -e "$PRACTICE_MAPS_DIR/$map" ]; then echo "  $map"; else echo "  $map (not found)"; fi
    done

    echo "=== Services ==="
    local sf=""
    if [ "$SYSTEMD_SCOPE" = "user" ]; then sf="--user"; fi
    if systemctl $sf is-active mc-tmpfs-adw.timer &>/dev/null; then
        echo "  ADW: active (${ADW_INTERVAL}s, keep $ADW_KEEP)"
    else
        echo "  ADW: inactive"
    fi
    if systemctl $sf is-enabled mc-tmpfs-startup.service &>/dev/null; then
        echo "  Startup: enabled"
    else
        echo "  Startup: not installed"
    fi
}

# -- composite --
cmd_setup() {
    confirm "Enable tmpfs, link instances, install ADW + startup service?" || return 0
    cmd_enable; cmd_adw_install; cmd_service_install
    echo ""; cmd_status
}

cmd_teardown() {
    confirm "Remove everything (unlink, remove services, disable tmpfs)?" || return 0
    cmd_adw_remove; cmd_service_remove; cmd_unlink 2>/dev/null || true; cmd_disable
}

# -- main --
usage() {
    cat << EOF
tmpfs.sh - MCSR TMPFS manager

Usage: $0 <command>

  setup / teardown    Full setup or full teardown
  enable / disable    Mount/unmount tmpfs, manage fstab
  link / unlink       Symlink/restore instance saves dirs
  link-maps           Link practice maps into tmpfs dirs
  unlink-maps         Remove practice map symlinks
  adw-install         Install systemd world cleanup timer
  adw-remove          Remove cleanup timer
  adw-run             Run cleanup once now
  service-install     Install boot-time dir creation service
  service-remove      Remove startup service
  status              Show current state

Instances and maps are picked interactively, or set them at the top of this script.
EOF
}

case "${1:-}" in
    enable)          cmd_enable ;;
    disable)         cmd_disable ;;
    link)            cmd_link ;;
    unlink)          cmd_unlink ;;
    link-maps)       cmd_link_maps ;;
    unlink-maps)     cmd_unlink_maps ;;
    adw-install)     cmd_adw_install ;;
    adw-remove)      cmd_adw_remove ;;
    adw-run)         cmd_adw_run ;;
    service-install) cmd_service_install ;;
    service-remove)  cmd_service_remove ;;
    status)          cmd_status ;;
    setup)           cmd_setup ;;
    teardown)        cmd_teardown ;;
    help|--help|-h)  usage ;;
    *)               usage; exit 1 ;;
esac
