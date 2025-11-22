/**
 * WebSocket Message Fragmentation Tests
 *
 * RFC 6455 §5.4 - Fragmentation
 * Tests message reassembly, continuation frames, and interleaved control frames
 */
module c3web::test::websocket::message_test;

import c3web::websocket::message;
import c3web::websocket::frame;
import std::io;

/**
 * Test 1: Reassemble text message from 3 fragments
 *
 * RFC 6455 §5.4: A fragmented message consists of a single frame with FIN=0
 * and opcode != 0, followed by zero or more frames with FIN=0 and opcode=0,
 * and terminated by a single frame with FIN=1 and opcode=0.
 */
fn void test_reassemble_text_message_three_fragments() @test
{
    message::MessageBuilder builder;
    builder.init();
    defer builder.free();

    // Fragment 1: "Hel" (FIN=0, opcode=TEXT)
    frame::Frame f1;
    f1.fin = false;
    f1.opcode = frame::Opcode.TEXT;
    f1.payload = (char[])"Hel";
    f1.payload_len = 3;

    bool complete1 = builder.add_frame(f1)!!;
    assert(!complete1, "Message should not be complete after first fragment");

    // Fragment 2: "lo " (FIN=0, opcode=CONTINUATION)
    frame::Frame f2;
    f2.fin = false;
    f2.opcode = frame::Opcode.CONTINUATION;
    f2.payload = (char[])"lo ";
    f2.payload_len = 3;

    bool complete2 = builder.add_frame(f2)!!;
    assert(!complete2, "Message should not be complete after second fragment");

    // Fragment 3: "World" (FIN=1, opcode=CONTINUATION)
    frame::Frame f3;
    f3.fin = true;
    f3.opcode = frame::Opcode.CONTINUATION;
    f3.payload = (char[])"World";
    f3.payload_len = 5;

    bool complete3 = builder.add_frame(f3)!!;
    assert(complete3, "Message should be complete after final fragment");

    // Get complete message (view into builder's buffer)
    message::Message msg = builder.get_message()!!;

    assert(msg.opcode == frame::Opcode.TEXT, "Message opcode should be TEXT");
    assert(msg.payload_len == 11, "Total payload length should be 11");
    assert((String)msg.payload == "Hello World", "Reassembled message should be 'Hello World'");
}

/**
 * Test 2: Reassemble binary message from 2 fragments
 */
fn void test_reassemble_binary_message_two_fragments() @test
{
    message::MessageBuilder builder;
    builder.init();
    defer builder.free();

    // Fragment 1: [0x01, 0x02, 0x03] (FIN=0, opcode=BINARY)
    frame::Frame f1;
    f1.fin = false;
    f1.opcode = frame::Opcode.BINARY;
    char[] payload1 = {0x01, 0x02, 0x03};
    f1.payload = payload1;
    f1.payload_len = 3;

    builder.add_frame(f1)!!;

    // Fragment 2: [0x04, 0x05] (FIN=1, opcode=CONTINUATION)
    frame::Frame f2;
    f2.fin = true;
    f2.opcode = frame::Opcode.CONTINUATION;
    char[] payload2 = {0x04, 0x05};
    f2.payload = payload2;
    f2.payload_len = 2;

    bool complete = builder.add_frame(f2)!!;
    assert(complete, "Binary message should be complete");

    message::Message msg = builder.get_message()!!;

    assert(msg.opcode == frame::Opcode.BINARY, "Message opcode should be BINARY");
    assert(msg.payload_len == 5, "Total payload length should be 5");
    assert(msg.payload[0] == 0x01 && msg.payload[4] == 0x05, "Binary data should be correct");
}

/**
 * Test 3: Handle interleaved control frame (PING) during fragmentation
 *
 * RFC 6455 §5.5: Control frames MAY be injected in the middle of a fragmented message
 */
fn void test_interleaved_control_frame() @test
{
    message::MessageBuilder builder;
    builder.init();
    defer builder.free();

    // Fragment 1: "Hello" (FIN=0, opcode=TEXT)
    frame::Frame f1;
    f1.fin = false;
    f1.opcode = frame::Opcode.TEXT;
    f1.payload = (char[])"Hello";
    f1.payload_len = 5;

    builder.add_frame(f1)!!;

    // Interleaved PING frame (FIN=1, opcode=PING) - should be ignored by builder
    frame::Frame ping;
    ping.fin = true;
    ping.opcode = frame::Opcode.PING;
    ping.payload = (char[])"ping";
    ping.payload_len = 4;

    // MessageBuilder should return fault for control frames during fragmentation
    if (catch builder.add_frame(ping))
    {
        // Expected - control frames should be handled separately
    }

    // Fragment 2: " World" (FIN=1, opcode=CONTINUATION)
    frame::Frame f2;
    f2.fin = true;
    f2.opcode = frame::Opcode.CONTINUATION;
    f2.payload = (char[])" World";
    f2.payload_len = 6;

    bool complete = builder.add_frame(f2)!!;
    assert(complete, "Message should be complete");

    message::Message msg = builder.get_message()!!;

    assert((String)msg.payload == "Hello World", "Message should not include PING data");
}

/**
 * Test 4: Reject continuation frame without initial frame
 *
 * RFC 6455 §5.4: A continuation frame MUST only follow a fragmented message start
 */
fn void test_reject_continuation_without_initial() @test
{
    message::MessageBuilder builder;
    builder.init();
    defer builder.free();

    // Try to add continuation frame without initial frame
    frame::Frame cont;
    cont.fin = true;
    cont.opcode = frame::Opcode.CONTINUATION;
    cont.payload = (char[])"data";
    cont.payload_len = 4;

    if (catch builder.add_frame(cont))
    {
        // Expected to fail
        return;
    }

    assert(false, "Should reject continuation frame without initial frame");
}

/**
 * Test 5: Reject non-continuation frame during fragmentation
 *
 * RFC 6455 §5.4: After a fragmented message starts, only CONTINUATION or control frames allowed
 */
fn void test_reject_non_continuation_during_fragmentation() @test
{
    message::MessageBuilder builder;
    builder.init();
    defer builder.free();

    // Fragment 1: Start fragmented message (FIN=0, opcode=TEXT)
    frame::Frame f1;
    f1.fin = false;
    f1.opcode = frame::Opcode.TEXT;
    f1.payload = (char[])"Hello";
    f1.payload_len = 5;

    builder.add_frame(f1)!!;

    // Try to add another TEXT frame (should be CONTINUATION)
    frame::Frame f2;
    f2.fin = true;
    f2.opcode = frame::Opcode.TEXT;
    f2.payload = (char[])"World";
    f2.payload_len = 5;

    if (catch builder.add_frame(f2))
    {
        // Expected to fail - can't start new message during fragmentation
        return;
    }

    assert(false, "Should reject non-continuation data frame during fragmentation");
}

/**
 * Test 6: Handle single-frame message (FIN=1, no fragmentation)
 */
fn void test_single_frame_message() @test
{
    message::MessageBuilder builder;
    builder.init();
    defer builder.free();

    // Single complete frame (FIN=1, opcode=TEXT)
    frame::Frame f;
    f.fin = true;
    f.opcode = frame::Opcode.TEXT;
    f.payload = (char[])"Complete";
    f.payload_len = 8;

    bool complete = builder.add_frame(f)!!;
    assert(complete, "Single-frame message should be complete immediately");

    message::Message msg = builder.get_message()!!;

    assert((String)msg.payload == "Complete", "Single-frame message should be intact");
}

/**
 * Test 7: Validate UTF-8 across fragmented text message
 *
 * RFC 6455 §5.4: Text frames MUST contain valid UTF-8, even when fragmented.
 * A multi-byte UTF-8 sequence can span fragment boundaries.
 */
fn void test_utf8_validation_across_fragments() @test
{
    message::MessageBuilder builder;
    builder.init();
    defer builder.free();

    // Fragment 1: "Hel" + first byte of "é" (0xC3)
    // "é" = U+00E9 = 0xC3 0xA9 in UTF-8
    char[] frag1 = {'H', 'e', 'l', 0xC3};

    frame::Frame f1;
    f1.fin = false;
    f1.opcode = frame::Opcode.TEXT;
    f1.payload = frag1;
    f1.payload_len = 4;

    builder.add_frame(f1)!!;

    // Fragment 2: second byte of "é" (0xA9) + "lo"
    char[] frag2 = {0xA9, 'l', 'o'};

    frame::Frame f2;
    f2.fin = true;
    f2.opcode = frame::Opcode.CONTINUATION;
    f2.payload = frag2;
    f2.payload_len = 3;

    bool complete = builder.add_frame(f2)!!;
    assert(complete, "UTF-8 fragmented message should complete successfully");

    message::Message msg = builder.get_message()!!;

    assert(msg.payload_len == 7, "Total length should be 7 bytes");
    // Note: UTF-8 validation happens during reassembly
}

/**
 * Test 8: Reject invalid UTF-8 in fragmented text message
 *
 * Invalid UTF-8 sequence across fragments should fail
 */
fn void test_reject_invalid_utf8_across_fragments() @test
{
    message::MessageBuilder builder;
    builder.init();
    defer builder.free();

    // Fragment 1: Start of 2-byte sequence (0xC3)
    char[] frag1 = {'H', 'e', 0xC3};

    frame::Frame f1;
    f1.fin = false;
    f1.opcode = frame::Opcode.TEXT;
    f1.payload = frag1;
    f1.payload_len = 3;

    builder.add_frame(f1)!!;

    // Fragment 2: Invalid continuation byte (0xFF instead of 0x80-0xBF)
    char[] frag2 = {0xFF, 'l', 'o'};

    frame::Frame f2;
    f2.fin = true;
    f2.opcode = frame::Opcode.CONTINUATION;
    f2.payload = frag2;
    f2.payload_len = 3;

    if (catch builder.add_frame(f2))
    {
        // Expected to fail due to invalid UTF-8
        return;
    }

    assert(false, "Should reject invalid UTF-8 sequence");
}

/**
 * Test 9: Handle empty fragments
 *
 * RFC 6455 allows zero-length payloads
 */
fn void test_empty_fragments() @test
{
    message::MessageBuilder builder;
    builder.init();
    defer builder.free();

    // Fragment 1: "Hello" (FIN=0)
    frame::Frame f1;
    f1.fin = false;
    f1.opcode = frame::Opcode.TEXT;
    f1.payload = (char[])"Hello";
    f1.payload_len = 5;

    builder.add_frame(f1)!!;

    // Fragment 2: Empty (FIN=0, opcode=CONTINUATION)
    frame::Frame f2;
    f2.fin = false;
    f2.opcode = frame::Opcode.CONTINUATION;
    f2.payload = {};
    f2.payload_len = 0;

    builder.add_frame(f2)!!;

    // Fragment 3: " World" (FIN=1, opcode=CONTINUATION)
    frame::Frame f3;
    f3.fin = true;
    f3.opcode = frame::Opcode.CONTINUATION;
    f3.payload = (char[])" World";
    f3.payload_len = 6;

    bool complete = builder.add_frame(f3)!!;
    assert(complete, "Message with empty fragment should complete");

    message::Message msg = builder.get_message()!!;

    assert((String)msg.payload == "Hello World", "Empty fragment should not affect result");
}

/**
 * Test 10: Enforce message size limit
 *
 * Prevent memory exhaustion attacks with very large messages
 */
fn void test_enforce_message_size_limit() @test
{
    message::MessageBuilder builder;
    builder.init();
    defer builder.free();

    // Set small limit for testing (e.g., 100 bytes)
    builder.set_max_message_size(100);

    // Try to add fragments that exceed limit
    frame::Frame f1;
    f1.fin = false;
    f1.opcode = frame::Opcode.TEXT;
    char[60] payload1;
    foreach (&c : payload1) *c = 'A';
    f1.payload = payload1[..];
    f1.payload_len = 60;

    builder.add_frame(f1)!!;

    // Second fragment: 60 more bytes (total 120 > 100 limit)
    frame::Frame f2;
    f2.fin = true;
    f2.opcode = frame::Opcode.CONTINUATION;
    char[60] payload2;
    foreach (&c : payload2) *c = 'B';
    f2.payload = payload2[..];
    f2.payload_len = 60;

    if (catch builder.add_frame(f2))
    {
        // Expected to fail due to size limit
        return;
    }

    assert(false, "Should reject message exceeding size limit");
}
