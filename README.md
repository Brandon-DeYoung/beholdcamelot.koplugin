# Behold: Camelot

An Arthurian realm builder card game for KOReader. Build your realm through 16 cards with four orientations each, gather resources, establish Holdings, and outscore a chosen rival.

## Install

Copy `beholdcamelot.koplugin` into `/koreader/plugins/`, restart KOReader, and open **Tools > Behold: Camelot**.

## Interface

- Tap a hand card or the separate pile-top card to focus it.
- Use **Inspect / flip** to inspect both physical sides. **Rotate** exchanges the visible halves; neither operation changes the game.
- Hold a card offered in a selection popup to inspect it without losing the pending choice.
- **Realm / Rival** shows the realm and every rival scoring category, with current inputs and points.
- Hold a rival for strategy, or hold a setup option for its description.
- The X asks before saving and quitting.

## Development and verification

Run from this directory:

```sh
luac -p beholdcamelot.koplugin/main.lua beholdcamelot.koplugin/scoring.lua beholdcamelot.koplugin/_meta.lua
lua tests/smoke.lua
```

The suite covers scoring fixtures, action costs and benefits, interrupts, storage timing, realm changes, banner restrictions, preview state isolation and UI layout at four simulated screen sizes. Randomized walks check card conservation, not optimal strategy. Physical Kindle touch/rendering verification is still required for this build.

The roster and terminology are listed in [DESIGN.md](DESIGN.md).

## Credit and support

Behold: Camelot is inspired by Joe Klipfel's **Behold: Rome**. Please support Joe by [buying his game from The Game Crafter](https://www.thegamecrafter.com/games/behold%3A-rome-standard-edition-).

This is an unofficial thematic adaptation, not affiliated with or endorsed by Joe Klipfel or the publisher.
