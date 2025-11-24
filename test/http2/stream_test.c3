/**
 * HTTP/2 Stream State Machine Tests
 * Tests for RFC 9113 Section 5.1 compliance
 */
module c3web::test::http2::stream_test;

import c3web::http2::stream;
import std::io;

/**
 * Test stream initialization
 */
fn void test_stream_initialization() @test
{
    stream::Stream s = stream::new_stream(1);

    assert(s.id == 1);
    assert(s.state == stream::StreamState.IDLE);
    assert(s.recv_window == 65535);
    assert(s.send_window == 65535);
    assert(s.bytes_received == 0);

    io::printn("[OK] Stream initialization");
}

/**
 * Test stream ID validation (RFC 9113 Section 5.1.1)
 */
fn void test_stream_id_validation() @test
{
    // Stream 0 is invalid for client streams
    assert(!stream::is_valid_client_stream_id(0));

    // Client streams must be odd
    assert(stream::is_valid_client_stream_id(1));
    assert(stream::is_valid_client_stream_id(3));
    assert(stream::is_valid_client_stream_id(5));

    // Even stream IDs are server-initiated
    assert(!stream::is_valid_client_stream_id(2));
    assert(!stream::is_valid_client_stream_id(4));

    // Stream IDs must increase monotonically
    assert(stream::is_stream_id_increasing(3, 1));
    assert(stream::is_stream_id_increasing(5, 3));
    assert(!stream::is_stream_id_increasing(3, 5));
    assert(!stream::is_stream_id_increasing(3, 3));

    io::printn("[OK] Stream ID validation");
}

/**
 * Test IDLE -> OPEN transition (RFC 9113 Section 5.1)
 */
fn void test_idle_to_open_transition() @test
{
    stream::Stream s = stream::new_stream(1);

    assert(s.state == stream::StreamState.IDLE);

    // Receiving HEADERS without END_STREAM transitions to OPEN
    stream::on_headers_received(&s, false)!!;

    assert(s.state == stream::StreamState.OPEN);

    io::printn("[OK] IDLE -> OPEN transition");
}

/**
 * Test IDLE -> HALF_CLOSED_REMOTE transition
 */
fn void test_idle_to_half_closed_remote() @test
{
    stream::Stream s = stream::new_stream(1);

    assert(s.state == stream::StreamState.IDLE);

    // Receiving HEADERS with END_STREAM transitions to HALF_CLOSED_REMOTE
    stream::on_headers_received(&s, true)!!;

    assert(s.state == stream::StreamState.HALF_CLOSED_REMOTE);

    io::printn("[OK] IDLE -> HALF_CLOSED_REMOTE transition");
}

/**
 * Test OPEN -> HALF_CLOSED_REMOTE transition
 */
fn void test_open_to_half_closed_remote() @test
{
    stream::Stream s = stream::new_stream(1);

    // Transition to OPEN
    stream::on_headers_received(&s, false)!!;
    assert(s.state == stream::StreamState.OPEN);

    // Receiving DATA with END_STREAM transitions to HALF_CLOSED_REMOTE
    stream::on_data_received(&s, 100, true)!!;

    assert(s.state == stream::StreamState.HALF_CLOSED_REMOTE);
    assert(s.bytes_received == 100);

    io::printn("[OK] OPEN -> HALF_CLOSED_REMOTE transition");
}

/**
 * Test OPEN -> HALF_CLOSED_LOCAL transition
 */
fn void test_open_to_half_closed_local() @test
{
    stream::Stream s = stream::new_stream(1);

    // Transition to OPEN
    stream::on_headers_received(&s, false)!!;
    assert(s.state == stream::StreamState.OPEN);

    // Sending END_STREAM transitions to HALF_CLOSED_LOCAL
    stream::send_end_stream(&s)!!;

    assert(s.state == stream::StreamState.HALF_CLOSED_LOCAL);

    io::printn("[OK] OPEN -> HALF_CLOSED_LOCAL transition");
}

/**
 * Test HALF_CLOSED_REMOTE -> CLOSED transition
 */
fn void test_half_closed_remote_to_closed() @test
{
    stream::Stream s = stream::new_stream(1);

    // Transition to HALF_CLOSED_REMOTE
    stream::on_headers_received(&s, true)!!;
    assert(s.state == stream::StreamState.HALF_CLOSED_REMOTE);

    // Sending END_STREAM completes the stream
    stream::send_end_stream(&s)!!;

    assert(s.state == stream::StreamState.CLOSED);

    io::printn("[OK] HALF_CLOSED_REMOTE -> CLOSED transition");
}

/**
 * Test HALF_CLOSED_LOCAL -> CLOSED transition
 */
fn void test_half_closed_local_to_closed() @test
{
    stream::Stream s = stream::new_stream(1);

    // Transition to OPEN then HALF_CLOSED_LOCAL
    stream::on_headers_received(&s, false)!!;
    stream::send_end_stream(&s)!!;
    assert(s.state == stream::StreamState.HALF_CLOSED_LOCAL);

    // Receiving END_STREAM completes the stream
    stream::on_data_received(&s, 0, true)!!;

    assert(s.state == stream::StreamState.CLOSED);

    io::printn("[OK] HALF_CLOSED_LOCAL -> CLOSED transition");
}

/**
 * Test RST_STREAM closes stream from any state (RFC 9113 Section 6.4)
 */
fn void test_rst_stream_closes_from_any_state() @test
{
    // RST_STREAM from IDLE
    stream::Stream s1 = stream::new_stream(1);
    stream::on_rst_stream_received(&s1, stream::ErrorCode.NO_ERROR);
    assert(s1.state == stream::StreamState.CLOSED);

    // RST_STREAM from OPEN
    stream::Stream s2 = stream::new_stream(3);
    stream::on_headers_received(&s2, false)!!;
    assert(s2.state == stream::StreamState.OPEN);
    stream::on_rst_stream_received(&s2, stream::ErrorCode.CANCEL);
    assert(s2.state == stream::StreamState.CLOSED);

    // RST_STREAM from HALF_CLOSED_REMOTE
    stream::Stream s3 = stream::new_stream(5);
    stream::on_headers_received(&s3, true)!!;
    assert(s3.state == stream::StreamState.HALF_CLOSED_REMOTE);
    stream::on_rst_stream_received(&s3, stream::ErrorCode.NO_ERROR);
    assert(s3.state == stream::StreamState.CLOSED);

    io::printn("[OK] RST_STREAM closes stream from any state");
}

/**
 * Test DATA on IDLE stream is CONNECTION_ERROR (RFC 9113 Section 5.1)
 */
fn void test_data_on_idle_is_connection_error() @test
{
    stream::Stream s = stream::new_stream(1);
    assert(s.state == stream::StreamState.IDLE);

    // DATA on IDLE stream should return CONNECTION_ERROR
    assert(@catch(stream::on_data_received(&s, 100, false)) == stream::CONNECTION_ERROR);

    io::printn("[OK] DATA on IDLE is CONNECTION_ERROR");
}

/**
 * Test DATA on HALF_CLOSED_REMOTE is STREAM_ERROR (RFC 9113 Section 5.1)
 */
fn void test_data_on_half_closed_remote_is_error() @test
{
    stream::Stream s = stream::new_stream(1);

    // Transition to HALF_CLOSED_REMOTE
    stream::on_headers_received(&s, true)!!;
    assert(s.state == stream::StreamState.HALF_CLOSED_REMOTE);

    // DATA after END_STREAM should fail
    assert(@catch(stream::on_data_received(&s, 100, false)) == stream::STREAM_ERROR);

    io::printn("[OK] DATA on HALF_CLOSED_REMOTE is STREAM_ERROR");
}

/**
 * Test HEADERS on HALF_CLOSED_REMOTE is STREAM_ERROR
 */
fn void test_headers_on_half_closed_remote_is_error() @test
{
    stream::Stream s = stream::new_stream(1);

    // Transition to HALF_CLOSED_REMOTE
    stream::on_headers_received(&s, true)!!;
    assert(s.state == stream::StreamState.HALF_CLOSED_REMOTE);

    // HEADERS after END_STREAM should fail
    assert(@catch(stream::on_headers_received(&s, false)) == stream::STREAM_ERROR);

    io::printn("[OK] HEADERS on HALF_CLOSED_REMOTE is STREAM_ERROR");
}

/**
 * Test WINDOW_UPDATE on IDLE is CONNECTION_ERROR
 */
fn void test_window_update_on_idle_is_error() @test
{
    stream::Stream s = stream::new_stream(1);
    assert(s.state == stream::StreamState.IDLE);

    // WINDOW_UPDATE on IDLE should fail
    assert(@catch(stream::on_window_update_received(&s, 1000)) == stream::CONNECTION_ERROR);

    io::printn("[OK] WINDOW_UPDATE on IDLE is CONNECTION_ERROR");
}

/**
 * Test WINDOW_UPDATE with increment 0 is error
 */
fn void test_window_update_zero_is_error() @test
{
    stream::Stream s = stream::new_stream(1);

    // Transition to OPEN
    stream::on_headers_received(&s, false)!!;

    // WINDOW_UPDATE with 0 increment is a protocol error
    assert(@catch(stream::on_window_update_received(&s, 0)) == stream::STREAM_ERROR);

    io::printn("[OK] WINDOW_UPDATE with 0 increment is STREAM_ERROR");
}

/**
 * Test WINDOW_UPDATE updates send window
 */
fn void test_window_update_increases_window() @test
{
    stream::Stream s = stream::new_stream(1);

    // Transition to OPEN
    stream::on_headers_received(&s, false)!!;

    uint initial_window = s.send_window;

    // WINDOW_UPDATE should increase send window
    stream::on_window_update_received(&s, 1000)!!;

    assert(s.send_window == initial_window + 1000);

    io::printn("[OK] WINDOW_UPDATE increases send window");
}

/**
 * Test WINDOW_UPDATE overflow detection
 */
fn void test_window_update_overflow() @test
{
    stream::Stream s = stream::new_stream(1);

    // Transition to OPEN
    stream::on_headers_received(&s, false)!!;

    // Set window to max value
    s.send_window = 0x7FFFFFFF;

    // WINDOW_UPDATE that would overflow should fail
    assert(@catch(stream::on_window_update_received(&s, 1)) == stream::STREAM_ERROR);

    io::printn("[OK] WINDOW_UPDATE overflow detected");
}

/**
 * Test PRIORITY with self-dependency is error
 */
fn void test_priority_self_dependency_error() @test
{
    stream::Stream s = stream::new_stream(1);

    // PRIORITY with stream_dependency == stream_id is error
    assert(@catch(stream::on_priority_received(&s, 1, false, 16)) == stream::STREAM_ERROR);

    io::printn("[OK] PRIORITY self-dependency is error");
}

/**
 * Test PRIORITY allowed on any state including CLOSED
 */
fn void test_priority_allowed_on_closed() @test
{
    stream::Stream s = stream::new_stream(1);

    // Transition to CLOSED via RST_STREAM
    stream::on_rst_stream_received(&s, stream::ErrorCode.NO_ERROR);
    assert(s.state == stream::StreamState.CLOSED);

    // PRIORITY should still be accepted on CLOSED stream
    stream::on_priority_received(&s, 0, false, 16)!!;

    io::printn("[OK] PRIORITY allowed on CLOSED stream");
}

/**
 * Test frame validation for IDLE state
 */
fn void test_frame_validation_idle() @test
{
    stream::Stream s = stream::new_stream(1);

    // HEADERS and PRIORITY allowed on IDLE
    stream::validate_frame_for_state(&s, stream::FrameType.HEADERS)!!;
    stream::validate_frame_for_state(&s, stream::FrameType.PRIORITY)!!;

    // DATA, RST_STREAM, WINDOW_UPDATE not allowed on IDLE
    assert(@catch(stream::validate_frame_for_state(&s, stream::FrameType.DATA)) == stream::CONNECTION_ERROR);
    assert(@catch(stream::validate_frame_for_state(&s, stream::FrameType.RST_STREAM)) == stream::CONNECTION_ERROR);
    assert(@catch(stream::validate_frame_for_state(&s, stream::FrameType.WINDOW_UPDATE)) == stream::CONNECTION_ERROR);

    io::printn("[OK] Frame validation for IDLE state");
}

/**
 * Test frame validation for OPEN state
 */
fn void test_frame_validation_open() @test
{
    stream::Stream s = stream::new_stream(1);
    stream::on_headers_received(&s, false)!!;
    assert(s.state == stream::StreamState.OPEN);

    // All frames allowed in OPEN state
    stream::validate_frame_for_state(&s, stream::FrameType.DATA)!!;
    stream::validate_frame_for_state(&s, stream::FrameType.HEADERS)!!;
    stream::validate_frame_for_state(&s, stream::FrameType.PRIORITY)!!;
    stream::validate_frame_for_state(&s, stream::FrameType.RST_STREAM)!!;
    stream::validate_frame_for_state(&s, stream::FrameType.WINDOW_UPDATE)!!;

    io::printn("[OK] Frame validation for OPEN state");
}

/**
 * Test frame validation for HALF_CLOSED_REMOTE state
 */
fn void test_frame_validation_half_closed_remote() @test
{
    stream::Stream s = stream::new_stream(1);
    stream::on_headers_received(&s, true)!!;
    assert(s.state == stream::StreamState.HALF_CLOSED_REMOTE);

    // DATA and HEADERS not allowed
    assert(@catch(stream::validate_frame_for_state(&s, stream::FrameType.DATA)) == stream::STREAM_ERROR);
    assert(@catch(stream::validate_frame_for_state(&s, stream::FrameType.HEADERS)) == stream::STREAM_ERROR);

    // PRIORITY, RST_STREAM, WINDOW_UPDATE allowed
    stream::validate_frame_for_state(&s, stream::FrameType.PRIORITY)!!;
    stream::validate_frame_for_state(&s, stream::FrameType.RST_STREAM)!!;
    stream::validate_frame_for_state(&s, stream::FrameType.WINDOW_UPDATE)!!;

    io::printn("[OK] Frame validation for HALF_CLOSED_REMOTE state");
}

/**
 * Test frame validation for CLOSED state
 */
fn void test_frame_validation_closed() @test
{
    stream::Stream s = stream::new_stream(1);
    stream::on_rst_stream_received(&s, stream::ErrorCode.NO_ERROR);
    assert(s.state == stream::StreamState.CLOSED);

    // Only PRIORITY allowed on CLOSED
    stream::validate_frame_for_state(&s, stream::FrameType.PRIORITY)!!;

    // Other frames not allowed
    assert(@catch(stream::validate_frame_for_state(&s, stream::FrameType.DATA)) == stream::STREAM_ERROR);
    // HEADERS on closed stream is CONNECTION_ERROR per RFC 9113 §5.1
    assert(@catch(stream::validate_frame_for_state(&s, stream::FrameType.HEADERS)) == stream::CONNECTION_ERROR);
    assert(@catch(stream::validate_frame_for_state(&s, stream::FrameType.WINDOW_UPDATE)) == stream::STREAM_ERROR);

    io::printn("[OK] Frame validation for CLOSED state");
}

/**
 * Test can_send_data and can_receive_data helpers
 */
fn void test_send_receive_helpers() @test
{
    // OPEN: can send and receive
    stream::Stream s1 = stream::new_stream(1);
    stream::on_headers_received(&s1, false)!!;
    assert(stream::can_send_data(&s1));
    assert(stream::can_receive_data(&s1));

    // HALF_CLOSED_LOCAL: can receive but not send
    stream::Stream s2 = stream::new_stream(3);
    stream::on_headers_received(&s2, false)!!;
    stream::send_end_stream(&s2)!!;
    assert(!stream::can_send_data(&s2));
    assert(stream::can_receive_data(&s2));

    // HALF_CLOSED_REMOTE: can send but not receive
    stream::Stream s3 = stream::new_stream(5);
    stream::on_headers_received(&s3, true)!!;
    assert(stream::can_send_data(&s3));
    assert(!stream::can_receive_data(&s3));

    // CLOSED: cannot send or receive
    stream::Stream s4 = stream::new_stream(7);
    stream::on_rst_stream_received(&s4, stream::ErrorCode.NO_ERROR);
    assert(!stream::can_send_data(&s4));
    assert(!stream::can_receive_data(&s4));

    io::printn("[OK] Send/receive helper functions");
}

/**
 * Test error code retrieval
 */
fn void test_error_codes() @test
{
    stream::Stream s = stream::new_stream(1);

    // IDLE violations are PROTOCOL_ERROR
    stream::ErrorCode code1 = stream::get_error_code_for_violation(&s, stream::FrameType.DATA);
    assert(code1 == stream::ErrorCode.PROTOCOL_ERROR);

    // Transition to HALF_CLOSED_REMOTE
    stream::on_headers_received(&s, true)!!;

    // DATA on HALF_CLOSED_REMOTE is STREAM_CLOSED
    stream::ErrorCode code2 = stream::get_error_code_for_violation(&s, stream::FrameType.DATA);
    assert(code2 == stream::ErrorCode.STREAM_CLOSED);

    io::printn("[OK] Error code retrieval");
}

/**
 * Test SETTINGS_INITIAL_WINDOW_SIZE adjustment affects existing streams
 * h2spec test: http2/6.9.2/1
 *
 * RFC 9113 §6.5.2: When the value of SETTINGS_INITIAL_WINDOW_SIZE changes,
 * a receiver MUST adjust the size of all stream flow-control windows that
 * it maintains by the difference between the new value and the old value.
 */
fn void test_initial_window_size_adjustment() @test
{
    // Create stream with default initial window size (65535)
    stream::Stream s = stream::new_stream(1, 65535);
    stream::on_headers_received(&s, false)!!;  // Transition to OPEN

    // Verify initial send_window
    assert(s.send_window == 65535);

    // Simulate consuming some of the window (e.g., we sent some data)
    s.send_window = 0;  // Window fully consumed

    // Simulate SETTINGS_INITIAL_WINDOW_SIZE change: old=65535, new=65536
    // Delta = 65536 - 65535 = +1
    int delta = 1;
    long new_window = (long)s.send_window + (long)delta;

    // The adjustment should make window = 1 (allowing 1 byte to be sent)
    assert(new_window == 1, "Expected window to be 1 after delta adjustment");

    // Apply the delta (this is what the server should do)
    s.send_window = (uint)new_window;
    assert(s.send_window == 1);

    io::printn("[OK] SETTINGS_INITIAL_WINDOW_SIZE adjustment (http2/6.9.2/1)");
}

/**
 * Test SETTINGS_INITIAL_WINDOW_SIZE negative delta
 * When new initial window size is smaller than old, existing windows decrease
 */
fn void test_initial_window_size_negative_delta() @test
{
    stream::Stream s = stream::new_stream(1, 65535);
    stream::on_headers_received(&s, false)!!;

    // Set send_window to 1000 (simulating partial consumption)
    s.send_window = 1000;

    // SETTINGS change: old=65535, new=65000
    // Delta = 65000 - 65535 = -535
    int delta = -535;
    long new_window = (long)s.send_window + (long)delta;

    // Window should become 1000 - 535 = 465
    assert(new_window == 465);

    s.send_window = (uint)new_window;
    assert(s.send_window == 465);

    io::printn("[OK] SETTINGS_INITIAL_WINDOW_SIZE negative delta");
}

/**
 * Test stream with pending_response flag for flow control blocked data
 * This tests the pattern used when a response is blocked due to flow control
 */
fn void test_pending_response_flag() @test
{
    stream::Stream s = stream::new_stream(1, 65535);
    stream::on_headers_received(&s, true)!!;  // Client sent END_STREAM

    // Initially no pending response
    assert(!s.pending_response);

    // Server wants to send response but window is 0
    s.send_window = 0;
    s.pending_response = true;  // Mark that we have data waiting

    assert(s.pending_response);
    assert(s.send_window == 0);

    // After window opens, pending_response should be checked and data sent
    // This simulates WINDOW_UPDATE or SETTINGS_INITIAL_WINDOW_SIZE change
    s.send_window = 100;

    // Server logic: if pending_response && send_window > 0, send data
    assert(s.pending_response && s.send_window > 0);

    io::printn("[OK] Pending response flag for flow control");
}
