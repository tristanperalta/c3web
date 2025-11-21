/**
 * WebSocket Message Reassembly
 *
 * RFC 6455 §5.4 - Fragmentation
 * Handles message fragmentation and reassembly across multiple frames
 */
module c3web::websocket::message;

import c3web::websocket::frame;
import c3web::websocket::utf8;
import std::io;

/**
 * Complete WebSocket message (after reassembly)
 */
struct Message
{
    frame::Opcode opcode;    // Original opcode (TEXT or BINARY)
    char[] payload;          // Complete message payload
    ulong payload_len;       // Total payload length
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
/**
 * Fragment entry for tracking payload chunks
 */
struct Fragment
{
    char[] data;
    ulong len;
}

struct MessageBuilder
{
    bool in_progress;                 // Currently reassembling a fragmented message
    frame::Opcode message_opcode;     // Opcode of the first frame
    Fragment[] fragments;             // Dynamic array of payload fragments
    usz fragment_count;               // Number of fragments
    ulong total_size;                 // Total size accumulated
    ulong max_message_size;           // Maximum allowed message size
    utf8::Utf8Validator utf8_validator; // For streaming UTF-8 validation
}

/**
 * Initialize message builder
 */
fn void MessageBuilder.init(&self) @public
{
    self.in_progress = false;
    self.message_opcode = frame::Opcode.CONTINUATION;
    self.fragments = {};
    self.fragment_count = 0;
    self.total_size = 0;
    self.max_message_size = 10 * 1024 * 1024; // 10 MB default
    self.utf8_validator.init();
}

/**
 * Free message builder resources
 */
fn void MessageBuilder.free(&self) @public
{
    if (self.fragments.len > 0)
    {
        mem::free(self.fragments.ptr);
    }
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
    self.fragment_count = 0;
    self.total_size = 0;
    self.utf8_validator.reset();
}

/**
 * Add a fragment to the internal array
 */
fn void MessageBuilder.add_fragment(&self, char[] data, ulong len) @private
{
    // Grow array if needed
    if (self.fragment_count >= self.fragments.len)
    {
        usz new_cap = self.fragments.len == 0 ? 4 : self.fragments.len * 2;
        Fragment[] new_fragments = mem::new_array(Fragment, new_cap);

        // Copy existing fragments
        foreach (i, frag : self.fragments)
        {
            new_fragments[i] = frag;
        }

        // Free old array
        if (self.fragments.len > 0)
        {
            mem::free(self.fragments.ptr);
        }

        self.fragments = new_fragments;
    }

    // Add new fragment
    self.fragments[self.fragment_count].data = data;
    self.fragments[self.fragment_count].len = len;
    self.fragment_count++;
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

        // Validate UTF-8 for text frames
        if (f.opcode == frame::Opcode.TEXT && f.payload_len > 0)
        {
            if (!self.utf8_validator.validate_incremental(f.payload))
            {
                self.reset();
                return INVALID_UTF8?;
            }
        }

        // Add payload fragment
        if (f.payload_len > 0)
        {
            self.total_size += f.payload_len;
            if (self.total_size > self.max_message_size)
            {
                self.reset();
                return MESSAGE_TOO_LARGE?;
            }

            // Add fragment to array
            self.add_fragment(f.payload, f.payload_len);
        }

        // If FIN=1, message is complete
        if (f.fin)
        {
            // For text frames, validate UTF-8 is complete
            if (f.opcode == frame::Opcode.TEXT)
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

    // Validate UTF-8 for text messages
    if (self.message_opcode == frame::Opcode.TEXT && f.payload_len > 0)
    {
        if (!self.utf8_validator.validate_incremental(f.payload))
        {
            self.reset();
            return INVALID_UTF8?;
        }
    }

    // Add fragment
    if (f.payload_len > 0)
    {
        self.total_size += f.payload_len;
        if (self.total_size > self.max_message_size)
        {
            self.reset();
            return MESSAGE_TOO_LARGE?;
        }

        // Add fragment to array
        self.add_fragment(f.payload, f.payload_len);
    }

    // Check if message is complete
    if (f.fin)
    {
        // For text frames, validate UTF-8 is complete
        if (self.message_opcode == frame::Opcode.TEXT)
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
 * @return Complete message with reassembled payload
 */
fn Message? MessageBuilder.get_message(&self) @public
{
    if (self.fragment_count == 0)
    {
        // Empty message (just headers)
        Message msg;
        msg.opcode = self.message_opcode;
        msg.payload = {};
        msg.payload_len = 0;
        return msg;
    }

    // Allocate buffer for complete message
    char[] complete_payload = mem::new_array(char, self.total_size);

    // Copy all fragments into buffer
    ulong offset = 0;
    for (usz i = 0; i < self.fragment_count; i++)
    {
        Fragment frag = self.fragments[i];
        foreach (j, byte : frag.data)
        {
            complete_payload[offset + j] = byte;
        }
        offset += frag.len;
    }

    Message msg;
    msg.opcode = self.message_opcode;
    msg.payload = complete_payload;
    msg.payload_len = self.total_size;

    return msg;
}
