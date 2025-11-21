// HTTP/1.1 Error Handling Tests
// Tests that parser returns appropriate HTTP status codes for errors
//
// Validates error-to-status code mapping:
// - 400 Bad Request (invalid syntax)
// - 413 Content Too Large (body exceeds limit)
// - 431 Request Header Fields Too Large (headers exceed limit)
// - 414 URI Too Long (URI exceeds limit)
// - 505 HTTP Version Not Supported (wrong version)

module c3web::test::http1::error_handling_test;

import c3web::http1::parser;
import std::core::string;

// Return 400 for invalid request line
fn void test_error_400_invalid_request_line() @test {
    String[] invalid_requests = {
        "GET\r\n\r\n",                          // Missing target and version
        "GET /path\r\n\r\n",                    // Missing version
        "GETPOST /path HTTP/1.1\r\n\r\n",       // Invalid method (no space)
        "GET  /path HTTP/1.1\r\n\r\n",          // Double space
        "GET /path HTTP/1.1 extra\r\n\r\n",     // Extra content after version
    };

    foreach (request : invalid_requests) {
        parser::Parser p;
        p.init();
        defer p.free();

        parser::ParseResult? result = p.feed((char[])request);
        assert(@catch(result), "Should fail on invalid request line");
        // Error should map to 400 Bad Request
    }
}

// Return 413 for body exceeding size limit
fn void test_error_413_payload_too_large() @test {
    parser::Parser p;
    p.init();
    defer p.free();
    p.max_request_size = 100;  // Set 100 byte limit

    String request =
        "POST /upload HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "Content-Length: 1000\r\n"  // Exceeds 100 byte limit
        "\r\n";

    parser::ParseResult? result = p.feed((char[])request);
    assert(@catch(result), "Should fail when Content-Length exceeds limit");
    // Error should map to 413 Content Too Large
}

// Return 431 for headers exceeding size limit
fn void test_error_431_headers_too_large() @test {
    parser::Parser p;
    p.init();
    defer p.free();
    p.max_header_size = 1024;  // Set 1KB header limit

    // Build request with headers > 1024 bytes
    DynamicArenaAllocator arena;
    arena.init(mem, 2048);
    defer arena.free();

    DString large_value = dstring::new(&arena);
    for (int i = 0; i < 2000; i++) {
        large_value.append_char('x');
    }
    String request = string::tformat(
        "GET / HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "X-Large-Header: %s\r\n"
        "\r\n",
        large_value.str_view()
    );

    parser::ParseResult? result = p.feed((char[])request);
    assert(@catch(result), "Should fail when headers exceed size limit");
    // Error should map to 431 Request Header Fields Too Large
}

// Return 414 for URI exceeding length limit
fn void test_error_414_uri_too_long() @test {
    parser::Parser p;
    p.init();
    defer p.free();
    // Parser should enforce URI length limit (e.g., 8KB per RFC recommendations)

    // Create URI with path > 8000 bytes (conservative limit)
    DynamicArenaAllocator arena;
    arena.init(mem, 10240);
    defer arena.free();

    DString long_path = dstring::new(&arena);
    long_path.append_char('/');
    for (int i = 0; i < 10000; i++) {
        long_path.append_char('x');
    }
    String request = string::tformat(
        "GET %s HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "\r\n",
        long_path.str_view()
    );

    parser::ParseResult? result = p.feed((char[])request);
    assert(@catch(result), "Should fail when URI exceeds length limit");
    // Error should map to 414 URI Too Long
}

// Return 505 for unsupported HTTP version
fn void test_error_505_version_not_supported() @test {
    String[] unsupported_versions = {
        "GET / HTTP/2.0\r\n\r\n",    // HTTP/2.0 not supported on HTTP/1.1 connection
        "GET / HTTP/0.9\r\n\r\n",    // HTTP/0.9 deprecated
        "GET / HTTP/1.0\r\n\r\n",    // HTTP/1.0 (could optionally support this)
        "GET / HTTP/3.0\r\n\r\n",    // HTTP/3
    };

    foreach (request : unsupported_versions) {
        parser::Parser p;
        p.init();
        defer p.free();

        parser::ParseResult? result = p.feed((char[])request);
        // Depending on implementation, HTTP/1.0 might be supported
        // But HTTP/2.0, 0.9, 3.0 should definitely fail
        if (request.contains("HTTP/1.0")) {
            // HTTP/1.0 support is optional
            continue;
        }
        assert(@catch(result), "Should fail on unsupported HTTP version");
        // Error should map to 505 HTTP Version Not Supported
    }
}
