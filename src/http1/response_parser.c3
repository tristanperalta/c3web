/**
 * HTTP/1.1 Response Parser
 *
 * Incremental state machine parser for HTTP/1.1 responses per RFC 9112.
 * Handles streaming data that arrives in chunks.
 */
module c3web::http1::response_parser;

import c3web::common::status;
import c3web::common::version;
import c3web::common::headers;
import c3web::http1::client_response;
import c3web::http1::chunked;
import std::io;
import std::core::string;

/**
 * Parser states for incremental parsing
 */
enum ParserState : char {
    START,
    STATUS_LINE,
    HEADERS,
    BODY,
    COMPLETE,
    ERROR,
}

/**
 * Result of parse operation
 */
enum ParseResult : char {
    MORE,      // Need more data
    COMPLETE,  // Parsing complete
    ERROR,     // Parse error
}

faultdef PARSE_ERROR, INVALID_STATUS_LINE, HEADER_TOO_LARGE, RESPONSE_TOO_LARGE;
faultdef PROTOCOL_VIOLATION;  // bare LF, null bytes, etc.

/**
 * Incremental HTTP/1.1 response parser
 */
struct ResponseParser {
    ParserState state;
    io::ByteBuffer buffer;
    client_response::ClientResponse response;
    usz bytes_parsed;
    usz max_header_size;
    usz max_response_size;
    bool is_chunked;                    // True if Transfer-Encoding: chunked
    chunked::ChunkedParser chunked_parser;  // For chunked encoding
}

// Parser configuration defaults
const usz DEFAULT_MAX_HEADER_SIZE = 8 * 1024;        // 8KB
const usz DEFAULT_MAX_RESPONSE_SIZE = 10 * 1024 * 1024;  // 10MB
const usz INITIAL_BUFFER_SIZE = 4 * 1024;            // 4KB

/**
 * Initialize parser with default limits.
 */
fn void ResponseParser.init(&self, Allocator allocator = mem) {
    self.state = ParserState.START;
    self.buffer.init(allocator, DEFAULT_MAX_RESPONSE_SIZE, INITIAL_BUFFER_SIZE);
    self.response.init(allocator);
    self.bytes_parsed = 0;
    self.max_header_size = DEFAULT_MAX_HEADER_SIZE;
    self.max_response_size = DEFAULT_MAX_RESPONSE_SIZE;
    self.is_chunked = false;
    self.chunked_parser.init(&self.response.trailers, allocator);
}

/**
 * Free parser resources.
 */
fn void ResponseParser.free(&self) {
    self.buffer.free();
    self.response.free();
    self.chunked_parser.free();
}

/**
 * Reset parser to initial state for connection reuse.
 */
fn void ResponseParser.reset(&self) {
    self.state = ParserState.START;
    self.buffer.read_idx = 0;
    self.buffer.write_idx = 0;
    self.response.reset();
    self.bytes_parsed = 0;
    self.is_chunked = false;
    self.chunked_parser.reset();
}

/**
 * Feed data to parser. Returns parse result.
 * Call repeatedly as data arrives from network.
 */
fn ParseResult? ResponseParser.feed(&self, char[] data) {
    // Check size limits
    if (self.bytes_parsed + data.len > self.max_response_size) {
        self.state = ParserState.ERROR;
        return PARSE_ERROR?;
    }

    // Append data to buffer
    self.buffer.write(data)!;
    self.bytes_parsed += data.len;

    // Run state machine
    return self.process()!;
}

/**
 * Get readable buffer data as char array.
 */
fn char[] ResponseParser.get_readable_buffer(&self) {
    usz readable = self.buffer.write_idx - self.buffer.read_idx;
    return self.buffer.bytes[self.buffer.read_idx : readable];
}

/**
 * Consume N bytes from buffer.
 */
fn void ResponseParser.consume_bytes(&self, usz n) {
    self.buffer.read_idx += n;
}

/**
 * Process buffered data through state machine.
 * Returns MORE if needs more data, COMPLETE if done, ERROR on failure.
 */
fn ParseResult? ResponseParser.process(&self) {
    while (true) {
        switch (self.state) {
            case ParserState.START:
                self.state = ParserState.STATUS_LINE;

            case ParserState.STATUS_LINE:
                ParseResult? result = self.parse_status_line();
                if (catch err = result) {
                    self.state = ParserState.ERROR;
                    return err?;
                }
                if (result == ParseResult.MORE) {
                    return ParseResult.MORE;
                }
                self.state = ParserState.HEADERS;

            case ParserState.HEADERS:
                ParseResult? result = self.parse_headers();
                if (catch err = result) {
                    self.state = ParserState.ERROR;
                    return err?;
                }
                if (result == ParseResult.MORE) {
                    return ParseResult.MORE;
                }
                self.state = ParserState.BODY;

            case ParserState.BODY:
                ParseResult? result = self.parse_body();
                if (catch err = result) {
                    self.state = ParserState.ERROR;
                    return err?;
                }
                if (result == ParseResult.MORE) {
                    return ParseResult.MORE;
                }
                self.state = ParserState.COMPLETE;

            case ParserState.COMPLETE:
                return ParseResult.COMPLETE;

            case ParserState.ERROR:
                return PARSE_ERROR?;
        }
    }
}

/**
 * Parse status line: HTTP/VERSION STATUS REASON\r\n
 * Returns MORE if incomplete, COMPLETE if done.
 */
fn ParseResult? ResponseParser.parse_status_line(&self) {
    // Look for CRLF to find end of status line
    String buffer_str = (String)self.get_readable_buffer();
    usz? crlf_pos = find_crlf(buffer_str);

    if (catch err = crlf_pos) {
        // Propagate protocol violations (bare LF, null bytes)
        if (err == PROTOCOL_VIOLATION) {
            return err?;
        }
        // No CRLF yet, check size limit
        if (buffer_str.len > self.max_header_size) {
            return HEADER_TOO_LARGE?;
        }
        return ParseResult.MORE;
    }

    // Extract status line
    String line = buffer_str[0:crlf_pos];

    // Parse: HTTP/VERSION SP STATUS SP REASON
    // Note: reason phrase is optional in HTTP/1.1
    usz? first_space = line.index_of_char(' ');
    if (catch err = first_space) {
        return INVALID_STATUS_LINE?;
    }

    // Parse version (e.g., "HTTP/1.1")
    String version_str = line[0:first_space];
    version::HttpVersion? parsed_version = version::parse(version_str);
    if (catch err = parsed_version) {
        return INVALID_STATUS_LINE?;
    }
    self.response.version = parsed_version;

    // Find second space (between status code and reason phrase)
    usz rest_start = first_space + 1;
    String rest = line[rest_start..];

    usz? second_space = rest.index_of_char(' ');
    String status_str;
    String reason_str = "";

    if (catch err = second_space) {
        // No second space, entire rest is status code (reason phrase optional)
        status_str = rest;
    } else {
        // Has reason phrase
        status_str = rest[0:second_space];
        reason_str = rest[second_space + 1..];
    }

    // Parse status code (must be exactly 3 digits)
    if (status_str.len != 3) {
        return INVALID_STATUS_LINE?;
    }

    // Parse status code as integer
    int? parsed_status = status_str.to_int();
    if (catch err = parsed_status) {
        return INVALID_STATUS_LINE?;
    }

    // Validate status code range (100-599)
    if (parsed_status < 100 || parsed_status >= 600) {
        return INVALID_STATUS_LINE?;
    }

    self.response.status = (status::HttpStatus)parsed_status;
    self.response.reason_phrase = reason_str;

    // Consume status line + CRLF from buffer
    self.consume_bytes(crlf_pos + 2);

    return ParseResult.COMPLETE;
}

/**
 * Parse headers until empty line (\r\n\r\n).
 * Returns MORE if incomplete, COMPLETE if done.
 */
fn ParseResult? ResponseParser.parse_headers(&self) {
    while (true) {
        String buffer_str = (String)self.get_readable_buffer();

        // Check size limit
        if (buffer_str.len > self.max_header_size) {
            return HEADER_TOO_LARGE?;
        }

        // Look for CRLF
        usz? crlf_pos = find_crlf(buffer_str);
        if (catch err = crlf_pos) {
            // Propagate protocol violations (bare LF, null bytes)
            if (err == PROTOCOL_VIOLATION) {
                return err?;
            }
            // No CRLF yet
            return ParseResult.MORE;
        }

        // Empty line means end of headers
        if (crlf_pos == 0) {
            self.consume_bytes(2); // Consume empty line (\r\n)

            // Check if body uses chunked encoding
            String? te = self.response.headers.get("Transfer-Encoding");
            if (try value = te) {
                if (value.contains("chunked")) {
                    self.is_chunked = true;
                }
            }

            return ParseResult.COMPLETE;
        }

        // Parse header line
        String line = buffer_str[0:crlf_pos];

        // Find colon separator
        usz? colon_pos = line.index_of_char(':');
        if (catch err = colon_pos) {
            return PARSE_ERROR?;
        }

        // Extract name and value
        String name = line[0:colon_pos];
        String value = line[colon_pos + 1..];

        // Trim leading/trailing whitespace from value (RFC 9110 �5.5)
        value = value.trim();

        // Add header to map
        self.response.headers.add(name, value)!;

        // Consume header line + CRLF
        self.consume_bytes(crlf_pos + 2);
    }
}

/**
 * Parse response body based on Content-Length or Transfer-Encoding.
 * Returns MORE if incomplete, COMPLETE if done.
 */
fn ParseResult? ResponseParser.parse_body(&self) {
    // Handle chunked encoding
    if (self.is_chunked) {
        char[] buffer_data = self.get_readable_buffer();
        if (buffer_data.len > 0) {
            bool? complete = self.chunked_parser.feed(buffer_data);
            if (catch err = complete) {
                return PARSE_ERROR?;
            }

            // Consume all fed data from buffer
            self.consume_bytes(buffer_data.len);

            if (complete) {
                return ParseResult.COMPLETE;
            }
        }

        return ParseResult.MORE;
    }

    // Handle Content-Length body
    usz? content_length = self.response.headers.get_content_length();
    if (catch err = content_length) {
        // No Content-Length and not chunked
        // For responses, this might mean:
        // 1) No body (1xx, 204, 304 status codes)
        // 2) Connection close indicates end of body
        // For now, assume no body if no Content-Length
        return ParseResult.COMPLETE;
    }

    // Check if we have enough data
    char[] buffer_data = self.get_readable_buffer();
    if (buffer_data.len < content_length) {
        return ParseResult.MORE;
    }

    // Body is complete (don't consume it, leave for get_body())
    return ParseResult.COMPLETE;
}

/**
 * Get parsed response. Only valid after parse returns COMPLETE.
 */
fn client_response::ClientResponse* ResponseParser.get_response(&self) {
    return &self.response;
}

/**
 * Get response body data. Only valid after parse returns COMPLETE.
 */
fn char[] ResponseParser.get_body(&self) {
    // If chunked, return decoded body from chunked parser
    if (self.is_chunked) {
        return self.chunked_parser.get_body();
    }

    // Otherwise, return Content-Length bytes from buffer
    usz? content_length = self.response.headers.get_content_length();
    if (catch err = content_length) {
        return (char[]){};
    }

    char[] buffer_data = self.get_readable_buffer();
    usz body_len = content_length < buffer_data.len ? content_length : buffer_data.len;
    return buffer_data[0:body_len];
}

/**
 * Find CRLF (\r\n) in string.
 * Returns position of \r, or fault if not found.
 *
 * Rejects bare LF and null bytes per RFC 9112.
 */
fn usz? find_crlf(String str) {
    // Scan for CRLF and security violations simultaneously
    for (usz i = 0; i < str.len; i++) {
        char c = str[i];

        // SECURITY: Reject null bytes
        if (c == 0) {
            return PROTOCOL_VIOLATION?;
        }

        // SECURITY: Reject bare LF without CR
        if (c == '\n') {
            if (i == 0 || str[i - 1] != '\r') {
                return PROTOCOL_VIOLATION?;
            }
            // This is the '\n' of a proper CRLF, return position of '\r'
            return i - 1;
        }

        // Check if this is '\r' followed by '\n' (proper CRLF)
        if (c == '\r' && i + 1 < str.len && str[i + 1] == '\n') {
            return i;
        }
    }

    // Not found yet - need more data
    return PARSE_ERROR?;
}
