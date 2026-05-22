/// Prompt handlers for pubdev_context guided workflows.
///
/// Three prompts are registered:
///   - add-and-setup-package     — guided setup for a named package
///   - analyze-upgrade-impact    — breaking-change analysis across a version range
///   - evaluate-alternatives     — package discovery and comparison for a use case
///
/// Each handler returns a [GetPromptResult] with a [PromptMessage] sequence
/// that directs the LLM through a defined workflow. The LLM retains the
/// reasoning role; no server-generated recommendation is included.
/// See issue #12.
library;

import 'package:dart_mcp/server.dart';

import '../data/domain_error.dart';

// ─── Prompt definitions ───────────────────────────────────────────────────────

/// Prompt definition for [AddAndSetupPackageHandler].
final kAddAndSetupPackagePrompt = Prompt(
  name: 'add-and-setup-package',
  description:
      'Surface this when the user wants to add a new package to their project. '
      "It reads the README, explains the package's core purpose, generates boilerplate initialisation code, "
      'and lists native platform setup steps.',
  arguments: [
    PromptArgument(
      name: 'package_name',
      description:
          'The exact pub.dev package name to add. '
          'Use search_packages first if you are not certain of the name.',
      required: true,
    ),
  ],
);

/// Prompt definition for [AnalyzeUpgradeImpactHandler].
final kAnalyzeUpgradeImpactPrompt = Prompt(
  name: 'analyze-upgrade-impact',
  description:
      'Surface this when the user wants to upgrade a dependency and needs to check for breaking changes. '
      'It fetches changelog entries between from_version and to_version, identifies breaking changes, '
      'and rewrites affected source code.',
  arguments: [
    PromptArgument(
      name: 'package_name',
      description: 'The exact pub.dev package name to analyse.',
      required: true,
    ),
    PromptArgument(
      name: 'from_version',
      description:
          'The currently installed version string. Changelog entries older than this are ignored.',
      required: true,
    ),
    PromptArgument(
      name: 'to_version',
      description: 'The target upgrade version string.',
      required: true,
    ),
  ],
);

/// Prompt definition for [EvaluateAlternativesHandler].
final kEvaluateAlternativesPrompt = Prompt(
  name: 'evaluate-alternatives',
  description:
      'Surface this when the user asks which package to use for a given task. '
      'It searches for matching packages, compares the top results, and produces a recommendation '
      'with a markdown comparison matrix.',
  arguments: [
    PromptArgument(
      name: 'use_case',
      description: 'A description of the task or feature the package must support.',
      required: true,
    ),
    PromptArgument(
      name: 'sdk',
      description:
          'Restrict search to packages supporting this SDK (e.g. "flutter"). Omit for all SDKs.',
      required: false,
    ),
    PromptArgument(
      name: 'platform',
      description:
          'Restrict search to packages supporting this platform (e.g. "android", "ios", "web"). Omit for all platforms.',
      required: false,
    ),
  ],
);

// ─── Domain error constants ───────────────────────────────────────────────────

const _kMissingPackageName = DomainError(
  error: DomainErrors.invalidInput,
  message: 'The package_name argument is required.',
  suggestion: 'Supply a valid pub.dev package name as package_name.',
);

const _kMissingFromVersion = DomainError(
  error: DomainErrors.invalidInput,
  message: 'The from_version argument is required.',
  suggestion: 'Supply the currently installed version string as from_version.',
);

const _kMissingToVersion = DomainError(
  error: DomainErrors.invalidInput,
  message: 'The to_version argument is required.',
  suggestion: 'Supply the target upgrade version string as to_version.',
);

const _kMissingUseCase = DomainError(
  error: DomainErrors.invalidInput,
  message: 'The use_case argument is required.',
  suggestion: 'Supply a description of the task or feature the package must support as use_case.',
);

// ─── Handlers ─────────────────────────────────────────────────────────────────

/// Handles calls to the `add-and-setup-package` prompt.
///
/// Returns a [GetPromptResult] with four [PromptMessage] values directing
/// the LLM to read the README, explain the package's purpose, write
/// boilerplate initialisation code, and list native platform setup steps.
///
/// Throws [ArgumentError] when the required `package_name` argument is absent
/// or empty.
final class AddAndSetupPackageHandler {
  /// Creates an [AddAndSetupPackageHandler].
  const AddAndSetupPackageHandler();

  /// Handles a [GetPromptRequest] for `add-and-setup-package`.
  ///
  /// Validates that `package_name` is present before constructing any message.
  /// Throws [ArgumentError] with an `invalid_input` [DomainError] JSON payload
  /// when validation fails.
  GetPromptResult call(GetPromptRequest request) {
    final args = request.arguments ?? const {};
    final name = args['package_name'] as String?;
    if (name == null || name.isEmpty) {
      throw ArgumentError(_kMissingPackageName.toJsonString());
    }

    return GetPromptResult(
      messages: [
        PromptMessage(
          role: Role.user,
          content: TextContent(
            text: 'Read the package README at pub://package/$name/readme.',
          ),
        ),
        PromptMessage(
          role: Role.user,
          content: TextContent(text: "Explain $name's core purpose concisely."),
        ),
        PromptMessage(
          role: Role.user,
          content: TextContent(
            text: 'Write production-ready boilerplate initialisation code for $name.',
          ),
        ),
        PromptMessage(
          role: Role.user,
          content: TextContent(
            text:
                'List any native platform setup required '
                '(for example AndroidManifest.xml or Info.plist changes) '
                'exactly as described in the README.',
          ),
        ),
      ],
    );
  }
}

/// Handles calls to the `analyze-upgrade-impact` prompt.
///
/// Returns a [GetPromptResult] with three [PromptMessage] values directing
/// the LLM to retrieve changelog entries, identify breaking changes, and
/// rewrite any source code that references the upgraded package.
///
/// Throws [ArgumentError] when any required argument (`package_name`,
/// `from_version`, or `to_version`) is absent or empty.
final class AnalyzeUpgradeImpactHandler {
  /// Creates an [AnalyzeUpgradeImpactHandler].
  const AnalyzeUpgradeImpactHandler();

  /// Handles a [GetPromptRequest] for `analyze-upgrade-impact`.
  ///
  /// Validates all three required arguments before constructing any message.
  /// Throws [ArgumentError] with an `invalid_input` [DomainError] JSON payload
  /// for the first missing argument.
  GetPromptResult call(GetPromptRequest request) {
    final args = request.arguments ?? const {};
    final name = args['package_name'] as String?;
    final fromVersion = args['from_version'] as String?;
    final toVersion = args['to_version'] as String?;

    if (name == null || name.isEmpty) {
      throw ArgumentError(_kMissingPackageName.toJsonString());
    }
    if (fromVersion == null || fromVersion.isEmpty) {
      throw ArgumentError(_kMissingFromVersion.toJsonString());
    }
    if (toVersion == null || toVersion.isEmpty) {
      throw ArgumentError(_kMissingToVersion.toJsonString());
    }

    return GetPromptResult(
      messages: [
        PromptMessage(
          role: Role.user,
          content: TextContent(
            text:
                'Call get_changelog for $name with from_version set to '
                '$fromVersion to retrieve only changelog entries newer than '
                'the current version.',
          ),
        ),
        PromptMessage(
          role: Role.user,
          content: TextContent(
            text:
                'Identify and list all breaking changes between '
                'version $fromVersion and $toVersion.',
          ),
        ),
        PromptMessage(
          role: Role.user,
          content: TextContent(
            text:
                'If source code is available in context, scan it for '
                'references to $name and rewrite it to comply with the '
                '$toVersion API.',
          ),
        ),
      ],
    );
  }
}

/// Handles calls to the `evaluate-alternatives` prompt.
///
/// Returns a [GetPromptResult] with three [PromptMessage] values directing
/// the LLM to search for packages matching the use case, compare the top
/// results, and produce a recommendation with a markdown comparison matrix.
///
/// The optional `sdk` and `platform` arguments are appended to the
/// `search_packages` instruction when present.
///
/// Throws [ArgumentError] when the required `use_case` argument is absent or
/// empty.
final class EvaluateAlternativesHandler {
  /// Creates an [EvaluateAlternativesHandler].
  const EvaluateAlternativesHandler();

  /// Handles a [GetPromptRequest] for `evaluate-alternatives`.
  ///
  /// Validates that `use_case` is present before constructing any message.
  /// Throws [ArgumentError] with an `invalid_input` [DomainError] JSON payload
  /// when validation fails.
  GetPromptResult call(GetPromptRequest request) {
    final args = request.arguments ?? const {};
    final useCase = args['use_case'] as String?;
    if (useCase == null || useCase.isEmpty) {
      throw ArgumentError(_kMissingUseCase.toJsonString());
    }

    final sdk = args['sdk'] as String?;
    final platform = args['platform'] as String?;

    final searchDesc = StringBuffer("'$useCase'");
    if (sdk != null && sdk.isNotEmpty) searchDesc.write(', sdk $sdk');
    if (platform != null && platform.isNotEmpty) searchDesc.write(', platform $platform');

    return GetPromptResult(
      messages: [
        PromptMessage(
          role: Role.user,
          content: TextContent(
            text: 'Call search_packages with query $searchDesc.',
          ),
        ),
        PromptMessage(
          role: Role.user,
          content: TextContent(text: 'Call compare_packages on the top 3 to 5 results.'),
        ),
        PromptMessage(
          role: Role.user,
          content: TextContent(
            text:
                'Produce a reasoned recommendation with a markdown comparison '
                'matrix showing package name, pub points, popularity, and '
                'platform support.',
          ),
        ),
      ],
    );
  }
}
