// HTTP/1.1 Response Parser Tests
// Tests response parsing from server

module c3web::test::http1::response_parser_test;

import c3web::http1::response_parser;
import c3web::http1::client_response;
import c3web::common::status;
import std::core::string;

// Basic 200 OK response
fn void test_basic_200_ok() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    String response_data = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nHello World";
    response_parser::ParseResult result = parser.feed((char[])response_data)!!;

    assert(result == response_parser::ParseResult.COMPLETE);

    client_response::ClientResponse* resp = parser.get_response();
    assert(resp.status == 200);
    assert(resp.reason_phrase == "OK");

    char[] body = parser.get_body();
    assert((String)body == "Hello World");
}

// 404 Not Found response
fn void test_404_not_found() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    String response_data = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
    response_parser::ParseResult result = parser.feed((char[])response_data)!!;

    assert(result == response_parser::ParseResult.COMPLETE);

    client_response::ClientResponse* resp = parser.get_response();
    assert(resp.status == 404);
    assert(resp.reason_phrase == "Not Found");
    assert(resp.is_client_error());
}

// 500 Internal Server Error
fn void test_500_server_error() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    String response_data = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 21\r\n\r\nInternal Server Error";
    response_parser::ParseResult result = parser.feed((char[])response_data)!!;

    assert(result == response_parser::ParseResult.COMPLETE);

    client_response::ClientResponse* resp = parser.get_response();
    assert(resp.status == 500);
    assert(resp.is_server_error());
}

// Response with multiple headers
fn void test_multiple_headers() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    String response_data =
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: 13\r\n"
        "X-Custom: test\r\n"
        "\r\n"
        "{\"foo\":\"bar\"}";

    response_parser::ParseResult result = parser.feed((char[])response_data)!!;
    assert(result == response_parser::ParseResult.COMPLETE);

    client_response::ClientResponse* resp = parser.get_response();
    assert(resp.headers.get("Content-Type")!! == "application/json");
    assert(resp.headers.get("X-Custom")!! == "test");
}

// Incremental parsing (data arrives in chunks)
fn void test_incremental_parsing() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    // Feed status line
    response_parser::ParseResult result = parser.feed((char[])"HTTP/1.1 200 OK\r\n")!!;
    assert(result == response_parser::ParseResult.MORE);

    // Feed headers
    result = parser.feed((char[])"Content-Length: 5\r\n")!!;
    assert(result == response_parser::ParseResult.MORE);

    // Feed end of headers
    result = parser.feed((char[])"\r\n")!!;
    assert(result == response_parser::ParseResult.MORE);

    // Feed body
    result = parser.feed((char[])"Hello")!!;
    assert(result == response_parser::ParseResult.COMPLETE);

    char[] body = parser.get_body();
    assert((String)body == "Hello");
}

// Status line split across chunks
fn void test_status_line_split() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    // Feed partial status line
    response_parser::ParseResult result = parser.feed((char[])"HTTP/1.1 ")!!;
    assert(result == response_parser::ParseResult.MORE);

    // Feed rest of status line
    result = parser.feed((char[])"200 OK\r\nContent-Length: 0\r\n\r\n")!!;
    assert(result == response_parser::ParseResult.COMPLETE);

    client_response::ClientResponse* resp = parser.get_response();
    assert(resp.status == 200);
}

// Response without reason phrase (optional per RFC 9112)
fn void test_no_reason_phrase() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    String response_data = "HTTP/1.1 200\r\nContent-Length: 0\r\n\r\n";
    response_parser::ParseResult result = parser.feed((char[])response_data)!!;

    assert(result == response_parser::ParseResult.COMPLETE);

    client_response::ClientResponse* resp = parser.get_response();
    assert(resp.status == 200);
    assert(resp.reason_phrase == "");
}

// 204 No Content (no body expected)
fn void test_204_no_content() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    String response_data = "HTTP/1.1 204 No Content\r\n\r\n";
    response_parser::ParseResult result = parser.feed((char[])response_data)!!;

    assert(result == response_parser::ParseResult.COMPLETE);

    client_response::ClientResponse* resp = parser.get_response();
    assert(resp.status == 204);

    char[] body = parser.get_body();
    assert(body.len == 0);
}

// 301 Redirect with Location header
fn void test_301_redirect() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    String response_data =
        "HTTP/1.1 301 Moved Permanently\r\n"
        "Location: https://example.com/new\r\n"
        "Content-Length: 0\r\n"
        "\r\n";

    response_parser::ParseResult result = parser.feed((char[])response_data)!!;
    assert(result == response_parser::ParseResult.COMPLETE);

    client_response::ClientResponse* resp = parser.get_response();
    assert(resp.status == 301);
    assert(resp.is_redirection());
    assert(resp.headers.get("Location")!! == "https://example.com/new");
}

// Chunked encoding response
fn void test_chunked_encoding() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    String response_data =
        "HTTP/1.1 200 OK\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "5\r\n"
        "Hello\r\n"
        "6\r\n"
        " World\r\n"
        "0\r\n"
        "\r\n";

    response_parser::ParseResult result = parser.feed((char[])response_data)!!;
    assert(result == response_parser::ParseResult.COMPLETE);

    char[] body = parser.get_body();
    assert((String)body == "Hello World");
}

// Chunked with trailer headers
fn void test_chunked_with_trailers() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    String response_data =
        "HTTP/1.1 200 OK\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "5\r\n"
        "Hello\r\n"
        "0\r\n"
        "X-Trailer: value\r\n"
        "\r\n";

    response_parser::ParseResult result = parser.feed((char[])response_data)!!;
    assert(result == response_parser::ParseResult.COMPLETE);

    client_response::ClientResponse* resp = parser.get_response();
    assert(resp.trailers.get("X-Trailer")!! == "value");
}

// HTTP/1.0 response
fn void test_http10_response() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    String response_data = "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK";
    response_parser::ParseResult result = parser.feed((char[])response_data)!!;

    assert(result == response_parser::ParseResult.COMPLETE);

    client_response::ClientResponse* resp = parser.get_response();
    assert(resp.version.is_http10());
}

// Invalid status line - missing version
fn void test_invalid_status_line_no_version() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    String response_data = "200 OK\r\n\r\n";
    if (catch excuse = parser.feed((char[])response_data)) {
        assert(excuse == response_parser::INVALID_STATUS_LINE);
    } else {
        assert(false, "Should have returned INVALID_STATUS_LINE fault");
    }
}

// Invalid status line - non-numeric status
fn void test_invalid_status_code() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    String response_data = "HTTP/1.1 ABC OK\r\n\r\n";
    if (catch excuse = parser.feed((char[])response_data)) {
        assert(excuse == response_parser::INVALID_STATUS_LINE);
    } else {
        assert(false, "Should have returned INVALID_STATUS_LINE fault");
    }
}

// Invalid status line - status code out of range
fn void test_status_code_out_of_range() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    String response_data = "HTTP/1.1 999 Unknown\r\n\r\n";
    if (catch excuse = parser.feed((char[])response_data)) {
        assert(excuse == response_parser::INVALID_STATUS_LINE);
    } else {
        assert(false, "Should have returned INVALID_STATUS_LINE fault");
    }
}

// Security: Bare LF rejection
fn void test_bare_lf_rejection() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    // Status line with bare LF (no CR)
    String response_data = "HTTP/1.1 200 OK\n\n";
    if (catch excuse = parser.feed((char[])response_data)) {
        assert(excuse == response_parser::PROTOCOL_VIOLATION);
    } else {
        assert(false, "Should have returned PROTOCOL_VIOLATION fault");
    }
}

// Security: Null byte rejection
fn void test_null_byte_rejection() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    // Status line with null byte
    char[] response_data = "HTTP/1.1 200\0 OK\r\n\r\n".ptr[0:21];
    if (catch excuse = parser.feed(response_data)) {
        assert(excuse == response_parser::PROTOCOL_VIOLATION);
    } else {
        assert(false, "Should have returned PROTOCOL_VIOLATION fault");
    }
}

// Parser reset for connection reuse
fn void test_parser_reset() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    // First response
    String response1 = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nFirst";
    response_parser::ParseResult result = parser.feed((char[])response1)!!;
    assert(result == response_parser::ParseResult.COMPLETE);

    client_response::ClientResponse* resp1 = parser.get_response();
    assert(resp1.status == 200);

    // Reset parser
    parser.reset();

    // Second response
    String response2 = "HTTP/1.1 404 Not Found\r\nContent-Length: 6\r\n\r\nSecond";
    result = parser.feed((char[])response2)!!;
    assert(result == response_parser::ParseResult.COMPLETE);

    client_response::ClientResponse* resp2 = parser.get_response();
    assert(resp2.status == 404);
}

// Large headers close to limit
fn void test_large_headers() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    // Create a large but valid header (under 8KB limit)
    DString builder = dstring::temp();
    builder.append("HTTP/1.1 200 OK\r\n");
    builder.append("X-Large: ");

    // Add ~7KB of header value
    for (int i = 0; i < 700; i++) {
        builder.append("1234567890");
    }
    builder.append("\r\nContent-Length: 0\r\n\r\n");

    String response_data = builder.str_view();
    response_parser::ParseResult result = parser.feed((char[])response_data)!!;
    assert(result == response_parser::ParseResult.COMPLETE);
}

// Header too large
fn void test_header_too_large() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    // Create a header that exceeds 8KB limit
    DString builder = dstring::temp();
    builder.append("HTTP/1.1 200 OK\r\n");
    builder.append("X-Too-Large: ");

    // Add >8KB of header value
    for (int i = 0; i < 900; i++) {
        builder.append("1234567890");
    }
    builder.append("\r\n\r\n");

    String response_data = builder.str_view();
    if (catch excuse = parser.feed((char[])response_data)) {
        assert(excuse == response_parser::HEADER_TOO_LARGE);
    } else {
        assert(false, "Should have returned HEADER_TOO_LARGE fault");
    }
}

// Empty body with Content-Length: 0
fn void test_empty_body() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    String response_data = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
    response_parser::ParseResult result = parser.feed((char[])response_data)!!;

    assert(result == response_parser::ParseResult.COMPLETE);

    char[] body = parser.get_body();
    assert(body.len == 0);
}

// Status helper methods
fn void test_status_helper_methods() @test {
    response_parser::ResponseParser parser;
    parser.init();
    defer parser.free();

    // Test 1xx informational
    String response_data = "HTTP/1.1 100 Continue\r\n\r\n";
    parser.feed((char[])response_data)!!;
    assert(parser.get_response().is_informational());

    parser.reset();

    // Test 2xx success
    response_data = "HTTP/1.1 200 OK\r\n\r\n";
    parser.feed((char[])response_data)!!;
    assert(parser.get_response().is_success());

    parser.reset();

    // Test 3xx redirect
    response_data = "HTTP/1.1 301 Moved\r\n\r\n";
    parser.feed((char[])response_data)!!;
    assert(parser.get_response().is_redirection());

    parser.reset();

    // Test 4xx client error
    response_data = "HTTP/1.1 400 Bad Request\r\n\r\n";
    parser.feed((char[])response_data)!!;
    assert(parser.get_response().is_client_error());

    parser.reset();

    // Test 5xx server error
    response_data = "HTTP/1.1 503 Unavailable\r\n\r\n";
    parser.feed((char[])response_data)!!;
    assert(parser.get_response().is_server_error());
}
