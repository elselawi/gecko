//! Dart/native compatibility handshake contract.
//!
//! This is intentionally a small, deterministic JSON contract. The native
//! worker exposes the same fields before accepting database operations.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

pub const HANDSHAKE_VERSION: u8 = 1;
pub const PACKAGE_VERSION: &str = "0.0.1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompatibilityHandshake {
    #[serde(rename = "handshakeVersion")]
    pub handshake_version: u8,
    #[serde(rename = "packageVersion")]
    pub package_version: String,
    #[serde(rename = "wireVersion")]
    pub wire_version: u8,
    #[serde(rename = "formatVersion")]
    pub format_version: u8,
    #[serde(rename = "nativeBuildId")]
    pub native_build_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompatibilityError(pub String);

impl std::fmt::Display for CompatibilityError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "CompatibilityError: {}", self.0)
    }
}
impl std::error::Error for CompatibilityError {}

type Result<T> = std::result::Result<T, CompatibilityError>;

impl CompatibilityHandshake {
    pub fn current(native_build_id: impl Into<String>) -> Self {
        Self {
            handshake_version: HANDSHAKE_VERSION,
            package_version: PACKAGE_VERSION.into(),
            wire_version: crate::wire::WIRE_VERSION,
            format_version: crate::format_header::FORMAT_VERSION,
            native_build_id: native_build_id.into(),
        }
    }

    pub fn encode(&self) -> Result<String> {
        serde_json::to_string(self).map_err(|error| CompatibilityError(error.to_string()))
    }

    pub fn decode(encoded: &str) -> Result<Self> {
        serde_json::from_str(encoded).map_err(|error| CompatibilityError(error.to_string()))
    }

    pub fn validate_compatibility(
        &self,
        expected_handshake_version: u8,
        expected_package_version: &str,
        expected_wire_version: u8,
        expected_format_version: u8,
    ) -> Result<()> {
        if self.handshake_version != expected_handshake_version
            || self.package_version != expected_package_version
            || self.wire_version != expected_wire_version
            || self.format_version != expected_format_version
            || self.native_build_id.trim().is_empty()
        {
            return Err(CompatibilityError(format!(
                "native artifact is incompatible: package {}, wire {}, format {}, build {}",
                self.package_version, self.wire_version, self.format_version, self.native_build_id
            )));
        }
        Ok(())
    }

    /// Returns a stable map useful to callers that need diagnostics without
    /// depending on JSON field ordering.
    pub fn fields(&self) -> BTreeMap<&'static str, String> {
        BTreeMap::from([
            ("formatVersion", self.format_version.to_string()),
            ("handshakeVersion", self.handshake_version.to_string()),
            ("nativeBuildId", self.native_build_id.clone()),
            ("packageVersion", self.package_version.clone()),
            ("wireVersion", self.wire_version.to_string()),
        ])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_handshake_round_trips() {
        let handshake = CompatibilityHandshake::current("test-build");
        assert_eq!(
            CompatibilityHandshake::decode(&handshake.encode().unwrap()).unwrap(),
            handshake
        );
    }

    #[test]
    fn rejects_incompatible_versions() {
        let handshake = CompatibilityHandshake::current("test-build");
        assert!(handshake
            .validate_compatibility(HANDSHAKE_VERSION, "9.9.9", 1, 1)
            .is_err());
    }
}
