#!/usr/bin/env python3
"""
Convert AutoEQ ParametricEQ.txt files into a single JSON bundle for FineTune.

Usage:
    python3 Scripts/convert-autoeq-profiles.py /path/to/AutoEQ/results \
        -o FineTune/Resources/AutoEQ-Profiles.json

Supports both flat and nested directory structures:
    results/<headphone>/ParametricEQ.txt
    results/<source>/<rig>/<headphone>/ParametricEQ.txt

Each ParametricEQ.txt is in EqualizerAPO format:
    Preamp: -6.2 dB
    Filter 1: ON PK Fc 100 Hz Gain -2.3 dB Q 1.41
    ...
"""
import argparse
import json
import os
import re
import sys


def slugify(name: str) -> str:
    return re.sub(r"[^a-z0-9-]", "", name.lower().replace(" ", "-"))


def parse_filter_line(line: str) -> dict | None:
    tokens = line.split()
    if "ON" not in [t.upper() for t in tokens]:
        return None

    filter_type = None
    for t in tokens:
        upper = t.upper()
        if upper in ("PK", "PEQ"):
            filter_type = "peaking"
        elif upper in ("LS", "LSC"):
            filter_type = "lowShelf"
        elif upper in ("HS", "HSC"):
            filter_type = "highShelf"
    if not filter_type:
        return None

    def extract(keyword):
        for i, t in enumerate(tokens):
            if t.upper() == keyword.upper() and i + 1 < len(tokens):
                try:
                    return float(tokens[i + 1])
                except ValueError:
                    return None
        return None

    freq = extract("Fc")
    gain = extract("Gain")
    q = extract("Q")

    if freq is None or gain is None or q is None:
        return None
    if freq <= 0 or q <= 0 or abs(gain) > 30:
        return None

    return {
        "type": filter_type,
        "frequency": freq,
        "gainDB": gain,
        "q": q,
    }


def parse_file(path: str, name: str) -> dict | None:
    preamp = 0.0
    filters = []

    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.lower().startswith("preamp:"):
                parts = line.split(":")[1].split()
                if parts:
                    try:
                        preamp = float(parts[0])
                    except ValueError:
                        pass
            elif line.lower().startswith("filter"):
                filt = parse_filter_line(line)
                if filt:
                    filters.append(filt)

    if not filters:
        return None

    filters = filters[:10]  # maxFilters

    return {
        "id": slugify(name),
        "name": name,
        "source": "bundled",
        "preampDB": preamp,
        "filters": filters,
    }


def find_parametric_eq_files(input_dir: str) -> list[tuple[str, str]]:
    """Recursively find all ParametricEQ.txt files.

    Returns list of (file_path, headphone_name) tuples.
    The headphone name is the immediate parent directory name.
    """
    results = []
    for root, _dirs, files in os.walk(input_dir):
        for fname in files:
            if fname.endswith("ParametricEQ.txt"):
                filepath = os.path.join(root, fname)
                headphone_name = os.path.basename(root)
                results.append((filepath, headphone_name))
    return sorted(results, key=lambda x: x[1].lower())


def main():
    parser = argparse.ArgumentParser(description="Convert AutoEQ profiles to JSON bundle")
    parser.add_argument("input_dir", help="Path to AutoEQ results directory")
    parser.add_argument("-o", "--output", default="FineTune/Resources/AutoEQ-Profiles.json",
                        help="Output JSON file path")
    parser.add_argument("--max", type=int, default=0,
                        help="Maximum number of profiles (0 = unlimited)")
    args = parser.parse_args()

    if not os.path.isdir(args.input_dir):
        print(f"Error: {args.input_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    profiles = []
    seen_ids = set()
    collisions = 0

    for filepath, headphone_name in find_parametric_eq_files(args.input_dir):
        profile = parse_file(filepath, headphone_name)
        if not profile:
            continue

        # Handle slug collisions by appending a numeric suffix
        base_id = profile["id"]
        unique_id = base_id
        suffix = 2
        while unique_id in seen_ids:
            unique_id = f"{base_id}-{suffix}"
            suffix += 1
            collisions += 1
        profile["id"] = unique_id

        profiles.append(profile)
        seen_ids.add(unique_id)

        if args.max > 0 and len(profiles) >= args.max:
            break

    if collisions:
        print(f"Resolved {collisions} slug collision(s)", file=sys.stderr)

    profiles.sort(key=lambda p: p["name"].lower())

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(profiles, f, separators=(",", ":"), ensure_ascii=False)

    print(f"Wrote {len(profiles)} profiles to {args.output}")


if __name__ == "__main__":
    main()
