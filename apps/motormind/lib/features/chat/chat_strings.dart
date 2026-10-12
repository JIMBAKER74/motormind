/// Every sentence the chat shows the person, in one place, so wording is a
/// reviewable diff rather than a scavenger hunt (the same rule disclosures
/// follow in `advisor_core`).
abstract final class ChatStrings {
  static const noModel = 'Motormind needs a model on this phone before it can answer.';
  static const otherModels = 'Other models';
  static const modelRetry = 'Retry';

  /// The panel's line while a model comes into memory (about fifteen
  /// seconds for Gemma 4 E2B on a 2022 flagship).
  static String loadingModel(String name) => 'Loading $name… this takes a few seconds.';

  static String downloadingModel(String name, int percent) => 'Downloading $name · $percent%';

  /// The one-tap offer when nothing is installed; [size] is the download.
  static String downloadModel(String name, String size) => 'Download $name ($size)';
  static const startFailed = 'Motormind could not start.';
  static const tooLong = 'Motormind took too long to answer.';
  static const contextFull =
      'The conversation grew past what this model can hold in memory. Start a new conversation '
      'to continue.';
  static const somethingWrong = 'Something went wrong.';
  static const numbersReplaced =
      'Motormind\'s wording was replaced because it contained numbers not from a calculation.';
  static const nothingToAdd =
      'Nothing to add yet. Pick an option above, change a filter, or tell me more.';
  static const hereIsWhatIFound = 'Here is what I found. Tell me more when you are ready.';
  static const policyBanner =
      'Motormind does not sell or promise. This reply tripped the sales-language check';
  static const pageReadFailed = 'The page could not be read. Try again or pick another site.';
  static const noListingsOnPage =
      'No listings matched on the page that is open. Change a filter, or scroll the site and '
      'ask me to read again.';
  static const humanCheck =
      'The site is asking you to confirm you are a person. Complete the check in the web pane, '
      'then ask me to read the page again.';
  static const captureFailed = 'The page could not be captured.';
  static const askMotormind = 'Ask Motormind';
  static const starting = 'Starting…';
  static const showSoFar = 'Show what you have so far';
  static const hintPending = 'Something else? Type it here…';
  static const hintFiltered = 'Tell me more: must-haves, a budget, a trade-in…';
  static const hintDefault = 'Tell me about the car you have in mind…';

  // The filters card.
  static const filtersTitle = 'What are we looking for?';
  static const anyType = 'Any type';
  static const anyPrice = 'Any price';
  static const anyMiles = 'Any miles';
  static const lookOn = 'Look on';
  static const collapse = 'Collapse';
  static const reading = 'reading…';

  /// The stage's label while the app opens and reads a site's page, so the
  /// page moving on its own is seen as the read it is, not a bug.
  static String readingSite(String site) => 'Reading $site…';

  /// A price ceiling chip, in thousands ("Under \$35k").
  static String underPrice(int dollars) => 'Under \$${dollars ~/ 1000}k';

  /// A price band chip: "Under \$25k", "\$25k–\$40k", "Over \$60k".
  static String priceBand(int? min, int? max) => switch ((min, max)) {
    (null, final int max) => underPrice(max),
    (final int min, null) => 'Over \$${min ~/ 1000}k',
    (final int min, final int max) => '\$${min ~/ 1000}k–\$${max ~/ 1000}k',
    (null, null) => anyPrice,
  };

  /// A mileage ceiling chip, in thousands ("Under 50k mi").
  static String underMiles(int miles) => 'Under ${miles ~/ 1000}k mi';

  /// The search status once a page was read.
  static String matchedCount(int n) => '$n matched';

  static String stoppedAfter(int seconds) =>
      'Stopped: Motormind went $seconds seconds without a word. Try a shorter message.';

  static String refusedInputs(Iterable<String> arguments) =>
      'Refused a calculation: ${arguments.join(', ')} was not something you told me.';

  static String checkingNumbers(Iterable<String> raw) => 'Checking numbers: ${raw.join(', ')}';

  static String noMatches(String site, String query) =>
      'Nothing on $site matched $query. Loosen a filter or try another site.';

  static String matches(int count, String site, String query) =>
      '$count ${count == 1 ? 'listing' : 'listings'} on $site match $query. '
      'Tap a type or price to narrow it, or tell me more.';

  static String searchNote(String query, String site, int matched) =>
      'Looking for $query on $site: $matched matched.';

  static String monthlyCostOf(String title) => 'What would the $title cost me a month?';
}
