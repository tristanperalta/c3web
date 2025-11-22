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

// ============================================================================
// Autobahn Category 7.3.x - Close Frame Payload Structure Tests
// ============================================================================

/**
 * Test 11: Parse CLOSE frame with empty payload (Autobahn 7.3.1)
 *
 * RFC 6455 §5.5.1: CLOSE frame MAY have empty payload (no status code).
 * Should return INVALID_FRAME_FORMAT fault (valid empty close, no status).
 */
fn void test_parse_close_status_empty_payload() @test
{
    // CLOSE frame with no payload (valid per RFC)
    char[] frame_data = {
        0x88,  // FIN=1, opcode=0x8 (CLOSE)
        0x00   // MASK=0, len=0
    };

    frame::Frame f = frame::parse(frame_data)!!;

    assert(f.opcode == frame::Opcode.CLOSE, "Opcode should be CLOSE");
    assert(f.payload_len == 0, "Payload should be empty");

    // parse_close_status should return INVALID_FRAME_FORMAT for empty payload
    if (catch err = control::parse_close_status(f))
    {
        assert(err == control::INVALID_FRAME_FORMAT, "Should return INVALID_FRAME_FORMAT for empty close");
        return;
    }

    assert(false, "Should fail to parse status from empty close frame");
}

/**
 * Test 12: Parse CLOSE frame with 1-byte payload (Autobahn 7.3.2)
 *
 * RFC 6455 §7.1.6: CLOSE frame body MUST be 0 bytes OR 2+ bytes.
 * A 1-byte payload is a protocol error (INVALID_CLOSE_PAYLOAD).
 */
fn void test_parse_close_status_one_byte_payload() @test
{
    // CLOSE frame with 1 byte payload (INVALID per RFC)
    char[] frame_data = {
        0x88,  // FIN=1, opcode=0x8 (CLOSE)
        0x01,  // MASK=0, len=1
        0x00   // Single byte (invalid)
    };

    frame::Frame f = frame::parse(frame_data)!!;

    assert(f.opcode == frame::Opcode.CLOSE, "Opcode should be CLOSE");
    assert(f.payload_len == 1, "Payload should be 1 byte");

    // parse_close_status should return INVALID_CLOSE_PAYLOAD
    if (catch err = control::parse_close_status(f))
    {
        assert(err == control::INVALID_CLOSE_PAYLOAD, "Should return INVALID_CLOSE_PAYLOAD for 1-byte payload");
        return;
    }

    assert(false, "Should fail to parse status from 1-byte close frame");
}

/**
 * Test 13: Parse CLOSE frame with status code only (Autobahn 7.3.3)
 *
 * RFC 6455 §5.5.1: CLOSE frame with exactly 2 bytes = status code, no reason.
 */
fn void test_parse_close_status_code_only() @test
{
    // CLOSE frame with status code 1000, no reason
    char[] frame_data = {
        0x88,        // FIN=1, opcode=0x8 (CLOSE)
        0x02,        // MASK=0, len=2
        0x03, 0xE8   // Status code 1000 (network byte order)
    };

    frame::Frame f = frame::parse(frame_data)!!;

    assert(f.opcode == frame::Opcode.CLOSE, "Opcode should be CLOSE");
    assert(f.payload_len == 2, "Payload should be 2 bytes");

    ushort status = control::parse_close_status(f)!!;
    assert(status == 1000, "Status code should be 1000");
}

/**
 * Test 14: Parse CLOSE frame with status code and reason (Autobahn 7.3.4)
 *
 * RFC 6455 §5.5.1: CLOSE frame with status + UTF-8 reason.
 */
fn void test_parse_close_status_code_with_reason() @test
{
    // CLOSE frame with status 1000 + reason "bye"
    char[] frame_data = {
        0x88,              // FIN=1, opcode=0x8 (CLOSE)
        0x05,              // MASK=0, len=5
        0x03, 0xE8,        // Status code 1000
        'b', 'y', 'e'      // Reason "bye"
    };

    frame::Frame f = frame::parse(frame_data)!!;

    assert(f.opcode == frame::Opcode.CLOSE, "Opcode should be CLOSE");
    assert(f.payload_len == 5, "Payload should be 5 bytes");

    ushort status = control::parse_close_status(f)!!;
    assert(status == 1000, "Status code should be 1000");

    // Validate reason is valid UTF-8
    control::validate_close_reason(f)!!;

    // Check reason content
    String reason = (String)f.payload[2:3];
    assert(reason == "bye", "Reason should be 'bye'");
}

/**
 * Test 15: Create CLOSE frame with maximum reason (Autobahn 7.3.5)
 *
 * RFC 6455 §5.5: Control frames MUST have payload ≤ 125 bytes.
 * Max reason = 125 - 2 (status code) = 123 bytes.
 */
fn void test_create_close_frame_max_reason() @test
{
    // Create 123-byte reason (max allowed)
    char[123] max_reason;
    foreach (&c : max_reason) *c = 'A';

    char[] frame_data = control::create_close_frame(control::CLOSE_NORMAL, (String)max_reason[..])!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;

    assert(f.opcode == frame::Opcode.CLOSE, "Opcode should be CLOSE");
    assert(f.payload_len == 125, "Payload should be 125 bytes (2 + 123)");

    ushort status = control::parse_close_status(f)!!;
    assert(status == 1000, "Status code should be 1000");
}

/**
 * Test 16: Reject CLOSE frame with reason too long (Autobahn 7.3.6)
 *
 * RFC 6455 §5.5: Control frame payload > 125 bytes is protocol error.
 */
fn void test_create_close_frame_reason_too_long() @test
{
    // Create 124-byte reason (exceeds max by 1)
    char[124] long_reason;
    foreach (&c : long_reason) *c = 'A';

    if (catch control::create_close_frame(control::CLOSE_NORMAL, (String)long_reason[..]))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject CLOSE frame with payload > 125 bytes");
}

/**
 * Test 17: Create empty CLOSE frame
 *
 * RFC 6455 §5.5.1: CLOSE frame MAY have no payload.
 */
fn void test_create_empty_close_frame() @test
{
    char[] frame_data = control::create_empty_close_frame();
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;

    assert(f.fin, "CLOSE frame must have FIN=1");
    assert(f.opcode == frame::Opcode.CLOSE, "Opcode should be CLOSE");
    assert(f.payload_len == 0, "Payload should be empty");
}

// ============================================================================
// Autobahn Category 7.7.x - Valid Close Code Tests
// ============================================================================

/**
 * Test 18: Valid close code 1000 (Normal Closure) (Autobahn 7.7.1)
 */
fn void test_valid_close_code_1000() @test
{
    assert(control::is_valid_close_status(1000), "1000 should be valid");

    char[] frame_data = control::create_close_frame(1000, "")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;
    ushort status = control::parse_close_status(f)!!;
    assert(status == 1000, "Should parse 1000 correctly");
}

/**
 * Test 19: Valid close code 1001 (Going Away) (Autobahn 7.7.2)
 */
fn void test_valid_close_code_1001() @test
{
    assert(control::is_valid_close_status(1001), "1001 should be valid");

    char[] frame_data = control::create_close_frame(1001, "")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;
    ushort status = control::parse_close_status(f)!!;
    assert(status == 1001, "Should parse 1001 correctly");
}

/**
 * Test 20: Valid close code 1002 (Protocol Error) (Autobahn 7.7.3)
 */
fn void test_valid_close_code_1002() @test
{
    assert(control::is_valid_close_status(1002), "1002 should be valid");

    char[] frame_data = control::create_close_frame(1002, "")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;
    ushort status = control::parse_close_status(f)!!;
    assert(status == 1002, "Should parse 1002 correctly");
}

/**
 * Test 21: Valid close code 1003 (Unsupported Data) (Autobahn 7.7.4)
 */
fn void test_valid_close_code_1003() @test
{
    assert(control::is_valid_close_status(1003), "1003 should be valid");

    char[] frame_data = control::create_close_frame(1003, "")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;
    ushort status = control::parse_close_status(f)!!;
    assert(status == 1003, "Should parse 1003 correctly");
}

/**
 * Test 22: Valid close code 1007 (Invalid Payload Data) (Autobahn 7.7.5)
 */
fn void test_valid_close_code_1007() @test
{
    assert(control::is_valid_close_status(1007), "1007 should be valid");

    char[] frame_data = control::create_close_frame(1007, "")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;
    ushort status = control::parse_close_status(f)!!;
    assert(status == 1007, "Should parse 1007 correctly");
}

/**
 * Test 23: Valid close code 1008 (Policy Violation) (Autobahn 7.7.6)
 */
fn void test_valid_close_code_1008() @test
{
    assert(control::is_valid_close_status(1008), "1008 should be valid");

    char[] frame_data = control::create_close_frame(1008, "")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;
    ushort status = control::parse_close_status(f)!!;
    assert(status == 1008, "Should parse 1008 correctly");
}

/**
 * Test 24: Valid close code 1009 (Message Too Big) (Autobahn 7.7.7)
 */
fn void test_valid_close_code_1009() @test
{
    assert(control::is_valid_close_status(1009), "1009 should be valid");

    char[] frame_data = control::create_close_frame(1009, "")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;
    ushort status = control::parse_close_status(f)!!;
    assert(status == 1009, "Should parse 1009 correctly");
}

/**
 * Test 25: Valid close code 1010 (Mandatory Extension) (Autobahn 7.7.8)
 */
fn void test_valid_close_code_1010() @test
{
    assert(control::is_valid_close_status(1010), "1010 should be valid");

    char[] frame_data = control::create_close_frame(1010, "")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;
    ushort status = control::parse_close_status(f)!!;
    assert(status == 1010, "Should parse 1010 correctly");
}

/**
 * Test 26: Valid close code 1011 (Internal Error) (Autobahn 7.7.9)
 */
fn void test_valid_close_code_1011() @test
{
    assert(control::is_valid_close_status(1011), "1011 should be valid");

    char[] frame_data = control::create_close_frame(1011, "")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;
    ushort status = control::parse_close_status(f)!!;
    assert(status == 1011, "Should parse 1011 correctly");
}

/**
 * Test 27: Valid close code 3000 (Application-specific range start) (Autobahn 7.7.10)
 */
fn void test_valid_close_code_3000() @test
{
    assert(control::is_valid_close_status(3000), "3000 should be valid");

    char[] frame_data = control::create_close_frame(3000, "")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;
    ushort status = control::parse_close_status(f)!!;
    assert(status == 3000, "Should parse 3000 correctly");
}

/**
 * Test 28: Valid close code 3999 (Application-specific range end) (Autobahn 7.7.11)
 */
fn void test_valid_close_code_3999() @test
{
    assert(control::is_valid_close_status(3999), "3999 should be valid");

    char[] frame_data = control::create_close_frame(3999, "")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;
    ushort status = control::parse_close_status(f)!!;
    assert(status == 3999, "Should parse 3999 correctly");
}

/**
 * Test 29: Valid close code 4000 (Private use range start) (Autobahn 7.7.12)
 */
fn void test_valid_close_code_4000() @test
{
    assert(control::is_valid_close_status(4000), "4000 should be valid");

    char[] frame_data = control::create_close_frame(4000, "")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;
    ushort status = control::parse_close_status(f)!!;
    assert(status == 4000, "Should parse 4000 correctly");
}

/**
 * Test 30: Valid close code 4999 (Private use range end) (Autobahn 7.7.13)
 */
fn void test_valid_close_code_4999() @test
{
    assert(control::is_valid_close_status(4999), "4999 should be valid");

    char[] frame_data = control::create_close_frame(4999, "")!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;
    ushort status = control::parse_close_status(f)!!;
    assert(status == 4999, "Should parse 4999 correctly");
}

// ============================================================================
// Autobahn Category 7.9.x - Invalid Close Code Tests
// ============================================================================

/**
 * Test 31: Reject invalid close code 0 (Autobahn 7.9.1)
 */
fn void test_reject_invalid_close_code_0() @test
{
    assert(!control::is_valid_close_status(0), "0 should be invalid");

    if (catch control::create_close_frame(0, ""))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject close code 0");
}

/**
 * Test 32: Reject invalid close code 999 (Autobahn 7.9.2)
 */
fn void test_reject_invalid_close_code_999() @test
{
    assert(!control::is_valid_close_status(999), "999 should be invalid");

    if (catch control::create_close_frame(999, ""))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject close code 999");
}

/**
 * Test 33: Reject reserved close code 1004 (Autobahn 7.9.3)
 */
fn void test_reject_reserved_close_code_1004() @test
{
    assert(!control::is_valid_close_status(1004), "1004 should be reserved/invalid");

    if (catch control::create_close_frame(1004, ""))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject reserved close code 1004");
}

/**
 * Test 34: Reject reserved close code 1005 (Autobahn 7.9.4)
 */
fn void test_reject_reserved_close_code_1005() @test
{
    assert(!control::is_valid_close_status(1005), "1005 should be reserved/invalid");

    if (catch control::create_close_frame(1005, ""))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject reserved close code 1005");
}

/**
 * Test 35: Reject reserved close code 1006 (Autobahn 7.9.5)
 */
fn void test_reject_reserved_close_code_1006() @test
{
    assert(!control::is_valid_close_status(1006), "1006 should be reserved/invalid");

    if (catch control::create_close_frame(1006, ""))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject reserved close code 1006");
}

/**
 * Test 36: Reject invalid close code 1012 (Autobahn 7.9.6)
 */
fn void test_reject_invalid_close_code_1012() @test
{
    assert(!control::is_valid_close_status(1012), "1012 should be invalid");

    if (catch control::create_close_frame(1012, ""))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject close code 1012");
}

/**
 * Test 37: Reject invalid close code 1013 (Autobahn 7.9.7)
 */
fn void test_reject_invalid_close_code_1013() @test
{
    assert(!control::is_valid_close_status(1013), "1013 should be invalid");

    if (catch control::create_close_frame(1013, ""))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject close code 1013");
}

/**
 * Test 38: Reject invalid close code 1014 (Autobahn 7.9.8)
 */
fn void test_reject_invalid_close_code_1014() @test
{
    assert(!control::is_valid_close_status(1014), "1014 should be invalid");

    if (catch control::create_close_frame(1014, ""))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject close code 1014");
}

/**
 * Test 39: Reject reserved close code 1015 (Autobahn 7.9.9)
 */
fn void test_reject_reserved_close_code_1015() @test
{
    assert(!control::is_valid_close_status(1015), "1015 should be reserved/invalid");

    if (catch control::create_close_frame(1015, ""))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject reserved close code 1015");
}

/**
 * Test 40: Reject invalid close code 1016 (Autobahn 7.9.10)
 */
fn void test_reject_invalid_close_code_1016() @test
{
    assert(!control::is_valid_close_status(1016), "1016 should be invalid");

    if (catch control::create_close_frame(1016, ""))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject close code 1016");
}

/**
 * Test 41: Reject invalid close code 1100 (Autobahn 7.9.11)
 */
fn void test_reject_invalid_close_code_1100() @test
{
    assert(!control::is_valid_close_status(1100), "1100 should be invalid");

    if (catch control::create_close_frame(1100, ""))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject close code 1100");
}

/**
 * Test 42: Reject invalid close code 2000 (Autobahn 7.9.12)
 */
fn void test_reject_invalid_close_code_2000() @test
{
    assert(!control::is_valid_close_status(2000), "2000 should be invalid");

    if (catch control::create_close_frame(2000, ""))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject close code 2000");
}

/**
 * Test 43: Reject invalid close code 2999 (Autobahn 7.9.13)
 */
fn void test_reject_invalid_close_code_2999() @test
{
    assert(!control::is_valid_close_status(2999), "2999 should be invalid");

    if (catch control::create_close_frame(2999, ""))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject close code 2999");
}

/**
 * Test 44: Reject invalid close code 5000 (Autobahn 7.9.x)
 */
fn void test_reject_invalid_close_code_5000() @test
{
    assert(!control::is_valid_close_status(5000), "5000 should be invalid");

    if (catch control::create_close_frame(5000, ""))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject close code 5000");
}

/**
 * Test 45: Reject invalid close code 65535 (max ushort)
 */
fn void test_reject_invalid_close_code_65535() @test
{
    assert(!control::is_valid_close_status(65535), "65535 should be invalid");

    if (catch control::create_close_frame(65535, ""))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject close code 65535");
}
