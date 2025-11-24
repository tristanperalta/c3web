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

/**
 * Test Huffman padding validation (RFC 7541 Section 5.2)
 *
 * RFC 7541: "A padding NOT consisting entirely of ones MUST be treated as a decoding error."
 * RFC 7541: "A padding strictly longer than 7 bits MUST be treated as a decoding error."
 */
fn void test_huffman_padding_not_ones() @test
{
    // '0' encodes as 00000 (5 bits)
    // 0x06 = 00000110 = '0' (5 bits) + 110 (3 bits padding)
    // Padding 110 is NOT all 1s (should be 111), so this is invalid
    char[] data_invalid_padding = { 0x06 };
    String? result = hpack::decode_huffman(data_invalid_padding);
    assert(@catch(result) == hpack::INVALID_HUFFMAN);

    // Also test: 0x04 = 00000100 = '0' (5 bits) + 100 (3 bits with zeros)
    char[] data_zeros_padding = { 0x04 };
    String? result2 = hpack::decode_huffman(data_zeros_padding);
    assert(@catch(result2) == hpack::INVALID_HUFFMAN);

    io::printn("[OK] Huffman padding not all 1s rejected");
}

/**
 * Test Huffman padding >7 bits detection (RFC 7541 Section 5.2)
 * h2spec test: hpack/5.2/1
 *
 * RFC 7541: "A padding strictly longer than 7 bits MUST be treated as a decoding error."
 *
 * When all remaining bits are 1s and there are >7 of them, this is excessive
 * padding, not more valid symbols (even if 8 bits of 1s could decode as ';').
 */
fn void test_huffman_padding_too_long() @test
{
    // 'a' (0x61) encodes as 00011 (5 bits)
    // Valid: 0x1f = 00011111 = 'a' (5 bits) + 3 bits padding = valid
    char[] data_valid = { 0x1f };
    String valid_result = hpack::decode_huffman(data_valid)!!;
    assert(valid_result == "a");

    // Invalid: 0x1f 0xff = 00011111 11111111 = 'a' (5 bits) + 11 bits of 1s
    // The 11 bits of 1s could decode as ';' + 3-bit padding, but since ALL
    // remaining bits after 'a' are 1s and there are >7 of them, this is
    // invalid padding, not a valid ';' character.
    char[] data_too_much_padding = { 0x1f, 0xff };
    String? result = hpack::decode_huffman(data_too_much_padding);
    assert(@catch(result) == hpack::INVALID_HUFFMAN);

    io::printn("[OK] Huffman padding >7 bits rejected (hpack/5.2/1)");
}

/**
 * Test Huffman EOS symbol detection (RFC 7541 Section 5.2)
 * h2spec test: hpack/5.2/3
 *
 * RFC 7541: "A Huffman-encoded string literal containing the EOS symbol
 * MUST be treated as a decoding error."
 *
 * EOS symbol = 30 bits of 1s (0x3FFFFFFF)
 */
fn void test_huffman_eos_in_string() @test
{
    // EOS is 30 bits of 1s: 111111111111111111111111111111
    //
    // 4 bytes of 0xFF = 32 bits of 1s, which contains the full EOS pattern
    // The decoder should detect EOS before/while decoding these bits

    char[] data_with_eos = { 0xFF, 0xFF, 0xFF, 0xFF };  // 32 bits of 1s
    String? result = hpack::decode_huffman(data_with_eos);
    assert(@catch(result) == hpack::EOS_IN_STRING);

    io::printn("[OK] Huffman EOS in string rejected (hpack/5.2/3)");
}

/**
 * Test valid Huffman encoding still works
 */
fn void test_huffman_valid_encoding() @test
{
    // '0' = 00000 (5 bits), needs 3-bit padding of 1s
    // 0x07 = 00000111 = '0' with proper 3-bit padding
    char[] data_valid = { 0x07 };
    String result = hpack::decode_huffman(data_valid)!!;
    assert(result == "0");

    // Valid 6-bit padding
    // Two '0's: 00000 00000 (10 bits) + 111111 (6-bit padding) = 16 bits
    // Binary: 0000000000111111 = 0x00, 0x3F
    char[] data_two_zeros = { 0x00, 0x3F };
    String result2 = hpack::decode_huffman(data_two_zeros)!!;
    assert(result2 == "00");

    io::printn("[OK] Valid Huffman encoding works");
}

/**
 * Test that EOS in Huffman string within a header block returns COMPRESSION_ERROR
 * h2spec test: hpack/5.2/3
 *
 * This tests the full flow: header block -> decode_string -> decode_huffman -> EOS detection
 * The server should respond with GOAWAY(COMPRESSION_ERROR), not process the request.
 */
fn void test_header_block_with_eos_returns_compression_error() @test
{
    // Build a header block with a Huffman-encoded value containing EOS
    // Format: 0x00 (literal without indexing, new name) + name + value
    //
    // Name: plain string "x" (0x01 0x78)
    // Value: Huffman string with EOS (0x84 = H-bit + length 4, then 0xFF 0xFF 0xFF 0xFF)
    //
    // The 4 bytes of 0xFF contain the 30-bit EOS pattern
    char[] header_block = {
        0x00,       // Literal without indexing, new name (index 0)
        0x01, 'x',  // Name: plain string "x" (length 1, no H-bit)
        0x84,       // Value: Huffman-encoded, length 4 (H-bit set = 0x80 | 4)
        0xFF, 0xFF, 0xFF, 0xFF  // 32 bits of 1s - contains EOS (30 bits of 1s)
    };

    // This should fail with COMPRESSION_ERROR because EOS is in the Huffman string
    hpack::HeaderField[]? result = hpack::decode_header_block(header_block);

    // Must fail - EOS in string is a decoding error per RFC 7541
    assert(@catch(result) == hpack::COMPRESSION_ERROR,
           "Expected COMPRESSION_ERROR for EOS in Huffman string within header block");

    io::printn("[OK] Header block with EOS returns COMPRESSION_ERROR (hpack/5.2/3)");
}

/**
 * Test decoding of fragmented header blocks (CONTINUATION frame simulation)
 * h2spec test: http2/6.10/1
 *
 * Header blocks may be split across HEADERS + multiple CONTINUATION frames.
 * When concatenated, they must decode correctly.
 */
fn void test_decode_fragmented_header_block() @test
{
    // Full header block: :method GET (0x82) + :path / (0x84) + :scheme https (0x87)
    // Split into 3 fragments to simulate HEADERS + 2 CONTINUATION frames
    char[] fragment1 = { 0x82 };        // :method GET
    char[] fragment2 = { 0x84 };        // :path /
    char[] fragment3 = { 0x87 };        // :scheme https

    // Concatenate fragments (simulating what the server does with CONTINUATION)
    char[3] full_block;
    full_block[0] = fragment1[0];
    full_block[1] = fragment2[0];
    full_block[2] = fragment3[0];

    // Decode the concatenated header block
    hpack::HeaderField[]? result = hpack::decode_header_block(full_block[..]);
    hpack::HeaderField[] headers = result!!;

    assert(headers.len == 3, "Expected 3 headers from fragmented block");
    assert(headers[0].name == ":method" && headers[0].value == "GET");
    assert(headers[1].name == ":path" && headers[1].value == "/");
    assert(headers[2].name == ":scheme" && headers[2].value == "https");

    io::printn("[OK] Fragmented header block decodes correctly (http2/6.10/1)");
}

/**
 * Test decoding a more complex fragmented header block with literal headers
 * This simulates what h2spec sends in the CONTINUATION test
 */
fn void test_decode_fragmented_literal_headers() @test
{
    // Create a header block with indexed + literal headers
    // :method GET (0x82) + custom header "x-test: value"
    //
    // Literal without indexing, indexed name (header name from index):
    // 0x0F 0x00 = literal without indexing, index 0 (new name follows)
    // But simpler: use 0x00 for literal new name
    char[] header_block = {
        0x82,                                    // :method GET
        0x84,                                    // :path /
        0x87,                                    // :scheme https
        0x41,                                    // :authority (index 1) with literal value
        0x09, 'l', 'o', 'c', 'a', 'l', 'h', 'o', 's', 't'  // "localhost"
    };

    hpack::HeaderField[]? result = hpack::decode_header_block(header_block);
    hpack::HeaderField[] headers = result!!;

    assert(headers.len == 4, "Expected 4 headers");
    assert(headers[0].name == ":method" && headers[0].value == "GET");
    assert(headers[1].name == ":path" && headers[1].value == "/");
    assert(headers[2].name == ":scheme" && headers[2].value == "https");
    assert(headers[3].name == ":authority" && headers[3].value == "localhost");

    io::printn("[OK] Complex fragmented header block decodes correctly");
}
