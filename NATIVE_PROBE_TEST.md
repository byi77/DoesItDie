# In-game test: `/did native`, round 2b (aura strips side by side, issue #49)

Test branch only. Round 1 showed the game's aura frames draw on the target frame and nameplates in combat, nothing
can be read back from them, and the skull pinned to a strip's end works. Round 2 draws the strips the way a real
feature would: **one strip per DoT, end to end**.

`/reload` is enough this time; no new files.

What you'll see while it's on, in the **lower half** of the target frame's bar and of the target's nameplate:

- One strip per DoT, each in its own color: Rake (cyan), Rip (pink), Moonfire (green), Insect Swarm (yellow),
  Lacerate (orange, scaled by its stacks, with the count above the bar's left end). Each is shown by the game only
  while that DoT is on the mob, and drains with its real time left.
- Each strip starts where DoesItDie's own numbers say the DoTs before it end (round 2's first try pinned each strip
  to the end of the one before, and Rip never showed: `/did native chain` switches back to that layout to compare).
- Each strip is as long as DoesItDie's own estimate of that DoT when it was applied, so the chain should end about
  where DoesItDie's marker ends. It drains smoothly where the marker steps down per tick.
- A small skull at the end of each strip, shown only once that strip ends past the green.

## Checklist

1. `/did native` (if it's not still on from last time). `/did native status` should say "chain Rake, Rip, Moonfire,
   Insect Swarm, Lacerate".
2. Rake, then Rip. Do you see two strips, Rip's starting where Rake's ends, together ending about where DoesItDie's
   marker ends?
3. Let Rake run out while Rip is still up. Does Rip's strip move left to the bar's start once Rake is gone?
4. A fresh mob: only Rip, no Rake. Does Rip's strip start at the bar's left end?
5. Moonfire on top (from caster form). Does it join the chain after Rip?
6. Bear: Lacerate three times. Does the orange strip grow with each stack and the count read 1, 2, 3?
7. A mob at low health: does the skull at the chain's end show when the chain passes the green, and not before?
8. `/reload` and tell me. I'll read the log from your SavedVariables folder.

A DoT that isn't on the druid list gets its own strip after your first cast of it, starting with your next time out
of combat. `/did native` turns it all off.
