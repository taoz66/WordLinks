#!/usr/bin/env python3
"""Compile and install a native layered icon when a capable actool is available.

Run after the static icon installer and before code signing. The existing static
icon is retained as the honest fallback. Set WORDLINKS_ACTOOL to select a newer
actool without changing the global Xcode selection. A successful exit from an old
actool is insufficient: installation requires a real BOM asset catalog plus
matching compiler-produced icon metadata.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MARKER = "WordlinksNativeLayeredIcon"


def find_actool(override: str | None) -> Path | None:
    if override:
        selected = Path(override).expanduser()
        if not selected.is_file() or not os.access(selected, os.X_OK):
            raise ValueError(f"WORDLINKS_ACTOOL is not an executable file: {selected}")
        return selected
    result = subprocess.run(["/usr/bin/xcrun", "--find", "actool"], capture_output=True, text=True)
    if result.returncode == 0 and result.stdout.strip():
        selected = Path(result.stdout.strip())
        if selected.is_file():
            return selected
    return None


def write_info(path: Path, info: dict) -> None:
    with path.open("wb") as stream:
        plistlib.dump(info, stream, sort_keys=False)


def compile_icon(tool: Path, source: Path, destination: Path, deployment: str) -> dict:
    partial = destination / "icon-info.plist"
    result = subprocess.run([
        str(tool), str(source), "--compile", str(destination),
        "--platform", "macosx", "--minimum-deployment-target", deployment,
        "--app-icon", source.stem, "--output-partial-info-plist", str(partial),
        "--output-format", "human-readable-text", "--warnings", "--notices",
    ], capture_output=True, text=True, timeout=120)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise ValueError(f"actool failed ({result.returncode}): {detail[-2500:]}")
    catalog = destination / "Assets.car"
    if not catalog.is_file() or catalog.stat().st_size < 128:
        raise ValueError("actool did not produce a compiled Assets.car; native .icon support was not confirmed")
    with catalog.open("rb") as stream:
        if stream.read(8) != b"BOMStore":
            raise ValueError("Assets.car is not a recognized binary asset catalog")
    if not partial.is_file():
        raise ValueError("actool did not produce icon metadata")
    with partial.open("rb") as stream:
        info = plistlib.load(stream)
    if not isinstance(info, dict) or info.get("CFBundleIconName") != source.stem:
        raise ValueError("compiler metadata does not identify the expected native icon")
    return info


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--source", type=Path, default=ROOT / "AppResources/AppIcons/Wordlinks.icon")
    parser.add_argument("--actool", default=os.environ.get("WORDLINKS_ACTOOL"))
    parser.add_argument("--require-native", action="store_true", help="Fail instead of accepting static fallback")
    args = parser.parse_args()
    info_path = args.app / "Contents/Info.plist"
    if not info_path.is_file():
        parser.error(f"App Info.plist does not exist: {info_path}")
    with info_path.open("rb") as stream:
        app_info = plistlib.load(stream)
    if not isinstance(app_info, dict):
        parser.error("App Info.plist is not a dictionary")
    resources = args.app / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    try:
        if not (args.source / "icon.json").is_file():
            raise ValueError(f"Icon Composer document is missing: {args.source}")
        tool = find_actool(args.actool)
        if tool is None:
            raise ValueError("no actool was found; set WORDLINKS_ACTOOL to a compiler supporting Icon Composer")
        existing = resources / "Assets.car"
        if existing.exists() and not app_info.get(MARKER, False):
            raise ValueError("an unrelated Assets.car already exists; compile icon and other assets together before installation")
        with tempfile.TemporaryDirectory(prefix="wordlinks-native-icon-") as temporary:
            output = Path(temporary)
            compiled_info = compile_icon(tool, args.source, output, str(app_info.get("LSMinimumSystemVersion", "14.0")))
            # Only install verified compiler output. Keep the static fallback for
            # older systems and preserve unrelated bundle metadata.
            for item in output.iterdir():
                if item.is_file() and item.suffix in (".car", ".icns"):
                    shutil.copy2(item, resources / item.name)
            for key, value in compiled_info.items():
                if key.startswith("CFBundleIcon"):
                    app_info[key] = value
            app_info[MARKER] = True
            write_info(info_path, app_info)
        args.app.touch()
        print(f"Installed verified native layered icon with {tool}: {resources / 'Assets.car'}")
        return 0
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.TimeoutExpired) as error:
        # A native-success marker is never retained for an unverified build.
        app_info[MARKER] = False
        if app_info.get("CFBundleIconName") == args.source.stem:
            app_info.pop("CFBundleIconName", None)
        write_info(info_path, app_info)
        print(f"Native layered icon unavailable: {error}", file=sys.stderr)
        print("Using static Apple-rendered light/dark Dock icons; native layered compilation did not succeed.")
        return 1 if args.require_native else 0


if __name__ == "__main__":
    raise SystemExit(main())
