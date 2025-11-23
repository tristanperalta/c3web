/**
 * HPACK Decoder Unit Tests
 * Tests for RFC 7541 compliance
 */
module c3web::test::http2::hpack_test;

import c3web::http2::hpack;
import std::io;

/**
 * Test static table lookup (RFC 7541 Appendix A)
 */
fn void test_static_table_lookup() @test
{
    // Index 1: :authority
    hpack::HeaderField h1 = hpack::get_static_header(1)!!;
    assert(h1.name == ":authority");
    assert(h1.value == "");

    // Index 2: :method GET
    hpack::HeaderField h2 = hpack::get_static_header(2)!!;
    assert(h2.name == ":method");
    assert(h2.value == "GET");

    // Index 8: :status 200
    hpack::HeaderField h8 = hpack::get_static_header(8)!!;
    assert(h8.name == ":status");
    assert(h8.value == "200");

    // Index 0 should fail (invalid)
    hpack::HeaderField? h0 = hpack::get_static_header(0);
    assert(@catch(h0) == hpack::INVALID_INDEX);

    // Index 62 should fail (beyond static table)
    hpack::HeaderField? h62 = hpack::get_static_header(62);
    assert(@catch(h62) == hpack::INVALID_INDEX);

    io::printn("[OK] Static table lookup");
}

/**
 * Test integer decoding (RFC 7541 Section 5.1)
 */
fn void test_integer_decoding() @test
{
    // Single byte integer (value < 2^N-1)
    // Value 10 with 5-bit prefix: 0b00001010 = 0x0A
    char[] data1 = { 0x0A };
    usz pos1 = 0;
    uint val1 = hpack::decode_integer(&data1, &pos1, 5)!!;
    assert(val1 == 10);
    assert(pos1 == 1);

    // Multi-byte integer example from RFC 7541 Section 5.1
    // Value 1337 with 5-bit prefix
    // 0b00011111 (31) + 0b10011010 (154) + 0b00001010 (10)
    // = 31 + 154 + 10*128 = 31 + 154 + 1280 = 1465... wait that's wrong
    // Actually: 31 + (154-128) + (10*128) = 31 + 26 + 1280 = 1337
    char[] data2 = { 0x1F, 0x9A, 0x0A };
    usz pos2 = 0;
    uint val2 = hpack::decode_integer(&data2, &pos2, 5)!!;
    assert(val2 == 1337);
    assert(pos2 == 3);

    // Empty data should fail
    char[] empty = {};
    usz pos_empty = 0;
    uint? val_empty = hpack::decode_integer(&empty, &pos_empty, 5);
    assert(@catch(val_empty) == hpack::INCOMPLETE_HEADER);

    io::printn("[OK] Integer decoding");
}

/**
 * Test string literal decoding (RFC 7541 Section 5.2)
 */
fn void test_string_decoding() @test
{
    // Plain string "hello" (not Huffman encoded)
    // 0x05 (length 5, H=0) + "hello"
    char[] data1 = { 0x05, 'h', 'e', 'l', 'l', 'o' };
    usz pos1 = 0;
    String str1 = hpack::decode_string(&data1, &pos1)!!;
    assert(str1 == "hello");
    assert(pos1 == 6);

    // Empty string
    char[] data2 = { 0x00 };
    usz pos2 = 0;
    String str2 = hpack::decode_string(&data2, &pos2)!!;
    assert(str2 == "");
    assert(pos2 == 1);

    // Truncated string should fail
    char[] data3 = { 0x05, 'h', 'e' };  // Says 5 bytes but only 2
    usz pos3 = 0;
    String? str3 = hpack::decode_string(&data3, &pos3);
    assert(@catch(str3) == hpack::INCOMPLETE_HEADER);

    io::printn("[OK] String decoding");
}

/**
 * Test indexed header field decoding (RFC 7541 Section 6.1)
 */
fn void test_indexed_header() @test
{
    // Indexed header field: 0x82 = 1000 0010 -> index 2 (:method GET)
    char[] data1 = { 0x82 };
    hpack::HeaderField[]? headers = hpack::decode_header_block(data1);
    hpack::HeaderField[] h = headers!!;
    io::printfn("something here---- %s", h);
    assert(h.len == 1);
    assert(h[0].name == ":method");
    assert(h[0].value == "GET");

    // Index 0 should fail (0x80 = indexed with index 0)
    char[] data2 = { 0x80 };
    hpack::HeaderField[]? headers2 = hpack::decode_header_block(data2);
    assert(@catch(headers2) == hpack::COMPRESSION_ERROR);

    io::printn("[OK] Indexed header field");
}

/**
 * Test literal header without indexing (RFC 7541 Section 6.2.2)
 */
fn void test_literal_header() @test
{
    // Literal header without indexing, new name
    // 0x00 + name length + name + value length + value
    // 0x00 0x04 "test" 0x05 "value"
    char[] data1 = { 0x00, 0x04, 't', 'e', 's', 't', 0x05, 'v', 'a', 'l', 'u', 'e' };
    hpack::HeaderField[]? headers = hpack::decode_header_block(data1);
    hpack::HeaderField[] h = headers!!;
    assert(h.len == 1);
    assert(h[0].name == "test");
    assert(h[0].value == "value");

    io::printn("[OK] Literal header without indexing");
}

/**
 * Test multiple headers in one block
 */
fn void test_multiple_headers() @test
{
    // :method GET (0x82) + :path / (0x84)
    char[] data = { 0x82, 0x84 };
    hpack::HeaderField[]? headers = hpack::decode_header_block(data);
    hpack::HeaderField[] h = headers!!;
    assert(h.len == 2);
    assert(h[0].name == ":method");
    assert(h[0].value == "GET");
    assert(h[1].name == ":path");
    assert(h[1].value == "/");

    io::printn("[OK] Multiple headers");
}

/**
 * Test h2spec specific cases
 */
fn void test_h2spec_cases() @test
{
    // h2spec tests invalid index (beyond table size)
    // Index 70 (0xC6 = 1100 0110 = 0x40 + 0x46 = indexed field with index 70)
    // Actually 0xC6 = 11000110 binary, but high bit means indexed
    // 0xC6 = 198, and 198 - 128 = 70 as index
    // Wait, for indexed header field, format is 1NNNNNNN
    // So 0xC6 = 1 1000110 = index 70
    // Static table is 1-61, dynamic table starts at 62
    // Index 70 with empty dynamic table should fail
    char[] data_invalid = { 0xC6 };  // 0xC6 = 198 = 128 + 70 = indexed field index 70
    hpack::HeaderField[]? headers_invalid = hpack::decode_header_block(data_invalid);
    assert(@catch(headers_invalid) == hpack::COMPRESSION_ERROR);

    io::printn("[OK] h2spec invalid index case");
}
