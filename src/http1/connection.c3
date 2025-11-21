<*
 * HTTP/1.1 Connection Management
 *
 * Manages a single HTTP/1.1 connection with request parsing and response writing.
 * Uses c3io async callbacks for I/O operations.
 *>
module c3web::http1::connection;

import c3web::http1::parser;
import c3web::http1::response;
import c3web::common::status;
import async::tcp;
import std::io;
import std::core::mem::allocator;

<* Connection states for the HTTP/1.1 connection lifecycle. *>
enum ConnectionState : char {
    IDLE,           // Connection established, waiting for request
    READING,        // Reading request data
    PROCESSING,     // Processing request (application handler)
    WRITING,        // Writing response data
    CLOSING,        // Closing connection
    CLOSED,         // Connection closed
}

<* Represents a single HTTP/1.1 connection. *>
struct Connection {
    tcp::TcpConnection* client;
    ConnectionState state;
    parser::Parser parser;
    response::Response current_response;
    bool keep_alive;
    Allocator allocator;
    RequestHandlerFn handler;
    void* handler_data;
}

<* Handler callback type for processing HTTP requests. *>
alias RequestHandlerFn = fn void(Connection* conn, parser::Request* request, response::Response* resp);

<* Create new connection with TCP client. *>
fn Connection* create_connection(tcp::TcpConnection* client, RequestHandlerFn handler, void* handler_data, Allocator alloc = mem) {
    Connection* conn = allocator::new(alloc, Connection);
    conn.client = client;
    conn.state = ConnectionState.IDLE;
    conn.parser.init(alloc);
    conn.current_response.init(alloc);
    conn.keep_alive = true;
    conn.allocator = alloc;
    conn.handler = handler;
    conn.handler_data = handler_data;
    return conn;
}

<* Free connection resources. *>
fn void Connection.free(&self) {
    self.parser.free();
    self.current_response.free();
}

<*
 * Allocator callback for c3io read operations.
 * Allocates buffer for incoming data.
 *>
fn char[] on_alloc(tcp::TcpConnection* client, usz suggested_size, void* user_data) {
    return mem::new_array(char, suggested_size);
}

<*
 * Read callback for c3io.
 * Called when data arrives from client.
 *>
fn void on_read(tcp::TcpConnection* client, char[] data, void* user_data) {
    Connection* conn = (Connection*)user_data;

    // Check for EOF (connection closed)
    if (data.len == 0) {
        conn.close();
        return;
    }

    // Feed data to parser
    parser::ParseResult? result = conn.parser.feed(data);

    if (catch err = result) {
        // Parse error - send 400 Bad Request
        conn.send_error_response(status::STATUS_BAD_REQUEST);
        return;
    }

    // Check if parsing is complete
    if (result == parser::ParseResult.COMPLETE) {
        conn.state = ConnectionState.PROCESSING;

        // Check for Connection: close header
        if (conn.parser.get_request().headers.is_connection_close()) {
            conn.keep_alive = false;
        }

        // Reset response for new request
        conn.current_response.reset();

        // Call application handler
        conn.handler(conn, conn.parser.get_request(), &conn.current_response);

        // Send response
        conn.send_response();
    }
    // Otherwise, keep reading (ParseResult.MORE)
}

<*
 * Write callback for c3io.
 * Called when write operation completes.
 *>
fn void on_write(tcp::TcpConnection* client, int status, void* user_data) {
    Connection* conn = (Connection*)user_data;

    if (status != 0) {
        // Write error - close connection
        conn.close();
        return;
    }

    // Determine next state
    if (conn.keep_alive) {
        conn.state = ConnectionState.IDLE;
        conn.reset_for_next_request();
    } else {
        conn.close();
    }
}

<*
 * Send HTTP response to client.
 * Serializes response and initiates async write.
 *>
fn void Connection.send_response(&self) {
    self.state = ConnectionState.WRITING;

    // Serialize response to buffer
    io::ByteBuffer buffer;
    buffer.init(self.allocator, 64 * 1024, 4096);
    defer buffer.free();

    self.current_response.serialize(&buffer)!!;

    // Get data to write
    char[] data = buffer.bytes[0 : buffer.write_idx];

    // Start async write (c3io copies data internally)
    self.client.write(data, &on_write, self)!!;
}

<*
 * Send error response to client.
 * Creates error response and sends it.
 *>
fn void Connection.send_error_response(&self, status::HttpStatus status_code) {
    self.current_response.reset();

    self.current_response.set_status(status_code);
    self.current_response.set_content_type("text/plain; charset=utf-8")!!;

    String reason = status::status_reason(status_code);
    self.current_response.write_string(reason)!!;

    self.keep_alive = false;  // Close connection after error
    self.send_response();
}

<* Reset connection state for next request (keep-alive). *>
fn void Connection.reset_for_next_request(&self) {
    self.parser.reset();
    self.keep_alive = true;
}

<* Close the connection. *>
fn void Connection.close(&self) {
    if (self.state != ConnectionState.CLOSED) {
        self.client.close();
        self.state = ConnectionState.CLOSED;
    }
}

<*
 * Start reading from client.
 * Should be called when connection is first accepted.
 *>
fn void? Connection.start_reading(&self) {
    self.state = ConnectionState.READING;
    return self.client.start_read(&on_alloc, &on_read, self);
}
