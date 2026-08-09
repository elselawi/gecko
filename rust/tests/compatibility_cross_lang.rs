use gecko_db_rust::compatibility::{CompatibilityHandshake, HANDSHAKE_VERSION, PACKAGE_VERSION};
use gecko_db_rust::format_header::{FORMAT_VERSION, WIRE_VERSION};

#[test]
fn handshake_contract_matches_dart_fields_and_versions() {
    let handshake = CompatibilityHandshake::current("0.0.1+rust");
    let encoded = handshake.encode().unwrap();
    let decoded: serde_json::Value = serde_json::from_str(&encoded).unwrap();

    assert_eq!(decoded["handshakeVersion"], HANDSHAKE_VERSION);
    assert_eq!(decoded["packageVersion"], PACKAGE_VERSION);
    assert_eq!(decoded["wireVersion"], WIRE_VERSION);
    assert_eq!(decoded["formatVersion"], FORMAT_VERSION);
    assert_eq!(decoded["nativeBuildId"], "0.0.1+rust");
    assert!(handshake
        .validate_compatibility(
            HANDSHAKE_VERSION,
            PACKAGE_VERSION,
            WIRE_VERSION,
            FORMAT_VERSION,
        )
        .is_ok());
}

#[test]
fn handshake_mismatch_is_rejected_before_operations() {
    let handshake = CompatibilityHandshake::current("0.0.1+rust");
    assert!(handshake
        .validate_compatibility(HANDSHAKE_VERSION, "9.9.9", WIRE_VERSION, FORMAT_VERSION)
        .is_err());
}
