/**
 * HTTP/2 Stream State Machine
 * RFC 9113 Section 5.1 - Streams and Multiplexing
 *
 * Implements the HTTP/2 stream lifecycle and state transitions.
 */
module c3web::http2::stream;

import std::io;

/**
 * HTTP/2 Stream States (RFC 9113 Section 5.1)
 */
enum StreamState : char {
    IDLE,                // Initial state
    OPEN,                // Bidirectional communication
    HALF_CLOSED_LOCAL,   // Local endpoint sent END_STREAM
    HALF_CLOSED_REMOTE,  // Remote endpoint sent END_STREAM
    CLOSED               // Terminal state
}

/**
 * HTTP/2 Frame Types (RFC 9113 Section 6)
 */
enum FrameType : const char {
    DATA          = 0x0,
    HEADERS       = 0x1,
    PRIORITY      = 0x2,
    RST_STREAM    = 0x3,
    SETTINGS      = 0x4,
    PUSH_PROMISE  = 0x5,
    PING          = 0x6,
    GOAWAY        = 0x7,
    WINDOW_UPDATE = 0x8,
    CONTINUATION  = 0x9
}

/**
 * HTTP/2 Error Codes (RFC 9113 Section 7)
 */
enum ErrorCode : const uint {
    NO_ERROR            = 0x0,
    PROTOCOL_ERROR      = 0x1,
    INTERNAL_ERROR      = 0x2,
    FLOW_CONTROL_ERROR  = 0x3,
    SETTINGS_TIMEOUT    = 0x4,
    STREAM_CLOSED       = 0x5,
    FRAME_SIZE_ERROR    = 0x6,
    REFUSED_STREAM      = 0x7,
    CANCEL              = 0x8,
    COMPRESSION_ERROR   = 0x9,
    CONNECT_ERROR       = 0xa,
    ENHANCE_YOUR_CALM   = 0xb,
    INADEQUATE_SECURITY = 0xc,
    HTTP_1_1_REQUIRED   = 0xd
}

/**
 * Error types for stream operations
 */
faultdef STREAM_ERROR, CONNECTION_ERROR;

/**
 * Stream error details
 */
struct StreamError {
    ErrorCode code;
    String message;
}

/**
 * HTTP/2 Stream
 */
struct Stream {
    uint id;                  // Stream identifier (RFC 9113 §5.1.1)
    StreamState state;        // Current state
    uint recv_window;         // Receive flow control window
    int send_window;          // Send flow control window (can be negative per RFC 9113)
    usz bytes_received;       // Bytes received (for Content-Length validation)
    usz expected_bytes;       // Expected bytes from Content-Length header
    bool has_content_length;  // Whether Content-Length was specified
    bool pending_response;    // True if we have response data blocked on flow control
    bool headers_sent;        // True if we've sent HEADERS for response
}

/**
 * Initialize a new stream
 */
fn Stream new_stream(uint stream_id, uint initial_window_size = 65535) {
    return (Stream){
        .id = stream_id,
        .state = IDLE,
        .recv_window = initial_window_size,
        .send_window = (int)initial_window_size,
        .bytes_received = 0,
        .expected_bytes = 0,
        .has_content_length = false,
        .pending_response = false,
        .headers_sent = false,
    };
}

/**
 * Validate stream ID (RFC 9113 Section 5.1.1)
 *
 * Stream ID rules:
 * - Stream 0 is reserved for connection-level frames
 * - Client-initiated streams: ODD numbers (1, 3, 5, ...)
 * - Server-initiated streams: EVEN numbers (2, 4, 6, ...)
 * - Stream IDs must increase monotonically
 */
fn bool is_valid_client_stream_id(uint stream_id) {
    // Stream 0 is connection control only
    if (stream_id == 0) return false;

    // Client-initiated streams must be odd
    return stream_id % 2 == 1;
}

fn bool is_stream_id_increasing(uint stream_id, uint last_stream_id) {
    return stream_id > last_stream_id;
}

/**
 * Validate if a frame type is allowed in the current stream state
 * (RFC 9113 Section 5.1)
 *
 * Returns CONNECTION_ERROR for IDLE state violations
 * Returns STREAM_ERROR for other state violations
 */
fn void? validate_frame_for_state(Stream* stream, FrameType frame_type) {
    switch (stream.state) {
        case IDLE:
            // Only HEADERS and PRIORITY allowed on IDLE streams (RFC 9113 §5.1)
            // DATA, RST_STREAM, WINDOW_UPDATE on IDLE are CONNECTION_ERROR
            if (frame_type == HEADERS || frame_type == PRIORITY) {
                return;
            }
            if (frame_type == DATA || frame_type == RST_STREAM || frame_type == WINDOW_UPDATE) {
                return CONNECTION_ERROR?;
            }
            return CONNECTION_ERROR?;

        case OPEN:
            // All frame types allowed in OPEN state
            return;

        case HALF_CLOSED_REMOTE:
            // Can only receive WINDOW_UPDATE, PRIORITY, RST_STREAM
            // DATA or HEADERS after END_STREAM is STREAM_ERROR (STREAM_CLOSED)
            if (frame_type == DATA || frame_type == HEADERS) {
                return STREAM_ERROR?;
            }
            return;

        case HALF_CLOSED_LOCAL:
            // Can receive any frame type
            return;

        case CLOSED:
            // Only PRIORITY allowed (brief grace period)
            if (frame_type == PRIORITY) {
                return;
            }
            // HEADERS on closed stream is CONNECTION_ERROR per RFC 9113 §5.1
            // Other frames are STREAM_ERROR (STREAM_CLOSED)
            if (frame_type == HEADERS) {
                return CONNECTION_ERROR?;
            }
            return STREAM_ERROR?;
    }
}

/**
 * Get error code for stream state violation
 */
fn ErrorCode get_error_code_for_violation(Stream* stream, FrameType frame_type) {
    switch (stream.state) {
        case IDLE:
            // IDLE violations are always PROTOCOL_ERROR (connection-level)
            return PROTOCOL_ERROR;

        case HALF_CLOSED_REMOTE:
            // Receiving DATA/HEADERS after END_STREAM
            if (frame_type == DATA || frame_type == HEADERS) {
                return STREAM_CLOSED;
            }
            return PROTOCOL_ERROR;

        case CLOSED:
            // Frames on closed stream
            return STREAM_CLOSED;

        default:
            return PROTOCOL_ERROR;
    }
}

/**
 * Handle HEADERS frame reception (RFC 9113 Section 6.2)
 * Updates stream state based on END_STREAM flag
 */
fn void? on_headers_received(Stream* stream, bool end_stream) {
    switch (stream.state) {
        case IDLE:
            // First HEADERS transitions IDLE -> OPEN or HALF_CLOSED_REMOTE
            stream.state = end_stream ? HALF_CLOSED_REMOTE : OPEN;

        case OPEN:
            // HEADERS with END_STREAM transitions to HALF_CLOSED_REMOTE
            if (end_stream) {
                stream.state = HALF_CLOSED_REMOTE;
            }

        case HALF_CLOSED_LOCAL:
            // Can receive HEADERS in this state
            if (end_stream) {
                stream.state = CLOSED;
            }

        case HALF_CLOSED_REMOTE:
            // Receiving HEADERS after END_STREAM is an error
            return STREAM_ERROR?;

        case CLOSED:
            // HEADERS on closed stream
            return STREAM_ERROR?;
    }
}

/**
 * Handle DATA frame reception (RFC 9113 Section 6.1)
 * Validates state and updates byte counts
 */
fn void? on_data_received(Stream* stream, usz length, bool end_stream) {
    // Validate state allows DATA
    if (stream.state == IDLE) {
        // DATA on IDLE stream is a connection error
        return CONNECTION_ERROR?;
    }

    if (stream.state != OPEN && stream.state != HALF_CLOSED_LOCAL) {
        // DATA on HALF_CLOSED_REMOTE or CLOSED is a stream error
        return STREAM_ERROR?;
    }

    // Update byte count
    stream.bytes_received += length;

    // Validate against Content-Length if specified
    if (stream.has_content_length && stream.bytes_received > stream.expected_bytes) {
        return STREAM_ERROR?;
    }

    // Handle END_STREAM flag
    if (end_stream) {
        // Validate Content-Length matches if specified
        if (stream.has_content_length && stream.bytes_received != stream.expected_bytes) {
            return STREAM_ERROR?;
        }

        // Transition state
        stream.state = (stream.state == OPEN) ? HALF_CLOSED_REMOTE : CLOSED;
    }
}

/**
 * Handle RST_STREAM frame (RFC 9113 Section 6.4)
 * Can be received in any state, always transitions to CLOSED
 */
fn void on_rst_stream_received(Stream* stream, ErrorCode error_code) {
    // RST_STREAM transitions any state to CLOSED
    stream.state = CLOSED;

    // Note: error_code indicates why the stream was reset
    // NO_ERROR (0x0) or CANCEL (0x8) are normal terminations
}

/**
 * Handle WINDOW_UPDATE frame (RFC 9113 Section 6.9)
 */
fn void? on_window_update_received(Stream* stream, uint window_increment) {
    // WINDOW_UPDATE on IDLE is a connection error
    if (stream.state == IDLE) {
        return CONNECTION_ERROR?;
    }

    // Window increment of 0 is a protocol error
    if (window_increment == 0) {
        return STREAM_ERROR?;
    }

    // Update send window
    // Check for overflow (window size exceeds 2^31-1)
    // Use long to avoid overflow in the check itself
    long new_window = (long)stream.send_window + (long)window_increment;
    if (new_window > 0x7FFFFFFF) {
        return STREAM_ERROR?;
    }

    stream.send_window = (int)new_window;
}

/**
 * Handle PRIORITY frame (RFC 9113 Section 6.3)
 * PRIORITY is allowed in any state, even CLOSED
 */
fn void? on_priority_received(Stream* stream, uint stream_dependency, bool exclusive, char weight) {
    // Validate stream dependency doesn't point to itself
    if (stream_dependency == stream.id) {
        return STREAM_ERROR?;
    }

    // PRIORITY frames are deprecated in RFC 9113 but still valid
    // We accept them but don't need to implement prioritization
    // Just validate and ignore
}

/**
 * Send END_STREAM from local endpoint
 * Updates state for locally-initiated stream closure
 */
fn void? send_end_stream(Stream* stream) {
    switch (stream.state) {
        case IDLE:
            // Can't send END_STREAM on IDLE (server doesn't initiate)
            return STREAM_ERROR?;

        case OPEN:
            // Sending END_STREAM transitions to HALF_CLOSED_LOCAL
            stream.state = HALF_CLOSED_LOCAL;

        case HALF_CLOSED_REMOTE:
            // Sending END_STREAM completes the stream
            stream.state = CLOSED;

        case HALF_CLOSED_LOCAL:
            // Already sent END_STREAM
            return STREAM_ERROR?;

        case CLOSED:
            // Stream already closed
            return STREAM_ERROR?;
    }
}

/**
 * Send RST_STREAM to immediately close the stream
 */
fn void send_rst_stream(Stream* stream, ErrorCode error_code) {
    // Can send RST_STREAM in any state
    stream.state = CLOSED;
}

/**
 * Check if stream can send frames
 */
fn bool can_send_data(Stream* stream) {
    return stream.state == OPEN || stream.state == HALF_CLOSED_REMOTE;
}

/**
 * Check if stream can receive frames
 */
fn bool can_receive_data(Stream* stream) {
    return stream.state == OPEN || stream.state == HALF_CLOSED_LOCAL;
}

/**
 * Get state name for debugging
 */
fn String get_state_name(StreamState state) {
    switch (state) {
        case IDLE: return "IDLE";
        case OPEN: return "OPEN";
        case HALF_CLOSED_LOCAL: return "HALF_CLOSED_LOCAL";
        case HALF_CLOSED_REMOTE: return "HALF_CLOSED_REMOTE";
        case CLOSED: return "CLOSED";
    }
    return "UNKNOWN";
}

/**
 * Get error code name for debugging
 */
fn String get_error_name(ErrorCode code) {
    switch (code) {
        case NO_ERROR: return "NO_ERROR";
        case PROTOCOL_ERROR: return "PROTOCOL_ERROR";
        case INTERNAL_ERROR: return "INTERNAL_ERROR";
        case FLOW_CONTROL_ERROR: return "FLOW_CONTROL_ERROR";
        case SETTINGS_TIMEOUT: return "SETTINGS_TIMEOUT";
        case STREAM_CLOSED: return "STREAM_CLOSED";
        case FRAME_SIZE_ERROR: return "FRAME_SIZE_ERROR";
        case REFUSED_STREAM: return "REFUSED_STREAM";
        case CANCEL: return "CANCEL";
        case COMPRESSION_ERROR: return "COMPRESSION_ERROR";
        case CONNECT_ERROR: return "CONNECT_ERROR";
        case ENHANCE_YOUR_CALM: return "ENHANCE_YOUR_CALM";
        case INADEQUATE_SECURITY: return "INADEQUATE_SECURITY";
        case HTTP_1_1_REQUIRED: return "HTTP_1_1_REQUIRED";
    }
    return "UNKNOWN";
}
