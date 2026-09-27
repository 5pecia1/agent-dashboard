# test/rust_tests/

Dart tests here verify contracts across the FRB (flutter_rust_bridge) boundary.

Rust tests in app-core (`cargo test`) cover the behavior of Rust logic, including pure functions and parsing rules. Tests here check whether DTOs are serialized and deserialized according to the contract when Dart accesses that logic through FRB. Examples include:

- Whether Dart receives the expected exception type and code when Rust rejects a payload that exceeds a size limit.
- Whether enum variant names agree between Rust `#[frb]` declarations and generated Dart enums.
- Whether Dart `switch` expressions handle every variant of a Rust enum exposed as a Freezed union, producing a compile error when a new variant is unhandled.

When adding an FRB API to app-core, add tests for its boundary contract here.
