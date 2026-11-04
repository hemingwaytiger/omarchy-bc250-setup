#!/usr/bin/env bash
# Turn a fresh Omarchy install (vanilla Arch) into the working BC-250 setup.
# Run as your normal user. The script calls sudo when it needs root.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

FORCE=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [--force]

Sets up an official Omarchy install (Arch Linux, not CachyOS) for the AMD
BC-250. Re-running is safe: files are backed up before they change, and a
second run leaves matching files alone.

  --force   continue even if this does not look like an Omarchy install
  --help    show this help

The CPU overclock service (bc250-smu-oc) is installed and left disabled.
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1 (try ./install.sh --help)"
      ;;
  esac
  shift
done

FAILED=()

run_step() {
  local title=$1
  shift
  log "$title"
  if "$@"; then
    log "done: ${title}"
    return 0
  fi
  warn "failed: ${title}"
  FAILED+=("$title")
}

step_preflight() {
  if [[ $EUID -eq 0 ]]; then
    die "Run this as your user, not root. It will call sudo itself."
  fi
  if [[ $(uname -m) != x86_64 ]]; then
    warn "This setup is for x86_64. This machine is $(uname -m)."
    return 1
  fi
  if ! grep -q '^ID=arch$' /etc/os-release && ! grep -q 'arch' /etc/os-release; then
    warn "This does not look like Arch Linux."
    return 1
  fi
  if [[ $FORCE -eq 0 ]]; then
    if ! command -v omarchy >/dev/null 2>&1 \
      && ! command -v omarchy-update >/dev/null 2>&1 \
      && [[ ! -d ${HOME}/.local/share/omarchy ]]; then
      warn "Omarchy was not found. Re-run with --force if this is intentional."
      return 1
    fi
  fi
  need sudo -v || return 1
  if [[ -r /sys/class/dmi/id/board_name || -r /sys/class/dmi/id/product_name ]]; then
    local board
    board=$(cat /sys/class/dmi/id/board_name /sys/class/dmi/id/product_name 2>/dev/null || true)
    if [[ $board != *[Bb][Cc]-250* && $board != *[Bb][Cc]250* ]]; then
      warn "Firmware board name does not mention BC-250 (${board//$'\n'/ }). Continuing."
    fi
  fi
  need sudo pacman -Sy --needed --noconfirm python || return 1
}

import_cachyos_key() {
  local server
  sudo pacman-key --init >/dev/null
  for server in keyserver.ubuntu.com keys.openpgp.org; do
    if sudo pacman-key --recv-keys F3B607488DB35A47 --keyserver "$server"; then
      sudo pacman-key --lsign-key F3B607488DB35A47
      return $?
    fi
    warn "keyserver ${server} did not provide the CachyOS key"
  done
  return 1
}

latest_mirror_pkg() {
  local listing=$1
  local pattern=$2
  local name
  name=$(printf '%s\n' "$listing" | grep -oE "$pattern" | sort -V | tail -n 1)
  [[ -n $name ]] || return 1
  printf '%s\n' "$name"
}

step_repos() {
  local listing mirror keyring mirrorlist v3list mode
  local -a packages
  mirror=https://mirror.cachyos.org/repo/x86_64/cachyos
  log "Importing the CachyOS signing key and installing the keyring and mirrorlists"
  need import_cachyos_key || return 1
  listing=$(curl -fsSL "${mirror}/") || {
    warn "Could not read ${mirror}/"
    return 1
  }
  keyring=$(latest_mirror_pkg "$listing" 'cachyos-keyring-[^"<> ]+-any\.pkg\.tar\.zst') || return 1
  mirrorlist=$(latest_mirror_pkg "$listing" 'cachyos-mirrorlist-[^"<> ]+-any\.pkg\.tar\.zst') || return 1
  packages=("${mirror}/${keyring}" "${mirror}/${mirrorlist}")
  if cpu_supports_v3; then
    mode=v3
    v3list=$(latest_mirror_pkg "$listing" 'cachyos-v3-mirrorlist-[^"<> ]+-any\.pkg\.tar\.zst') || return 1
    packages+=("${mirror}/${v3list}")
    log "CPU supports x86-64-v3. Repositories will match the working machine."
  else
    mode=plain
    warn "CPU does not advertise x86-64-v3. Using the generic cachyos repo only."
  fi
  need sudo pacman -U --needed --noconfirm "${packages[@]}" || return 1

  log "Updating /etc/pacman.conf. A timestamped backup is written first when the file changes."
  log "[bc250-cachyos] uses SigLevel = Optional TrustAll, same as the working machine"
  if [[ $mode == v3 ]]; then
    log "Order: bc250-cachyos, cachyos-v3, cachyos-extra-v3, cachyos-core-v3, cachyos, core, extra, multilib"
  else
    log "Order: bc250-cachyos, cachyos, core, extra, multilib"
  fi
  need apply_text_file /etc/pacman.conf ensure-machine-repos "$mode" || return 1
  log "Repository headers now in /etc/pacman.conf:"
  grep -E '^\[.*\]' /etc/pacman.conf || true
  need sudo pacman -Sy || return 1
}

step_packages() {
  local -a packages
  packages=(
    linux-cachyos-bc250
    linux-cachyos-bc250-headers
    mesa
    lib32-mesa
    vulkan-radeon
    lib32-vulkan-radeon
    vulkan-mesa-layers
    lib32-vulkan-mesa-layers
    bc250-cec
    bc250-dual-audio
    proton-cachyos-native-bc250
    protonge-latest-bc250
    steam
    gamemode
    lib32-gamemode
    linux-firmware
    amd-ucode
    v4l-utils
    python
    python-evdev
    wireplumber
    pipewire
    pipewire-alsa
    pipewire-pulse
    alsa-plugins
    alsa-utils
    mesa-utils
    vulkan-tools
    git
    base-devel
  )
  log "Upgrading the system onto these repositories and installing the BC-250 stack"
  log "The Omarchy kernel stays installed so Limine still has a fallback entry"
  need sudo pacman -Syu --needed --noconfirm "${packages[@]}" || return 1
  if ! pacman -Q bc250-cec >/dev/null 2>&1; then
    warn "bc250-cec did not install from the repo. Copying the bundled 1-17 files."
    need install_file "$ROOT/system/cec/usr/lib/bc250-cec/bc250-cec-daemon.sh" /usr/lib/bc250-cec/bc250-cec-daemon.sh 755 || return 1
    need install_file "$ROOT/system/cec/usr/lib/bc250-cec/bc250-cec-keymap.sh" /usr/lib/bc250-cec/bc250-cec-keymap.sh 755 || return 1
    need install_file "$ROOT/system/cec/usr/lib/systemd/system/bc250-cec.service" /usr/lib/systemd/system/bc250-cec.service 644 || return 1
    need install_file "$ROOT/system/cec/usr/lib/udev/rules.d/71-bc250-cec-keys.rules" /usr/lib/udev/rules.d/71-bc250-cec-keys.rules 644 || return 1
    need install_file "$ROOT/system/cec/etc/bc250-cec.conf" /etc/bc250-cec.conf 644 || return 1
    sudo udevadm control --reload-rules || true
  fi
}

install_yay() {
  local tmp
  if command -v yay >/dev/null 2>&1; then
    log "yay is already installed"
    return 0
  fi
  tmp=$(mktemp -d)
  git clone --depth 1 https://aur.archlinux.org/yay.git "${tmp}/yay" || return 1
  (
    cd "${tmp}/yay" || exit 1
    makepkg -si --noconfirm
  ) || return 1
  rm -rf "$tmp"
}

step_aur() {
  need install_yay || return 1
  if ! yay -S --needed --noconfirm umr; then
    warn "umr failed to build. Trying umr-git."
    need yay -S --needed --noconfirm umr-git || return 1
  fi
  log "Building cyan-skillfish-governor-smu from the AUR. This compiles Rust code."
  need yay -S --needed --noconfirm cyan-skillfish-governor-smu || return 1
}

amdgpu_has_param() {
  local param=$1
  local ko
  ko=$(find /lib/modules /usr/lib/modules -path '*cachyos-bc250*' -name 'amdgpu.ko*' 2>/dev/null | head -n 1 || true)
  [[ -n $ko ]] || return 1
  modinfo "$ko" 2>/dev/null | grep -q "^parm:[[:space:]]*${param}:"
}

step_boot() {
  local -a params
  local boot entry found
  found=0
  load_base_params
  params=("${BASE_PARAMS[@]}")
  if amdgpu_has_param cs_eight_core_map; then
    params+=(amdgpu.cs_eight_core_map=1)
    log "Kernel still has amdgpu.cs_eight_core_map; adding it to the command line"
  else
    warn "Skipping amdgpu.cs_eight_core_map=1. This kernel does not list that parameter, and an unknown amdgpu option can keep the GPU driver from loading. Current BC-250 kernels pick 6-core or 8-core telemetry on their own."
  fi

  boot=$(bootloader_name)
  log "Bootloader: ${boot}"
  case $boot in
    limine)
      need apply_text_file /etc/default/limine ensure-limine "${params[@]}" || return 1
      if [[ -f /etc/kernel/cmdline ]]; then
        need apply_text_file /etc/kernel/cmdline ensure-kernel-cmdline "${params[@]}" || return 1
      fi
      if command -v limine-update >/dev/null 2>&1; then
        need sudo limine-update || return 1
      elif command -v limine-mkinitcpio >/dev/null 2>&1; then
        need sudo limine-mkinitcpio || return 1
      else
        warn "limine-update is not installed. Reboot will not see the new command line until the UKI is rebuilt."
      fi
      ;;
    systemd-boot)
      while IFS= read -r entry; do
        found=1
        need apply_text_file "$entry" ensure-systemd-boot "${params[@]}" || return 1
      done < <(find /boot/loader/entries -maxdepth 1 -type f -name '*.conf' | sort)
      if [[ $found -eq 0 ]]; then
        warn "No systemd-boot entries were found under /boot/loader/entries."
        return 1
      fi
      ;;
    grub)
      need apply_text_file /etc/default/grub ensure-grub "${params[@]}" || return 1
      if [[ -f /boot/grub/grub.cfg ]]; then
        need sudo grub-mkconfig -o /boot/grub/grub.cfg || return 1
      fi
      ;;
    *)
      warn "No Limine, systemd-boot, or GRUB configuration was found."
      warn "Add these parameters yourself, without removing root=: ${params[*]}"
      return 1
      ;;
  esac

  need install_file "$ROOT/system/etc/99-swappiness.conf" /etc/sysctl.d/99-swappiness.conf 644 || return 1
  sudo sysctl --system >/dev/null || warn "sysctl --system reported an error"
  need install_file "$ROOT/system/modules-load.d/nct6687.conf" /etc/modules-load.d/nct6687.conf 644 || return 1
}

step_governor() {
  need install_file \
    "$ROOT/system/etc/cyan-skillfish-governor-smu/config.toml" \
    /etc/cyan-skillfish-governor-smu/config.toml \
    644 || return 1
  if [[ ! -f /usr/lib/systemd/system/cyan-skillfish-governor-smu.service \
    && ! -f /etc/systemd/system/cyan-skillfish-governor-smu.service ]]; then
    warn "cyan-skillfish-governor-smu.service is not installed. The config is in place for when the package is."
    return 1
  fi
  sudo systemctl daemon-reload
  sudo systemctl enable cyan-skillfish-governor-smu.service || return 1
  if ! sudo systemctl start cyan-skillfish-governor-smu.service; then
    warn "GPU governor is enabled and will start after reboot into the BC-250 kernel"
  fi
}

step_services() {
  need install_file "$ROOT/system/bin/bc250-cu-live-manager" /usr/local/bin/bc250-cu-live-manager 755 || return 1
  need install_file "$ROOT/system/etc/bc250-cu-live-manager.conf" /etc/bc250-cu-live-manager.conf 644 || return 1
  need install_file "$ROOT/system/systemd/bc250-cu-live-manager.service" /etc/systemd/system/bc250-cu-live-manager.service 644 || return 1

  need install_file "$ROOT/system/bin/bc250-thermal-guard" /usr/local/bin/bc250-thermal-guard 755 || return 1
  need install_file "$ROOT/system/systemd/bc250-thermal-guard.service" /etc/systemd/system/bc250-thermal-guard.service 644 || return 1

  need install_file "$ROOT/system/bin/bc250_apply.py" /usr/local/lib/bc250-smu-oc/bc250_apply.py 755 || return 1
  need install_file "$ROOT/system/etc/bc250-smu-oc.conf" /etc/bc250-smu-oc.conf 644 || return 1
  need install_file "$ROOT/system/systemd/bc250-smu-oc.service" /etc/systemd/system/bc250-smu-oc.service 644 || return 1

  sudo systemctl daemon-reload
  sudo systemctl enable bc250-cu-live-manager.service || return 1
  sudo systemctl enable bc250-thermal-guard.service || return 1
  if [[ -f /usr/lib/systemd/system/bc250-cec.service || -f /etc/systemd/system/bc250-cec.service ]]; then
    sudo systemctl enable bc250-cec.service || return 1
  else
    warn "bc250-cec.service is missing, so it was not enabled"
  fi

  # Re-running the installer always leaves the CPU overclock off.
  sudo systemctl disable --now bc250-smu-oc.service || true
  log "bc250-smu-oc.service is installed and disabled. It is not started."

  sudo systemctl start bc250-cu-live-manager.service \
    || warn "CU manager is enabled and will run after reboot into the BC-250 kernel"
  sudo systemctl start bc250-thermal-guard.service \
    || warn "Thermal guard is enabled and will run after the GPU governor is up"
  if systemctl cat bc250-cec.service >/dev/null 2>&1; then
    sudo systemctl start bc250-cec.service \
      || warn "CEC service is enabled and will run after the display comes up"
  fi
}

install_theme() {
  local name=$1
  local src="${ROOT}/themes/${name}"
  local dest="${HOME}/.config/omarchy/themes/${name}"
  local backup
  [[ -d $src ]] || {
    warn "missing theme ${src}"
    return 1
  }
  mkdir -p "${HOME}/.config/omarchy/themes"
  if [[ -d $dest ]] && diff -rq "$src" "$dest" >/dev/null; then
    log "theme ${name} already matches"
    return 0
  fi
  if [[ -d $dest ]]; then
    backup="${HOME}/.local/state/omarchy-bc250-setup/theme-backups/${name}-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$(dirname "$backup")"
    cp -a "$dest" "$backup"
    log "backed up theme ${name} -> ${backup}"
  fi
  rm -rf "$dest"
  cp -a "$src" "$dest"
  log "installed theme ${name} -> ${dest}"
}

step_themes() {
  local name share
  for name in vader jedi amber-retro green-crt; do
    need install_theme "$name" || return 1
  done
  share=${HOME}/.local/share/omarchy
  if [[ -d ${share}/themes && ! -d ${share}/.git ]]; then
    for name in vader jedi amber-retro green-crt; do
      mkdir -p "${share}/themes"
      rm -rf "${share}/themes/${name}"
      cp -a "${ROOT}/themes/${name}" "${share}/themes/${name}"
      log "also copied ${name} to ${share}/themes/${name}"
    done
  else
    log "Left ${share}/themes alone. On current Omarchy that directory is a git checkout and omarchy-update replaces it."
  fi
  log "Themes are in the picker. Open Omarchy's theme menu and choose one. Nothing was switched automatically."
}

step_helper() {
  need install_file "$ROOT/bin/update-all" /usr/local/bin/update-all 755 || return 1
}

run_step "1/9 Check this Omarchy install" step_preflight
run_step "2/9 CachyOS and BC-250 package repositories" step_repos
run_step "3/9 Kernel, Mesa, CEC, dual audio, and Proton" step_packages
run_step "4/9 yay, umr, and the GPU governor" step_aur
run_step "5/9 Kernel command line, swappiness, and the fan driver" step_boot
run_step "6/9 GPU governor configuration" step_governor
run_step "7/9 CU manager, thermal guard, and CEC" step_services
run_step "8/9 Themes" step_themes
run_step "9/9 update-all helper" step_helper

cat <<'EOF'

What you do next
  1. Reboot and, if Limine does not already select it, choose the
     linux-cachyos-bc250 entry. With remember_last_entry, that choice sticks.
  2. After boot, check the kernel and the GPU:
       uname -r
       lsmod | grep nct6687
       vulkaninfo --summary
  3. In Steam, pick proton-cachyos-native-bc250 or protonge-latest-bc250
     as the compatibility tool for a game. Installing the packages does not
     change the global default.
  4. Open the Omarchy theme menu and pick Vader, Jedi, Amber Retro, or Green CRT.
  5. Leave bc250-smu-oc disabled. It changes CPU clocks and this setup never
     enables it.

Restart audio if you want the Dolby Digital sink immediately:
  systemctl --user restart pipewire pipewire-pulse wireplumber

EOF

if [[ ${#FAILED[@]} -gt 0 ]]; then
  warn "Some steps failed:"
  printf '  %s\n' "${FAILED[@]}" >&2
  exit 1
fi

log "Install finished."
