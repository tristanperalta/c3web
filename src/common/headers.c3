<*
 * HTTP Header Management
 *
 * Case-insensitive header storage and common header constants per RFC 9110§5.
 *>
module c3web::common::headers;

import std::collections::map;

<*
 * Case-insensitive header map.
 *
 * HTTP header field names are case-insensitive (RFC 9110§5.1).
 *>
struct HeaderMap {
    HashMap{String, String} headers;
    DynamicArenaAllocator arena;  // Owns all normalized header name strings
}

// Header-related faults
faultdef INVALID_HEADER_NAME, INVALID_HEADER_VALUE, HEADER_NOT_FOUND;
faultdef INVALID_CONTENT_LENGTH, MULTIPLE_CONTENT_LENGTH_MISMATCH;
faultdef TRANSFER_ENCODING_WITH_CONTENT_LENGTH;

// Common HTTP headers (RFC 9110)
const String HEADER_ACCEPT = "accept";
const String HEADER_ACCEPT_ENCODING = "accept-encoding";
const String HEADER_ACCEPT_LANGUAGE = "accept-language";
const String HEADER_AUTHORIZATION = "authorization";
const String HEADER_CACHE_CONTROL = "cache-control";
const String HEADER_CONNECTION = "connection";
const String HEADER_CONTENT_ENCODING = "content-encoding";
const String HEADER_CONTENT_LENGTH = "content-length";
const String HEADER_CONTENT_TYPE = "content-type";
const String HEADER_COOKIE = "cookie";
const String HEADER_DATE = "date";
const String HEADER_ETAG = "etag";
const String HEADER_EXPECT = "expect";
const String HEADER_HOST = "host";
const String HEADER_IF_MODIFIED_SINCE = "if-modified-since";
const String HEADER_IF_NONE_MATCH = "if-none-match";
const String HEADER_LAST_MODIFIED = "last-modified";
const String HEADER_LOCATION = "location";
const String HEADER_RANGE = "range";
const String HEADER_REFERER = "referer";
const String HEADER_SERVER = "server";
const String HEADER_SET_COOKIE = "set-cookie";
const String HEADER_TRANSFER_ENCODING = "transfer-encoding";
const String HEADER_UPGRADE = "upgrade";
const String HEADER_USER_AGENT = "user-agent";
const String HEADER_WWW_AUTHENTICATE = "www-authenticate";

// WebSocket headers (RFC 6455)
const String HEADER_SEC_WEBSOCKET_KEY = "sec-websocket-key";
const String HEADER_SEC_WEBSOCKET_ACCEPT = "sec-websocket-accept";
const String HEADER_SEC_WEBSOCKET_VERSION = "sec-websocket-version";
const String HEADER_SEC_WEBSOCKET_PROTOCOL = "sec-websocket-protocol";
const String HEADER_SEC_WEBSOCKET_EXTENSIONS = "sec-websocket-extensions";

<* Header field name and value pair *>
struct HeaderField {
    String name;
    String value;
}

<* Initialize header map. *>
fn void HeaderMap.init(&self, Allocator allocator = mem) {
    self.headers.init(allocator, 32);
    // Initialize arena with 1KB pages (good for ~50 headers)
    self.arena.init(allocator, 1024);
}

<* Free header map resources. *>
fn void HeaderMap.free(&self) {
    self.headers.free();
    // Free ALL normalized header name strings at once - O(1) operation!
    self.arena.free();
}

<*
 * Convert header name to lowercase for case-insensitive comparison.
 * Uses arena allocator for efficient batch deallocation.
 *>
fn String normalize_header_name(String name, DynamicArenaAllocator* arena) {
    return name.to_lower_copy(arena);
}

<*
 * Validate header field name (RFC 9110§5.1).
 * Field name must be a token: tchar+
 * tchar = ALPHA / DIGIT / "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~"
 *>
fn bool is_valid_header_name(String name) {
    if (name.len == 0) return false;

    foreach (char c : name) {
        if (c.is_alnum() || c == '!' || c == '#' || c == '$' ||
            c == '%' || c == '&' || c == '\'' || c == '*' ||
            c == '+' || c == '-' || c == '.' || c == '^' ||
            c == '_' || c == '`' || c == '|' || c == '~') {
            continue;
        }
        return false;
    }

    return true;
}

<*
 * Validate header field value (RFC 9110§5.5).
 * Must not contain CR or LF (prevents header injection).
 *>
fn bool is_valid_header_value(String value) {
    foreach (char c : value) {
        if (c == '\r' || c == '\n') {
            return false;
        }
    }
    return true;
}

<*
 * Add header to map. Validates name and value.
 * Normalizes name to lowercase for case-insensitive lookup.
 *
 * Special handling for Content-Length to prevent request smuggling:
 * - Multiple Content-Length headers must have identical values (RFC 9112 §6.3)
 * - Transfer-Encoding + Content-Length is rejected (RFC 9112 §6.3 ¶3)
 *>
fn void? HeaderMap.add(&self, String name, String value) {
    if (!is_valid_header_name(name)) {
        return INVALID_HEADER_NAME?;
    }

    if (!is_valid_header_value(value)) {
        return INVALID_HEADER_VALUE?;
    }

    String normalized = normalize_header_name(name, &self.arena);

    // Validate Content-Length value before storing
    if (normalized == HEADER_CONTENT_LENGTH) {
        // Validate the Content-Length value is non-negative integer
        String trimmed = value.trim();

        // Empty string is invalid
        if (trimmed.len == 0) {
            return INVALID_CONTENT_LENGTH?;
        }

        // Check for negative sign (invalid per RFC 9112 §6.3)
        if (trimmed[0] == '-') {
            return INVALID_CONTENT_LENGTH?;
        }

        // Validate all characters are digits
        foreach (char c : trimmed) {
            if (!c.is_digit()) {
                return INVALID_CONTENT_LENGTH?;
            }
        }

        // Check for duplicate Content-Length with different value
        if (self.has(HEADER_CONTENT_LENGTH)) {
            // Already have Content-Length - verify values match
            String? existing = self.get(HEADER_CONTENT_LENGTH);
            if (catch err = existing) {
                // Shouldn't happen since we just checked has()
                return err?;
            }
            String existing_trimmed = existing.trim();
            if (existing_trimmed != trimmed) {
                // Different Content-Length values = request smuggling attack
                return MULTIPLE_CONTENT_LENGTH_MISMATCH?;
            }
            // Same value - OK per RFC, but don't need to store again
            return;
        }
    }

    // Validate Transfer-Encoding header strictly (prevent obfuscation attacks)
    if (normalized == HEADER_TRANSFER_ENCODING) {
        // Reject if already exists (multiple TE headers = obfuscation attack)
        if (self.has(HEADER_TRANSFER_ENCODING)) {
            return INVALID_HEADER_VALUE?;
        }

        // Only accept "chunked" (no multiple codings, no whitespace tricks)
        String trimmed = value.trim();
        String lower = trimmed.to_lower_tcopy();

        // Reject anything that's not exactly "chunked"
        if (lower != "chunked") {
            return INVALID_HEADER_VALUE?;
        }

        // Reject if Content-Length also present
        if (self.has(HEADER_CONTENT_LENGTH)) {
            return TRANSFER_ENCODING_WITH_CONTENT_LENGTH?;
        }
    }
    if (normalized == HEADER_CONTENT_LENGTH) {
        if (self.has(HEADER_TRANSFER_ENCODING)) {
            return TRANSFER_ENCODING_WITH_CONTENT_LENGTH?;
        }
    }

    self.headers.set(normalized, value);
}

<* Get header value by name (case-insensitive). *>
fn String? HeaderMap.get(&self, String name) {
    String normalized = normalize_header_name(name, &self.arena);
    String*? value_ref = self.headers.get_ref(normalized);
    if (catch err = value_ref) {
        return HEADER_NOT_FOUND?;
    }
    return *value_ref;
}

<* Check if header exists (case-insensitive). *>
fn bool HeaderMap.has(&self, String name) {
    String normalized = normalize_header_name(name, &self.arena);
    return self.headers.has_key(normalized);
}

<* Remove header by name (case-insensitive). *>
fn void HeaderMap.remove(&self, String name) {
    String normalized = normalize_header_name(name, &self.arena);
    self.headers.remove(normalized);
}

<* Get number of headers. *>
fn usz HeaderMap.count(&self) {
    return self.headers.count;
}

<* Clear all headers. *>
fn void HeaderMap.clear(&self) {
    self.headers.clear();
}

<*
 * Get Content-Length header value as integer with strict validation.
 * Validates:
 * - Must be non-negative integer
 * - No invalid characters (letters, decimals, hex, etc.)
 * - Multiple Content-Length headers must have identical values
 *>
fn usz? HeaderMap.get_content_length(&self) {
    String? value = self.get(HEADER_CONTENT_LENGTH);
    if (catch err = value) {
        return err?;
    }

    // Trim whitespace (RFC allows OWS around field value)
    String trimmed = value.trim();

    // Empty string is invalid
    if (trimmed.len == 0) {
        return INVALID_CONTENT_LENGTH?;
    }

    // Check for negative sign (invalid per RFC 9112 §6.3)
    if (trimmed[0] == '-') {
        return INVALID_CONTENT_LENGTH?;
    }

    // Validate all characters are digits
    foreach (char c : trimmed) {
        if (!c.is_digit()) {
            return INVALID_CONTENT_LENGTH?;
        }
    }

    // Parse as unsigned long (any parse error = invalid Content-Length)
    if (catch err = trimmed.to_ulong()) {
        return INVALID_CONTENT_LENGTH?;
    }
    ulong result = trimmed.to_ulong()!;

    return (usz)result;
}

<* Check if Transfer-Encoding is chunked. *>
fn bool HeaderMap.is_chunked(&self) {
    String? value = self.get(HEADER_TRANSFER_ENCODING);
    if (catch err = value) {
        return false;
    }
    String lower = value.to_lower_tcopy();
    return lower == "chunked";
}

<* Check if Connection header indicates keep-alive. *>
fn bool HeaderMap.is_keep_alive(&self) {
    String? value = self.get(HEADER_CONNECTION);
    if (catch err = value) {
        return false; // Default depends on HTTP version
    }
    String lower = value.to_lower_tcopy();
    return lower == "keep-alive";
}

<* Check if Connection header indicates close. *>
fn bool HeaderMap.is_connection_close(&self) {
    String? value = self.get(HEADER_CONNECTION);
    if (catch err = value) {
        return false;
    }
    String lower = value.to_lower_tcopy();
    return lower == "close";
}

<*
 * Parse header line "name: value" into name and value.
 * Trims whitespace from value.
 *
 * Rejects whitespace before colon per RFC 9112.
 *>
fn HeaderField? parse_header_line(String line) {
    // Find colon separator
    usz? colon_pos = line.index_of_char(':');
    if (catch err = colon_pos) {
        return INVALID_HEADER_VALUE?;
    }

    String name_raw = line[0:colon_pos];
    String value = line[colon_pos + 1..].trim();

    // Reject whitespace before colon (RFC violation, enables obfuscation)
    // Header name must not have trailing whitespace
    if (name_raw.len > 0) {
        char last_char = name_raw[name_raw.len - 1];
        if (last_char == ' ' || last_char == '\t') {
            return INVALID_HEADER_NAME?;
        }
    }

    String name = name_raw.trim();

    if (!is_valid_header_name(name)) {
        return INVALID_HEADER_NAME?;
    }

    if (!is_valid_header_value(value)) {
        return INVALID_HEADER_VALUE?;
    }

    return (HeaderField){ name, value };
}
