#!/usr/bin/env bash
# Shared helpers for install.sh and uninstall.sh.

if [[ -z ${ROOT:-} ]]; then
  ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fi

log() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need() {
  "$@"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "command failed (${rc}): $*"
  fi
  return "$rc"
}

backup_file() {
  local file=$1
  local stamp dest
  [[ -e $file ]] || return 0
  stamp=$(date +%Y%m%d-%H%M%S)
  dest="${file}.bak-${stamp}"
  if [[ -e $dest ]]; then
    dest="${dest}-$$"
  fi
  sudo cp -a "$file" "$dest"
  log "backed up ${file} -> ${dest}"
}

install_file() {
  local src=$1
  local dest=$2
  local mode=${3:-644}
  if [[ ! -f $src ]]; then
    warn "missing source file ${src}"
    return 1
  fi
  if [[ -f $dest ]] && cmp -s "$src" "$dest"; then
    log "unchanged ${dest}"
    return 0
  fi
  if [[ -e $dest ]]; then
    backup_file "$dest"
  fi
  sudo install -D -m "$mode" "$src" "$dest"
  log "installed ${dest}"
}

apply_text_file() {
  local dest=$1
  shift
  local tmp input
  tmp=$(mktemp)
  if [[ -f $dest ]]; then
    input=$dest
  else
    input=/dev/null
  fi
  if ! python3 "$ROOT/lib/edit_configs.py" "$@" "$input" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [[ -f $dest ]] && cmp -s "$dest" "$tmp"; then
    log "unchanged ${dest}"
    rm -f "$tmp"
    return 0
  fi
  if [[ -f $dest ]]; then
    backup_file "$dest"
  fi
  sudo install -D -m 644 "$tmp" "$dest"
  rm -f "$tmp"
  log "updated ${dest}"
}

load_base_params() {
  BASE_PARAMS=()
  local line
  while IFS= read -r line || [[ -n ${line:-} ]]; do
    [[ -z $line || $line == \#* ]] && continue
    BASE_PARAMS+=("$line")
  done < "$ROOT/system/cmdline/params.txt"
}

cpu_supports_v3() {
  local ldso=/lib/ld-linux-x86-64.so.2
  local help
  [[ -x $ldso ]] || return 1
  help=$("$ldso" --help 2>/dev/null || true)
  [[ $help == *"x86-64-v3 (supported, searched)"* ]]
}

bootloader_name() {
  if command -v limine-update >/dev/null 2>&1 \
    || command -v limine-mkinitcpio >/dev/null 2>&1 \
    || [[ -d /etc/limine-entry-tool.d ]]; then
    printf 'limine\n'
    return 0
  fi
  if [[ -d /boot/loader/entries ]]; then
    printf 'systemd-boot\n'
    return 0
  fi
  if [[ -f /etc/default/grub ]]; then
    printf 'grub\n'
    return 0
  fi
  printf 'unknown\n'
}
