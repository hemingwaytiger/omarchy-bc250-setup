#!/usr/bin/env python3
"""Unit tests for lib/edit_configs.py. No hardware and no root required."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

import edit_configs  # noqa: E402


ARCH_CONF = """\
[options]
Architecture = auto

#[multilib]
#Include = /etc/pacman.d/mirrorlist

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
"""

PARAMS = [
    "nowatchdog",
    "systemd.zram=0",
    "ttm.pages_limit=3145728",
    "amdgpu.vm_update_mode=3",
]


def check(name: str, got: str, expected: str) -> None:
    if got != expected:
        raise SystemExit(f"{name} failed\n--- got ---\n{got}\n--- expected ---\n{expected}")
    print(f"ok {name}")


def _headers(text: str) -> list[str]:
    return [
        line.strip()
        for line in text.splitlines()
        if line.startswith("[") and not line.startswith("#")
    ]


def test_pacman() -> None:
    enabled = edit_configs.ensure_multilib(ARCH_CONF)
    assert "[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" in enabled
    assert "#[multilib]" not in enabled
    check("multilib idempotent", edit_configs.ensure_multilib(enabled), enabled)

    stacked = edit_configs.ensure_machine_repos(ARCH_CONF, v3=True)
    check(
        "v3 repo order",
        "\n".join(_headers(stacked)),
        "\n".join(
            [
                "[options]",
                "[bc250-cachyos]",
                "[cachyos-v3]",
                "[cachyos-extra-v3]",
                "[cachyos-core-v3]",
                "[cachyos]",
                "[core]",
                "[extra]",
                "[multilib]",
            ]
        ),
    )
    assert "SigLevel = Optional TrustAll" in stacked
    assert "https://github.com/MastaG/linux-cachyos-bc250/releases/download/repo" in stacked
    assert stacked.count("Include = /etc/pacman.d/cachyos-v3-mirrorlist") == 3
    check("v3 idempotent", edit_configs.ensure_machine_repos(stacked, v3=True), stacked)

    plain = edit_configs.ensure_machine_repos(stacked, v3=False)
    check(
        "plain cachyos fallback",
        "\n".join(_headers(plain)),
        "\n".join(
            [
                "[options]",
                "[bc250-cachyos]",
                "[cachyos]",
                "[core]",
                "[extra]",
                "[multilib]",
            ]
        ),
    )
    assert "[cachyos-v3]" not in plain
    assert "SigLevel = Optional TrustAll" in plain

    removed = edit_configs.remove_machine_repos(stacked)
    assert "[bc250-cachyos]" not in removed
    assert "[cachyos-v3]" not in removed
    assert "[cachyos]" not in removed
    assert "[core]" in removed
    assert "[multilib]" in removed
    print("ok pacman repo order")


def test_limine() -> None:
    created = edit_configs.ensure_limine("", PARAMS)
    assert 'KERNEL_CMDLINE[default]+="nowatchdog systemd.zram=0 ttm.pages_limit=3145728 amdgpu.vm_update_mode=3"' in created
    check("limine idempotent", edit_configs.ensure_limine(created, PARAMS), created)

    existing = 'KERNEL_CMDLINE[default]="root=UUID=abc quiet splash"\n'
    merged = edit_configs.ensure_limine(existing, PARAMS)
    assert "root=UUID=abc" in merged
    assert "quiet" in merged
    assert "ttm.pages_limit=3145728" in merged
    check("limine merge idempotent", edit_configs.ensure_limine(merged, PARAMS), merged)

    restored = edit_configs.remove_limine(merged, PARAMS)
    assert restored == 'KERNEL_CMDLINE[default]="root=UUID=abc quiet splash"\n'
    emptied = edit_configs.remove_limine(created, PARAMS)
    assert "ttm.pages_limit" not in emptied
    assert "KERNEL_CMDLINE" not in emptied
    print("ok limine remove")


def test_other_bootloaders() -> None:
    cmdline = "root=UUID=abc rw quiet\n"
    updated = edit_configs.ensure_kernel_cmdline(cmdline, PARAMS)
    assert updated.startswith("root=UUID=abc rw quiet nowatchdog ")
    assert edit_configs.remove_kernel_cmdline(updated, PARAMS) == cmdline

    grub = 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n'
    grub_updated = edit_configs.ensure_grub(grub, PARAMS)
    assert 'quiet splash nowatchdog' in grub_updated
    assert edit_configs.remove_grub(grub_updated, PARAMS) == grub

    entry = "title Arch\nlinux /vmlinuz\noptions quiet splash\n"
    boot = edit_configs.ensure_systemd_boot(entry, PARAMS)
    assert "options quiet splash nowatchdog systemd.zram=0" in boot
    assert edit_configs.remove_systemd_boot(boot, PARAMS) == entry
    unchanged = edit_configs.ensure_systemd_boot("title only\n", PARAMS)
    assert unchanged == "title only\n"
    print("ok other bootloaders")


if __name__ == "__main__":
    test_pacman()
    test_limine()
    test_other_bootloaders()
    print("all tests passed")
