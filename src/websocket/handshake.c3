/**
 * WebSocket Handshake Validation
 *
 * RFC 6455 §4 - Opening Handshake
 * Validates HTTP/1.1 upgrade requests and generates Sec-WebSocket-Accept response
 */
module c3web::websocket::handshake;

import c3web::http1::parser;
import c3web::common::method;
import std::encoding::base64;
import std::hash::sha1;
import std::io;

// RFC 6455 §1.3 - Magic GUID for Sec-WebSocket-Accept generation
const String WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/**
 * Generate Sec-WebSocket-Accept header value
 *
 * RFC 6455 §4.2.2, step 5.3-5.5:
 * 1. Concatenate Sec-WebSocket-Key with magic GUID
 * 2. SHA-1 hash the result
 * 3. Base64 encode the hash
 *
 * @param key - Value from Sec-WebSocket-Key header
 * @return Base64-encoded SHA-1 hash, or fault on error
 */
fn String? generate_websocket_accept(String key) @public
{
    // Step 1: Concatenate key + GUID (using temp allocator)
    String concatenated = string::tformat("%s%s", key, WEBSOCKET_GUID);

    // Step 2: SHA-1 hash (produces 20 bytes)
    char[20] sha1_hash = sha1::hash((char[])concatenated);

    // Step 3: Base64 encode the hash
    return base64::encode(mem, &sha1_hash);
}

/**
 * Validate Sec-WebSocket-Key format
 *
 * RFC 6455 §4.2.1, step 7: The header field value must be a base64-encoded
 * value that, when decoded, is 16 bytes in length.
 *
 * @param key - Value from Sec-WebSocket-Key header
 * @return true if valid, false otherwise
 */
fn bool validate_websocket_key(String key) @public
{
    // Try to decode base64
    if (try result = base64::decode(tmem, (char[])key))
    {
        // Valid base64 - check length
        return result.len == 16;
    }

    // Invalid base64
    return false;
}

/**
 * Validate WebSocket upgrade request
 *
 * RFC 6455 §4.2.1 - Server-side Requirements
 * Checks all required headers and conditions for a valid upgrade request.
 *
 * @param request - Parsed HTTP request
 * @return true if valid upgrade request, false otherwise
 */
fn bool validate_upgrade_request(parser::Request* request) @public
{
    // 1. Method MUST be GET (RFC 6455 §4.2.1, step 3)
    if (request.method != method::HttpMethod.GET)
    {
        return false;
    }

    // 2. HTTP version MUST be 1.1 or higher (RFC 6455 §4.2.1, step 2)
    if (!request.version.is_http11())
    {
        return false;
    }

    // 3. MUST have Host header (RFC 6455 §4.2.1, step 4)
    if (catch request.headers.get("host"))
    {
        return false;
    }

    // 4. MUST have "Upgrade: websocket" (case-insensitive, RFC 6455 §4.2.1, step 5)
    String? upgrade = request.headers.get("upgrade");
    if (catch upgrade)
    {
        return false;
    }
    if (upgrade.to_lower_tcopy() != "websocket")
    {
        return false;
    }

    // 5. MUST have "Connection: Upgrade" (case-insensitive, RFC 6455 §4.2.1, step 6)
    // Note: Can be comma-separated list, must contain "upgrade" token
    String? connection = request.headers.get("connection");
    if (catch connection)
    {
        return false;
    }
    // Simple check: contains "upgrade" (case-insensitive)
    if (!connection.to_lower_tcopy().contains("upgrade"))
    {
        return false;
    }

    // 6. MUST have Sec-WebSocket-Key (RFC 6455 §4.2.1, step 7)
    String? ws_key = request.headers.get("sec-websocket-key");
    if (catch ws_key)
    {
        return false;
    }

    // 7. Key must be valid base64 encoding 16 bytes
    if (!validate_websocket_key(ws_key))
    {
        return false;
    }

    // 8. MUST have "Sec-WebSocket-Version: 13" (RFC 6455 §4.2.1, step 8)
    String? ws_version = request.headers.get("sec-websocket-version");
    if (catch ws_version)
    {
        return false;
    }
    if (ws_version != "13")
    {
        return false;
    }

    // All validations passed
    return true;
}

/**
 * Create HTTP 101 Switching Protocols response
 *
 * RFC 6455 §4.2.2 - Server Response
 *
 * @param accept_key - Value from generate_websocket_accept()
 * @return HTTP 101 response as string
 */
fn String create_upgrade_response(String accept_key) @public
{
    return string::tformat(
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Accept: %s\r\n"
        "\r\n",
        accept_key
    );
}
