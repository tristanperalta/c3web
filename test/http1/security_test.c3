// HTTP/1.1 Security Tests
// RFC 9112 §11.2 - Request Smuggling Prevention
//
// Tests that prevent HTTP request smuggling attacks:
// - CL.TE (Content-Length to Transfer-Encoding) attacks
// - TE.CL (Transfer-Encoding to Content-Length) attacks
// - Multiple Content-Length header attacks
// - Header obfuscation attacks
// - Protocol violations that enable smuggling

module c3web::test::http1::security_test;

import c3web::http1::parser;

// Reject both Transfer-Encoding AND Content-Length (RFC 9112 §6.3 ¶3)
// This prevents request smuggling attacks
fn void test_smuggling_both_te_and_cl() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // RFC 9112 §6.3 Para 3: "Such a message might indicate an attempt to
    // perform request smuggling and ought to be handled as an error."
    String request =
        "POST / HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "Content-Length: 10\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "5\r\n"
        "hello\r\n"
        "0\r\n"
        "\r\n";

    parser::ParseResult? result = p.feed((char[])request);
    // MUST reject this as a security violation
    assert(@catch(result), "SECURITY: Must reject Transfer-Encoding + Content-Length");
    // Should return 400 Bad Request
}

// Reject multiple different Content-Length values
// Prevents CL.CL smuggling attacks
fn void test_smuggling_multiple_cl_different() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request =
        "POST / HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "Content-Length: 5\r\n"
        "Content-Length: 10\r\n"  // MISMATCH - attack vector!
        "\r\n"
        "hello";

    parser::ParseResult? result = p.feed((char[])request);
    // MUST reject different Content-Length values
    assert(@catch(result), "SECURITY: Must reject mismatched Content-Length headers");
    // Should return 400 Bad Request
}

// Accept multiple identical Content-Length values
// RFC 9112 allows this case
fn void test_multiple_cl_identical_allowed() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request =
        "POST / HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "Content-Length: 5\r\n"
        "Content-Length: 5\r\n"
        "Content-Length: 5\r\n"
        "\r\n"
        "hello";

    parser::ParseResult? result = p.feed((char[])request);
    // This is OK per RFC 9112 - all values are identical
    assert(result!! == parser::ParseResult.COMPLETE, "Identical Content-Length values should be allowed");
}

// Reject obfuscated Transfer-Encoding
// Attackers may try to hide Transfer-Encoding from certain parsers
fn void test_smuggling_te_obfuscation() @test {
    String[] obfuscated_requests = {
        // Multiple Transfer-Encoding headers with different values
        "POST / HTTP/1.1\r\n"
        "Transfer-Encoding: chunked\r\n"
        "Transfer-Encoding: identity\r\n"
        "\r\n",

        // Transfer-Encoding with multiple codings
        "POST / HTTP/1.1\r\n"
        "Transfer-Encoding: chunked, identity\r\n"
        "\r\n",

        // Whitespace tricks (space before colon is INVALID per RFC)
        "POST / HTTP/1.1\r\n"
        "Transfer-Encoding : chunked\r\n"
        "\r\n",
    };

    foreach (request : obfuscated_requests) {
        parser::Parser p;
        p.init();
        defer p.free();

        parser::ParseResult? result = p.feed((char[])request);
        // For maximum security, be VERY strict about Transfer-Encoding format
        // Only accept exactly "Transfer-Encoding: chunked" with optional whitespace
        assert(@catch(result), "SECURITY: Must reject obfuscated Transfer-Encoding");
    }
}

// Whitespace in header values (must trim correctly)
// Edge case: Improper whitespace handling can cause smuggling
fn void test_smuggling_header_value_whitespace() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // Leading/trailing whitespace in Content-Length
    String request =
        "POST / HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "Content-Length:  10  \r\n"  // Extra spaces around value
        "\r\n"
        "0123456789";

    parser::ParseResult? result = p.feed((char[])request);
    // Must correctly trim whitespace and parse "10"
    assert(result!! == parser::ParseResult.COMPLETE, "Should handle whitespace in header values");
    assert(p.get_body().len == 10, "Should parse trimmed Content-Length correctly");
}

// Reject bare LF without CR (protocol violation)
// Some parsers accept LF-only, enabling smuggling
fn void test_smuggling_bare_lf() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // Request with LF only (should be CRLF per RFC 9112)
    char[] request = {
        'P','O','S','T',' ','/',' ','H','T','T','P','/','1','.','1','\n',  // LF only
        'H','o','s','t',':',' ','e','x','a','m','p','l','e','.','c','o','m','\n',
        'C','o','n','t','e','n','t','-','L','e','n','g','t','h',':',' ','5','\n',
        '\n',
        'h','e','l','l','o'
    };

    parser::ParseResult? result = p.feed(request);
    // MUST reject: RFC 9112 requires CRLF, not bare LF
    assert(@catch(result), "SECURITY: Must reject bare LF (require CRLF)");
    // Should return 400 Bad Request
}

// Reject null bytes in headers
// Null bytes can truncate strings in some parsers
fn void test_smuggling_null_bytes() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // Request with null byte in Host header
    char[] request = {
        'P','O','S','T',' ','/',' ','H','T','T','P','/','1','.','1','\r','\n',
        'H','o','s','t',':',' ','e','x','a','m','p','l','e',
        0,  // Null byte - attack!
        'a','t','t','a','c','k','.','c','o','m','\r','\n',
        'C','o','n','t','e','n','t','-','L','e','n','g','t','h',':',' ','0','\r','\n',
        '\r','\n'
    };

    parser::ParseResult? result = p.feed(request);
    // Null bytes in headers are INVALID and dangerous
    assert(@catch(result), "SECURITY: Must reject null bytes in headers");
    // Should return 400 Bad Request
}
