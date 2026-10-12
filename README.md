# Motormind AI

> **This is an exploratory prototype, built for demonstration. It is not a product and it
> is not release-ready.** Please read it that way: the point is to try an idea (an
> on-device model composing the screen from a conversation) on a real phone, find out
> what breaks, and write down what was learned. Things that are expected of a product,
> such as a finished interface, stable behavior across sites, release signing, privacy
> and policy documents, accessibility and localization, are either partial or not
> started; the [Experimental status](#experimental-status) section says which. The
> numbers in [docs/MEASUREMENTS.md](docs/MEASUREMENTS.md) come from unscripted sessions
> on one phone, not from a benchmark. Nothing here is advice about buying a vehicle, and
> the finance figures are illustrative.
>
> **Status, October 2026.** The finance engine, its guards and the disclosures are tested
> and stable. The dynamic-design parts are at a prototype stage and their contracts are
> still changing. Gemma 4 E2B holds a conversation, calls the finance tools, reads
> listing pages through the in-app browser, and the app composes the screen from cards, a
> live filters card and a display decision table. Work happens on `develop`.
> Backlog: [BACKLOG.md](BACKLOG.md). Docs: [docs/](docs/README.md).

An on-device AI companion for finding and financing a personal vehicle, built in Flutter.
The language model runs **on the phone**. The financial math runs in **deterministic,
unit-tested Dart**. The app is **a tool, not a salesperson**: it does not sell, lease,
finance or refer, and it is paid by no one for any transaction.

The use case comes from Deloitte's *The AI Dossier* (2026), which describes an "AI assistant
for vehicle buying and leasing": agents that match a buyer to vehicles, analyze total cost
of ownership and lease terms with full transparency, and guide the buyer through a decision
most people find intimidating. [docs/DELOITTE_MAPPING.md](docs/DELOITTE_MAPPING.md) maps
this design to that use case's pillars and trust principles. Motormind AI is not affiliated
with or endorsed by Deloitte. The broader idea the project explores is **UI composed
at runtime from the conversation** rather than pre-designed screens
([ADR 0006](docs/adr/0006-generative-ui.md)).

## Experimental status

The vehicle use case is the carrier; the thesis is dynamic design, and it is a prototype.
A reviewer should expect rough edges in every session: a model that goes quiet, a page a
site serves differently than yesterday, a layout decision that lands a second late. Those
are the material of the project, and the experiment log in the design notes records them
rather than hiding them. What the pieces are, honestly:

- **Stable and tested:** the finance math (`vehicle_finance`), the narration and input
  guards, the closed tool switch, the disclosures, the reading recipes with their
  self-check, the captures workflow.
- **Prototype, working:** the component registry and the `present` protocol (the model
  can show a card; it cannot yet replace, collapse or bring forward one already on
  screen); the display decision table; the Cards stage with attributed, tappable tiles.
- **Prototype, built but unproven:** the display agent as a second session of the same
  model. It is off by default, and its cost was first measured on real hardware in
  [docs/MEASUREMENTS.md](docs/MEASUREMENTS.md); emulator timings are not representative.
- **Designed, not built:** the model's context contracts (a per-turn context record, an
  active-component list, change operations instead of rebuilds, named regions, goal
  lines). Today the model is told a once-built system instruction plus one hidden line
  per turn about the filters and the listings. Expect these contracts, and the tool and
  component shapes that go with them, to change.
- **Not started:** a composition grammar, viewport and posture awareness, proposals
  learned from what the person taps, the hosted recipe-repair service.

The decisions taken so far are in [ADR 0006](docs/adr/0006-generative-ui.md) and
[ADR 0008](docs/adr/0008-display-agent-and-cards-stage.md). The design notes and the
experiment log live outside the repository until they stabilize.

## What it does

- **Converses** about what the buyer needs, wants and can afford, in a tone the buyer
  picks (practical, stretch, just for fun, detailed budgeting). Income, credit band,
  trade payoff and payment ceiling never leave the device.
- **Computes, never guesses.** Payment, amortization, lease versus buy, trade equity
  including negative equity, affordability warnings and rough cost of ownership come from
  pure Dart functions. The model extracts inputs and explains outputs. Two guards enforce
  it: a narration guard rejects any number the model wrote that no tool returned, and an
  input guard refuses a calculation whose inputs the person never gave, so the model asks
  instead of inventing an income ([ADR 0002](docs/adr/0002-model-never-does-arithmetic.md)).
- **Composes the screen (prototype).** The model asks for a component from a registry
  (payment card, fullscreen breakdown, compare, question chips) and a surface (docked or
  fullscreen); the person can override; a pin is planned.
- **Browses with the buyer.** The top of the screen is a web pane showing a curated listing
  site (EchoPark by default). It is the person's browser: they scroll, tap, and answer any
  verification a site shows. The assistant reads only the page they have open, pulls
  listings and figures out of it, and can open a site's filtered results page for a stated
  budget and body style. Figures found on a page become labeled inputs. Reading is a
  per-site JSON recipe with a self-check; a captured page is how a broken recipe gets fixed
  ([ADR 0007](docs/adr/0007-reading-recipes-as-data.md)).
- **Decides the layout at runtime (prototype).** Which card is on the stage, whether the
  filters card is open, how much of the screen the page gets: a rules table decides from
  screen state, and a second session of the same model can take the rows over; that
  session is off by default
  ([ADR 0008](docs/adr/0008-display-agent-and-cards-stage.md)).
- **Lets the user pick the model.** A short catalog of on-device models (Gemma 4 E2B
  default), downloaded from the public litert-community catalog, switchable at runtime.
  See [docs/MODELS.md](docs/MODELS.md).
- **Discloses before and during use.** A short disclaimer gate, long-form disclosures one
  tap away, and assumptions beside every number.

Planned, not built: form filling on approved sites with a preview and a confirm every
time; the disclosures on the web; a light model for older phones.

## What it does not do

- Sell, lease, finance, or pass information to any lender or dealer.
- Pull credit or enter Social Security, account or payment details anywhere.
- Quote a rate as fact. Rates are illustrative, dated, labeled and editable.
- Promise anything. Sales language in a reply raises a visible flag.

Advertising, if any, is a build-time flavor with a fixed, labeled slot that never touches
results or ranking. The demo build has none.

## Repository layout

| Path | What it is |
|---|---|
| `apps/motormind/packages/vehicle_finance/` | Pure Dart finance engine with tests |
| `apps/motormind/packages/advisor_core/` | Pure Dart tool specs, finance tool handlers, narration guard, policy check, disclosures, buyer profile, component registry; with tests |
| `apps/motormind/` | The Flutter app: conversation, stage and cards, live search and filters, web pane with reading recipes and captures, model catalog (Riverpod 3, go_router) |
| `packages/` | Upstream `flutter_edge_ai` packages: inference engines, agent loop, speech, RAG, diagnostics |
| `docs/` | Architecture, setup, models, decisions ([index](docs/README.md)) |
| `BACKLOG.md` | Epics, features and user stories |

This repository is a trimmed fork of [DenisovAV/flutter_edge_ai](https://github.com/DenisovAV/flutter_edge_ai)
(formerly `flutter_gemma`), the on-device LLM toolkit for Flutter.
[docs/UPSTREAM.md](docs/UPSTREAM.md) explains the relationship.

## Building and running

Toolchain install is in [docs/SETUP.md](docs/SETUP.md). The two Dart packages run on the
Dart VM alone; the app's widget tests need Flutter.

```bash
cd apps/motormind/packages/vehicle_finance && dart pub get && dart test
```

```bash
cd apps/motormind/packages/advisor_core && dart pub get && dart test
```

```bash
cd apps/motormind && flutter pub get && flutter analyze && flutter test
```

Running on a device or emulator, including the emulator GPU modes the web pane needs, is
in [docs/SETUP.md](docs/SETUP.md).

## Attribution and license

Upstream `flutter_edge_ai` is MIT licensed, copyright Sasha Denisov. See [LICENSE](LICENSE).
Project-specific code and documentation are by James Baker, built with AI coding
assistance; the architecture, product decisions and review are his.
