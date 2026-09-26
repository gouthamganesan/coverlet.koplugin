# Streak chain

A KOReader sleep screen for making reading a daily habit. It shows the book
you're reading, the time left in the chapter, and a four-week chain of reading
days, with the streak underneath.

Any page counts as a reading day. The numbers come from KOReader's own
Reading statistics, so nothing new is tracked.

## Install

Copy this folder to `koreader/plugins/streakchain.koplugin` on the device and
restart KOReader. Then:

- **Tools → Streak chain → Use as sleep screen** turns it on. Turning it off
  restores whatever sleep screen you had before.
- **Preview** shows it now; tap to close.
- **Yearly goal** sets the "14 of 24 books" count. With no goal it reads
  "14 finished this year".

It uses Vollkorn and Atkinson Hyperlegible when they're installed in the
device's font folder, and KOReader's Noto fonts otherwise.

On an ad-supported Kindle, KOReader only draws sleep screens once Amazon's ad
screensaver is unloaded (`lipc-set-prop com.lab126.blanket unload
ad_screensaver`). That resets on every reboot.

## What it shows

| Part | Rule |
|---|---|
| Next step | "11 min left in Part II". Uses the chapter's title when it has 20 characters or fewer, otherwise "this chapter". In the last chapter, or a book without chapters, it's "left in the book". Without Reading statistics, pages instead of minutes. |
| Chain | Monday-first, four weeks, today on the last row. Squares: before your first reading day, missed, under 20 min, 20–39, 40+, today not read yet (dashed), today read (outlined). |
| Streak note | "Today's square is still empty." / "Today is in the chain." / "Your longest run so far." / "One page starts a new run." None depend on the time of day. |
| Stats line | Best run (only when it beats the current one), this week's reading time, books finished this year. |
| Header | Weekday and date. Warns about the battery at 15% or less. |

Other layouts: no book open (the chain fills the screen), Reading statistics
off (a hint replaces the chain), landscape, a typeset cover for books without
one, and a "Finished" band on finished books.

## Code

- `main.lua`: menu, and the hook into KOReader's `Screensaver:show()`. Core
  passes the `streakchain` screen type through `setup()` untouched; the hook
  builds the widget and hands it to core's `ScreenSaverWidget`, so core closes
  it on wake like its own screens.
- `streakchain/data.lua`: reads the open book (or the last one, from the file
  browser) and the statistics database into a plain model.
- `streakchain/screen.lua`: draws the model. Layout is in the design's units
  (1264×1680) and scaled to the real screen.
- `streakchain/format.lua`, `streakchain/chain.lua`: every piece of wording
  and the day maths, as pure Lua.

## Tests

```sh
tools/test.sh ~/.cache/streakchain-kotest/ko ~/.cache/streakchain-kotest/covers
```

This needs Docker and an extracted `koreader-linux-arm64` release under
`$HOME`. It runs two layers in a Debian container:

1. `tests/run.lua`: unit tests for the wording and chain maths, on KOReader's
   LuaJIT.
2. `tools/render.lua`: the real KOReader engine, headless. It renders every
   state in `tools/fixtures.lua` to PNG, checks the statistics SQL against a
   synthetic database, and suspends through core's `Screensaver` to confirm
   the hook end to end.
