# NeonNotes marketing kit

Everything here is generated from the real app — no mockups, no staged HTML.
`tools/social/CaptureStage.tscn` boots the actual `Main.tscn` against a
disposable demo vault inside a `SubViewport`, so a shot is reproducible at any
resolution and can never touch a real vault.

## Assets

| File | Size | Use |
|---|---|---|
| `captures/01-hero-preview.png` | 1920x1080 | Hero / README / OG fallback |
| `captures/02-editor-source.png` | 1920x1080 | Editing, syntax highlighting |
| `captures/03-editor-tags.png` | 1920x1080 | Tags, prose editing |
| `captures/04-graph-dock.png` | 1920x1080 | Note + graph side by side |
| `captures/05-graph-full.png` | 1920x1080 | The radial vault map |
| `captures/06-search-tags.png` | 1920x1080 | `#tag` search |
| `captures/07-settings.png` | 1920x1080 | Theme / CRT / sync settings |
| `captures/08-square-hero.png` | 1080x1080 | Feed post (Instagram, Threads) |
| `captures/09-portrait-hero.png` | 1080x1350 | 4:5 feed post |
| `captures/10-mobile-note.png` | 1080x1920 | Phone, note view |
| `captures/11-mobile-drawer.png` | 1080x1920 | Phone, sidebar drawer |
| `captures/neonnotes-demo-16x9.mp4` | 1280x720, 19.9 s | X, LinkedIn, Mastodon, YouTube |
| `captures/neonnotes-demo-16x9.gif` | 720 px, 15 fps | Mastodon, Reddit, README |
| `captures/neonnotes-demo-9x16.mp4` | 1080x1920, 9.3 s | Reels, Shorts, TikTok, Stories |
| `captures/neonnotes-demo-9x16.gif` | 540 px, 15 fps | Vertical previews |
| `captures/platform/*.png` | exact per-platform sizes | X, Bluesky, Mastodon, LinkedIn, OG, Product Hunt |

Poster frame: use `01-hero-preview.png` for video thumbnails.

## Copy

| File | Use |
|---|---|
| `copy/platform-strategy.md` | Which channels, in what order, and what to skip |
| `copy/x-program.md` | Ongoing X cadence, formats, and a caption for every asset |
| `copy/x-thread.md` | The pinned launch thread |
| `copy/bluesky-mastodon.md`, `copy/linkedin.md`, `copy/instagram-tiktok.md` | Per-platform versions |
| `copy/reddit.md`, `copy/show-hn-product-hunt.md` | The one-shot launches |
| `copy/alt-text.md` | Alt text for every image and video |

## Regenerate

```bash
# stills (11 PNGs, ~30 s)
NEONNOTES_VAULT=user://neonnotes-capture \
NEONNOTES_CAPTURE_VAULT=user://neonnotes-capture \
godot --path . tools/social/CaptureStage.tscn

# landscape demo movie (~600 frames, ~1 min)
NEONNOTES_VAULT=user://neonnotes-capture \
NEONNOTES_CAPTURE_VAULT=user://neonnotes-capture \
NEONNOTES_MOVIE_SIZE=1280x720 \
godot --path . tools/social/CaptureMovie.tscn

python3 tools/social/encode_video.py marketing/captures/_frames \
  marketing/captures/neonnotes-demo-16x9 --fps 30

# vertical demo movie
NEONNOTES_VAULT=user://neonnotes-capture \
NEONNOTES_CAPTURE_VAULT=user://neonnotes-capture \
NEONNOTES_MOVIE_SIZE=1080x1920 \
godot --path . tools/social/CaptureMovie.tscn

python3 tools/social/encode_video.py marketing/captures/_frames \
  marketing/captures/neonnotes-demo-9x16 --fps 30 --gif-width 540

# per-platform still sizes
python3 tools/social/platform_sizes.py
```

The encoder uses `$FFMPEG`, then `ffmpeg` on `PATH`, then the FFmpeg bundled
with Shotcut (`~/.local/share/Shotcut.app`) — no install step needed here.

## Posting checklist

- Never post a shot the app cannot reproduce: change the demo vault content in
  `tools/social/capture_stage.gd`, re-run, and use the new PNGs.
- Alt text is in `copy/alt-text.md`; paste it into every platform that asks.
- Vertical cut for Reels/Shorts/TikTok, 16:9 everywhere else.
- Link to `https://github.com/DigitalKI/neonnotes` in the first post or the bio,
  never only in a later reply.
- Say "v2 development line, working toward v3" if the version comes up; do not
  imply a stable release.
- LAN sync is unencrypted: never present it as secure/private transport.

## What the assistant can and cannot do here

Can: generate stills and video from the real UI, derive platform sizes, write
copy, alt text and thread structure, keep everything reproducible in-repo.
Cannot: log in and post for you. There are no social APIs or credentials wired
into this environment, so publishing stays a human step (or needs a scheduler
such as Buffer/Typefully connected to the account).
