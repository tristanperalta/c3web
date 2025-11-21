/**
 * WebSocket Control Frame Handling
 *
 * RFC 6455 §5.5 - Control Frames
 * Utilities for creating and parsing CLOSE, PING, and PONG frames
 */
module c3web::websocket::control;

import c3web::websocket::frame;
import c3web::websocket::utf8;
import std::io;
import std::core::bitorder;

/**
 * Close status codes (RFC 6455 §7.4)
 */
const ushort CLOSE_NORMAL = 1000;              // Normal closure
const ushort CLOSE_GOING_AWAY = 1001;          // Going away (e.g., server shutdown)
const ushort CLOSE_PROTOCOL_ERROR = 1002;      // Protocol error
const ushort CLOSE_UNSUPPORTED_DATA = 1003;    // Unsupported data (e.g., text when expecting binary)
const ushort CLOSE_INVALID_PAYLOAD = 1007;     // Invalid frame payload data (e.g., bad UTF-8)
const ushort CLOSE_POLICY_VIOLATION = 1008;    // Policy violation
const ushort CLOSE_MESSAGE_TOO_BIG = 1009;     // Message too big
const ushort CLOSE_MANDATORY_EXTENSION = 1010; // Client expected extension not negotiated
const ushort CLOSE_INTERNAL_ERROR = 1011;      // Server encountered unexpected condition

// Reserved codes (not for use in applications)
const ushort CLOSE_NO_STATUS = 1005;           // Reserved: no status code present
const ushort CLOSE_ABNORMAL = 1006;            // Reserved: abnormal closure (no close frame)
const ushort CLOSE_TLS_HANDSHAKE_FAIL = 1015;  // Reserved: TLS handshake failure

/**
 * Control frame errors
 */
faultdef CONTROL_PAYLOAD_TOO_LARGE, INVALID_CLOSE_STATUS, INVALID_UTF8_REASON,
         INVALID_FRAME_FORMAT;

/**
 * Validate close status code
 *
 * RFC 6455 §7.4.1: Valid status codes are:
 * - 1000-1011 (except 1004, 1005, 1006 which are reserved)
 * - 3000-3999 (application-specific)
 * - 4000-4999 (private use)
 */
fn bool is_valid_close_status(ushort code) @public
{
    // Standard codes (1000-1011)
    if (code >= 1000 && code <= 1011)
    {
        // Reserved codes that must not be sent
        if (code == 1004 || code == 1005 || code == 1006 || code == 1015)
        {
            return false;
        }
        return true;
    }

    // Application-specific (3000-3999)
    if (code >= 3000 && code <= 3999)
    {
        return true;
    }

    // Private use (4000-4999)
    if (code >= 4000 && code <= 4999)
    {
        return true;
    }

    // All other codes are invalid
    return false;
}

/**
 * Create an empty CLOSE frame (no status code)
 *
 * RFC 6455 §5.5.1: CLOSE frame may have no payload (no status code, no reason)
 * This is valid for responding to CLOSE frames without status codes.
 *
 * @return Frame data ready to send
 */
fn char[] create_empty_close_frame() @public
{
    // Build frame: [FIN=1, opcode=CLOSE][payload_len=0]
    char[] frame_data = mem::new_array(char, 2);
    frame_data[0] = 0x88;  // FIN=1, RSV=0, opcode=CLOSE
    frame_data[1] = 0x00;  // MASK=0, payload_len=0
    return frame_data;
}

/**
 * Create a CLOSE frame
 *
 * RFC 6455 §5.5.1: Close frame contains a status code (2 bytes)
 * and an optional UTF-8 reason (remaining payload)
 *
 * @param status_code - Close status code (1000-1011, 3000-4999)
 * @param reason - Optional UTF-8 reason string
 * @return Frame data ready to send
 */
fn char[]? create_close_frame(ushort status_code, String reason) @public
{
    // Validate status code
    if (!is_valid_close_status(status_code))
    {
        return INVALID_CLOSE_STATUS?;
    }

    // Calculate payload size
    ulong payload_len = 2; // Status code
    if (reason.len > 0)
    {
        payload_len += reason.len;
    }

    // RFC 6455 §5.5: Control frames must have payload ≤ 125 bytes
    if (payload_len > 125)
    {
        return CONTROL_PAYLOAD_TOO_LARGE?;
    }

    // Validate reason is UTF-8
    if (reason.len > 0)
    {
        utf8::Utf8Validator validator;
        validator.init();
        if (!validator.validate_incremental((char[])reason) || !validator.is_complete())
        {
            return INVALID_UTF8_REASON?;
        }
    }

    // Build frame: [FIN=1, opcode=CLOSE][payload_len][status_code][reason]
    ulong frame_len = 2 + payload_len; // Header (2 bytes) + payload
    char[] frame_data = mem::new_array(char, frame_len);

    // Byte 0: FIN=1, RSV=0, opcode=CLOSE (0x8)
    frame_data[0] = 0x88;

    // Byte 1: MASK=0, payload_len
    frame_data[1] = (char)payload_len;

    // Bytes 2-3: Status code (network byte order / big-endian)
    frame_data[2] = (char)(status_code >> 8);
    frame_data[3] = (char)(status_code & 0xFF);

    // Bytes 4+: Reason (if present)
    if (reason.len > 0)
    {
        foreach (i, c : reason)
        {
            frame_data[4 + i] = c;
        }
    }

    return frame_data;
}

/**
 * Create a PING frame
 *
 * RFC 6455 §5.5.2: Ping frame may contain application data
 *
 * @param payload - Application data (up to 125 bytes)
 * @return Frame data ready to send
 */
fn char[]? create_ping_frame(char[] payload) @public
{
    // RFC 6455 §5.5: Control frames must have payload ≤ 125 bytes
    if (payload.len > 125)
    {
        return CONTROL_PAYLOAD_TOO_LARGE?;
    }

    // Build frame: [FIN=1, opcode=PING][payload_len][payload]
    ulong frame_len = 2 + payload.len;
    char[] frame_data = mem::new_array(char, frame_len);

    // Byte 0: FIN=1, RSV=0, opcode=PING (0x9)
    frame_data[0] = 0x89;

    // Byte 1: MASK=0, payload_len
    frame_data[1] = (char)payload.len;

    // Bytes 2+: Payload
    if (payload.len > 0)
    {
        foreach (i, byte : payload)
        {
            frame_data[2 + i] = byte;
        }
    }

    return frame_data;
}

/**
 * Create a PONG frame (response to PING)
 *
 * RFC 6455 §5.5.3: Pong frame must echo the PING's application data
 *
 * @param payload - Application data from PING frame
 * @return Frame data ready to send
 */
fn char[]? create_pong_frame(char[] payload) @public
{
    // RFC 6455 §5.5: Control frames must have payload ≤ 125 bytes
    if (payload.len > 125)
    {
        return CONTROL_PAYLOAD_TOO_LARGE?;
    }

    // Build frame: [FIN=1, opcode=PONG][payload_len][payload]
    ulong frame_len = 2 + payload.len;
    char[] frame_data = mem::new_array(char, frame_len);

    // Byte 0: FIN=1, RSV=0, opcode=PONG (0xA)
    frame_data[0] = 0x8A;

    // Byte 1: MASK=0, payload_len
    frame_data[1] = (char)payload.len;

    // Bytes 2+: Payload (echo from PING)
    if (payload.len > 0)
    {
        foreach (i, byte : payload)
        {
            frame_data[2 + i] = byte;
        }
    }

    return frame_data;
}

/**
 * Parse status code from CLOSE frame
 *
 * RFC 6455 §5.5.1: First 2 bytes of payload are status code
 *
 * @param f - Parsed CLOSE frame
 * @return Status code
 */
fn ushort? parse_close_status(frame::Frame f) @public
{
    if (f.opcode != frame::Opcode.CLOSE)
    {
        return INVALID_FRAME_FORMAT?;
    }

    // CLOSE frame with no payload means no status code (abnormal)
    if (f.payload_len < 2)
    {
        return INVALID_FRAME_FORMAT?;
    }

    // Extract status code (network byte order)
    ushort status = ((ushort)f.payload[0] << 8) | (ushort)f.payload[1];

    return status;
}

/**
 * Validate CLOSE frame reason (UTF-8)
 *
 * RFC 6455 §5.5.1: Close reason must be valid UTF-8
 *
 * @param f - Parsed CLOSE frame
 * @return void or fault if invalid
 */
fn void? validate_close_reason(frame::Frame f) @public
{
    if (f.opcode != frame::Opcode.CLOSE)
    {
        return INVALID_FRAME_FORMAT?;
    }

    // If payload > 2 bytes, validate UTF-8 reason
    if (f.payload_len > 2)
    {
        char[] reason = f.payload[2:f.payload_len - 2];

        utf8::Utf8Validator validator;
        validator.init();

        if (!validator.validate_incremental(reason) || !validator.is_complete())
        {
            return INVALID_UTF8_REASON?;
        }
    }

    return;
}
