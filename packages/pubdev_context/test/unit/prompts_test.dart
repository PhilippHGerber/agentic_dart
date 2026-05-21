/// Unit tests for the prompt handler implementations.
library;

import 'package:dart_mcp/server.dart';
import 'package:pubdev_context/src/prompts/prompts.dart';
import 'package:test/test.dart';

// ─── Helpers ─────────────────────────────────────────────────────────────────

String _text(PromptMessage message) => (message.content as TextContent).text;

GetPromptRequest _addAndSetupReq(Map<String, Object?> args) =>
    GetPromptRequest(name: 'add-and-setup-package', arguments: args);

GetPromptRequest _upgradeImpactReq(Map<String, Object?> args) =>
    GetPromptRequest(name: 'analyze-upgrade-impact', arguments: args);

GetPromptRequest _alternativesReq(Map<String, Object?> args) =>
    GetPromptRequest(name: 'evaluate-alternatives', arguments: args);

Matcher _throwsInvalidInput() => throwsA(
  isA<ArgumentError>().having(
    (e) => e.message.toString(),
    'message',
    contains('invalid_input'),
  ),
);

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  // ─── AddAndSetupPackageHandler ────────────────────────────────────────────────

  group('AddAndSetupPackageHandler', () {
    const handler = AddAndSetupPackageHandler();

    test('returns exactly 4 messages', () {
      final result = handler.call(_addAndSetupReq({'package_name': 'http'}));
      expect(result.messages, hasLength(4));
    });

    test('all messages have role user', () {
      final result = handler.call(_addAndSetupReq({'package_name': 'http'}));
      expect(result.messages.map((m) => m.role), everyElement(equals(Role.user)));
    });

    test('first message references pub:// readme URI for the package', () {
      final result = handler.call(_addAndSetupReq({'package_name': 'http'}));
      expect(_text(result.messages[0]), contains('pub://package/http/readme'));
    });

    test('second message asks to explain core purpose', () {
      final result = handler.call(_addAndSetupReq({'package_name': 'http'}));
      expect(_text(result.messages[1]), contains('core purpose'));
    });

    test('third message asks for boilerplate initialisation code', () {
      final result = handler.call(_addAndSetupReq({'package_name': 'http'}));
      expect(_text(result.messages[2]), contains('boilerplate initialisation code'));
    });

    test('fourth message asks for native platform setup steps', () {
      final result = handler.call(_addAndSetupReq({'package_name': 'http'}));
      expect(_text(result.messages[3]), contains('native platform setup'));
    });

    test('package name is interpolated into messages', () {
      final result = handler.call(_addAndSetupReq({'package_name': 'riverpod'}));
      expect(_text(result.messages[0]), contains('riverpod'));
    });

    test('throws ArgumentError with invalid_input when package_name is absent', () {
      expect(() => handler.call(_addAndSetupReq({})), _throwsInvalidInput());
    });

    test('throws ArgumentError with invalid_input when package_name is empty', () {
      expect(
        () => handler.call(_addAndSetupReq({'package_name': ''})),
        _throwsInvalidInput(),
      );
    });
  });

  // ─── AnalyzeUpgradeImpactHandler ─────────────────────────────────────────────

  group('AnalyzeUpgradeImpactHandler', () {
    const handler = AnalyzeUpgradeImpactHandler();

    const validArgs = {
      'package_name': 'dio',
      'from_version': '4.0.0',
      'to_version': '5.0.0',
    };

    test('returns exactly 3 messages', () {
      final result = handler.call(_upgradeImpactReq(validArgs));
      expect(result.messages, hasLength(3));
    });

    test('all messages have role user', () {
      final result = handler.call(_upgradeImpactReq(validArgs));
      expect(result.messages.map((m) => m.role), everyElement(equals(Role.user)));
    });

    test('first message instructs calling get_changelog with from_version', () {
      final result = handler.call(_upgradeImpactReq(validArgs));
      final text = _text(result.messages[0]);
      expect(text, contains('get_changelog'));
      expect(text, contains('4.0.0'));
    });

    test('second message asks to identify breaking changes between versions', () {
      final result = handler.call(_upgradeImpactReq(validArgs));
      final text = _text(result.messages[1]);
      expect(text, contains('breaking changes'));
      expect(text, contains('4.0.0'));
      expect(text, contains('5.0.0'));
    });

    test('third message asks to rewrite source code for new API', () {
      final result = handler.call(_upgradeImpactReq(validArgs));
      final text = _text(result.messages[2]);
      expect(text, contains('rewrite'));
      expect(text, contains('5.0.0'));
    });

    test('package name is interpolated into first message', () {
      final result = handler.call(_upgradeImpactReq(validArgs));
      expect(_text(result.messages[0]), contains('dio'));
    });

    test('throws invalid_input when package_name is absent', () {
      expect(
        () => handler.call(_upgradeImpactReq({'from_version': '1.0.0', 'to_version': '2.0.0'})),
        _throwsInvalidInput(),
      );
    });

    test('throws invalid_input when package_name is empty', () {
      expect(
        () => handler.call(
          _upgradeImpactReq({'package_name': '', 'from_version': '1.0.0', 'to_version': '2.0.0'}),
        ),
        _throwsInvalidInput(),
      );
    });

    test('throws invalid_input when from_version is absent', () {
      expect(
        () => handler.call(_upgradeImpactReq({'package_name': 'dio', 'to_version': '2.0.0'})),
        _throwsInvalidInput(),
      );
    });

    test('throws invalid_input when from_version is empty', () {
      expect(
        () => handler.call(
          _upgradeImpactReq({'package_name': 'dio', 'from_version': '', 'to_version': '2.0.0'}),
        ),
        _throwsInvalidInput(),
      );
    });

    test('throws invalid_input when to_version is absent', () {
      expect(
        () => handler.call(_upgradeImpactReq({'package_name': 'dio', 'from_version': '1.0.0'})),
        _throwsInvalidInput(),
      );
    });

    test('throws invalid_input when to_version is empty', () {
      expect(
        () => handler.call(
          _upgradeImpactReq({'package_name': 'dio', 'from_version': '1.0.0', 'to_version': ''}),
        ),
        _throwsInvalidInput(),
      );
    });
  });

  // ─── EvaluateAlternativesHandler ─────────────────────────────────────────────

  group('EvaluateAlternativesHandler', () {
    const handler = EvaluateAlternativesHandler();

    test('returns exactly 3 messages', () {
      final result = handler.call(_alternativesReq({'use_case': 'HTTP client'}));
      expect(result.messages, hasLength(3));
    });

    test('all messages have role user', () {
      final result = handler.call(_alternativesReq({'use_case': 'HTTP client'}));
      expect(result.messages.map((m) => m.role), everyElement(equals(Role.user)));
    });

    test('first message instructs calling search_packages with use_case', () {
      final result = handler.call(_alternativesReq({'use_case': 'HTTP client'}));
      final text = _text(result.messages[0]);
      expect(text, contains('search_packages'));
      expect(text, contains('HTTP client'));
    });

    test('second message instructs calling compare_packages on top results', () {
      final result = handler.call(_alternativesReq({'use_case': 'HTTP client'}));
      expect(_text(result.messages[1]), contains('compare_packages'));
    });

    test('third message asks for recommendation with comparison matrix', () {
      final result = handler.call(_alternativesReq({'use_case': 'HTTP client'}));
      final text = _text(result.messages[2]);
      expect(text, contains('recommendation'));
      expect(text, contains('matrix'));
    });

    test('sdk filter is included in first message when provided', () {
      final result = handler.call(
        _alternativesReq({'use_case': 'state management', 'sdk': 'flutter'}),
      );
      expect(_text(result.messages[0]), contains('flutter'));
    });

    test('platform filter is included in first message when provided', () {
      final result = handler.call(
        _alternativesReq({'use_case': 'state management', 'platform': 'android'}),
      );
      expect(_text(result.messages[0]), contains('android'));
    });

    test('both sdk and platform filters appear when provided', () {
      final result = handler.call(
        _alternativesReq({'use_case': 'storage', 'sdk': 'flutter', 'platform': 'ios'}),
      );
      final text = _text(result.messages[0]);
      expect(text, contains('flutter'));
      expect(text, contains('ios'));
    });

    test('sdk filter is omitted from first message when absent', () {
      final result = handler.call(_alternativesReq({'use_case': 'HTTP client'}));
      expect(_text(result.messages[0]), isNot(contains('sdk')));
    });

    test('sdk filter is omitted from first message when empty', () {
      final result = handler.call(_alternativesReq({'use_case': 'HTTP client', 'sdk': ''}));
      expect(_text(result.messages[0]), isNot(contains('sdk')));
    });

    test('throws invalid_input when use_case is absent', () {
      expect(() => handler.call(_alternativesReq({})), _throwsInvalidInput());
    });

    test('throws invalid_input when use_case is empty', () {
      expect(
        () => handler.call(_alternativesReq({'use_case': ''})),
        _throwsInvalidInput(),
      );
    });
  });
}
