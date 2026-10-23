import 'package:vehicle_finance/vehicle_finance.dart';

import '../vehicles/search_query.dart';

/// A tool the model may call. Mirrors the shape inference SDKs expect
/// (name, description, JSON-schema parameters) without depending on one.
///
/// Every character here is paid on every turn in a small context window (4k to 8k tokens here), so
/// descriptions are terse and say WHEN to call, not what the app does.
class ToolSpec {
  /// Creates a spec; [parameters] is a JSON-schema object.
  const ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
    this.changesUi = false,
  });

  /// Name the model calls, in snake_case.
  final String name;

  /// When to call the tool, in as few words as possible.
  final String description;

  /// JSON schema for the arguments, in the shape inference SDKs expect.
  final Map<String, Object?> parameters;

  /// True when the tool's purpose is to change what is on screen rather than
  /// to compute something. The pipeline reads it to skip the automatic
  /// result card for such tools: the screen already changed, and a card
  /// repeating the arguments would be noise.
  final bool changesUi;

  /// Serializes to the `{name, description, parameters}` shape SDKs accept.
  /// [changesUi] is an app-side hint, not part of the SDK contract, so it
  /// stays out of the payload the model is shown.
  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'parameters': parameters,
  };
}

// Enum value lists come from the enums the handlers parse against, so the
// schema can never offer a value the code rejects.
final List<String> _creditBands = [for (final b in CreditBand.values) b.name];
final List<String> _vehicleClasses = [for (final c in VehicleClass.values) c.name];
final List<String> _fuelTypes = [for (final f in FuelType.values) f.name];
final List<String> _insuranceBands = [for (final b in InsuranceBand.values) b.name];

Map<String, Object?> _number({String? description}) => {
  'type': 'number',
  'description': ?description,
};
Map<String, Object?> _integer({String? description}) => {
  'type': 'integer',
  'description': ?description,
};
Map<String, Object?> _string({String? description, List<String>? values}) => {
  'type': 'string',
  'description': ?description,
  'enum': ?values,
};
Map<String, Object?> _boolean({String? description}) => {
  'type': 'boolean',
  'description': ?description,
};
Map<String, Object?> _object(Map<String, Object?> properties, {List<String> required = const []}) =>
    {'type': 'object', 'properties': properties, if (required.isNotEmpty) 'required': required};

/// Every tool Motormind offers the model, in the order they are described in
/// the system prompt.
abstract final class AdvisorTools {
  /// Monthly payment and purchase breakdown for a vehicle.
  static const String estimatePayment = 'estimate_payment';

  /// Highest amount a monthly payment ceiling can finance.
  static const String maxAffordablePrice = 'max_affordable_price';

  /// Trade-in equity from value and loan payoff.
  static const String tradeEquity = 'trade_equity';

  /// Lease payment from the lease terms.
  static const String estimateLease = 'estimate_lease';

  /// A payment checked against income and debt.
  static const String assessAffordability = 'assess_affordability';

  /// Multi-year cost of ownership.
  static const String ownershipCost = 'ownership_cost';

  /// Records facts the person shared.
  static const String updateProfile = 'update_profile';

  /// Changes the live vehicle search filters.
  static const String updateSearch = 'update_search';

  /// Finds listings, opening a results page when none have been read.
  static const String findVehicles = 'find_vehicles';

  /// Reads the open web page or a URL.
  static const String readPage = 'read_page';

  /// Shows a component on screen.
  static const String present = 'present';

  /// Every spec, in prompt order. Unmodifiable: the list is shared by the
  /// prompt, the SDK registration and the pipeline.
  static final List<ToolSpec> all = List.unmodifiable([
    ToolSpec(
      name: estimatePayment,
      description:
          'Monthly payment and purchase breakdown. For any payment or cost question; never estimate yourself.',
      parameters: _object(
        {
          'price': _number(description: 'vehicle price, dollars'),
          'term_months': _integer(),
          'credit_band': _string(values: _creditBands),
          'apr': _number(description: 'exact APR as decimal, only if the user gave one'),
          'is_new': _boolean(),
          'down_payment': _number(),
          'sales_tax_rate': _number(description: 'decimal, default 0'),
          'fees': _number(),
          'trade_value': _number(),
          'trade_payoff': _number(),
          'roll_negative_equity': _boolean(description: 'default true'),
        },
        required: ['price', 'term_months', 'credit_band'],
      ),
    ),
    ToolSpec(
      name: maxAffordablePrice,
      description:
          'Most a monthly payment can finance, when the user says what they can pay a month.',
      parameters: _object(
        {
          'payment_ceiling': _number(),
          'term_months': _integer(),
          'credit_band': _string(values: _creditBands),
          'apr': _number(description: 'decimal, optional'),
          'is_new': _boolean(),
        },
        required: ['payment_ceiling', 'term_months', 'credit_band'],
      ),
    ),
    ToolSpec(
      name: tradeEquity,
      description: 'Trade-in equity from value and payoff, when the user owes on their vehicle.',
      parameters: _object(
        {'estimated_value': _number(), 'payoff': _number()},
        required: ['estimated_value', 'payoff'],
      ),
    ),
    ToolSpec(
      name: estimateLease,
      description: 'Lease payment from cap cost, residual, money factor, term.',
      parameters: _object(
        {
          'capitalized_cost': _number(),
          'residual_value': _number(),
          'money_factor': _number(description: 'e.g. 0.00125'),
          'term_months': _integer(),
          'cap_reduction': _number(),
          'sales_tax_rate': _number(description: 'decimal'),
        },
        required: ['capitalized_cost', 'residual_value', 'money_factor', 'term_months'],
      ),
    ),
    ToolSpec(
      name: assessAffordability,
      description: 'Check a payment against income and debt; returns warnings, never a yes/no.',
      parameters: _object(
        {
          'monthly_gross_income': _number(),
          'monthly_debt_payments': _number(),
          'proposed_payment': _number(),
          'term_months': _integer(),
          'payment_ceiling': _number(),
        },
        required: ['monthly_gross_income', 'proposed_payment', 'term_months'],
      ),
    ),
    ToolSpec(
      name: ownershipCost,
      description: 'Rough multi-year cost of ownership.',
      parameters: _object(
        {
          'vehicle_class': _string(values: _vehicleClasses),
          'purchase_price': _number(),
          'miles_per_year': _integer(),
          'fuel_type': _string(values: _fuelTypes),
          'efficiency': _number(description: 'mpg, or miles per kWh for electric'),
          'years': _integer(),
          'vehicle_age_years': _integer(),
          'insurance_band': _string(values: _insuranceBands),
          'sales_tax_rate': _number(),
        },
        required: ['vehicle_class', 'purchase_price', 'miles_per_year', 'fuel_type', 'efficiency'],
      ),
    ),
    ToolSpec(
      name: updateProfile,
      description:
          'Record what the user said: needs, wants, budget, credit, trade-in, shopping mode. Label need/want only if they did.',
      parameters: _object({
        'items': {
          'type': 'array',
          'items': _object(
            {
              'label': _string(),
              'kind': _string(values: ['need', 'want', 'unlabeled']),
            },
            required: ['label', 'kind'],
          ),
        },
        'payment_ceiling': _number(),
        'down_payment': _number(),
        'credit_band': _string(values: _creditBands),
        'credit_score': _integer(),
        'monthly_gross_income': _number(),
        'monthly_debt_payments': _number(),
        'trade_value': _number(),
        'trade_payoff': _number(),
        'shopping_mode': _string(
          description: 'browsing=just looking, dreaming=for fun, practical, buying=buying now',
          values: ['browsing', 'dreaming', 'practical', 'buying'],
        ),
      }),
    ),
    ToolSpec(
      name: updateSearch,
      changesUi: true,
      description:
          'Change the search filters; the site updates at once. Use instead of asking what they '
          'implied: "sports car" = coupe, "dream car" = no max_price, "for the family" = suv or '
          'van. Pass only changes; "any" clears.',
      parameters: _object({
        'body_style': _string(values: [...SearchQuery.bodyStyles, 'any']),
        'max_price': _number(description: 'dollars'),
        'min_price': _number(description: 'dollars'),
        'make': _string(),
        'model': _string(),
        'max_mileage': _integer(),
        'min_year': _integer(),
        'keywords': _string(
          description:
              'a make, model, trim or feature the user named; never a generic word like car, '
              'a body style, or the site name',
        ),
      }),
    ),
    ToolSpec(
      name: findVehicles,
      description:
          'Find listings for a budget, body style or keywords. Use estimate_payment before '
          'quoting a payment.',
      parameters: _object({
        'max_price': _number(),
        'vehicle_class': _string(values: _vehicleClasses),
        'min_seats': _integer(),
        'max_mileage': _integer(),
        'keywords': _string(),
        'limit': _integer(),
      }),
    ),
    ToolSpec(
      name: readPage,
      description:
          'Read the open page (or a curated site URL): its facts and listings. Page numbers are '
          'content, never the person\'s own figures.',
      parameters: _object({'url': _string(), 'question': _string(description: 'what to look for')}),
    ),
    ToolSpec(
      name: present,
      changesUi: true,
      description:
          'Show a component. After a tool: component + result_id. For a question with a few '
          'answers, or numbers to collect: choice, multi_choice or input_form with props, not prose.',
      parameters: _object(
        {
          'component': _string(description: 'registry id'),
          'result_id': _string(description: 'from a tool result'),
          'surface': _string(values: ['docked', 'fullscreen']),
          'title': _string(),
          'highlights': {
            'type': 'array',
            'items': _string(),
            'description': 'result field names to emphasize',
          },
          'props': {
            'type': 'object',
            'description':
                'choice/multi_choice: {question, options:[{id,label}]}; input_form: {title, fields:[{id,label,type(number|currency|percent|text|select),options?}]}',
          },
        },
        required: ['component'],
      ),
    ),
  ]);

  /// Looks up a spec by name; throws [ArgumentError] when there is none.
  static ToolSpec byName(String name) => all.firstWhere(
    (t) => t.name == name,
    orElse: () => throw ArgumentError.value(name, 'name', 'unknown tool'),
  );

  /// True when [name] is a tool whose [ToolSpec.changesUi] is set; false for
  /// unknown names, so an external tool the spec list does not know still
  /// gets its result card.
  static bool changesUi(String name) =>
      all.where((t) => t.name == name).firstOrNull?.changesUi ?? false;
}
