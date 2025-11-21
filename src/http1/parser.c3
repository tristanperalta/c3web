<*
 * HTTP/1.1 Request Parser
 *
 * Incremental state machine parser for HTTP/1.1 requests per RFC 9112.
 * Handles streaming data that arrives in chunks.
 *>
module c3web::http1::parser;

import c3web::common::method;
import c3web::common::version;
import c3web::common::headers;
import c3web::http1::chunked;
import std::io;
import std::net::url;
import std::core::string;

<* Parser states for incremental parsing *>
enum ParserState : char {
    START,
    REQUEST_LINE,
    HEADERS,
    BODY,
    COMPLETE,
    ERROR,
}

<* Result of parse operation *>
enum ParseResult : char {
    MORE,      // Need more data
    COMPLETE,  // Parsing complete
    ERROR,     // Parse error
}

faultdef PARSE_ERROR, INVALID_REQUEST_LINE, HEADER_TOO_LARGE, REQUEST_TOO_LARGE;
faultdef PROTOCOL_VIOLATION;  // bare LF, null bytes, etc.

<* HTTP/1.1 request representation *>
struct Request {
    method::HttpMethod method;
    String target;              // Raw request target from request line
    url::Url url;               // Parsed URL (for absolute URIs)
    String path;                // Decoded path (for origin-form requests)
    url::UrlQueryValues query;  // Parsed query parameters
    version::HttpVersion version;
    headers::HeaderMap headers;
    headers::HeaderMap trailers; // Optional trailer headers (RFC 9112 §7.1.2)
}

<* Incremental HTTP/1.1 parser *>
struct Parser {
    ParserState state;
    io::ByteBuffer buffer;
    Request request;
    usz bytes_parsed;
    usz max_header_size;
    usz max_request_size;
    bool is_chunked;                    // True if Transfer-Encoding: chunked
    chunked::ChunkedParser chunked_parser;  // For chunked encoding
}

// Parser configuration defaults
const usz DEFAULT_MAX_HEADER_SIZE = 8 * 1024;        // 8KB
const usz DEFAULT_MAX_REQUEST_SIZE = 1024 * 1024;    // 1MB
const usz DEFAULT_MAX_URI_LENGTH = 8 * 1024;         // 8KB
const usz INITIAL_BUFFER_SIZE = 4 * 1024;            // 4KB

<* Initialize parser with default limits. *>
fn void Parser.init(&self, Allocator allocator = mem) {
    self.state = ParserState.START;
    self.buffer.init(allocator, DEFAULT_MAX_REQUEST_SIZE, INITIAL_BUFFER_SIZE);
    self.request.headers.init(allocator);
    self.request.trailers.init(allocator);
    self.bytes_parsed = 0;
    self.max_header_size = DEFAULT_MAX_HEADER_SIZE;
    self.max_request_size = DEFAULT_MAX_REQUEST_SIZE;
    self.is_chunked = false;
    self.chunked_parser.init(&self.request.trailers, allocator);
}

<* Free parser resources. *>
fn void Parser.free(&self) {
    self.buffer.free();
    self.request.headers.free();
    self.request.trailers.free();
    self.chunked_parser.free();
}

<* Reset parser to initial state for connection reuse. *>
fn void Parser.reset(&self) {
    self.state = ParserState.START;
    self.buffer.read_idx = 0;
    self.buffer.write_idx = 0;
    self.request.headers.clear();
    self.request.trailers.clear();
    self.bytes_parsed = 0;
    self.is_chunked = false;
    self.chunked_parser.reset();
}

<*
 * Feed data to parser. Returns parse result.
 * Call repeatedly as data arrives from network.
 *>
fn ParseResult? Parser.feed(&self, char[] data) {
    // Check size limits
    if (self.bytes_parsed + data.len > self.max_request_size) {
        self.state = ParserState.ERROR;
        return PARSE_ERROR?;
    }

    // Append data to buffer
    self.buffer.write(data)!;
    self.bytes_parsed += data.len;

    // Run state machine
    return self.process()!;
}

<* Get readable buffer data as char array. *>
fn char[] Parser.get_readable_buffer(&self) {
    usz readable = self.buffer.write_idx - self.buffer.read_idx;
    return self.buffer.bytes[self.buffer.read_idx : readable];
}

<* Consume N bytes from buffer. *>
fn void Parser.consume_bytes(&self, usz n) {
    self.buffer.read_idx += n;
}

<*
 * Process buffered data through state machine.
 * Returns MORE if needs more data, COMPLETE if done, ERROR on failure.
 *>
fn ParseResult? Parser.process(&self) {
    while (true) {
        switch (self.state) {
            case ParserState.START:
                self.state = ParserState.REQUEST_LINE;

            case ParserState.REQUEST_LINE:
                ParseResult? result = self.parse_request_line();
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

<*
 * Parse request line: METHOD TARGET HTTP/VERSION\r\n
 * Returns MORE if incomplete, COMPLETE if done.
 *>
fn ParseResult? Parser.parse_request_line(&self) {
    // Look for CRLF to find end of request line
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

    // Extract request line
    String line = buffer_str[0:crlf_pos];

    // Parse: METHOD SP TARGET SP HTTP/VERSION
    String[]? parts = line.tsplit(" ");
    if (catch err = parts) {
        return INVALID_REQUEST_LINE?;
    }

    if (parts.len != 3) {
        return INVALID_REQUEST_LINE?;
    }

    // Parse method
    method::HttpMethod? parsed_method = method::parse(parts[0]);
    if (catch err = parsed_method) {
        return INVALID_REQUEST_LINE?;
    }
    self.request.method = parsed_method;

    // Store raw target
    self.request.target = parts[1];

    // Validate URI length (414 URI Too Long)
    if (parts[1].len > DEFAULT_MAX_URI_LENGTH) {
        return REQUEST_TOO_LARGE?;
    }

    // Parse target as URL
    // For origin-form (e.g., "/path?query"), prepend scheme+host to make it parseable
    String target_to_parse = parts[1];
    if (target_to_parse.starts_with("/")) {
        // Origin-form: prepend dummy scheme://host for parsing
        target_to_parse = string::tformat("http://localhost%s", target_to_parse);
    }

    // Parse URL (use temp allocator for parsing, will copy what we need)
    url::Url? parsed_url = url::tparse(target_to_parse);
    if (catch err = parsed_url) {
        return INVALID_REQUEST_LINE?;
    }

    // Extract path and query
    self.request.path = parsed_url.path.copy(tmem);
    if (parsed_url.query.len > 0) {
        self.request.query = url::parse_query_to_temp(parsed_url.query);
    }

    // For absolute-form, store the full URL
    if (!parts[1].starts_with("/")) {
        self.request.url = parsed_url;
    }

    // Parse version
    version::HttpVersion? parsed_version = version::parse(parts[2]);
    if (catch err = parsed_version) {
        return INVALID_REQUEST_LINE?;
    }

    // Validate version is supported (HTTP/1.1 only, optionally HTTP/1.0)
    // Return 505 HTTP Version Not Supported for other versions
    if (!parsed_version.is_http11() && !parsed_version.is_http10()) {
        return version::UNSUPPORTED_VERSION?;
    }

    self.request.version = parsed_version;

    // Consume request line + CRLF from buffer
    self.consume_bytes(crlf_pos + 2);

    return ParseResult.COMPLETE;
}

<*
 * Parse headers until empty line (\r\n\r\n).
 * Returns MORE if incomplete, COMPLETE if done.
 *>
fn ParseResult? Parser.parse_headers(&self) {
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

        // Check for empty line (end of headers)
        if (crlf_pos == 0) {
            // Consume final CRLF
            self.consume_bytes(2);
            return ParseResult.COMPLETE;
        }

        // Parse header line
        String line = buffer_str[0:crlf_pos];
        headers::HeaderField? field = headers::parse_header_line(line);
        if (catch err = field) {
            return PARSE_ERROR?;
        }

        // Add to header map
        self.request.headers.add(field.name, field.value)!;

        // Consume header line + CRLF
        self.consume_bytes(crlf_pos + 2);
    }
}

<*
 * Parse request body based on Content-Length or Transfer-Encoding.
 * Returns MORE if incomplete, COMPLETE if done.
 *>
fn ParseResult? Parser.parse_body(&self) {
    // Check Transfer-Encoding first (takes precedence over Content-Length)
    if (self.request.headers.is_chunked()) {
        // Mark as chunked on first call to parse_body
        if (!self.is_chunked) {
            self.is_chunked = true;
        }

        // Feed buffer data to chunked parser
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

    // Check Content-Length
    usz? content_length = self.request.headers.get_content_length();
    if (catch err = content_length) {
        // No body
        return ParseResult.COMPLETE;
    }

    // Reject body that exceeds size limit (413 Payload Too Large)
    if (content_length > self.max_request_size) {
        return REQUEST_TOO_LARGE?;
    }

    // Check if we have enough data
    char[] buffer_data = self.get_readable_buffer();
    if (buffer_data.len < content_length) {
        return ParseResult.MORE;
    }

    // Body is ready (we don't consume it, just mark complete)
    // The body data remains in buffer for application to read
    return ParseResult.COMPLETE;
}

<*
 * Get parsed request. Only valid after parse returns COMPLETE.
 *>
fn Request* Parser.get_request(&self) {
    return &self.request;
}

<* Get request body data. Only valid after parse returns COMPLETE. *>
fn char[] Parser.get_body(&self) {
    // If chunked, return decoded body from chunked parser
    if (self.is_chunked) {
        return self.chunked_parser.get_body();
    }

    // Otherwise, return Content-Length bytes from buffer
    usz? content_length = self.request.headers.get_content_length();
    if (catch err = content_length) {
        return (char[]){};
    }

    char[] buffer_data = self.get_readable_buffer();
    usz body_len = content_length < buffer_data.len ? content_length : buffer_data.len;
    return buffer_data[0:body_len];
}

<*
 * Find CRLF (\r\n) in string.
 * Returns position of \r, or fault if not found.
 *
 * Rejects bare LF and null bytes per RFC 9112.
 *>
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
            // Found proper CRLF, but continue checking rest of line for null bytes
            // Actually, just return here - we'll check the line on the next call
            return i;
        }
    }

    // Not found yet - need more data
    return PARSE_ERROR?;
}
