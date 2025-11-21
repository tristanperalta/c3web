/**
 * WebSocket Handshake Tests
 *
 * RFC 6455 §4 - Opening Handshake
 * Tests upgrade request validation and Sec-WebSocket-Accept generation
 */
module c3web::test::websocket::handshake_test;

import c3web::websocket::handshake;
import c3web::http1::parser;
import c3web::common::headers;
import std::io;

/**
 * Test 1: Generate Sec-WebSocket-Accept from RFC 6455 example
 *
 * RFC 6455 §4.2.2 provides a known-good test case:
 * Key: "dGhlIHNhbXBsZSBub25jZQ=="
 * Expected Accept: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
 */
fn void test_websocket_accept_generation() @test
{
    String key = "dGhlIHNhbXBsZSBub25jZQ==";
    String accept = handshake::generate_websocket_accept(key)!!;
    defer mem::free(accept.ptr);

    assert(accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
           "Accept header must match RFC 6455 example");
}

/**
 * Test 2: Valid upgrade request with all required headers
 */
fn void test_valid_upgrade_request() @test
{
    parser::Parser p;
    p.init(mem);
    defer p.free();

    String request_data =
        "GET /chat HTTP/1.1\r\n"
        "Host: server.example.com\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n";

    p.feed((char[])request_data)!!;
    parser::Request* req = p.get_request();

    assert(handshake::validate_upgrade_request(req),
           "Valid upgrade request should be accepted");
}

/**
 * Test 3: Missing Upgrade header
 */
fn void test_missing_upgrade_header() @test
{
    parser::Parser p;
    p.init(mem);
    defer p.free();

    String request_data =
        "GET /chat HTTP/1.1\r\n"
        "Host: server.example.com\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n";

    p.feed((char[])request_data)!!;
    parser::Request* req = p.get_request();

    assert(!handshake::validate_upgrade_request(req),
           "Missing Upgrade header should be rejected");
}

/**
 * Test 4: Missing Connection header
 */
fn void test_missing_connection_header() @test
{
    parser::Parser p;
    p.init(mem);
    defer p.free();

    String request_data =
        "GET /chat HTTP/1.1\r\n"
        "Host: server.example.com\r\n"
        "Upgrade: websocket\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n";

    p.feed((char[])request_data)!!;
    parser::Request* req = p.get_request();

    assert(!handshake::validate_upgrade_request(req),
           "Missing Connection header should be rejected");
}

/**
 * Test 5: Missing Sec-WebSocket-Key
 */
fn void test_missing_websocket_key() @test
{
    parser::Parser p;
    p.init(mem);
    defer p.free();

    String request_data =
        "GET /chat HTTP/1.1\r\n"
        "Host: server.example.com\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n";

    p.feed((char[])request_data)!!;
    parser::Request* req = p.get_request();

    assert(!handshake::validate_upgrade_request(req),
           "Missing Sec-WebSocket-Key should be rejected");
}

/**
 * Test 6: Invalid WebSocket version (not 13)
 */
fn void test_invalid_websocket_version() @test
{
    parser::Parser p;
    p.init(mem);
    defer p.free();

    String request_data =
        "GET /chat HTTP/1.1\r\n"
        "Host: server.example.com\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Version: 8\r\n"
        "\r\n";

    p.feed((char[])request_data)!!;
    parser::Request* req = p.get_request();

    assert(!handshake::validate_upgrade_request(req),
           "WebSocket version != 13 should be rejected");
}

/**
 * Test 7: Invalid HTTP method (must be GET)
 */
fn void test_invalid_http_method() @test
{
    parser::Parser p;
    p.init(mem);
    defer p.free();

    String request_data =
        "POST /chat HTTP/1.1\r\n"
        "Host: server.example.com\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n";

    p.feed((char[])request_data)!!;
    parser::Request* req = p.get_request();

    assert(!handshake::validate_upgrade_request(req),
           "POST method should be rejected (only GET allowed)");
}

/**
 * Test 8: Case insensitive header values
 * RFC 6455 requires case-insensitive matching for "websocket" and "upgrade"
 */
fn void test_case_insensitive_headers() @test
{
    parser::Parser p;
    p.init(mem);
    defer p.free();

    String request_data =
        "GET /chat HTTP/1.1\r\n"
        "Host: server.example.com\r\n"
        "Upgrade: WEBSOCKET\r\n"
        "Connection: UPGRADE\r\n"
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n";

    p.feed((char[])request_data)!!;
    parser::Request* req = p.get_request();

    assert(handshake::validate_upgrade_request(req),
           "Case-insensitive header values should be accepted");
}

/**
 * Test 9: Invalid base64 in Sec-WebSocket-Key
 */
fn void test_websocket_key_invalid_base64() @test
{
    parser::Parser p;
    p.init(mem);
    defer p.free();

    String request_data =
        "GET /chat HTTP/1.1\r\n"
        "Host: server.example.com\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: invalid@#$base64\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n";

    p.feed((char[])request_data)!!;
    parser::Request* req = p.get_request();

    assert(!handshake::validate_upgrade_request(req),
           "Invalid base64 in Sec-WebSocket-Key should be rejected");
}

/**
 * Test 10: Sec-WebSocket-Key wrong length (must decode to 16 bytes)
 */
fn void test_websocket_key_wrong_length() @test
{
    parser::Parser p;
    p.init(mem);
    defer p.free();

    // "SGVsbG8=" decodes to "Hello" (5 bytes, not 16)
    String request_data =
        "GET /chat HTTP/1.1\r\n"
        "Host: server.example.com\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: SGVsbG8=\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n";

    p.feed((char[])request_data)!!;
    parser::Request* req = p.get_request();

    assert(!handshake::validate_upgrade_request(req),
           "Sec-WebSocket-Key not 16 bytes should be rejected");
}
