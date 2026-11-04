#!/usr/bin/env bash
# Undo local files, services, command-line parameters, and themes.
# Does not remove pacman packages. Pass --repos to drop the repo blocks too.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

REMOVE_REPOS=0

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--repos]

Disables the BC-250 services this setup enabled, removes the local scripts
and command-line parameters it added, and removes the four themes if they
still match this repository.

  --repos   also remove [bc250-cachyos] and the CachyOS repo blocks
            from /etc/pacman.conf, after backing that file up

Pacman packages stay installed. Boot the Omarchy kernel before removing
linux-cachyos-bc250, then see the README for the package commands.
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --repos)
      REMOVE_REPOS=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1 (try ./uninstall.sh --help)"
      ;;
  esac
  shift
done

if [[ $EUID -eq 0 ]]; then
  die "Run this as your user, not root. It will call sudo itself."
fi
sudo -v || die "sudo failed"

remove_matching_file() {
  local src=$1
  local dest=$2
  if [[ ! -e $dest ]]; then
    return 0
  fi
  if [[ -f $src && -f $dest ]] && cmp -s "$src" "$dest"; then
    sudo rm -f "$dest"
    log "removed ${dest}"
    return 0
  fi
  warn "left ${dest} in place because it no longer matches this repository"
}

load_base_params
PARAMS=("${BASE_PARAMS[@]}" amdgpu.cs_eight_core_map=1)

log "Disabling BC-250 services"
sudo systemctl disable --now \
  bc250-cu-live-manager.service \
  bc250-thermal-guard.service \
  bc250-cec.service \
  cyan-skillfish-governor-smu.service \
  bc250-smu-oc.service \
  || warn "one or more services were not installed"

boot=$(bootloader_name)
log "Removing BC-250 kernel parameters (${boot})"
case $boot in
  limine)
    if [[ -f /etc/default/limine ]]; then
      apply_text_file /etc/default/limine remove-limine "${PARAMS[@]}" || warn "could not edit Limine config"
    fi
    if [[ -f /etc/kernel/cmdline ]]; then
      apply_text_file /etc/kernel/cmdline remove-kernel-cmdline "${PARAMS[@]}" || true
    fi
    if command -v limine-update >/dev/null 2>&1; then
      sudo limine-update || warn "limine-update failed"
    elif command -v limine-mkinitcpio >/dev/null 2>&1; then
      sudo limine-mkinitcpio || warn "limine-mkinitcpio failed"
    fi
    ;;
  systemd-boot)
    if [[ -d /boot/loader/entries ]]; then
      while IFS= read -r entry; do
        apply_text_file "$entry" remove-systemd-boot "${PARAMS[@]}" || true
      done < <(find /boot/loader/entries -maxdepth 1 -type f -name '*.conf' | sort)
    fi
    ;;
  grub)
    if [[ -f /etc/default/grub ]]; then
      apply_text_file /etc/default/grub remove-grub "${PARAMS[@]}" || true
    fi
    if [[ -f /boot/grub/grub.cfg ]]; then
      sudo grub-mkconfig -o /boot/grub/grub.cfg || warn "grub-mkconfig failed"
    fi
    ;;
  *)
    warn "Bootloader was not recognized. Remove the BC-250 parameters from the kernel command line by hand."
    ;;
esac

log "Removing local files that still match this repository"
remove_matching_file "$ROOT/system/bin/bc250-cu-live-manager" /usr/local/bin/bc250-cu-live-manager
remove_matching_file "$ROOT/system/bin/bc250-thermal-guard" /usr/local/bin/bc250-thermal-guard
remove_matching_file "$ROOT/bin/update-all" /usr/local/bin/update-all
remove_matching_file "$ROOT/system/systemd/bc250-cu-live-manager.service" /etc/systemd/system/bc250-cu-live-manager.service
remove_matching_file "$ROOT/system/systemd/bc250-thermal-guard.service" /etc/systemd/system/bc250-thermal-guard.service
remove_matching_file "$ROOT/system/systemd/bc250-smu-oc.service" /etc/systemd/system/bc250-smu-oc.service
remove_matching_file "$ROOT/system/etc/bc250-cu-live-manager.conf" /etc/bc250-cu-live-manager.conf
remove_matching_file "$ROOT/system/etc/bc250-smu-oc.conf" /etc/bc250-smu-oc.conf
remove_matching_file "$ROOT/system/etc/99-swappiness.conf" /etc/sysctl.d/99-swappiness.conf
remove_matching_file "$ROOT/system/modules-load.d/nct6687.conf" /etc/modules-load.d/nct6687.conf
remove_matching_file \
  "$ROOT/system/etc/cyan-skillfish-governor-smu/config.toml" \
  /etc/cyan-skillfish-governor-smu/config.toml
remove_matching_file "$ROOT/system/bin/bc250_apply.py" /usr/local/lib/bc250-smu-oc/bc250_apply.py
sudo rmdir /usr/local/lib/bc250-smu-oc 2>/dev/null || true

if ! pacman -Q bc250-cec >/dev/null 2>&1; then
  remove_matching_file "$ROOT/system/cec/usr/lib/bc250-cec/bc250-cec-daemon.sh" /usr/lib/bc250-cec/bc250-cec-daemon.sh
  remove_matching_file "$ROOT/system/cec/usr/lib/bc250-cec/bc250-cec-keymap.sh" /usr/lib/bc250-cec/bc250-cec-keymap.sh
  remove_matching_file "$ROOT/system/cec/usr/lib/systemd/system/bc250-cec.service" /usr/lib/systemd/system/bc250-cec.service
  remove_matching_file "$ROOT/system/cec/usr/lib/udev/rules.d/71-bc250-cec-keys.rules" /usr/lib/udev/rules.d/71-bc250-cec-keys.rules
  remove_matching_file "$ROOT/system/cec/etc/bc250-cec.conf" /etc/bc250-cec.conf
fi

sudo systemctl daemon-reload || true

for theme_name in vader jedi amber-retro green-crt; do
  dest="${HOME}/.config/omarchy/themes/${theme_name}"
  src="${ROOT}/themes/${theme_name}"
  if [[ -d $dest ]] && diff -rq "$src" "$dest" >/dev/null; then
    rm -rf "$dest"
    log "removed theme ${dest}"
  elif [[ -d $dest ]]; then
    warn "left theme ${dest} because it no longer matches this repository"
  fi
done

if [[ $REMOVE_REPOS -eq 1 ]]; then
  log "Removing BC-250 and CachyOS repository blocks from /etc/pacman.conf"
  apply_text_file /etc/pacman.conf remove-machine-repos || die "could not edit /etc/pacman.conf"
  sudo pacman -Sy || warn "pacman -Sy failed after removing repositories"
else
  log "Left /etc/pacman.conf repositories in place. Run ./uninstall.sh --repos to remove them."
fi

cat <<'EOF'

Packages were not removed. Boot an Omarchy kernel entry first, then, if you
want the Arch packages back, run:

  sudo pacman -Rns linux-cachyos-bc250 linux-cachyos-bc250-headers bc250-cec bc250-dual-audio proton-cachyos-native-bc250 protonge-latest-bc250 cyan-skillfish-governor-smu umr
  sudo pacman -S extra/mesa extra/vulkan-radeon multilib/lib32-mesa multilib/lib32-vulkan-radeon

EOF
