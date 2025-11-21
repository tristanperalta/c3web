// HTTP/1.1 Request Body Handling Tests
// RFC 9112 §6 - Message Body
//
// Tests message body length determination including:
// - Content-Length vs Transfer-Encoding precedence
// - Multiple Content-Length header handling
// - Body size limits
// - Empty body handling

module c3web::test::http1::body_handling_test;

import c3web::http1::parser;
import c3web::common::method;
import std::core::string;
import std::io;

// Content-Length takes exact bytes (not more)
fn void test_body_content_length_exact() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request =
        "POST /upload HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "Content-Length: 5\r\n"
        "\r\n"
        "hello"
        "extra data after body"; // This is from NEXT request (pipelining)

    parser::ParseResult? result = p.feed((char[])request);
    assert(result!! == parser::ParseResult.COMPLETE, "Should parse with exact Content-Length");

    char[] body = p.get_body();
    assert(body.len == 5, "Body should be exactly 5 bytes");
    assert((String)body == "hello", "Body should be 'hello'");

    // Verify parser didn't consume extra data (for pipelining)
    // The "extra data after body" should remain in buffer for next request
}

// Transfer-Encoding overrides Content-Length (RFC 9112 §6.3 ¶3)
// SECURITY: This test prevents request smuggling attacks
fn void test_transfer_encoding_precedence() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request =
        "POST /upload HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "Transfer-Encoding: chunked\r\n"
        "Content-Length: 999\r\n"  // MUST be ignored or treated as error
        "\r\n"
        "5\r\n"
        "hello\r\n"
        "0\r\n"
        "\r\n";

    // RFC 9112 §6.3 Para 3: "Such a message might indicate an attempt to
    // perform request smuggling and ought to be handled as an error."
    //
    // Conservative approach: Reject the request (400 Bad Request)
    parser::ParseResult? result = p.feed((char[])request);
    assert(@catch(result), "Should reject Transfer-Encoding + Content-Length as security risk");
}

// Multiple identical Content-Length values (valid per RFC)
fn void test_multiple_content_length_identical() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // RFC 9112 §6.3: Multiple Content-Length with same value is OK
    String request =
        "POST /upload HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "Content-Length: 5\r\n"
        "Content-Length: 5\r\n"
        "Content-Length: 5\r\n"
        "\r\n"
        "hello";

    parser::ParseResult? result = p.feed((char[])request);
    assert(result!! == parser::ParseResult.COMPLETE, "Multiple identical Content-Length should be OK");
    assert((String)p.get_body() == "hello");
}

// Multiple different Content-Length values (INVALID - security)
fn void test_multiple_content_length_different() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // RFC 9112 §6.3: Different Content-Length values = 400 Bad Request
    // SECURITY: This is a request smuggling attack vector
    String request =
        "POST /upload HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "Content-Length: 5\r\n"
        "Content-Length: 10\r\n"  // MISMATCH - attack!
        "\r\n"
        "hello";

    parser::ParseResult? result = p.feed((char[])request);
    assert(@catch(result), "Should reject different Content-Length values");
}

// No body (GET request)
fn void test_get_request_no_body() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request =
        "GET / HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "\r\n";

    parser::ParseResult? result = p.feed((char[])request);
    assert(result!! == parser::ParseResult.COMPLETE);
    assert(p.get_body().len == 0, "GET request should have no body");
}

// Content-Length: 0 (explicit empty body)
fn void test_content_length_zero() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request =
        "POST /create HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "Content-Length: 0\r\n"
        "\r\n";

    parser::ParseResult? result = p.feed((char[])request);
    assert(result!! == parser::ParseResult.COMPLETE);
    assert(p.get_body().len == 0, "Content-Length: 0 should have empty body");
}

// Max body size enforcement (413 Payload Too Large)
fn void test_body_size_limit() @test {
    parser::Parser p;
    p.init();
    defer p.free();
    p.max_request_size = 1024;  // Set 1KB limit

    String request =
        "POST /upload HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "Content-Length: 10000\r\n"  // Exceeds 1KB limit
        "\r\n";

    parser::ParseResult? result = p.feed((char[])request);
    // Should fail immediately upon seeing Content-Length > limit
    // Return 413 Payload Too Large
    assert(@catch(result), "Should reject body exceeding size limit");
}

// Negative Content-Length (INVALID per RFC 9112 §6.3)
fn void test_negative_content_length() @test {
    String[] negative_values = {
        "-1",
        "-100",
        "-420",
        "-999999999"
    };

    foreach (value : negative_values) {
        parser::Parser p;
        p.init();
        defer p.free();

        String request = string::tformat(
            "POST /upload HTTP/1.1\r\n"
            "Host: example.com\r\n"
            "Content-Length: %s\r\n"
            "\r\n",
            value
        );

        parser::ParseResult? result = p.feed((char[])request);
        assert(@catch(result), "Should reject negative Content-Length");
        // Should return 400 Bad Request
    }
}

// Non-integer Content-Length (INVALID per RFC 9112 §6.3)
fn void test_non_integer_content_length() @test {
    String[] invalid_values = {
        "abc123",       // Letters followed by numbers
        "123abc",       // Numbers followed by letters
        "0x10",         // Hex notation
        "3.14",         // Decimal/float
        "12.0",         // Float that looks like int
        "1e5",          // Scientific notation
        "1,000",        // Comma separator
        "foo",          // Pure text
        "",             // Empty string
        " ",            // Just whitespace (trims to empty)
        // Note: " 123" and "123 " are valid per RFC 9110 (OWS allowed)
    };

    foreach (i, value : invalid_values) {
        parser::Parser p;
        p.init();
        defer p.free();

        String request = string::tformat(
            "POST /upload HTTP/1.1\r\n"
            "Host: example.com\r\n"
            "Content-Length: %s\r\n"
            "\r\n",
            value
        );

        parser::ParseResult? result = p.feed((char[])request);
        assert(@catch(result), "Should reject non-integer Content-Length");
        // Should return 400 Bad Request
    }
}
