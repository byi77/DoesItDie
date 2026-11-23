# In-game test: `/did native` (issue #49, AuraContainer)

Test branch only. The probe draws Blizzard's own aura frames on your target frame and the target's nameplate and
logs what the addon can read back. Its log is `DoesItDieDB.nativeLog` in
`_forever_\WTF\Account\<account>\SavedVariables\DoesItDie.lua`, saved on `/reload` or logout.

**Restart the game client first.** `NativeProbe.lua` is a new file, so a `/reload` won't pick it up.

What you'll see while it's on:

- **Cyan strip** (lower half of the health bar): drawn by the game while one of your DoTs is on the mob. Its length is
  that DoT's damage times the time left (the size comes from DoesItDie's own estimate when you cast).
- **Orange strip** (upper half; druid or rogue only): Lacerate or Deadly Poison, with its length also scaled by the
  stack count. The stack count shows above the bar's left end.
- **Percentage** above the bar's right end: time left, as the game formats it.
- **Small skull on the bar**: the position-only kill icon. It should appear only when the cyan strip reaches past the end
  of the green.

## Checklist

1. Out of combat, target a mob and type `/did native`. The chat should say "Native probe ON".
2. Cast Moonfire. Do the cyan strip and the percentage show on the target frame **and** on the nameplate, and shrink
   until Moonfire runs out? Do they disappear when it ends?
3. Pull a mob and keep a DoT on it through the fight. Does the strip still show and drain **in combat**?
4. Low-health test: get a mob low enough that one DoT would kill it. Does the bar skull appear when the cyan strip
   passes the end of the green, and not before?
5. Type `/did native base`. The cyan strip now starts where DoesItDie's own marker ends. It counts the same DoT
   twice, so the skull showing early is expected; this checks that the strip can be chained after our total.
6. Bear form: Lacerate three times. Does the orange strip grow with each stack, and does the count read 1, 2, 3?
7. Put a DoT on two mobs and tab between them. Does the strip follow the target each time?
8. If you can, repeat step 2 on one pull in a dungeon.
9. `/reload`, then send me the SavedVariables file, or tell me to read it from your WTF folder.

`/did native` again turns it off. It stays on through `/reload` until you do. Other commands:
`/did native 500` sets the strip to 500 damage, `/did native auto` goes back to your DoT's own size, and
`/did native status` shows what's on.

Anything odd (nothing shows, Lua errors, frames in the wrong place), a screenshot helps.
