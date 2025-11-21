/**
 * WebSocket Control Frame Tests
 *
 * RFC 6455 §5.5 - Control Frames
 * Tests CLOSE, PING, and PONG frame handling
 */
module c3web::test::websocket::control_test;

import c3web::websocket::frame;
import c3web::websocket::control;
import std::io;

/**
 * Test 1: Create CLOSE frame with status code 1000 (Normal Closure)
 *
 * RFC 6455 §5.5.1: Close frame may contain a status code (first 2 bytes)
 * and an optional close reason (UTF-8 text after status code)
 */
fn void test_create_close_frame_normal() @test
{
    char[] frame_data = control::create_close_frame(control::CLOSE_NORMAL, "Goodbye")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;

    assert(f.fin, "CLOSE frame must have FIN=1");
    assert(f.opcode == frame::Opcode.CLOSE, "Opcode should be CLOSE");
    assert(f.payload_len >= 2, "CLOSE frame should have at least status code");

    // Extract status code (network byte order)
    ushort status = ((ushort)f.payload[0] << 8) | (ushort)f.payload[1];
    assert(status == 1000, "Status code should be 1000");

    // Check reason (if present)
    if (f.payload_len > 2)
    {
        String reason = (String)f.payload[2:f.payload_len - 2];
        assert(reason == "Goodbye", "Close reason should be 'Goodbye'");
    }
}

/**
 * Test 2: Create CLOSE frame without reason
 */
fn void test_create_close_frame_no_reason() @test
{
    char[] frame_data = control::create_close_frame(control::CLOSE_NORMAL, "")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;

    assert(f.opcode == frame::Opcode.CLOSE, "Opcode should be CLOSE");
    assert(f.payload_len == 2, "Should only have status code, no reason");

    ushort status = ((ushort)f.payload[0] << 8) | (ushort)f.payload[1];
    assert(status == 1000, "Status code should be 1000");
}

/**
 * Test 3: Parse CLOSE frame and extract status code
 */
fn void test_parse_close_frame() @test
{
    // Create CLOSE frame manually: opcode=0x8, status=1001 (Going Away)
    char[] frame_data = {
        0x88,              // FIN=1, opcode=0x8 (CLOSE)
        0x02,              // MASK=0, len=2
        0x03, 0xE9         // Status code 1001 (network byte order)
    };

    frame::Frame f = frame::parse(frame_data)!!;

    ushort status = control::parse_close_status(f)!!;
    assert(status == 1001, "Status code should be 1001 (Going Away)");
}

/**
 * Test 4: Validate close status codes
 *
 * RFC 6455 §7.4: Valid status codes are 1000-1011, 3000-3999, 4000-4999
 */
fn void test_validate_close_status_codes() @test
{
    // Valid codes
    assert(control::is_valid_close_status(1000), "1000 (Normal) should be valid");
    assert(control::is_valid_close_status(1001), "1001 (Going Away) should be valid");
    assert(control::is_valid_close_status(1002), "1002 (Protocol Error) should be valid");
    assert(control::is_valid_close_status(1003), "1003 (Unsupported Data) should be valid");
    assert(control::is_valid_close_status(1007), "1007 (Invalid Payload) should be valid");
    assert(control::is_valid_close_status(1008), "1008 (Policy Violation) should be valid");
    assert(control::is_valid_close_status(1009), "1009 (Message Too Big) should be valid");
    assert(control::is_valid_close_status(1010), "1010 (Mandatory Extension) should be valid");
    assert(control::is_valid_close_status(1011), "1011 (Internal Error) should be valid");

    // Reserved codes (invalid)
    assert(!control::is_valid_close_status(1004), "1004 should be reserved");
    assert(!control::is_valid_close_status(1005), "1005 should be reserved");
    assert(!control::is_valid_close_status(1006), "1006 should be reserved");
    assert(!control::is_valid_close_status(1015), "1015 should be reserved");

    // Invalid range
    assert(!control::is_valid_close_status(999), "999 should be invalid");
    assert(!control::is_valid_close_status(1016), "1016 should be invalid (out of standard range)");
}

/**
 * Test 5: Create PING frame with application data
 *
 * RFC 6455 §5.5.2: Ping frame may contain application data
 */
fn void test_create_ping_frame() @test
{
    char[] frame_data = control::create_ping_frame((char[])"heartbeat")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;

    assert(f.fin, "PING frame must have FIN=1");
    assert(f.opcode == frame::Opcode.PING, "Opcode should be PING");
    assert(f.payload_len == 9, "Payload length should be 9");
    assert((String)f.payload == "heartbeat", "Payload should be 'heartbeat'");
}

/**
 * Test 6: Create PONG frame (response to PING)
 *
 * RFC 6455 §5.5.3: Pong frame must echo the PING's application data
 */
fn void test_create_pong_frame() @test
{
    // First, create a PING frame
    char[] ping_data = control::create_ping_frame((char[])"test123")!!;
    defer mem::free(ping_data.ptr);
    frame::Frame ping = frame::parse(ping_data)!!;

    // Create PONG response (echo payload)
    char[] pong_data = control::create_pong_frame(ping.payload)!!;
    defer mem::free(pong_data.ptr);
    frame::Frame pong = frame::parse(pong_data)!!;

    assert(pong.fin, "PONG frame must have FIN=1");
    assert(pong.opcode == frame::Opcode.PONG, "Opcode should be PONG");
    assert(pong.payload_len == ping.payload_len, "PONG payload should match PING");
    assert((String)pong.payload == "test123", "PONG should echo PING payload");
}

/**
 * Test 7: Reject control frame with payload > 125 bytes
 *
 * RFC 6455 §5.5: All control frames MUST have payload length ≤ 125 bytes
 */
fn void test_reject_large_control_frame_payload() @test
{
    // Try to create PING with 126 bytes (too large)
    char[126] large_payload;
    foreach (&c : large_payload) *c = 'A';

    if (catch control::create_ping_frame(large_payload[..]))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject PING frame with payload > 125 bytes");
}

/**
 * Test 8: Create empty PING frame
 *
 * RFC 6455 §5.5.2: PING frame may have empty payload
 */
fn void test_create_empty_ping() @test
{
    char[] frame_data = control::create_ping_frame({})!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;

    assert(f.opcode == frame::Opcode.PING, "Opcode should be PING");
    assert(f.payload_len == 0, "Payload should be empty");
}

/**
 * Test 9: Parse CLOSE frame with invalid UTF-8 reason
 *
 * RFC 6455 §5.5.1: Close reason MUST be valid UTF-8
 */
fn void test_reject_close_frame_invalid_utf8_reason() @test
{
    // CLOSE frame with status + invalid UTF-8 reason
    char[] frame_data = {
        0x88,              // FIN=1, opcode=0x8 (CLOSE)
        0x05,              // MASK=0, len=5
        0x03, 0xE8,        // Status code 1000
        0xFF, 0xFE, 0xFD   // Invalid UTF-8 bytes
    };

    frame::Frame f = frame::parse(frame_data)!!;

    // Validate the close reason UTF-8
    if (catch control::validate_close_reason(f))
    {
        // Expected to fail due to invalid UTF-8
        return;
    }

    assert(false, "Should reject CLOSE frame with invalid UTF-8 reason");
}

/**
 * Test 10: Create CLOSE frame with various status codes
 */
fn void test_create_close_with_different_status_codes() @test
{
    // Test multiple status codes
    ushort[] status_codes = {
        control::CLOSE_NORMAL,
        control::CLOSE_GOING_AWAY,
        control::CLOSE_PROTOCOL_ERROR,
        control::CLOSE_UNSUPPORTED_DATA,
        control::CLOSE_INVALID_PAYLOAD,
        control::CLOSE_POLICY_VIOLATION,
        control::CLOSE_MESSAGE_TOO_BIG,
        control::CLOSE_MANDATORY_EXTENSION,
        control::CLOSE_INTERNAL_ERROR
    };

    foreach (code : status_codes)
    {
        char[] frame_data = control::create_close_frame(code, "test")!!;
        defer mem::free(frame_data.ptr);
        frame::Frame f = frame::parse(frame_data)!!;

        assert(f.opcode == frame::Opcode.CLOSE, "Should be CLOSE frame");

        ushort parsed_status = control::parse_close_status(f)!!;
        assert(parsed_status == code, "Status code should match");
    }
}
