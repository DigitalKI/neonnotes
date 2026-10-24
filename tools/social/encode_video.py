#!/usr/bin/env python3
"""Encode the frame sequence written by tools/social/CaptureMovie.tscn into
social-ready assets.

  python3 tools/social/encode_video.py <frames_dir> <out_basename> [--fps 30]

Writes <out>.mp4 (H.264 + faststart: X, Instagram, TikTok, LinkedIn, YouTube),
<out>.gif (palette-optimised, loops forever: Mastodon, Reddit, README) and
<out>.webp (smallest animated still for the web).

ffmpeg is required for all three. It is looked up as $FFMPEG, then on PATH, then
in the Shotcut bundle (which ships a full build with libx264) — no install step
needed on a machine that already has Shotcut.
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys

SHOTCUT = os.path.expanduser("~/.local/share/Shotcut.app")


def find_ffmpeg():
    if os.environ.get("FFMPEG"):
        return os.environ["FFMPEG"], {}
    if shutil.which("ffmpeg"):
        return "ffmpeg", {}
    bundled = os.path.join(SHOTCUT, "bin", "ffmpeg")
    if os.path.exists(bundled):
        env = dict(os.environ)
        libs = os.pathsep.join([os.path.join(SHOTCUT, "lib"), os.path.join(SHOTCUT, "libexec")])
        env["LD_LIBRARY_PATH"] = libs + (os.pathsep + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else "")
        return bundled, env
    sys.exit("ffmpeg not found: install it, or set FFMPEG=/path/to/ffmpeg")


def run(cmd, env):
    subprocess.run(cmd, check=True, env=env)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frames_dir")
    ap.add_argument("out_basename")
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--gif-width", type=int, default=720)
    ap.add_argument("--gif-fps", type=int, default=15)
    ap.add_argument("--keep-frames", action="store_true")
    a = ap.parse_args()

    paths = sorted(glob.glob(os.path.join(a.frames_dir, "frame_*.jpg")) +
                   glob.glob(os.path.join(a.frames_dir, "frame_*.png")))
    if not paths:
        sys.exit(f"no frames in {a.frames_dir}")
    ext = os.path.basename(paths[0]).rsplit(".", 1)[1]
    pattern = os.path.join(a.frames_dir, f"frame_%04d.{ext}")
    ffmpeg, env = find_ffmpeg()
    print(f"{len(paths)} frames @ {a.fps} fps = {len(paths) / a.fps:.1f}s")

    mp4 = a.out_basename + ".mp4"
    run([ffmpeg, "-y", "-loglevel", "error", "-framerate", str(a.fps), "-i", pattern,
         "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p",
         "-movflags", "+faststart", mp4], env)
    print(f"wrote {mp4} ({os.path.getsize(mp4) / 1e6:.1f} MB)")

    gif = a.out_basename + ".gif"
    run([ffmpeg, "-y", "-loglevel", "error", "-framerate", str(a.fps), "-i", pattern,
         "-vf", f"fps={a.gif_fps},scale={a.gif_width}:-1:flags=lanczos,split[a][b];"
                f"[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer",
         "-loop", "0", gif], env)
    print(f"wrote {gif} ({os.path.getsize(gif) / 1e6:.1f} MB)")

    webp = a.out_basename + ".webp"
    run([ffmpeg, "-y", "-loglevel", "error", "-framerate", str(a.fps), "-i", pattern,
         "-vf", f"fps={a.gif_fps},scale={a.gif_width}:-1:flags=lanczos",
         "-c:v", "libwebp", "-lossless", "0", "-q:v", "70", "-loop", "0", webp], env)
    print(f"wrote {webp} ({os.path.getsize(webp) / 1e6:.1f} MB)")

    if not a.keep_frames:
        for p in paths:
            os.remove(p)
        print("removed source frames")


if __name__ == "__main__":
    main()
