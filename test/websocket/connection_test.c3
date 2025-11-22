/**
 * WebSocket Connection Tests
 *
 * RFC 6455 - Complete WebSocket connection lifecycle
 * Tests connection state management, message sending/receiving, and control frames
 */
module c3web::test::websocket::connection_test;

import c3web::websocket::connection;
import c3web::websocket::frame;
import c3web::websocket::control;
import std::io;

/**
 * Test 1: Initialize WebSocket connection
 */
fn void test_initialize_connection() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    assert(conn.state == connection::State.OPEN, "Initial state should be OPEN");
}

/**
 * Test 2: Send text message (single frame)
 *
 * Should create a single TEXT frame with FIN=1
 */
fn void test_send_text_message() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    char[] frame_data = conn.send_text("Hello WebSocket")!!;
    defer mem::free(frame_data.ptr);

    // Parse to verify frame structure
    frame::Frame f = frame::parse(frame_data)!!;

    assert(f.fin, "Single message should have FIN=1");
    assert(f.opcode == frame::Opcode.TEXT, "Should be TEXT frame");
    assert((String)f.payload == "Hello WebSocket", "Payload should match");
}

/**
 * Test 3: Receive text message (parse and validate)
 */
fn void test_receive_text_message() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    // Create incoming TEXT frame
    char[] incoming = {
        0x81,              // FIN=1, opcode=TEXT
        0x05,              // MASK=0, len=5
        'H', 'e', 'l', 'l', 'o'
    };

    connection::Message msg = conn.receive_message(incoming)!!;
    defer if (msg.payload_len > 0) mem::free(msg.payload.ptr);

    assert(msg.opcode == frame::Opcode.TEXT, "Should be TEXT message");
    assert((String)msg.payload == "Hello", "Payload should be 'Hello'");
}

/**
 * Test 4: Send binary message
 */
fn void test_send_binary_message() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    char[] data = {0x01, 0x02, 0x03, 0x04, 0x05};

    char[] frame_data = conn.send_binary(data)!!;
    defer mem::free(frame_data.ptr);

    frame::Frame f = frame::parse(frame_data)!!;

    assert(f.fin, "Single message should have FIN=1");
    assert(f.opcode == frame::Opcode.BINARY, "Should be BINARY frame");
    assert(f.payload_len == 5, "Payload length should be 5");
    assert(f.payload[0] == 0x01 && f.payload[4] == 0x05, "Binary data should match");
}

/**
 * Test 5: Receive binary message
 */
fn void test_receive_binary_message() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    // Create incoming BINARY frame
    char[] incoming = {
        0x82,              // FIN=1, opcode=BINARY
        0x03,              // MASK=0, len=3
        0xAA, 0xBB, 0xCC
    };

    connection::Message msg = conn.receive_message(incoming)!!;
    defer if (msg.payload_len > 0) mem::free(msg.payload.ptr);

    assert(msg.opcode == frame::Opcode.BINARY, "Should be BINARY message");
    assert(msg.payload_len == 3, "Payload length should be 3");
    assert(msg.payload[0] == 0xAA, "Binary data should match");
}

/**
 * Test 6: Receive fragmented message (automatic reassembly)
 *
 * Two fragments: "Hello" + " World"
 */
fn void test_receive_fragmented_message() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    // Fragment 1: "Hello" (FIN=0, TEXT)
    char[] frag1 = {
        0x01,              // FIN=0, opcode=TEXT
        0x05,              // len=5
        'H', 'e', 'l', 'l', 'o'
    };

    // First fragment - should not return message yet
    if (try msg = conn.receive_message(frag1))
    {
        assert(false, "First fragment should not complete message");
    }

    // Fragment 2: " World" (FIN=1, CONTINUATION)
    char[] frag2 = {
        0x80,              // FIN=1, opcode=CONTINUATION
        0x06,              // len=6
        ' ', 'W', 'o', 'r', 'l', 'd'
    };

    connection::Message msg = conn.receive_message(frag2)!!;
    defer if (msg.payload_len > 0) mem::free(msg.payload.ptr);

    assert(msg.opcode == frame::Opcode.TEXT, "Should be TEXT message");
    assert((String)msg.payload == "Hello World", "Reassembled message should be complete");
}

/**
 * Test 7: Handle PING (automatic PONG response)
 *
 * Connection should automatically respond to PING with PONG
 */
fn void test_handle_ping_automatic_pong() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    // Incoming PING frame
    char[] ping = {
        0x89,              // FIN=1, opcode=PING
        0x04,              // len=4
        't', 'e', 's', 't'
    };

    // Handle PING - should return PONG frame
    char[] pong_data = conn.handle_control_frame(ping)!!;
    defer mem::free(pong_data.ptr);

    frame::Frame pong = frame::parse(pong_data)!!;

    assert(pong.opcode == frame::Opcode.PONG, "Should respond with PONG");
    assert((String)pong.payload == "test", "PONG should echo PING payload");
}

/**
 * Test 8: Send PING frame
 */
fn void test_send_ping() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    char[] ping_data = conn.send_ping((char[])"heartbeat")!!;
    defer mem::free(ping_data.ptr);

    frame::Frame f = frame::parse(ping_data)!!;

    assert(f.opcode == frame::Opcode.PING, "Should be PING frame");
    assert((String)f.payload == "heartbeat", "Payload should match");
}

/**
 * Test 9: Graceful close handshake
 *
 * Send CLOSE frame with status code
 */
fn void test_send_close() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    // Send CLOSE frame
    char[] close_data = conn.send_close(control::CLOSE_NORMAL, "Goodbye")!!;
    defer mem::free(close_data.ptr);

    frame::Frame f = frame::parse(close_data)!!;

    assert(f.opcode == frame::Opcode.CLOSE, "Should be CLOSE frame");
    assert(conn.state == connection::State.CLOSING, "State should be CLOSING");

    // Extract status code
    ushort status = ((ushort)f.payload[0] << 8) | (ushort)f.payload[1];
    assert(status == 1000, "Status should be CLOSE_NORMAL");
}

/**
 * Test 10: Handle incoming CLOSE frame
 *
 * Should respond with CLOSE and transition to CLOSED state
 */
fn void test_handle_close_frame() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    // Incoming CLOSE frame
    char[] close_frame = {
        0x88,              // FIN=1, opcode=CLOSE
        0x02,              // len=2
        0x03, 0xE8         // Status 1000
    };

    // Handle CLOSE - should return response CLOSE
    char[] response = conn.handle_control_frame(close_frame)!!;
    defer mem::free(response.ptr);

    frame::Frame f = frame::parse(response)!!;

    assert(f.opcode == frame::Opcode.CLOSE, "Should respond with CLOSE");
    assert(conn.state == connection::State.CLOSED, "State should be CLOSED");
}

// ============================================================================
// Autobahn Category 7.x - Close Handshake Tests at Connection Level
// ============================================================================

/**
 * Test 11: Handle incoming CLOSE frame with empty payload (Autobahn 7.3.1)
 *
 * RFC 6455 §5.5.1: CLOSE frame MAY have empty payload.
 * Server should respond with empty CLOSE.
 */
fn void test_handle_close_empty_payload() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    // CLOSE frame with no payload
    char[] close_frame = {
        0x88,  // FIN=1, opcode=CLOSE
        0x00   // len=0
    };

    char[] response = conn.handle_control_frame(close_frame)!!;
    defer mem::free(response.ptr);

    frame::Frame f = frame::parse(response)!!;

    assert(f.opcode == frame::Opcode.CLOSE, "Should respond with CLOSE");
    assert(f.payload_len == 0, "Response should have empty payload");
    assert(conn.state == connection::State.CLOSED, "State should be CLOSED");
}

/**
 * Test 12: Handle incoming CLOSE frame with 1-byte payload (Autobahn 7.3.2)
 *
 * RFC 6455 §7.1.6: CLOSE frame body MUST be 0 bytes OR 2+ bytes.
 * 1-byte payload is protocol error, server should respond with 1002.
 */
fn void test_handle_close_one_byte_payload() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    // CLOSE frame with 1 byte payload (INVALID)
    char[] close_frame = {
        0x88,  // FIN=1, opcode=CLOSE
        0x01,  // len=1
        0xAB   // Single byte (invalid)
    };

    char[] response = conn.handle_control_frame(close_frame)!!;
    defer mem::free(response.ptr);

    frame::Frame f = frame::parse(response)!!;

    assert(f.opcode == frame::Opcode.CLOSE, "Should respond with CLOSE");
    assert(f.payload_len >= 2, "Response should have status code");

    // Should respond with 1002 (Protocol Error)
    ushort status = ((ushort)f.payload[0] << 8) | (ushort)f.payload[1];
    assert(status == 1002, "Should respond with 1002 (Protocol Error)");
    assert(conn.state == connection::State.CLOSED, "State should be CLOSED");
}

/**
 * Test 13: Handle incoming CLOSE frame with status code only (Autobahn 7.3.3)
 *
 * Server should echo back the same status code.
 */
fn void test_handle_close_status_only() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    // CLOSE frame with status 1000, no reason
    char[] close_frame = {
        0x88,        // FIN=1, opcode=CLOSE
        0x02,        // len=2
        0x03, 0xE8   // Status 1000
    };

    char[] response = conn.handle_control_frame(close_frame)!!;
    defer mem::free(response.ptr);

    frame::Frame f = frame::parse(response)!!;

    assert(f.opcode == frame::Opcode.CLOSE, "Should respond with CLOSE");

    // Should echo back the status code
    ushort status = ((ushort)f.payload[0] << 8) | (ushort)f.payload[1];
    assert(status == 1000, "Should echo back status 1000");
    assert(conn.state == connection::State.CLOSED, "State should be CLOSED");
}

/**
 * Test 14: Handle incoming CLOSE with status and reason (Autobahn 7.3.4)
 *
 * Server should echo back the status code (reason may be omitted).
 */
fn void test_handle_close_with_reason() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    // CLOSE frame with status 1000 + reason "bye"
    char[] close_frame = {
        0x88,              // FIN=1, opcode=CLOSE
        0x05,              // len=5
        0x03, 0xE8,        // Status 1000
        'b', 'y', 'e'      // Reason "bye"
    };

    char[] response = conn.handle_control_frame(close_frame)!!;
    defer mem::free(response.ptr);

    frame::Frame f = frame::parse(response)!!;

    assert(f.opcode == frame::Opcode.CLOSE, "Should respond with CLOSE");

    ushort status = ((ushort)f.payload[0] << 8) | (ushort)f.payload[1];
    assert(status == 1000, "Should echo back status 1000");
    assert(conn.state == connection::State.CLOSED, "State should be CLOSED");
}

/**
 * Test 15: Close handshake completion when we initiate
 *
 * When we send CLOSE first and then receive CLOSE response.
 */
fn void test_close_handshake_initiated_by_us() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    // We send CLOSE first
    char[] our_close = conn.send_close(control::CLOSE_NORMAL, "Goodbye")!!;
    defer mem::free(our_close.ptr);

    assert(conn.state == connection::State.CLOSING, "State should be CLOSING after we send CLOSE");
    assert(conn.close_sent, "close_sent should be true");

    // Peer responds with CLOSE
    char[] peer_close = {
        0x88,        // FIN=1, opcode=CLOSE
        0x02,        // len=2
        0x03, 0xE8   // Status 1000
    };

    char[] response = conn.handle_control_frame(peer_close)!!;
    // Response should be empty (no need to respond again)
    assert(response.len == 0, "Should not send another CLOSE");

    assert(conn.state == connection::State.CLOSED, "State should be CLOSED");
    assert(conn.close_received, "close_received should be true");
}

/**
 * Test 16: Reject send_text after CLOSE sent
 *
 * After entering CLOSING state, should not allow sending data.
 */
fn void test_reject_send_after_close() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    // Send CLOSE
    char[] close_data = conn.send_close(control::CLOSE_NORMAL, "")!!;
    defer mem::free(close_data.ptr);

    assert(conn.state == connection::State.CLOSING, "State should be CLOSING");

    // Try to send text - should fail
    if (catch conn.send_text("Hello"))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject send_text after CLOSE sent");
}

/**
 * Test 17: Reject send_binary after connection closed
 */
fn void test_reject_send_after_closed() @test
{
    connection::WebSocketConnection conn;
    conn.init();
    defer conn.free();

    // Receive CLOSE from peer (enters CLOSED state)
    char[] peer_close = {
        0x88,        // FIN=1, opcode=CLOSE
        0x02,        // len=2
        0x03, 0xE8   // Status 1000
    };

    char[] response = conn.handle_control_frame(peer_close)!!;
    defer mem::free(response.ptr);

    assert(conn.state == connection::State.CLOSED, "State should be CLOSED");

    // Try to send binary - should fail
    if (catch conn.send_binary((char[]){0x01, 0x02}))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject send_binary after connection closed");
}

/**
 * Test 18: Handle various valid close codes at connection level (7.7.x)
 */
fn void test_handle_close_various_valid_codes() @test
{
    // Test various valid status codes
    ushort[] valid_codes = { 1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 3000, 4000 };

    foreach (code : valid_codes)
    {
        connection::WebSocketConnection conn;
        conn.init();
        defer conn.free();

        // Build CLOSE frame with this status code
        char[] close_frame = {
            0x88,  // FIN=1, opcode=CLOSE
            0x02,  // len=2
            (char)(code >> 8),    // Status high byte
            (char)(code & 0xFF)   // Status low byte
        };

        char[] response = conn.handle_control_frame(close_frame)!!;
        defer mem::free(response.ptr);

        frame::Frame f = frame::parse(response)!!;

        assert(f.opcode == frame::Opcode.CLOSE, "Should respond with CLOSE");

        ushort echo_status = ((ushort)f.payload[0] << 8) | (ushort)f.payload[1];
        assert(echo_status == code, "Should echo back the same status code");
        assert(conn.state == connection::State.CLOSED, "State should be CLOSED");
    }
}
