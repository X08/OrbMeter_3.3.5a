# OrbMeter

**A small orb that shows your damage or healing per second, with a threat ring. A simple, refined overview instead of a full meter window.**

Made by **X08 | Dreamwind (ChromieCraft-EU)**
Version 1.0 · World of Warcraft **3.3.5a** (Interface 30300) · Part of the X08 addon suite

---

## What it does

OrbMeter sits on your screen as one small orb. It shows your DPS or HPS as a number, coloured by how you rank in your group. Hover it for your top abilities, right-click it for reports. It is built to answer "how am I doing?" at a glance, not to be a full damage-meter window.

- **Orb:** your damage or healing per second, abbreviated (`1.1K`, `2.3M`). The colour runs from blue (low in the group) to red (top damage) or green (top healing). Solo, it stays neutral because there is nobody to compare against.
- **Threat ring:** an outer ring that fills clockwise as your threat on your target climbs toward whoever holds aggro, and is full red when you pull. It works for everyone, not just tanks.
- **Hover overview:** your top 8 abilities with icon, amount and share, as blue bars. It shows the fight in progress marked `(Current)`, otherwise the last fight `(Last)`, or the total since reset `(Total)` if you choose that. Your choice of Last or Total is in the options.
- **Adaptive tracking:** the orb follows what you cast. Three damage spells in a row switch it to Damage; three healing spells switch it to Healing. A healer who starts nuking, or a caster who heals, sees the number that matters. Spec and form only set the starting mode, and only out of combat. A left-click pins the mode by hand.
- **Group-wide:** damage and healing are tracked for your whole party or raid, pets and guardians included, so the orb's colour and the reports compare you against real numbers.
- **Reports:** post a Top 5 to Say, Party, Raid or Guild, or print your own breakdown locally.

## Install

1. Download the latest release.
2. Copy the **`OrbMeter`** folder into `World of Warcraft/Interface/AddOns/`.
3. Restart the game, or `/reload` if you are already in.

The folder must be named `OrbMeter` and contain `OrbMeter.toc`, `OrbMeter_core.lua`, `OrbMeter_visual.lua` and the `media` folder.

## Using it

| Action | What happens |
|---|---|
| **Hover** the orb | Ability overview for the current mode |
| **Left-click** | Switch Damage <-> Healing by hand (pins the mode) |
| **Right-click** | Menu: Personal Stats, Report To, Options, Reset Logs |
| **Drag** (when unlocked) | Move the orb |

### Right-click menu

- **Personal Stats > Damage / Healing:** prints your breakdown to your chat window: the fight in progress (only while there is one), the last fight, then the total. Each block shows totals, your share of the group, and per ability: amount, share, crit chance and misses (auto-attack included).
- **Report To > Say / Party / Raid / Guild:** posts a Top 5 for the last fight or the total, ranked by total **Damage Done** or **Effective Healing**, with each member's rate and share of the group. While a fight is going, "Current Fight" entries appear too. "Last Fight" always means the previous completed fight, never the one in progress.
- **Options:** opens the settings window.
- **Reset Logs:** wipes the recorded data. Data also clears on logout or reload.

Example of a posted report:

```
OrbMeter - Last Fight - Top 5 Damage Done (53.4s):
1. Lunaaru - 179.1K (3.4K DPS, 35%)
2. Dunwgol - 128.8K (2.4K DPS, 25%)
3. Lorelhei - 100.8K (1.9K DPS, 20%)
4. Alteracmack - 88.5K (1.7K DPS, 18%)
5. Dreamwind - 8.1K (152 DPS, 2%)
```

### Options window

Open it from the right-click menu or with `/om options`. Every setting is also a slash command. The `?` button next to the title explains the addon.

- Lock position
- Dim out of combat, and the opacity it dims to
- Orb size
- Adaptive Tracking (Damage/Healing), with a hover explanation
- Hover overview shows: Last Fight or Total

### Slash commands

`/orbmeter` or `/om`

| Command | Effect |
|---|---|
| `/om options` | Open the options window |
| `/om unlock` / `/om lock` | Show the border and allow dragging / lock it again |
| `/om size <28-96>` | Orb size (28 is the default and the minimum) |
| `/om adaptive [on\|off]` | Orb follows what you cast (toggles if no argument) |
| `/om hover last\|total` | What the hover overview shows |
| `/om combat` | Toggle dimming out of combat |
| `/om alpha <0-100>` | Opacity (%) the orb dims to out of combat |
| `/om reset` | Reset the recorded logs |
| `/om debug` | Print the tracking core's raw numbers (useful for bug reports) |

## How the numbers are counted

- **Damage** = amount - overkill + damage the target's shield absorbed. Overkill is not counted.
- **Effective healing** = heal amount - overhealing. Damage a shield actually absorbs is credited to the shield's caster as healing. Shields that expire unused earn nothing.
- **Pets and guardians** are credited to their owner, for you and for other players.
- **Soul Link:** damage redirected to a pet is netted out before shield credit.
- **Damage shields** (Thorns, Lightning Shield, Retribution Aura and similar) count for the wearer.
- **Fights are shared.** When other players are in the fight, it runs from the first hit to the last hit by anyone, and everyone's rate is divided by that same window. A lingering combat flag (a healer's HoTs, for example) cannot stretch it. If nobody in the group deals damage for 8 seconds, the fight ends and the next hit starts a new one. Healing never starts or extends a fight. Everyone's DPS in your group therefore lines up with everyone else's. In testing, four clients in one group agreed within about 0.1%.
- **Spec and form** pick the starting mode (healer specs start in Healing). They are only re-read out of combat, so they never fight with adaptive tracking.
- Works on **non-English clients**: it matches by spell ID, GUID and icon, not by names.

## FadeOut integration (optional)

If the **FadeOut** addon is installed, OrbMeter registers with it as "Orb Meter". FadeOut then owns the orb's dimming and the built-in dim and opacity options are ignored. The options window says so: *FadeOut addon DETECTED - Dimming is ignored*. Untick "Orb Meter" in `/fadeout` to go back to the built-in dimming (the window then reads *Dimming not set*). Without FadeOut nothing changes.

## Compatibility and known limits

- Built for the **3.3.5a** client. Not for retail or other versions.
- Needs the combat log within range. Members far away or in another zone are not seen.
- Item procs are counted as casts by adaptive tracking, so a trinket proc can add one to the run.
- Healing ticks that land after a fight has ended are not counted.
- Threat percentages assume the standard 3.3.5a meaning of `UnitDetailedThreatSituation`.

## Saved variables

`OrbMeterDB` stores your settings (position, size, lock, dimming, adaptive, hover choice, options window position). Recorded damage and healing are **not** saved.

## Reporting bugs

Run `/om debug` right after the problem and include the line, along with your class, spec, group size and what you expected. Bugs, ideas and feedback are welcome.

## Changelog

**1.0**
- First public release.
- Orb with DPS/HPS number and relative colour, threat ring, hover ability overview (Current / Last / Total).
- Top 5 reports (Say, Party, Raid, Guild) and Personal Stats printouts.
- Adaptive tracking: three damage or healing casts in a row switch the orb. Spec and form only decide the mode out of combat.
- Shared group fight window, so everyone's rates line up.
- Options window mirroring the slash commands, with a `?` help button.
- Optional FadeOut integration.
- Pets, guardians, shield absorbs, Soul Link and damage shields are handled; non-English clients supported.

## Credits

Made by **X08 | Dreamwind (ChromieCraft-EU)**. The orb's look and its pie-wheel texture follow the style of GCDDot, from the same suite.
