<*
 * HTTP Version
 *
 * HTTP protocol version parsing and validation per RFC 9110§2.5.
 *>
module c3web::common::version;

import std::core::string;

<* HTTP protocol version. *>
struct HttpVersion {
    char major;
    char minor;
}

faultdef INVALID_VERSION, UNSUPPORTED_VERSION;

// Common HTTP versions
const HttpVersion HTTP_1_0 = { 1, 0 };
const HttpVersion HTTP_1_1 = { 1, 1 };
const HttpVersion HTTP_2_0 = { 2, 0 };
const HttpVersion HTTP_3_0 = { 3, 0 };

<* Parse HTTP version from string (e.g., "HTTP/1.1"). *>
fn HttpVersion? parse(String version_str) {
    if (version_str.len < 8) {
        return INVALID_VERSION?;
    }

    // Check "HTTP/" prefix
    if (version_str[0] != 'H' || version_str[1] != 'T' ||
        version_str[2] != 'T' || version_str[3] != 'P' ||
        version_str[4] != '/') {
        return INVALID_VERSION?;
    }

    // Parse major version (single digit)
    if (!version_str[5].is_digit()) {
        return INVALID_VERSION?;
    }
    char major = version_str[5] - '0';

    // Check dot separator
    if (version_str[6] != '.') {
        return INVALID_VERSION?;
    }

    // Parse minor version (single digit)
    if (!version_str[7].is_digit()) {
        return INVALID_VERSION?;
    }
    char minor = version_str[7] - '0';

    return (HttpVersion){ major, minor };
}

<* Convert version to string (e.g., "HTTP/1.1"). *>
fn String HttpVersion.to_string(&self, Allocator allocator = mem) {
    return string::format(allocator, "HTTP/%d.%d", self.major, self.minor);
}

<* Check if version equals another version. *>
fn bool HttpVersion.equals(HttpVersion* version, HttpVersion* other) {
    return version.major == other.major && version.minor == other.minor;
}

<* Check if this is HTTP/1.1. *>
fn bool HttpVersion.is_http11(HttpVersion* version) {
    return version.major == 1 && version.minor == 1;
}

<* Check if this is HTTP/1.0. *>
fn bool HttpVersion.is_http10(HttpVersion* version) {
    return version.major == 1 && version.minor == 0;
}

<* Check if this is HTTP/2. *>
fn bool HttpVersion.is_http2(HttpVersion* version) {
    return version.major == 2 && version.minor == 0;
}
