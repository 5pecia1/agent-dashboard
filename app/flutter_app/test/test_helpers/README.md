# test/test_helpers/

Shared fixtures and harnesses for multiple test files belong here, such as recurring `ProviderScope` overrides, fixed viewports for golden tests, and deterministic fake FRB response builders.

These files are helpers, not tests. Do not use the `*_test.dart` suffix, which would include them in Flutter's filename-based test discovery.

Extract shared setup here when the same override group or helper appears in two or more files under `state_tests/` or `widget_tests/`.
