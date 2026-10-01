#!/usr/bin/env bash
#
# Arch Linux boot configuration
#
# Adds:
#   quiet
#   loglevel=3
#   systemd.show_status=auto
#   rd.udev.log_level=3
#   vt.global_cursor_default=0
#
# Removes:
#   fsck
#
# from mkinitcpio HOOKS, then rebuilds initramfs.
#
# Supports the bootloader configurations used by Archinstall:
#   - systemd-boot
#   - GRUB
#   - EFISTUB
#   - Limine
#   - rEFInd
#
# Also handles Archinstall UKI installations.
#

set -Eeuo pipefail

readonly PARAMS=(
    "quiet"
    "loglevel=3"
    "systemd.show_status=auto"
    "rd.udev.log_level=3"
    "vt.global_cursor_default=0"
)

readonly MKINITCPIO_CONF="/etc/mkinitcpio.conf"
readonly CMDLINE_CONF="/etc/kernel/cmdline"

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

info()
{
    printf '\n==> %s\n' "$*"
}

backup()
{
    local file="$1"

    [[ -f "$file" ]] || return 0

    local backup="${file}.bak"

    if [[ -e "$backup" ]]; then
        backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
    fi

    cp -a -- "$file" "$backup"

    echo "    Backup: $backup"
}

require_root()
{
    (( EUID == 0 )) ||
        die "Run this script as root, e.g. sudo $0"
}

require_file()
{
    [[ -f "$1" ]] ||
        die "Required file does not exist: $1"
}

command_exists()
{
    command -v "$1" >/dev/null 2>&1
}

# ----------------------------------------------------------------------
# Add/replace our parameters in an existing command line.
#
# Parameters with the same key are replaced:
#
#   loglevel=4 -> loglevel=3
#
# Parameters without '=' are treated as flags:
#
#   quiet
#
# ----------------------------------------------------------------------

update_cmdline()
{
    local current="$1"
    local param key word
    local result=()

    read -r -a words <<< "$current"

    for word in "${words[@]}"; do
        result+=("$word")
    done

    for param in "${PARAMS[@]}"; do
        key="${param%%=*}"

        local new_result=()

        for word in "${result[@]}"; do
            if [[ "${word%%=*}" == "$key" ]]; then
                continue
            fi

            new_result+=("$word")
        done

        new_result+=("$param")
        result=("${new_result[@]}")
    done

    printf '%s\n' "${result[*]}"
}

# ----------------------------------------------------------------------
# Determine whether the system has UKI configuration.
#
# Archinstall writes /etc/kernel/cmdline when configuring UKIs.
# The actual UKIs are normally under /efi/EFI/Linux or /boot/EFI/Linux.
# ----------------------------------------------------------------------

has_uki()
{
    [[ -f "$CMDLINE_CONF" ]] &&
    {
        compgen -G "/efi/EFI/Linux/*.efi" >/dev/null ||
        compgen -G "/boot/EFI/Linux/*.efi" >/dev/null
    }
}

# ----------------------------------------------------------------------
# Find systemd-boot BLS directory.
# ----------------------------------------------------------------------

find_systemd_boot_entries()
{
    if [[ -d /boot/loader/entries ]]; then
        printf '%s\n' /boot/loader/entries
        return 0
    fi

    if [[ -d /efi/loader/entries ]]; then
        printf '%s\n' /efi/loader/entries
        return 0
    fi

    return 1
}

# ----------------------------------------------------------------------
# Find Limine configuration.
#
# Archinstall:
#
# UEFI:
#   ESP/EFI/arch-limine/limine.conf
#
# BIOS:
#   /boot/limine/limine.conf
#
# Removable Limine installations use EFI/BOOT instead.
# ----------------------------------------------------------------------

find_limine_config()
{
    local file

    for file in \
        /boot/limine/limine.conf \
        /efi/EFI/arch-limine/limine.conf \
        /boot/EFI/arch-limine/limine.conf \
        /efi/EFI/BOOT/limine.conf \
        /boot/EFI/BOOT/limine.conf
    do
        if [[ -f "$file" ]]; then
            printf '%s\n' "$file"
            return 0
        fi
    done

    return 1
}

# ----------------------------------------------------------------------
# Find rEFInd's Arch Linux kernel configuration.
# ----------------------------------------------------------------------

find_refind_config()
{
    local file

    for file in \
        /boot/refind_linux.conf \
        /efi/refind_linux.conf
    do
        if [[ -f "$file" ]]; then
            printf '%s\n' "$file"
            return 0
        fi
    done

    return 1
}

# ----------------------------------------------------------------------
# Detect bootloader.
#
# We deliberately do not assume that merely having a bootloader package
# installed means that bootloader is being used.
# ----------------------------------------------------------------------

detect_bootloader()
{
    # systemd-boot is the easiest to identify reliably.
    if command_exists bootctl &&
       bootctl is-installed >/dev/null 2>&1; then
        echo "systemd-boot"
        return
    fi

    if find_systemd_boot_entries >/dev/null 2>&1 &&
       [[ -f /boot/loader/loader.conf ||
          -f /efi/loader/loader.conf ]]; then
        echo "systemd-boot"
        return
    fi

    # Look at the current EFI boot entry where possible.
    if [[ -d /sys/firmware/efi ]] &&
       command_exists efibootmgr; then

        local current
        current="$(efibootmgr 2>/dev/null | sed -n 's/^BootCurrent: //p')"

        if [[ -n "$current" ]]; then
            local entry

            entry="$(
                efibootmgr -v 2>/dev/null |
                grep -E "^Boot${current}\\*?" || true
            )"

            if grep -qi 'grub' <<< "$entry"; then
                echo "grub"
                return
            fi

            if grep -qi 'Limine' <<< "$entry"; then
                echo "limine"
                return
            fi

            if grep -qi 'rEFInd' <<< "$entry"; then
                echo "refind"
                return
            fi

            if grep -qi 'Arch Linux' <<< "$entry"; then
                # Archinstall EFISTUB entries are labelled:
                #   Arch Linux (linux)
                #
                # Do not classify the generic "Arch Linux Limine
                # Bootloader" entry as EFISTUB.
                if grep -q '\\EFI\\arch-limine\\' <<< "$entry"; then
                    echo "limine"
                    return
                fi

                if grep -q '\\EFI\\refind\\' <<< "$entry"; then
                    echo "refind"
                    return
                fi

                if grep -qE 'File\(\\vmlinuz-|File\(\\EFI\\Linux\\arch-' <<< "$entry"; then
                    echo "efistub"
                    return
                fi
            fi
        fi
    fi

    # Filesystem fallback.
    if [[ -f /etc/default/grub ]] &&
       [[ -f /boot/grub/grub.cfg ]]; then
        echo "grub"
        return
    fi

    if find_limine_config >/dev/null 2>&1; then
        echo "limine"
        return
    fi

    if find_refind_config >/dev/null 2>&1; then
        echo "refind"
        return
    fi

    # If /etc/kernel/cmdline exists but no bootloader could be
    # identified, this is commonly an EFI-stub/UKI setup.
    if [[ -f "$CMDLINE_CONF" ]]; then
        if [[ -d /sys/firmware/efi ]]; then
            echo "efistub"
            return
        fi
    fi

    return 1
}

# ----------------------------------------------------------------------
# Update /etc/kernel/cmdline
#
# This is the source of truth for Archinstall UKIs.
# ----------------------------------------------------------------------

configure_kernel_cmdline()
{
    info "Updating $CMDLINE_CONF"

    if [[ -f "$CMDLINE_CONF" ]]; then
        backup "$CMDLINE_CONF"

        local current
        current="$(<"$CMDLINE_CONF")"

        update_cmdline "$current" > "${CMDLINE_CONF}.new"
        mv "${CMDLINE_CONF}.new" "$CMDLINE_CONF"
    else
        mkdir -p "$(dirname "$CMDLINE_CONF")"

        printf '%s\n' "${PARAMS[*]}" > "$CMDLINE_CONF"

        echo "    Created $CMDLINE_CONF"
    fi
}

# ----------------------------------------------------------------------
# GRUB
#
# Archinstall currently writes kernel parameters to:
#
#   GRUB_CMDLINE_LINUX=""
#
# NOT GRUB_CMDLINE_LINUX_DEFAULT.
# ----------------------------------------------------------------------

configure_grub()
{
    local file="/etc/default/grub"

    require_file "$file"

    info "Configuring GRUB"

    backup "$file"

    python3 - "$file" "${PARAMS[*]}" <<'PY'
import re
import sys

path = sys.argv[1]
params = sys.argv[2].split()

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

match = re.search(
    r'^GRUB_CMDLINE_LINUX="([^"]*)"$',
    data,
    re.MULTILINE
)

if not match:
    raise SystemExit(
        "GRUB_CMDLINE_LINUX was not found in /etc/default/grub"
    )

current = match.group(1).split()

for param in params:
    key = param.split("=", 1)[0]

    current = [
        item for item in current
        if item.split("=", 1)[0] != key
    ]

    current.append(param)

replacement = (
    'GRUB_CMDLINE_LINUX="'
    + " ".join(current)
    + '"'
)

data = re.sub(
    r'^GRUB_CMDLINE_LINUX="[^"]*"$',
    replacement,
    data,
    count=1,
    flags=re.MULTILINE
)

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY

    info "Regenerating GRUB configuration"

    command_exists grub-mkconfig ||
        die "grub-mkconfig is not installed."

    grub-mkconfig -o /boot/grub/grub.cfg
}

# ----------------------------------------------------------------------
# systemd-boot
# ----------------------------------------------------------------------

configure_systemd_boot()
{
    local entries

    entries="$(find_systemd_boot_entries || true)"

    if [[ -z "$entries" ]]; then
        # UKI setup: Arch Wiki says /etc/kernel/cmdline is the source.
        if [[ -f "$CMDLINE_CONF" ]]; then
            configure_kernel_cmdline
            return
        fi

        die "Could not find systemd-boot loader entries."
    fi

    info "Configuring systemd-boot"

    shopt -s nullglob

    local files=("$entries"/*.conf)

    if (( ${#files[@]} == 0 )); then
        # No BLS entries generally means a UKI setup.
        if [[ -f "$CMDLINE_CONF" ]]; then
            configure_kernel_cmdline
            return
        fi

        die "No systemd-boot entries found."
    fi

    local file

    for file in "${files[@]}"; do
        backup "$file"

        python3 - "$file" "${PARAMS[*]}" <<'PY'
import re
import sys

path = sys.argv[1]
params = sys.argv[2].split()

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

match = re.search(
    r'^options[ \t]+(.+)$',
    data,
    re.MULTILINE
)

if not match:
    raise SystemExit(
        f"No options line found in {path}"
    )

current = match.group(1).split()

for param in params:
    key = param.split("=", 1)[0]

    current = [
        item for item in current
        if item.split("=", 1)[0] != key
    ]

    current.append(param)

replacement = "options " + " ".join(current)

data = re.sub(
    r'^options[ \t]+.+$',
    replacement,
    data,
    count=1,
    flags=re.MULTILINE
)

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY

        echo "    Updated: $file"
    done
}

# ----------------------------------------------------------------------
# Limine
#
# Arch Wiki:
#
#   kernel_cmdline: ...
#
# is an alias for:
#
#   cmdline: ...
# ----------------------------------------------------------------------

configure_limine()
{
    local file

    file="$(find_limine_config || true)"

    [[ -n "$file" ]] ||
        die "Limine configuration could not be found."

    info "Configuring Limine: $file"

    backup "$file"

    python3 - "$file" "${PARAMS[*]}" <<'PY'
import re
import sys

path = sys.argv[1]
params = sys.argv[2].split()

with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

found = False

for i, line in enumerate(lines):

    # Support both names documented by Limine.
    match = re.match(
        r'^(\s*)(kernel_cmdline|cmdline):[ \t]*(.*)$',
        line
    )

    if not match:
        continue

    indent = match.group(1)
    keyword = match.group(2)
    current = match.group(3).split()

    for param in params:
        key = param.split("=", 1)[0]

        current = [
            item for item in current
            if item.split("=", 1)[0] != key
        ]

        current.append(param)

    lines[i] = (
        f"{indent}{keyword}: "
        + " ".join(current)
    )

    found = True

if not found:
    raise SystemExit(
        "No kernel_cmdline: or cmdline: entry found in "
        + path
    )

with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
PY
}

# ----------------------------------------------------------------------
# rEFInd
#
# Archinstall generates:
#
#   "Arch Linux (linux)" "kernel parameters initrd=..."
#
# We modify the second quoted field while preserving initrd=.
# ----------------------------------------------------------------------

configure_refind()
{
    local file

    file="$(find_refind_config || true)"

    [[ -n "$file" ]] ||
        die "rEFInd refind_linux.conf could not be found."

    info "Configuring rEFInd: $file"

    backup "$file"

    python3 - "$file" "${PARAMS[*]}" <<'PY'
import re
import sys

path = sys.argv[1]
params = sys.argv[2].split()

with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

output = []

for line in lines:

    # rEFInd's refind_linux.conf format:
    #
    # "Description" "options"
    #
    match = re.match(
        r'^(\s*"[^"]*"\s+")([^"]*)(".*)$',
        line
    )

    if not match:
        output.append(line)
        continue

    prefix = match.group(1)
    options = match.group(2)
    suffix = match.group(3)

    words = options.split()

    for param in params:
        key = param.split("=", 1)[0]

        words = [
            item for item in words
            if item.split("=", 1)[0] != key
        ]

        words.append(param)

    output.append(
        prefix +
        " ".join(words) +
        suffix
    )

with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(output) + "\n")
PY
}

# ----------------------------------------------------------------------
# EFISTUB
#
# Archinstall creates non-UKI EFISTUB entries roughly as:
#
#   efibootmgr --create
#       --label "Arch Linux (linux)"
#       --loader /vmlinuz-linux
#       --unicode
#       "initrd=\initramfs-linux.img ..."
#
# We do NOT attempt to reconstruct an EFI entry. Instead, we use the
# UEFI variable interface exposed by efibootmgr to replace the existing
# entry's command line while preserving its loader/device information.
#
# For UKIs, /etc/kernel/cmdline is the source of truth instead.
# ----------------------------------------------------------------------

configure_efistub()
{
    [[ -d /sys/firmware/efi ]] ||
        die "EFISTUB requires a running UEFI system."

    command_exists efibootmgr ||
        die "efibootmgr is required for EFISTUB."

    if has_uki; then
        configure_kernel_cmdline
        return
    fi

    info "Configuring EFISTUB UEFI entries"

    local current
    current="$(efibootmgr 2>/dev/null)" ||
        die "Could not read UEFI variables."

    local bootnum
    bootnum="$(
        sed -n \
            's/^BootCurrent: \([0-9A-Fa-f]\{4\}\)$/\1/p' \
            <<< "$current"
    )"

    [[ -n "$bootnum" ]] ||
        die "Could not determine BootCurrent."

    local entry
    entry="$(
        efibootmgr -v 2>/dev/null |
        grep -E "^Boot${bootnum}\\*?" || true
    )"

    if [[ -z "$entry" ]]; then
        die "Could not read Boot${bootnum}."
    fi

    #
    # Only modify an Archinstall-style Arch Linux EFISTUB entry.
    #
    if ! grep -q 'Arch Linux (' <<< "$entry"; then
        die "BootCurrent is not an Arch Linux EFISTUB entry."
    fi

    if ! grep -qE 'File\(\\vmlinuz-|File\(\\EFI\\Linux\\arch-' <<< "$entry"; then
        die "BootCurrent does not appear to be an EFISTUB entry."
    fi

    #
    # efibootmgr output is not a lossless machine-readable format.
    # We therefore refuse to rewrite an entry if we cannot safely locate
    # the existing Unicode command line.
    #
    local commandline
    commandline="$(
        sed -n \
            's/.*File([^)]*)[[:space:]]*\(.*\)$/\1/p' \
            <<< "$entry"
    )"

    if [[ -z "$commandline" ]]; then
        #
        # Some efibootmgr versions print the data differently.
        # Fall back to the portion following the EFI file path.
        #
        commandline="$(
            sed -E \
                's/^.*File\([^)]*\)[[:space:]]*//' \
                <<< "$entry"
        )"
    fi

    [[ -n "$commandline" ]] ||
        die "Could not safely extract the EFISTUB command line."

    local new_commandline
    new_commandline="$(update_cmdline "$commandline")"

    echo
    echo "Current EFISTUB entry:"
    echo "  $entry"
    echo
    echo "New command line:"
    echo "  $new_commandline"
    echo

    #
    # IMPORTANT:
    #
    # efibootmgr does not provide a generic "edit just the command line"
    # operation. Recreating the entry is firmware/device dependent.
    #
    # Therefore do not silently destroy/recreate BootCurrent.
    #
    # The safe mechanism is to use the kernel command-line file when
    # available. If it is not, require the user to explicitly opt into
    # recreating the entry.
    #
    if [[ "${ALLOW_EFISTUB_RECREATE:-0}" != "1" ]]; then
        cat >&2 <<EOF

EFISTUB was detected, but this installation does not use a UKI.

The kernel command line is stored in the UEFI NVRAM boot entry.
Silently deleting/recreating that entry is unsafe because the exact
disk/partition/file-path data must be preserved.

No EFI variable was modified.

If you explicitly want this script to recreate the entry, run:

    sudo ALLOW_EFISTUB_RECREATE=1 $0

EOF
        exit 2
    fi

    die "EFISTUB entry recreation requires the exact EFI disk/partition/path and is intentionally not performed by this generic script."
}

# ----------------------------------------------------------------------
# Remove fsck from mkinitcpio HOOKS.
#
# We only modify the actual HOOKS=() assignment and do not source the
# configuration file.
# ----------------------------------------------------------------------

remove_fsck_hook()
{
    require_file "$MKINITCPIO_CONF"

    info "Removing fsck from mkinitcpio HOOKS"

    backup "$MKINITCPIO_CONF"

    python3 - "$MKINITCPIO_CONF" <<'PY'
import re
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

match = re.search(
    r'^HOOKS=\(([^)]*)\)',
    data,
    re.MULTILINE
)

if not match:
    raise SystemExit(
        "Could not find a single-line HOOKS=(...) assignment."
    )

hooks = match.group(1).split()

if "fsck" not in hooks:
    print("    fsck hook is already absent.")
    raise SystemExit(0)

hooks = [hook for hook in hooks if hook != "fsck"]

replacement = "HOOKS=(" + " ".join(hooks) + ")"

data = re.sub(
    r'^HOOKS=\([^)]*\)',
    replacement,
    data,
    count=1,
    flags=re.MULTILINE
)

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

require_root

info "Detecting bootloader"

BOOTLOADER="$(detect_bootloader || true)"

[[ -n "$BOOTLOADER" ]] ||
    die "Could not safely identify the active bootloader."

echo "    Bootloader: $BOOTLOADER"

if has_uki; then
    echo "    UKI:        yes"
else
    echo "    UKI:        no"
fi

echo
echo "    Parameters to add:"
printf '      %s\n' "${PARAMS[@]}"

# ----------------------------------------------------------------------
# Configure command line.
# ----------------------------------------------------------------------

case "$BOOTLOADER" in

    grub)
        if has_uki; then
            #
            # Archinstall UKI configuration:
            # /etc/kernel/cmdline -> embedded into UKI.
            #
            configure_kernel_cmdline
        else
            configure_grub
        fi
        ;;

    systemd-boot)
        configure_systemd_boot
        ;;

    limine)
        if has_uki; then
            configure_kernel_cmdline
        else
            configure_limine
        fi
        ;;

    refind)
        if has_uki; then
            configure_kernel_cmdline
        else
            configure_refind
        fi
        ;;

    efistub)
        configure_efistub
        ;;

    *)
        die "Unsupported bootloader: $BOOTLOADER"
        ;;
esac

# ----------------------------------------------------------------------
# Remove fsck hook.
# ----------------------------------------------------------------------

remove_fsck_hook

# ----------------------------------------------------------------------
# Rebuild initramfs / UKIs.
#
# For a UKI installation this is what embeds /etc/kernel/cmdline.
# ----------------------------------------------------------------------

info "Rebuilding initramfs"

command_exists mkinitcpio ||
    die "mkinitcpio is not installed."

mkinitcpio -P

# ----------------------------------------------------------------------
# Show resulting configuration.
# ----------------------------------------------------------------------

echo
echo "=============================================="
echo "Configuration completed."
echo "=============================================="
echo
echo "Bootloader: $BOOTLOADER"
echo

if [[ -f "$CMDLINE_CONF" ]]; then
    echo "/etc/kernel/cmdline:"
    sed 's/^/  /' "$CMDLINE_CONF"
    echo
fi

if [[ -f "$MKINITCPIO_CONF" ]]; then
    echo "mkinitcpio HOOKS:"
    grep '^HOOKS=' "$MKINITCPIO_CONF" || true
    echo
fi

cat <<'EOF'
After reboot, verify the parameters actually reached
the running kernel with:

    cat /proc/cmdline

You should see:

    quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 vt.global_cursor_default=0

Note that removing the mkinitcpio "fsck" hook does not disable
systemd's later filesystem checks. Those are controlled separately
by fstab/fsck settings and systemd.
EOF
