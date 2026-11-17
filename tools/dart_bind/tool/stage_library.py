#!/usr/bin/env python3
"""Stage compiled NeuG libraries in the SDK target directory.

This tool does not require a host Dart native library.
"""

import argparse
import json
import shutil
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "target",
        choices=[
            "android_arm64",
            "android_x64",
            "ios_arm64_device",
            "ios_arm64_simulator",
            "ios_x64_simulator",
            "macos_arm64",
            "macos_x64",
            "linux_arm64",
            "linux_x64",
        ],
    )
    parser.add_argument(
        "library",
        type=Path,
        help="Path to libneug matching the current C API",
    )
    parser.add_argument(
        "dependencies", type=Path, nargs="*", help="Companion shared libraries"
    )
    args = parser.parse_args()
    if args.target.startswith(("android_", "linux_")):
        suffix = ".so"
    else:
        suffix = ".dylib"
    sources = [args.library, *args.dependencies]
    names = [
        "libneug" + suffix,
        *(source.name for source in args.dependencies),
    ]
    if len(set(names)) != len(names):
        parser.error("Duplicate shared library filenames")
    for source in sources:
        if not source.is_file():
            parser.error(f"File not found: {source}")
        if source.suffix != suffix:
            parser.error(f"{args.target} requires {suffix}: {source}")
    directory = Path(__file__).resolve().parent.parent / "native" / args.target
    directory.mkdir(parents=True, exist_ok=True)
    for source, name in zip(sources, names):
        destination = directory / name
        if source.resolve() != destination.resolve():
            shutil.copy2(source, destination)
    # List only dependencies supplied in this invocation.
    # Stale files are not bundled.
    (directory / "libraries.json").write_text(
        json.dumps(names),
        encoding="utf-8",
    )
    print(f"Native libraries staged in: {directory}")


if __name__ == "__main__":
    main()
