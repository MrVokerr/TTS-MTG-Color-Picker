# TTS-MTG Color Picker

Drop-in [Tabletop Simulator](https://www.tabletopsimulator.com/) object for Oops-style MTG tables. Paste the script onto a token, drop it on the table, and tint each seat’s board chrome and playmat line-work without editing Global.lua or any other Lua files.

**Script:** [`Seat Color Picker.lua`](Seat%20Color%20Picker.lua)  
**Design notes:** [`seat-color-picker.md`](seat-color-picker.md) — read before changing the picker so we don’t re-try dead ends.

---

## Goals

| Goal | Status |
|------|--------|
| Drop-in object; paste script; works on Oops **4p** | Done |
| Works on Oops **6p / 8p** | **TODO** — currently 4p only |
| **No edits** to Global.lua or other Lua *files* | Done (hard constraint; runtime-only mutation allowed) |
| Custom RGB tint for board chrome (life, timers, CMD, hand counts, …) | Done |
| Recolor playmat **line-work** only (not a wash over the art) | Partial — vector overlay works, but **color can show through** (see TODO) |
| Auto-align overlay to table deck/GY zones | Done on 4p (Technique K) |
| Persist across save / load / rewind | Done (`onSave` + `script_state`) |
| On-screen HUD picker (not world-space above the table) | Done (Global `UI`) |
| Recolor TTS chat name / player list / pointer | Done for **stock palette** via hand-zone engine swap (Technique J); arbitrary hex still impossible |
| In-game mat calibrate (±0.1) for fine pads | Done (Calibrate mat… panel) |

### TODO

- **Playmat line-work overlay** — fix so no color shows through (lines should read clean over the mat art, not as a tint wash / bleed).
- **6p and 8p tables** — picker currently only works correctly on the **4p** Oops table; extend zone align + cosmetics so 6- and 8-player layouts work the same way.

---

## Install / use

1. Create any object (e.g. a Custom Token) in TTS.
2. Paste the contents of `Seat Color Picker.lua` into that object’s script.
3. Drop the object on an Oops MTG table (4p today).
4. Click **Color** → pick hue / SV / hex → **Apply** for mat line-work + board widgets.
5. Optional: use the **engine seat row** to swap to another stock TTS player color (chat / list / pointer).
6. Optional: **Calibrate mat…** for ±0.1 pads if the overlay needs a nudge.

---

## Hard constraints

### 1. Picker-only — do not edit other Lua *files*

Import **one object** onto a workshop table without touching other scripts.

Runtime mutation of other objects (Descriptions, `reload()`, `Global.setTable` aliases, `Global.setVectorLines`) is allowed — shipped mod scripts are never edited.

Cosmetics that widgets reset on `onload` / `onPlayerTurn` must be **re-applied from the picker** (sticky loop + delayed `Wait.time` bursts).

### 2. Don’t use `Player.changeColor` alone

Scripts and zones key off **seat name**. Changing seats mid-table without migrating the hand zone breaks Oops tables (hand counters spam nil hand errors).

Working recipe (**Technique J**): re-value the hand zone → migrate the player → fix everything keyed off the old name. Chat/list/pointer only ever get another **stock** palette color, never an arbitrary hex.

### 3. Engine chrome follows Player Color

Chat name, player list, and pointer accent always use the seated Player Color. No Lua API for custom RGB there — only stock swaps via hand zones.

TTS has **12** named colors; only **10** are useful seats (Grey = spectator, Black = host/GM).

### 4. Playmat outline is baked into the table texture

Colored outlines are part of the custom table texture, not a separate object. Shipped approach: **vector line-work overlay** (`Global.setVectorLines`), auto-aligned to deck/GY zones — not a full-mat wash.

---

## Architecture

```
Seat Color Picker object
  ├─ 3D button "Color"     → open / right-click reset tint
  ├─ onSave / script_state → { seats, swaps }
  ├─ Global UI (picker)    → SV grid + hue + hex + Apply + engine palette
  ├─ Global UI (calibrate) → ± pads for mat overlay
  ├─ applySeatCosmetics    → whitelist scan + sticky re-apply
  ├─ rebuildSeatBorders    → vector loops (zone-aligned)
  └─ engine swap           → hand setValue + changeColor + Global aliases + widget reload
```

### Two color paths

| Path | What it changes | Engine chat / list? |
|------|-----------------|---------------------|
| **Apply / hex / SV grid** | Mat line-work + board widgets only | No |
| **Engine seat row** | Real seat color (stock palette) **and** paints mat/widgets with that stock RGB | Yes |
| After an engine swap, **Apply** again | Custom mat hex on top of the new engine seat | Seat stays swapped |

### Overlay alignment (Technique K)

Primary: map image **deck** box → `data[seat].libraryZone`, image **graveyard** box → `data[seat].graveyard`. Scale/rotation from distance/direction between those world positions.

Fallback: Art Playmat enabler hand-math if zones are missing.

Fine pads: `scale`, `offsetRight`, `offsetFwd`, `flipX`, `flipZ`, `borderY`, `lineThickness`.

**Whitelist:** life tracker, highlight mat, commander damage, rhystic, commander zone, hand counter (+ self), timer.  
**Skip:** turn skipper, mana, hand counter screen, art playmat surface.

---

## What we paint vs skip

### Paint

| Target | Method |
|--------|--------|
| Life Tracker, Commander Damage, Rhystic | mesh tint |
| Highlight Mat | turn glow @ low alpha |
| Timer | mesh + digit fonts |
| Hand Counter / Self | label `font_color` |
| Commander Zone | value `font_color` |
| Playmat line-work | vector loops (zone-aligned) |

### Skip

| Target | Why |
|--------|-----|
| Art Playmat surface | Full-mat tint washed the art |
| Turn Skipper | Tint encodes seat for skip logic |
| Hand Counter Screen | Black hide plate |
| Mana / Ready / importers | Out of scope |
| Life tracker chat text | Hard-coded `ownerRGB` |
| Engine UI with arbitrary hex | Stock palette via Technique J only |

---

## Techniques (keep / avoid)

| Technique | Verdict |
|-----------|---------|
| **A** Patch every widget + Global API | **Don’t** under drop-in constraint |
| **B** Tint-only scan | Incomplete — need sticky re-apply |
| **C** Full-mat translucent wash | **Don’t** — washes art |
| **D** Object-attached `self.UI` | **Don’t** — floats in the sky |
| **E** Global screen UI | **Keep** |
| **I** Vector line-work overlay | **Keep** (fix bleed-through — TODO) |
| **J** Hand-zone engine swap | **Keep** |
| **K** Deck + GY zone auto-align | **Keep** as primary (extend to 6p/8p — TODO) |
| **L** In-game calibrate panel | **Keep** |

---

## TTS API lessons

- **`onSave()` must return** the JSON string. Keep both `onSave` + `script_state`.
- Infinite sticky loop: `Wait` with `repetitions = -1`.
- Use `btn.index` in `editButton`; preserve font alpha; skip near-black / near-white fonts.
- Use `UI.show` / `UI.hide` (not `active`) for FadeIn/FadeOut.
- Global UI callbacks: `onClick = self.getGUID() .. '/onCalNudge'`.
- Button clicks often pass `value = -1` — put the real key in the **element id**.
- Lua patterns have **no** `|` alternation — match `calDec_` / `calInc_` separately.
- Label `Text` needs `raycastTarget=false` or it steals calibrate clicks.
- 3D “Color” button: `{0, 180, 0}` upright; hide while HUD open.

---

## Verification checklist (manual in TTS)

1. Sit a seat → open picker → **on-screen** panel; “Color” button upright; hides while open.
2. Hue strip rainbow; Apply custom hex → widgets + **line-work** update (not a wash over art).
3. Opening **Calibrate mat…** broadcasts align mode (deck/GY zones or hand fallback).
4. Deck / graveyard rectangles sit on the real library + GY zones for that seat.
5. Calibrate ± updates and redraws live; Print dumps `matCal` to chat.
6. Pen drawings survive Apply (sentinel thickness).
7. Turn / sticky: highlight still correct.
8. Save / reload: seats + swaps + loops restored.
9. **Engine swap** → chat / list / pointer update; **no** hand-counter spam.
10. Engine swap → Apply custom hex → mat uses hex, engine seat stays swapped.
11. Apply alone → mat/widgets only; chat color unchanged.
12. Revert to original seat.
13. **TODO:** repeat on 6p/8p once supported.
14. **TODO:** confirm line-work has no color bleed-through on the mat art.

---

## FAQ

| Ask | Answer |
|-----|--------|
| “Can we change chat / player list?” | Stock palette only (Technique J). No arbitrary hex. |
| “Can we change the playmat trim?” | Vector overlay (I), auto-aligned to deck/GY zones (K). Color bleed-through is a known TODO. |
| “Why not align to the hand zone?” | Hand sits *below* the printed mat; overlay floated on the wood. |
| “Why deck + graveyard?” | Those zones exist per seat in Global `data`; centers lock scale/rotation. |
| “More engine colors than the 10?” | No — TTS only has 12 names; Grey/Black aren’t usable seats. |
| “Apply vs engine row?” | Apply = cosmetics only. Engine = real seat + stock mat tint; Apply can still override mat later. |
| “Works on 6p / 8p?” | Not yet — 4p only; see TODO. |
| “UI in the sky?” | Global `UI`, not `self.UI`. |

---

## License

No license file yet — all rights reserved unless otherwise stated by the author.
