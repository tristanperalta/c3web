/**
 * WebSocket Compression Module
 *
 * RFC 7692 - Compression Extensions for WebSocket (permessage-deflate)
 *
 * This module provides:
 * - DEFLATE compression/decompression contexts
 * - Extension parameter negotiation
 * - Per-message compression with RSV1 handling
 */
module c3web::websocket::compression;

import c3web::websocket::frame;
import std::core::mem;
import std::core::string;
import std::core::dstring;
import miniz;

// ============================================================================
// Error Definitions
// ============================================================================

faultdef INIT_FAILED, COMPRESS_FAILED, DECOMPRESS_FAILED, INVALID_EXTENSION,
         INVALID_WINDOW_BITS, INVALID_COMPRESSED_CONTROL_FRAME;

// ============================================================================
// Extension Parameters (RFC 7692 Section 7.1)
// ============================================================================

struct ExtensionParams
{
    int server_max_window_bits;      // 8-15, default 15
    int client_max_window_bits;      // 8-15, default 15
    bool server_no_context_takeover; // Reset context after each message
    bool client_no_context_takeover; // Reset context after each message
}

fn ExtensionParams default_extension_params()
{
    return {
        .server_max_window_bits = 15,
        .client_max_window_bits = 15,
        .server_no_context_takeover = false,
        .client_no_context_takeover = false
    };
}

// ============================================================================
// Low-Level Deflate Context
// ============================================================================

struct DeflateContext
{
    miniz::MzStream stream;
    bool initialized;
    int window_bits;
}

fn void? DeflateContext.init(&self, int window_bits = 15)
{
    // miniz only supports window_bits of exactly 15, so we always use 15
    // The window_bits parameter is stored for API compatibility
    self.window_bits = window_bits;

    // Zero-initialize the stream
    mem::clear(&self.stream, miniz::MzStream.sizeof);

    // Use negative window bits for raw deflate (no zlib header)
    // miniz only supports -15 for raw deflate
    int ret = miniz::mz_deflateInit2(
        &self.stream,
        miniz::MZ_DEFAULT_LEVEL,
        miniz::MZ_DEFLATED,
        -15,  // Negative = raw deflate, miniz only supports -15
        8,    // mem_level
        miniz::MZ_DEFAULT_STRATEGY
    );

    if (ret != miniz::MZ_OK)
    {
        return INIT_FAILED?;
    }

    self.initialized = true;
}

fn char[]? DeflateContext.compress(&self, char[] input)
{
    if (!self.initialized)
    {
        return COMPRESS_FAILED?;
    }

    // Get upper bound for output size
    ulong bound = miniz::mz_deflateBound(&self.stream, input.len);

    // Allocate output buffer (add space for trailing bytes we'll strip)
    char[] output = mem::new_array(char, bound + 4);

    // Save initial total_out for calculating this operation's output size
    ulong initial_total_out = self.stream.total_out;

    // Set up stream
    self.stream.next_in = input.ptr;
    self.stream.avail_in = (uint)input.len;
    self.stream.next_out = output.ptr;
    self.stream.avail_out = (uint)output.len;

    // Compress with SYNC_FLUSH to get complete deflate block
    int ret = miniz::mz_deflate(&self.stream, miniz::MZ_SYNC_FLUSH);

    if (ret != miniz::MZ_OK && ret != miniz::MZ_STREAM_END)
    {
        mem::free(output.ptr);
        return COMPRESS_FAILED?;
    }

    // Calculate actual output size (difference from initial)
    usz output_size = (usz)(self.stream.total_out - initial_total_out);

    // RFC 7692: Strip trailing 0x00 0x00 0xFF 0xFF (SYNC_FLUSH marker)
    if (output_size >= 4 &&
        output[output_size - 4] == 0x00 &&
        output[output_size - 3] == 0x00 &&
        output[output_size - 2] == (char)0xFF &&
        output[output_size - 1] == (char)0xFF)
    {
        output_size -= 4;
    }

    // Return correctly sized slice
    return output[0:output_size];
}

fn void? DeflateContext.reset(&self)
{
    if (!self.initialized)
    {
        return INIT_FAILED?;
    }

    int ret = miniz::mz_deflateReset(&self.stream);
    if (ret != miniz::MZ_OK)
    {
        return INIT_FAILED?;
    }
}

fn void DeflateContext.free(&self)
{
    if (self.initialized)
    {
        miniz::mz_deflateEnd(&self.stream);
        self.initialized = false;
    }
}

// ============================================================================
// Low-Level Inflate Context
// ============================================================================

struct InflateContext
{
    miniz::MzStream stream;
    bool initialized;
    int window_bits;
}

fn void? InflateContext.init(&self, int window_bits = 15)
{
    // miniz only supports window_bits of exactly 15, so we always use 15
    // The window_bits parameter is stored for API compatibility
    self.window_bits = window_bits;

    // Zero-initialize the stream
    mem::clear(&self.stream, miniz::MzStream.sizeof);

    // Use negative window bits for raw inflate (no zlib header)
    // miniz only supports -15 for raw inflate
    int ret = miniz::mz_inflateInit2(&self.stream, -15);

    if (ret != miniz::MZ_OK)
    {
        return INIT_FAILED?;
    }

    self.initialized = true;
}

fn char[]? InflateContext.decompress(&self, char[] input)
{
    if (!self.initialized)
    {
        return DECOMPRESS_FAILED?;
    }

    // RFC 7692: Append trailing 0x00 0x00 0xFF 0xFF before decompressing
    char[] input_with_trailer = mem::new_array(char, input.len + 4);
    mem::copy(input_with_trailer.ptr, input.ptr, input.len);
    input_with_trailer[input.len] = 0x00;
    input_with_trailer[input.len + 1] = 0x00;
    input_with_trailer[input.len + 2] = (char)0xFF;
    input_with_trailer[input.len + 3] = (char)0xFF;
    defer mem::free(input_with_trailer.ptr);

    // Save initial total_out for calculating this operation's output size
    ulong initial_total_out = self.stream.total_out;

    // Start with reasonable output buffer size
    usz output_capacity = input.len * 4;
    if (output_capacity < 256) output_capacity = 256;

    char[] output = mem::new_array(char, output_capacity);
    usz output_size = 0;

    // Set up stream
    self.stream.next_in = input_with_trailer.ptr;
    self.stream.avail_in = (uint)input_with_trailer.len;

    // Decompress in a loop (output may be larger than input)
    while (true)
    {
        self.stream.next_out = &output[output_size];
        self.stream.avail_out = (uint)(output_capacity - output_size);

        int ret = miniz::mz_inflate(&self.stream, miniz::MZ_SYNC_FLUSH);

        // Calculate output size relative to initial position
        output_size = (usz)(self.stream.total_out - initial_total_out);

        if (ret == miniz::MZ_STREAM_END)
        {
            break;
        }

        if (ret != miniz::MZ_OK && ret != miniz::MZ_BUF_ERROR)
        {
            mem::free(output.ptr);
            return DECOMPRESS_FAILED?;
        }

        // If we need more output space, expand buffer and continue
        // (even if avail_in == 0, inflator may have buffered data to flush)
        if (self.stream.avail_out == 0)
        {
            usz new_capacity = output_capacity * 2;
            char[] new_output = mem::new_array(char, new_capacity);
            mem::copy(new_output.ptr, output.ptr, output_size);
            mem::free(output.ptr);
            output = new_output;
            output_capacity = new_capacity;
            continue;
        }

        // If we consumed all input and have available output space, we're done
        if (self.stream.avail_in == 0)
        {
            break;
        }
    }

    return output[0:output_size];
}

fn void? InflateContext.reset(&self)
{
    if (!self.initialized)
    {
        return INIT_FAILED?;
    }

    int ret = miniz::mz_inflateReset(&self.stream);
    if (ret != miniz::MZ_OK)
    {
        return INIT_FAILED?;
    }
}

fn void InflateContext.free(&self)
{
    if (self.initialized)
    {
        miniz::mz_inflateEnd(&self.stream);
        self.initialized = false;
    }
}

// ============================================================================
// Extension Negotiation
// ============================================================================

/**
 * Parse Sec-WebSocket-Extensions header value
 */
fn ExtensionParams? parse_extension(String header)
{
    // Check for permessage-deflate
    if (!header.contains("permessage-deflate"))
    {
        return INVALID_EXTENSION?;
    }

    ExtensionParams params = default_extension_params();

    // Parse server_max_window_bits
    if (header.contains("server_max_window_bits="))
    {
        // Find and parse the value
        if (try pos = header.index_of("server_max_window_bits="))
        {
            usz start = pos + 23;
            // Parse digits
            int value = 0;
            while (start < header.len && header[start] >= '0' && header[start] <= '9')
            {
                value = value * 10 + (header[start] - '0');
                start++;
            }
            if (is_valid_window_bits(value))
            {
                params.server_max_window_bits = value;
            }
        }
    }

    // Parse client_max_window_bits
    if (header.contains("client_max_window_bits="))
    {
        if (try pos = header.index_of("client_max_window_bits="))
        {
            usz start = pos + 23;
            int value = 0;
            while (start < header.len && header[start] >= '0' && header[start] <= '9')
            {
                value = value * 10 + (header[start] - '0');
                start++;
            }
            if (is_valid_window_bits(value))
            {
                params.client_max_window_bits = value;
            }
        }
    }

    // Parse boolean flags
    params.server_no_context_takeover = header.contains("server_no_context_takeover");
    params.client_no_context_takeover = header.contains("client_no_context_takeover");

    return params;
}

/**
 * Validate window bits value (must be 8-15)
 */
fn bool is_valid_window_bits(int bits)
{
    return bits >= 8 && bits <= 15;
}

/**
 * Generate Sec-WebSocket-Extensions response header
 */
fn String generate_response_header(ExtensionParams params)
{
    DString response;
    response.tinit();  // Use temp allocator so it's auto-freed
    response.append("permessage-deflate");

    if (params.server_max_window_bits != 15)
    {
        response.appendf("; server_max_window_bits=%d", params.server_max_window_bits);
    }

    if (params.client_max_window_bits != 15)
    {
        response.appendf("; client_max_window_bits=%d", params.client_max_window_bits);
    }

    if (params.server_no_context_takeover)
    {
        response.append("; server_no_context_takeover");
    }

    if (params.client_no_context_takeover)
    {
        response.append("; client_no_context_takeover");
    }

    // Return copy that caller must free
    return response.copy_str(mem);
}

// ============================================================================
// Per-Message Deflate Handler
// ============================================================================

struct PerMessageDeflate
{
    DeflateContext deflate;
    InflateContext inflate;
    ExtensionParams params;
    bool initialized;
}

fn void? PerMessageDeflate.init(&self, ExtensionParams params)
{
    self.params = params;

    // Default to 15 if not set (0 means uninitialized)
    int server_bits = params.server_max_window_bits;
    int client_bits = params.client_max_window_bits;
    if (server_bits == 0 || server_bits > 15) server_bits = 15;
    if (client_bits == 0 || client_bits > 15) client_bits = 15;
    // Window bits 8 workaround: use 9 instead (zlib quirk - zlib doesn't support 8)
    if (server_bits == 8) server_bits = 9;
    if (client_bits == 8) client_bits = 9;

    self.deflate.init(server_bits)!;
    self.inflate.init(client_bits)!;
    self.initialized = true;
}

fn void PerMessageDeflate.free(&self)
{
    if (self.initialized)
    {
        self.deflate.free();
        self.inflate.free();
        self.initialized = false;
    }
}

/**
 * Compress a message payload
 */
fn char[]? PerMessageDeflate.compress_message(&self, char[] payload)
{
    char[] compressed = self.deflate.compress(payload)!;

    // Reset context if no_context_takeover is set
    if (self.params.server_no_context_takeover)
    {
        self.deflate.reset()!;
    }

    return compressed;
}

/**
 * Decompress a message payload
 */
fn char[]? PerMessageDeflate.decompress_message(&self, char[] payload)
{
    char[] decompressed = self.inflate.decompress(payload)!;

    // Reset context if no_context_takeover is set
    if (self.params.client_no_context_takeover)
    {
        self.inflate.reset()!;
    }

    return decompressed;
}

/**
 * Create a compressed frame with proper RSV1 handling
 */
fn char[]? PerMessageDeflate.compress_frame(&self, frame::Opcode opcode, char[] payload, bool is_first_frame)
{
    // Control frames cannot be compressed
    if (frame::is_control_frame(opcode))
    {
        return frame::create_frame(opcode, payload, true, false);
    }

    char[] compressed = self.compress_message(payload)!;
    defer mem::free(compressed.ptr);

    // Set RSV1 only on first frame of message
    bool rsv1 = is_first_frame;

    return frame::create_frame_with_rsv(opcode, compressed, true, false, rsv1, false, false);
}

/**
 * Validate that a frame doesn't violate compression rules
 */
fn void? PerMessageDeflate.validate_frame(&self, char[] frame_data)
{
    if (frame_data.len < 2)
    {
        return INVALID_EXTENSION?;
    }

    char first_byte = frame_data[0];
    bool rsv1 = (first_byte & 0x40) != 0;
    frame::Opcode opcode = (frame::Opcode)(first_byte & 0x0F);

    // Control frames must not have RSV1 set
    if (rsv1 && frame::is_control_frame(opcode))
    {
        return INVALID_COMPRESSED_CONTROL_FRAME?;
    }
}
