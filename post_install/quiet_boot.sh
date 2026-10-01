#!/usr/bin/env bash
set -euo pipefail

#
# Arch Linux boot configuration helper
#
# Does the following:
#   1. Adds:
#        quiet
#        loglevel=3
#        systemd.show_status=auto
#        rd.udev.log_level=3
#        vt.global_cursor_default=0
#   2. Removes "fsck" from mkinitcpio HOOKS
#   3. Rebuilds initramfs
#   4. Detects the bootloader used by the installed system
#   5. Updates its kernel command line
#
# Supported Archinstall bootloaders:
#   - systemd-boot
#   - GRUB
#   - EFISTUB
#   - Limine
#   - rEFInd
#

KERNEL_PARAMS=(
    quiet
    loglevel=3
    systemd.show_status=auto
    rd.udev.log_level=3
    vt.global_cursor_default=0
)

MKINITCPIO_CONFIG="/etc/mkinitcpio.conf"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

backup() {
    local file="$1"

    [[ -f "$file" ]] || return 0

    local backup="${file}.bak"

    if [[ -e "$backup" ]]; then
        backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
    fi

    cp -a -- "$file" "$backup"
    echo "    Backup: $backup"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ----------------------------------------------------------------------
# Root / platform checks
# ----------------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "Run this script as root."

if [[ ! -d /sys/firmware/efi ]]; then
    UEFI=0
else
    UEFI=1
fi

# ----------------------------------------------------------------------
# Kernel parameter helper
# ----------------------------------------------------------------------

append_params() {
    local current="$1"
    local param
    local key
    local found

    for param in "${KERNEL_PARAMS[@]}"; do
        key="${param%%=*}"
        found=0

        # Remove an existing instance of the same parameter key.
        read -ra words <<< "$current"

        local new_words=()
        local word

        for word in "${words[@]}"; do
            if [[ "${word%%=*}" == "$key" ]]; then
                continue
            fi

            new_words+=("$word")
        done

        new_words+=("$param")

        current="${new_words[*]}"
    done

    printf '%s\n' "$current"
}

# ----------------------------------------------------------------------
# Detect actual bootloader
# ----------------------------------------------------------------------

detect_bootloader() {
    local detected=()

    #
    # GRUB
    #
    if [[ -f /etc/default/grub ]] ||
       [[ -f /boot/grub/grub.cfg ]] ||
       [[ -f /boot/grub/i386-pc/core.img ]] ||
       [[ -f /boot/grub/x86_64-efi/grubx64.efi ]]; then
        detected+=("grub")
    fi

    #
    # systemd-boot
    #
    if command_exists bootctl &&
       bootctl is-installed >/dev/null 2>&1; then
        detected+=("systemd-boot")
    elif [[ -d /boot/loader ]] ||
         [[ -d /efi/loader ]] ||
         [[ -d /boot/EFI/BOOT ]] && [[ -f /boot/loader/loader.conf ]]; then
        detected+=("systemd-boot")
    fi

    #
    # Limine
    #
    if [[ -f /boot/limine/limine.conf ]] ||
       [[ -f /boot/limine/limine-bios.sys ]]; then
        detected+=("limine")
    fi

    # Archinstall's normal UEFI Limine location.
    if [[ -f /efi/EFI/arch-limine/limine.conf ]] ||
       [[ -f /boot/EFI/arch-limine/limine.conf ]] ||
       [[ -f /boot/EFI/BOOT/limine.conf ]]; then
        detected+=("limine")
    fi

    #
    # rEFInd
    #
    if [[ -f /boot/refind_linux.conf ]] ||
       [[ -f /boot/EFI/refind/refind.conf ]] ||
       [[ -f /efi/EFI/refind/refind.conf ]] ||
       [[ -f /boot/EFI/BOOT/refind.conf ]]; then
        detected+=("refind")
    fi

    #
    # EFISTUB
    #
    # EFISTUB has no configuration file. Detect it from the UEFI NVRAM
    # entries using efibootmgr.
    #
    if (( UEFI )) && command_exists efibootmgr; then
        if efibootmgr 2>/dev/null |
            grep -Eqi 'Arch Linux \(.*\).*File\(.*(vmlinuz|EFI/Linux/arch-).*'; then
            detected+=("efistub")
        fi
    fi

    # Remove duplicates.
    printf '%s\n' "${detected[@]}" |
        sort -u
}

mapfile -t BOOTLOADERS < <(detect_bootloader)

if (( ${#BOOTLOADERS[@]} == 0 )); then
    die "Could not detect an Archinstall-supported bootloader."
fi

if (( ${#BOOTLOADERS[@]} > 1 )); then
    echo
    echo "Multiple bootloaders/configurations were detected:"
    printf '  - %s\n' "${BOOTLOADERS[@]}"
    echo

    # Prefer an explicitly identifiable EFI boot entry if there is one.
    if printf '%s\n' "${BOOTLOADERS[@]}" | grep -qx "efistub"; then
        BOOTLOADER="efistub"
    elif printf '%s\n' "${BOOTLOADERS[@]}" | grep -qx "systemd-boot"; then
        BOOTLOADER="systemd-boot"
    elif printf '%s\n' "${BOOTLOADERS[@]}" | grep -qx "grub"; then
        BOOTLOADER="grub"
    elif printf '%s\n' "${BOOTLOADERS[@]}" | grep -qx "limine"; then
        BOOTLOADER="limine"
    else
        BOOTLOADER="refind"
    fi

    echo "Using: $BOOTLOADER"
else
    BOOTLOADER="${BOOTLOADERS[0]}"
fi

# ----------------------------------------------------------------------
# GRUB
# ----------------------------------------------------------------------

configure_grub() {
    local config="/etc/default/grub"

    [[ -f "$config" ]] ||
        die "GRUB detected but $config does not exist."

    info "Configuring GRUB"

    backup "$config"

    python - "$config" "${KERNEL_PARAMS[*]}" <<'PY'
import re
import sys

path = sys.argv[1]
params = sys.argv[2].split()

data = open(path).read()

m = re.search(
    r'^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"$',
    data,
    re.MULTILINE
)

if not m:
    raise SystemExit(
        "GRUB_CMDLINE_LINUX_DEFAULT was not found."
    )

current = m.group(1).split()

for param in params:
    key = param.split("=", 1)[0]

    current = [
        x for x in current
        if x.split("=", 1)[0] != key
    ]

    current.append(param)

replacement = (
    'GRUB_CMDLINE_LINUX_DEFAULT="'
    + " ".join(current)
    + '"'
)

data = re.sub(
    r'^GRUB_CMDLINE_LINUX_DEFAULT="[^"]*"$',
    replacement,
    data,
    count=1,
    flags=re.MULTILINE
)

open(path, "w").write(data)
PY

    info "Regenerating GRUB configuration"

    grub-mkconfig -o /boot/grub/grub.cfg
}

# ----------------------------------------------------------------------
# systemd-boot
# ----------------------------------------------------------------------

configure_systemd_boot() {
    local entries_dir=""

    if [[ -d /boot/loader/entries ]]; then
        entries_dir="/boot/loader/entries"
    elif [[ -d /efi/loader/entries ]]; then
        entries_dir="/efi/loader/entries"
    else
        die "systemd-boot detected but no loader/entries directory found."
    fi

    info "Configuring systemd-boot"

    local file

    shopt -s nullglob

    local entries=("$entries_dir"/*.conf)

    if (( ${#entries[@]} == 0 )); then
        die "No systemd-boot BLS entries found."
    fi

    for file in "${entries[@]}"; do
        backup "$file"

        python - "$file" "${KERNEL_PARAMS[*]}" <<'PY'
import re
import sys

path = sys.argv[1]
params = sys.argv[2].split()

data = open(path).read()

m = re.search(
    r'^options\s+(.+)$',
    data,
    re.MULTILINE
)

if not m:
    current = []
else:
    current = m.group(1).split()

for param in params:
    key = param.split("=", 1)[0]

    current = [
        x for x in current
        if x.split("=", 1)[0] != key
    ]

    current.append(param)

line = "options " + " ".join(current)

if m:
    data = re.sub(
        r'^options\s+.+$',
        line,
        data,
        count=1,
        flags=re.MULTILINE
    )
else:
    data = data.rstrip() + "\n" + line + "\n"

open(path, "w").write(data)
PY

        echo "    Updated: $file"
    done
}

# ----------------------------------------------------------------------
# Limine
# ----------------------------------------------------------------------

configure_limine() {
    local config=""

    #
    # Match Archinstall's current locations.
    #
    for candidate in \
        /boot/limine/limine.conf \
        /efi/EFI/arch-limine/limine.conf \
        /boot/EFI/arch-limine/limine.conf \
        /boot/EFI/BOOT/limine.conf
    do
        if [[ -f "$candidate" ]]; then
            config="$candidate"
            break
        fi
    done

    [[ -n "$config" ]] ||
        die "Limine detected but its configuration could not be found."

    info "Configuring Limine: $config"

    backup "$config"

    python - "$config" "${KERNEL_PARAMS[*]}" <<'PY'
import re
import sys

path = sys.argv[1]
params = sys.argv[2].split()

data = open(path).read()

lines = data.splitlines()

found = False

for i, line in enumerate(lines):
    if re.match(r'^\s*cmdline:', line):
        prefix, value = line.split(":", 1)
        current = value.strip().split()

        for param in params:
            key = param.split("=", 1)[0]

            current = [
                x for x in current
                if x.split("=", 1)[0] != key
            ]

            current.append(param)

        indent = re.match(r'^\s*', line).group()

        lines[i] = (
            indent +
            "cmdline: " +
            " ".join(current)
        )

        found = True

if not found:
    raise SystemExit(
        "No cmdline: entries found in Limine configuration."
    )

open(path, "w").write("\n".join(lines) + "\n")
PY
}

# ----------------------------------------------------------------------
# rEFInd
# ----------------------------------------------------------------------

configure_refind() {
    local config=""

    #
    # Archinstall's rEFInd configuration is normally here:
    #
    #   /boot/refind_linux.conf
    #
    # If /boot is a separate filesystem, it may instead live there
    # through the mounted boot partition.
    #
    for candidate in \
        /boot/refind_linux.conf \
        /efi/refind_linux.conf \
        /boot/EFI/refind/refind_linux.conf
    do
        if [[ -f "$candidate" ]]; then
            config="$candidate"
            break
        fi
    done

    [[ -n "$config" ]] ||
        die "rEFInd detected but refind_linux.conf was not found."

    info "Configuring rEFInd: $config"

    backup "$config"

    python - "$config" "${KERNEL_PARAMS[*]}" <<'PY'
import re
import sys

path = sys.argv[1]
params = sys.argv[2].split()

lines = open(path).read().splitlines()

output = []

for line in lines:
    m = re.match(
        r'^(\s*"[^"]*"\s+")([^"]*)("\s*)$',
        line
    )

    if not m:
        output.append(line)
        continue

    prefix = m.group(1)
    current = m.group(2).split()
    suffix = m.group(3)

    # Preserve initrd= and other rEFInd-specific arguments,
    # while replacing only the parameters we own.
    for param in params:
        key = param.split("=", 1)[0]

        current = [
            x for x in current
            if x.split("=", 1)[0] != key
        ]

        current.append(param)

    output.append(
        prefix +
        " ".join(current) +
        suffix
    )

open(path, "w").write("\n".join(output) + "\n")
PY
}

# ----------------------------------------------------------------------
# EFISTUB
# ----------------------------------------------------------------------

configure_efistub() {
    (( UEFI )) ||
        die "EFISTUB requires UEFI."

    command_exists efibootmgr ||
        die "efibootmgr is required for EFISTUB."

    info "Configuring EFISTUB UEFI entries"

    local efivars

    efivars="$(efibootmgr 2>/dev/null)" ||
        die "Could not read UEFI boot entries with efibootmgr."

    #
    # We deliberately operate on Arch Linux entries rather than every
    # UEFI entry on the machine.
    #
    while IFS= read -r line; do
        [[ "$line" =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]]+Arch\ Linux ]] ||
            continue

        local bootnum="${BASH_REMATCH[1]}"

        local current
        current="$(efibootmgr -v |
            awk -v n="$bootnum" '
                $1 ~ "^Boot" n {
                    sub(/^[^[:space:]]+[[:space:]]+/, "")
                    print
                }
            ')"

        [[ -n "$current" ]] || continue

        #
        # Extract the existing kernel command line from the EFI entry.
        # efibootmgr prints it after the loader path.
        #
        local cmdline
        cmdline="$(
            printf '%s\n' "$current" |
            sed -E 's/.*File\(.*\)[[:space:]]*//'
        )"

        [[ -n "$cmdline" ]] || {
            echo "    Skipping Boot$bootnum: no command line detected."
            continue
        }

        local new_cmdline
        new_cmdline="$(append_params "$cmdline")"

        echo "    Updating Boot$bootnum"

        #
        # Recreate the entry with the same disk/partition/loader is
        # complicated and varies by firmware. Instead, use efibootmgr's
        # -u/-b modification capability where supported.
        #
        efibootmgr \
            --bootnum "$bootnum" \
            --unicode "$new_cmdline"
    done <<< "$efivars"
}

# ----------------------------------------------------------------------
# mkinitcpio
# ----------------------------------------------------------------------

configure_mkinitcpio() {
    [[ -f "$MKINITCPIO_CONFIG" ]] ||
        die "$MKINITCPIO_CONFIG not found."

    info "Removing fsck from mkinitcpio HOOKS"

    backup "$MKINITCPIO_CONFIG"

    python - "$MKINITCPIO_CONFIG" <<'PY'
import re
import sys

path = sys.argv[1]

data = open(path).read()

m = re.search(
    r'^HOOKS=\(([^)]*)\)',
    data,
    re.MULTILINE
)

if not m:
    raise SystemExit("HOOKS array not found.")

hooks = m.group(1).split()

hooks = [
    hook for hook in hooks
    if hook != "fsck"
]

replacement = "HOOKS=(" + " ".join(hooks) + ")"

data = re.sub(
    r'^HOOKS=\([^)]*\)',
    replacement,
    data,
    count=1,
    flags=re.MULTILINE
)

open(path, "w").write(data)
PY
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

echo
echo "Detected bootloader: $BOOTLOADER"
echo

case "$BOOTLOADER" in
    grub)
        configure_grub
        ;;

    systemd-boot)
        configure_systemd_boot
        ;;

    limine)
        configure_limine
        ;;

    refind)
        configure_refind
        ;;

    efistub)
        configure_efistub
        ;;

    *)
        die "Unsupported bootloader: $BOOTLOADER"
        ;;
esac

echo

configure_mkinitcpio

echo
info "Rebuilding initramfs"

mkinitcpio -P

echo
echo "============================================"
echo "Boot configuration completed successfully."
echo "============================================"
echo
echo "Bootloader: $BOOTLOADER"
echo
echo "Kernel parameters:"
printf '  %s\n' "${KERNEL_PARAMS[@]}"
echo
echo "mkinitcpio:"
grep '^HOOKS=' "$MKINITCPIO_CONFIG"
echo

