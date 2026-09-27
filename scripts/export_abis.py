#!/usr/bin/env python3
"""Export the two production ABIs, or check that the delivered copies match."""

import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    for contract in ("LaunchToken", "KudosEpochs"):
        result = subprocess.run(
            ["forge", "inspect", f"src/{contract}.sol:{contract}", "abi", "--json"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        abi = json.loads(result.stdout)
        path = root / "docs" / "abi" / f"{contract}.json"
        if args.check:
            if not path.exists() or json.loads(path.read_text()) != abi:
                raise SystemExit(f"ABI is missing or stale: {path}")
            print(f"Verified {path.name}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(abi, indent=2) + "\n")
            print(f"Exported {path.name}")


if __name__ == "__main__":
    main()
