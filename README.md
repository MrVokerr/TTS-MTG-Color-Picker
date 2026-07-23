# TTS-MTG Color Picker

Drop-in [Tabletop Simulator](https://www.tabletopsimulator.com/) object for Oops-style MTG tables. Paste the script onto a token, drop it on the table, and tint each seat’s board chrome and playmat line-work without editing Global.lua or any other Lua files.

**Current version:** `1.0.1` (`SCRIPT_VERSION` in the script)  
**Script:** [`seat-color-picker.lua`](seat-color-picker.lua)  
**Design notes:** [`seat-color-picker.md`](seat-color-picker.md) — read before changing the picker so we don’t re-try dead ends.

---

## Directory

```
TTS-MTG/
├── seat-color-picker.lua   # drop-in object script (paste into a TTS token)
├── seat-color-picker.md    # design notes / techniques / dead ends
└── README.md
```

---

## Prerequisites

- [Tabletop Simulator](https://www.tabletopsimulator.com/)
- An Oops-style MTG table (4p / 6p / 8p) with per-seat library + graveyard zones in Global `data`
- Internet access on first load (and whenever a newer `SCRIPT_VERSION` is published) for auto-update

---

## Install / use

1. Create any object (e.g. a Custom Token) in TTS.
2. Paste the contents of [`seat-color-picker.lua`](seat-color-picker.lua) into that object’s script.
3. Drop the object on an Oops MTG table.
4. Click **Color** → pick hue / SV / hex → **Apply** for mat line-work + board widgets.
5. Optional: use the **engine seat row** to swap to another stock TTS player color (chat / list / pointer).
6. Right-click the **Color** button to clear your seat’s custom tint.

Until **Apply** (or an engine seat pick), the object does not tint widgets or draw overlays.

### Auto-update from GitHub

On every `onLoad`, the object fetches this file from:

`https://raw.githubusercontent.com/MrVokerr/TTS-MTG-Color-Picker/master/seat-color-picker.lua`

If remote `SCRIPT_VERSION` differs from the local copy, it calls `setLuaScript` + `reload()`. Saved Objects and old table saves keep their seat tint state (`onSave` / `script_state`) but pull the published script.

| Knobs | |
|-------|--|
| `SCRIPT_VERSION` | Bump this whenever you push a release people should get |
| `AUTO_UPDATE` | Set `false` to test a local paste without GitHub overwriting it |
| Offline / GitHub down | Logs a chat message and keeps the bundled script |

**Bootstrap:** Objects that never had the auto-update block cannot self-update — paste this script once, then GitHub is the source of truth. If an object still points at the old `Seat Color Picker.lua` URL (v1.0.0), re-paste once so it uses `seat-color-picker.lua`.

---

## Features / status

| Feature | Status |
|---------|--------|
| Drop-in object; no edits to other Lua *files* | Done |
| Custom RGB tint for board chrome (life, timers, CMD, hand counts, …) | Done |
| Playmat **line-work** overlay (vector loops, not a full-mat wash) | Done — bleed-through polish still open |
| Zone auto-align (deck + GY → Technique K) | Done; scales for 4p / 6p / 8p |
| Traced mat shapes | **4p** and **6p** layouts; **8p** reuses 4p crop |
| Persist across save / load / rewind | Done (`onSave` + `script_state`) |
| On-screen HUD picker (Global `UI`) | Done |
| Stock-palette chat / list / pointer (Technique J) | Done; arbitrary hex impossible |
| GitHub auto-update on load | Done (`SCRIPT_VERSION`) |
| Event-driven chrome re-apply (turn / connect / drop / spawn) | Done — no repeating sticky interval |
| In-game mat calibrate panel | Present in code but **disabled** in the UI |

### Open polish

- Playmat line-work: reduce color showing through the mat art.
- Confirm 6p / 8p overlays and cosmetics on live Oops tables end-to-end.

---

## Hard constraints

### 1. Picker-only — do not edit other Lua *files*

Import **one object** onto a workshop table without touching other scripts.

Runtime mutation of other objects (Descriptions, `reload()`, `Global.setTable` aliases, `Global.setVectorLines`) is allowed — shipped mod scripts are never edited.

Cosmetics that widgets reset on load / turn must be **re-applied from the picker** (`scheduleReapply` after events).

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
  ├─ onLoad → GitHub auto-update (SCRIPT_VERSION)
  ├─ 3D button "Color"     → open / right-click reset tint
  ├─ onSave / script_state → { seats, swaps }
  ├─ Global UI (picker)    → SV grid + hue + hex + Apply + engine palette
  ├─ applySeatCosmetics    → whitelist scan + event re-apply
  ├─ rebuildSeatBorders    → MAT_4P / MAT_6P vector loops (zone-aligned)
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

Fine pads (in `matCal`, calibrate UI currently off): `scale`, `offsetRight`, `offsetFwd`, `flipX`, `flipZ`, `borderY`, `lineThickness`.

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
| **B** Tint-only scan | Incomplete — need event re-apply |
| **C** Full-mat translucent wash | **Don’t** — washes art |
| **D** Object-attached `self.UI` | **Don’t** — floats in the sky |
| **E** Global screen UI | **Keep** |
| **I** Vector line-work overlay | **Keep** (bleed-through polish open) |
| **J** Hand-zone engine swap | **Keep** |
| **K** Deck + GY zone auto-align | **Keep** |
| **L** In-game calibrate panel | In code; UI currently disabled |

---

## TTS API lessons

- **`onSave()` must return** the JSON string. Keep both `onSave` + `script_state`.
- After `setLuaScript`, call `reload()` (wait until `self.resting`) so the new script’s `onLoad` runs.
- Use `btn.index` in `editButton`; preserve font alpha; skip near-black / near-white fonts.
- Use `UI.show` / `UI.hide` (not `active`) for FadeIn/FadeOut.
- Global UI callbacks: `onClick = self.getGUID() .. '/onCalNudge'`.
- Button clicks often pass `value = -1` — put the real key in the **element id**.
- Lua patterns have **no** `|` alternation — match prefixes separately.
- Label `Text` needs `raycastTarget=false` or it steals clicks.
- 3D “Color” button: `{0, 180, 0}` upright; hide while HUD open.

---

## Verification checklist (manual in TTS)

1. Sit a seat → open picker → **on-screen** panel; “Color” button upright; hides while open.
2. Hue strip rainbow; Apply custom hex → widgets + **line-work** update (not a wash over art).
3. Nothing tinted/drawn until Apply or engine seat pick.
4. Deck / graveyard rectangles sit on the real library + GY zones for that seat (try 4p and 6p).
5. Pen drawings survive Apply (sentinel thickness).
6. Turn / connect / drop: highlight and chrome still correct (event re-apply).
7. Save / reload: seats + swaps + loops restored.
8. **Engine swap** → chat / list / pointer update; **no** hand-counter spam.
9. Engine swap → Apply custom hex → mat uses hex, engine seat stays swapped.
10. Apply alone → mat/widgets only; chat color unchanged.
11. Revert to original seat / clear tint (right-click Color).
12. Bump `SCRIPT_VERSION` on GitHub → reload table → chat shows update, object script matches remote.

---

## FAQ

| Ask | Answer |
|-----|--------|
| “Can we change chat / player list?” | Stock palette only (Technique J). No arbitrary hex. |
| “Can we change the playmat trim?” | Vector overlay (I), auto-aligned to deck/GY zones (K). |
| “Why not align to the hand zone?” | Hand sits *below* the printed mat; overlay floated on the wood. |
| “Why deck + graveyard?” | Those zones exist per seat in Global `data`; centers lock scale/rotation. |
| “More engine colors than the 10?” | No — TTS only has 12 names; Grey/Black aren’t usable seats. |
| “Apply vs engine row?” | Apply = cosmetics only. Engine = real seat + stock mat tint; Apply can still override mat later. |
| “Works on 6p / 8p?” | Zone align yes; 6p has its own traced shapes; 8p reuses 4p crop — verify on live tables. |
| “UI in the sky?” | Global `UI`, not `self.UI`. |
| “Saved object stays outdated?” | After one paste of the auto-update script, GitHub wins on load when `SCRIPT_VERSION` changes. |

---

## License

No license file yet — all rights reserved unless otherwise stated by the author.
