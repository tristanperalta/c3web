/**
 * HTTP/1.1 Chunked Transfer Encoding Parser
 *
 * Implements RFC 9112 §7.1 - Chunked Transfer Coding
 *
 * Format:
 *   chunk-size [ chunk-ext ] CRLF
 *   chunk-data CRLF
 *   ...
 *   0 [ chunk-ext ] CRLF
 *   [ trailer-section ] CRLF
 */
module c3web::http1::chunked;

import c3web::common::headers;
import std::collections::list;

// Chunked encoding faults
faultdef INVALID_CHUNK_SIZE, INVALID_CHUNK_FORMAT, CHUNK_TOO_LARGE;

// Chunked parser states
enum ChunkedState {
    CHUNK_SIZE,        // Reading hex chunk size
    CHUNK_SIZE_LF,     // Expecting LF after chunk size line
    CHUNK_DATA,        // Reading chunk data bytes
    CHUNK_DATA_CR,     // Expecting CR after chunk data
    CHUNK_DATA_LF,     // Expecting LF after chunk data
    TRAILER_HEADERS,   // Reading trailer headers
    COMPLETE,          // Last chunk (size 0) received
}

/**
 * Chunked encoding parser
 * Incrementally decodes chunked transfer encoding
 */
struct ChunkedParser {
    ChunkedState state;
    usz current_chunk_size;    // Size of current chunk being read
    usz current_chunk_read;    // Bytes read from current chunk
    DynamicArenaAllocator chunk_size_arena;  // For parsing chunk size line
    List{char} chunk_size_buffer;  // Accumulates chunk size line
    List{char} body_data;          // Accumulated decoded body
    headers::HeaderMap* trailers;  // Optional trailer headers
    usz max_chunk_size;           // Maximum allowed chunk size (default 16MB)
}

const usz DEFAULT_MAX_CHUNK_SIZE = 16 * 1024 * 1024;  // 16 MB

<* Initialize chunked parser *>
fn void ChunkedParser.init(&self, headers::HeaderMap* trailers, Allocator allocator = mem) {
    self.state = ChunkedState.CHUNK_SIZE;
    self.current_chunk_size = 0;
    self.current_chunk_read = 0;
    self.chunk_size_arena.init(allocator, 256);
    self.chunk_size_buffer.init(allocator);
    self.body_data.init(allocator);
    self.trailers = trailers;
    self.max_chunk_size = DEFAULT_MAX_CHUNK_SIZE;
}

<* Free chunked parser resources *>
fn void ChunkedParser.free(&self) {
    self.chunk_size_arena.free();
    self.chunk_size_buffer.free();
    self.body_data.free();
}

<* Reset chunked parser for reuse *>
fn void ChunkedParser.reset(&self) {
    self.state = ChunkedState.CHUNK_SIZE;
    self.current_chunk_size = 0;
    self.current_chunk_read = 0;
    self.chunk_size_buffer.clear();
    self.body_data.clear();
}

<*
 * Parse hex chunk size from buffer
 * Handles chunk extensions (ignores them per RFC 9112 §7.1.1)
 *>
fn usz? parse_chunk_size(char[] line) {
    if (line.len == 0) {
        return INVALID_CHUNK_SIZE?;
    }

    // Find semicolon (chunk extension separator) or end of line
    usz size_end = line.len;
    foreach (i, c : line) {
        if (c == ';') {
            size_end = i;
            break;
        }
    }

    // Parse hex digits
    usz chunk_size = 0;
    for (usz i = 0; i < size_end; i++) {
        char c = line[i];

        // Skip whitespace (OWS allowed before chunk-size)
        if (c == ' ' || c == '\t') {
            if (i > 0) break;  // Whitespace after hex digits ends parsing
            continue;
        }

        // Convert hex digit to value
        usz digit_value;
        if (c >= '0' && c <= '9') {
            digit_value = (usz)(c - '0');
        } else if (c >= 'a' && c <= 'f') {
            digit_value = (usz)(c - 'a' + 10);
        } else if (c >= 'A' && c <= 'F') {
            digit_value = (usz)(c - 'A' + 10);
        } else {
            return INVALID_CHUNK_SIZE?;
        }

        // Check for overflow
        if (chunk_size > (usz.max / 16u)) {
            return CHUNK_TOO_LARGE?;
        }

        chunk_size = chunk_size * 16 + digit_value;
    }

    return chunk_size;
}

<*
 * Feed data into chunked parser
 * Returns true when complete (last chunk received)
 *>
fn bool? ChunkedParser.feed(&self, char[] data) {
    usz i = 0;
    while (i < data.len) {
        char c = data[i];

        switch (self.state) {
            case CHUNK_SIZE:
                if (c == '\r') {
                    // CR signals end of chunk size line
                    self.state = ChunkedState.CHUNK_SIZE_LF;
                    i++;
                } else {
                    // Accumulate chunk size line
                    self.chunk_size_buffer.push(c);
                    i++;
                }

            case CHUNK_SIZE_LF:
                if (c != '\n') {
                    return INVALID_CHUNK_FORMAT?;
                }

                // Parse chunk size
                char[] size_line = self.chunk_size_buffer.array_view();
                usz? chunk_size = parse_chunk_size(size_line);
                if (catch err = chunk_size) {
                    return err?;
                }

                // Check max chunk size
                if (chunk_size > self.max_chunk_size) {
                    return CHUNK_TOO_LARGE?;
                }

                self.current_chunk_size = chunk_size;
                self.current_chunk_read = 0;
                self.chunk_size_buffer.clear();

                // If chunk size is 0, this is the last chunk
                if (chunk_size == 0) {
                    self.state = ChunkedState.TRAILER_HEADERS;
                } else {
                    self.state = ChunkedState.CHUNK_DATA;
                }
                i++;

            case CHUNK_DATA:
                // Read chunk data bytes
                usz remaining = self.current_chunk_size - self.current_chunk_read;
                usz available = data.len - i;
                usz to_read = remaining < available ? remaining : available;

                // Copy chunk data to body
                for (usz j = 0; j < to_read; j++) {
                    self.body_data.push(data[i + j]);
                }

                self.current_chunk_read += to_read;
                i += to_read;

                // If chunk complete, expect CRLF
                if (self.current_chunk_read == self.current_chunk_size) {
                    self.state = ChunkedState.CHUNK_DATA_CR;
                }

            case CHUNK_DATA_CR:
                if (c != '\r') {
                    return INVALID_CHUNK_FORMAT?;
                }
                self.state = ChunkedState.CHUNK_DATA_LF;
                i++;

            case CHUNK_DATA_LF:
                if (c != '\n') {
                    return INVALID_CHUNK_FORMAT?;
                }
                // Ready for next chunk
                self.state = ChunkedState.CHUNK_SIZE;
                i++;

            case TRAILER_HEADERS:
                // Parse trailer headers line by line
                // Look for CRLF to find end of line
                if (c == '\r' && i + 1 < data.len && data[i + 1] == '\n') {
                    // Found CRLF
                    char[] line_data = self.chunk_size_buffer.array_view();
                    String line = (String)line_data;

                    if (line.len == 0) {
                        // Empty line = end of trailers
                        self.state = ChunkedState.COMPLETE;
                        i += 2;  // Skip CRLF
                        return true;  // Complete!
                    }

                    // Parse trailer header
                    headers::HeaderField? field = headers::parse_header_line(line);
                    if (catch err = field) {
                        return INVALID_CHUNK_FORMAT?;
                    }

                    // Copy strings to arena (chunk_size_buffer will be cleared)
                    String name_copy = field.name.copy(&self.chunk_size_arena);
                    String value_copy = field.value.copy(&self.chunk_size_arena);

                    // Add to trailers map
                    self.trailers.add(name_copy, value_copy)!;

                    // Clear buffer for next line
                    self.chunk_size_buffer.clear();
                    i += 2;  // Skip CRLF
                } else if (c == '\n') {
                    // Bare LF - security violation
                    return INVALID_CHUNK_FORMAT?;
                } else {
                    // Accumulate trailer header line
                    self.chunk_size_buffer.push(c);
                    i++;
                }

            case COMPLETE:
                // Already complete, ignore extra data
                return true;
        }
    }

    // Need more data
    return false;
}

<* Get decoded body data *>
fn char[] ChunkedParser.get_body(&self) {
    return self.body_data.array_view();
}

<* Check if chunked parsing is complete *>
fn bool ChunkedParser.is_complete(&self) {
    return self.state == ChunkedState.COMPLETE;
}
