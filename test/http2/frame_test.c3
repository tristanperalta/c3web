/**
 * HTTP/2 Frame Validation Tests
 * Tests for RFC 9113 Section 4 compliance
 */
module c3web::test::http2::frame_test;

import c3web::http2::frame;
import c3web::http2::stream;
import std::io;

/**
 * Test default settings
 */
fn void test_default_settings() @test
{
    frame::ConnectionSettings settings = frame::default_settings();

    assert(settings.max_frame_size == 16384);
    assert(settings.initial_window_size == 65535);
    assert(settings.enable_push == false);

    io::printn("[OK] Default settings");
}

/**
 * Test frame size validation - within limits
 */
fn void test_frame_size_within_limits() @test
{
    frame::ConnectionSettings settings = frame::default_settings();

    frame::FrameHeader header = (frame::FrameHeader){
        .length = 1000,
        .type = stream::FrameType.DATA,
        .flags = 0,
        .stream_id = 1,
    };

    // Should succeed - within max frame size
    frame::validate_frame_size(&header, &settings)!!;

    io::printn("[OK] Frame size within limits");
}

/**
 * Test frame size validation - exceeds limit
 */
fn void test_frame_size_exceeds_limit() @test
{
    frame::ConnectionSettings settings = frame::default_settings();

    frame::FrameHeader header = (frame::FrameHeader){
        .length = 20000,  // Exceeds default 16384
        .type = stream::FrameType.DATA,
        .flags = 0,
        .stream_id = 1,
    };

    // Should fail - exceeds max frame size
    assert(@catch(frame::validate_frame_size(&header, &settings)) == frame::FRAME_SIZE_ERROR);

    io::printn("[OK] Frame size exceeds limit");
}

/**
 * Test SETTINGS frame exempt from max frame size
 */
fn void test_settings_frame_size_exempt() @test
{
    frame::ConnectionSettings settings = frame::default_settings();

    frame::FrameHeader header = (frame::FrameHeader){
        .length = 20000,  // Exceeds default but OK for SETTINGS
        .type = stream::FrameType.SETTINGS,
        .flags = 0,
        .stream_id = 0,
    };

    // SETTINGS frames are exempt from SETTINGS_MAX_FRAME_SIZE
    frame::validate_frame_size(&header, &settings)!!;

    io::printn("[OK] SETTINGS frame size exempt");
}

/**
 * Test stream ID validation for connection-level frames
 */
fn void test_connection_level_frames_stream_id_zero() @test
{
    // SETTINGS must have stream ID 0
    frame::FrameHeader settings_header = (frame::FrameHeader){
        .length = 0,
        .type = stream::FrameType.SETTINGS,
        .flags = 0,
        .stream_id = 0,
    };
    frame::validate_stream_id_for_frame_type(&settings_header)!!;

    // PING must have stream ID 0
    frame::FrameHeader ping_header = (frame::FrameHeader){
        .length = 8,
        .type = stream::FrameType.PING,
        .flags = 0,
        .stream_id = 0,
    };
    frame::validate_stream_id_for_frame_type(&ping_header)!!;

    // GOAWAY must have stream ID 0
    frame::FrameHeader goaway_header = (frame::FrameHeader){
        .length = 8,
        .type = stream::FrameType.GOAWAY,
        .flags = 0,
        .stream_id = 0,
    };
    frame::validate_stream_id_for_frame_type(&goaway_header)!!;

    io::printn("[OK] Connection-level frames have stream ID 0");
}

/**
 * Test stream ID validation - connection frame with non-zero stream ID
 */
fn void test_connection_frame_nonzero_stream_id_fails() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 0,
        .type = stream::FrameType.SETTINGS,
        .flags = 0,
        .stream_id = 1,  // Invalid - must be 0
    };

    assert(@catch(frame::validate_stream_id_for_frame_type(&header)) == frame::PROTOCOL_ERROR);

    io::printn("[OK] Connection frame with non-zero stream ID fails");
}

/**
 * Test stream ID validation for stream-level frames
 */
fn void test_stream_level_frames_nonzero_stream_id() @test
{
    // DATA must have stream ID > 0
    frame::FrameHeader data_header = (frame::FrameHeader){
        .length = 0,
        .type = stream::FrameType.DATA,
        .flags = 0,
        .stream_id = 1,
    };
    frame::validate_stream_id_for_frame_type(&data_header)!!;

    // HEADERS must have stream ID > 0
    frame::FrameHeader headers_header = (frame::FrameHeader){
        .length = 0,
        .type = stream::FrameType.HEADERS,
        .flags = 0,
        .stream_id = 1,
    };
    frame::validate_stream_id_for_frame_type(&headers_header)!!;

    io::printn("[OK] Stream-level frames have stream ID > 0");
}

/**
 * Test stream ID validation - stream frame with zero stream ID
 */
fn void test_stream_frame_zero_stream_id_fails() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 0,
        .type = stream::FrameType.DATA,
        .flags = 0,
        .stream_id = 0,  // Invalid - must be > 0
    };

    assert(@catch(frame::validate_stream_id_for_frame_type(&header)) == frame::PROTOCOL_ERROR);

    io::printn("[OK] Stream frame with zero stream ID fails");
}

/**
 * Test DATA frame validation - no padding
 */
fn void test_data_frame_no_padding() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 100,
        .type = stream::FrameType.DATA,
        .flags = 0,  // No PADDED flag
        .stream_id = 1,
    };

    char[100] payload;
    frame::validate_data_frame(&header, &payload)!!;

    io::printn("[OK] DATA frame without padding");
}

/**
 * Test DATA frame validation - with valid padding
 */
fn void test_data_frame_with_padding() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 10,
        .type = stream::FrameType.DATA,
        .flags = (char)frame::FrameFlags.PADDED,
        .stream_id = 1,
    };

    // Payload: [pad_length=5] [data...] [padding...]
    char[10] payload = { 5, 1, 2, 3, 4, 0, 0, 0, 0, 0 };
    frame::validate_data_frame(&header, &payload)!!;

    io::printn("[OK] DATA frame with valid padding");
}

/**
 * Test DATA frame validation - padding exceeds payload
 */
fn void test_data_frame_padding_exceeds_payload() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 10,
        .type = stream::FrameType.DATA,
        .flags = (char)frame::FrameFlags.PADDED,
        .stream_id = 1,
    };

    // Payload: pad_length=20 exceeds payload length of 10
    char[10] payload = { 20, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    assert(@catch(frame::validate_data_frame(&header, &payload)) == frame::PROTOCOL_ERROR);

    io::printn("[OK] DATA frame padding exceeds payload fails");
}

/**
 * Test HEADERS frame validation - with PRIORITY flag
 */
fn void test_headers_frame_with_priority() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 10,
        .type = stream::FrameType.HEADERS,
        .flags = (char)frame::FrameFlags.PRIORITY,
        .stream_id = 1,
    };

    // Payload: [E + stream_dep (4 bytes)] [weight (1 byte)] [header block...]
    char[10] payload = { 0, 0, 0, 0, 16, 1, 2, 3, 4, 5 };
    frame::validate_headers_frame(&header, &payload)!!;

    io::printn("[OK] HEADERS frame with PRIORITY flag");
}

/**
 * Test HEADERS frame validation - PRIORITY flag but insufficient payload
 */
fn void test_headers_frame_priority_insufficient_payload() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 3,
        .type = stream::FrameType.HEADERS,
        .flags = (char)frame::FrameFlags.PRIORITY,
        .stream_id = 1,
    };

    // Payload too small for PRIORITY (needs 5 bytes)
    char[3] payload = { 0, 0, 0 };
    assert(@catch(frame::validate_headers_frame(&header, &payload)) == frame::PROTOCOL_ERROR);

    io::printn("[OK] HEADERS frame PRIORITY insufficient payload fails");
}

/**
 * Test PRIORITY frame validation - valid
 */
fn void test_priority_frame_valid() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 5,
        .type = stream::FrameType.PRIORITY,
        .flags = 0,
        .stream_id = 3,
    };

    // Payload: [E + stream_dep (4 bytes)] [weight (1 byte)]
    // Stream dependency = 1 (different from stream ID 3)
    char[5] payload = { 0, 0, 0, 1, 16 };
    frame::validate_priority_frame(&header, &payload)!!;

    io::printn("[OK] PRIORITY frame valid");
}

/**
 * Test PRIORITY frame validation - self dependency
 */
fn void test_priority_frame_self_dependency() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 5,
        .type = stream::FrameType.PRIORITY,
        .flags = 0,
        .stream_id = 3,
    };

    // Payload: stream dependency = 3 (same as stream ID)
    char[5] payload = { 0, 0, 0, 3, 16 };
    assert(@catch(frame::validate_priority_frame(&header, &payload)) == frame::PROTOCOL_ERROR);

    io::printn("[OK] PRIORITY frame self-dependency fails");
}

/**
 * Test PRIORITY frame validation - wrong size
 */
fn void test_priority_frame_wrong_size() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 10,  // Must be exactly 5
        .type = stream::FrameType.PRIORITY,
        .flags = 0,
        .stream_id = 3,
    };

    char[10] payload;
    assert(@catch(frame::validate_priority_frame(&header, &payload)) == frame::FRAME_SIZE_ERROR);

    io::printn("[OK] PRIORITY frame wrong size fails");
}

/**
 * Test RST_STREAM frame validation - valid
 */
fn void test_rst_stream_frame_valid() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 4,
        .type = stream::FrameType.RST_STREAM,
        .flags = 0,
        .stream_id = 1,
    };

    // Payload: 4-byte error code
    char[4] payload = { 0, 0, 0, 0 };
    frame::validate_rst_stream_frame(&header, &payload)!!;

    io::printn("[OK] RST_STREAM frame valid");
}

/**
 * Test RST_STREAM frame validation - wrong size
 */
fn void test_rst_stream_frame_wrong_size() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 5,  // Must be exactly 4
        .type = stream::FrameType.RST_STREAM,
        .flags = 0,
        .stream_id = 1,
    };

    char[5] payload;
    assert(@catch(frame::validate_rst_stream_frame(&header, &payload)) == frame::FRAME_SIZE_ERROR);

    io::printn("[OK] RST_STREAM frame wrong size fails");
}

/**
 * Test SETTINGS frame validation - valid
 */
fn void test_settings_frame_valid() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 12,  // 2 settings * 6 bytes each
        .type = stream::FrameType.SETTINGS,
        .flags = 0,
        .stream_id = 0,
    };

    // Two settings: HEADER_TABLE_SIZE=4096, ENABLE_PUSH=0
    char[12] payload = {
        0, 1,  // SETTINGS_HEADER_TABLE_SIZE
        0, 0, 0x10, 0,  // value = 4096
        0, 2,  // SETTINGS_ENABLE_PUSH
        0, 0, 0, 0,  // value = 0
    };
    frame::validate_settings_frame(&header, &payload)!!;

    io::printn("[OK] SETTINGS frame valid");
}

/**
 * Test SETTINGS frame validation - ACK with payload
 */
fn void test_settings_frame_ack_with_payload() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 6,  // Non-zero length
        .type = stream::FrameType.SETTINGS,
        .flags = (char)frame::FrameFlags.ACK,
        .stream_id = 0,
    };

    char[6] payload;
    assert(@catch(frame::validate_settings_frame(&header, &payload)) == frame::FRAME_SIZE_ERROR);

    io::printn("[OK] SETTINGS ACK with payload fails");
}

/**
 * Test SETTINGS frame validation - not multiple of 6
 */
fn void test_settings_frame_wrong_size() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 7,  // Not multiple of 6
        .type = stream::FrameType.SETTINGS,
        .flags = 0,
        .stream_id = 0,
    };

    char[7] payload;
    assert(@catch(frame::validate_settings_frame(&header, &payload)) == frame::FRAME_SIZE_ERROR);

    io::printn("[OK] SETTINGS frame not multiple of 6 fails");
}

/**
 * Test setting value validation - ENABLE_PUSH invalid value
 */
fn void test_setting_enable_push_invalid() @test
{
    // ENABLE_PUSH must be 0 or 1
    assert(@catch(frame::validate_setting_value(0x2, 2)) == frame::PROTOCOL_ERROR);
    assert(@catch(frame::validate_setting_value(0x2, 100)) == frame::PROTOCOL_ERROR);

    io::printn("[OK] ENABLE_PUSH invalid value fails");
}

/**
 * Test setting value validation - INITIAL_WINDOW_SIZE exceeds max
 */
fn void test_setting_initial_window_size_exceeds_max() @test
{
    // INITIAL_WINDOW_SIZE must not exceed 2^31-1 (RFC 9113 §6.5.2: FLOW_CONTROL_ERROR)
    assert(@catch(frame::validate_setting_value(0x4, 0x80000000)) == frame::FLOW_CONTROL_ERROR);

    io::printn("[OK] INITIAL_WINDOW_SIZE exceeds max fails");
}

/**
 * Test setting value validation - MAX_FRAME_SIZE out of range
 */
fn void test_setting_max_frame_size_out_of_range() @test
{
    // MAX_FRAME_SIZE must be between 16384 and 16777215
    assert(@catch(frame::validate_setting_value(0x5, 1000)) == frame::PROTOCOL_ERROR);
    assert(@catch(frame::validate_setting_value(0x5, 16777216)) == frame::PROTOCOL_ERROR);

    io::printn("[OK] MAX_FRAME_SIZE out of range fails");
}

/**
 * Test PING frame validation - valid
 */
fn void test_ping_frame_valid() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 8,
        .type = stream::FrameType.PING,
        .flags = 0,
        .stream_id = 0,
    };

    char[8] payload = { 1, 2, 3, 4, 5, 6, 7, 8 };
    frame::validate_ping_frame(&header, &payload)!!;

    io::printn("[OK] PING frame valid");
}

/**
 * Test PING frame validation - wrong size
 */
fn void test_ping_frame_wrong_size() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 10,  // Must be exactly 8
        .type = stream::FrameType.PING,
        .flags = 0,
        .stream_id = 0,
    };

    char[10] payload;
    assert(@catch(frame::validate_ping_frame(&header, &payload)) == frame::FRAME_SIZE_ERROR);

    io::printn("[OK] PING frame wrong size fails");
}

/**
 * Test GOAWAY frame validation - valid
 */
fn void test_goaway_frame_valid() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 10,  // 8 bytes min + 2 bytes debug data
        .type = stream::FrameType.GOAWAY,
        .flags = 0,
        .stream_id = 0,
    };

    // Payload: last stream ID (4 bytes) + error code (4 bytes) + debug data
    char[10] payload = { 0, 0, 0, 1, 0, 0, 0, 0, 'O', 'K' };
    frame::validate_goaway_frame(&header, &payload)!!;

    io::printn("[OK] GOAWAY frame valid");
}

/**
 * Test GOAWAY frame validation - too small
 */
fn void test_goaway_frame_too_small() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 5,  // Must be at least 8
        .type = stream::FrameType.GOAWAY,
        .flags = 0,
        .stream_id = 0,
    };

    char[5] payload;
    assert(@catch(frame::validate_goaway_frame(&header, &payload)) == frame::FRAME_SIZE_ERROR);

    io::printn("[OK] GOAWAY frame too small fails");
}

/**
 * Test WINDOW_UPDATE frame validation - valid
 */
fn void test_window_update_frame_valid() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 4,
        .type = stream::FrameType.WINDOW_UPDATE,
        .flags = 0,
        .stream_id = 1,
    };

    // Payload: window size increment = 1000
    char[4] payload = { 0, 0, 0x03, 0xE8 };
    frame::validate_window_update_frame(&header, &payload)!!;

    io::printn("[OK] WINDOW_UPDATE frame valid");
}

/**
 * Test WINDOW_UPDATE frame validation - zero increment
 */
fn void test_window_update_frame_zero_increment() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 4,
        .type = stream::FrameType.WINDOW_UPDATE,
        .flags = 0,
        .stream_id = 1,
    };

    // Payload: window size increment = 0 (invalid)
    char[4] payload = { 0, 0, 0, 0 };
    assert(@catch(frame::validate_window_update_frame(&header, &payload)) == frame::PROTOCOL_ERROR);

    io::printn("[OK] WINDOW_UPDATE zero increment fails");
}

/**
 * Test WINDOW_UPDATE frame validation - wrong size
 */
fn void test_window_update_frame_wrong_size() @test
{
    frame::FrameHeader header = (frame::FrameHeader){
        .length = 5,  // Must be exactly 4
        .type = stream::FrameType.WINDOW_UPDATE,
        .flags = 0,
        .stream_id = 1,
    };

    char[5] payload;
    assert(@catch(frame::validate_window_update_frame(&header, &payload)) == frame::FRAME_SIZE_ERROR);

    io::printn("[OK] WINDOW_UPDATE wrong size fails");
}

/**
 * Test padding extraction - no padding
 */
fn void test_extract_padding_none() @test
{
    char flags = 0;  // No PADDED flag
    char[10] payload = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    char[] result = frame::extract_padding(flags, &payload)!!;
    assert(result.len == 10);
    assert(result[0] == 1);

    io::printn("[OK] Extract padding - none");
}

/**
 * Test padding extraction - with padding
 */
fn void test_extract_padding_with_padding() @test
{
    char flags = (char)frame::FrameFlags.PADDED;
    // Payload: [pad_length=3] [data: 1,2,3,4,5,6] [padding: 0,0,0]
    char[10] payload = { 3, 1, 2, 3, 4, 5, 6, 0, 0, 0 };

    char[] result = frame::extract_padding(flags, &payload)!!;
    assert(result.len == 6);
    assert(result[0] == 1);
    assert(result[5] == 6);

    io::printn("[OK] Extract padding - with padding");
}

/**
 * Test has_flag helper
 */
fn void test_has_flag() @test
{
    char flags = (char)frame::FrameFlags.END_STREAM | (char)frame::FrameFlags.PADDED;

    assert(frame::has_flag(flags, frame::FrameFlags.END_STREAM));
    assert(frame::has_flag(flags, frame::FrameFlags.PADDED));
    assert(!frame::has_flag(flags, frame::FrameFlags.END_HEADERS));

    io::printn("[OK] has_flag helper");
}
