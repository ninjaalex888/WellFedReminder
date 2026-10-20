# Well Fed Reminder

A lightweight addon for **WoW Forever** that flashes a food icon whenever you're missing the
**Well Fed** buff, counts down while you eat, and warns you before Well Fed runs out. No WeakAuras needed.

| You are | What you see |
|---|---|
| Not Well Fed | A red-bordered food icon flashing near the middle of the screen, plus a raid-warning sound when Well Fed drops |
| Eating | A green border and a countdown of the 10 seconds until Well Fed lands |
| Running out | A pulsing yellow border counting down the last 2:00 (change it with `/wellfed warn`) |
| Well Fed | Nothing |
| In a city or inn | Nothing, fed or not (`/wellfed city` turns this off) |

The icon also stays out of the way while you're dead or on a flight path, and in combat by default.

## Install

1. Download `WellFedReminder-<version>.zip` from the [latest release](https://github.com/ninjaalex888/WellFedReminder/releases/latest).
2. Extract it into the WoW Forever client's `Interface\AddOns` folder, so you end up with
   `Interface\AddOns\WellFedReminder\WellFedReminder.toc`. During the beta the client folder is `_classic_beta_`.
3. Restart the game (or `/reload`) and check that **Well Fed Reminder** is ticked in the AddOns list at character select.

The green **Code → Download ZIP** button works too, but rename the extracted folder from
`WellFedReminder-main` to `WellFedReminder`. WoW only loads an addon whose folder name matches its `.toc`.

If the addon shows as out of date, your client is newer than interface `16001` (Forever 1.60.1).
Get the current number with `/dump select(4, GetBuildInfo())` and put it on the `## Interface:` line of
`WellFedReminder.toc`, or tick **Load out of date AddOns**.

## Commands

Type `/wellfed` or `/wfr` on its own to list these in game, along with your current settings.

| Command | What it does |
|---|---|
| `/wellfed unlock`, `/wellfed lock` | Unlock to drag the icon where you want it, then lock it in place |
| `/wellfed test` | Preview the flashing reminder for 10 seconds |
| `/wellfed warn <seconds>` | How early to warn before Well Fed runs out (default 120, `0` turns it off) |
| `/wellfed scale <0.5-3>` | Icon size |
| `/wellfed combat` | Keep showing in combat, counting down from the last reading (off by default) |
| `/wellfed instance` | Only remind inside dungeons and raids (off by default) |
| `/wellfed city` | Hide in cities and inns, fed or not (on by default) |
| `/wellfed sound` | Alert sound when Well Fed drops (on by default) |
| `/wellfed add <buff name>`, `remove <buff name>`, `list` | Which buffs count as being fed |
| `/wellfed on`, `/wellfed off` | Turn the reminder on or off |
| `/wellfed status` | What the addon sees right now |
| `/wellfed reset` | Restore all defaults |

Settings are saved account-wide.

## Notes for WoW Forever

- **Combat restrictions.** Forever runs the modern (Midnight 12.x) addon API, which hides aura data from
  addons during combat, boss encounters and PvP matches. The addon reads your buffs only when those
  restrictions are off and checks every value with `issecretvalue()` before using it. In combat the icon
  hides; `/wellfed combat` keeps it up instead, counting down from the last reading.
- **Cities.** The addon goes by the game's rested state (the `zzz` on your portrait), which covers the
  capital cities and inns.
- **Other buff names.** It looks for buffs named "Well Fed", plus the client's own name for it on
  non-English clients. If a food's buff shows up under a different name, add it with `/wellfed add <buff name>`.
