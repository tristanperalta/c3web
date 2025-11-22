/**
 * WebSocket Frame Parser
 *
 * RFC 6455 §5 - Data Framing
 * Parses WebSocket binary frame format with masking support
 */
module c3web::websocket::frame;

import std::io;
import std::core::bitorder;
import std::core::mem;

/**
 * WebSocket frame opcodes (RFC 6455 §5.2)
 */
enum Opcode : const char
{
    CONTINUATION = 0x0,  // Continuation frame
    TEXT         = 0x1,  // Text frame (UTF-8)
    BINARY       = 0x2,  // Binary frame
    // 0x3-0x7 reserved for non-control frames
    CLOSE        = 0x8,  // Connection close
    PING         = 0x9,  // Ping
    PONG         = 0xA,  // Pong
    // 0xB-0xF reserved for control frames
}

/**
 * Parsed WebSocket frame
 */
struct Frame
{
    bool fin;              // Final fragment flag
    bool rsv1;             // Reserved bit 1 (extensions)
    bool rsv2;             // Reserved bit 2 (extensions)
    bool rsv3;             // Reserved bit 3 (extensions)
    Opcode opcode;         // Frame opcode
    bool masked;           // Masking flag
    ulong payload_len;     // Payload length (decoded)
    char[4] mask_key;      // Masking key (if masked)
    char[] payload;        // Unmasked payload data
}

/**
 * Frame parsing errors
 */
faultdef INCOMPLETE_FRAME, INVALID_OPCODE, CONTROL_FRAME_TOO_LARGE,
         CONTROL_FRAME_FRAGMENTED, INVALID_PAYLOAD_LENGTH, INVALID_RSV_BITS;

/**
 * Check if opcode is a control frame
 *
 * RFC 6455 §5.5: Control frames have opcode high bit set (0x8-0xF)
 */
fn bool is_control_frame(Opcode opcode) @public
{
    return (((char)opcode) & 0x08) != 0;
}

/**
 * Check if opcode is valid
 *
 * RFC 6455 §5.2: Valid opcodes are 0x0-0x2, 0x8-0xA
 * Reserved: 0x3-0x7, 0xB-0xF
 */
fn bool is_valid_opcode(Opcode opcode) @public
{
    char op = (char)opcode;

    // Data frames: 0x0-0x2
    if (op <= 0x2) return true;

    // Control frames: 0x8-0xA
    if (op >= 0x8 && op <= 0xA) return true;

    // Everything else is reserved
    return false;
}

/**
 * Parse frame header only (without payload)
 *
 * Useful for determining how much data to read before parsing full frame.
 *
 * @param data - Raw frame bytes (at least 2 bytes)
 * @return Parsed frame header, or fault
 */
fn Frame? parse_header(char[] data, bool allow_rsv1 = false) @public
{
    if (data.len < 2)
    {
        return INCOMPLETE_FRAME?;
    }

    Frame f;

    // Byte 0: FIN, RSV, opcode
    char byte0 = data[0];
    f.fin = (byte0 & 0x80) != 0;
    f.rsv1 = (byte0 & 0x40) != 0;
    f.rsv2 = (byte0 & 0x20) != 0;
    f.rsv3 = (byte0 & 0x10) != 0;
    f.opcode = (Opcode)(byte0 & 0x0F);

    // RFC 6455 §5.2: RSV bits MUST be 0 unless extension defines meaning
    // RSV1 is allowed when permessage-deflate compression is enabled (RFC 7692)
    bool rsv1_ok = allow_rsv1 && f.rsv1 && !is_control_frame(f.opcode);
    if ((!rsv1_ok && f.rsv1) || f.rsv2 || f.rsv3)
    {
        return INVALID_RSV_BITS?;
    }

    // Validate opcode
    if (!is_valid_opcode(f.opcode))
    {
        return INVALID_OPCODE?;
    }

    // Byte 1: MASK, payload length
    char byte1 = data[1];
    f.masked = (byte1 & 0x80) != 0;
    char payload_len_first = byte1 & 0x7F;

    // Decode payload length
    ulong expected_header_size = 2;

    if (payload_len_first < 126)
    {
        // 7-bit length
        f.payload_len = (ulong)payload_len_first;
    }
    else if (payload_len_first == 126)
    {
        // 16-bit extended length
        expected_header_size += 2;
        if (data.len < expected_header_size)
        {
            return INCOMPLETE_FRAME?;
        }

        // Network byte order (big-endian)
        f.payload_len = bitorder::read(data[2:2], bitorder::UShortBE);
    }
    else // payload_len_first == 127
    {
        // 64-bit extended length
        expected_header_size += 8;
        if (data.len < expected_header_size)
        {
            return INCOMPLETE_FRAME?;
        }

        // Network byte order (big-endian)
        f.payload_len = bitorder::read(data[2:8], bitorder::ULongBE);
    }

    // Read masking key if present
    if (f.masked)
    {
        expected_header_size += 4;
        if (data.len < expected_header_size)
        {
            return INCOMPLETE_FRAME?;
        }

        ulong mask_offset = expected_header_size - 4;
        f.mask_key[0] = data[mask_offset];
        f.mask_key[1] = data[mask_offset + 1];
        f.mask_key[2] = data[mask_offset + 2];
        f.mask_key[3] = data[mask_offset + 3];
    }

    // RFC 6455 §5.5: Control frames MUST NOT be fragmented
    if (is_control_frame(f.opcode) && !f.fin)
    {
        return CONTROL_FRAME_FRAGMENTED?;
    }

    // RFC 6455 §5.5: Control frames MUST have payload <= 125 bytes
    if (is_control_frame(f.opcode) && f.payload_len > 125)
    {
        return CONTROL_FRAME_TOO_LARGE?;
    }

    return f;
}

/**
 * Unmask payload data
 *
 * RFC 6455 §5.3: XOR each byte with mask_key[i % 4]
 *
 * @param payload - Masked payload data (modified in place)
 * @param mask_key - 4-byte masking key
 */
fn void unmask_payload(char[] payload, char[4] mask_key) @public
{
    foreach (i, &byte : payload)
    {
        *byte ^= mask_key[i % 4];
    }
}

/**
 * Parse complete WebSocket frame
 *
 * @param data - Raw frame bytes (header + payload)
 * @return Parsed frame with unmasked payload, or fault
 */
fn Frame? parse(char[] data, bool allow_rsv1 = false) @public
{
    // Parse header first
    Frame f = parse_header(data, allow_rsv1)!;

    // Calculate header size to find payload offset
    ulong header_size = 2;

    char payload_len_first = data[1] & 0x7F;
    if (payload_len_first == 126)
    {
        header_size += 2;
    }
    else if (payload_len_first == 127)
    {
        header_size += 8;
    }

    if (f.masked)
    {
        header_size += 4;
    }

    // Check if we have complete frame
    ulong total_size = header_size + f.payload_len;
    if (data.len < total_size)
    {
        return INCOMPLETE_FRAME?;
    }

    // Extract payload
    if (f.payload_len > 0)
    {
        // Get payload slice from input data (inclusive start, length-based)
        f.payload = data[header_size:f.payload_len];

        // Unmask if needed
        if (f.masked)
        {
            unmask_payload(f.payload, f.mask_key);
        }
    }
    else
    {
        f.payload = {};
    }

    return f;
}

/**
 * Create a WebSocket frame
 *
 * @param opcode - Frame opcode
 * @param payload - Payload data
 * @param fin - Final frame flag
 * @param mask - Whether to mask the payload (client->server)
 * @return Serialized frame bytes
 */
fn char[] create_frame(Opcode opcode, char[] payload, bool fin, bool mask) @public
{
    return create_frame_with_rsv(opcode, payload, fin, mask, false, false, false);
}

/**
 * Create a WebSocket frame with RSV bits
 *
 * @param opcode - Frame opcode
 * @param payload - Payload data
 * @param fin - Final frame flag
 * @param mask - Whether to mask the payload (client->server)
 * @param rsv1 - Reserved bit 1 (compression)
 * @param rsv2 - Reserved bit 2
 * @param rsv3 - Reserved bit 3
 * @return Serialized frame bytes
 */
fn char[] create_frame_with_rsv(Opcode opcode, char[] payload, bool fin, bool mask,
                                  bool rsv1, bool rsv2, bool rsv3) @public
{
    // Calculate header size
    usz header_size = 2;
    if (payload.len >= 126 && payload.len <= 65535)
    {
        header_size += 2;
    }
    else if (payload.len > 65535)
    {
        header_size += 8;
    }

    if (mask)
    {
        header_size += 4;
    }

    // Allocate frame buffer
    char[] frame = mem::new_array(char, header_size + payload.len);

    // Byte 0: FIN, RSV, opcode
    frame[0] = (char)opcode;
    if (fin) frame[0] |= 0x80;
    if (rsv1) frame[0] |= 0x40;
    if (rsv2) frame[0] |= 0x20;
    if (rsv3) frame[0] |= 0x10;

    // Byte 1: MASK, payload length
    usz offset = 1;
    if (payload.len < 126)
    {
        frame[1] = (char)payload.len;
        if (mask) frame[1] |= 0x80;
        offset = 2;
    }
    else if (payload.len <= 65535)
    {
        frame[1] = 126;
        if (mask) frame[1] |= 0x80;
        // Big-endian 16-bit length
        frame[2] = (char)((payload.len >> 8) & 0xFF);
        frame[3] = (char)(payload.len & 0xFF);
        offset = 4;
    }
    else
    {
        frame[1] = 127;
        if (mask) frame[1] |= 0x80;
        // Big-endian 64-bit length
        for (int i = 0; i < 8; i++)
        {
            frame[2 + i] = (char)((payload.len >> (56 - i * 8)) & 0xFF);
        }
        offset = 10;
    }

    // Masking key (if masked)
    char[4] mask_key;
    if (mask)
    {
        // Use simple mask for now (server frames typically don't mask)
        // For client implementations, a proper PRNG should be used
        mask_key[0] = 0x37;
        mask_key[1] = 0xFA;
        mask_key[2] = 0x21;
        mask_key[3] = 0x3D;
        frame[offset] = mask_key[0];
        frame[offset + 1] = mask_key[1];
        frame[offset + 2] = mask_key[2];
        frame[offset + 3] = mask_key[3];
        offset += 4;
    }

    // Copy payload (mask if needed)
    for (usz i = 0; i < payload.len; i++)
    {
        if (mask)
        {
            frame[offset + i] = payload[i] ^ mask_key[i % 4];
        }
        else
        {
            frame[offset + i] = payload[i];
        }
    }

    return frame;
}
