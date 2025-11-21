/**
 * WebSocket Connection Management
 *
 * RFC 6455 - Complete WebSocket connection lifecycle
 * Manages connection state, message sending/receiving, and control frames
 */
module c3web::websocket::connection;

import c3web::websocket::frame;
import c3web::websocket::message;
import c3web::websocket::control;
import c3web::websocket::utf8;
import std::io;

/**
 * Connection states (RFC 6455 §4)
 */
enum State : const char
{
    CONNECTING = 0,  // Handshake in progress
    OPEN = 1,        // Connection established, can send/receive
    CLOSING = 2,     // Close frame sent, waiting for response
    CLOSED = 3,      // Connection closed
}

/**
 * Complete message (for public API)
 */
struct Message
{
    frame::Opcode opcode;
    char[] payload;
    ulong payload_len;
}

/**
 * WebSocket connection errors
 */
faultdef CONNECTION_CLOSED, INVALID_STATE, MESSAGE_INCOMPLETE,
         INVALID_UTF8_TEXT, CONTROL_FRAME_RECEIVED;

/**
 * WebSocket connection
 */
struct WebSocketConnection
{
    State state;                        // Current connection state
    message::MessageBuilder msg_builder; // For reassembling fragmented messages
    bool close_sent;                    // Track if we sent CLOSE
    bool close_received;                // Track if we received CLOSE
}

/**
 * Initialize WebSocket connection
 */
fn void WebSocketConnection.init(&self) @public
{
    self.state = State.OPEN;
    self.msg_builder.init();
    self.close_sent = false;
    self.close_received = false;
}

/**
 * Free connection resources
 */
fn void WebSocketConnection.free(&self) @public
{
    self.msg_builder.free();
}

/**
 * Send text message
 *
 * @param text - UTF-8 text message
 * @return Frame data ready to send
 */
fn char[]? WebSocketConnection.send_text(&self, String text) @public
{
    if (self.state != State.OPEN)
    {
        return CONNECTION_CLOSED?;
    }

    // Validate UTF-8
    utf8::Utf8Validator validator;
    validator.init();
    if (!validator.validate_incremental((char[])text) || !validator.is_complete())
    {
        return INVALID_UTF8_TEXT?;
    }

    // For now, send as single frame (no fragmentation)
    // TODO: Auto-fragment large messages
    return create_data_frame(frame::Opcode.TEXT, (char[])text, true);
}

/**
 * Send binary message
 *
 * @param data - Binary data
 * @return Frame data ready to send
 */
fn char[]? WebSocketConnection.send_binary(&self, char[] data) @public
{
    if (self.state != State.OPEN)
    {
        return CONNECTION_CLOSED?;
    }

    // Send as single frame (no fragmentation)
    // TODO: Auto-fragment large messages
    return create_data_frame(frame::Opcode.BINARY, data, true);
}

/**
 * Send PING frame
 *
 * @param payload - Application data (up to 125 bytes)
 * @return Frame data ready to send
 */
fn char[]? WebSocketConnection.send_ping(&self, char[] payload) @public
{
    if (self.state == State.CLOSED)
    {
        return CONNECTION_CLOSED?;
    }

    return control::create_ping_frame(payload);
}

/**
 * Send CLOSE frame
 *
 * @param status_code - Close status code
 * @param reason - Close reason (UTF-8)
 * @return Frame data ready to send
 */
fn char[]? WebSocketConnection.send_close(&self, ushort status_code, String reason) @public
{
    if (self.state == State.CLOSED)
    {
        return CONNECTION_CLOSED?;
    }

    self.state = State.CLOSING;
    self.close_sent = true;

    return control::create_close_frame(status_code, reason);
}

/**
 * Receive message from incoming frame data
 *
 * Handles fragmentation automatically. Returns message only when complete.
 *
 * @param frame_data - Raw frame bytes
 * @return Complete message, or fault if incomplete/control frame
 */
fn Message? WebSocketConnection.receive_message(&self, char[] frame_data) @public
{
    if (self.state == State.CLOSED)
    {
        return CONNECTION_CLOSED?;
    }

    // Parse frame
    frame::Frame f = frame::parse(frame_data)!;

    // Control frames should be handled separately
    if (frame::is_control_frame(f.opcode))
    {
        return CONTROL_FRAME_RECEIVED?;
    }

    // Add frame to message builder
    bool complete = self.msg_builder.add_frame(f)!;

    if (!complete)
    {
        // Message not yet complete (more fragments expected)
        return MESSAGE_INCOMPLETE?;
    }

    // Get complete message
    message::Message msg = self.msg_builder.get_message()!;

    // Reset builder for next message
    self.msg_builder.reset();

    // Convert to public Message type
    Message result;
    result.opcode = msg.opcode;
    result.payload = msg.payload;
    result.payload_len = msg.payload_len;

    return result;
}

/**
 * Handle control frame (PING, PONG, CLOSE)
 *
 * Returns appropriate response frame if needed.
 *
 * @param frame_data - Raw control frame bytes
 * @return Response frame (PONG for PING, CLOSE for CLOSE), or void
 */
fn char[]? WebSocketConnection.handle_control_frame(&self, char[] frame_data) @public
{
    // Parse frame
    frame::Frame f = frame::parse(frame_data)!;

    if (!frame::is_control_frame(f.opcode))
    {
        return INVALID_STATE?;
    }

    switch (f.opcode)
    {
        case frame::Opcode.PING:
            // Respond with PONG (echo payload)
            return control::create_pong_frame(f.payload);

        case frame::Opcode.PONG:
            // Unsolicited PONG - just ignore (return empty array = no response needed)
            return {};

        case frame::Opcode.CLOSE:
            // Handle close handshake
            self.close_received = true;

            if (!self.close_sent)
            {
                // We haven't sent CLOSE yet - respond with CLOSE
                self.state = State.CLOSED;
                ushort status = control::CLOSE_NORMAL;

                // Try to extract status from incoming CLOSE
                if (try received_status = control::parse_close_status(f))
                {
                    status = received_status;
                }

                return control::create_close_frame(status, "");
            }
            else
            {
                // We already sent CLOSE, now received response - close complete
                self.state = State.CLOSED;
                return {}; // No response needed
            }

        default:
            return INVALID_STATE?;
    }
}

/**
 * Create a data frame (TEXT or BINARY)
 *
 * @param opcode - TEXT or BINARY
 * @param payload - Frame payload
 * @param fin - FIN flag (true for final/only frame)
 * @return Frame data ready to send
 */
fn char[]? create_data_frame(frame::Opcode opcode, char[] payload, bool fin) @private
{
    // Calculate frame size
    // Header: 2 bytes minimum (could be more for extended length)
    ulong header_size = 2;
    ulong payload_len = payload.len;

    if (payload_len > 125 && payload_len <= 65535)
    {
        header_size += 2; // 16-bit extended length
    }
    else if (payload_len > 65535)
    {
        header_size += 8; // 64-bit extended length
    }

    ulong total_size = header_size + payload_len;
    char[] frame_data = mem::new_array(char, total_size);

    // Byte 0: FIN, RSV=0, opcode
    char byte0 = (char)opcode;
    if (fin)
    {
        byte0 |= 0x80; // Set FIN bit
    }
    frame_data[0] = byte0;

    // Byte 1+: MASK=0, payload length
    usz offset = 2;

    if (payload_len <= 125)
    {
        frame_data[1] = (char)payload_len;
    }
    else if (payload_len <= 65535)
    {
        frame_data[1] = 126;
        // 16-bit length (network byte order)
        frame_data[2] = (char)(payload_len >> 8);
        frame_data[3] = (char)(payload_len & 0xFF);
        offset = 4;
    }
    else
    {
        frame_data[1] = 127;
        // 64-bit length (network byte order)
        frame_data[2] = (char)(payload_len >> 56);
        frame_data[3] = (char)(payload_len >> 48);
        frame_data[4] = (char)(payload_len >> 40);
        frame_data[5] = (char)(payload_len >> 32);
        frame_data[6] = (char)(payload_len >> 24);
        frame_data[7] = (char)(payload_len >> 16);
        frame_data[8] = (char)(payload_len >> 8);
        frame_data[9] = (char)(payload_len & 0xFF);
        offset = 10;
    }

    // Copy payload
    foreach (i, byte : payload)
    {
        frame_data[offset + i] = byte;
    }

    return frame_data;
}
