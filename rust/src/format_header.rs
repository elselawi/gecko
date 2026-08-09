//! Fixed on-disk/wire compatibility header mirroring Dart `FormatHeader`.

pub const FORMAT_VERSION: u8 = 1;
pub const WIRE_VERSION: u8 = 1;
pub const MAGIC: [u8; 6] = [0x47, 0x45, 0x43, 0x4B, 0x4F, 0x01];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FormatHeader {
    pub format_version: u8,
    pub wire_version: u8,
    pub package_version: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeaderError(pub String);

impl std::fmt::Display for HeaderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "HeaderError: {}", self.0)
    }
}
impl std::error::Error for HeaderError {}

type Result<T> = std::result::Result<T, HeaderError>;

impl FormatHeader {
    pub fn encode(&self) -> Result<Vec<u8>> {
        let version = self.package_version.as_bytes();
        if version.len() > u8::MAX as usize {
            return Err(HeaderError("package version is too long".into()));
        }
        let mut out = MAGIC.to_vec();
        out.push(self.format_version);
        out.push(self.wire_version);
        out.push(version.len() as u8);
        out.extend_from_slice(version);
        Ok(out)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < MAGIC.len() + 3 || bytes[..MAGIC.len()] != MAGIC {
            return Err(HeaderError("invalid magic or truncated header".into()));
        }
        let package_len = bytes[MAGIC.len() + 2] as usize;
        let expected = MAGIC.len() + 3 + package_len;
        if bytes.len() != expected {
            return Err(HeaderError("invalid header length".into()));
        }
        let package_version = std::str::from_utf8(&bytes[MAGIC.len() + 3..])
            .map_err(|_| HeaderError("invalid package version UTF-8".into()))?
            .to_owned();
        Ok(Self {
            format_version: bytes[MAGIC.len()],
            wire_version: bytes[MAGIC.len() + 1],
            package_version,
        })
    }

    pub fn validate_compatibility(&self, format: u8, wire: u8) -> Result<()> {
        if self.format_version != format || self.wire_version != wire {
            return Err(HeaderError(format!(
                "requires format {}/wire {}, found {}/{}",
                format, wire, self.format_version, self.wire_version
            )));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let header = FormatHeader {
            format_version: FORMAT_VERSION,
            wire_version: WIRE_VERSION,
            package_version: "0.0.1".into(),
        };
        assert_eq!(
            FormatHeader::decode(&header.encode().unwrap()).unwrap(),
            header
        );
    }

    #[test]
    fn rejects_bad_header() {
        assert!(FormatHeader::decode(&[0, 1, 2]).is_err());
    }

    #[test]
    fn rejects_incompatible_versions() {
        let header = FormatHeader {
            format_version: FORMAT_VERSION,
            wire_version: WIRE_VERSION,
            package_version: "x".into(),
        };
        assert!(header.validate_compatibility(1, 99).is_err());
    }
}
