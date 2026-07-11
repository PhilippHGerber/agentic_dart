/// Guards against `lib/src/version.dart` drifting from `pubspec.yaml`.
library;

import 'dart:io';

import 'package:pubdev_context/src/version.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('packageVersion matches the version in pubspec.yaml', () {
    final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync());
    final pubspecVersion = (pubspec as YamlMap)['version'] as String;

    expect(
      packageVersion,
      equals(pubspecVersion),
      reason:
          'lib/src/version.dart is generated from pubspec.yaml and is out '
          'of date — regenerate it (see the "Generated code" header in '
          'that file) after bumping the package version.',
    );
  });
}
