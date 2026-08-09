# nugsCastBars — changelog

## 0.8.3

- **Fixed: an attached GCD bar did not line up with the player cast bar if the two
  had different scales.** It was matching that bar's width but keeping its own
  scale, and width is measured in a frame's own units — so two frames of equal width
  at different scales are not the same size on screen, which is precisely the
  misalignment attaching exists to prevent. Attached mode now adopts the player
  bar's scale as well as its width, and its own scale slider is hidden while
  attached rather than left sitting there doing nothing.
- **Ready for patch 12.1.** The .toc declares `120007, 120100`, so this is current
  on live and on the 12.1 PTR at once rather than being flagged out of date on one of
  them. Nothing here uses an API that 12.1 removes, and the unit calls that begin
  returning secret values in 12.1 are guarded - a release check now enforces both, so
  it stays true.

## 0.8.2

- **Fixed: the GCD bar's spark was invisible.** My mistake in 0.8.1 — the spark and
  the timer text were textures on the frame itself, and a child frame draws over
  every texture its parent owns whatever layer that texture is on, so both status
  bars were covering them. They now live on an overlay frame stacked above the bars.
  The spark also has a minimum height: scaled purely off a 6px bar it was a smudge,
  and it wants to stand proud of the bar to read at all.
- **Latency tail on the GCD bar**, off by default. It marks the slice at the end of
  the sweep in which a keypress still reaches the server before the global expires,
  and it sits on whichever end the sweep actually runs out at — the left for a
  draining bar, the right for a filling one. Worth having here even if you leave it
  off the cast bars: "when can I press the next one" is the question this bar exists
  to answer, and that is not quite the same as "when does the global end".
- **Show it: always / only in combat / only out of combat.** A metronome beating
  away while you stand in a city is noise. Default is unchanged (always), but in
  combat is the one most people will end up on.

## 0.8.1

**The GCD bar now keeps beating between presses**, which is what it was asked to do
and is not what 0.8.0 did — that one showed a global and then went quiet.

- New **Behaviour** setting on the GCD tab:
  - **Always running** (now the default) — a metronome. The bar sweeps continuously
    at the length of your global and restarts the moment one is triggered, so the
    rhythm is visible even when nothing is being cast. Press Judgement, watch the
    sweep run, and it keeps cycling until the next press resets it.
  - **Only while a global is running** — 0.8.0's behaviour, kept because it is what
    most other GCD bars do.
- Only a press that **actually costs a global** resets the sweep. The reset comes
  off the rising edge of the global itself, not off any cast succeeding, so
  off-global abilities do not disturb it — and neither does the constant cooldown
  chatter that `SPELL_UPDATE_COOLDOWN` carries for unrelated spells.
- The **length of your global is learned, not assumed**: read plainly from the
  client where it will say, and otherwise measured off our own clock as each one
  runs. Haste changes it, so it is re-earned every global rather than cached once —
  a reading taken before the pull no longer locks out measurement for the fight.
  `/ncast diag` reports the current length and where it came from.

**Why two status bars now:** the looping sweep cannot use `SetTimerDuration` — a
duration object only exists while a cooldown is actually running, and the loop has
to keep going between them — so it drives `SetValue` off our own clock instead. Those
two do not mix on one widget: a *finished* timer keeps painting its terminal state,
and a later `SetValue` on the same bar does not necessarily repaint it. There is no
documented way to detach a timer once armed. Two bars with one shown at a time
sidesteps the question rather than betting on undocumented repaint behaviour.

## 0.8.0

**A global cooldown bar**, on its own **GCD** tab. Off by default.

- A slim bar showing the global running down, so the next ability's readiness can be
  read without watching an action bar.
- **Attached by default**: it sits under the player cast bar and matches its width,
  so the two stay lined up wherever that bar is moved — no second thing to place.
  Free placement is the other option, draggable with `/ncast unlock` like everything
  else.
- Height, scale, texture, border, spark, colours, and a **direction** setting —
  empties as it runs out, or fills. Optional remaining-time text with its own font,
  size, outline and decimals; off by default, since at a second and a half the bar
  reads faster than a number.
- "Hide while no global is running" can be turned off for anyone who would rather
  have an empty bar sitting there than something appearing at the edge of vision.
- `/ncast diag` reports whether it is on, how it is anchored, and whether the two
  things it needs from the client are answering.

It is driven the same way the cast bars are, and for the same reason: the global is
a spell (61304), `C_Spell.GetSpellCooldownDuration` hands back a Duration object,
and `StatusBar:SetTimerDuration` animates from it — so the fill stays correct in
combat without a number ever passing through Lua. Whether the bar is up at all is
decided by `isActive`, which is NeverSecret and so a real boolean to branch on.

## 0.7.4

- **Bars can no longer be placed during combat**, which matches the rule that a pull
  locks them in the first place. Unlocking puts sample bars on screen, and a sample
  cast during a real pull cannot be told apart from a real one. It is now refused with
  a line of chat rather than half-entered.

## 0.7.3

- **Fixed: "action blocked" errors during combat.** `SetPropagateKeyboardInput` - used
  so that Escape closes a dropdown or the placement bar rather than the window behind
  it - is protected during a fight. Calling it then raises ADDON_ACTION_BLOCKED naming
  this addon, and unlike a Lua error it cannot be caught: it taints the addon for the
  rest of the session. 8 call sites now skip themselves in combat.
- The worst of them was the key handler: it guarded the Escape branch but not the
  branch every *other* key took, so with a list open in combat any keypress would have
  thrown it - movement keys included.

## 0.7.2

- Internal hardening, no visible change. The scroll helper's fallback width guard could
  copy a zero width onto a list's content frame during the first layout pass, and once
  copied nothing would correct it - rows would draw but not be clickable. Every list here
  sets its own content width afterwards, so this was never reachable; the guard now waits
  for the scroll frame to have a real width, so it stays a safe backstop.

## 0.7.1

- **The settings window gets out of the way while you place your cast bars.** Unlocking
  hides it and puts up a small bar instead - Lock bars and Demo cast - and locking brings the
  window back exactly where it was. Placing things meant dragging boxes the window was
  usually sitting on top of, so it had to be shoved aside and dragged back every time.
- The bar can be dragged if it is in the way, and Escape locks rather than just
  dismissing it - hiding it while things were still unlocked would have left nothing on
  screen to end that state.
- `/ncast unlock` puts the bar up too. If the settings window was not open when you
  unlocked, locking does not conjure one.
- **Fixed: a dropdown could run off the bottom of a smaller screen.** Four of them
  dropped straight down from their button with no check that there was room below and
  no clamping, while the lists beside them already handled it. They now open upwards
  when there is no room, and are clamped as a backstop - clamping alone would slide a
  list up over the button that opened it, hiding the thing being changed.
- **The settings window closes when a fight starts, and the anchor locks.** Not because
  anything here would be blocked - none of these windows touch a secure frame, so
  nothing throws "action blocked" the way an addon driving action bars does. The
  reason is that both states put fake data on screen: unlocked, every bar carries a preview cast, and sample
  data during a real pull cannot be told apart from the real thing. Nothing reopens
  when combat drops.
- **The slash command is now `/ncast`.** `/nugscastbars` still works.
- **`/ncb` now belongs to nugsComboBar.** If you have a macro using `/ncb` for cast
  bars it will not error - it will quietly drive the other addon, which is worse. Both
  commands changed at once on purpose, while the number of people holding macros is
  still small.

## 0.7.0

- **Use your own sound file for the interrupt cue.** Open the sound list, pick
  **+ Add your own**, paste the path to an `.ogg` or `.mp3`, and press Test. It plays
  straight away if the path is right, and says what is wrong if it is not. Name it and
  it joins the cue list like any other.
- **Test really does test.** The client returns nothing at all for a file it cannot
  find, so the path is verified before it is kept rather than failing silently in the
  middle of a pull. The game's own sound settings are checked first, so a muted client
  is reported as a muted client instead of being blamed on the path.
- **Cues are shared with the other nugs addons.** A sound added in nugsCooldownPulse
  shows up here and the other way round, through the same plain global the addons
  already use to find each other. Neither addon depends on the other, and nugsSuite is
  not required for it.
- **Your own cues are at the top of the list**, with **+ Add your own sound file** as
  the first row. With a LibSharedMedia pack loaded that list runs to dozens, and
  anything at the bottom of it was found by scrolling or not at all.
- **The scroll bar can be grabbed and dragged.** It was drawn as a texture, and a
  texture cannot take mouse input at all - so it showed you where you were in a list
  and gave you no way to act on it, leaving the wheel as the only way down a long one.
  It is a real bar now: drag the thumb, or click the track to page toward the click.
  The wheel still works exactly as before.
- **Fixed: the cue list on the General tab came up empty on the first click** and only
  filled in on the second. Its rows were sized from the scroll frame, which is
  positioned by anchors and so measures zero until a layout pass has run - every row
  was built zero-wide. The same bug was fixed in the other lists a version ago and
  this one was missed, so the scroll helper now repairs a zero-width list itself
  rather than relying on each list to size itself correctly.
- **Lists close when you click away from them.** They stayed open until something was
  selected or the button was pressed again.
- **Fixed: a list could be cut off at the edge of the panel it opened from.** It was
  attached to whichever frame its button sat in, and when that was a scrolling pane the
  list was clipped by it - a scroll frame clips its children. Lists now hang off the
  screen itself, so they overhang the window instead of being cut in half.
- **Fixed: closing the window with Escape left an open list floating on screen.**
  Lists hang off the screen itself now rather than off the window, which is what stops
  a scrolling pane clipping them - and also cut the tie that used to take them down
  with it. A list now watches the control it was opened from and closes when that goes
  away, so it cannot outlive its window however the window was closed. Escape closes
  the list first and the window second, which is the order people expect.

## 0.6.4

- **Fixed: the settings window twitched the first time it was dragged.** It is
  anchored to the centre of the screen, and StartMoving has to convert that relative
  anchor into an absolute position before it can move anything - landing on a
  fractional pixel. That conversion now happens once, rounded, when the window first
  opens, so the first drag has nothing left to convert. It only ever showed up once
  per session, which is why moving the window made it stop.

## 0.6.3

- **Fixed: the Saved... button threw "attempt to call a nil value" and never opened.**
  The picker was placed near the top of the file but calls a scroll helper defined
  hundreds of lines below it, so the call bound to a nil global. Moved below the
  helper it depends on.
- The picker is now **Pick a saved profile...** sitting beside a shortened name box,
  rather than a fourth button crammed next to Save/Load/Delete.
- **Fixed: sliders jumped when clicked.** The value box commits when it loses focus,
  so clicking straight onto a slider re-applied whatever was still in the box over
  the value you had just clicked. It now ignores a commit that matches the live
  value.

## 0.6.2

- A **Saved...** button next to the profile buttons lists what you have saved, so a
  name never has to be typed from memory.
- **Fixed: a pop-up list came up empty the first time and only filled in on the
  second click.** Its width was read from the scroll frame, which is sized by
  anchors and so still measures zero on the frame it was created in - every row was
  built zero-wide. The width now comes from the pop-up's own size, which is known
  immediately.
- Pop-up lists are lifted off the window's near-black background and edged in
  storm-blue, so a floating list reads as sitting on top of the panel rather than
  disappearing into it.

## 0.6.1

- **Fixed: the options window threw an error and the General tab came up blank.**
  The new profile box was built by calling this file's EditBox helper with the
  argument order used by a same-named helper in another nugs addon. It handed back a
  plain frame, setting a text handler on it errored, and construction stopped part
  way down the column - which is why the window opened empty on the second try
  rather than not at all.

## 0.6.0

- **Profiles.** Save the current settings under a name, then load them on any other
  character. Profiles live in the account-wide saved variables, so one made on your
  main is visible from every alt - no strings to copy, no export and re-import.
- Nothing auto-saves and nothing is bound to a character. A change you make simply
  stays until you Save it into a profile or Load a different one over it.
- **Every slider value can be typed.** The number beside each slider is now a box:
  drag to find a value, type to repeat one you already know. Both drive the same
  setting.
- The boxes commit on Enter or when you click away, put the live value back if you
  type something that is not a number rather than zeroing it, and clamp to the
  slider's own range - so a stray extra digit cannot push a setting somewhere the
  slider could never reach.
- The profile section now says which profile is **loaded**, and marks it
  |cffd8a13f(modified)|r the moment you change anything - because after that you are no
  longer on it, and a label that just echoed the last name you clicked would be wrong
  within seconds. Save writes your changes back; Load throws them away.

## 0.5.4 — 2026-07-30

**The interrupted unit's name now shows in combat.** It was silently dropping out,
and the reason is an asymmetry worth naming: a *spell* has an id, so a plain name
can be looked up locally from `C_Spell.GetSpellInfo` — which is why the spell has
always shown. A *unit* has no such path, and in combat `UnitName` hands back a
secret string. The message builder concatenates, a secret may never be joined to
other text, so the name was being discarded.

A secret can still be **drawn**, just not joined. So:

- When the name survives `Plain()` — out of combat, mostly — it reads as one line,
  exactly as before: "Kick > Chaos Bolt on Rageclaw Shaman".
- When it does not, it goes on a **second line of its own** rather than being lost.
  Sized to 80% of the main line and drawn straight into a FontString, which is the
  one thing a secret value is for.
- The unlock preview and the Test button both now show the two-line form, since
  that is the shape it takes in an actual fight.

**Chat cannot carry the secret form** — `print` has to turn its argument into a
string, and that is precisely what a secret will not do. Chat gets the message
without the name; the screen gets both. That one is a limit of the game rather than
a setting, and the options window now says so.

## 0.5.3 — 2026-07-30

The on-screen announcement is now **its own frame** rather than a line borrowed from
Blizzard's error area, which means it can be placed, styled and sized like
everything else here.

- **Movable.** It joins the same lock as the bars, so `/ncb unlock` puts a sample
  message up and lets you drag it, and one command still places the whole addon.
- **It now names your ability and what it stopped** — "Kick > Chaos Bolt on
  Training Dummy". Which of your interrupts was used comes from watching it go off;
  where a class has only one, there was never any ambiguity to resolve. Every part
  is independent, and anything the client will not name plainly is left out rather
  than guessed at.
- **Font, outline, size, colour**, plus hold and fade times, on the General tab.
- The fade is an animation rather than an OnUpdate, so the timing is fixed the
  moment the message appears and there is nothing for Lua to recompute each frame.

## 0.5.2 — 2026-07-30

**0.5.1's announcements never fired.** 12.0 does not let an addon register
`COMBAT_LOG_EVENT_UNFILTERED` at all — the call comes back as
`ADDON_ACTION_FORBIDDEN` on a protected `Frame:RegisterEvent`. It does not need to.

- `UNIT_SPELLCAST_INTERRUPTED` and `UNIT_SPELLCAST_CHANNEL_STOP` carry a fourth
  argument, **`interruptedBy`** — nil when a cast merely ended, set when something
  stopped it. Those events are unit-filtered and already registered by every bar,
  so detection now costs nothing at all and the combat log is gone entirely.
- Ownership is decided best-first: if `interruptedBy` survives `Plain()` it is
  compared against your GUID, which is exact. If it is secret it can still be
  truth-tested — proving the cast was interrupted but not by whom — and ownership
  falls back to whether one of your own interrupts landed in the last 0.7s.
- Target and focus are often the same mob, so one interrupt arrived as two events.
  Announcements inside 0.3s of each other are now the same interrupt, once.
- Your own cast being stopped can no longer be credited to you as an interrupt.

**Bug this exposed:** a channel has no `INTERRUPTED` event of its own — being kicked
arrives as a `CHANNEL_STOP` carrying `interruptedBy`. Without reading it, a kicked
channel finished **green**, as though it had run its course. It now correctly shows
as interrupted.

## 0.5.1 — 2026-07-30

**Announce your interrupts when they land.** Both off by default.

- **Sound** on a successful interrupt, picked from the same media list as the fonts
  and textures, so any LibSharedMedia sound pack shows up in it. Clicking a cue in
  the list plays it.
- **On-screen and/or chat message** — "Interrupted: Chaos Bolt (Training Dummy)" —
  with a Test button next to the setting.
- Only *your* interrupts count, your pet's included, which is what a warlock's
  Spell Lock needs. Identified by GUID, falling back to the combat log's own
  "mine" affiliation bit if the client will not hand the GUID over plainly.
- Nothing secret ever reaches the message: the interrupted spell's name is resolved
  from its id where possible (a plain id looked up locally gives a plain name back),
  and any piece the client kept secret is left out rather than risking a
  concatenation that would error.
- `SPELL_INTERRUPT` from the combat log is the only thing that says an interrupt
  actually *connected* — no unit event distinguishes "the cast stopped" from "you
  stopped it". That event is expensive, so the frame is registered only while an
  announcement is switched on, unregistered again when it is off, and its handler
  drops everything that is not that one subevent before doing anything else.

## 0.5.0 — 2026-07-30

**Interrupt-aware colouring**, the way Plater does it: an interruptible cast is
coloured by whether *your* interrupt is off cooldown.

- Two independent toggles per bar — **interrupt ready** and **interrupt on
  cooldown** — each with its own colour, so you can flag only the state you care
  about and leave the other on the normal casting colour. On out of the box for
  **Target** and **Focus**; available on **Boss** but not assumed.
- These take **priority** over the casting and channelling colours on that bar. A
  cast that *cannot* be interrupted keeps its own colour either way — it is never
  claimed to be kickable.
- The colour flips live when your kick comes off cooldown mid-cast.
- Your interrupt is detected from your class and spellbook. `/ncb diag` prints what
  it found and whether it is ready right now, and the General tab takes a
  comma-separated list of spell ids to override the detection.

How it works, because it looks impossible under 12.0: the question is two facts
ANDed together — whether the cast can be interrupted, which is a **secret boolean**
that may never be branched on, and whether your interrupt is ready, which is not
(`C_Spell.GetSpellCooldown` returns `isActive` and `isOnGCD` flagged NeverSecret).
The AND is never computed. An overlay is *tinted* by the plain half and *revealed*
by the secret half via `SetAlphaFromBoolean`, inverted against the shield so it
appears only on a cast that really can be interrupted. Nothing in Lua ever learns
which.

## 0.4.6 — 2026-07-28

- A single line in the options window - "Part of the nugs suite" - shown only when
  nugsSuite is not installed. A note, not a warning, and not a dependency: this
  addon works exactly the same on its own, and the suite is only worth having once
  you run more than one of them.

## 0.4.5 — 2026-07-28

- The minimap button no longer shows a sliver of the world between the icon and the
  tracking border. The border's hole is slightly wider than the icon was, leaving a
  thin see-through ring; there is now a dark disc behind the icon, and the icon
  itself went from 19 to 21 pixels.

## 0.4.4 — 2026-07-28

- Registers with **nugsSuite**, the new hub addon: it can now list this addon, open
  this window, fold this minimap button into its own, and carry these settings to
  another character as part of one profile string.
- The registration is a single entry written into a plain global table. nugsSuite
  does not have to be installed for it to be harmless, and does not have to load
  first for it to be found - so nothing here changes if you never install it.
- The measured cast-length cache (`learned`) and the minimap button's angle are
  marked as never exported. The first is machine-written and by far the largest
  thing in the saved variables; the second is nobody else's business.

## 0.4.3 — 2026-07-28

- CurseForge project id (**1629882**) recorded in the .toc, so addon managers can
  tie an installed copy back to the project and offer updates.

## 0.4.2 — 2026-07-28

- The N now sits **on** the bar rather than above it, where a spell name sits on a
  real cast bar: left of the fill edge, with the spark clear to its right and the
  empty track beyond. A dark halo, produced by resampling the glyph around a ring
  of offsets, keeps it legible over the lit fill.
- A letter big enough to span the bar was tried first and rejected: it occluded the
  very thing the mark is of, leaving the fill visible only as stubs either side of
  the glyph.

## 0.4.1 — 2026-07-28

- The icon now carries the **N**, in the same bold geometric letterform as
  nugsCooldownPulse's `ringN`, so the two sit together in the addon list as one
  suite. Composed as a nameplate — the letter above, its cast bar beneath — rather
  than copying the ring, so the pair are siblings and not twins. The glyph is drawn
  from the same stroke-to-cap ratio (0.24) as `ringN`.
- The bar is a little taller and its rim a little stronger: at addon-list and
  minimap sizes the unfilled half of a track that dark otherwise vanishes into the
  backdrop.

## 0.4.0 — 2026-07-28

**0.3.0 was wrong.** It said timers and interruptibility on another unit's cast
were unknowable in 12.0. They are not — ElvUI and Plater both show them, and
reading oUF's castbar element on disk turned up a purpose-built API for exactly
this that I had not known existed.

The principle I had backwards: a secret value is not a wall, it is a *pipe*. The
client gives you something you may not read but may hand to a widget, and the
widget does the work.

- **Real countdowns on every unit.** `UnitCastingDuration` / `UnitChannelDuration`
  / `UnitEmpoweredChannelDuration` return a Duration object;
  `StatusBar:SetTimerDuration(obj, interpolation, direction)` makes the bar animate
  itself in the right direction at the right speed, and
  `Duration:GetRemainingDuration()` feeds `FontString:SetFormattedText()` a real
  number. Nothing passes through Lua, so nothing has to be readable. This is now
  the primary drawing mode — `timer` — for **all** bars.
- **Interruptibility is back.** `Texture:SetAlphaFromBoolean(secretBool, 1, 0)` is
  the display sink for a secret boolean. The shield icon uses it directly, and the
  "cannot be interrupted" colour is now an overlay pinned to the fill texture whose
  alpha that same boolean sets — so the bar changes colour without any code ever
  branching on the value.
- **`UnitSpellTargetName` / `UnitSpellTargetClass`** replace the hand-rolled
  `unit.."target"` snapshot: the spell's actual target, straight from the client.
- **`barID`**, the tenth return of `UnitCastingInfo` in 12.0 (added because castID
  went secret), is a plain cast identity and is now what two casts are compared by.
- **Empower stage pips** are drawn from `UnitEmpoweredStagePercentages`. Which
  stage is *currently* held is genuinely unknowable now — oUF notes Blizzard is
  aware — so the pips mark boundaries and nothing tracks the current one.
- Channels count down and casts count up via `StatusBarTimerDirection`, so the
  0.3.0 caveat about channels filling instead of draining is gone.
- The 0.3.0 paths all survive as fallbacks, in order: `timer` → `timed` →
  `secret` → `guessed` → `unknown`. `/ncb diag` names the mode in use and reports
  whether the client offers the timer API and secret-boolean display at all.
- "Elapsed" and "elapsed / total" formats need a subtraction the values may refuse;
  it is attempted and falls back to time-remaining rather than to nothing.

## 0.3.0 — 2026-07-28

The target bar was not missing events. It was **erroring**, 40 times, on the first
thing it touched.

Confirmed from BugSack on retail 12.0.7: for another unit's cast,
`UnitCastingInfo` returns **every** field secret — name, icon, start, end, castID,
`notInterruptible` and spellID. Two rules came out of it, and the whole file now
obeys them:

- A secret **string or number** may be truth-tested and handed to a display sink
  (`SetText`, `SetTexture`). It may not be measured, concatenated, compared or
  computed with. (`if name then` was fine; that is why the error landed further
  down the table constructor.)
- A secret **boolean** may not even be truth-tested — branching on it is exactly
  the leak the system exists to prevent. That was the crash: `notInterruptible and
  true or false`.

Fixes:

- Every boolean out of a unit API now goes through `Plain()`, giving a
  true/false/**nil** tri-state where nil honestly means "not allowed to know".
  Interruptibility on another player's cast now reads unknown rather than crashing
  — the bar takes its normal colour and the shield stays down.
- **New "secret" drawing mode, and it is accurate.** The client's own timestamps
  are handed straight to `StatusBar:SetMinMaxValues`, and the bar is fed
  `GetTime()` each frame. Nothing in Lua ever reads them, so being secret does not
  matter and the widget does the division. This draws a *correct* bar for another
  player's cast — no timer text, since we never learn the fraction, and channels
  fill rather than drain. If the widget refuses the values we find out once and
  drop back to the remembered-length or sweep modes.
- **The spark is now pinned to the moving edge of the fill texture** instead of
  being positioned by arithmetic, so it tracks a bar whose scale we are not
  allowed to read.
- Spell and target names are never measured or concatenated when secret: trimming
  passes them through whole, and the cast target falls back to its own line with
  `SetTextColor` instead of embedded colour codes.
- `UnitExists` calls removed from the cast path — it returns a boolean, and
  `UnitName`/`UnitCastingInfo` answer the same question by returning nil.
- `/ncb diag` reports each bar's drawing mode (timed / secret / guessed / unknown),
  whether times are readable, and interruptibility as can / cannot / unknown —
  and prints no secret value, since `string.format` will not take one either.

## 0.2.0 — 2026-07-28

Chasing a report that the target bar did not appear for another player's cast.
No cause was proven, so this build makes the bar not depend on the event stream
being perfect, and adds the tools to prove where the fault is next time.

- **Polling safety net.** Five times a second, every enabled bar checks what its
  unit is actually casting and starts, replaces or ends its bar to match. Events
  remain the fast path; this catches anything they miss. Demos, previews and bars
  mid-fade are left alone.
- **Unit-event filters are re-armed** whenever a target, focus or pet slot
  changes, so a filter can never go stale behind a swapped unit token.
- **`/ncb diag`** reports, per bar: enabled, whether the unit is there, whether
  the frame is shown, its alpha, size and position, whether its events are
  registered, and what the client says that unit is casting this instant.
- **`/ncb debug`** logs every spellcast event as it arrives, so a missing bar can
  be told apart from a missing event.
- The poll only calls a vanished cast "interrupted" when it knew the length and
  the cast stopped short of it; without that evidence it reports a finish.

## 0.1.0 — 2026-07-28

First build.

- Bars for **player, target, focus, pet and boss1–boss5**, each with its own
  config: texture, width, height, scale, border, spark, icon (side / crop / gap),
  font, outline, size, spell name with alignment and trimming, timer (remaining /
  elapsed / elapsed-total, 0–2 decimals), hold and fade times, and eight colours.
- **Cast target display** — who the cast is aimed at, snapshotted at cast start,
  shown inline, below the bar or to the right; class-coloured, and red when the
  cast is on you.
- **Uninterruptible casts** get their own bar colour and a shield icon.
- **Latency tail** on the player bar.
- **Empowered casts** draw a divider at each stage boundary.
- Optional per-unit **suppression of Blizzard's own cast bars**.
- Options window in the RaidReady / nugsCooldownPulse skin: tab per bar, two
  columns of settings that re-flow around whatever does not apply to the bar you
  are on, a media picker that previews fonts in their own font and bar textures as
  actual bars, and the game's colour picker behind every swatch.
- **Unlock mode** shows a looping demo cast on every enabled bar so you can place
  them against something real. `/ncb test` does the same without unlocking.
- "Use this bar's look everywhere" copies style without touching sizes or
  positions.
- Minimap button (left click options, right click lock/unlock), `/ncb` with
  subcommands, and a stub in the Blizzard settings list.
- Cast timing is laundered through `Plain()`: where the client will not hand over
  usable start/end times, the bar times the cast itself off `GetTime()` and falls
  back to the length it last measured for that spell, marking the timer with `?`.
  With no measurement to fall back on it sweeps and shows no number rather than
  inventing progress.
- Icon generated by `..\nugsCastBars-art\icon.js` (dependency-free node renderer
  and BLP2 writer, kept outside the addon folder so it never lands in a release
  zip).
