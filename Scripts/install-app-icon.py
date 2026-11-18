#!/usr/bin/env python3
"""Install the static Wordlinks icon before signing a macOS app bundle."""

import argparse
import plistlib
import shutil
import struct
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Path to the assembled .app bundle")
    parser.add_argument(
        "--icon",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "AppResources/AppIcons/Wordlinks.icns",
        help="Static .icns source (defaults to this project's Wordlinks icon)",
    )
    args = parser.parse_args()

    try:
        if not args.icon.is_file():
            raise ValueError(f"Icon file is missing: {args.icon}")
        with args.icon.open("rb") as stream:
            header = stream.read(8)
        if (
            len(header) != 8
            or header[:4] != b"icns"
            or struct.unpack(">I", header[4:])[0] != args.icon.stat().st_size
        ):
            raise ValueError(f"Not a valid ICNS container: {args.icon}")

        contents = args.app / "Contents"
        info_path = contents / "Info.plist"
        if not info_path.is_file():
            raise ValueError(f"App Info.plist is missing: {info_path}")
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
        if not isinstance(info, dict):
            raise ValueError(f"App Info.plist must contain a dictionary: {info_path}")

        resources = contents / "Resources"
        resources.mkdir(parents=True, exist_ok=True)
        destination = resources / "Wordlinks.icns"
        shutil.copy2(args.icon, destination)
        info["CFBundleIconFile"] = destination.name
        # This installer supplies a static .icns, not a compiled native .icon.
        info.pop("CFBundleIconName", None)
        with info_path.open("wb") as stream:
            plistlib.dump(info, stream, sort_keys=False)
        # Let Finder and Icon Services notice the icon in an existing bundle.
        args.app.touch()
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"install-app-icon: {error}", file=sys.stderr)
        return 1

    print(f"Installed static Wordlinks icon: {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
