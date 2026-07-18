# Apotris iOS + visionOS — Control Spec

The controls are the product. This doc is the contract; constants are starting values, tuned in play, changes recorded in DECISIONS.md.

## Principles

1. **Direct manipulation.** The piece follows the finger. Movement is finger-absolute (net drag ⇒ net cells), not velocity-nudged.
2. **One vocabulary, context-aware.** The same physical gestures work everywhere; semantics flip between *gameplay* and *menu* automatically from `scene->name()`. The player never mode-switches by hand.
3. **The engine never knows.** Gestures compile down to the same `pressKey`/`unpressKey` calls a keyboard makes, through the game's own live bindings (`KEY_*` globals / savefile action binds). Remapping, replays, DAS/ARR settings all keep working.
4. **Never gesture-gate a function.** Everything reachable by gesture is also reachable by pad, keyboard, buttons scheme, or a visible chip/ornament.
5. **Latency budget: gesture recognition → key state in ≤1 frame (16.7 ms).** Use predicted touches for drags. No recognizer may wait on another's failure where it adds perceptible delay (the tap recognizers must not wait for double-tap timeouts, etc.).

## Game actions (upstream's own action set)

Gameplay: Move L / Move R / Rotate CW / Rotate CCW / Rotate 180 / Soft Drop / Hard Drop / Hold / Zone.
Menu: Up / Down / Left / Right / Confirm / Cancel / Pause / Restart.

## iOS — Gesture scheme (default)

The whole screen is the surface (gestures work over the board too). Raw `UITouch` state machine, not stock recognizers, so thresholds and timing are ours.

### Gameplay semantics

| Gesture | Action | Notes |
|---|---|---|
| Horizontal drag | Move piece | Quantized: 1 step per `CELL_PT` of net horizontal travel from gesture anchor; anchor re-bases on direction reversal so wiggle feels immediate. Steps emitted as press/release pairs of the *bound* move key; ≥2 queued steps collapse into held-key bursts (engine DAS untouched). |
| Downward drag (slow) | Soft drop | When cumulative dy > `SOFT_ENGAGE_PT` and gesture classified vertical: hold Soft Drop key; release on lift or when dy direction leaves downward band. |
| Downward flick (fast) | Hard drop | Classifier below. Single press. |
| Upward swipe | Hold piece | dy < −`SWIPE_UP_PT` with velocity < flick ceiling…any speed. Single press. |
| Tap, right half | Rotate CW | Touch < `TAP_MAX_MS`, moved < `SLOP_PT`. |
| Tap, left half | Rotate CCW | Same. |
| Two-finger tap | Rotate 180 | Two touches down within `CHORD_MS`, both lift as taps. |
| Long-press (stationary) | Zone | ≥ `LONGPRESS_MS`, moved < `SLOP_PT`. Rare action; deliberate. |
| ⏸ chip (top corner) | Pause (Start) | Persistent, small, translucent. |
| ⚙ chip (top corner) | Port settings sheet | Native SwiftUI. |

### Axis lock & classification

A touch starts **unclassified**. It becomes a *drag* when net movement ≥ `SLOP_PT` (8 pt); the dominant axis at that moment locks the drag as horizontal or vertical. Horizontal drags never soft-drop; vertical drags never move — prevents diagonal chaos. A vertical-locked drag may still re-lock horizontal if |dx| exceeds |dy| by `RELOCK_RATIO` before soft-drop engages (early wobble forgiveness). Once soft drop is held, the lock is final for that touch.

### The flick classifier (hard vs soft drop)

The one place where two intents share a gesture axis. Rules:

- Evaluate continuously during a vertical-locked drag, deciding within `FLICK_WINDOW_MS` (120 ms) of vertical lock.
- **Hard drop** fires immediately when: instantaneous downward velocity ≥ `FLICK_VY` (900 pt/s) **and** net dy ≥ `FLICK_MIN_PT` (36 pt) within the window. Consume the touch (no further actions from it).
- Otherwise the drag is a **soft drop** once dy ≥ `SOFT_ENGAGE_PT` (20 pt): hold key until lift. A soft drop never upgrades to hard drop mid-gesture (post-window velocity spikes are ignored — prevents catastrophic misdrops).
- A hard drop is *never* produced after the window. Misclassification cost is asymmetric (accidental hard drop ruins a game; a sluggish soft drop is a shrug) — thresholds bias toward soft.
- **Test rig:** classifier is a pure function of (t, x, y) samples; unit-tested against recorded traces: slow drag, fast drag, flick, flick-with-hook, drag-then-pause, jittery slow drag. Rig lives with the shell tests and runs in CI-of-one (`scripts/sim-verify.sh`).

### Menu semantics (scene-name driven)

| Gesture | Action |
|---|---|
| Tap (anywhere) | Confirm (A) |
| Two-finger tap | Cancel (B) |
| Swipe / drag | Discrete d-pad steps: 1 per `MENU_STEP_PT` (40 pt) of travel on the dominant axis; continuous slide walks lists |
| Long-press | Cancel (B) alternative — also mapped, aids discoverability |
| ⏸ chip | Start |

Scene classification: gameplay set = {Game-family scenes}; everything else = menu. Table maintained in one shell-side function against `scene->name()` strings; unknown names default to **menu** semantics (safe: no hard drops in menus).

### Constants (iOS)

| const | value | meaning |
|---|---|---|
| CELL_PT | clamp(boardCellPt × 1.25, 14…22) | pt of drag per cell step |
| SLOP_PT | 8 | movement before drag classification |
| TAP_MAX_MS | 180 | max touch duration for tap |
| CHORD_MS | 80 | window for two-finger chord |
| LONGPRESS_MS | 350 | zone trigger |
| SOFT_ENGAGE_PT | 20 | dy before soft drop holds |
| FLICK_WINDOW_MS | 120 | decision window after vertical lock |
| FLICK_VY | 900 pt/s | flick velocity floor |
| FLICK_MIN_PT | 36 | flick distance floor |
| SWIPE_UP_PT | 30 | hold-piece trigger |
| MENU_STEP_PT | 40 | pt per menu d-pad step |
| RELOCK_RATIO | 1.5 | |dx|/|dy| to re-lock axis |

Sensitivity setting scales CELL_PT (0.7×–1.6×).

## iOS — GB buttons scheme (optional)

AGB-flavored overlay, enabled in port settings (Gestures / Buttons / Both).

- **Layout:** d-pad lower-left; A (CW) and B (CCW) diagonal pair lower-right; L/R shoulder pills at the top corners of the control zone (Hold on both by default, matching upstream's GBA defaults); Start/Select small pills bottom-center. Portrait: control zone below the letterboxed game. Landscape: flanking the game, GBA-style.
- **D-pad:** one control, 8-way hit-testing with diagonal deadzones tuned for Tetris (pure L/R/D dominate); slide between directions without lifting; direction changes fire `UISelectionFeedbackGenerator`.
- **Buttons:** `UIImpactFeedbackGenerator` light on press-in, micro on release; buttons track multi-touch independently; slide-off cancels with release event.
- **Style:** dark translucent (55% opacity setting), GBA-purple accents, SF-symbol-free hand-drawn glyphs (A/B letters, chevron d-pad). Size + opacity sliders.
- Buttons map to the packed key codes the game already binds (A/B/L/R/Start/Select/d-pad), so in-game remapping applies.

## visionOS — Pinch scheme

Windowed 2D app; primary input is indirect gaze+pinch via `SpatialEventGesture` (chirality-aware). Direct touch (poking the panel) feeds the same state machine with iOS thresholds.

| Gesture | Action |
|---|---|
| Right-hand pinch-tap | Rotate CW |
| Left-hand pinch-tap | Rotate CCW |
| Pinch-drag horizontal | Move (CELL_PT_VISION = 28 pt; indirect gain differs) |
| Pinch-drag down | Soft drop (hold) |
| Pinch-flick down | Hard drop (same classifier, FLICK_VY_VISION = 600 pt/s) |
| Pinch-flick up | Hold piece |
| Both hands pinched < CHORD_MS apart | Rotate 180 |
| Long pinch, stationary | Zone |

- Chirality unavailable (some pointers) ⇒ treat as right hand.
- Menu semantics identical to iOS (right-tap confirm; left-tap cancel — chirality replaces the two-finger chord).
- **Bottom ornament** (native SwiftUI): ⏸ Pause · ⇄ Hold · ⟲ · ⟳ · ⚙ — gaze-friendly fallback covering every gesture-mapped action per Principle 4.
- **Trap (inherited):** claim gamepad events with `GCEventInteraction` or gaze-pinch eats controller presses.
- No touch haptics on visionOS; audio + visual feedback carry the weight; controller rumble unaffected.

## Gamepad + keyboard (both platforms)

- `GCExtendedGamepad`: d-pad→d-pad; left stick→d-pad with hysteresis (engage 0.5, release 0.3); A/B/X/Y→A/B/X? — mapped to upstream's SDL_GameController button numbering inside the packed key codes, so the game's own controls screen rebinds them natively. Shoulders→L/R, Menu→Start, Options→Select.
- Defaults self-healing: applied only where the savefile leaves an action unbound; user rebinds never clobbered.
- Rumble: `rumbleOutput(strength)` → CHHapticEngine on the controller (falls back to device haptics on iPhone in buttons mode... no — device rumble only when controller absent and setting enabled).
- `GCKeyboard`: scancodes → packed SDLK codes matching `liba_window` desktop defaults (WASD + Return/Backspace/1/2/3/Esc), so the sim and iPad keyboards behave exactly like the desktop build.

## Haptics vocabulary (iOS, every call site behind the toggle)

| event | pattern |
|---|---|
| cell step (gesture move) | selection tick |
| rotate | light impact |
| hard drop | rigid impact |
| hold | light impact |
| GB button press / release | light / micro impact |
| d-pad direction change | selection tick |

Line-clear / game-event haptics: stretch — requires a clean engine signal; do not patch the engine for it (rule 9); acceptable source is the existing `rumbleOutput` path which the game already drives on clears when rumble is enabled. Route rumble→Core Haptics on iPhone when no controller is connected: free, faithful, zero new engine knowledge.

## Verification hooks

- **Debug HUD** (DEBUG builds): scene name, last synthetic key, key-state bitfield, frame counter, gesture classifier state. Screenshot of HUD + board = the artifact proving touch→engine.
- **Synthetic touch driver** (DEBUG): shell accepts scripted touch traces (JSON: t,x,y,phase) via launch argument; replays them through the real classifier into the real engine — powers `sim-verify.sh` end-to-end runs (boot → menu-nav by swipes → start marathon → move/rotate/hard-drop → screenshot).
- Flick classifier unit rig as above.
