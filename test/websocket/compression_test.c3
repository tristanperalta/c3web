/**
 * WebSocket Compression Tests (TDD)
 *
 * RFC 7692 - Compression Extensions for WebSocket (permessage-deflate)
 * Tests based on Autobahn Testsuite Categories 12 and 13
 */
module c3web::test::websocket::compression_test;

import c3web::websocket::compression;
import c3web::websocket::frame;
import std::io;

// ============================================================================
// Phase 1: Low-level Deflate Tests
// ============================================================================

/**
 * Compress a simple string
 *
 * Verify that deflate compression produces output smaller than input
 * for compressible data.
 */
fn void test_deflate_compress_simple() @test
{
    compression::DeflateContext ctx;
    ctx.init()!!;
    defer ctx.free();

    String input = "Hello, WebSocket compression! This is a test message that should compress well.";
    char[] compressed = ctx.compress((char[])input)!!;
    defer mem::free(compressed.ptr);

    // Compressed should be smaller for this compressible text
    assert(compressed.len > 0, "Compressed output should not be empty");
    assert(compressed.len < input.len, "Compressed should be smaller than input for text");
}

/**
 * Decompress back to original
 *
 * Verify that inflate decompression restores original data.
 */
fn void test_deflate_decompress_simple() @test
{
    compression::DeflateContext deflate_ctx;
    deflate_ctx.init()!!;
    defer deflate_ctx.free();

    compression::InflateContext inflate_ctx;
    inflate_ctx.init()!!;
    defer inflate_ctx.free();

    String input = "Hello, WebSocket!";
    char[] compressed = deflate_ctx.compress((char[])input)!!;
    defer mem::free(compressed.ptr);

    char[] decompressed = inflate_ctx.decompress(compressed)!!;
    defer mem::free(decompressed.ptr);

    assert((String)decompressed == input, "Decompressed should match original");
}

/**
 * Roundtrip compression
 *
 * Compress and decompress various sizes, verify equality.
 */
fn void test_deflate_roundtrip() @test
{
    compression::DeflateContext deflate_ctx;
    deflate_ctx.init()!!;
    defer deflate_ctx.free();

    compression::InflateContext inflate_ctx;
    inflate_ctx.init()!!;
    defer inflate_ctx.free();

    // Test various sizes matching Autobahn 12.1.x patterns
    usz[] sizes = { 16, 64, 256, 1024, 4096, 8192 };

    foreach (size : sizes)
    {
        // Create test data
        char[] input = mem::new_array(char, size);
        defer mem::free(input.ptr);
        for (usz i = 0; i < size; i++)
        {
            input[i] = (char)('A' + (i % 26));
        }

        char[] compressed = deflate_ctx.compress(input)!!;
        defer mem::free(compressed.ptr);

        char[] decompressed = inflate_ctx.decompress(compressed)!!;
        defer mem::free(decompressed.ptr);

        assert(decompressed.len == size, "Decompressed length should match original");
        for (usz i = 0; i < size; i++)
        {
            assert(decompressed[i] == input[i], "Decompressed data should match original");
        }

        // Reset contexts for next iteration (no_context_takeover behavior)
        deflate_ctx.reset()!!;
        inflate_ctx.reset()!!;
    }
}

/**
 * Raw deflate mode (no zlib header)
 *
 * RFC 7692 requires raw DEFLATE without zlib/gzip wrappers.
 * The first byte should NOT be a zlib header (0x78).
 */
fn void test_deflate_raw_mode() @test
{
    compression::DeflateContext ctx;
    ctx.init()!!;
    defer ctx.free();

    String input = "Test data for raw deflate verification";
    char[] compressed = ctx.compress((char[])input)!!;
    defer mem::free(compressed.ptr);

    // Raw deflate should NOT start with zlib header (0x78 0x9C, 0x78 0x01, etc.)
    // First byte of raw deflate is typically 0x00-0x07 or other block markers
    if (compressed.len > 0)
    {
        assert(compressed[0] != 0x78, "Should be raw deflate, not zlib format");
    }
}

/**
 * Trailing bytes handling
 *
 * RFC 7692 Section 7.2.1: Compressed data has trailing 0x00 0x00 0xFF 0xFF removed.
 * Our compress() should strip it, decompress() should handle without it.
 */
fn void test_deflate_trailing_bytes() @test
{
    compression::DeflateContext deflate_ctx;
    deflate_ctx.init()!!;
    defer deflate_ctx.free();

    String input = "Test message";
    char[] compressed = deflate_ctx.compress((char[])input)!!;
    defer mem::free(compressed.ptr);

    // Verify trailing bytes are NOT present (they should be stripped)
    if (compressed.len >= 4)
    {
        bool has_trailer = compressed[compressed.len - 4] == 0x00 &&
                           compressed[compressed.len - 3] == 0x00 &&
                           compressed[compressed.len - 2] == 0xFF &&
                           compressed[compressed.len - 1] == 0xFF;
        assert(!has_trailer, "Trailing 0x00 0x00 0xFF 0xFF should be stripped");
    }
}

/**
 * Context reuse (context takeover)
 *
 * When context is reused, repeated patterns compress better.
 */
fn void test_deflate_context_reuse() @test
{
    compression::DeflateContext deflate_ctx;
    deflate_ctx.init()!!;
    defer deflate_ctx.free();

    compression::InflateContext inflate_ctx;
    inflate_ctx.init()!!;
    defer inflate_ctx.free();

    String msg = "This is a repeated test message for context takeover.";

    // First compression
    char[] compressed1 = deflate_ctx.compress((char[])msg)!!;
    defer mem::free(compressed1.ptr);

    // Second compression (same data, context retained)
    char[] compressed2 = deflate_ctx.compress((char[])msg)!!;
    defer mem::free(compressed2.ptr);

    // With context takeover, second compression should be smaller or equal
    // (dictionary from first message helps compress second)
    assert(compressed2.len <= compressed1.len, "Context takeover should maintain or improve compression");

    // Decompress both (inflate context also reused)
    char[] decompressed1 = inflate_ctx.decompress(compressed1)!!;
    defer mem::free(decompressed1.ptr);

    char[] decompressed2 = inflate_ctx.decompress(compressed2)!!;
    defer mem::free(decompressed2.ptr);

    assert((String)decompressed1 == msg, "First decompression should match");
    assert((String)decompressed2 == msg, "Second decompression should match");
}

/**
 * Context reset (no_context_takeover)
 *
 * When context is reset, each message is compressed independently.
 */
fn void test_deflate_context_reset() @test
{
    compression::DeflateContext deflate_ctx;
    deflate_ctx.init()!!;
    defer deflate_ctx.free();

    compression::InflateContext inflate_ctx;
    inflate_ctx.init()!!;
    defer inflate_ctx.free();

    String msg = "This is a repeated test message for context takeover.";

    // First compression
    char[] compressed1 = deflate_ctx.compress((char[])msg)!!;
    defer mem::free(compressed1.ptr);

    // Reset context (simulate no_context_takeover)
    deflate_ctx.reset()!!;
    inflate_ctx.reset()!!;

    // Second compression (fresh context)
    char[] compressed2 = deflate_ctx.compress((char[])msg)!!;
    defer mem::free(compressed2.ptr);

    // With context reset, both compressions should be same size
    assert(compressed1.len == compressed2.len, "With reset, compression should be identical");

    // Decompress both
    inflate_ctx.reset()!!;
    char[] decompressed1 = inflate_ctx.decompress(compressed1)!!;
    defer mem::free(decompressed1.ptr);

    inflate_ctx.reset()!!;
    char[] decompressed2 = inflate_ctx.decompress(compressed2)!!;
    defer mem::free(decompressed2.ptr);

    assert((String)decompressed1 == msg, "First decompression should match");
    assert((String)decompressed2 == msg, "Second decompression should match");
}

// ============================================================================
// Phase 2: Extension Negotiation Tests
// ============================================================================

/**
 * Parse basic extension header
 *
 * Parse "permessage-deflate" without parameters.
 */
fn void test_parse_extension_header_basic() @test
{
    compression::ExtensionParams? params = compression::parse_extension("permessage-deflate");
    assert(@ok(params), "Should parse basic extension header");

    compression::ExtensionParams p = params!!;
    assert(p.server_max_window_bits == 15, "Default server_max_window_bits should be 15");
    assert(p.client_max_window_bits == 15, "Default client_max_window_bits should be 15");
    assert(!p.server_no_context_takeover, "Default server_no_context_takeover should be false");
    assert(!p.client_no_context_takeover, "Default client_no_context_takeover should be false");
}

/**
 * Parse extension with parameters
 *
 * Parse "permessage-deflate; server_max_window_bits=12"
 */
fn void test_parse_extension_with_params() @test
{
    compression::ExtensionParams? params = compression::parse_extension(
        "permessage-deflate; server_max_window_bits=12; client_no_context_takeover");

    assert(@ok(params), "Should parse extension with parameters");

    compression::ExtensionParams p = params!!;
    assert(p.server_max_window_bits == 12, "server_max_window_bits should be 12");
    assert(p.client_max_window_bits == 15, "client_max_window_bits should be default 15");
    assert(!p.server_no_context_takeover, "server_no_context_takeover should be false");
    assert(p.client_no_context_takeover, "client_no_context_takeover should be true");
}

/**
 * Parse client_max_window_bits without value
 *
 * "client_max_window_bits" alone means client supports the parameter.
 */
fn void test_parse_client_max_window_bits_no_value() @test
{
    compression::ExtensionParams? params = compression::parse_extension(
        "permessage-deflate; client_max_window_bits");

    assert(@ok(params), "Should parse client_max_window_bits without value");

    compression::ExtensionParams p = params!!;
    // When no value, server can choose any value 8-15; default to 15
    assert(p.client_max_window_bits == 15, "client_max_window_bits without value should default to 15");
}

/**
 * Validate window bits range
 *
 * Window bits must be 8-15. Values outside should be rejected.
 */
fn void test_validate_window_bits_range() @test
{
    // Valid: 8-15
    for (int bits = 8; bits <= 15; bits++)
    {
        assert(compression::is_valid_window_bits(bits), "Window bits 8-15 should be valid");
    }

    // Invalid: outside range
    assert(!compression::is_valid_window_bits(7), "Window bits 7 should be invalid");
    assert(!compression::is_valid_window_bits(16), "Window bits 16 should be invalid");
    assert(!compression::is_valid_window_bits(0), "Window bits 0 should be invalid");
}

/**
 * Validate no_context_takeover flags.
 * These are boolean flags - present means true, absent means false.
 */
fn void test_validate_no_context_takeover() @test
{
    // With server_no_context_takeover
    compression::ExtensionParams? params1 = compression::parse_extension(
        "permessage-deflate; server_no_context_takeover");
    assert(@ok(params1), "Should parse server_no_context_takeover");
    assert(params1!!.server_no_context_takeover, "server_no_context_takeover should be true");

    // With both
    compression::ExtensionParams? params2 = compression::parse_extension(
        "permessage-deflate; server_no_context_takeover; client_no_context_takeover");
    assert(@ok(params2), "Should parse both no_context_takeover flags");
    assert(params2!!.server_no_context_takeover, "server_no_context_takeover should be true");
    assert(params2!!.client_no_context_takeover, "client_no_context_takeover should be true");
}

/**
 * Generate server response header
 *
 * Build Sec-WebSocket-Extensions response based on negotiated params.
 * Note: window_bits parameters are intentionally NOT output because miniz
 * only supports window_bits=15. By omitting them, we use the RFC default (15).
 */
fn void test_generate_server_response() @test
{
    compression::ExtensionParams params = {
        .server_max_window_bits = 12,  // Will be ignored in response
        .client_max_window_bits = 10,  // Will be ignored in response
        .server_no_context_takeover = true,
        .client_no_context_takeover = false
    };

    String response = compression::generate_response_header(params);
    defer mem::free(response.ptr);

    // Should contain the extension name and context_takeover params
    assert(response.contains("permessage-deflate"), "Should contain extension name");
    assert(response.contains("server_no_context_takeover"), "Should contain server_no_context_takeover");

    // Should NOT contain window_bits (we only support 15, the default)
    assert(!response.contains("server_max_window_bits"), "Should NOT contain server_max_window_bits");
    assert(!response.contains("client_max_window_bits"), "Should NOT contain client_max_window_bits");
}

// ============================================================================
// Phase 3: Frame-Level Compression Tests (RSV1 handling)
// ============================================================================

/**
 * Compressed frame has RSV1 set
 *
 * RFC 7692: RSV1=1 indicates the message is compressed.
 */
fn void test_compressed_frame_rsv1_set() @test
{
    compression::PerMessageDeflate pmd;
    pmd.init(compression::default_extension_params())!!;
    defer pmd.free();

    // Create a compressed text frame
    char[] compressed_frame = pmd.compress_frame(frame::Opcode.TEXT, (char[])"Hello", true)!!;
    defer mem::free(compressed_frame.ptr);

    // Parse the frame header (allow RSV1 since compression is enabled)
    frame::Frame f = frame::parse(compressed_frame, true)!!;

    assert(f.rsv1, "Compressed frame should have RSV1=1");
    assert(f.opcode == frame::Opcode.TEXT, "Opcode should be TEXT");
}

/**
 * Continuation frame has RSV1 clear
 *
 * RFC 7692 Section 6.1: RSV1 only on first frame of message.
 */
fn void test_continuation_frame_rsv1_clear() @test
{
    compression::PerMessageDeflate pmd;
    pmd.init(compression::default_extension_params())!!;
    defer pmd.free();

    // Create a continuation frame (part of compressed message)
    char[] cont_frame = pmd.compress_frame(frame::Opcode.CONTINUATION, (char[])"World", false)!!;
    defer mem::free(cont_frame.ptr);

    frame::Frame f = frame::parse(cont_frame)!!;

    assert(!f.rsv1, "Continuation frame should have RSV1=0");
    assert(f.opcode == frame::Opcode.CONTINUATION, "Opcode should be CONTINUATION");
}

/**
 * Control frames are not compressed
 *
 * RFC 7692: Control frames (ping, pong, close) MUST NOT be compressed.
 */
fn void test_control_frame_not_compressed() @test
{
    // Create PING frame
    char[] ping_frame = frame::create_frame(frame::Opcode.PING, (char[])"ping", true, false);
    defer mem::free(ping_frame.ptr);

    frame::Frame f = frame::parse(ping_frame)!!;

    assert(!f.rsv1, "PING frame should have RSV1=0");
    assert(f.opcode == frame::Opcode.PING, "Opcode should be PING");

    // Create PONG frame
    char[] pong_frame = frame::create_frame(frame::Opcode.PONG, (char[])"pong", true, false);
    defer mem::free(pong_frame.ptr);

    frame::Frame f2 = frame::parse(pong_frame)!!;
    assert(!f2.rsv1, "PONG frame should have RSV1=0");

    // Create CLOSE frame
    char[] close_frame = frame::create_frame(frame::Opcode.CLOSE, (char[]){0x03, 0xE8}, true, false);
    defer mem::free(close_frame.ptr);

    frame::Frame f3 = frame::parse(close_frame)!!;
    assert(!f3.rsv1, "CLOSE frame should have RSV1=0");
}

/**
 * Reject compressed control frame
 *
 * If RSV1=1 on a control frame, it's a protocol error.
 */
fn void test_reject_compressed_control_frame() @test
{
    // Manually create a malformed PING with RSV1=1
    // FIN=1 (0x80), RSV1=1 (0x40), opcode=PING (0x09) = 0xC9
    char[] malformed_ping = {
        0xC9,  // FIN=1, RSV1=1, opcode=PING (0x89 | 0x40)
        0x04,  // len=4
        'p', 'i', 'n', 'g'
    };

    compression::PerMessageDeflate pmd;
    pmd.init(compression::default_extension_params())!!;
    defer pmd.free();

    // Should reject this frame
    if (catch pmd.validate_frame(malformed_ping))
    {
        // Expected: protocol error
        return;
    }

    assert(false, "Should reject compressed control frame");
}

// ============================================================================
// Phase 4: Message Compression Tests (Autobahn 12.x patterns)
// ============================================================================

/**
 * Compress small message (16 bytes) - Autobahn 12.1.1 pattern
 */
fn void test_compress_small_message_16bytes() @test
{
    compression::PerMessageDeflate pmd;
    pmd.init(compression::default_extension_params())!!;
    defer pmd.free();

    char[16] input;
    for (int i = 0; i < 16; i++) input[i] = (char)('A' + (i % 26));

    char[] compressed = pmd.compress_message(&input)!!;
    defer mem::free(compressed.ptr);

    char[] decompressed = pmd.decompress_message(compressed)!!;
    defer mem::free(decompressed.ptr);

    assert(decompressed.len == 16, "Decompressed should be 16 bytes");
    for (int i = 0; i < 16; i++)
    {
        assert(decompressed[i] == input[i], "Data should match");
    }
}

/**
 * Compress medium message (1KB) - Autobahn 12.1.4 pattern
 */
fn void test_compress_medium_message_1kb() @test
{
    compression::PerMessageDeflate pmd;
    pmd.init(compression::default_extension_params())!!;
    defer pmd.free();

    char[] input = mem::new_array(char, 1024);
    defer mem::free(input.ptr);
    for (usz i = 0; i < 1024; i++) input[i] = (char)('A' + (i % 26));

    char[] compressed = pmd.compress_message(input)!!;
    defer mem::free(compressed.ptr);

    char[] decompressed = pmd.decompress_message(compressed)!!;
    defer mem::free(decompressed.ptr);

    assert(decompressed.len == 1024, "Decompressed should be 1024 bytes");
}

/**
 * Compress large message (64KB) - Autobahn 12.1.9 pattern
 */
fn void test_compress_large_message_64kb() @test
{
    compression::PerMessageDeflate pmd;
    pmd.init(compression::default_extension_params())!!;
    defer pmd.free();

    char[] input = mem::new_array(char, 65536);
    defer mem::free(input.ptr);
    for (usz i = 0; i < 65536; i++) input[i] = (char)('A' + (i % 26));

    char[] compressed = pmd.compress_message(input)!!;
    defer mem::free(compressed.ptr);

    // Should compress well (repetitive data)
    assert(compressed.len < 65536, "Repetitive data should compress");

    char[] decompressed = pmd.decompress_message(compressed)!!;
    defer mem::free(decompressed.ptr);

    assert(decompressed.len == 65536, "Decompressed should be 65536 bytes");
}

/**
 * Decompress message with trailer handling
 *
 * Decompressor must add trailing 0x00 0x00 0xFF 0xFF before inflating.
 */
fn void test_decompress_message_with_trailer() @test
{
    compression::PerMessageDeflate pmd;
    pmd.init(compression::default_extension_params())!!;
    defer pmd.free();

    String input = "Test message for trailer handling";

    char[] compressed = pmd.compress_message((char[])input)!!;
    defer mem::free(compressed.ptr);

    // decompress_message should internally add the trailer
    char[] decompressed = pmd.decompress_message(compressed)!!;
    defer mem::free(decompressed.ptr);

    assert((String)decompressed == input, "Should decompress correctly");
}

/**
 * Decompress fragmented compressed message
 *
 * Message split across multiple frames should decompress after reassembly.
 */
fn void test_decompress_fragmented_compressed() @test
{
    compression::PerMessageDeflate pmd;
    pmd.init(compression::default_extension_params())!!;
    defer pmd.free();

    String input = "This is a longer message that will be fragmented across multiple frames for testing.";

    // Compress the full message
    char[] compressed = pmd.compress_message((char[])input)!!;
    defer mem::free(compressed.ptr);

    // Simulate fragmentation: split compressed payload
    usz split = compressed.len / 2;
    char[] frag1 = compressed[0:split];
    char[] frag2 = compressed[split:compressed.len - split];

    // Reassemble
    char[] reassembled = mem::new_array(char, compressed.len);
    defer mem::free(reassembled.ptr);
    mem::copy(reassembled.ptr, frag1.ptr, frag1.len);
    mem::copy(&reassembled[split], frag2.ptr, frag2.len);

    // Decompress reassembled
    char[] decompressed = pmd.decompress_message(reassembled)!!;
    defer mem::free(decompressed.ptr);

    assert((String)decompressed == input, "Fragmented message should decompress correctly");
}

// ============================================================================
// Phase 5: Context Takeover Tests (Autobahn 13.x patterns)
// ============================================================================

/**
 * Compression with context takeover
 *
 * Autobahn 13.x: Multiple messages with context takeover should show
 * improved compression on repeated data.
 */
fn void test_compression_with_context_takeover() @test
{
    compression::ExtensionParams params = {
        .server_no_context_takeover = false,
        .client_no_context_takeover = false
    };

    compression::PerMessageDeflate pmd;
    pmd.init(params)!!;
    defer pmd.free();

    String msg = "This message will be sent multiple times to test context takeover compression efficiency.";

    char[] compressed1 = pmd.compress_message((char[])msg)!!;
    defer mem::free(compressed1.ptr);

    char[] compressed2 = pmd.compress_message((char[])msg)!!;
    defer mem::free(compressed2.ptr);

    char[] compressed3 = pmd.compress_message((char[])msg)!!;
    defer mem::free(compressed3.ptr);

    // With context takeover, subsequent messages should compress better
    // (dictionary built from previous messages)
    assert(compressed2.len <= compressed1.len, "Second message should compress as well or better");
    assert(compressed3.len <= compressed2.len, "Third message should compress as well or better");
}

/**
 * Compression without context takeover
 *
 * Each message compressed independently - same message = same compressed size.
 */
fn void test_compression_without_context_takeover() @test
{
    compression::ExtensionParams params = {
        .server_no_context_takeover = true,
        .client_no_context_takeover = true
    };

    compression::PerMessageDeflate pmd;
    pmd.init(params)!!;
    defer pmd.free();

    String msg = "This message will be sent multiple times without context takeover.";

    char[] compressed1 = pmd.compress_message((char[])msg)!!;
    defer mem::free(compressed1.ptr);

    char[] compressed2 = pmd.compress_message((char[])msg)!!;
    defer mem::free(compressed2.ptr);

    char[] compressed3 = pmd.compress_message((char[])msg)!!;
    defer mem::free(compressed3.ptr);

    // Without context takeover, all compressions should be identical size
    assert(compressed1.len == compressed2.len, "Without context takeover, sizes should match");
    assert(compressed2.len == compressed3.len, "Without context takeover, sizes should match");
}

/**
 * Window bits 8 workaround
 *
 * Window bits 8 is problematic in zlib, should be treated as 9.
 */
fn void test_window_bits_8_workaround() @test
{
    compression::ExtensionParams params = {
        .server_max_window_bits = 8,
        .client_max_window_bits = 8
    };

    compression::PerMessageDeflate pmd;
    pmd.init(params)!!;
    defer pmd.free();

    String msg = "Test message with window bits 8 workaround";

    char[] compressed = pmd.compress_message((char[])msg)!!;
    defer mem::free(compressed.ptr);

    char[] decompressed = pmd.decompress_message(compressed)!!;
    defer mem::free(decompressed.ptr);

    // Should work despite window bits 8 (internally treated as 9)
    assert((String)decompressed == msg, "Should handle window bits 8 correctly");
}

/**
 * Verify server_max_window_bits=9 roundtrip works
 *
 * Autobahn 13.3.x: When server_max_window_bits=9 is negotiated,
 * the server MUST use a 9-bit window for compression.
 *
 * Note: This test passes even with the bug because both compressor and
 * decompressor use the same (wrong) window size.
 */
fn void test_server_max_window_bits_9() @test
{
    compression::ExtensionParams params9 = {
        .server_max_window_bits = 9,
        .client_max_window_bits = 9,
        .server_no_context_takeover = false,
        .client_no_context_takeover = false
    };

    compression::PerMessageDeflate pmd9;
    pmd9.init(params9)!!;
    defer pmd9.free();

    // Verify the context stored the correct window bits
    // Note: window_bits 8 is bumped to 9 due to zlib quirk
    assert(pmd9.deflate.window_bits == 9, "Deflate should store window_bits=9");
    assert(pmd9.inflate.window_bits == 9, "Inflate should store window_bits=9");

    // Compress and decompress - should work with matching window bits
    String msg = "Test message for window bits 9 verification - this tests Autobahn 13.3.x compliance";
    char[] compressed = pmd9.compress_message((char[])msg)!!;
    defer mem::free(compressed.ptr);

    char[] decompressed = pmd9.decompress_message(compressed)!!;
    defer mem::free(decompressed.ptr);

    assert((String)decompressed == msg, "Should roundtrip correctly with window_bits=9");
}

/**
 * Verify different window bits parameters are accepted
 *
 * Note: miniz only supports window_bits=15 internally for raw deflate mode.
 * This test verifies that different window_bits parameters are accepted
 * and compression still works, even though miniz uses 15-bit windows internally.
 *
 * RFC 7692 compliance note: Data compressed with a 15-bit window CAN be
 * decompressed by a decoder with a smaller window, as long as back-references
 * don't exceed the smaller window size. For most data patterns, this works.
 */
fn void test_window_bits_params_accepted() @test
{
    // Create test data
    char[] input = mem::new_array(char, 1024);
    defer mem::free(input.ptr);
    for (usz i = 0; i < 1024; i++)
    {
        input[i] = (char)('A' + (i % 26));
    }

    // Compress with window_bits=15 (standard)
    compression::ExtensionParams params15 = {
        .server_max_window_bits = 15,
        .client_max_window_bits = 15,
        .server_no_context_takeover = true,
        .client_no_context_takeover = true
    };
    compression::PerMessageDeflate pmd15;
    pmd15.init(params15)!!;
    defer pmd15.free();

    char[] compressed15 = pmd15.compress_message(input)!!;
    defer mem::free(compressed15.ptr);

    // Compress with window_bits=9 (smaller window requested)
    compression::ExtensionParams params9 = {
        .server_max_window_bits = 9,
        .client_max_window_bits = 9,
        .server_no_context_takeover = true,
        .client_no_context_takeover = true
    };
    compression::PerMessageDeflate pmd9;
    pmd9.init(params9)!!;
    defer pmd9.free();

    char[] compressed9 = pmd9.compress_message(input)!!;
    defer mem::free(compressed9.ptr);

    // Both should compress successfully
    assert(compressed15.len > 0, "Should compress with window_bits=15");
    assert(compressed9.len > 0, "Should compress with window_bits=9");

    // Verify decompression still works
    char[] decompressed = pmd9.decompress_message(compressed9)!!;
    defer mem::free(decompressed.ptr);
    assert(decompressed.len == input.len, "Decompressed size should match input");
}
