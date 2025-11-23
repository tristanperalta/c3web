/**
 * HTTP/2 Frame Validation
 * RFC 9113 Section 4 - HTTP Frames
 *
 * Implements strict frame validation including size limits, padding,
 * and frame-specific validation rules.
 */
module c3web::http2::frame;

import c3web::http2::stream;
import std::io;

/**
 * Frame validation errors
 */
faultdef FRAME_SIZE_ERROR, PROTOCOL_ERROR, COMPRESSION_ERROR, FLOW_CONTROL_ERROR;

/**
 * HTTP/2 Frame Flags (RFC 9113 Section 4.1)
 */
enum FrameFlags : const char {
    END_STREAM  = 0x1,  // DATA, HEADERS
    ACK         = 0x1,  // SETTINGS, PING
    END_HEADERS = 0x4,  // HEADERS, PUSH_PROMISE, CONTINUATION
    PADDED      = 0x8,  // DATA, HEADERS, PUSH_PROMISE
    PRIORITY    = 0x20, // HEADERS
}

/**
 * Connection settings
 */
struct ConnectionSettings {
    uint max_frame_size;             // SETTINGS_MAX_FRAME_SIZE (default 16384)
    uint max_header_list_size;       // SETTINGS_MAX_HEADER_LIST_SIZE
    uint max_concurrent_streams;     // SETTINGS_MAX_CONCURRENT_STREAMS
    uint initial_window_size;        // SETTINGS_INITIAL_WINDOW_SIZE (default 65535)
    bool enable_push;                // SETTINGS_ENABLE_PUSH (default true)
}

/**
 * Frame header (RFC 9113 Section 4.1)
 * All frames begin with a fixed 9-byte header
 */
struct FrameHeader {
    uint length;           // 24-bit length (payload only, not including header)
    stream::FrameType type;          // 8-bit type
    char flags;            // 8-bit flags
    uint stream_id;        // 31-bit stream identifier (R bit always 0)
}

/**
 * Default connection settings (RFC 9113 Section 6.5.2)
 */
fn ConnectionSettings default_settings() {
    return (ConnectionSettings){
        .max_frame_size = 16384,           // 2^14
        .max_header_list_size = 0,         // Unlimited (0 means no limit)
        .max_concurrent_streams = 100,     // Reasonable default
        .initial_window_size = 65535,      // 2^16 - 1
        .enable_push = false,              // Server push disabled by default
    };
}

/**
 * Validate frame size (RFC 9113 Section 4.2)
 *
 * Frame size limits:
 * - All frames MUST be <= SETTINGS_MAX_FRAME_SIZE
 * - Default max frame size: 16384 bytes (2^14)
 * - Allowed range: 16384 to 16777215 (2^24-1)
 * - Exception: SETTINGS_MAX_FRAME_SIZE does not apply to SETTINGS frames
 */
fn void? validate_frame_size(FrameHeader* header, ConnectionSettings* settings) {
    // SETTINGS frames are exempt from SETTINGS_MAX_FRAME_SIZE limit
    // but still limited by maximum frame size (2^24-1 = 16777215)
    if (header.type == stream::FrameType.SETTINGS) {
        if (header.length > 16777215) {
            return FRAME_SIZE_ERROR?;
        }
        return;
    }

    // All other frames must respect SETTINGS_MAX_FRAME_SIZE
    if (header.length > settings.max_frame_size) {
        return FRAME_SIZE_ERROR?;
    }
}

/**
 * Validate stream ID for frame type (RFC 9113 Section 5.1.1)
 *
 * Some frames are connection-level (stream ID MUST be 0):
 * - SETTINGS, PING, GOAWAY
 *
 * Other frames are stream-level (stream ID MUST be > 0):
 * - DATA, HEADERS, PRIORITY, RST_STREAM, PUSH_PROMISE, CONTINUATION
 *
 * WINDOW_UPDATE can be either (0 for connection, >0 for stream)
 */
fn void? validate_stream_id_for_frame_type(FrameHeader* header) {
    switch (header.type) {
        // Connection-level frames (stream ID MUST be 0)
        case stream::FrameType.SETTINGS:
        case stream::FrameType.PING:
        case stream::FrameType.GOAWAY:
            if (header.stream_id != 0) {
                return PROTOCOL_ERROR?;
            }

        // Stream-level frames (stream ID MUST be > 0)
        case stream::FrameType.DATA:
        case stream::FrameType.HEADERS:
        case stream::FrameType.PRIORITY:
        case stream::FrameType.RST_STREAM:
        case stream::FrameType.PUSH_PROMISE:
        case stream::FrameType.CONTINUATION:
            if (header.stream_id == 0) {
                return PROTOCOL_ERROR?;
            }

        // WINDOW_UPDATE can be either connection (0) or stream (>0)
        case stream::FrameType.WINDOW_UPDATE:
            // No restriction - valid for both
            return;
    }
}

/**
 * Validate DATA frame (RFC 9113 Section 6.1)
 *
 * Rules:
 * - Stream ID must be > 0
 * - If PADDED flag set, first byte is pad length
 * - Pad length must not exceed frame length - 1
 */
fn void? validate_data_frame(FrameHeader* header, char[] payload) {
    // Stream ID already validated by validate_stream_id_for_frame_type

    // Validate padding if PADDED flag is set
    if (header.flags & (char)FrameFlags.PADDED) {
        if (payload.len == 0) {
            return PROTOCOL_ERROR?;
        }

        char pad_length = payload[0];

        // Pad length must not exceed payload length minus 1 (for pad_length field itself)
        if (pad_length >= payload.len) {
            return PROTOCOL_ERROR?;
        }
    }
}

/**
 * Validate HEADERS frame (RFC 9113 Section 6.2)
 *
 * Rules:
 * - Stream ID must be > 0
 * - If PADDED flag set, first byte is pad length
 * - If PRIORITY flag set, next 5 bytes are priority fields
 * - END_HEADERS flag indicates this is the last HEADERS frame (or CONTINUATION follows)
 */
fn void? validate_headers_frame(FrameHeader* header, char[] payload) {
    usz consumed = 0;

    // Validate padding if PADDED flag is set
    if (header.flags & (char)FrameFlags.PADDED) {
        if (payload.len == 0) {
            return PROTOCOL_ERROR?;
        }

        char pad_length = payload[0];
        consumed += 1;

        // Pad length must not exceed remaining payload
        if (pad_length >= payload.len - consumed) {
            return PROTOCOL_ERROR?;
        }
    }

    // Validate priority if PRIORITY flag is set
    if (header.flags & (char)FrameFlags.PRIORITY) {
        // Priority fields: 1 bit E flag + 31 bit stream dependency + 8 bit weight = 5 bytes
        if (payload.len - consumed < 5) {
            return PROTOCOL_ERROR?;
        }
        consumed += 5;
    }

    // Remaining payload should be header block fragment
    // (HPACK validation happens separately)
}

/**
 * Validate PRIORITY frame (RFC 9113 Section 6.3)
 *
 * Rules:
 * - Stream ID must be > 0
 * - Payload must be exactly 5 bytes
 * - Stream dependency must not point to itself
 */
fn void? validate_priority_frame(FrameHeader* header, char[] payload) {
    // PRIORITY frame must be exactly 5 bytes
    if (header.length != 5) {
        return FRAME_SIZE_ERROR?;
    }

    if (payload.len != 5) {
        return PROTOCOL_ERROR?;
    }

    // Extract stream dependency (first 4 bytes, ignore E bit)
    uint stream_dependency = 0;
    stream_dependency |= ((uint)payload[0] & 0x7F) << 24;
    stream_dependency |= ((uint)payload[1]) << 16;
    stream_dependency |= ((uint)payload[2]) << 8;
    stream_dependency |= ((uint)payload[3]);

    // Stream dependency must not point to itself
    if (stream_dependency == header.stream_id) {
        return PROTOCOL_ERROR?;
    }
}

/**
 * Validate RST_STREAM frame (RFC 9113 Section 6.4)
 *
 * Rules:
 * - Stream ID must be > 0
 * - Payload must be exactly 4 bytes (error code)
 */
fn void? validate_rst_stream_frame(FrameHeader* header, char[] payload) {
    // RST_STREAM frame must be exactly 4 bytes
    if (header.length != 4) {
        return FRAME_SIZE_ERROR?;
    }

    if (payload.len != 4) {
        return PROTOCOL_ERROR?;
    }
}

/**
 * Validate SETTINGS frame (RFC 9113 Section 6.5)
 *
 * Rules:
 * - Stream ID must be 0
 * - Payload length must be multiple of 6 (each setting is 6 bytes)
 * - If ACK flag is set, payload must be empty
 */
fn void? validate_settings_frame(FrameHeader* header, char[] payload) {
    // If ACK flag is set, payload must be empty
    if (header.flags & (char)FrameFlags.ACK) {
        if (header.length != 0) {
            return FRAME_SIZE_ERROR?;
        }
        return;
    }

    // Payload length must be multiple of 6
    if (header.length % 6 != 0) {
        return FRAME_SIZE_ERROR?;
    }

    // Validate each setting parameter
    usz pos = 0;
    while (pos < payload.len) {
        if (pos + 6 > payload.len) {
            return PROTOCOL_ERROR?;
        }

        // Setting identifier (2 bytes)
        ushort identifier = 0;
        identifier |= ((ushort)payload[pos]) << 8;
        identifier |= ((ushort)payload[pos + 1]);

        // Setting value (4 bytes)
        uint value = 0;
        value |= ((uint)payload[pos + 2]) << 24;
        value |= ((uint)payload[pos + 3]) << 16;
        value |= ((uint)payload[pos + 4]) << 8;
        value |= ((uint)payload[pos + 5]);

        // Validate specific settings
        validate_setting_value(identifier, value)!;

        pos += 6;
    }
}

/**
 * Validate individual setting values (RFC 9113 Section 6.5.2)
 */
fn void? validate_setting_value(ushort identifier, uint value) {
    switch (identifier) {
        case 0x1: // SETTINGS_HEADER_TABLE_SIZE
            // Any value is valid
            return;
        case 0x2: // SETTINGS_ENABLE_PUSH
            // Must be 0 or 1
            if (value != 0 && value != 1) {
                return PROTOCOL_ERROR?;
            }
            return;
        case 0x3: // SETTINGS_MAX_CONCURRENT_STREAMS
            // Any value is valid
            return;
        case 0x4: // SETTINGS_INITIAL_WINDOW_SIZE
            // Must not exceed 2^31-1 (2147483647) - RFC 9113 Section 6.5.2
            // Exceeding this is a FLOW_CONTROL_ERROR, not PROTOCOL_ERROR
            if (value > 0x7FFFFFFF) {
                return FLOW_CONTROL_ERROR?;
            }
            return;
        case 0x5: // SETTINGS_MAX_FRAME_SIZE
            // Must be between 16384 (2^14) and 16777215 (2^24-1)
            if (value < 16384 || value > 16777215) {
                return PROTOCOL_ERROR?;
            }
            return;
        case 0x6: // SETTINGS_MAX_HEADER_LIST_SIZE
            // Any value is valid
            return;
        default:
            // Unknown settings are ignored (RFC 9113 Section 6.5.2)
            return;
    }
}

/**
 * Validate PING frame (RFC 9113 Section 6.7)
 *
 * Rules:
 * - Stream ID must be 0
 * - Payload must be exactly 8 bytes
 */
fn void? validate_ping_frame(FrameHeader* header, char[] payload) {
    // PING frame must be exactly 8 bytes
    if (header.length != 8) {
        return FRAME_SIZE_ERROR?;
    }

    if (payload.len != 8) {
        return PROTOCOL_ERROR?;
    }
}

/**
 * Validate GOAWAY frame (RFC 9113 Section 6.8)
 *
 * Rules:
 * - Stream ID must be 0
 * - Payload must be at least 8 bytes (last stream ID + error code)
 * - Additional debug data is optional
 */
fn void? validate_goaway_frame(FrameHeader* header, char[] payload) {
    // GOAWAY frame must have at least 8 bytes (last stream ID + error code)
    if (header.length < 8) {
        return FRAME_SIZE_ERROR?;
    }

    if (payload.len < 8) {
        return PROTOCOL_ERROR?;
    }

    // Additional debug data is allowed
}

/**
 * Validate WINDOW_UPDATE frame (RFC 9113 Section 6.9)
 *
 * Rules:
 * - Payload must be exactly 4 bytes
 * - Window size increment must be > 0 and <= 2^31-1
 */
fn void? validate_window_update_frame(FrameHeader* header, char[] payload) {
    // WINDOW_UPDATE frame must be exactly 4 bytes
    if (header.length != 4) {
        return FRAME_SIZE_ERROR?;
    }

    if (payload.len != 4) {
        return PROTOCOL_ERROR?;
    }

    // Extract window size increment (31 bits, ignore R bit)
    uint increment = 0;
    increment |= ((uint)payload[0] & 0x7F) << 24;
    increment |= ((uint)payload[1]) << 16;
    increment |= ((uint)payload[2]) << 8;
    increment |= ((uint)payload[3]);

    // Window size increment must be > 0
    if (increment == 0) {
        return PROTOCOL_ERROR?;
    }

    // Window size increment must not exceed 2^31-1
    if (increment > 0x7FFFFFFF) {
        return PROTOCOL_ERROR?;
    }
}

/**
 * Validate complete frame (header + payload)
 *
 * Performs all validation checks:
 * - Frame size limits
 * - Stream ID for frame type
 * - Frame-specific validation
 */
fn void? validate_frame(FrameHeader* header, char[] payload, ConnectionSettings* settings) {
    // Validate frame size
    validate_frame_size(header, settings)!;

    // Validate stream ID for frame type
    validate_stream_id_for_frame_type(header)!;

    // Frame-specific validation
    switch (header.type) {
        case stream::FrameType.DATA:
            validate_data_frame(header, payload)!;

        case stream::FrameType.HEADERS:
            validate_headers_frame(header, payload)!;

        case stream::FrameType.PRIORITY:
            validate_priority_frame(header, payload)!;

        case stream::FrameType.RST_STREAM:
            validate_rst_stream_frame(header, payload)!;

        case stream::FrameType.SETTINGS:
            validate_settings_frame(header, payload)!;

        case stream::FrameType.PING:
            validate_ping_frame(header, payload)!;

        case stream::FrameType.GOAWAY:
            validate_goaway_frame(header, payload)!;

        case stream::FrameType.WINDOW_UPDATE:
            validate_window_update_frame(header, payload)!;

        case stream::FrameType.PUSH_PROMISE:
        case stream::FrameType.CONTINUATION:
            // Basic validation - detailed validation would go here
            if (header.stream_id == 0) {
                return PROTOCOL_ERROR?;
            }
    }
}

/**
 * Extract padding from DATA or HEADERS frame payload
 * Returns the unpadded payload
 */
fn char[]? extract_padding(char flags, char[] payload) {
    if (!(flags & (char)FrameFlags.PADDED)) {
        // No padding
        return payload;
    }

    if (payload.len == 0) {
        return PROTOCOL_ERROR?;
    }

    char pad_length = payload[0];

    // Validate pad length
    if (pad_length >= payload.len) {
        return PROTOCOL_ERROR?;
    }

    // Return payload without padding length byte and padding
    usz data_len = payload.len - 1 - pad_length;
    return payload[1:data_len];
}

/**
 * Check if frame has specific flag set
 */
fn bool has_flag(char flags, FrameFlags flag) {
    return (flags & (char)flag) != 0;
}
