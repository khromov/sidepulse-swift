# Elgato Marketplace listing

Text and media for the SidePulse Swift product in the [Maker Console](https://maker.elgato.com).
`scripts/release-streamdeck.sh` builds the upload and the images. The rules quoted here are from
Elgato's [product guidelines](https://docs.elgato.com/guidelines/products) and
[plugin guidelines](https://docs.elgato.com/guidelines/stream-deck/plugins).

## Product

- **Name:** SidePulse Swift. It must be unique, about 30 characters or fewer, without the maker's name or
  emoji, and it cannot be changed after submission without emailing maker@elgato.com. It must match `Name`
  (and `Category`) in `manifest.json`.
- **Maker / organization:** must equal `Author` in `manifest.json` (now "Stanislav Khromov").
- **Category:** Developer tools (or Productivity).
- **Tags:** claude code, codex, opencode, ai agents, coding, developer, status, notifications.
- **Price:** free.
- **Links:** website https://github.com/khromov/sidepulse-swift, support
  https://github.com/khromov/sidepulse-swift/issues.
- **Supported:** macOS 26 or later, Stream Deck 6.9 or later, every Stream Deck with keys (no dial or touch
  strip layout yet).

## Description

250 to 1,500 characters, in English, listing every requirement:

> See at a glance whether your AI coding agents need you. SidePulse Swift adds an Agent Status key that
> shows the state of your Claude Code, Codex and OpenCode sessions. It turns orange the moment one of them
> waits for your answer or a permission prompt, and red when a tool call or turn fails.
>
> The key shows Error or Ask when an agent needs you, Working (animated) while agents work or run tools,
> Done when a task has just finished and Idle when nothing is running, plus how many agents are active.
> Put one key on your deck to follow every agent, or one key per agent: each key's settings let you pick
> Claude Code, Codex or OpenCode. Press the key to open SidePulse settings.
>
> Requirements: a Mac with macOS 26 or later, and the free, open-source SidePulse Swift app
> (https://github.com/khromov/sidepulse-swift), which installs the hooks that report your agents' status.
> The plugin starts the app when you press the key, and opens its download page if it is not installed.
> A SidePulse LED device is optional.
>
> SidePulse Swift is an independent open-source project. It works with Claude Code, Codex and OpenCode but
> is not affiliated with or endorsed by Anthropic, OpenAI, the OpenCode project or the makers of the
> SidePulse hardware. It collects no data and connects only to Stream Deck and the SidePulse app on your
> Mac.

## Media

From `dist/streamdeck-marketplace/`, all generated from the plugin's own key renderer:

| File | Use | Size |
| --- | --- | --- |
| `icon.png` | App icon (static PNG, the logo in focus, no "Official", no links) | 288 × 288 |
| `thumbnail.png` | Thumbnail | 1920 × 960 |
| `gallery-1-states.png` | Gallery: every key state | 1920 × 960 |
| `gallery-2-deck.png` | Gallery: keys on a 15-key deck | 1920 × 960 |
| `gallery-3-agents.png` | Gallery: one key per agent | 1920 × 960 |

The gallery needs 3 to 10 items. Photos of a real deck or a short MP4 (1920 × 1080, under 250 MB) can be
added. Elgato asks for a video when a product needs other hardware or a paid service, so record one if
review asks (Claude Code and Codex are paid services).

## Release notes

### 1.0.0.0

First release: the Agent Status key, with per-key agent selection and an animation switch.

## Before submitting

1. Bump `Version` in `manifest.json` and run `scripts/release-streamdeck.sh`.
2. Remove a development link (`~/Library/Application Support/com.elgato.StreamDeck/Plugins/io.sidepulse.swift.streamdeck.sdPlugin`),
   open `dist/io.sidepulse.swift.streamdeck.streamDeckPlugin` and check that Stream Deck installs it and the key
   works.
3. Upload with **Publish after review** unticked, download the DRM-processed build from the product's
   Versions tab, and test it the same way before publishing.
