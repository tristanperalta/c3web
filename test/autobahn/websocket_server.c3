/**
 * WebSocket Echo Server for Autobahn Testsuite
 *
 * RFC 6455 compliant WebSocket server using c3io async event loop.
 * Echoes all messages back for Autobahn conformance testing.
 */
module c3web::test::autobahn::server;

import c3web::websocket::connection;
import c3web::websocket::handshake;
import c3web::websocket::frame;
import c3web::http1::parser;
import async::event_loop;
import async::tcp;
import std::io;

const ushort SERVER_PORT = 9002;

struct WebSocketSession
{
    tcp::TcpConnection* conn;
    connection::WebSocketConnection ws_conn;
    parser::Parser http_parser;
    bool handshake_complete;
    bool handshake_response_writing;
    int session_id;
    DString pipelined_buffer;  // Buffer for data received during handshake write
    DString frame_buffer;      // Buffer for incomplete WebSocket frames (TCP fragmentation)
}

int global_session_id = 0;

fn int main()
{
    io::printn("Starting WebSocket Echo Server for Autobahn Testsuite...");
    io::printfn("Listening on ws://0.0.0.0:%d (accessible via ws://localhost:%d)", SERVER_PORT, SERVER_PORT);

    // Create event loop
    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        io::eprintfn("[ERROR] Failed to create event loop");
        return 1;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    // Create TCP server
    tcp::TcpConnection*? server_opt = tcp::create(&loop);
    if (catch err = server_opt)
    {
        io::eprintfn("[ERROR] Failed to create server");
        return 1;
    }
    tcp::TcpConnection* server = server_opt;
    defer server.close();

    // Bind and listen (0.0.0.0 to accept connections from Docker)
    server.bind("0.0.0.0", SERVER_PORT)!!;
    server.listen(128, &on_connection)!!;

    io::printn("[READY] Server listening - waiting for Autobahn client connections");
    io::stdout().flush()!!;

    // Run event loop
    loop.run()!!;

    return 0;
}

/**
 * Connection callback - called when client connects
 */
fn void on_connection(tcp::TcpConnection* server, tcp::TcpConnection* client, void* user_data)
{
    // Create WebSocket session
    WebSocketSession* session = mem::new(WebSocketSession);
    session.conn = client;
    session.ws_conn.init();
    session.http_parser.init(mem);
    session.handshake_complete = false;
    session.handshake_response_writing = false;
    session.session_id = ++global_session_id;
    session.pipelined_buffer = dstring::new(mem);
    session.frame_buffer = dstring::new(mem);

    io::printfn("[%d] New connection", session.session_id);

    // Set up async read
    client.start_read(&on_alloc, &on_read, session)!!;
}

/**
 * Allocator callback for c3io
 */
fn char[] on_alloc(tcp::TcpConnection* conn, usz suggested_size, void* user_data)
{
    return mem::new_array(char, suggested_size);
}

/**
 * Read callback - called when data arrives
 */
fn void on_read(tcp::TcpConnection* conn, char[] data, void* user_data)
{
    WebSocketSession* session = (WebSocketSession*)user_data;

    // Check for EOF
    if (data.len == 0)
    {
        io::printfn("[%d] Client disconnected (EOF)", session.session_id);
        cleanup_session(session);
        return;
    }

    io::printfn("[%d] Received %d bytes (handshake_complete=%s, writing_handshake=%s)",
                session.session_id, data.len,
                session.handshake_complete ? "true" : "false",
                session.handshake_response_writing ? "true" : "false");

    // Buffer incoming data while handshake response is being written
    if (session.handshake_response_writing)
    {
        io::printfn("[%d] Buffering %d bytes - handshake response still being written", session.session_id, data.len);
        session.pipelined_buffer.append(data);
        return;
    }

    if (!session.handshake_complete)
    {
        // Still doing HTTP handshake
        handle_handshake(session, data);
    }
    else
    {
        // WebSocket established - handle frames
        handle_websocket_data(session, data);
    }
}

/**
 * Handle HTTP WebSocket upgrade handshake
 */
fn void handle_handshake(WebSocketSession* session, char[] data)
{
    // Feed data to HTTP parser
    parser::ParseResult? result = session.http_parser.feed(data);

    if (catch err = result)
    {
        io::eprintfn("[%d] Invalid handshake: %s", session.session_id, err);
        send_http_error(session, 400, "Bad Request");
        cleanup_session(session);
        return;
    }

    if (result != parser::ParseResult.COMPLETE)
    {
        // Need more data
        return;
    }

    // Got complete HTTP request - validate WebSocket upgrade
    parser::Request* req = session.http_parser.get_request();

    if (!handshake::validate_upgrade_request(req))
    {
        io::eprintfn("[%d] Invalid WebSocket upgrade request", session.session_id);
        send_http_error(session, 400, "Bad Request");
        cleanup_session(session);
        return;
    }

    // Get Sec-WebSocket-Key
    String? ws_key = req.headers.get("sec-websocket-key");
    if (catch ws_key)
    {
        send_http_error(session, 400, "Missing Sec-WebSocket-Key");
        cleanup_session(session);
        return;
    }

    io::printfn("[%d] Received Sec-WebSocket-Key: %s (len=%d)", session.session_id, ws_key, ws_key.len);

    // Generate accept key
    String? accept_key = handshake::generate_websocket_accept(ws_key);
    if (catch err = accept_key)
    {
        io::eprintfn("[%d] Failed to generate accept key: %s", session.session_id, err);
        send_http_error(session, 500, "Internal Server Error");
        cleanup_session(session);
        return;
    }

    // Log the generated accept key for debugging
    io::printfn("[%d] Generated Sec-WebSocket-Accept: '%s' (len=%d)", session.session_id, accept_key, accept_key.len);

    // Build handshake response (use heap, not temp, for async write)
    DString response = dstring::new_with_capacity(mem, 512);
    defer response.free();

    response.append("HTTP/1.1 101 Switching Protocols\r\n");
    response.append("Upgrade: websocket\r\n");
    response.append("Connection: Upgrade\r\n");
    response.appendf("Sec-WebSocket-Accept: %s\r\n", accept_key);
    response.append("\r\n");

    // Send response (tcp.write() will copy this valid heap data)
    io::printfn("[%d] Sending handshake response (%d bytes)", session.session_id, response.len());
    io::printfn("[%d] Response accept key in header: '%s'", session.session_id, accept_key);

    // Get response as char array
    char[] response_bytes = (char[])response.str_view();
    io::printfn("[%d] Response bytes length: %d", session.session_id, response_bytes.len);
    io::printfn("[%d] Response preview: %s", session.session_id, response.str_view()[:50]);

    // Mark that we're writing the handshake - will set handshake_complete in callback
    session.handshake_response_writing = true;
    session.conn.write(response_bytes, &on_handshake_write_complete, session)!!;
}

/**
 * Handle WebSocket frame data with TCP fragmentation buffering
 */
fn void handle_websocket_data(WebSocketSession* session, char[] data)
{
    // Append incoming data to frame buffer
    session.frame_buffer.append(data);

    // Process frames from buffer until we can't parse anymore
    while (session.frame_buffer.len() > 0)
    {
        char[] buffer_data = (char[])session.frame_buffer.str_view();

        // First try to parse the frame header to see if we have enough data
        frame::Frame? header_result = frame::parse_header(buffer_data);
        if (catch header_err = header_result)
        {
            if (header_err == frame::INCOMPLETE_FRAME)
            {
                // Need more data for header - wait for next read
                return;
            }
            // Other header error - protocol violation
            io::eprintfn("[%d] Frame header error: %s", session.session_id, header_err);
            cleanup_session(session);
            return;
        }

        frame::Frame header = header_result;

        // Calculate total frame size needed
        ulong header_size = 2;
        if (buffer_data.len >= 2)
        {
            char payload_len_first = buffer_data[1] & 0x7F;
            if (payload_len_first == 126)
            {
                header_size += 2;
            }
            else if (payload_len_first == 127)
            {
                header_size += 8;
            }
        }
        if (header.masked)
        {
            header_size += 4;
        }
        ulong total_frame_size = header_size + header.payload_len;

        // Check if we have complete frame
        if (buffer_data.len < total_frame_size)
        {
            // Need more data for payload - wait for next read
            return;
        }

        // We have a complete frame - process it
        char[] frame_data = buffer_data[:total_frame_size];

        // Check if it's a control frame
        if (frame::is_control_frame(header.opcode))
        {
            // Handle control frame
            if (try control_response = session.ws_conn.handle_control_frame(frame_data))
            {
                if (control_response.len > 0)
                {
                    if (catch err = session.conn.write(control_response, &on_write_complete, session))
                    {
                        io::eprintfn("[%d] Control frame write failed: %s", session.session_id, err);
                        cleanup_session(session);
                        return;
                    }
                }

                // Check if closed
                if (session.ws_conn.state == connection::State.CLOSED)
                {
                    io::printfn("[%d] WebSocket close handshake complete", session.session_id);
                    cleanup_session(session);
                    return;
                }
            }
            else if (catch control_err = session.ws_conn.handle_control_frame(frame_data))
            {
                io::eprintfn("[%d] Error handling control frame: %s", session.session_id, control_err);
                cleanup_session(session);
                return;
            }
        }
        else
        {
            // Handle data frame
            if (try msg = session.ws_conn.receive_message(frame_data))
            {
                // Got complete message - echo it back
                char[]? echo_frame;

                if (msg.opcode == frame::Opcode.TEXT)
                {
                    echo_frame = session.ws_conn.send_text((String)msg.payload);
                }
                else if (msg.opcode == frame::Opcode.BINARY)
                {
                    echo_frame = session.ws_conn.send_binary(msg.payload);
                }

                if (catch err = echo_frame)
                {
                    io::eprintfn("[%d] Failed to create echo frame: %s", session.session_id, err);
                    cleanup_session(session);
                    return;
                }

                // Send echo
                if (catch err = session.conn.write(echo_frame, &on_write_complete, session))
                {
                    io::eprintfn("[%d] Write failed: %s", session.session_id, err);
                    cleanup_session(session);
                    return;
                }

                // Free message payload
                if (msg.payload_len > 0)
                {
                    mem::free(msg.payload.ptr);
                }
            }
            else if (catch msg_err = session.ws_conn.receive_message(frame_data))
            {
                // MESSAGE_INCOMPLETE means fragmented message waiting for continuation
                if (msg_err == connection::MESSAGE_INCOMPLETE)
                {
                    // This is ok - we're in the middle of a fragmented message
                }
                else
                {
                    io::eprintfn("[%d] Error receiving message: %s", session.session_id, msg_err);
                    cleanup_session(session);
                    return;
                }
            }
        }

        // Remove processed frame from buffer
        // Create new buffer with remaining data
        usz remaining_len = buffer_data.len - total_frame_size;
        if (remaining_len > 0)
        {
            DString new_buffer = dstring::new(mem);
            new_buffer.append(buffer_data[total_frame_size:remaining_len]);
            session.frame_buffer.free();
            session.frame_buffer = new_buffer;
        }
        else
        {
            session.frame_buffer.clear();
        }
    }
}

/**
 * Handshake write completion callback
 */
fn void on_handshake_write_complete(tcp::TcpConnection* conn, int status, void* user_data)
{
    WebSocketSession* session = (WebSocketSession*)user_data;

    if (status < 0)
    {
        io::eprintfn("[%d] Handshake write error", session.session_id);
        cleanup_session(session);
        return;
    }

    // Handshake response has been sent - now we can accept WebSocket frames
    session.handshake_response_writing = false;
    session.handshake_complete = true;
    io::printfn("[%d] WebSocket handshake complete (response sent)", session.session_id);

    // Check if there's remaining data in the HTTP parser buffer (pipelined WebSocket frames)
    char[] remaining = session.http_parser.get_readable_buffer();
    if (remaining.len > 0)
    {
        io::printfn("[%d] Processing %d bytes of HTTP parser remaining data", session.session_id, remaining.len);
        handle_websocket_data(session, remaining);
    }

    // Process any data that was buffered during the handshake write
    if (session.pipelined_buffer.len() > 0)
    {
        io::printfn("[%d] Processing %d bytes of buffered pipelined data", session.session_id, session.pipelined_buffer.len());
        handle_websocket_data(session, (char[])session.pipelined_buffer.str_view());
        session.pipelined_buffer.clear();
    }
}

/**
 * Write completion callback
 */
fn void on_write_complete(tcp::TcpConnection* conn, int status, void* user_data)
{
    if (status < 0)
    {
        WebSocketSession* session = (WebSocketSession*)user_data;
        io::eprintfn("[%d] Write error", session.session_id);
        cleanup_session(session);
    }
}

/**
 * Send HTTP error response
 */
fn void send_http_error(WebSocketSession* session, ushort status, String status_text)
{
    DString response = dstring::new_with_capacity(mem, 256);
    defer response.free();

    response.appendfn("HTTP/1.1 %d %s\r\n", status, status_text);
    response.append("Content-Type: text/plain\r\n");
    response.appendfn("Content-Length: %d\r\n", status_text.len);
    response.append("Connection: close\r\n");
    response.append("\r\n");
    response.append(status_text);

    session.conn.write((char[])response.str_view(), &on_write_complete, session)!!;
}

/**
 * Clean up session
 */
fn void cleanup_session(WebSocketSession* session)
{
    session.ws_conn.free();
    session.http_parser.free();
    session.pipelined_buffer.free();
    session.frame_buffer.free();
    session.conn.close();
    mem::free(session);
}
