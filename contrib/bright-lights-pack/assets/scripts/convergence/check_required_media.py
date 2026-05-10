#!/usr/bin/env python3
"""Validate required run media for convergence gates.

This is intentionally generic. Some rigs produce IsaacLab h264/faststart
rollouts, while MJX/MuJoCo often writes small mpeg4 mp4s. For gate purposes we
need to know whether required media exists, decodes, and contains non-blank
frames; codec packaging is a rig-specific reviewer concern.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path


VIDEO_EXTS = {".mp4", ".webm", ".gif", ".mov", ".mkv"}
IMAGE_EXTS = {".png", ".jpg", ".jpeg"}


def ffprobe(video: Path) -> dict:
    out = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_streams",
            "-show_format",
            "-print_format",
            "json",
            str(video),
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    data = json.loads(out)
    if not data.get("streams"):
        raise RuntimeError("no video stream")
    return data


def frame_count(stream: dict) -> int:
    for key in ("nb_read_frames", "nb_frames"):
        val = stream.get(key)
        if val and val != "N/A":
            try:
                return int(val)
            except ValueError:
                pass
    duration = stream.get("duration")
    rate = stream.get("avg_frame_rate")
    if duration and rate and rate != "0/0":
        num, den = rate.split("/")
        fps = float(num) / float(den)
        return max(1, int(round(float(duration) * fps)))
    raise RuntimeError("no usable frame count")


def extract_frame(video: Path, index: int, output: Path) -> None:
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-i",
            str(video),
            "-vf",
            f"select=eq(n\\,{index})",
            "-vsync",
            "0",
            "-frames:v",
            "1",
            str(output),
        ],
        check=True,
    )


def extract_frame_ppm(video: Path, index: int) -> tuple[int, int, bytes]:
    out = subprocess.run(
        [
            "ffmpeg",
            "-loglevel",
            "error",
            "-i",
            str(video),
            "-vf",
            f"select=eq(n\\,{index})",
            "-vsync",
            "0",
            "-frames:v",
            "1",
            "-f",
            "image2pipe",
            "-vcodec",
            "ppm",
            "-",
        ],
        check=True,
        capture_output=True,
    ).stdout
    marker = b"\n255\n"
    header_end = out.find(marker)
    if not out.startswith(b"P6\n") or header_end < 0:
        raise RuntimeError("ffmpeg did not produce a binary PPM frame")
    header = out[:header_end].decode("ascii").split()
    if len(header) < 3:
        raise RuntimeError("malformed PPM header")
    width = int(header[1])
    height = int(header[2])
    pixels = out[header_end + len(marker):]
    expected = width * height * 3
    if len(pixels) < expected:
        raise RuntimeError(f"short PPM frame: got {len(pixels)}, expected {expected}")
    return width, height, pixels[:expected]


def pixel_stats(rgb: bytes) -> tuple[float, int]:
    n = len(rgb)
    if n == 0:
        return 0.0, 0
    total = sum(rgb)
    total_sq = sum(v * v for v in rgb)
    mean = total / n
    variance = max(0.0, total_sq / n - mean * mean)
    unique = len({rgb[i:i + 3] for i in range(0, len(rgb), 3)})
    return variance ** 0.5, unique


def foreground_signal_pct(rgb: bytes) -> float:
    """Approximate visible non-ground foreground in MuJoCo/Isaac videos.

    The usual blank-render failure still has high variance because the ground
    grid is visible. Humanoid/robot bodies in our videos contribute a much
    larger bright-neutral foreground than the blue/teal floor, so this catches
    ground-only videos before review without relying on prompt judgment.
    """
    if not rgb:
        return 0.0
    hits = 0
    pixels = len(rgb) // 3
    for i in range(0, len(rgb), 3):
        r, g, b = rgb[i], rgb[i + 1], rgb[i + 2]
        mx = max(r, g, b)
        mn = min(r, g, b)
        avg = (r + g + b) / 3.0
        if avg > 70 and (mx - mn) < 55:
            hits += 1
    return 100.0 * hits / max(1, pixels)


def video_stats(
    video: Path,
    samples: int,
    stddev_min: float,
    unique_min: int,
    foreground_min_pct: float,
) -> dict:
    probe = ffprobe(video)
    stream = probe["streams"][0]
    total = frame_count(stream)
    indices = sorted(set(min(total - 1, i * total // samples) for i in range(samples)))
    frame_stats = []
    failures = []
    for idx in indices:
        _, _, rgb = extract_frame_ppm(video, idx)
        stddev, unique = pixel_stats(rgb)
        foreground_pct = foreground_signal_pct(rgb)
        ok = (
            stddev > stddev_min
            and unique > unique_min
            and foreground_pct >= foreground_min_pct
        )
        frame_stats.append(
            {
                "frame_index": idx,
                "pixel_stddev": round(stddev, 2),
                "unique_colors": unique,
                "foreground_signal_pct": round(foreground_pct, 3),
                "passes": bool(ok),
            }
        )
        if not ok:
            failures.append(
                f"{video.name}: frame {idx} weak visual signal "
                f"(stddev={stddev:.2f}, unique={unique}, "
                f"foreground_pct={foreground_pct:.3f})"
            )
    return {
        "path": str(video),
        "codec": stream.get("codec_name"),
        "pix_fmt": stream.get("pix_fmt"),
        "frames": total,
        "duration": stream.get("duration"),
        "frame_stats": frame_stats,
        "failures": failures,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", required=True, type=Path)
    parser.add_argument("--require-media", action="store_true")
    parser.add_argument("--require-video", action="store_true")
    parser.add_argument("--require-visible-video", action="store_true")
    parser.add_argument("--samples", type=int, default=4)
    parser.add_argument("--stddev-min", type=float, default=8.0)
    parser.add_argument("--unique-min", type=int, default=250)
    parser.add_argument("--foreground-min-pct", type=float, default=1.0)
    args = parser.parse_args()

    run_dir = args.run_dir
    files = [p for p in run_dir.rglob("*") if p.is_file()]
    videos = sorted(p for p in files if p.suffix.lower() in VIDEO_EXTS)
    images = sorted(p for p in files if p.suffix.lower() in IMAGE_EXTS)
    failures = []

    if args.require_media and not videos and not images:
        failures.append("required media missing: no video or image files found")
    if (args.require_video or args.require_visible_video) and not videos:
        failures.append("required video missing: no video files found")

    video_results = []
    if args.require_visible_video:
        for video in videos:
            try:
                result = video_stats(
                    video,
                    args.samples,
                    args.stddev_min,
                    args.unique_min,
                    args.foreground_min_pct,
                )
                failures.extend(result["failures"])
                video_results.append(result)
            except Exception as exc:
                failures.append(f"{video}: could not inspect video frames: {exc}")

    verdict = "PASS" if not failures else "FAIL"
    print(
        json.dumps(
            {
                "run_dir": str(run_dir),
                "require_media": args.require_media,
                "require_video": args.require_video,
                "require_visible_video": args.require_visible_video,
                "videos": [str(p.relative_to(run_dir)) for p in videos],
                "images": [str(p.relative_to(run_dir)) for p in images],
                "video_results": video_results,
                "failures": failures,
                "verdict": verdict,
            },
            indent=2,
        )
    )
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
