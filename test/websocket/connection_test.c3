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
