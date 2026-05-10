#!/usr/bin/env python3
"""Visual gate for rollout.mp4 files.

Validates that a rollout video is a real IsaacLab render (not a broken
mp4v or solid-colour frame dump):

  - codec is h264
  - pix_fmt is yuv420p
  - first two mp4 atoms are ['ftyp', 'moov']  (faststart applied)
  - N evenly-spaced sample frames each have
        pixel_stddev > stddev_min  AND  unique_colors > unique_min

Emits a JSON verdict to stdout and returns exit code 0 (PASS) / 1 (FAIL).

Extracted from bl-p0txht's inline reviewer gate (accepted 2026-05-02).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import struct
import subprocess
import sys
from pathlib import Path


# --- ffprobe / ffmpeg helpers ------------------------------------------------

def _ffprobe_stream(video_in: Path) -> dict:
    """Return the first video stream's JSON dict."""
    out = subprocess.run(
        [
            "ffprobe", "-v", "error",
            "-select_streams", "v:0",
            "-show_streams", "-show_format",
            "-print_format", "json",
            str(video_in),
        ],
        check=True, capture_output=True, text=True,
    ).stdout
    data = json.loads(out)
    if not data.get("streams"):
        raise RuntimeError(f"ffprobe found no video stream in {video_in}")
    return data


def _first_atoms(video_in: Path, n_atoms: int = 2, scan_bytes: int = 256) -> list:
    """Return the first N atom tags from the file's box chain.

    MP4/MOV file = concatenation of atoms, each [size:4 BE][tag:4 ASCII]...
    A faststart mp4 has 'ftyp' then 'moov' before 'mdat'.
    """
    with open(video_in, "rb") as f:
        buf = f.read(scan_bytes)
    tags: list = []
    i = 0
    while i + 8 <= len(buf) and len(tags) < n_atoms:
        (size,) = struct.unpack(">I", buf[i:i + 4])
        tag_bytes = buf[i + 4:i + 8]
        try:
            tag = tag_bytes.decode("ascii")
        except UnicodeDecodeError:
            break
        if not all(32 <= ord(c) < 127 for c in tag):
            break
        tags.append(tag)
        if size == 1:
            # 64-bit extended size follows
            if i + 16 > len(buf):
                break
            (size64,) = struct.unpack(">Q", buf[i + 8:i + 16])
            if size64 < 16:
                break
            i += size64
        elif size == 0:
            # runs to EOF
            break
        else:
            if size < 8:
                break
            i += size
    return tags


def _frame_count(stream: dict) -> int:
    """Best-effort frame count with fallback chain."""
    for key in ("nb_read_frames", "nb_frames"):
        val = stream.get(key)
        if val and val != "N/A":
            try:
                return int(val)
            except ValueError:
                pass
    # fallback: duration * avg_frame_rate
    dur = stream.get("duration")
    afr = stream.get("avg_frame_rate")
    if dur and afr and afr != "0/0":
        try:
            num, den = afr.split("/")
            fps = float(num) / float(den) if float(den) else 0.0
            return int(round(float(dur) * fps))
        except (ValueError, ZeroDivisionError):
            pass
    raise RuntimeError("ffprobe did not return a usable frame count")


def _extract_frame_png(video_in: Path, frame_idx: int, out_png: Path) -> None:
    """Extract a single frame by index using the ffmpeg select filter."""
    out_png.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "ffmpeg", "-y", "-loglevel", "error",
            "-i", str(video_in),
            "-vf", f"select=eq(n\\,{frame_idx})",
            "-vsync", "0",
            "-frames:v", "1",
            str(out_png),
        ],
        check=True,
    )


# --- labeling -----------------------------------------------------------------

def _idx_label(i: int, n: int) -> object:
    """Return the human label for sample i of n.

    For N=4 this produces bl-p0txht's labels [0, 'T/4', 'T/2', '3T/4'];
    for other N we fall back to 'i/N' strings.
    """
    if i == 0:
        return 0
    # reduce i/n
    from math import gcd
    g = gcd(i, n)
    num, den = i // g, n // g
    if den == 1:
        return f"{num}T"
    return f"{num}T/{den}" if num != 1 else f"T/{den}"


# --- main --------------------------------------------------------------------

def main(argv: list | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--video_in", required=True, type=Path)
    ap.add_argument("--num_samples", type=int, default=4)
    ap.add_argument("--stddev_min", type=float, default=15.0)
    ap.add_argument("--unique_min", type=int, default=1000)
    ap.add_argument("--dump_frames_to", type=Path, default=None)
    args = ap.parse_args(argv)

    # Defer numpy/PIL imports until after arg parsing so --help is fast and
    # exceptions from missing deps don't mask a simple misuse.
    import numpy as np
    from PIL import Image

    # ffprobe version sanity (plan: fail loud if < 4.x).
    ver_out = subprocess.run(
        ["ffprobe", "-version"], check=True, capture_output=True, text=True,
    ).stdout.splitlines()[0]
    m = re.search(r"ffprobe version (\d+)", ver_out)
    if not m or int(m.group(1)) < 4:
        raise RuntimeError(f"ffprobe >= 4.x required, found: {ver_out}")

    probe = _ffprobe_stream(args.video_in)
    stream = probe["streams"][0]
    codec = stream.get("codec_name", "")
    pix_fmt = stream.get("pix_fmt", "")
    total_frames = _frame_count(stream)
    first_atoms = _first_atoms(args.video_in)

    failures: list = []
    if codec != "h264":
        failures.append(f"codec:{codec} != h264")
    if pix_fmt != "yuv420p":
        failures.append(f"pix_fmt:{pix_fmt} != yuv420p")
    if first_atoms[:2] != ["ftyp", "moov"]:
        failures.append(f"faststart:first_atoms={first_atoms} != ['ftyp', 'moov']")

    # Sample indices: [i * T // N for i in range(N)] matches bl-p0txht's
    # [0, T/4, T/2, 3T/4] for N=4.
    n = args.num_samples
    sample_indices = [i * total_frames // n for i in range(n)]

    frame_stats: list = []
    tmp_dir = args.dump_frames_to
    if tmp_dir is None:
        import tempfile
        tmp_dir = Path(tempfile.mkdtemp(prefix="check_rollout_visual_"))
        cleanup_tmp = True
    else:
        tmp_dir = Path(tmp_dir)
        tmp_dir.mkdir(parents=True, exist_ok=True)
        cleanup_tmp = False

    try:
        for i, idx in enumerate(sample_indices):
            label = _idx_label(i, n)
            png = tmp_dir / f"frame_{idx}.png"
            _extract_frame_png(args.video_in, idx, png)
            arr = np.asarray(Image.open(png).convert("RGB"))
            pixel_stddev = float(arr.std())
            unique_colors = int(
                len(np.unique(arr.reshape(-1, arr.shape[-1]), axis=0))
            )
            passes_stddev = pixel_stddev > args.stddev_min
            passes_unique = unique_colors > args.unique_min
            passes = bool(passes_stddev and passes_unique)
            frame_stats.append({
                "idx": label,
                "frame_index": idx,
                "pixel_stddev": round(pixel_stddev, 2),
                "unique_colors": unique_colors,
                "passes": passes,
            })
            if not passes_unique:
                failures.append(
                    f"frame_{idx}:unique_colors={unique_colors} < {args.unique_min}"
                )
            if not passes_stddev:
                failures.append(
                    f"frame_{idx}:pixel_stddev={pixel_stddev:.2f} < {args.stddev_min}"
                )
    finally:
        if cleanup_tmp:
            for f in tmp_dir.glob("*.png"):
                try:
                    f.unlink()
                except OSError:
                    pass
            try:
                tmp_dir.rmdir()
            except OSError:
                pass

    verdict = "PASS" if not failures else "FAIL"
    result = {
        "video_in": str(args.video_in),
        "video_codec": codec,
        "video_pix_fmt": pix_fmt,
        "video_container_faststart_first_atoms": first_atoms[:2],
        "video_frames": total_frames,
        "thresholds": {
            "num_samples": n,
            "stddev_min": args.stddev_min,
            "unique_min": args.unique_min,
        },
        "frame_stats": frame_stats,
        "failures": failures,
        "verdict": verdict,
    }
    print(json.dumps(result, indent=2))
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
