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
import c3web::websocket::control;
import c3web::websocket::message;
import c3web::websocket::compression;
import c3web::websocket::utf8;
import c3web::http1::parser;
import async::event_loop;
import async::tcp;
import std::io;
import std::atomic;
import std::thread;

const ushort SERVER_PORT = 9002;

struct WebSocketSession
{
    Atomic{int} refcount;  // Thread-safe reference counting (freed when refcount hits -1)
    tcp::TcpConnection* conn;
    connection::WebSocketConnection ws_conn;
    parser::Parser http_parser;
    bool handshake_complete;
    bool handshake_response_writing;
    int session_id;
    DString pipelined_buffer;  // Buffer for data received during handshake write
    DString frame_buffer;  // Buffer for incomplete WebSocket frames (TCP fragmentation)
    usz frame_buffer_offset;  // Read offset into frame_buffer (avoid O(n²) copies)
    // Compression support (RFC 7692)
    bool compression_enabled;
    compression::PerMessageDeflate pmd;
    compression::ExtensionParams compression_params;
}

/**
 * Retain - increment reference count
 */
fn void WebSocketSession.retain(&self)
{
    self.refcount.add(1, RELAXED);
}

/**
 * Release - decrement reference count, cleanup when it reaches -1
 */
fn void WebSocketSession.release(&self)
{
    if (self.refcount.sub(1, RELAXED) == 0)
    {
        thread::fence(ACQUIRE);
        self.dealloc();
    }
}

/**
 * Custom cleanup - called when refcount reaches -1
 */
fn void WebSocketSession.dealloc(&self)
{
    io::printfn("[%d] Session refcount reached 0, cleaning up", self.session_id);
    self.ws_conn.free();
    self.http_parser.free();
    self.pipelined_buffer.free();
    self.frame_buffer.free();
    if (self.compression_enabled)
    {
        self.pmd.free();
    }
    self.conn.close();
    mem::free(self);
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
    // Set max message size to 17MB for Autobahn test 9.1.6 (16MB text messages)
    session.ws_conn.set_max_message_size(17 * 1024 * 1024);
    session.http_parser.init(mem);
    session.handshake_complete = false;
    session.handshake_response_writing = false;
    session.session_id = ++global_session_id;
    // RefCounted starts at 0 (valid), freed at -1. We hold one reference for the read callback.
    session.pipelined_buffer = dstring::new(mem);
    session.frame_buffer = dstring::new(mem);
    session.frame_buffer_offset = 0;

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
        session.release();
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
        session.release();
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
        session.release();
        return;
    }

    // Get Sec-WebSocket-Key
    String? ws_key = req.headers.get("sec-websocket-key");
    if (catch ws_key)
    {
        send_http_error(session, 400, "Missing Sec-WebSocket-Key");
        session.release();
        return;
    }

    io::printfn("[%d] Received Sec-WebSocket-Key: %s (len=%d)", session.session_id, ws_key, ws_key.len);

    // Check for compression extension (RFC 7692)
    String? extensions_header = req.headers.get("sec-websocket-extensions");
    if (try ext_header = extensions_header)
    {
        if (ext_header.contains("permessage-deflate"))
        {
            io::printfn("[%d] Client requested permessage-deflate compression", session.session_id);
            // Parse extension parameters
            if (try params = compression::parse_extension(ext_header))
            {
                session.compression_params = params;
                // Initialize compression context
                if (catch init_err = session.pmd.init(params))
                {
                    io::eprintfn("[%d] Failed to init compression: %s", session.session_id, init_err);
                }
                else
                {
                    session.compression_enabled = true;
                    io::printfn("[%d] Compression enabled (server_max_window_bits=%d, client_max_window_bits=%d)",
                                session.session_id, params.server_max_window_bits, params.client_max_window_bits);
                }
            }
        }
    }

    // Generate accept key
    String? accept_key = handshake::generate_websocket_accept(ws_key);
    if (catch err = accept_key)
    {
        io::eprintfn("[%d] Failed to generate accept key: %s", session.session_id, err);
        send_http_error(session, 500, "Internal Server Error");
        session.release();
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
    // Add compression extension to response if enabled
    if (session.compression_enabled)
    {
        String ext_response = compression::generate_response_header(session.compression_params);
        defer mem::free(ext_response.ptr);
        response.appendf("Sec-WebSocket-Extensions: %s\r\n", ext_response);
    }
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
    session.retain();  // +1 ref for write callback
    session.conn.write(response_bytes, &on_handshake_write_complete, session)!!;
}

/**
 * Handle WebSocket frame data with TCP fragmentation buffering
 */
fn void handle_websocket_data(WebSocketSession* session, char[] data)
{
    // Append incoming data to frame buffer
    session.frame_buffer.append_chars((String)data);

    // Process frames from buffer until we can't parse anymore
    while (session.frame_buffer.len() > session.frame_buffer_offset)
    {
        // Get view of unread data in buffer (from offset to end)
        char[] buffer_data = ((char[])session.frame_buffer.str_view())[session.frame_buffer_offset..];

        // First try to parse the frame header to see if we have enough data
        // Allow RSV1 if compression is enabled (RFC 7692)
        frame::Frame? header_result = frame::parse_header(buffer_data, session.compression_enabled);
        if (catch header_err = header_result)
        {
            if (header_err == frame::INCOMPLETE_FRAME)
            {
                // Need more data for header - wait for next read
                return;
            }
            // Other header error - protocol violation, send close with 1002
            io::eprintfn("[%d] Frame header error: %s", session.session_id, header_err);
            send_close_and_release(session, control::CLOSE_PROTOCOL_ERROR, "Protocol error");
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
                    session.retain();  // +1 ref for write callback
                    if (catch err = session.conn.write(control_response, &on_write_complete, session))
                    {
                        io::eprintfn("[%d] Control frame write failed: %s", session.session_id, err);
                        session.release();  // Release the ref we just took
                        session.release();  // Release main ref
                        return;
                    }
                }

                // Check if closed
                if (session.ws_conn.state == connection::State.CLOSED)
                {
                    io::printfn("[%d] WebSocket close handshake complete", session.session_id);
                    session.release();
                    return;
                }
            }
            else if (catch control_err = session.ws_conn.handle_control_frame(frame_data))
            {
                io::eprintfn("[%d] Error handling control frame: %s", session.session_id, control_err);
                send_close_and_release(session, control::CLOSE_PROTOCOL_ERROR, "Protocol error");
                return;
            }
        }
        else
        {
            // Handle data frame - call receive_message ONCE
            // Pass allow_rsv1=true if compression enabled
            connection::Message? msg_result = session.ws_conn.receive_message(frame_data, session.compression_enabled);

            if (catch msg_err = msg_result)
            {
                // MESSAGE_INCOMPLETE means fragmented message waiting for continuation
                if (msg_err == connection::MESSAGE_INCOMPLETE)
                {
                    // This is ok - we're in the middle of a fragmented message
                    // Continue to next frame
                }
                else if (msg_err == message::INVALID_UTF8)
                {
                    // UTF-8 validation error - use 1007
                    io::eprintfn("[%d] Invalid UTF-8 in text message", session.session_id);
                    send_close_and_release(session, control::CLOSE_INVALID_PAYLOAD, "Invalid UTF-8");
                    return;
                }
                else
                {
                    io::eprintfn("[%d] Error receiving message: %s", session.session_id, msg_err);
                    send_close_and_release(session, control::CLOSE_PROTOCOL_ERROR, "Protocol error");
                    return;
                }
            }
            else
            {
                // Got complete message - echo it back
                connection::Message msg = msg_result;
                char[] payload_to_echo = msg.payload;
                bool payload_needs_free = true;

                // Decompress if the message was compressed (RSV1 set on first frame)
                if (msg.compressed && session.compression_enabled)
                {
                    if (try decompressed = session.pmd.decompress_message(msg.payload))
                    {
                        // Free original compressed payload
                        if (msg.payload_len > 0)
                        {
                            mem::free(msg.payload.ptr);
                        }
                        payload_to_echo = decompressed;
                        // Decompressed payload needs to be freed later

                        // Validate UTF-8 for TEXT messages after decompression (RFC 7692)
                        if (msg.opcode == frame::Opcode.TEXT && payload_to_echo.len > 0)
                        {
                            utf8::Utf8Validator validator;
                            validator.init();
                            if (!validator.validate_incremental(payload_to_echo) || !validator.is_complete())
                            {
                                io::eprintfn("[%d] Invalid UTF-8 in decompressed text message", session.session_id);
                                mem::free(payload_to_echo.ptr);
                                send_close_and_release(session, control::CLOSE_INVALID_PAYLOAD, "Invalid UTF-8");
                                return;
                            }
                        }
                    }
                    else if (catch decomp_err = session.pmd.decompress_message(msg.payload))
                    {
                        io::eprintfn("[%d] Decompression failed: %s", session.session_id, decomp_err);
                        if (msg.payload_len > 0)
                        {
                            mem::free(msg.payload.ptr);
                        }
                        send_close_and_release(session, control::CLOSE_PROTOCOL_ERROR, "Decompression error");
                        return;
                    }
                }

                char[]? echo_frame;

                // Compress echo response if compression is enabled
                if (session.compression_enabled)
                {
                    // Compress the payload
                    if (try compressed = session.pmd.compress_message(payload_to_echo))
                    {
                        // Create frame with RSV1=1 to indicate compression
                        echo_frame = frame::create_frame_with_rsv(msg.opcode, compressed, true, false, true, false, false);
                        mem::free(compressed.ptr);
                    }
                    else if (catch comp_err = session.pmd.compress_message(payload_to_echo))
                    {
                        io::eprintfn("[%d] Compression failed: %s, sending uncompressed", session.session_id, comp_err);
                        // Fall back to uncompressed
                        if (msg.opcode == frame::Opcode.TEXT)
                        {
                            echo_frame = session.ws_conn.send_text((String)payload_to_echo);
                        }
                        else
                        {
                            echo_frame = session.ws_conn.send_binary(payload_to_echo);
                        }
                    }
                }
                else
                {
                    // No compression - send as-is
                    if (msg.opcode == frame::Opcode.TEXT)
                    {
                        echo_frame = session.ws_conn.send_text((String)payload_to_echo);
                    }
                    else if (msg.opcode == frame::Opcode.BINARY)
                    {
                        echo_frame = session.ws_conn.send_binary(payload_to_echo);
                    }
                }

                if (catch err = echo_frame)
                {
                    io::eprintfn("[%d] Failed to create echo frame: %s", session.session_id, err);
                    if (payload_needs_free && payload_to_echo.len > 0)
                    {
                        mem::free(payload_to_echo.ptr);
                    }
                    session.release();
                    return;
                }

                // Send echo
                session.retain();  // +1 ref for write callback
                if (catch err = session.conn.write(echo_frame, &on_write_complete, session))
                {
                    io::eprintfn("[%d] Write failed: %s", session.session_id, err);
                    session.release();  // Release the ref we just took
                    session.release();  // Release main ref
                    if (payload_needs_free && payload_to_echo.len > 0)
                    {
                        mem::free(payload_to_echo.ptr);
                    }
                    return;
                }

                // Free payload
                if (payload_needs_free && payload_to_echo.len > 0)
                {
                    mem::free(payload_to_echo.ptr);
                }
            }
        }

        // Consume processed frame by advancing offset (O(1) instead of O(n) copy)
        session.frame_buffer_offset += total_frame_size;

        // Compact buffer periodically when offset exceeds 1MB to prevent unbounded growth
        if (session.frame_buffer_offset > 1024 * 1024)
        {
            // Remove consumed bytes from front of buffer
            usz remaining = session.frame_buffer.len() - session.frame_buffer_offset;
            if (remaining > 0)
            {
                char[] remaining_data = ((char[])session.frame_buffer.str_view())[session.frame_buffer_offset..];
                session.frame_buffer.clear();
                session.frame_buffer.append_chars((String)remaining_data);
            }
            else
            {
                session.frame_buffer.clear();
            }
            session.frame_buffer_offset = 0;
        }
    }
}

/**
 * Handshake write completion callback
 */
fn void on_handshake_write_complete(tcp::TcpConnection* conn, int status, void* user_data)
{
    WebSocketSession* session = (WebSocketSession*)user_data;
    defer session.release();  // Always release write callback ref

    if (status < 0)
    {
        io::eprintfn("[%d] Handshake write error", session.session_id);
        return;  // defer will release
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
    WebSocketSession* session = (WebSocketSession*)user_data;
    defer session.release();  // Always release write callback ref

    if (status < 0)
    {
        io::eprintfn("[%d] Write error", session.session_id);
        // defer will release the write callback ref
        // No need to explicitly release main ref - the read callback or other callbacks will handle it
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

    session.retain();  // +1 ref for write callback
    session.conn.write((char[])response.str_view(), &on_write_complete, session)!!;
}

/**
 * Send a close frame with the given status code and release main ref
 */
fn void send_close_and_release(WebSocketSession* session, ushort status_code, String reason)
{
    if (try close_frame = control::create_close_frame(status_code, reason))
    {
        io::printfn("[%d] Sending close frame with code %d: %s", session.session_id, status_code, reason);
        // Send close frame, then release in callback
        session.retain();  // +1 ref for close write callback
        if (catch err = session.conn.write(close_frame, &on_close_write_complete, session))
        {
            io::eprintfn("[%d] Failed to send close frame: %s", session.session_id, err);
            session.release();  // Release the ref we just took
        }
    }
    // Release main reference (read callback ref)
    session.release();
}

/**
 * Close frame write completion callback
 */
fn void on_close_write_complete(tcp::TcpConnection* conn, int status, void* user_data)
{
    WebSocketSession* session = (WebSocketSession*)user_data;
    io::printfn("[%d] Close frame sent, releasing ref", session.session_id);
    session.release();  // Release close write callback ref
}

