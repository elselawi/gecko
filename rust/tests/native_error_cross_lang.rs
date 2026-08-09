use gecko_db_rust::error::{GeckoErrorEnvelope, GeckoErrorType};

#[test]
fn typed_native_error_envelope_is_dart_decodable() {
    let error = GeckoErrorEnvelope {
        error_type: GeckoErrorType::DatabaseLocked,
        message: "database is locked".into(),
        details: Some(serde_json::json!({"path": "db.redb"})),
    };
    let decoded: serde_json::Value = serde_json::from_str(&error.encode()).unwrap();
    assert_eq!(decoded["type"], "databaseLocked");
    assert_eq!(decoded["message"], "database is locked");
    assert_eq!(decoded["details"]["path"], "db.redb");
}
