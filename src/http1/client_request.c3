/**
 * HTTP/1.1 Client Request Builder
 *
 * Provides a builder API for constructing HTTP requests.
 */
module c3web::http1::client_request;

import c3web::common::method;
import c3web::common::version;
import c3web::common::headers;
import std::net::url;
import std::core::string;
import std::collections::list;
import std::io;

faultdef INVALID_URL, REQUEST_BUILD_ERROR;

/**
 * HTTP client request builder
 */
struct ClientRequest {
    method::HttpMethod method;
    url::Url url;
    version::HttpVersion http_version;
    List{HeaderEntry} headers_list;  // List preserves order and allows duplicates
    char[] body;
    bool has_body;
    bool keep_alive;
    Allocator allocator;
}

/**
 * Header entry that preserves order and allows duplicates
 */
struct HeaderEntry {
    String name;
    String value;
}

const String DEFAULT_USER_AGENT = "c3web/0.1.0";

<* Initialize client request *>
fn void ClientRequest.init(&self, Allocator allocator = mem) {
    self.method = method::HttpMethod.GET;
    self.http_version = version::HTTP_1_1;
    self.headers_list.init(allocator);
    self.has_body = false;
    self.keep_alive = true;  // HTTP/1.1 defaults to keep-alive
    self.allocator = allocator;
}

<* Free client request resources *>
fn void ClientRequest.free(&self) {
    // Free copied header strings
    foreach (entry : self.headers_list) {
        entry.name.free(self.allocator);
        entry.value.free(self.allocator);
    }
    self.headers_list.free();
}

<* Reset request for reuse *>
fn void ClientRequest.reset(&self) {
    // Free header strings before clearing
    foreach (entry : self.headers_list) {
        entry.name.free(self.allocator);
        entry.value.free(self.allocator);
    }

    self.method = method::HttpMethod.GET;
    self.http_version = version::HTTP_1_1;
    self.headers_list.clear();
    self.has_body = false;
    self.keep_alive = true;
}

<* Set HTTP method *>
fn void ClientRequest.set_method(&self, method::HttpMethod method) {
    self.method = method;
}

<* Set request URL *>
fn void? ClientRequest.set_url(&self, String url_str) {
    url::Url? parsed = url::tparse(url_str);
    if (catch err = parsed) {
        return INVALID_URL?;
    }
    self.url = parsed;
}

<* Set HTTP version to 1.1 *>
fn void ClientRequest.set_version_http11(&self) {
    self.http_version = version::HTTP_1_1;
}

<* Set HTTP version to 1.0 *>
fn void ClientRequest.set_version_http10(&self) {
    self.http_version = version::HTTP_1_0;
}

<* Set request body *>
fn void ClientRequest.set_body(&self, char[] body) {
    self.body = body;
    self.has_body = true;
}

<* Set Connection behavior (keep-alive or close) *>
fn void ClientRequest.set_keep_alive(&self, bool keep_alive) {
    self.keep_alive = keep_alive;
}

<* Add header (allows duplicates) *>
fn void ClientRequest.add_header(&self, String name, String value) {
    HeaderEntry entry = {
        .name = name.copy(self.allocator),
        .value = value.copy(self.allocator)
    };
    self.headers_list.push(entry);
}

<* Set header (replaces existing with same name) *>
fn void ClientRequest.set_header(&self, String name, String value) {
    // Remove existing headers with this name
    self.remove_header(name);
    // Add new one
    self.add_header(name, value);
}

<* Remove header by name *>
fn void ClientRequest.remove_header(&self, String name) {
    String name_lower = name.to_lower_tcopy();

    // Remove all headers matching this name (case-insensitive)
    for (usz i = 0; i < self.headers_list.len();) {
        HeaderEntry* entry = self.headers_list.get_ref(i);
        String entry_name_lower = entry.name.to_lower_tcopy();

        if (entry_name_lower == name_lower) {
            // Free the strings before removing
            entry.name.free(self.allocator);
            entry.value.free(self.allocator);
            self.headers_list.remove_at(i);
            // Don't increment i, we just removed element
        } else {
            i++;
        }
    }
}

<* Check if header exists *>
fn bool ClientRequest.has_header(&self, String name) {
    String name_lower = name.to_lower_tcopy();

    foreach (entry : self.headers_list) {
        String entry_name_lower = entry.name.to_lower_tcopy();
        if (entry_name_lower == name_lower) {
            return true;
        }
    }
    return false;
}

<* Serialize request to string *>
fn String ClientRequest.to_string(&self) {
    DString builder = dstring::temp();

    // Request line: METHOD TARGET HTTP/VERSION
    builder.append(self.method.to_string());
    builder.append_char(' ');

    // Target (path + query)
    String target = self.url.path.len > 0 ? self.url.path : "/";
    builder.append(target);

    if (self.url.query.len > 0) {
        builder.append_char('?');
        builder.append(self.url.query);
    }

    builder.append_char(' ');
    builder.append(self.http_version.to_string(tmem));
    builder.append("\r\n");

    // Host header (required for HTTP/1.1)
    if (!self.has_header("Host")) {
        builder.append("Host: ");
        builder.append(self.url.host);

        // Include port if non-standard
        if (self.url.port != 0 &&
            !((self.url.scheme == "http" && self.url.port == 80) ||
              (self.url.scheme == "https" && self.url.port == 443))) {
            builder.appendf(":%d", self.url.port);
        }
        builder.append("\r\n");
    }

    // User-Agent (add if not present)
    if (!self.has_header("User-Agent")) {
        builder.append("User-Agent: ");
        builder.append(DEFAULT_USER_AGENT);
        builder.append("\r\n");
    }

    // Connection header
    if (!self.keep_alive) {
        builder.append("Connection: close\r\n");
    } else if (self.http_version.is_http10()) {
        // HTTP/1.0 needs explicit keep-alive
        builder.append("Connection: keep-alive\r\n");
    }
    // HTTP/1.1 defaults to keep-alive, so we can omit Connection header

    // Content-Length for body
    if (self.has_body && !self.has_header("Content-Length")) {
        builder.appendf("Content-Length: %d\r\n", self.body.len);
    }

    // Custom headers
    foreach (entry : self.headers_list) {
        builder.append(entry.name);
        builder.append(": ");
        builder.append(entry.value);
        builder.append("\r\n");
    }

    // End of headers
    builder.append("\r\n");

    // Body (if present)
    if (self.has_body) {
        builder.append((String)self.body);
    }

    return builder.str_view();
}

<* Serialize request to ByteBuffer *>
fn void? ClientRequest.to_buffer(&self, io::ByteBuffer* buffer) {
    String serialized = self.to_string();
    buffer.write((char[])serialized)!;
}

// === Convenience Functions ===

<* Create GET request *>
fn ClientRequest? create_get(String url, Allocator allocator = mem) {
    ClientRequest req;
    req.init(allocator);

    req.set_method(method::HttpMethod.GET);
    req.set_url(url)!;
    req.set_version_http11();

    return req;
}

<* Create POST request with body *>
fn ClientRequest? create_post(String url, char[] body, Allocator allocator = mem) {
    ClientRequest req;
    req.init(allocator);

    req.set_method(method::HttpMethod.POST);
    req.set_url(url)!;
    req.set_version_http11();
    req.set_body(body);

    return req;
}

<* Create POST request with JSON body *>
fn ClientRequest? create_post_json(String url, char[] json_body, Allocator allocator = mem) {
    ClientRequest req;
    req.init(allocator);

    req.set_method(method::HttpMethod.POST);
    req.set_url(url)!;
    req.set_version_http11();
    req.add_header("Content-Type", "application/json");
    req.set_body(json_body);

    return req;
}

<* Create PUT request with body *>
fn ClientRequest? create_put(String url, char[] body, Allocator allocator = mem) {
    ClientRequest req;
    req.init(allocator);

    req.set_method(method::HttpMethod.PUT);
    req.set_url(url)!;
    req.set_version_http11();
    req.set_body(body);

    return req;
}

<* Create DELETE request *>
fn ClientRequest? create_delete(String url, Allocator allocator = mem) {
    ClientRequest req;
    req.init(allocator);

    req.set_method(method::HttpMethod.DELETE);
    req.set_url(url)!;
    req.set_version_http11();

    return req;
}
