/**
 * HTTP/1.1 Client Connection
 *
 * Manages a single HTTP client connection with:
 * - Reference counting for async operation safety
 * - Connection timeout handling
 * - Keep-alive support for connection reuse
 * - Proper async cleanup
 */
module c3web::http1::client_connection;

import c3web::http1::response_parser;
import c3web::http1::client_response;
import c3web::http1::client_request;
import async::tcp;
import async::timer;
import async::event_loop;
import std::io;
import std::time;

faultdef CONNECTION_ERROR, CONNECTION_TIMEOUT, CONNECTION_CLOSED, DNS_ERROR;

/**
 * Client connection state
 */
enum ConnectionState : char {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    CLOSING,
    CLOSED,
}

/**
 * HTTP client connection with reference counting
 */
struct ClientConnection {
    tcp::TcpConnection* tcp_conn;
    response_parser::ResponseParser parser;

    String host;
    ushort port;
    ConnectionState state;
    bool keep_alive;
    bool is_closed;        // Safety flag to prevent use-after-free
    int refcount;          // Reference count for async operations

    timer::Timer* timeout;
    long last_used_time;   // Unix timestamp for idle tracking

    // Callbacks
    ConnectCallback connect_cb;
    void* connect_user_data;

    ResponseCallback response_cb;
    void* response_user_data;

    Allocator allocator;
}

/**
 * Callback when connection is established
 */
alias ConnectCallback = fn void(ClientConnection* conn, int status, void* user_data);

/**
 * Callback when response is received
 */
alias ResponseCallback = fn void(ClientConnection* conn, client_response::ClientResponse* response,
                                  char[] body, void* user_data);

/**
 * Connect to HTTP server
 */
fn ClientConnection*? connect(event_loop::EventLoop* loop, String host, ushort port,
                              ConnectCallback callback, void* user_data = null,
                              Allocator allocator = mem) @public
{
    ClientConnection* conn = mem::new(ClientConnection);
    conn.host = host.copy(allocator);
    conn.port = port;
    conn.state = ConnectionState.CONNECTING;
    conn.keep_alive = true;  // HTTP/1.1 defaults to keep-alive
    conn.is_closed = false;
    conn.refcount = 1;  // Owner reference
    conn.connect_cb = callback;
    conn.connect_user_data = user_data;
    conn.allocator = allocator;
    conn.parser.init(allocator);
    conn.last_used_time = (long)time::now().to_seconds();

    // Create connection timeout (30 seconds)
    conn.timeout = timer::create(loop)!;
    conn.timeout.start(30000, 0, &on_connection_timeout, conn);
    conn.refcount++;  // Timer holds a reference

    // Initiate TCP connection
    conn.tcp_conn = tcp::connect(loop, host, port, &on_tcp_connect, conn)!;
    conn.refcount++;  // TCP connect callback holds a reference

    return conn;
}

/**
 * Send HTTP request on this connection
 */
fn void? ClientConnection.send_request(&self, client_request::ClientRequest* request,
                                       ResponseCallback callback, void* user_data = null) @public
{
    if (self.is_closed || self.state != ConnectionState.CONNECTED) {
        return CONNECTION_CLOSED?;
    }

    self.response_cb = callback;
    self.response_user_data = user_data;

    // Serialize request to string
    String request_str = request.to_string();

    // Write to TCP connection
    self.tcp_conn.write((char[])request_str, &on_request_sent, self)!;
    self.refcount++;  // Write callback holds a reference

    self.last_used_time = (long)time::now().to_seconds();
}

/**
 * Close connection (async, safe with pending operations)
 */
fn void ClientConnection.close(&self) @public
{
    // Idempotent - only execute once
    if (self.is_closed) return;

    // Mark closed FIRST to prevent use-after-free in callbacks
    self.is_closed = true;
    self.state = ConnectionState.CLOSING;

    // Close TCP connection
    if (self.tcp_conn) {
        self.tcp_conn.close();
        self.tcp_conn = null;
    }

    // Stop and close timeout timer
    if (self.timeout) {
        self.timeout.stop();
        self.timeout.close();
        self.timeout = null;
    }

    // Decrement owner reference - may free if no pending async operations
    decrement_and_free_if_zero(self);
}

/**
 * Check if connection can be reused
 */
fn bool ClientConnection.is_reusable(&self) @public
{
    return !self.is_closed &&
           self.state == ConnectionState.CONNECTED &&
           self.keep_alive;
}

/**
 * Get idle time in seconds
 */
fn long ClientConnection.idle_seconds(&self) @public
{
    return (long)time::now().to_seconds() - self.last_used_time;
}

// ============================================================================
// Reference Counting Helpers
// ============================================================================

/**
 * Decrement refcount and free when it reaches zero
 */
fn void decrement_and_free_if_zero(ClientConnection* conn)
{
    conn.refcount--;

    if (conn.refcount == 0) {
        // Free all resources
        conn.parser.free();
        conn.host.free(conn.allocator);
        mem::free(conn);  // Free the connection struct itself
    } else if (conn.refcount < 0) {
        // BUG: Indicates missing increment or double-decrement
        io::eprintfn("[BUG] ClientConnection refcount went negative (%d)", conn.refcount);
    }
}

// ============================================================================
// TCP Callbacks
// ============================================================================

/**
 * Called when TCP connection is established (or fails)
 */
fn void on_tcp_connect(tcp::TcpConnection* tcp_conn, int status, void* user_data)
{
    ClientConnection* conn = (ClientConnection*)user_data;
    defer decrement_and_free_if_zero(conn);

    // Safety check
    if (conn.is_closed) return;

    // Cancel connection timeout
    if (conn.timeout) {
        conn.timeout.stop();
        conn.timeout.close();
        conn.timeout = null;
        decrement_and_free_if_zero(conn);  // Timer reference released
    }

    if (status != 0) {
        // Connection failed
        io::eprintfn("TCP connection failed: %d", status);
        conn.state = ConnectionState.CLOSED;

        // Notify user
        if (conn.connect_cb) {
            conn.connect_cb(conn, status, conn.connect_user_data);
        }
        return;
    }

    // Connected successfully
    conn.state = ConnectionState.CONNECTED;
    conn.last_used_time = (long)time::now().to_seconds();

    // Enable TCP keep-alive (60 second delay)
    conn.tcp_conn.set_keepalive(true, 60)!!;

    // Disable Nagle's algorithm for lower latency
    conn.tcp_conn.set_nodelay(true)!!;

    // Start reading responses
    conn.tcp_conn.start_read(&on_alloc, &on_read, conn)!!;
    conn.refcount++;  // Read callback holds a reference

    // Notify user of successful connection
    if (conn.connect_cb) {
        conn.connect_cb(conn, 0, conn.connect_user_data);
    }
}

/**
 * Allocate buffer for incoming data
 */
fn char[] on_alloc(tcp::TcpConnection* tcp_conn, usz suggested_size, void* user_data)
{
    return mem::new_array(char, suggested_size);
}

/**
 * Called when data is received
 */
fn void on_read(tcp::TcpConnection* tcp_conn, char[] data, void* user_data)
{
    ClientConnection* conn = (ClientConnection*)user_data;
    defer decrement_and_free_if_zero(conn);

    // Safety check
    if (conn.is_closed) return;

    if (data.len == 0) {
        // EOF or error - connection closed by server
        conn.state = ConnectionState.CLOSED;
        conn.close();
        return;
    }

    // Feed data to parser
    response_parser::ParseResult? result = conn.parser.feed(data);

    if (catch err = result) {
        // Parse error
        io::eprintfn("Response parse error");
        conn.close();
        return;
    }

    if (result == response_parser::ParseResult.COMPLETE) {
        // Response complete
        client_response::ClientResponse* response = conn.parser.get_response();
        char[] body = conn.parser.get_body();

        // Update connection state based on response headers
        update_keep_alive_from_response(conn, response);

        // Notify user
        if (conn.response_cb) {
            conn.response_cb(conn, response, body, conn.response_user_data);
        }

        // Reset parser for next response (if keep-alive)
        if (conn.keep_alive) {
            conn.parser.reset();
        } else {
            // Close connection after response
            conn.close();
        }

        conn.last_used_time = (long)time::now().to_seconds();
    } else {
        // Need more data - continue reading
        conn.tcp_conn.start_read(&on_alloc, &on_read, conn)!!;
        conn.refcount++;  // Next read callback holds a reference
    }
}

/**
 * Called when request has been sent
 */
fn void on_request_sent(tcp::TcpConnection* tcp_conn, int status, void* user_data)
{
    ClientConnection* conn = (ClientConnection*)user_data;
    defer decrement_and_free_if_zero(conn);

    // Safety check
    if (conn.is_closed) return;

    if (status != 0) {
        // Write error
        io::eprintfn("Request send failed: %d", status);
        conn.close();
        return;
    }

    // Request sent successfully - now waiting for response
    conn.last_used_time = (long)time::now().to_seconds();
}

/**
 * Called when connection timeout expires
 */
fn void on_connection_timeout(timer::Timer* timer, void* user_data)
{
    ClientConnection* conn = (ClientConnection*)user_data;
    defer decrement_and_free_if_zero(conn);

    // Safety check
    if (conn.is_closed) return;

    io::eprintfn("Connection timeout");

    // Close timer
    timer.close();
    conn.timeout = null;

    // If still connecting, notify failure
    if (conn.state == ConnectionState.CONNECTING) {
        conn.state = ConnectionState.CLOSED;

        if (conn.connect_cb) {
            conn.connect_cb(conn, -1, conn.connect_user_data);  // -1 = timeout
        }
    }

    // Close connection
    conn.close();
}

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Update keep-alive state based on response headers
 */
fn void update_keep_alive_from_response(ClientConnection* conn, client_response::ClientResponse* response)
{
    // Check Connection header
    String? connection_header = response.headers.get("Connection");
    if (try value = connection_header) {
        String lower = value.to_lower_tcopy();
        if (lower.contains("close")) {
            conn.keep_alive = false;
        } else if (lower.contains("keep-alive")) {
            conn.keep_alive = true;
        }
    }

    // HTTP/1.0 requires explicit keep-alive
    if (response.version.is_http10()) {
        if (catch err = connection_header) {
            conn.keep_alive = false;  // No Connection header in HTTP/1.0 = close
        }
    }

    // HTTP/1.1 defaults to keep-alive unless Connection: close
    // (already handled above)
}
