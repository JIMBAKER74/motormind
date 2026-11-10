# Motormind AI — Dynamic design requirements

The `DD-R` list, moved into the repo on 2026-11-10 so a change and the requirement it
serves can be reviewed together. The narrative behind it (the idea, the principles, the
model's contracts, worked examples and the experiment log) stays in the design notes
outside the repo; the backlog's stories (`VA-…`) point here by `DD-R` number.

**M** must, **S** should, **C** could. **Status:** built, partial (what is missing is
said), not built. **Device:** the date the behavior was last seen working on a device or
emulator with the real model; blank means unit tests only. **Done when** is the
observable check: on screen, in the developer log, or in a named test.

Precedence when sources disagree: this file, then the design notes, then the backlog.

## Vocabulary and composition

| ID | Pri | Requirement | Status | Device | Done when |
|---|---|---|---|---|---|
| DD-R1 | M | A component registry: id, data rendered, a one-line description for the model, default placement, props validation | built | 2026-11-02 | Every component the model may name is in `ComponentRegistry.forModel`; a `present` with an unknown id or bad props returns the registry's error (`present_request_test`) |
| DD-R2 | M | Interaction components (choice, multiple choice, short form); the conversation input is the escape, signalled by its hint | built | 2026-11-10 | A live choice shows chips and the input hint changes (`chat_panel_test`: a choice prompt renders options) |
| DD-R2b | M | App-owned components (the live filters card): rendered and validated through the registry, outside the model's vocabulary; the model is told their state | built | 2026-11-10 | The filters card is in the conversation after a mode is chosen; the model's prompt carries its state, never asks what it already answers |
| DD-R3 | M | `present` names a component, data by reference, placement, emphasis, props; invalid calls return a correctable error | built | 2026-11-02 | The compare is presented by the model on a device; a refused call logs `present rejected` with the reason |
| DD-R4 | S | A composition grammar (stack, row, compare, minimize) over registry leaves | not built | | The model can return a row of two cards and the stage lays it out |
| DD-R5 | C | A free-canvas experiment with the same leaf rule | not built | | An experiment log entry with where a 2B model's layout breaks |

## Allocation and constraints

| ID | Pri | Requirement | Status | Device | Done when |
|---|---|---|---|---|---|
| DD-R6 | M | An app-owned layout allocator from content, prompt, keyboard, viewport and the person's setting | partial: surface states and the stage split by rules; no allocator over regions | | Each input changes the split in a widget test, and none of them is the model's |
| DD-R7 | M | While typing, the thing being answered stays visible | partial: the split follows the keyboard; not checked per component | | With the keyboard up, the live question and the card it is about are both on screen (widget test) |
| DD-R8 | M | A prompt about on-screen content never covers it; it collapses or relocates | partial: the filters card collapses when docked | | A choice about a listing leaves the listing visible (widget test) |
| DD-R9 | S | The same composition becomes side by side on wide or unfolded screens | not built | | On a 600 dp+ window the stage and the conversation sit side by side |
| DD-R10 | M | The model knows the canvas: size class and posture, keyboard, density | partial: size and posture in the opening context; keyboard per turn (`kb=`); a posture change mid-conversation is not sent | | Unfolding the Fold mid-conversation puts `posture` in the next `[Screen …]` |

## Control and override

| ID | Pri | Requirement | Status | Device | Done when |
|---|---|---|---|---|---|
| DD-R11 | M | A persistent reorganize control ("</>") and a pin that stops the model moving the surface | partial: "</>" cycles the surface; no pin | | With the pin on, a `present` that would change the surface leaves it as it was |
| DD-R12 | M | Every structured prompt can be minimized or dismissed | built (dismiss); minimize is not built | 2026-11-10 | "Not now" collapses a question to "(set aside)" and the next record says `new=set aside c7` |
| DD-R13 | S | The model's placement is a request; the person's last manual action wins until the context changes | built | | A manual Web/Cards flip holds until the next presented card (`display_agent_test`) |

## Situation awareness

| ID | Pri | Requirement | Status | Device | Done when |
|---|---|---|---|---|---|
| DD-R14 | S | Return cues: after background or inactivity, one line of orientation | built: `new=returned 40m` after 1 min away; a quiet turn after 10 min; no "continue here" control | 2026-11-10 (the note) | After 10 min away the model may say one line, or nothing (`chat_panel_test`: a long absence) |
| DD-R15 | S | Staleness: sourced content shows its age; the model is told and offers a refresh | partial: tiles show their age; remembered cards drop after 7 days; the model is not told ages | | The record or the listings line carries the read age of the cards on screen |
| DD-R16 | S | The empty state is chosen by the model from a small set the app offers | not built | | |
| DD-R17 | C | Content may change while the person types, if what they look at stays put | not built | | |
| DD-R17b | M | The standard questions are a live card in the conversation: applied at once, inferred from free text, one note per applied search | built | 2026-11-10 | Typing "a Honda sports car under 40k" sets the chips before the model replies |

## The Cards stage, reading recipes and learning

| ID | Pri | Requirement | Status | Device | Done when |
|---|---|---|---|---|---|
| DD-R24 | M | Cards are the primary stage; the web pane is the source, brought forward when needed | built | 2026-11-02 | A search brings Cards forward with attributed tiles |
| DD-R25 | S | Cards from several sites share one stage, each with its source and read time | partial: one site per search | | Two sites' tiles on one stage, each labeled |
| DD-R26 | M | Reading is a versioned recipe with a self-check; a broken recipe is marked and the model told | built | 2026-10-22 | `reading_recipe_test`; a failed self-check shows "needs repair" |
| DD-R27 | C | A hosted help service repairs broken recipes | not built (process designed) | | |
| DD-R28 | S | Cards have an image and are tappable; viewed and dismissed are visible states | built | 2026-11-02 | |
| DD-R29 | S | Learning from selections, proposed with a chip, never too early | partial: signals recorded and told to the model; no proposals | | After three shared properties, one chip proposal the person can undo |
| DD-R30 | S | Emergent filters from what the person mentions | not built | | "heated seats" becomes a chip marked "filtered here" |
| DD-R31 | S | Derived content appears with its input and is replaced by the fuller component when the person asks | not built (`replaces` now makes it possible) | | A price ceiling shows a payment range; asking about credit replaces it in place |
| DD-R32 | M | Filter visibility is a display decision; collapse to a funnel line | built | 2026-11-10 | |
| DD-R33 | S | A display agent (rules first, a model session switchable) with a small indicator | built | 2026-11-10 | The indicator reads "arranged by rules" or "by model in N ms" |
| DD-R34 | M | Informational language: no "advice", "advisor", "recommend" or "should" | built | | `policy_check_test` |

## The model's contracts

| ID | Pri | Requirement | Status | Device | Done when |
|---|---|---|---|---|---|
| DD-R35 | M | The opening context holds only what is true for the whole conversation: persona, rules, fixed contract, the app's goal, the vocabulary with regions, mode guidance, the profile at open, the viewport | partial: all but regions per component | 2026-11-10 | `system_prompt_test`; the log's `system instruction: N chars` |
| DD-R36 | M | A per-turn record with a budget and a changes-only rule; names, states, counts, ids, never a figure | built: compact keys, a legend in the opening context, 80-token budget | 2026-11-10 | `context_record_test`; the log's `context ~Ntok (record Mtok: keys)` |
| DD-R37 | M | An active-component list with the app's ids, region and state, for both agents and the log | partial: the interaction agent has it; the display agent still gets its one-line state | 2026-11-10 | `conv=` and `stage=` in the record; the display agent's prompt carries the same list |
| DD-R38 | M | Change operations over ids, validated against the active list; a bad reference returns the list (interaction agent) or is dropped (display agent) | partial: present, `replaces`, focus, close for the interaction agent; the display agent still returns slots | | `turn_pipeline_test`; `chat_panel_test` (focus, close, replaces) |
| DD-R39 | S | Goal lines: the app's (fixed), the person's (the model's words), the screen's (derived) | partial: no person's goal | 2026-11-10 | `goal=` in the record; the app's goal in the opening context |
| DD-R40 | S | A precedence rule between the agents and the person | built: the person's manual action wins; a display decision about a screen that has since changed is dropped | | The log's `display stale` line when the conversation moved a card during a decision |
| DD-R41 | S | The per-turn log records the context sent and its token count beside the decision | built | 2026-11-10 | `turn stats: … context ~Ntok` |
| DD-R42 | M | Dead taps are signals: answered at once, recorded in `new`, nothing disabled while the model loads | built | 2026-11-02 | Three taps on one spot ask "What are you looking for?" |
| DD-R43 | M | Images come from the person's browsing; the app never scrolls a page | built | 2026-10-22 | |

## Safety and trust

| ID | Pri | Requirement | Status | Device | Done when |
|---|---|---|---|---|---|
| DD-R18 | M | Numeric fields bind only to computed results; the guard applies to all model text | built | 2026-11-02 | `narration_guard_test` |
| DD-R18b | M | Calculation inputs trace to the person, the profile or an earlier result | built | 2026-11-02 | `input_guard_test`; Monthly cost? carries the price in the person's words |
| DD-R18c | S | A computed result the model does not present is presented by the app | built | | `turn_pipeline_test` |
| DD-R19 | M | Disclosures and policy banners have reserved places neither agent can cover | built | | |
| DD-R20 | M | Advertising, if any, has a fixed slot outside the vocabulary | not built (the demo has no ads) | | |

## Evaluation

| ID | Pri | Requirement | Status | Device | Done when |
|---|---|---|---|---|---|
| DD-R21 | M | A log per turn: component, placement, props shape, viewport, whether the person overrode, time to render | partial: no override flag | 2026-11-10 | |
| DD-R22 | S | Scripted scenarios through a fake model that assert compositions | partial: `ScriptedDriver` widget tests | | |
| DD-R23 | S | A per-model scorecard of valid components, placements and structured prompts | not built | | A table per model with a threshold, from N device runs |
