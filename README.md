# Streak chain

A KOReader sleep screen for making reading a daily habit. It shows the book
you're reading and the time left in it, today against your daily goal, your
other reading goals, and the day streak over a three-month calendar.

Any page counts as a reading day. The numbers come from KOReader's own
Reading statistics and the goals from Bookshelf's Reading goal module, so
nothing new is tracked.

## Install

Copy this folder to `koreader/plugins/streakchain.koplugin` on the device and
restart KOReader. Then:

- **Tools → Streak chain → Use as sleep screen** turns it on. Turning it off
  restores whatever sleep screen you had before.
- **Preview** shows it now; tap to close.

Goals are set in Bookshelf (daily, weekly, monthly, yearly). A goal that's
switched off or unset there drops its row here.

It uses Vollkorn and Atkinson Hyperlegible when they're installed in the
device's font folder, and KOReader's Noto fonts otherwise.

On an ad-supported Kindle, KOReader only draws sleep screens once Amazon's ad
screensaver is unloaded (`lipc-set-prop com.lab126.blanket unload
ad_screensaver`). That resets on every reboot.

## What it shows

Design 7b, "Two-column ledger", on paper: the book on a light gray page, the
stats on a white sheet.

| Part | Rule |
|---|---|
| Header | Weekday and date. Warns about the battery at 15% or less. |
| Book | The cover at its own pixels, only ever shrunk (to 420 px tall), never enlarged or reshaped; a typeset cover when there's none. Title, author, then the next step: "22 min left in Chapter Thirteen", the chapter's title when it has 20 characters or fewer, otherwise "this chapter"; "left in the book" in the last chapter or a book without chapters; pages without Reading statistics. |
| Hero | Time to the end, "2 h 40 to the end" or "38 min to the end"; the page without Reading statistics. Under it, time in this book so far: "6 h 40 in, since 12 Sep". |
| Quote | A quote about reading in the gap above the hero, the next one from a shuffled order that doesn't repeat until all have shown. At most two lines and only what the gap holds; one too long is skipped for the next that fits, and if none fits the gap stays empty. The list is `streakchain/quotes.lua`. |
| Chapter bar | The current chapter magnified to 40% of the width, filled as far as it's read, with its title and the time left in it; the chapters before it solid, the ones after outlined, each as wide as its share of the rest. Front and back matter of a page or two fold into their neighbours. A book without chapters is one box: "Page 87 of 230", "143 pages to go". |
| Today | Minutes to the daily goal with a bar ("33 min to today's goal"), then Yesterday ("52 min", or "Rest day"), Pages today, and Goal day streak: days in a row the whole goal was met, today counting once it is. After the goal: "52 min today · goal done". |
| Goals | This week in hours ("3 h 07 of 10 h"), this month's books and this year's books (a cell per book), then the hours read this year. Weeks start on Monday. |
| Streak | The day streak with a flame: small at 1–2 days, larger at 3–6, largest from 7, with a white core from 30; an outline until a page is read today, dashed with no run. "Best run: 12 days" while the best run is ahead of the current one. |
| Calendar | This month and the two before it, Monday-first. Days shaded by minutes read (none, under 20, 20–39, 40+), today ringed, days to come dashed, the current run joined up. |

Nothing refers to the time of day, and the wording reads right at 1 and at
many. Other layouts: no book open, Reading statistics off (a hint in place of
the stats), landscape (the book and the streak on the left, Today and Goals on
the right), and a "Finished" band on finished books.

## Code

- `main.lua`: menu, and the hook into KOReader's `Screensaver:show()`. Core
  passes the `streakchain` screen type through `setup()` untouched; the hook
  builds the widget and hands it to core's `ScreenSaverWidget`, so core closes
  it on wake like its own screens.
- `streakchain/data.lua`: reads the open book (or the last one, from the file
  browser), the statistics database and Bookshelf's goals into a plain model.
- `streakchain/screen.lua`: draws the model. Layout is in the design's units
  (1264×1680) and scaled to the real screen. The flame is drawn from the SVGs
  in `streakchain/flame/`.
- `streakchain/format.lua`, `streakchain/chain.lua`, `streakchain/quote.lua`:
  every piece of wording, the day maths and the chapter bar's layout, and the
  quote's rotation and fit, as pure Lua.

## Tests

```sh
tools/test.sh ~/.cache/streakchain-kotest/ko ~/.cache/streakchain-kotest/covers
```

This needs Docker and an extracted `koreader-linux-arm64` release under
`$HOME`. It runs two layers in a Debian container:

1. `tests/run.lua`: unit tests for the wording, the day maths, the chapter bar
   and the quote rules, on KOReader's LuaJIT.
2. `tools/render.lua`: the real KOReader engine, headless. It renders every
   state in `tools/fixtures.lua` to PNG and fails if any block overlaps
   another, leaves the screen, or runs into its neighbour; checks the
   statistics SQL against a synthetic database; and suspends through core's
   `Screensaver` to confirm the hook end to end.

`tools/repro_book.lua` opens a real book in a headless reader session and
checks the file browser's screen matches the reader's (see its header for
how to run it).
