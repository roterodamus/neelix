#!/usr/bin/env bash

# ============================================================
# Arch Linux boot configuration
#
# Does:
#   - Installs and configures Plymouth
#   - Adds silent-boot kernel parameters
#   - Adds Plymouth's "splash" parameter
#   - Removes fsck from mkinitcpio HOOKS
#   - Adds the Plymouth mkinitcpio hook in the correct position
#   - Rebuilds initramfs
#   - Supports Archinstall bootloader layouts:
#       systemd-boot
#       GRUB
#       Limine
#       rEFInd
#       EFISTUB
#   - Supports UKI layouts through /etc/kernel/cmdline
#
# Run as root.
# ============================================================

export LC_ALL=C

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    printf 'ERROR: run this script as root.\n' >&2
    exit 1
fi

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

readonly MKINITCPIO_CONF="/etc/mkinitcpio.conf"

# Plymouth theme.
# "bgrt" is included with the Arch plymouth package.
readonly PLYMOUTH_THEME="bgrt"

# Parameters requested for silent boot + Plymouth.
readonly -a REQUIRED_KERNEL_PARAMS=(
    quiet
    splash
    loglevel=3
    systemd.show_status=auto
    rd.udev.log_level=3
    vt.global_cursor_default=0
)

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '==> %s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

command -v pacman >/dev/null 2>&1 || die "pacman not found."
command -v mkinitcpio >/dev/null 2>&1 || die "mkinitcpio not found."

[[ -f "$MKINITCPIO_CONF" ]] ||
    die "$MKINITCPIO_CONF does not exist."

# ------------------------------------------------------------
# Backup configuration
# ------------------------------------------------------------

BACKUP_DIR="/etc/boot-plymouth-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

cp -a "$MKINITCPIO_CONF" "$BACKUP_DIR/mkinitcpio.conf"

info "Configuration backup: $BACKUP_DIR"

# ------------------------------------------------------------
# Install Plymouth
# ------------------------------------------------------------

info "Installing Plymouth..."

pacman -S --needed --noconfirm plymouth

command -v plymouth-set-default-theme >/dev/null 2>&1 ||
    die "plymouth-set-default-theme was not installed."

[[ -d "/usr/share/plymouth/themes/$PLYMOUTH_THEME" ]] ||
    die "Plymouth theme '$PLYMOUTH_THEME' is not installed."

# ------------------------------------------------------------
# Plymouth theme
# ------------------------------------------------------------

info "Setting Plymouth theme: $PLYMOUTH_THEME"

plymouth-set-default-theme "$PLYMOUTH_THEME"

# ------------------------------------------------------------
# Kernel command-line manipulation
# ------------------------------------------------------------

escape_regex() {
    printf '%s' "$1" |
        sed 's/[][\\.^$*+?(){}|]/\\&/g'
}

update_cmdline() {
    local current="$1"
    local param key regex

    for param in "${REQUIRED_KERNEL_PARAMS[@]}"; do
        if [[ "$param" == *=* ]]; then
            key="${param%%=*}"
        else
            key="$param"
        fi

        regex="$(escape_regex "$key")"

        # Remove an existing instance of this parameter.
        # The parameter is considered whitespace-delimited, which is
        # how kernel command lines are represented.
        current="$(
            printf '%s\n' "$current" |
                sed -E \
                    "s/(^|[[:space:]])${regex}(=[^[:space:]]+)?([[:space:]]|$)/ /g" |
                sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
        )"

        if [[ -n "$current" ]]; then
            current+=" "
        fi

        current+="$param"
    done

    printf '%s' "$current"
}

# ------------------------------------------------------------
# Remove fsck from mkinitcpio HOOKS
# ------------------------------------------------------------

remove_fsck_hook() {
    local tmp
    tmp="$(mktemp)"

    awk '
        BEGIN {
            in_hooks = 0
        }

        /^[[:space:]]*HOOKS[[:space:]]*=/ {
            in_hooks = 1
        }

        {
            if (in_hooks) {
                gsub(/(^|[[:space:]])fsck([[:space:]]|$)/, " ")
                gsub(/[[:space:]]+/, " ")
            }

            print

            if (in_hooks && /\)/) {
                in_hooks = 0
            }
        }
    ' "$MKINITCPIO_CONF" > "$tmp"

    if ! cmp -s "$MKINITCPIO_CONF" "$tmp"; then
        cat "$tmp" > "$MKINITCPIO_CONF"
        info "Removed fsck from mkinitcpio HOOKS."
    else
        info "fsck was already absent from mkinitcpio HOOKS."
    fi

    rm -f "$tmp"
}

# ------------------------------------------------------------
# Configure Plymouth mkinitcpio hook
# ------------------------------------------------------------

configure_plymouth_hook() {
    local tmp
    tmp="$(mktemp)"

    awk '
        function print_hooks(    i) {
            printf "HOOKS=("
            for (i = 1; i <= hook_count; i++) {
                if (hooks[i] != "")
                    printf "%s%s", (i == 1 ? "" : " "), hooks[i]
            }
            print ")"
        }

        /^[[:space:]]*HOOKS[[:space:]]*=/ {
            # Read the entire HOOKS assignment, including multiline arrays.
            line = $0

            while (line !~ /\)/ && getline nextline) {
                line = line " " nextline
            }

            # Extract everything between the first '(' and the last ')'.
            sub(/^[^(]*\(/, "", line)
            sub(/\)[^)]*$/, "", line)

            hook_count = 0

            # Split on whitespace.
            n = split(line, raw, /[[:space:]]+/)

            for (i = 1; i <= n; i++) {
                if (raw[i] == "")
                    continue

                # Remove fsck and an existing plymouth hook.
                if (raw[i] == "fsck" || raw[i] == "plymouth")
                    continue

                hooks[++hook_count] = raw[i]
            }

            # Find the correct Plymouth position.
            #
            # systemd initramfs:
            #   systemd -> plymouth
            #
            # encrypted root:
            #   plymouth -> encrypt/sd-encrypt
            #
            # busybox/udev initramfs:
            #   udev -> plymouth
            #
            insert_at = 0

            for (i = 1; i <= hook_count; i++) {
                if (hooks[i] == "encrypt" ||
                    hooks[i] == "sd-encrypt") {
                    insert_at = i
                    break
                }
            }

            if (insert_at == 0) {
                for (i = 1; i <= hook_count; i++) {
                    if (hooks[i] == "systemd") {
                        insert_at = i + 1
                        break
                    }
                }
            }

            if (insert_at == 0) {
                for (i = 1; i <= hook_count; i++) {
                    if (hooks[i] == "udev") {
                        insert_at = i + 1
                        break
                    }
                }
            }

            if (insert_at == 0) {
                for (i = 1; i <= hook_count; i++) {
                    if (hooks[i] == "filesystems") {
                        insert_at = i
                        break
                    }
                }
            }

            if (insert_at == 0)
                insert_at = hook_count + 1

            # Shift elements to make room.
            for (i = hook_count; i >= insert_at; i--)
                hooks[i + 1] = hooks[i]

            hooks[insert_at] = "plymouth"
            hook_count++

            print_hooks()

            in_hooks = 1

            # Skip the remaining physical lines of a multiline HOOKS array.
            while (line !~ /\)/ && getline line) {
                if (line ~ /\)/)
                    break
            }

            in_hooks = 0
            next
        }

        {
            print
        }
    ' "$MKINITCPIO_CONF" > "$tmp"

    if ! cmp -s "$MKINITCPIO_CONF" "$tmp"; then
        cat "$tmp" > "$MKINITCPIO_CONF"
        info "Configured mkinitcpio Plymouth hook."
    else
        info "mkinitcpio Plymouth configuration already correct."
    fi

    rm -f "$tmp"
}

# ------------------------------------------------------------
# Update /etc/kernel/cmdline
# ------------------------------------------------------------

update_kernel_cmdline_file() {
    local file="/etc/kernel/cmdline"
    local old new

    [[ -f "$file" ]] || return 1

    old="$(cat "$file")"
    new="$(update_cmdline "$old")"

    printf '%s\n' "$new" > "$file"

    info "Updated $file"

    return 0
}

# ------------------------------------------------------------
# Update systemd-boot BLS entries
# ------------------------------------------------------------

update_systemd_boot_entries() {
    local entries_dir=""
    local file old_options new_options
    local found=0

    for candidate in \
        /efi/loader/entries \
        /boot/loader/entries
    do
        if [[ -d "$candidate" ]]; then
            entries_dir="$candidate"
            break
        fi
    done

    [[ -n "$entries_dir" ]] || return 1

    shopt -s nullglob

    for file in "$entries_dir"/*.conf; do
        found=1

        old_options="$(
            sed -nE 's/^[[:space:]]*options[[:space:]]+(.*)$/\1/p' "$file" |
                head -n1
        )"

        [[ -n "$old_options" ]] || continue

        new_options="$(update_cmdline "$old_options")"

        sed -i -E \
            "s|^[[:space:]]*options[[:space:]].*$|options $new_options|" \
            "$file"

        info "Updated systemd-boot entry: $file"
    done

    shopt -u nullglob

    (( found == 1 ))
}

# ------------------------------------------------------------
# Update GRUB
# ------------------------------------------------------------

update_grub() {
    local grub_default="/etc/default/grub"
    local old new

    [[ -f "$grub_default" ]] || return 1
    command -v grub-mkconfig >/dev/null 2>&1 || return 1

    # Archinstall currently writes kernel parameters to
    # GRUB_CMDLINE_LINUX.
    #
    # Some installations also have GRUB_CMDLINE_LINUX_DEFAULT.
    # Update both when present.

    if grep -qE '^[[:space:]]*GRUB_CMDLINE_LINUX=' "$grub_default"; then
        old="$(
            sed -nE \
                's/^[[:space:]]*GRUB_CMDLINE_LINUX="(.*)"[[:space:]]*$/\1/p' \
                "$grub_default" |
                head -n1
        )"

        new="$(update_cmdline "$old")"

        sed -i -E \
            "s|^[[:space:]]*GRUB_CMDLINE_LINUX=.*$|GRUB_CMDLINE_LINUX=\"$new\"|" \
            "$grub_default"
    else
        printf '\nGRUB_CMDLINE_LINUX="%s"\n' \
            "$(update_cmdline "")" >> "$grub_default"
    fi

    if grep -qE '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_default"; then
        old="$(
            sed -nE \
                's/^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT="(.*)"[[:space:]]*$/\1/p' \
                "$grub_default" |
                head -n1
        )"

        new="$(update_cmdline "$old")"

        sed -i -E \
            "s|^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=.*$|GRUB_CMDLINE_LINUX_DEFAULT=\"$new\"|" \
            "$grub_default"
    fi

    local grub_cfg="/boot/grub/grub.cfg"

    if [[ -d /boot/grub ]]; then
        grub-mkconfig -o "$grub_cfg"
        info "Regenerated $grub_cfg."
    else
        warn "GRUB configuration directory not found."
    fi

    return 0
}

# ------------------------------------------------------------
# Find Limine configuration
# ------------------------------------------------------------

find_limine_config() {
    local candidate

    for candidate in \
        /boot/limine.conf \
        /boot/limine/limine.conf \
        /efi/limine.conf \
        /efi/limine/limine.conf
    do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    find /boot /efi \
        -maxdepth 3 \
        -type f \
        \( -name 'limine.conf' -o -name 'limine.cfg' \) \
        -print -quit 2>/dev/null

    return 1
}

# ------------------------------------------------------------
# Update Limine
# ------------------------------------------------------------

update_limine() {
    local config
    local old new

    config="$(find_limine_config)" || return 1

    # Limine's kernel command line directive is kernel_cmdline:
    # cmdline: is accepted as an alias by Limine.
    if grep -qE '^[[:space:]]*(kernel_cmdline|cmdline):' "$config"; then
        old="$(
            sed -nE \
                's/^[[:space:]]*(kernel_cmdline|cmdline):[[:space:]]*(.*)$/\2/p' \
                "$config" |
                head -n1
        )"

        new="$(update_cmdline "$old")"

        sed -i -E \
            "s|^([[:space:]]*)(kernel_cmdline|cmdline):.*$|\1kernel_cmdline: $new|" \
            "$config"

        info "Updated Limine configuration: $config"
        return 0
    fi

    return 1
}

# ------------------------------------------------------------
# Update rEFInd
# ------------------------------------------------------------

update_refind() {
    local config
    local tmp
    local changed=0

    for config in \
        /boot/refind_linux.conf \
        /efi/refind_linux.conf
    do
        [[ -f "$config" ]] || continue

        tmp="$(mktemp)"

        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^[[:space:]]*\"[^\"]+\"[[:space:]]+\"(.*)\"[[:space:]]*$ ]]; then
                local title params new_params
                title="${line#\"}"
                title="${title%%\"*}"

                params="${line#*\" \"}"
                params="${params%\"}"

                new_params="$(update_cmdline "$params")"

                printf '"%s" "%s"\n' "$title" "$new_params" >> "$tmp"
                changed=1
            else
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$config"

        if (( changed )); then
            cat "$tmp" > "$config"
            info "Updated rEFInd configuration: $config"
        fi

        rm -f "$tmp"

        return 0
    done

    return 1
}

# ------------------------------------------------------------
# Detect UKI
# ------------------------------------------------------------

detect_uki() {
    [[ -f /etc/kernel/cmdline ]] || return 1

    local uki

    for uki in \
        /efi/EFI/Linux/*.efi \
        /boot/EFI/Linux/*.efi
    do
        [[ -f "$uki" ]] && return 0
    done

    return 1
}

# ------------------------------------------------------------
# Detect bootloader from UEFI BootCurrent
# ------------------------------------------------------------

detect_uefi_bootloader() {
    command -v efibootmgr >/dev/null 2>&1 || return 1

    local output current_line current_id entry

    output="$(efibootmgr -v 2>/dev/null)" || return 1

    current_line="$(
        printf '%s\n' "$output" |
            sed -nE 's/^BootCurrent:[[:space:]]*([0-9A-Fa-f]{4}).*$/\1/p' |
            head -n1
    )"

    [[ -n "$current_line" ]] || return 1

    entry="$(
        printf '%s\n' "$output" |
            grep -E "^Boot${current_line}\\*" |
            head -n1
    )"

    [[ -n "$entry" ]] || return 1

    case "$entry" in
        *systemd*|*SYSTEMD*)
            printf '%s\n' "systemd-boot"
            ;;
        *grub*|*GRUB*)
            printf '%s\n' "grub"
            ;;
        *limine*|*LIMINE*)
            printf '%s\n' "limine"
            ;;
        *refind*|*rEFInd*|*REFIND*)
            printf '%s\n' "refind"
            ;;
        *File\\\\vmlinuz*|*File\\\\EFI\\\\Linux\\\\*)
            printf '%s\n' "efistub"
            ;;
        *)
            return 1
            ;;
    esac
}

# ------------------------------------------------------------
# Detect bootloader from filesystem
# ------------------------------------------------------------

detect_filesystem_bootloader() {
    if [[ -f /etc/default/grub ]] ||
       [[ -f /boot/grub/grub.cfg ]]; then
        printf '%s\n' "grub"
        return 0
    fi

    if [[ -d /boot/loader ]] ||
       [[ -d /efi/loader ]]; then
        printf '%s\n' "systemd-boot"
        return 0
    fi

    if find_limine_config >/dev/null 2>&1; then
        printf '%s\n' "limine"
        return 0
    fi

    if [[ -f /boot/refind_linux.conf ]] ||
       [[ -f /efi/refind_linux.conf ]]; then
        printf '%s\n' "refind"
        return 0
    fi

    return 1
}

# ------------------------------------------------------------
# Main mkinitcpio configuration
# ------------------------------------------------------------

info "Removing fsck hook..."
remove_fsck_hook

info "Adding/configuring Plymouth hook..."
configure_plymouth_hook

# ------------------------------------------------------------
# Kernel command line / bootloader
# ------------------------------------------------------------

BOOTLOADER=""

if detect_uki; then
    info "UKI detected."

    if update_kernel_cmdline_file; then
        info "Updated UKI kernel command line."
    else
        die "UKI detected but /etc/kernel/cmdline is missing."
    fi
else
    if command -v efibootmgr >/dev/null 2>&1; then
        BOOTLOADER="$(detect_uefi_bootloader || true)"
    fi

    if [[ -z "$BOOTLOADER" ]]; then
        BOOTLOADER="$(detect_filesystem_bootloader || true)"
    fi

    [[ -n "$BOOTLOADER" ]] ||
        die "Could not detect a supported bootloader configuration."

    info "Detected bootloader: $BOOTLOADER"

    case "$BOOTLOADER" in
        systemd-boot)
            if ! update_systemd_boot_entries; then
                if [[ -f /etc/kernel/cmdline ]]; then
                    update_kernel_cmdline_file
                else
                    die "systemd-boot detected but no BLS entries or /etc/kernel/cmdline found."
                fi
            fi
            ;;

        grub)
            update_grub ||
                die "GRUB detected but its configuration could not be updated."
            ;;

        limine)
            if ! update_limine; then
                if [[ -f /etc/kernel/cmdline ]]; then
                    update_kernel_cmdline_file
                else
                    die "Limine detected but no Limine config or /etc/kernel/cmdline found."
                fi
            fi
            ;;

        refind)
            update_refind ||
                die "rEFInd detected but refind_linux.conf could not be updated."
            ;;

        efistub)
            die "EFISTUB was detected. Refusing to rewrite EFI NVRAM entries automatically because recreating them can alter firmware BootOrder. Update the existing EFISTUB command line with your EFI boot manager before continuing."
            ;;

        *)
            die "Unsupported bootloader: $BOOTLOADER"
            ;;
    esac
fi

# ------------------------------------------------------------
# Verify mkinitcpio configuration before rebuilding
# ------------------------------------------------------------

info "Checking mkinitcpio configuration..."

if ! mkinitcpio -L | grep -qx 'plymouth'; then
    die "mkinitcpio does not provide the Plymouth hook."
fi

HOOKS_LINE="$(
    awk '
        /^[[:space:]]*HOOKS[[:space:]]*=/ {
            line=$0
            while (line !~ /\)/ && getline nextline)
                line=line " " nextline
            print line
            exit
        }
    ' "$MKINITCPIO_CONF"
)"

[[ -n "$HOOKS_LINE" ]] ||
    die "Could not read HOOKS from $MKINITCPIO_CONF."

if [[ "$HOOKS_LINE" =~ (^|[[:space:]])fsck([[:space:]]|$) ]]; then
    die "fsck is still present in HOOKS."
fi

if [[ ! "$HOOKS_LINE" =~ (^|[[:space:]])plymouth([[:space:]]|$) ]]; then
    die "plymouth is not present in HOOKS."
fi

# ------------------------------------------------------------
# Rebuild initramfs
# ------------------------------------------------------------

info "Rebuilding all initramfs images..."

mkinitcpio -P

# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

printf '\n'
info "Configuration complete."

printf '%s\n' "Plymouth theme:"
plymouth-set-default-theme

printf '%s\n' "mkinitcpio HOOKS:"
grep -E '^[[:space:]]*HOOKS=' "$MKINITCPIO_CONF" || true

if [[ -f /etc/kernel/cmdline ]]; then
    printf '%s\n' "Kernel command line (/etc/kernel/cmdline):"
    cat /etc/kernel/cmdline
fi

printf '\n'
info "Verify the active kernel command line after reboot with:"
printf '%s\n' '    cat /proc/cmdline'

printf '\n'
info "Backup saved at:"
printf '%s\n' "    $BACKUP_DIR"
