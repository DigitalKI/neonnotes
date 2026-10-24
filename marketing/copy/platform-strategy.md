# Platform strategy

The product is a local-first Markdown app built in Godot, AGPL, currently on the
v2 development line. That narrows the audience: people who care about **file
ownership**, **Godot/indie dev**, and **self-hosting**. Choose channels by who is
actually there, not by reach.

## Tiers

### Tier 1 — ongoing (2–3 posts/week each, same content, zero extra work)

| Channel | Why | What works | What to avoid |
|---|---|---|---|
| **X** | Where indie dev / build-in-public / Godot people are; video and GIF get distributed | Short demos, dev logs, one technical thread a week | Links in the post body, hashtag stuffing, daily posting |
| **Bluesky** | Same copy, better organic reach for small accounts right now, strong dev/OSS crowd | Identical posts minus hashtags | Nothing much — cross-post freely |
| **Mastodon** (fosstodon.org or similar) | AGPL + local-first is native here; the audience *is* the product thesis | 3–5 real hashtags (`#Godot`, `#Markdown`, `#LocalFirst`, `#OpenSource`), alt text always | Reposting the same link repeatedly |

Cross-posting is a copy-paste and a hashtag edit; treat it as one channel with
three endpoints.

### Tier 2 — one-shot launches (spaced 2–4 weeks apart, never the same week)

| Channel | Timing | Angle |
|---|---|---|
| **r/godot** | after the X cadence has a few weeks of visible progress | The engineering: gl_compatibility, SubViewport capture, pure-GDScript GIF encoder, worker-thread search |
| **r/selfhosted** | a separate week | The sync model: per-vault identity, 8-word pairing, UDP/TCP, no cloud — and the unencrypted caveat stated plainly |
| **r/NoteTaking** | another separate week | The workflow: write in the app, read the same file anywhere |
| **Show HN** | weekday, ~9–10am US Eastern, after a milestone you can defend | The constraint (plain files) + what breaks, invited criticism |
| **Product Hunt** | last, and only once you have some audience to convert | Design + ownership; needs a support push on the day |

Rules that keep these from backfiring: disclose you are the author, read each
subreddit's self-promo rules first, never post the same text to two subs in the
same week, and answer every critical comment for 48 hours.

### Tier 3 — long-form anchors (compounding, low frequency)

- **GitHub README + social preview** — this is the real landing page. The
  `platform/og-image.png` is already sized for it.
- **dev.to / Hashnode article** — "I built a note-taking app in Godot 4.7".
  Mirrors the Show HN comment, ranks in search, and gives X threads something
  worth linking to.
- **YouTube** — the 9:16 cut as a Short, plus one honest 2–3 minute demo when
  there is a build worth showing. Shorts can point at the repo.

### Tier 4 — skip or deprioritise

Instagram feed, Facebook, Threads, Pinterest, TikTok. The vertical video works
there visually, but the conversion is close to zero for a desktop Markdown app,
and each platform costs a separate posting habit. If you enjoy making vertical
video, cross-post it; do not build a strategy on it.

### Communities (best feedback per minute spent)

Godot Discord `#showcase`, local-first software communities, self-hosted
communities, and the note-taking app forums (Obsidian/Logseq-adjacent) *only*
where their self-promo rules allow it. These produce the bug reports that make
the app better; social produces the signups.

## Launch sequence

| Week | Move |
|---|---|
| 1–2 | X/Bluesky/Mastodon cadence starts; pinned thread; README + og-image polished |
| 3 | dev.to technical article; reply-driven engagement daily |
| 4 | r/godot one-shot |
| 5 | YouTube Short from the vertical cut; keep the cadence |
| 6 | r/selfhosted one-shot (different week) |
| 7 | Show HN |
| 8+ | Product Hunt once there is an audience; then repeat the cycle on milestones |

## Rules that apply everywhere

- **One link per three posts, maximum.** X and Mastodon both downrank link posts;
  put the repo in the first reply, not the post.
- **Alt text on every image and video.** Mastodon expects it, X rewards it, and
  it is the only accessibility feature these platforms have.
- **Never claim "secure" about LAN sync.** It is unencrypted by design right now.
- **Do not imply a stable release.** "v2 development line, working toward v3" is
  the honest line.
- **Answer questions with screenshots.** A 10-second clip beats a paragraph every
  time, and you already have the harness to make one in a minute.
