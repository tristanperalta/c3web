/**
 * WebSocket Message Reassembly
 *
 * RFC 6455 §5.4 - Fragmentation
 * Handles message fragmentation and reassembly across multiple frames
 */
module c3web::websocket::message;

import c3web::websocket::frame;
import c3web::websocket::utf8;
import std::collections::list;
import std::io;

/**
 * Complete WebSocket message (after reassembly)
 */
struct Message
{
    frame::Opcode opcode;    // Original opcode (TEXT or BINARY)
    char[] payload;          // Complete message payload
    ulong payload_len;       // Total payload length
    bool compressed;         // RSV1 was set on first frame (RFC 7692)
}

/**
 * Message reassembly errors
 */
faultdef MESSAGE_TOO_LARGE, INVALID_UTF8, UNEXPECTED_CONTINUATION,
         UNEXPECTED_DATA_FRAME, INVALID_CONTROL_FRAME;

/**
 * Message builder for reassembling fragmented messages
 *
 * RFC 6455 §5.4:
 * - First frame: FIN=0, opcode=TEXT/BINARY
 * - Middle frames: FIN=0, opcode=CONTINUATION
 * - Final frame: FIN=1, opcode=CONTINUATION
 * - Control frames can be interleaved
 */
struct MessageBuilder
{
    bool in_progress;                 // Currently reassembling a fragmented message
    frame::Opcode message_opcode;     // Opcode of the first frame
    List{char} payload_data;          // Accumulated payload data
    ulong max_message_size;           // Maximum allowed message size
    utf8::Utf8Validator utf8_validator; // For streaming UTF-8 validation
    bool message_compressed;          // RSV1 was set on first frame (RFC 7692)
}

/**
 * Initialize message builder
 */
fn void MessageBuilder.init(&self) @public
{
    self.in_progress = false;
    self.message_opcode = frame::Opcode.CONTINUATION;
    // Pre-allocate 64KB to avoid repeated reallocations for large messages
    self.payload_data.init(mem, 64 * 1024);
    self.max_message_size = 10 * 1024 * 1024; // 10 MB default
    self.utf8_validator.init();
    self.message_compressed = false;
}

/**
 * Free message builder resources
 */
fn void MessageBuilder.free(&self) @public
{
    self.payload_data.free();
}

/**
 * Set maximum message size (for DoS prevention)
 */
fn void MessageBuilder.set_max_message_size(&self, ulong max_size) @public
{
    self.max_message_size = max_size;
}

/**
 * Reset builder state for next message
 */
fn void MessageBuilder.reset(&self) @public
{
    self.in_progress = false;
    self.message_opcode = frame::Opcode.CONTINUATION;
    self.payload_data.clear();
    self.utf8_validator.reset();
    self.message_compressed = false;
}

/**
 * Add payload data to the accumulated buffer
 */
fn void MessageBuilder.add_payload(&self, char[] data) @private
{
    // Use bulk copy instead of byte-by-byte (critical for 4MB+ messages)
    self.payload_data.push_all(data);
}

/**
 * Add a frame to the message builder
 *
 * @param f - Frame to add
 * @return true if message is complete, false if more fragments expected
 */
fn bool? MessageBuilder.add_frame(&self, frame::Frame f) @public
{
    // Control frames should not be passed to MessageBuilder
    // They should be handled separately by the connection
    if (frame::is_control_frame(f.opcode))
    {
        return INVALID_CONTROL_FRAME?;
    }

    // Case 1: Starting a new message
    if (!self.in_progress)
    {
        // Must be TEXT or BINARY, not CONTINUATION
        if (f.opcode == frame::Opcode.CONTINUATION)
        {
            return UNEXPECTED_CONTINUATION?;
        }

        // Start new message
        self.message_opcode = f.opcode;
        self.in_progress = true;
        self.utf8_validator.reset();
        // Track RSV1 from first frame (RFC 7692 compression indicator)
        self.message_compressed = f.rsv1;

        // Validate UTF-8 for text frames (skip if compressed - RSV1 set)
        // RFC 7692: Compressed data is NOT valid UTF-8, validation happens after decompression
        if (f.opcode == frame::Opcode.TEXT && f.payload_len > 0 && !f.rsv1)
        {
            if (!self.utf8_validator.validate_incremental(f.payload))
            {
                self.reset();
                return INVALID_UTF8?;
            }
        }

        // Add payload data
        if (f.payload_len > 0)
        {
            if (self.payload_data.len() + f.payload_len > self.max_message_size)
            {
                self.reset();
                return MESSAGE_TOO_LARGE?;
            }

            self.add_payload(f.payload);
        }

        // If FIN=1, message is complete
        if (f.fin)
        {
            // For text frames, validate UTF-8 is complete (skip if compressed)
            if (f.opcode == frame::Opcode.TEXT && !f.rsv1)
            {
                if (!self.utf8_validator.is_complete())
                {
                    self.reset();
                    return INVALID_UTF8?;
                }
            }
            return true;
        }

        // Message continues
        return false;
    }

    // Case 2: Continuing fragmented message
    // Must be CONTINUATION opcode
    if (f.opcode != frame::Opcode.CONTINUATION)
    {
        self.reset();
        return UNEXPECTED_DATA_FRAME?;
    }

    // Validate UTF-8 for text messages (skip if compressed)
    // RFC 7692: message_compressed is set from RSV1 on first frame
    if (self.message_opcode == frame::Opcode.TEXT && f.payload_len > 0 && !self.message_compressed)
    {
        if (!self.utf8_validator.validate_incremental(f.payload))
        {
            self.reset();
            return INVALID_UTF8?;
        }
    }

    // Add payload data
    if (f.payload_len > 0)
    {
        if (self.payload_data.len() + f.payload_len > self.max_message_size)
        {
            self.reset();
            return MESSAGE_TOO_LARGE?;
        }

        self.add_payload(f.payload);
    }

    // Check if message is complete
    if (f.fin)
    {
        // For text frames, validate UTF-8 is complete (skip if compressed)
        if (self.message_opcode == frame::Opcode.TEXT && !self.message_compressed)
        {
            if (!self.utf8_validator.is_complete())
            {
                self.reset();
                return INVALID_UTF8?;
            }
        }
        return true;
    }

    // More fragments expected
    return false;
}

/**
 * Get the complete message after reassembly
 *
 * Note: Returns a view into the builder's internal buffer.
 * The data is valid until the next reset() or free() call.
 *
 * @return Complete message with reassembled payload
 */
fn Message? MessageBuilder.get_message(&self) @public
{
    Message msg;
    msg.opcode = self.message_opcode;
    msg.payload = self.payload_data.array_view();
    msg.payload_len = self.payload_data.len();
    msg.compressed = self.message_compressed;
    return msg;
}
