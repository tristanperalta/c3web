/**
 * WebSocket Performance Tests
 *
 * Autobahn Test Category 9.8.x - RTT/Latency Tests
 * Tests performance of handling many small messages (not large single messages)
 *
 * 9.8.5: Send 1000 binary messages of payload size 1024 bytes
 * 9.8.6: Send 1000 binary messages of payload size 4096 bytes
 */
module c3web::test::websocket::large_message_test;

import c3web::websocket::frame;
import c3web::websocket::message;
import c3web::websocket::connection;
import std::io;
import std::core::mem;

/**
 * Test 1: Simulate Autobahn 9.8.5 - 1000 binary messages of 1024 bytes
 *
 * Tests frame parsing and unmasking performance for many small messages.
 * This is an RTT/latency test, not a large message test.
 */
fn void test_1000_messages_1kb() @test
{
    const usz MESSAGE_COUNT = 1000;
    const usz PAYLOAD_SIZE = 1024;
    const usz HEADER_SIZE = 8; // 2 + 2 (16-bit len) + 4 (mask)

    char[4] mask = {0x12, 0x34, 0x56, 0x78};
    char original = 'B';

    // Build a single frame template
    char[] frame_data = mem::new_array(char, HEADER_SIZE + PAYLOAD_SIZE);
    defer mem::free(frame_data);

    // Header: FIN=1, BINARY, MASK=1, 16-bit length
    frame_data[0] = 0x82; // FIN=1, opcode=0x2 (binary)
    frame_data[1] = 0x80 | 126; // MASK=1, len=126 (16-bit follows)
    frame_data[2] = (char)((PAYLOAD_SIZE >> 8) & 0xFF);
    frame_data[3] = (char)(PAYLOAD_SIZE & 0xFF);
    frame_data[4] = mask[0];
    frame_data[5] = mask[1];
    frame_data[6] = mask[2];
    frame_data[7] = mask[3];

    // Masked payload
    for (usz i = 0; i < PAYLOAD_SIZE; i++)
    {
        frame_data[HEADER_SIZE + i] = original ^ mask[i & 3];
    }

    // Parse 1000 messages
    for (usz msg = 0; msg < MESSAGE_COUNT; msg++)
    {
        // Re-mask the payload (since parse() unmasks in place)
        for (usz i = 0; i < PAYLOAD_SIZE; i++)
        {
            frame_data[HEADER_SIZE + i] = original ^ mask[i & 3];
        }

        frame::Frame f = frame::parse(frame_data)!!;

        assert(f.fin, "FIN should be set");
        assert(f.opcode == frame::Opcode.BINARY, "Opcode should be BINARY");
        assert(f.payload_len == PAYLOAD_SIZE, "Payload should be 1KB");
        assert(f.payload[0] == original, "First byte should be unmasked");
        assert(f.payload[PAYLOAD_SIZE - 1] == original, "Last byte should be unmasked");
    }
}

/**
 * Test 2: Simulate Autobahn 9.8.6 - 1000 binary messages of 4096 bytes
 *
 * Tests frame parsing and unmasking performance for many medium messages.
 */
fn void test_1000_messages_4kb() @test
{
    const usz MESSAGE_COUNT = 1000;
    const usz PAYLOAD_SIZE = 4096;
    const usz HEADER_SIZE = 8; // 2 + 2 (16-bit len) + 4 (mask)

    char[4] mask = {0xAB, 0xCD, 0xEF, 0x12};
    char original = 'D';

    char[] frame_data = mem::new_array(char, HEADER_SIZE + PAYLOAD_SIZE);
    defer mem::free(frame_data);

    // Header: FIN=1, BINARY, MASK=1, 16-bit length
    frame_data[0] = 0x82;
    frame_data[1] = 0x80 | 126;
    frame_data[2] = (char)((PAYLOAD_SIZE >> 8) & 0xFF);
    frame_data[3] = (char)(PAYLOAD_SIZE & 0xFF);
    frame_data[4] = mask[0];
    frame_data[5] = mask[1];
    frame_data[6] = mask[2];
    frame_data[7] = mask[3];

    // Masked payload
    for (usz i = 0; i < PAYLOAD_SIZE; i++)
    {
        frame_data[HEADER_SIZE + i] = original ^ mask[i & 3];
    }

    // Parse 1000 messages
    for (usz msg = 0; msg < MESSAGE_COUNT; msg++)
    {
        // Re-mask the payload
        for (usz i = 0; i < PAYLOAD_SIZE; i++)
        {
            frame_data[HEADER_SIZE + i] = original ^ mask[i & 3];
        }

        frame::Frame f = frame::parse(frame_data)!!;

        assert(f.fin, "FIN should be set");
        assert(f.opcode == frame::Opcode.BINARY, "Opcode should be BINARY");
        assert(f.payload_len == PAYLOAD_SIZE, "Payload should be 4KB");
        assert(f.payload[0] == original, "First byte should be unmasked");
    }
}

/**
 * Test 3: Unmask correctness with various sizes
 *
 * Ensures the 64-bit XOR optimization produces correct results
 * for all payload sizes (edge cases at 8-byte boundaries).
 */
fn void test_unmask_correctness() @test
{
    usz[16] sizes = {1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 100, 1000, 65535, 65536};

    char[4] mask = {0x12, 0x34, 0x56, 0x78};

    foreach (size : sizes)
    {
        char[] payload = mem::new_array(char, size);
        defer mem::free(payload);

        char[] expected = mem::new_array(char, size);
        defer mem::free(expected);

        // Fill with masked pattern
        for (usz i = 0; i < size; i++)
        {
            char original = (char)(i & 0xFF);
            payload[i] = original ^ mask[i & 3];
            expected[i] = original;
        }

        // Unmask
        frame::unmask_payload(payload, mask);

        // Verify
        for (usz i = 0; i < size; i++)
        {
            assert(payload[i] == expected[i], "Unmask mismatch");
        }
    }
}

/**
 * Test 4: Unmask with unaligned memory
 *
 * Tests that unmask handles unaligned memory correctly
 * (important for 64-bit XOR optimization).
 */
fn void test_unmask_unaligned() @test
{
    const usz SIZE = 1024;
    char[] buffer = mem::new_array(char, SIZE + 16);
    defer mem::free(buffer);

    // Create unaligned slice (offset by 3 bytes)
    char[] payload = buffer[3:SIZE];

    char[4] mask = {0xAB, 0xCD, 0xEF, 0x12};
    char original = 'A';

    for (usz i = 0; i < payload.len; i++)
    {
        payload[i] = original ^ mask[i & 3];
    }

    frame::unmask_payload(payload, mask);

    // Verify
    assert(payload[0] == original, "First byte should be 'A'");
    assert(payload[payload.len - 1] == original, "Last byte should be 'A'");
}

/**
 * Test 5: MessageBuilder handles multiple sequential messages
 *
 * Tests that MessageBuilder can be reused for multiple messages
 * (simulates echo server handling many requests).
 */
fn void test_message_builder_multiple() @test
{
    message::MessageBuilder builder;
    builder.init();
    defer builder.free();

    const usz MESSAGE_COUNT = 100;
    const usz PAYLOAD_SIZE = 1024;

    char[] payload = mem::new_array(char, PAYLOAD_SIZE);
    defer mem::free(payload);
    foreach (&c : payload) *c = 'M';

    for (usz msg = 0; msg < MESSAGE_COUNT; msg++)
    {
        // Single-frame message
        frame::Frame f;
        f.fin = true;
        f.opcode = frame::Opcode.BINARY;
        f.payload = payload;
        f.payload_len = PAYLOAD_SIZE;

        bool complete = builder.add_frame(f)!!;
        assert(complete, "Single-frame message should be complete");

        message::Message result = builder.get_message()!!;
        assert(result.payload_len == PAYLOAD_SIZE, "Payload size should match");
        assert(result.payload[0] == 'M', "Content should match");

        // Reset for next message
        builder.reset();
    }
}

/**
 * Test 6: Large single message (1MB)
 *
 * Tests handling of large single messages with 64-bit length encoding.
 */
fn void test_parse_1mb_frame() @test
{
    const usz PAYLOAD_SIZE = 1 * 1024 * 1024; // 1MB
    const usz HEADER_SIZE = 14; // 2 + 8 (64-bit len) + 4 (mask)

    char[] frame_data = mem::new_array(char, HEADER_SIZE + PAYLOAD_SIZE);
    defer mem::free(frame_data);

    // Header: FIN=1, BINARY, MASK=1, 64-bit length
    frame_data[0] = 0x82; // FIN=1, opcode=0x2 (binary)
    frame_data[1] = 0xFF; // MASK=1, len=127

    // 64-bit length (big-endian)
    frame_data[2] = 0;
    frame_data[3] = 0;
    frame_data[4] = 0;
    frame_data[5] = 0;
    frame_data[6] = (char)(PAYLOAD_SIZE >> 24);
    frame_data[7] = (char)(PAYLOAD_SIZE >> 16);
    frame_data[8] = (char)(PAYLOAD_SIZE >> 8);
    frame_data[9] = (char)(PAYLOAD_SIZE & 0xFF);

    // Mask key
    char[4] mask = {0x11, 0x22, 0x33, 0x44};
    frame_data[10] = mask[0];
    frame_data[11] = mask[1];
    frame_data[12] = mask[2];
    frame_data[13] = mask[3];

    // Masked payload
    char original = 'Y';
    for (usz i = 0; i < PAYLOAD_SIZE; i++)
    {
        frame_data[HEADER_SIZE + i] = original ^ mask[i & 3];
    }

    frame::Frame f = frame::parse(frame_data)!!;

    assert(f.fin, "FIN should be set");
    assert(f.opcode == frame::Opcode.BINARY, "Opcode should be BINARY");
    assert(f.masked, "Frame should be masked");
    assert(f.payload_len == PAYLOAD_SIZE, "Payload length should be 1MB");
    assert(f.payload[0] == original, "First byte should be 'Y' (unmasked)");
    assert(f.payload[PAYLOAD_SIZE - 1] == original, "Last byte should be 'Y' (unmasked)");
}

/**
 * Test 7: Fragmented message reassembly
 *
 * Tests MessageBuilder with fragmented messages (multiple frames).
 */
fn void test_fragmented_message() @test
{
    message::MessageBuilder builder;
    builder.init();
    defer builder.free();

    const usz CHUNK_SIZE = 1024;
    const usz CHUNK_COUNT = 10;

    char[] chunk = mem::new_array(char, CHUNK_SIZE);
    defer mem::free(chunk);
    foreach (&c : chunk) *c = 'F';

    // First frame (opcode=BINARY, FIN=0)
    frame::Frame f1;
    f1.fin = false;
    f1.opcode = frame::Opcode.BINARY;
    f1.payload = chunk;
    f1.payload_len = CHUNK_SIZE;
    bool complete = builder.add_frame(f1)!!;
    assert(!complete, "First fragment should not complete message");

    // Middle frames (opcode=CONTINUATION, FIN=0)
    for (usz i = 1; i < CHUNK_COUNT - 1; i++)
    {
        frame::Frame f;
        f.fin = false;
        f.opcode = frame::Opcode.CONTINUATION;
        f.payload = chunk;
        f.payload_len = CHUNK_SIZE;
        complete = builder.add_frame(f)!!;
        assert(!complete, "Middle fragment should not complete message");
    }

    // Final frame (opcode=CONTINUATION, FIN=1)
    frame::Frame f_last;
    f_last.fin = true;
    f_last.opcode = frame::Opcode.CONTINUATION;
    f_last.payload = chunk;
    f_last.payload_len = CHUNK_SIZE;
    complete = builder.add_frame(f_last)!!;
    assert(complete, "Final fragment should complete message");

    message::Message msg = builder.get_message()!!;
    assert(msg.payload_len == CHUNK_SIZE * CHUNK_COUNT, "Total payload should be 10KB");
    assert(msg.opcode == frame::Opcode.BINARY, "Opcode should be BINARY");
    assert(msg.payload[0] == 'F', "First byte should be 'F'");
    assert(msg.payload[msg.payload_len - 1] == 'F', "Last byte should be 'F'");
}
