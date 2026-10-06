#!/usr/bin/env python3
"""Patch a Chroma/spoti.pw IPA so Plus labels/locks do not gate features.

The IPA is a zip. This script patches the injected Frameworks/spotifyglass.dylib
in-place after extraction, then repackages the IPA. It is intentionally narrow:
it changes only the Chroma/spotifyglass tweak's Plus UI/lock methods and leaves
Spotify's own binaries and features intact.
"""
from __future__ import annotations

import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

RET = bytes.fromhex("c0035fd6")
MOV_W0_0_RET = bytes.fromhex("00008052c0035fd6")
MOV_X0_0_RET = bytes.fromhex("000080d2c0035fd6")

# Offsets are vmaddrs/file offsets in the v0.50.0 spotifyglass.dylib that ships
# in spoti.pw-0.50.0.ipa. __TEXT vmaddr == file offset in this binary.
PATCHES = [
    # Treat Plus rows as ordinary/free rows so the Plus split/badges disappear.
    (0x0DB30C, MOV_W0_0_RET, "-[SGModRow plus] -> false"),

    # Do not mark Mod pages or reorder pages as Plus-only.
    (0x0E3718, MOV_X0_0_RET, "-[SGModPage plusFeature] -> nil"),
    (0x0E5034, MOV_X0_0_RET, "-[SGOrderController plusFeature] -> nil"),

    # Central lock checks: Plus-locked pages and rows are always unlocked.
    (0x0E553C, MOV_W0_0_RET, "-[SGPage plusLocked] -> false"),
    (0x0DF4A0, MOV_W0_0_RET, "-[SGModPage locks:] -> false"),
    (0x0E3D2C, MOV_W0_0_RET, "-[SGOrderController locked] -> false"),

    # Cell-level cached lock state cannot block controls.
    (0x0DEEB4, MOV_W0_0_RET, "-[SGModSliderCell locked] -> false"),
    (0x0F3918, MOV_W0_0_RET, "-[SGDSPSliderCell locked] -> false"),

    # Do not show the Plus offer/error CTA as a blocker.
    (0x0F0694, MOV_W0_0_RET, "-[SGDSPErrorPage offeredPlus] -> false"),
]

EXPECTED_STRINGS = [
    b"SGPage",
    b"plusLocked",
    b"SGModRow",
    b"SGModPage",
    b"Chroma Plus",
]


def run(cmd: list[str], cwd: Path | None = None) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=cwd, check=True)


def patch_dylib(path: Path) -> None:
    data = bytearray(path.read_bytes())
    if data[:4] != bytes.fromhex("cffaedfe"):
        raise SystemExit(f"{path} is not a little-endian 64-bit Mach-O")
    for needle in EXPECTED_STRINGS:
        if needle not in data:
            raise SystemExit(f"safety check failed: {needle!r} not found in {path}")

    for offset, patch, note in PATCHES:
        if offset + len(patch) > len(data):
            raise SystemExit(f"patch offset out of range: 0x{offset:x}")
        original = bytes(data[offset : offset + len(patch)])
        if original == patch:
            print(f"already patched: {note} @ 0x{offset:x}")
            continue
        # Most target methods begin with either an ADRP/LDR getter or a stack-frame prologue.
        first = struct.unpack_from("<I", data, offset)[0]
        if first in (0xD65F03C0, 0x52800000, 0xD2800000):
            pass
        elif not (
            (first & 0x9F000000) == 0x90000000  # ADRP
            or (first & 0xFFC00000) == 0xB9400000  # LDR/LDUR-ish 32-bit getter forms
            or (first & 0xFFC00000) == 0x39400000  # LDRB getter forms
            or (first & 0xFFC00000) == 0xF9400000  # LDR 64-bit getter forms
            or (first & 0xFF000000) in (0xA9000000, 0xA8000000)  # STP prologue
            or (first & 0xFF000000) == 0xD1000000  # SUB SP prologue
        ):
            raise SystemExit(
                f"safety check failed at 0x{offset:x}: unexpected first instruction 0x{first:08x}"
            )
        print(f"patching {note} @ 0x{offset:x}: {original.hex()} -> {patch.hex()}")
        data[offset : offset + len(patch)] = patch

    path.write_bytes(data)


def find_app(root: Path) -> Path:
    payload = root / "Payload"
    apps = list(payload.glob("*.app"))
    if not apps:
        raise SystemExit("No Payload/*.app found in IPA")
    return apps[0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("ipa", type=Path)
    ap.add_argument("-o", "--output", type=Path, required=True)
    ap.add_argument("--no-ldid", action="store_true", help="Do not ldid-sign the patched dylib")
    args = ap.parse_args()

    ipa = args.ipa.resolve()
    out = args.output.resolve()
    if not ipa.exists():
        raise SystemExit(f"No such IPA: {ipa}")
    out.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="noplus-ipa-") as td:
        root = Path(td)
        run(["unzip", "-q", str(ipa), "-d", str(root)])
        app = find_app(root)
        dylib = app / "Frameworks" / "spotifyglass.dylib"
        if not dylib.exists():
            raise SystemExit(f"spotifyglass.dylib not found at {dylib}")

        patch_dylib(dylib)

        if not args.no_ldid and shutil.which("ldid"):
            # Re-fakesign the modified tweak dylib. Installers that use a real
            # certificate can still re-sign the whole IPA afterwards.
            run(["ldid", "-S", str(dylib)])
        elif not args.no_ldid:
            print("warning: ldid not found; leaving patched dylib for installer-side re-signing", file=sys.stderr)

        if out.exists():
            out.unlink()
        run(["zip", "-qry", str(out), "Payload"], cwd=root)
        run(["unzip", "-tq", str(out)])
        print(f"Wrote {out} ({out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
