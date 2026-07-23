# Seat Color Picker — design notes & lessons learned

Living notes from building [`seat-color-picker.lua`](seat-color-picker.lua).  
**Read this before changing the picker** so we do not re-try dead ends.

Related short install/use guide: [README.md](README.md).

---

## Goals (what “done” means)

| Goal | Status |
|------|--------|
| Drop-in object; paste script; works on Oops **4p / 6p / 8p** | Done |
| **No edits** to Global.lua or other Lua *files* | Done (hard constraint; runtime-only mutation allowed) |
| Custom RGB tint for board chrome (life, timers, CMD, hand counts, …) | Done |
| Recolor playmat **line-work** only (not a wash over the art) | Done (vector overlay) |
| Auto-align overlay to table deck/GY zones (all seats / table sizes) | Done (Technique K) |
| Persist across save / load / rewind | Done (`onSave` + `script_state`) |
| On-screen HUD picker (not world-space above the table) | Done (Global `UI`) |
| Recolor TTS chat name / player list / pointer | Done for **stock palette** via hand-zone engine swap (Technique J); arbitrary hex still impossible |
| In-game mat calibrate (±0.1) for fine pads | Done (Calibrate mat… panel) |

---

## Hard constraints we locked in

### 1. Picker-only — do not edit other Lua *files*

We **planned** Global helpers (`getSeatCosmeticRgb`) + patches to Life Tracker, Hand Counter, Highlight Mat, etc.

**Rejected because:** user must be able to import **one object** onto any of the three workshop tables without touching other Lua files.

**Refined later:** *runtime* mutation of other objects (rewriting Descriptions, `reload()`, `Global.setTable` aliases, `Global.setVectorLines`) is allowed — the mod's shipped scripts are never edited, so the picker stays drop-in.

**Implication:** cosmetics that widgets reset on `onload` / `onPlayerTurn` must be **re-applied from the picker** (sticky loop + delayed `Wait.time` bursts). Chat `printToAll(..., ownerRGB)` in Life Tracker stays stock seat color forever unless that script is edited.

### 2. `Player.changeColor` alone breaks the table — swap the hand zone instead

Scripts and zones key off **seat name** (Description prefixes, `data[color]`, `deckDirs[color]`). Naively changing seats mid-table breaks Oops tables — hand counters spam *"Object reference not set to an instance of an object"* every second because their `Wait.time` loops poll `Player[oldColor].getHandObjects()` after the old seat's hand zone is gone.

The working recipe (Technique J) is: re-value the hand zone, *then* migrate the player, *then* fix everything that keyed off the old name. Chat/list/pointer only ever get another **stock** palette color (Teal, Pink, …), never an arbitrary hex.

### 3. Engine chrome follows the Player Color — but the Player Color can be swapped

Chat name color, the top-right player list, and the pointer accent always render in the seated Player Color. There is **no** Lua API for custom RGB on those — but since TTS seats are defined by **hand zones**, re-valuing a seat's hand zone to an unused stock color (then `changeColor`-ing the player onto it) changes the engine color for real. See Technique J.

TTS has exactly **12** named player colors: White, Brown, Red, Orange, Yellow, Green, Teal, Blue, Purple, Pink, Grey, Black. Only the first **10** are useful seats (Grey = spectator, Black = host/GM). There is no custom hex engine color.

### 4. The playmat outline (“trim”) is baked into the table texture

Confirmed via the [mtg-edh-4player save template](https://github.com/klrmngr/mtg-edh-4player/blob/5a9e3ed7c639a4e55a1802a8656a17afc204bb64/save.template.json#L32): `"Table": "Table_Custom"` + `TableURL` — colored outlines are **part of that texture**, not a separate object.

Options considered:

1. **Swap `TableURL`** — static for everyone; skipped.
2. **Rebuild the table** as tintable objects — fork territory; skipped.
3. **Draw on top** — full wash (Technique C) rejected; **vector line-work** (Technique I) shipped, auto-aligned to deck/GY zones (Technique K).

---

## Architecture that works (current)

```
Seat Color Picker object
  ├─ 3D button "Color"     → open / right-click reset tint
  ├─ onSave / script_state → { seats = { [seat] = {r,g,b} }, swaps = { [origin] = current } }
  ├─ Global UI (picker)    → SV grid + hue + hex + Apply + engine palette
  ├─ Global UI (calibrate) → ± pads for mat overlay (optional)
  ├─ applySeatCosmetics    → whitelist scan + sticky re-apply
  ├─ rebuildSeatBorders    → vector loops (zone-aligned)
  └─ engine swap           → hand setValue + changeColor + Global aliases + widget reload
```

### Two independent color paths

| Path | What it changes | Engine chat / list? |
|------|-----------------|---------------------|
| **Apply / hex / SV grid** | Mat line-work + board widgets only | No |
| **Engine seat row** | Real seat color (stock palette) **and** paints mat/widgets with that stock RGB | Yes |
| After an engine swap, **Apply** again | Custom mat hex on top of the new engine seat | Seat stays swapped |

### Overlay alignment (Technique K)

Primary: map image **deck** box → `data[seat].libraryZone`, image **graveyard** box → `data[seat].graveyard` (same zones Global / other scripts use). Scale and rotation come from the distance/direction between those two world positions — works for every seat and for 4p/6p/8p as long as that table’s Global exposes those zones.

Fallback: Art Playmat enabler hand-math (`getHandTransform` + `matCal.centerFwd` / `worldW` / …) if zones are missing.

Fine pads (calibrate panel): `scale`, `offsetRight`, `offsetFwd`, `flipX`, `flipZ`, `borderY`, `lineThickness`.

**Whitelist kinds:** life tracker, highlight mat, commander damage, rhystic, commander zone, hand counter (+ self), timer.  
**Skip:** turn skipper, mana, hand counter screen, art playmat surface (full-mat tint removed).

---

## Techniques we tried

### A. Patch every seat widget + Global API

| | |
|--|--|
| **Tried** | Add `seatCosmeticColors` on Global; each widget calls `Global.call('getSeatCosmeticRgb', …)` |
| **Verdict** | **Do not do** under drop-in constraint |

### B. Tint-only scan from picker (early)

| | |
|--|--|
| **Tried** | `getAllObjects()` + `setColorTint` only |
| **Verdict** | Incomplete — need `editButton` + sticky re-apply |

### C. Spawn translucent “Seat Color Wash”

| | |
|--|--|
| **Tried** | Full-mat translucent Custom_Model |
| **Verdict** | **Do not re-add** — washed color over the art; user rejected |

### D. Object-attached XmlUI (`self.UI`)

| | |
|--|--|
| **Verdict** | **Do not use** — panel floats in the sky |

### E. Global screen UI (`UI.setXmlTable`) — current

| | |
|--|--|
| **Verdict** | **Keep** — rikrassen-style HUD; callbacks `guid/functionName` |

### F / G / H. Hue control

| | |
|--|--|
| **Verdict** | Native Slider can’t rainbow; **hue strip buttons** + transparent slider **Keep** |

### I. Vector line-work overlay — current

| | |
|--|--|
| **Tried** | `Global.setVectorLines` loops from a 1024×505 shape table (outer border, hand row, side column, icon boxes) |
| **Liked** | Lines only, no assets, pen drawings survive via sentinel thickness `≈0.173` |
| **Gotchas** | No `loop` flag — repeat first point to close; full-mat tint removed on purpose |
| **Verdict** | **Keep** |

### J. Hand-zone engine swap — current

| | |
|--|--|
| **Tried** | Hand `setValue` → `changeColor` → alias `data`/`deckDirs` → Description/Name rewrite + `reload()` (skip Card/Deck) |
| **Gotchas** | Stock palette only; post-load re-alias at 1/3/6s; without rebind, hand counters spam nil hand errors |
| **Verdict** | **Keep** |

### K. Deck + graveyard zone auto-align — current

| | |
|--|--|
| **Tried** | Image middle icon box ↔ `libraryZone`, bottom icon box ↔ `graveyard`; derive scale from center-to-center distance, axes from column + zone `getTransformRight()` |
| **Liked** | One code path for all seats; 4p/6p/8p sizes come from the zones, not hard-coded `worldW` |
| **Gotchas** | Needs `Global.getTable('data')[seat].libraryZone` and `.graveyard`; after engine swap, resolve via `swaps` aliases; if mirrored, toggle `flipX` / `flipZ` once |
| **Verdict** | **Keep** as primary; hand-math is fallback only |

### L. In-game calibrate panel — current

| | |
|--|--|
| **Tried** | Second Global UI panel; ±0.1 nudges; print `matCal` block to chat |
| **Gotchas** | Label `Text` must use `raycastTarget=false` or it steals clicks; Button `onClick` often passes `value=-1` — parse **element id** (`calInc_scale`); Lua patterns have **no** `|` alternation — match `calDec_` / `calInc_` separately |
| **Verdict** | **Keep** for pads / flips |

---

## TTS API lessons (QA / docs)

### Persistence

- **`onSave()` must return** the JSON string. Keep both `onSave` + `script_state`.

### `Wait`

- Infinite sticky loop: `repetitions = -1`. Stop when no cosmetics left.

### Buttons / fonts

- Use `btn.index` in `editButton`; preserve font alpha; skip near-black / near-white fonts.

### UI show/hide

- Use `UI.show` / `UI.hide` (not `active`) for FadeIn/FadeOut.

### Global UI callbacks

```text
onClick = self.getGUID() .. '/onCalNudge'
```

- TTS Button clicks often pass `value = -1`; put the real key in the **element id**.
- Lua patterns: **no** `(A|B)` alternation — write two matches.

### 3D “Color” button

- `{0, 180, 0}` upright for typical tokens; hide while HUD open.

### Events

| Event | Note |
|-------|------|
| `onPlayerTurn(player, …)` | Player instance |
| `onPlayerChangeColor(player_color)` | **string** |
| `onObjectDrop(player_color, object)` | **string** |

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

## UX decisions we liked

- Apply = mat/widgets only; engine row = optional real seat swap (+ stock mat tint).
- Live preview; Close restores baseline; one HUD owner at a time (`visibility`).
- Zone auto-align so 4/6/8 don’t need separate shape sizes.
- Calibrate panel + “Print values to chat” for locking pads into `matCal`.
- Sticky re-apply after turn / connect / color change / drop / spawn.

## UX / tech we disliked

- World-space object UI in the sky.
- White Slider as a fake hue bar.
- Full-mat wash / full-mat tint.
- Manual hand-transform calibrate for every table size (replaced by Technique K).
- Silent UI callback failures (always broadcast on parse fail).
- Lua `(Dec|Inc)` in patterns (doesn’t work).

---

## Verification checklist (manual in TTS)

1. Sit a seat → open picker → **on-screen** panel; “Color” button upright; hides while open.  
2. Hue strip rainbow; Apply custom hex → widgets + **line-work** update (not a wash over art).  
3. Opening **Calibrate mat…** broadcasts `Mat align mode: deck/GY zones` (or hand fallback).  
4. Deck / graveyard rectangles sit on the real library + GY zones for that seat.  
5. Calibrate ± updates numbers in chat and redraws live; Print dumps `matCal` to chat.  
6. Pen drawings survive Apply (sentinel thickness).  
7. Turn / sticky: highlight still correct.  
8. Save / reload: seats + swaps + loops restored.  
9. **Engine swap** to Pink → chat / list / pointer Pink; **no** hand-counter spam; draw/mulligan work.  
10. Engine swap → Apply custom hex → mat uses hex, engine seat stays Pink.  
11. Apply alone (never touch engine row) → mat/widgets only; chat color unchanged.  
12. Revert to original seat.  
13. Repeat on another seat and on 6p/8p if available.

---

## If someone asks again…

| Ask | Answer |
|-----|--------|
| “Can we change chat / player list?” | Stock palette only (Technique J). No arbitrary hex. |
| “Can we change the playmat trim?” | Vector overlay (I), auto-aligned to deck/GY zones (K). |
| “Why not align to the hand zone?” | Hand sits *below* the printed mat; overlay floated on the wood. |
| “Why deck + graveyard?” | Those zones already exist per seat in Global `data`; centers lock scale/rotation for the whole drawing. |
| “More engine colors than the 10?” | No — TTS only has 12 names; Grey/Black aren’t usable seats. |
| “Apply vs engine row?” | Apply = cosmetics only. Engine = real seat + stock mat tint; Apply can still override mat later. |
| “Cal +/− did nothing?” | Parse **id** (`calInc_scale`); don’t use Lua `\|` alternation; `raycastTarget=false` on labels. |
| “UI in the sky?” | Global `UI`, not `self.UI`. |

---

## File map

| Path | Role |
|------|------|
| `seat-color-picker.lua` | Only implementation file (`matCal`, shapes, zone align, UI, swap) |
| `README.md` | Short install / use / coverage |
| `docs/seat-color-picker.md` | This document |

Last updated: drop-in picker with Global HUD, sticky cosmetics, vector line-work overlay auto-aligned to library/graveyard zones, in-game calibrate pads, and hand-zone engine seat swap.
