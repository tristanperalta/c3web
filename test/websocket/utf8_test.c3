/**
 * UTF-8 Validator Tests for WebSocket
 *
 * RFC 3629 and RFC 6455 §8.1 require strict UTF-8 validation for text frames.
 * These tests verify:
 * - Valid UTF-8 sequences (1-4 bytes)
 * - Invalid encodings (overlong, surrogates, too large)
 * - Incremental/streaming validation
 * - State tracking across chunks
 */
module c3web::test::websocket::utf8_test;

import c3web::websocket::utf8;
import std::io;

/**
 * Test 1: Valid ASCII (1-byte sequences)
 */
fn void test_valid_ascii() @test
{
    utf8::Utf8Validator validator;
    validator.init();

    char[] data = "Hello";
    assert(validator.validate_incremental(data), "ASCII should be valid UTF-8");
    assert(validator.is_complete(), "ASCII should be in complete state");
}

/**
 * Test 2: Valid 2-byte UTF-8 sequence
 * é = U+00E9 = 0xC3 0xA9
 */
fn void test_valid_multibyte_2byte() @test
{
    utf8::Utf8Validator validator;
    validator.init();

    char[] data = {0xC3, 0xA9};  // "é"
    assert(validator.validate_incremental(data), "2-byte UTF-8 should be valid");
    assert(validator.is_complete(), "Should be in complete state");
}

/**
 * Test 3: Valid 3-byte UTF-8 sequence
 * 世 = U+4E16 = 0xE4 0xB8 0x96
 */
fn void test_valid_multibyte_3byte() @test
{
    utf8::Utf8Validator validator;
    validator.init();

    char[] data = {0xE4, 0xB8, 0x96};  // "世"
    assert(validator.validate_incremental(data), "3-byte UTF-8 should be valid");
    assert(validator.is_complete(), "Should be in complete state");
}

/**
 * Test 4: Valid 4-byte UTF-8 sequence
 * 👋 = U+1F44B = 0xF0 0x9F 0x91 0x8B
 */
fn void test_valid_multibyte_4byte() @test
{
    utf8::Utf8Validator validator;
    validator.init();

    char[] data = {0xF0, 0x9F, 0x91, 0x8B};  // "👋" emoji
    assert(validator.validate_incremental(data), "4-byte UTF-8 should be valid");
    assert(validator.is_complete(), "Should be in complete state");
}

/**
 * Test 5: Invalid continuation byte without lead byte
 * Continuation bytes (0x80-0xBF) cannot appear without a lead byte
 */
fn void test_invalid_continuation() @test
{
    utf8::Utf8Validator validator;
    validator.init();

    char[] data = {0x80};  // Bare continuation byte
    assert(!validator.validate_incremental(data), "Bare continuation should be invalid");
}

/**
 * Test 6: Invalid overlong encoding
 * "A" (U+0041) as 2-byte: 0xC1 0x81 (should be 1-byte 0x41)
 * Overlong encodings are security vulnerabilities
 */
fn void test_invalid_overlong_encoding() @test
{
    utf8::Utf8Validator validator;
    validator.init();

    char[] data = {0xC1, 0x81};  // Overlong encoding of "A"
    assert(!validator.validate_incremental(data), "Overlong encoding should be rejected");
}

/**
 * Test 7: Invalid UTF-8 encoding of surrogate (low)
 * U+D800 = 0xED 0xA0 0x80 (surrogate range 0xD800-0xDFFF is invalid)
 * RFC 3629 forbids UTF-8 encodings of surrogates
 */
fn void test_invalid_surrogate_d800() @test
{
    utf8::Utf8Validator validator;
    validator.init();

    char[] data = {0xED, 0xA0, 0x80};  // UTF-8 encoding of U+D800
    assert(!validator.validate_incremental(data), "Surrogate U+D800 should be rejected");
}

/**
 * Test 8: Invalid UTF-8 encoding of surrogate (high)
 * U+DFFF = 0xED 0xBF 0xBF (end of surrogate range)
 */
fn void test_invalid_surrogate_dfff() @test
{
    utf8::Utf8Validator validator;
    validator.init();

    char[] data = {0xED, 0xBF, 0xBF};  // UTF-8 encoding of U+DFFF
    assert(!validator.validate_incremental(data), "Surrogate U+DFFF should be rejected");
}

/**
 * Test 9: Invalid code point > U+10FFFF
 * U+110000 = 0xF4 0x90 0x80 0x80 (beyond valid Unicode range)
 */
fn void test_invalid_too_large() @test
{
    utf8::Utf8Validator validator;
    validator.init();

    char[] data = {0xF4, 0x90, 0x80, 0x80};  // U+110000 (too large)
    assert(!validator.validate_incremental(data), "Code point > U+10FFFF should be rejected");
}

/**
 * Test 10: Incomplete UTF-8 sequence
 * First byte of 2-byte sequence without continuation
 */
fn void test_incomplete_sequence() @test
{
    utf8::Utf8Validator validator;
    validator.init();

    char[] data = {0xC3};  // Start of 2-byte sequence, no continuation
    assert(validator.validate_incremental(data), "Incomplete sequence should not error yet");
    assert(!validator.is_complete(), "Should NOT be in complete state (waiting for continuation)");
}

/**
 * Test 11: Incremental validation across chunks
 * Multi-byte sequence split across multiple calls (like WebSocket frames)
 * Feed "世" as two chunks: [0xE4] then [0xB8, 0x96]
 */
fn void test_incremental_validation() @test
{
    utf8::Utf8Validator validator;
    validator.init();

    // First chunk: lead byte only
    char[] chunk1 = {0xE4};
    assert(validator.validate_incremental(chunk1), "First chunk should be valid (incomplete)");
    assert(!validator.is_complete(), "Should be waiting for more bytes");

    // Second chunk: continuation bytes
    char[] chunk2 = {0xB8, 0x96};
    assert(validator.validate_incremental(chunk2), "Second chunk should complete sequence");
    assert(validator.is_complete(), "Should now be in complete state");
}

/**
 * Test 12: Validator reset functionality
 * After incomplete sequence, reset should restore ACCEPT state
 */
fn void test_validator_reset() @test
{
    utf8::Utf8Validator validator;
    validator.init();

    // Create incomplete state
    char[] incomplete = {0xC3};
    validator.validate_incremental(incomplete);
    assert(!validator.is_complete(), "Should be incomplete");

    // Reset
    validator.reset();
    assert(validator.is_complete(), "After reset should be in ACCEPT state");

    // Validate new data
    char[] data = "Hello";
    assert(validator.validate_incremental(data), "Should work after reset");
    assert(validator.is_complete(), "Should be complete");
}
