// HTTP/1.1 Chunked Transfer Encoding Tests
// RFC 9112 §7.1 - Chunked Transfer Coding
//
// Tests chunked request body parsing including:
// - Basic chunk parsing
// - Chunk extensions
// - Trailer headers
// - Edge cases and error conditions

module c3web::test::http1::chunked_encoding_test;

import c3web::http1::parser;
import c3web::common::method;
import std::core::string;
import std::io;

// Basic single chunk
fn void test_chunked_basic() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request =
        "POST /upload HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "5\r\n"
        "hello\r\n"
        "0\r\n"
        "\r\n";

    parser::ParseResult? result = p.feed((char[])request);
    assert(result!! == parser::ParseResult.COMPLETE, "Should parse complete chunked message");

    char[] body = p.get_body();
    assert(body.len == 5, "Body should be 5 bytes");
    assert((String)body == "hello", "Body should be 'hello'");
}

// Multiple chunks that concatenate
fn void test_chunked_multiple() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request =
        "POST /upload HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "5\r\n"
        "hello\r\n"
        "7\r\n"
        " world!\r\n"
        "0\r\n"
        "\r\n";

    parser::ParseResult? result = p.feed((char[])request);
    assert(result!! == parser::ParseResult.COMPLETE);

    char[] body = p.get_body();
    assert(body.len == 12, "Body should be 12 bytes");
    assert((String)body == "hello world!", "Body should concatenate chunks");
}

// Hex case insensitivity
fn void test_chunked_hex_cases() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // Lowercase hex
    String request1 =
        "POST /upload HTTP/1.1\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "a\r\n"
        "0123456789\r\n"
        "0\r\n"
        "\r\n";

    parser::ParseResult? result1 = p.feed((char[])request1);
    assert(result1!! == parser::ParseResult.COMPLETE);
    assert(p.get_body().len == 10, "Lowercase 'a' = 10 bytes");

    // Reset for next test
    p.reset();

    // Uppercase hex
    String request2 =
        "POST /upload HTTP/1.1\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "A\r\n"
        "0123456789\r\n"
        "0\r\n"
        "\r\n";

    parser::ParseResult? result2 = p.feed((char[])request2);
    assert(result2!! == parser::ParseResult.COMPLETE);
    assert(p.get_body().len == 10, "Uppercase 'A' = 10 bytes");

    // Reset for mixed case
    p.reset();

    // Mixed case: 0xAB = 171 decimal
    DynamicArenaAllocator arena;
    arena.init(mem, 1024);
    defer arena.free();

    DString data = dstring::new(&arena);
    for (int i = 0; i < 171; i++) {
        data.append_char('x');
    }
    String data_str = data.str_view();
    String request3 = string::tformat(
        "POST /upload HTTP/1.1\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "aB\r\n"
        "%s\r\n"
        "0\r\n"
        "\r\n",
        data_str
    );

    parser::ParseResult? result3 = p.feed((char[])request3);
    assert(result3!! == parser::ParseResult.COMPLETE);
    assert(p.get_body().len == 171, "Mixed case 'aB' = 171 bytes");
}

// Chunk extensions (MUST ignore if not understood per RFC 9112 §7.1.1)
fn void test_chunked_extensions_ignored() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request =
        "POST /upload HTTP/1.1\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "5;name=value;foo=bar\r\n"  // Chunk extensions
        "hello\r\n"
        "0;final=yes\r\n"           // Extension on last chunk
        "\r\n";

    parser::ParseResult? result = p.feed((char[])request);
    assert(result!! == parser::ParseResult.COMPLETE);

    char[] body = p.get_body();
    assert((String)body == "hello", "Should ignore extensions and parse body");
}

// Trailer headers after last chunk
fn void test_chunked_with_trailers() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request =
        "POST /upload HTTP/1.1\r\n"
        "Transfer-Encoding: chunked\r\n"
        "Trailer: X-Checksum\r\n"  // Declares trailer fields
        "\r\n"
        "5\r\n"
        "hello\r\n"
        "0\r\n"
        "X-Checksum: abc123\r\n"  // Trailer field
        "X-Custom: value\r\n"
        "\r\n";

    parser::ParseResult? result = p.feed((char[])request);
    assert(result!! == parser::ParseResult.COMPLETE);

    // Verify body
    char[] body = p.get_body();
    assert((String)body == "hello");

    // Verify trailers were parsed
    parser::Request* req = p.get_request();
    assert(req.trailers.has("x-checksum"), "Should have trailer header");
    String? checksum = req.trailers.get("x-checksum");
    assert(checksum!! == "abc123", "Trailer value should match");
}

// Zero-length last chunk (terminates message)
fn void test_chunked_zero_length_terminator() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request =
        "POST /upload HTTP/1.1\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "5\r\n"
        "hello\r\n"
        "0\r\n"   // Last chunk (terminates)
        "\r\n";

    parser::ParseResult? result = p.feed((char[])request);
    assert(result!! == parser::ParseResult.COMPLETE);
    assert((String)p.get_body() == "hello");
}

// Incremental chunk size arrival (byte-by-byte)
fn void test_chunked_incremental_chunk_size() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    p.feed((char[])"POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")!!;

    // Feed chunk size one char at a time
    parser::ParseResult? r1 = p.feed((char[])"1");
    assert(r1!! == parser::ParseResult.MORE, "Need more for chunk size");

    parser::ParseResult? r2 = p.feed((char[])"0");  // 0x10 = 16
    assert(r2!! == parser::ParseResult.MORE);

    parser::ParseResult? r3 = p.feed((char[])"\r");
    assert(r3!! == parser::ParseResult.MORE);

    parser::ParseResult? r4 = p.feed((char[])"\n");
    assert(r4!! == parser::ParseResult.MORE, "Need chunk data");

    // Feed chunk data
    char[16] data = { 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x' };
    parser::ParseResult? r5 = p.feed(&data);
    assert(r5!! == parser::ParseResult.MORE, "Need CRLF after data");

    parser::ParseResult? r6 = p.feed((char[])"\r\n");
    assert(r6!! == parser::ParseResult.MORE, "Need last chunk");

    // Last chunk
    parser::ParseResult? r7 = p.feed((char[])"0\r\n\r\n");
    assert(r7!! == parser::ParseResult.COMPLETE);

    assert(p.get_body().len == 16);
}

// Chunk data split across multiple reads
fn void test_chunked_data_split() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    p.feed((char[])"POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")!!;
    p.feed((char[])"A\r\n")!!;  // 10 bytes expected

    // Feed data in pieces (total 10 bytes)
    p.feed((char[])"abc")!!;     // 3 bytes
    p.feed((char[])"defg")!!;    // 4 bytes
    p.feed((char[])"hij")!!;     // 3 bytes

    parser::ParseResult? result = p.feed((char[])"\r\n");
    assert(result!! == parser::ParseResult.MORE, "Need last chunk");

    p.feed((char[])"0\r\n\r\n")!!;
    assert((String)p.get_body() == "abcdefghij");
}

// Invalid chunk size (non-hex) - should fail
fn void test_chunked_invalid_size() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request =
        "POST / HTTP/1.1\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "XYZ\r\n";  // Invalid hex characters

    parser::ParseResult? result = p.feed((char[])request);
    assert(@catch(result), "Should fail on invalid chunk size");
}

// Missing CRLF after chunk data - should fail
fn void test_chunked_missing_crlf() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request =
        "POST / HTTP/1.1\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "5\r\n"
        "hello"     // Missing CRLF after data
        "0\r\n\r\n";

    parser::ParseResult? result = p.feed((char[])request);
    assert(@catch(result), "Should fail on missing CRLF after chunk data");
}
