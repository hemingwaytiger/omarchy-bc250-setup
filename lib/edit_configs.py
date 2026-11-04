#!/usr/bin/env python3
"""Idempotent edits for pacman.conf and bootloader command lines.

The installer writes the result to a temporary file and installs it only when
the bytes change. Run the unit tests with: python3 tests/test_edits.py
"""

from __future__ import annotations

import re
import sys

MANAGED_COMMENT = "# managed-by: omarchy-bc250-setup"

BC250_BLOCK = (
    "[bc250-cachyos]\n"
    "SigLevel = Optional TrustAll\n"
    "Server = https://github.com/MastaG/linux-cachyos-bc250/releases/download/repo\n"
    "\n"
)

# Order matches the working machine (reference/pacman.conf.txt):
# v3, extra-v3, core-v3, then the generic cachyos repo.
# The v3 mirrorlist expands $repo, so each v3 section includes that file.
V3_REPOS = (
    "[cachyos-v3]\n"
    "Include = /etc/pacman.d/cachyos-v3-mirrorlist\n"
    "\n"
    "[cachyos-extra-v3]\n"
    "Include = /etc/pacman.d/cachyos-v3-mirrorlist\n"
    "\n"
    "[cachyos-core-v3]\n"
    "Include = /etc/pacman.d/cachyos-v3-mirrorlist\n"
    "\n"
    "[cachyos]\n"
    "Include = /etc/pacman.d/cachyos-mirrorlist\n"
    "\n"
)

PLAIN_CACHYOS = (
    "[cachyos]\n"
    "Include = /etc/pacman.d/cachyos-mirrorlist\n"
    "\n"
)

CACHYOS_SECTIONS = (
    "cachyos-v3",
    "cachyos-extra-v3",
    "cachyos-core-v3",
    "cachyos",
)

ARCH_ANCHORS = ("core", "extra", "multilib")


def _section_name(line: str) -> str | None:
    match = re.match(r"^\[([^]]+)\]\s*$", line.strip())
    if match is None:
        return None
    return match.group(1)


def strip_sections(text: str, names: set[str]) -> str:
    lines = text.splitlines(keepends=True)
    kept: list[str] = []
    skipping = False
    for line in lines:
        header = _section_name(line)
        if header is not None:
            skipping = header in names
        if not skipping:
            kept.append(line)
    return "".join(kept)


def insert_before(text: str, block: str, anchors: tuple[str, ...]) -> str:
    if not block.endswith("\n"):
        block += "\n"
    lines = text.splitlines(keepends=True)
    for index, line in enumerate(lines):
        header = _section_name(line)
        if header in anchors:
            return "".join(lines[:index]) + block + "".join(lines[index:])
    if text and not text.endswith("\n"):
        text += "\n"
    return text + block


def extract_section(text: str, name: str) -> tuple[str, str]:
    lines = text.splitlines(keepends=True)
    kept: list[str] = []
    section: list[str] = []
    taking = False
    for line in lines:
        header = _section_name(line)
        if header is not None:
            taking = header == name
        if taking:
            section.append(line)
        else:
            kept.append(line)
    return "".join(kept), "".join(section)


def insert_after_section(text: str, after_name: str, block: str) -> str:
    if not block.endswith("\n"):
        block += "\n"
    lines = text.splitlines(keepends=True)
    start = None
    for index, line in enumerate(lines):
        if _section_name(line) == after_name:
            start = index
            break
    if start is None:
        if text and not text.endswith("\n"):
            text += "\n"
        return text + block
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if _section_name(lines[index]) is not None:
            end = index
            break
    return "".join(lines[:end]) + block + "".join(lines[end:])


def ensure_machine_repos(text: str, v3: bool) -> str:
    """Repos in the working machine's order, with multilib enabled.

    v3 selects cachyos-v3, cachyos-extra-v3, cachyos-core-v3 and cachyos.
    Otherwise only the generic cachyos repo is added. bc250-cachyos is always
    first. core, extra and multilib stay below those sections, in that order.
    """
    text = strip_sections(text, {"bc250-cachyos", *CACHYOS_SECTIONS})
    text = ensure_multilib(text)
    text, multilib = extract_section(text, "multilib")
    block = BC250_BLOCK + (V3_REPOS if v3 else PLAIN_CACHYOS)
    text = insert_before(text, block, ("core", "extra"))
    if not multilib:
        return text
    if not multilib.endswith("\n"):
        multilib += "\n"
    if "[extra]" in text:
        return insert_after_section(text, "extra", multilib)
    if "[core]" in text:
        return insert_after_section(text, "core", multilib)
    return text + multilib


def remove_machine_repos(text: str) -> str:
    return strip_sections(text, {"bc250-cachyos", *CACHYOS_SECTIONS})


def ensure_multilib(text: str) -> str:
    if re.search(r"(?m)^\[multilib\]\s*$", text):
        return text
    pattern = re.compile(
        r"(?m)^#[ \t]*\[multilib\][ \t]*\n"
        r"#[ \t]*Include[ \t]*=[ \t]*/etc/pacman\.d/mirrorlist[ \t]*$"
    )
    if pattern.search(text):
        return pattern.sub(
            "[multilib]\nInclude = /etc/pacman.d/mirrorlist",
            text,
            count=1,
        )
    if text and not text.endswith("\n"):
        text += "\n"
    return text + "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n"


def _split_nl(line: str) -> tuple[str, str]:
    if line.endswith("\n"):
        return line[:-1], "\n"
    return line, ""


def _add_tokens(value: str, params: list[str]) -> str:
    tokens = value.split()
    for param in params:
        if param not in tokens:
            tokens.append(param)
    return " ".join(tokens)


def _remove_tokens(value: str, params: list[str]) -> str:
    drop = set(params)
    return " ".join(token for token in value.split() if token not in drop)


def _parse_limine(body: str) -> tuple[str, str] | None:
    match = re.match(r"^(KERNEL_CMDLINE\[default\]\+?=)(.*)$", body)
    if match is None:
        return None
    raw = match.group(2).strip()
    if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
        raw = raw[1:-1]
    return match.group(1), raw


def _format_limine(operator: str, value: str) -> str:
    return f'{operator}"{value}"'


def ensure_limine(text: str, params: list[str]) -> str:
    lines = text.splitlines(keepends=True)
    for index, line in enumerate(lines):
        body, newline = _split_nl(line)
        parsed = _parse_limine(body)
        if parsed is None:
            continue
        operator, value = parsed
        lines[index] = _format_limine(operator, _add_tokens(value, params)) + (
            newline or "\n"
        )
        return "".join(lines)
    block = (
        MANAGED_COMMENT
        + "\n"
        + _format_limine("KERNEL_CMDLINE[default]+=", " ".join(params))
        + "\n"
    )
    if text and not text.endswith("\n"):
        text += "\n"
    if text.strip():
        if not text.endswith("\n\n"):
            text += "\n"
    return text + block


def remove_limine(text: str, params: list[str]) -> str:
    lines = text.splitlines(keepends=True)
    output: list[str] = []
    index = 0
    while index < len(lines):
        body, newline = _split_nl(lines[index])
        if body.strip() == MANAGED_COMMENT and index + 1 < len(lines):
            next_body, next_nl = _split_nl(lines[index + 1])
            parsed = _parse_limine(next_body)
            if parsed is not None:
                operator, value = parsed
                updated = _remove_tokens(value, params)
                if updated == "":
                    index += 2
                    continue
                output.append(lines[index])
                output.append(_format_limine(operator, updated) + (next_nl or "\n"))
                index += 2
                continue
        parsed = _parse_limine(body)
        if parsed is not None:
            operator, value = parsed
            updated = _remove_tokens(value, params)
            if updated == "":
                index += 1
                continue
            output.append(_format_limine(operator, updated) + (newline or "\n"))
            index += 1
            continue
        output.append(lines[index])
        index += 1
    return "".join(output)


def _rewrite_first_payload(text: str, params: list[str], remove: bool) -> str:
    lines = text.splitlines(keepends=True)
    done = False
    output: list[str] = []
    for line in lines:
        body, newline = _split_nl(line)
        stripped = body.strip()
        if not done and stripped and not stripped.startswith("#"):
            updated = _remove_tokens(stripped, params) if remove else _add_tokens(stripped, params)
            if updated == "":
                done = True
                continue
            output.append(updated + (newline or "\n"))
            done = True
            continue
        output.append(line)
    if done or remove:
        return "".join(output)
    extra = " ".join(params) + "\n"
    if text and not text.endswith("\n"):
        text += "\n"
    return text + extra


def ensure_kernel_cmdline(text: str, params: list[str]) -> str:
    return _rewrite_first_payload(text, params, remove=False)


def remove_kernel_cmdline(text: str, params: list[str]) -> str:
    return _rewrite_first_payload(text, params, remove=True)


def _rewrite_grub(text: str, params: list[str], remove: bool) -> str:
    lines = text.splitlines(keepends=True)
    found = False
    output: list[str] = []
    for line in lines:
        body, newline = _split_nl(line)
        match = re.match(r"^GRUB_CMDLINE_LINUX_DEFAULT=(.*)$", body)
        if match and not found:
            found = True
            raw = match.group(1).strip()
            if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
                raw = raw[1:-1]
            updated = _remove_tokens(raw, params) if remove else _add_tokens(raw, params)
            output.append(f'GRUB_CMDLINE_LINUX_DEFAULT="{updated}"' + (newline or "\n"))
            continue
        output.append(line)
    if found or remove:
        return "".join(output)
    if text and not text.endswith("\n"):
        text += "\n"
    return text + 'GRUB_CMDLINE_LINUX_DEFAULT="' + " ".join(params) + '"\n'


def ensure_grub(text: str, params: list[str]) -> str:
    return _rewrite_grub(text, params, remove=False)


def remove_grub(text: str, params: list[str]) -> str:
    return _rewrite_grub(text, params, remove=True)


def _rewrite_systemd_boot(text: str, params: list[str], remove: bool) -> str:
    lines = text.splitlines(keepends=True)
    found = False
    output: list[str] = []
    for line in lines:
        body, newline = _split_nl(line)
        match = re.match(r"^options(\s+)(.*)$", body)
        if match and not found:
            found = True
            updated = (
                _remove_tokens(match.group(2), params)
                if remove
                else _add_tokens(match.group(2), params)
            )
            if updated == "":
                output.append("options" + (newline or "\n"))
            else:
                output.append("options " + updated + (newline or "\n"))
            continue
        output.append(line)
    return "".join(output)


def ensure_systemd_boot(text: str, params: list[str]) -> str:
    return _rewrite_systemd_boot(text, params, remove=False)


def remove_systemd_boot(text: str, params: list[str]) -> str:
    return _rewrite_systemd_boot(text, params, remove=True)


def _ensure_machine_repos(text: str, params: list[str]) -> str:
    if len(params) != 1 or params[0] not in {"v3", "plain"}:
        raise ValueError("ensure-machine-repos requires 'v3' or 'plain'")
    return ensure_machine_repos(text, params[0] == "v3")


COMMANDS = {
    "ensure-machine-repos": _ensure_machine_repos,
    "ensure-multilib": lambda text, _params: ensure_multilib(text),
    "remove-machine-repos": lambda text, _params: remove_machine_repos(text),
    "ensure-limine": ensure_limine,
    "remove-limine": remove_limine,
    "ensure-kernel-cmdline": ensure_kernel_cmdline,
    "remove-kernel-cmdline": remove_kernel_cmdline,
    "ensure-grub": ensure_grub,
    "remove-grub": remove_grub,
    "ensure-systemd-boot": ensure_systemd_boot,
    "remove-systemd-boot": remove_systemd_boot,
}


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print(
            "usage: edit_configs.py <command> <src> <dest> [param ...]",
            file=sys.stderr,
        )
        return 2
    command, src, dest = argv[1], argv[2], argv[3]
    params = argv[4:]
    if command not in COMMANDS:
        print(f"unknown command: {command}", file=sys.stderr)
        return 2
    with open(src, encoding="utf-8") as handle:
        text = handle.read()
    try:
        updated = COMMANDS[command](text, params)
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 2
    with open(dest, "w", encoding="utf-8") as handle:
        handle.write(updated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
