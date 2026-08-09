use gecko_db_rust::format_header::{FormatHeader, FORMAT_VERSION, MAGIC, WIRE_VERSION};

#[test]
fn dart_header_golden_bytes_are_rust_compatible() {
    let header = FormatHeader {
        format_version: FORMAT_VERSION,
        wire_version: WIRE_VERSION,
        package_version: "0.0.1".into(),
    };
    let expected = [
        MAGIC[0], MAGIC[1], MAGIC[2], MAGIC[3], MAGIC[4], MAGIC[5], 1, 1, 5, b'0', b'.', b'0',
        b'.', b'1',
    ];
    assert_eq!(header.encode().unwrap(), expected);
    assert_eq!(FormatHeader::decode(&expected).unwrap(), header);
}
