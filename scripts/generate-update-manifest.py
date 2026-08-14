#!/usr/bin/env python3
import argparse
import datetime
import hashlib
import json
from pathlib import Path


ASSETS = {
    "windows-x64": ("CLOAK_Wallet-windows-x64.zip", "windows", "x64"),
    "macos-universal": ("CLOAK_Wallet-macos-universal.zip", "macos", "universal"),
    "android-universal": ("CLOAK_Wallet.apk", "android", "universal"),
    "linux-x64": ("CLOAK_Wallet-x86_64.AppImage", "linux", "x64"),
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--parameter-generation", required=True)
    arguments = parser.parse_args()

    if arguments.tag != f"v{arguments.version}":
        raise SystemExit("tag and version disagree")
    assets = {}
    for target, (filename, platform, architecture) in ASSETS.items():
        path = arguments.directory / filename
        if not path.is_file():
            raise SystemExit(f"missing release asset: {filename}")
        assets[target] = {
            "architecture": architecture,
            "name": filename,
            "platform": platform,
            "sha256": sha256_file(path),
            "size": path.stat().st_size,
            "url": (
                f"https://github.com/{arguments.repository}/releases/download/"
                f"{arguments.tag}/{filename}"
            ),
        }

    manifest = {
        "assets": assets,
        "build": arguments.build,
        "commit": arguments.commit,
        "issuedAt": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "minimumUpdaterVersion": "2.1.0",
        "notes": f"CLOAK Wallet {arguments.version} signed release.",
        "requiredParameterGeneration": arguments.parameter_generation,
        "schema": 1,
        "tag": arguments.tag,
        "version": arguments.version,
    }
    output = arguments.directory / "update-v1.json"
    output.write_bytes(
        (json.dumps(manifest, separators=(",", ":"), sort_keys=True) + "\n").encode()
    )


if __name__ == "__main__":
    main()
