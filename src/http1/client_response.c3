/**
 * HTTP/1.1 Client Response
 *
 * Represents a parsed HTTP response from a server.
 */
module c3web::http1::client_response;

import c3web::common::status;
import c3web::common::version;
import c3web::common::headers;
import std::core::string;

/**
 * HTTP/1.1 client response (parsed from server)
 */
struct ClientResponse {
    version::HttpVersion version;
    status::HttpStatus status;
    String reason_phrase;           // "OK", "Not Found", etc.
    headers::HeaderMap headers;
    headers::HeaderMap trailers;    // Optional trailer headers (RFC 9112 §7.1.2)
}

/**
 * Initialize client response
 */
fn void ClientResponse.init(&self, Allocator allocator = mem) {
    self.version = version::HTTP_1_1;
    self.status = 200;
    self.reason_phrase = "";
    self.headers.init(allocator);
    self.trailers.init(allocator);
}

/**
 * Free client response resources
 */
fn void ClientResponse.free(&self) {
    self.headers.free();
    self.trailers.free();
}

/**
 * Reset response for reuse
 */
fn void ClientResponse.reset(&self) {
    self.version = version::HTTP_1_1;
    self.status = 200;
    self.reason_phrase = "";
    self.headers.clear();
    self.trailers.clear();
}

/**
 * Check if status is informational (1xx)
 */
fn bool ClientResponse.is_informational(&self) {
    return status::is_informational(self.status);
}

/**
 * Check if status is successful (2xx)
 */
fn bool ClientResponse.is_success(&self) {
    return status::is_success(self.status);
}

/**
 * Check if status is redirection (3xx)
 */
fn bool ClientResponse.is_redirection(&self) {
    return status::is_redirection(self.status);
}

/**
 * Check if status is client error (4xx)
 */
fn bool ClientResponse.is_client_error(&self) {
    return status::is_client_error(self.status);
}

/**
 * Check if status is server error (5xx)
 */
fn bool ClientResponse.is_server_error(&self) {
    return status::is_server_error(self.status);
}

/**
 * Check if status is any error (4xx or 5xx)
 */
fn bool ClientResponse.is_error(&self) {
    return status::is_error(self.status);
}
