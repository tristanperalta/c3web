<*
 * HTTP/1.1 Response Builder
 *
 * Builds and serializes HTTP/1.1 responses per RFC 9112.
 *>
module c3web::http1::response;

import c3web::common::status;
import c3web::common::version;
import c3web::common::headers;
import std::io;
import std::collections::list;

<* HTTP/1.1 response representation *>
struct Response {
    version::HttpVersion version;
    status::HttpStatus status;
    headers::HeaderMap headers;
    io::ByteBuffer body;
    bool headers_sent;
}

faultdef RESPONSE_ERROR, HEADERS_ALREADY_SENT;

<* Initialize response with default HTTP/1.1 and 200 OK. *>
fn void Response.init(&self, Allocator allocator = mem) {
    self.version = version::HTTP_1_1;
    self.status = status::STATUS_OK;
    self.headers.init(allocator);
    self.body.init(allocator, 64 * 1024, 4096); // 64KB max, 4KB initial
    self.headers_sent = false;
}

<* Free response resources. *>
fn void Response.free(&self) {
    self.headers.free();
    self.body.free();
}

<* Reset response for reuse (clears headers and body). *>
fn void Response.reset(&self) {
    self.headers.clear();
    self.body.read_idx = 0;
    self.body.write_idx = 0;
    self.headers_sent = false;
    self.status = status::STATUS_OK;
    self.version = version::HTTP_1_1;
}

<* Set response status code. *>
fn void Response.set_status(&self, status::HttpStatus status_code) {
    self.status = status_code;
}

<* Set response HTTP version. *>
fn void Response.set_version(&self, version::HttpVersion ver) {
    self.version = ver;
}

<* Add header to response. *>
fn void? Response.add_header(&self, String name, String value) {
    if (self.headers_sent) {
        return HEADERS_ALREADY_SENT?;
    }
    return self.headers.add(name, value);
}

<* Set Content-Type header. *>
fn void? Response.set_content_type(&self, String content_type) {
    return self.add_header(headers::HEADER_CONTENT_TYPE, content_type);
}

<* Write data to response body. *>
fn void? Response.write_body(&self, char[] data) {
    self.body.write(data)!;
}

<* Write string to response body. *>
fn void? Response.write_string(&self, String str) {
    return self.write_body((char[])str);
}

<*
 * Serialize response to ByteBuffer.
 * Generates complete HTTP response including status line, headers, and body.
 *>
fn void? Response.serialize(&self, io::ByteBuffer* output) {
    // Write status line: HTTP/VERSION STATUS REASON\r\n
    self.write_status_line(output)!;

    // Ensure Content-Length is set if body exists
    self.ensure_content_length()!;

    // Write headers
    self.write_headers(output)!;

    // Write empty line to end headers
    output.write("\r\n")!;

    // Write body if present
    if (self.body.write_idx > 0) {
        char[] body_data = self.body.bytes[0 : self.body.write_idx];
        output.write(body_data)!;
    }

    self.headers_sent = true;
}

<*
 * Write status line to buffer.
 * Format: HTTP/1.1 200 OK\r\n
 *>
fn void? Response.write_status_line(&self, io::ByteBuffer* output) {
    // HTTP version
    String version_str = self.version.to_string(tmem);
    output.write((char[])version_str)!;
    output.write(" ")!;

    // Status code
    String status_str = string::format(tmem, "%d", self.status);
    output.write((char[])status_str)!;
    output.write(" ")!;

    // Reason phrase
    String reason = status::status_reason(self.status);
    output.write((char[])reason)!;
    output.write("\r\n")!;
}

<*
 * Write all headers to buffer.
 * Format: field-name: field-value\r\n
 *>
fn void? Response.write_headers(&self, io::ByteBuffer* output) {
    // Iterate through all headers using @each macro
    self.headers.headers.@each(; String key, String value)
    {
        // Write field-name
        output.write((char[])key)!;
        output.write(": ")!;

        // Write field-value
        output.write((char[])value)!;
        output.write("\r\n")!;
    };
}

<* Ensure Content-Length header is set based on body size. *>
fn void? Response.ensure_content_length(&self) {
    // Only set if not already present and body exists
    if (!self.headers.has(headers::HEADER_CONTENT_LENGTH) && self.body.write_idx > 0) {
        String length_str = string::format(tmem, "%d", self.body.write_idx);
        self.headers.add(headers::HEADER_CONTENT_LENGTH, length_str)!;
    }
}

<*
 * Create a simple text response.
 * Convenience method for quick responses.
 *>
fn Response create_text_response(String text, status::HttpStatus status_code = status::STATUS_OK, Allocator allocator = mem) {
    Response response;
    response.init(allocator);
    response.set_status(status_code);
    response.set_content_type("text/plain; charset=utf-8")!!;
    response.write_string(text)!!;
    return response;
}

<*
 * Create a JSON response.
 * Convenience method for JSON responses.
 *>
fn Response create_json_response(String json, status::HttpStatus status_code = status::STATUS_OK, Allocator allocator = mem) {
    Response response;
    response.init(allocator);
    response.set_status(status_code);
    response.set_content_type("application/json; charset=utf-8")!!;
    response.write_string(json)!!;
    return response;
}

<*
 * Create an error response.
 * Convenience method for error responses.
 *>
fn Response create_error_response(status::HttpStatus status_code, String message = "", Allocator allocator = mem) {
    Response response;
    response.init(allocator);
    response.set_status(status_code);
    response.set_content_type("text/plain; charset=utf-8")!!;

    if (message.len > 0) {
        response.write_string(message)!!;
    } else {
        String reason = status::status_reason(status_code);
        response.write_string(reason)!!;
    }

    return response;
}
