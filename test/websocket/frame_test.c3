/**
 * WebSocket Frame Parsing Tests
 *
 * RFC 6455 §5 - Data Framing
 * Tests binary frame format parsing and validation
 */
module c3web::test::websocket::frame_test;

import c3web::websocket::frame;
import std::io;

/**
 * Test 1: Parse basic text frame (1-byte payload, unmasked)
 *
 * Frame structure:
 * - FIN=1, opcode=0x1 (text)
 * - MASK=0, payload_len=5
 * - Payload: "Hello"
 */
fn void test_parse_text_frame_unmasked() @test
{
    char[] data = {
        0x81,              // FIN=1, RSV=0, opcode=0x1 (text)
        0x05,              // MASK=0, len=5
        'H', 'e', 'l', 'l', 'o'
    };

    frame::Frame f = frame::parse(data)!!;

    assert(f.fin, "FIN should be set");
    assert(f.opcode == frame::Opcode.TEXT, "Opcode should be TEXT");
    assert(!f.masked, "Frame should not be masked");
    assert(f.payload_len == 5, "Payload length should be 5");
    assert((String)f.payload == "Hello", "Payload should be 'Hello'");
}

/**
 * Test 2: Parse binary frame with masking (client-to-server)
 *
 * RFC 6455 §5.1: All frames from client MUST be masked
 * Frame with mask key 0x37, 0xFA, 0x21, 0x3D
 */
fn void test_parse_binary_frame_masked() @test
{
    // Original payload: [0x01, 0x02, 0x03]
    // Mask: [0x37, 0xFA, 0x21, 0x3D]
    // Masked: [0x36, 0xF8, 0x22]
    char[] data = {
        0x82,                          // FIN=1, opcode=0x2 (binary)
        0x83,                          // MASK=1, len=3
        0x37, 0xFA, 0x21, 0x3D,       // Masking key
        0x36, 0xF8, 0x22              // Masked payload
    };

    frame::Frame f = frame::parse(data)!!;

    assert(f.fin, "FIN should be set");
    assert(f.opcode == frame::Opcode.BINARY, "Opcode should be BINARY");
    assert(f.masked, "Frame should be masked");
    assert(f.payload_len == 3, "Payload length should be 3");

    // Check unmasked payload
    assert(f.payload[0] == 0x01, "Byte 0 should be 0x01");
    assert(f.payload[1] == 0x02, "Byte 1 should be 0x02");
    assert(f.payload[2] == 0x03, "Byte 2 should be 0x03");
}

/**
 * Test 3: Parse frame with 16-bit extended payload length (126-65535 bytes)
 *
 * When payload_len == 126, next 2 bytes are 16-bit length (network byte order)
 */
fn void test_parse_extended_payload_16bit() @test
{
    char[] data = {
        0x81,              // FIN=1, opcode=0x1 (text)
        0x7E,              // MASK=0, len=126 (extended 16-bit)
        0x00, 0x80,        // Length = 128 (network byte order)
        // ... 128 bytes of payload would follow
    };

    // For this test, just check header parsing
    frame::Frame f = frame::parse_header(data)!!;

    assert(f.fin, "FIN should be set");
    assert(f.payload_len == 128, "Payload length should be 128");
    assert(!f.masked, "Frame should not be masked");
}

/**
 * Test 4: Parse frame with 64-bit extended payload length (>65535 bytes)
 *
 * When payload_len == 127, next 8 bytes are 64-bit length (network byte order)
 */
fn void test_parse_extended_payload_64bit() @test
{
    char[] data = {
        0x82,              // FIN=1, opcode=0x2 (binary)
        0xFF,              // MASK=1, len=127 (extended 64-bit)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,  // Length = 65536
        0x12, 0x34, 0x56, 0x78  // Masking key
        // ... 65536 bytes of payload would follow
    };

    frame::Frame f = frame::parse_header(data)!!;

    assert(f.fin, "FIN should be set");
    assert(f.payload_len == 65536, "Payload length should be 65536");
    assert(f.masked, "Frame should be masked");
}

/**
 * Test 5: Parse close frame (control frame)
 *
 * RFC 6455 §5.5.1: Close frame with status code 1000 (normal closure)
 */
fn void test_parse_close_frame() @test
{
    char[] data = {
        0x88,              // FIN=1, opcode=0x8 (close)
        0x02,              // MASK=0, len=2
        0x03, 0xE8         // Status code 1000 (network byte order)
    };

    frame::Frame f = frame::parse(data)!!;

    assert(f.fin, "FIN should be set");
    assert(f.opcode == frame::Opcode.CLOSE, "Opcode should be CLOSE");
    assert(f.payload_len == 2, "Payload length should be 2");

    // Extract status code
    ushort status = ((ushort)f.payload[0] << 8) | (ushort)f.payload[1];
    assert(status == 1000, "Status code should be 1000");
}

/**
 * Test 6: Parse ping frame (control frame)
 *
 * RFC 6455 §5.5.2: Ping with application data
 */
fn void test_parse_ping_frame() @test
{
    char[] data = {
        0x89,              // FIN=1, opcode=0x9 (ping)
        0x04,              // MASK=0, len=4
        't', 'e', 's', 't'
    };

    frame::Frame f = frame::parse(data)!!;

    assert(f.fin, "FIN should be set");
    assert(f.opcode == frame::Opcode.PING, "Opcode should be PING");
    assert(f.payload_len == 4, "Payload length should be 4");
    assert((String)f.payload == "test", "Payload should be 'test'");
}

/**
 * Test 7: Parse pong frame (control frame)
 *
 * RFC 6455 §5.5.3: Pong responding to ping
 */
fn void test_parse_pong_frame() @test
{
    char[] data = {
        0x8A,              // FIN=1, opcode=0xA (pong)
        0x04,              // MASK=0, len=4
        't', 'e', 's', 't'
    };

    frame::Frame f = frame::parse(data)!!;

    assert(f.fin, "FIN should be set");
    assert(f.opcode == frame::Opcode.PONG, "Opcode should be PONG");
    assert(f.payload_len == 4, "Payload length should be 4");
}

/**
 * Test 8: Parse fragmented frame (FIN=0, continuation)
 *
 * RFC 6455 §5.4: First fragment with FIN=0
 */
fn void test_parse_fragmented_frame() @test
{
    char[] data = {
        0x01,              // FIN=0, opcode=0x1 (text, first fragment)
        0x03,              // MASK=0, len=3
        'H', 'e', 'l'
    };

    frame::Frame f = frame::parse(data)!!;

    assert(!f.fin, "FIN should NOT be set (fragmented)");
    assert(f.opcode == frame::Opcode.TEXT, "Opcode should be TEXT");
    assert(f.payload_len == 3, "Payload length should be 3");
}

/**
 * Test 9: Parse continuation frame
 *
 * RFC 6455 §5.4: Continuation frame (opcode=0x0)
 */
fn void test_parse_continuation_frame() @test
{
    char[] data = {
        0x80,              // FIN=1, opcode=0x0 (continuation, final fragment)
        0x02,              // MASK=0, len=2
        'l', 'o'
    };

    frame::Frame f = frame::parse(data)!!;

    assert(f.fin, "FIN should be set (final fragment)");
    assert(f.opcode == frame::Opcode.CONTINUATION, "Opcode should be CONTINUATION");
    assert(f.payload_len == 2, "Payload length should be 2");
}

/**
 * Test 10: Reject control frame with FIN=0
 *
 * RFC 6455 §5.5: Control frames MUST NOT be fragmented
 */
fn void test_reject_fragmented_control_frame() @test
{
    char[] data = {
        0x08,              // FIN=0, opcode=0x8 (close) - INVALID!
        0x00               // MASK=0, len=0
    };

    if (catch frame::parse(data))
    {
        // Expected to fail
        return;
    }

    assert(false, "Fragmented control frame should be rejected");
}

/**
 * Test 11: Reject control frame with payload > 125 bytes
 *
 * RFC 6455 §5.5: Control frame payload MUST be <= 125 bytes
 */
fn void test_reject_control_frame_payload_too_large() @test
{
    char[] data = {
        0x88,              // FIN=1, opcode=0x8 (close)
        0x7E,              // MASK=0, len=126 (extended) - INVALID for control!
        0x00, 0x80         // Length = 128
    };

    if (catch frame::parse_header(data))
    {
        // Expected to fail
        return;
    }

    assert(false, "Control frame with payload > 125 bytes should be rejected");
}

/**
 * Test 12: Reject reserved opcode
 *
 * RFC 6455 §5.2: Reserved opcodes (0x3-0x7, 0xB-0xF) MUST fail
 */
fn void test_reject_reserved_opcode() @test
{
    char[] data = {
        0x83,              // FIN=1, opcode=0x3 (reserved)
        0x00               // MASK=0, len=0
    };

    if (catch frame::parse(data))
    {
        // Expected to fail
        return;
    }

    assert(false, "Reserved opcode should be rejected");
}
