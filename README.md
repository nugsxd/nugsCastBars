# nugsCastBars

Cast bars for **you, your target, your focus, your pet and up to five bosses** —
one addon, one look, and the same controls on every bar.

Retail only (Interface 120007 / Midnight). Open the options with **`/ncast`**, or
left-click the minimap button.

---

## Why

`asTargetCastbar` had the right idea and stopped short: target and focus only, and
almost nothing you could change. nugsCastBars covers every unit that matters and
puts texture, font, icon, timer, colours and the cast's target in the options
window instead of in the source file.

## What each bar can do

Every one of these is per bar, so your own cast bar can look nothing like the boss
bars if that is what you want.

| | |
|---|---|
| **Bar** | texture (LibSharedMedia aware), width, height, scale, border, spark |
| **Icon** | on or off, left or right, cropped or full, gap to the bar |
| **Text** | font, outline, size, spell name with alignment and optional trimming |
| **Timer** | remaining, elapsed, or elapsed / total, to 0–2 decimals |
| **Cast target** | who the cast is aimed at — inline, below the bar, or off to the right |
| **Interrupts** | its own bar colour and a shield icon when a cast cannot be interrupted |
| **Colours** | casting, channelling, uninterruptible, finished, interrupted, background, border, text |
| **Finishing** | how long a finished bar holds, and how long it takes to fade |
| **Blizzard** | switch off the stock bar for that unit |

Boss bars additionally get a stacking direction and the gap between them. Boss 1 is
the bar you drag; the rest follow it.

The player bar can show the **latency tail** — the slice at the end of your cast
that has already left your client, so starting the next one inside it costs you
nothing.

Evoker **empowered** casts get a divider at each stage boundary.

## The cast target

This is the feature `asTargetCastbar` was built around, and it works the way the
game does: the target is read **once, when the cast starts**, because that is the
moment a spell locks onto its target. Re-reading it every frame would show you
where the boss is looking now, not where the spell is going to land.

It is class-coloured by default, and turns red when the cast is on **you**.

## Placing the bars

`/ncast unlock`, or the button in the options window. Every enabled bar shows a demo
cast while unlocked, so you are lining up the real thing rather than an empty box.
Drag them, then `/ncast lock`. The two position sliders nudge whichever bar's tab you
are on, and agree with wherever you last dropped it.

## Commands

```
/ncast                  open the options window
/ncast unlock | lock    place the bars
/ncast test             a demo cast on every bar
/ncast on | off         master switch
/ncast reset <bar|all>  start a bar over  (player|target|focus|pet|boss|all)
/ncast minimap          show or hide the minimap button
/ncast diag             what the addon sees on every bar, right now
/ncast debug            log every spellcast event as it arrives
```

## When a bar does not show up

`/ncast diag` prints a line per bar: whether it is enabled, whether the unit is
even there, whether the frame is shown and at what alpha, its size and position,
whether its events are registered, and what the client says that unit is casting
at that moment. Target the unit that is casting and run it — the line tells you
whether the addon is missing the cast or drawing it somewhere you are not looking.

`/ncast debug` then logs each spellcast event as it lands, which separates "no event
arrived" from "event arrived, bar did not draw".

Bars do not rely on events alone: five times a second each one checks what its
unit is actually casting and corrects itself, so a missed event costs at most a
fifth of a second.

## Notes

- **LibSharedMedia** is used if some other addon has loaded it, and is never
  required. Without it you get the stock textures and fonts.
- **Hiding Blizzard's bar** takes effect immediately; putting it back needs a
  `/reload`.
### How this works under 12.0's secret values

For **another unit's** cast, retail 12.0 hands addons every field as a *secret
value*: name, icon, start and end times, spell id, and whether it can be
interrupted. A secret can be shown on screen but not read, measured, compared or
computed with by the addon.

That is not a wall, it is a pipe. The client will hand you something you may not
read, on the understanding that you pass it to a widget and the widget does the
work. nugsCastBars uses that throughout:

- `UnitCastingDuration` / `UnitChannelDuration` returns a **Duration object**;
  `StatusBar:SetTimerDuration` makes the bar animate itself, counting down for
  channels and up for casts, and `Duration:GetRemainingDuration()` feeds
  `SetFormattedText` a **real countdown**. The number never passes through Lua.
- `Texture:SetAlphaFromBoolean` is the display sink for a secret **boolean**, which
  is how the interrupt shield and the "cannot be interrupted" bar colour work
  without any code branching on the value.
- `UnitSpellTargetName` / `UnitSpellTargetClass` give the cast's actual target.

Each bar reports which mode it is drawing in (`/ncast diag`):

| mode | when | what you get |
|---|---|---|
| `timer` | the normal case on 12.0 | everything: accurate bar, countdown, spark, interrupt colour |
| `timed` | no timer API, but readable times | the same, from our own maths |
| `secret` | no timer API and secret times | an accurate bar, but no numbers |
| `guessed` | no usable times; this spell has been watched finish before | bar and timer from the remembered length, marked `?` |
| `unknown` | nothing to go on | a sweep, and no number at all |

One thing really is gone: which **stage** of an empowered cast is currently held is
no longer knowable by anyone. The pips mark the boundaries; nothing tracks the
current one.

## Checks

Every push runs static analysis over the Lua in this repo, and the same checks run
locally before a release. To run them yourself:

```
npm install
npm test
```

Each check exists because of a bug that got as far as a build, and each script says
which one at the top of the file:

| | |
|---|---|
| `check.js` | every file parses |
| `fwdref.js` | a name used above the `local` that declares it - which silently reads a nil global |
| `selfref.js` | `local x = f(function() ... x ... end)`, where the closure captures nil rather than `x` |
| `wowcheck.js` | taint, secret values, and the other WoW-specific ways Lua that looks fine still breaks |
| `globalwrite.js` | assignments that never declared a local - advisory, since SavedVariables have to be globals |

Two more run before release but are not in this repo, because they need a copy of
Ketho's WoW API annotations: a check that no call has been moved or removed in the
current patch, and a full `lua-language-server` pass.

---

Copyright (c) 2026 nugs. All Rights Reserved. See LICENSE.
