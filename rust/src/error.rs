//! Typed error envelope used by the native boundary.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GeckoErrorType {
    Unknown,
    KeyNotFound,
    CollectionNotFound,
    SchemaValidation,
    TransactionAborted,
    Decryption,
    DatabaseAlreadyOpen,
    DatabaseLocked,
    UpgradeRequired,
    ChecksumMismatch,
    InvalidOperation,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GeckoErrorEnvelope {
    #[serde(rename = "type")]
    pub error_type: GeckoErrorType,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<serde_json::Value>,
}

impl GeckoErrorEnvelope {
    pub fn new(error_type: GeckoErrorType, message: impl Into<String>) -> Self {
        Self {
            error_type,
            message: message.into(),
            details: None,
        }
    }

    pub fn encode(&self) -> String {
        serde_json::to_string(self).expect("typed error envelope must encode")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_envelope_round_trips() {
        let error = GeckoErrorEnvelope {
            error_type: GeckoErrorType::DatabaseLocked,
            message: "database is locked".into(),
            details: Some(serde_json::json!({"path": "db.redb"})),
        };
        let decoded: GeckoErrorEnvelope = serde_json::from_str(&error.encode()).unwrap();
        assert_eq!(decoded, error);
    }
}
