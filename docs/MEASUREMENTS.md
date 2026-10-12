# Measurements

Numbers from real hardware. Emulator timings are not representative (software GL and CPU
inference share the cores; see `docs/SETUP.md`), so nothing from the emulator is recorded
here. Each run names the device, the build, the model and the exact script, so a later run
on another phone is comparable. The experiment log in the design notes records what each
number changed.

## Device: Samsung Galaxy Z Fold 4 (SM-F936U)

| Item | Value |
|---|---|
| OS | Android 16 (API 36), build BP2A.250605.031 |
| Chipset | Qualcomm Snapdragon 8+ Gen 1 (SM8475) |
| Memory | 11.5 GB total; 4.5 GB available before the app started |
| Screen used | cover screen, 904 × 2316 px at 420 dpi (folded) |
| Build | `develop` at 54398e65 plus the README disclosure, debug APK (`flutter build apk --debug`) |
| Model | Gemma 4 E2B (`gemma-4-E2B-it.litertlm`, 2.6 GB, GPU backend) |
| Baseline memory | app open, no model loaded: 630 MB PSS (175 MB of it graphics, the web pane) |

How the numbers were taken: `adb logcat` captured for the whole session; the app's
`logDev` lines give turn start, each tool call, turn done and every display decision with
who decided and how long; the engine's own log lines give prefill and decode; memory from
`dumpsys meminfo` at rest, after the model loaded and after the turns. Wall-clock from the
log timestamps.

## Run 1 — 2026-10-12, Galaxy Z Fold 4, Gemma 4 E2B on the GPU

Three app sessions in one evening, all with the display agent (second session) **on**,
because the owner had switched it on before the first run; a rules-only baseline is still
to be taken. The first session ran the October 9 build with a 4,096-token window; the
later two ran the fixed build with 8,192 (see "What the run changed" below).

### Startup

| Step | Measured |
|---|---|
| Model file download (2.6 GB, Wi-Fi) | about 3 min with one connection abort and an automatic retry |
| Engine create (model load, GPU init, cache) | 12.9 s, 7.8 s, 14.8 s, 10.0 s across four launches |
| Conversation session create | 2.1 s to 2.9 s |
| System instruction | 2,735 chars (~683 tokens) on the old build; 2,962 chars (~740 tokens) with the keyword guidance |
| Memory, model loaded, pane open | 2.9 GB PSS (1.76 GB of it graphics: the weights on the GPU) and 0.64 GB swap; the OS went from 4.5 GB available to 2.9 GB |

### Conversation turns (interaction agent)

| What | Measured |
|---|---|
| First prefill of a conversation (instruction + tools + first message) | 6.1 s, 7.9 s, 7.3 s |
| Prefill of a later user message | 3.0 s to 4.1 s |
| Prefill of a tool result | 0.3 s to 2.2 s (0.7 s for a `find_vehicles` result) |
| Decode | 9 to 15 tokens/s when the phone is fresh; 7 to 8 tokens/s after ten minutes of back-to-back generation |
| A typical two-tool turn (`update_search` → `present` → reply) | 17.5 s wall clock |
| A long reply | 230 tokens in 29 s |
| Zero-token reply after a tool call (the known Gemma silence) | 0.4 s; the app wrote the sentence |

### Display agent (second session of the same model)

| What | Measured |
|---|---|
| One decision early in a conversation | 3.4 s to 6.4 s (prefill 1.7 to 2.2 s, decode 17 to 74 tokens at 13 to 17 tokens/s) |
| One decision after a conversation turn with tool results | 6.6 s to 11.3 s |
| A run of decisions during one search (the stage and counts changing several times) | ten decisions in 90 s; their prefill climbed 4.3 → 7.5 → 9.1 → 14.3 → 11.5 → 14.9 → 18.9 → 26.2 → 30.1 s |
| First decision of a fresh launch with a 29-token conversation | 19.3 s (prefill 10.1 s, decode 46 tokens at 4.9 tokens/s); cause not established |
| Agreement with the rules table | 17 of 19 decisions identical; the two differences were `summary` instead of `expanded` for the filters card before any filter was set, and `third` instead of `typing` for the split with the keyboard up |

The climb is the engine's session model (ADR 0008): every decision opens a session, and
on this engine a session switch replays the other session's history, so each decision
costs its own prompt plus the whole conversation so far, and decisions that queue up
behind a changing screen each pay it again. Two consequences, both now in the backlog:
decisions must be coalesced (one per settled screen, never a queue), and the display
agent's prompt must not grow with the conversation. Until then the switch stays off by
default, which the measurements confirm was the right default.

### What the run found, and what it changed

Numbers were the aim; the run also found five defects, each fixed the same night:

- The APK under test dated from October 9: the Gradle signing block from the security
  commit never compiled (`java.util.Properties` inside the `android` block resolves `java`
  to the plugin extension), and the build check hid the failure behind a pipe.
- The model put the site name and then "car" in the search keywords; the local filter
  required the keyword in a listing title, so 21 read listings became "none".
- The 5.5 GB free-memory threshold put this 12 GB phone on a 4,096-token window; the
  third turn overflowed it after one page read (835 tokens of capacity left). Threshold
  4 GB now; a results page sends its listings and not its prose.
- "No model is loaded. Open Models and choose one" showed while the model was loading,
  and nothing loaded without a visit to the Models screen. The installed default now loads
  at launch, the panel shows the load, and a phone with no model is offered the one that
  fits its memory.
- Price chips were ceilings only; "an SUV over $40k" had no chip. Bands now.

Still open from the run: the EchoPark reading recipe fails its self-check on the live page
(66 cards matched, none with a title), so the text fallback reads the page and no images
show until a captured page fixes the selector; the rules-only baseline; and the display
agent's cost after the coalescing fix.
