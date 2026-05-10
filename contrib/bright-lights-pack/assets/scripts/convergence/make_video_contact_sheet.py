#!/usr/bin/env python3
"""Create contact sheets for run videos so reviewers can inspect content.

This is intentionally generic: it does not decide whether a robot is visible.
It turns video artifacts into small image sheets that a reviewer can inspect
before accepting a run.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path


VIDEO_EXTS = {".mp4", ".webm", ".gif", ".mov", ".mkv"}


def _probe_duration(path: Path) -> float:
    out = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "json",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    data = json.loads(out)
    return max(float(data.get("format", {}).get("duration") or 0.0), 0.0)


def _extract_frame(video: Path, t: float, out_png: Path) -> bool:
    proc = subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-ss",
            f"{t:.3f}",
            "-i",
            str(video),
            "-frames:v",
            "1",
            str(out_png),
        ],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0 and out_png.exists() and out_png.stat().st_size > 0


def _make_sheet(frames: list[Path], out_jpg: Path, thumb_width: int) -> None:
    from PIL import Image, ImageDraw

    thumbs = []
    for frame in frames:
        img = Image.open(frame).convert("RGB")
        scale = thumb_width / float(img.width)
        thumb_height = max(1, int(round(img.height * scale)))
        img = img.resize((thumb_width, thumb_height))
        thumbs.append((frame.name, img))

    if not thumbs:
        raise RuntimeError("no frames extracted")

    label_h = 20
    width = thumb_width * len(thumbs)
    height = max(img.height for _, img in thumbs) + label_h
    sheet = Image.new("RGB", (width, height), (20, 20, 20))
    draw = ImageDraw.Draw(sheet)

    x = 0
    for label, img in thumbs:
        sheet.paste(img, (x, label_h))
        draw.text((x + 4, 3), label, fill=(230, 230, 230))
        x += thumb_width

    out_jpg.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out_jpg, quality=88)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True, type=Path)
    ap.add_argument("--out-dir", type=Path, default=None)
    ap.add_argument("--samples", type=int, default=4)
    ap.add_argument("--thumb-width", type=int, default=240)
    args = ap.parse_args()

    run_dir = args.run_dir
    out_dir = args.out_dir or (run_dir / "review_artifacts" / "video_contact_sheets")
    videos = sorted(
        p for p in run_dir.rglob("*")
        if p.is_file() and p.suffix.lower() in VIDEO_EXTS
    )

    manifest = []
    out_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="video_contact_sheet_") as tmp:
        tmp_dir = Path(tmp)
        for video in videos:
            rel = video.relative_to(run_dir)
            safe = "__".join(rel.parts).replace(" ", "_")
            stem = Path(safe).with_suffix("").name
            duration = _probe_duration(video)
            if duration <= 0:
                times = [0.0]
            else:
                # Avoid exactly EOF, which can fail on short videos.
                times = [duration * frac for frac in (0.05, 0.30, 0.60, 0.90)]
                times = times[: max(1, args.samples)]

            frames = []
            for idx, t in enumerate(times):
                frame = tmp_dir / f"{stem}_{idx}_t{t:.2f}.png"
                if _extract_frame(video, t, frame):
                    frames.append(frame)

            if not frames:
                manifest.append({"video": str(rel), "status": "failed:no_frames"})
                continue

            sheet = out_dir / f"{stem}.jpg"
            _make_sheet(frames, sheet, args.thumb_width)
            manifest.append({
                "video": str(rel),
                "contact_sheet": str(sheet.relative_to(run_dir)),
                "duration_s": round(duration, 3),
                "frames": len(frames),
                "status": "ok",
            })

    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"run_dir": str(run_dir), "videos": manifest}, indent=2))
    return 0 if any(item.get("status") == "ok" for item in manifest) else 1


if __name__ == "__main__":
    raise SystemExit(main())
