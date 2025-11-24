/**
 * HTTP/2 Test Server for h2spec Conformance Testing
 *
 * Minimal HTTP/2 server implementation using c3io async event loop.
 * This server will be expanded as the HTTP/2 implementation progresses.
 *
 * Current capabilities:
 * - Connection preface validation ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
 * - SETTINGS frame exchange
 * - PING/PONG handling
 * - GOAWAY for graceful shutdown
 *
 * RFC 9113 compliant where implemented.
 */
module c3web::test::h2spec::server;

import async::event_loop;
import async::tcp;
import std::io;
import std::atomic;
import std::thread;
import c3web::http2::stream;
import c3web::http2::frame;
import c3web::http2::hpack;
import std::collections::map;
import std::core::mem::allocator;
import libc;

const ushort SERVER_PORT = 8080;

// Signal handling for SIGPIPE (POSIX)
// SIG_IGN is typically (void*)1 - ignore signal
extern fn void* signal(CInt signum, void* handler) @extern("signal");
const void* SIG_IGN_PTR = (void*)(uptr)1;

// HTTP/2 Connection Preface (RFC 9113 §3.4)
// Client must send this first, followed by a SETTINGS frame
const char[24] CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

// Frame Types (RFC 9113 §6)
const char FRAME_DATA          = 0x0;
const char FRAME_HEADERS       = 0x1;
const char FRAME_PRIORITY      = 0x2;
const char FRAME_RST_STREAM    = 0x3;
const char FRAME_SETTINGS      = 0x4;
const char FRAME_PUSH_PROMISE  = 0x5;
const char FRAME_PING          = 0x6;
const char FRAME_GOAWAY        = 0x7;
const char FRAME_WINDOW_UPDATE = 0x8;
const char FRAME_CONTINUATION  = 0x9;

// Frame Flags
const char FLAG_ACK        = 0x1;  // For SETTINGS and PING
const char FLAG_END_STREAM = 0x1;  // For DATA and HEADERS
const char FLAG_END_HEADERS = 0x4; // For HEADERS
const char FLAG_PADDED     = 0x8;
const char FLAG_PRIORITY   = 0x20;

// Error Codes (RFC 9113 §7)
const uint ERR_NO_ERROR            = 0x0;
const uint ERR_PROTOCOL_ERROR      = 0x1;
const uint ERR_INTERNAL_ERROR      = 0x2;
const uint ERR_FLOW_CONTROL_ERROR  = 0x3;
const uint ERR_SETTINGS_TIMEOUT    = 0x4;
const uint ERR_STREAM_CLOSED       = 0x5;
const uint ERR_FRAME_SIZE_ERROR    = 0x6;
const uint ERR_REFUSED_STREAM      = 0x7;
const uint ERR_CANCEL              = 0x8;
const uint ERR_COMPRESSION_ERROR   = 0x9;
const uint ERR_CONNECT_ERROR       = 0xa;
const uint ERR_ENHANCE_YOUR_CALM   = 0xb;
const uint ERR_INADEQUATE_SECURITY = 0xc;
const uint ERR_HTTP_1_1_REQUIRED   = 0xd;

// Settings Identifiers (RFC 9113 §6.5.2)
const ushort SETTINGS_HEADER_TABLE_SIZE      = 0x1;
const ushort SETTINGS_ENABLE_PUSH            = 0x2;
const ushort SETTINGS_MAX_CONCURRENT_STREAMS = 0x3;
const ushort SETTINGS_INITIAL_WINDOW_SIZE    = 0x4;
const ushort SETTINGS_MAX_FRAME_SIZE         = 0x5;
const ushort SETTINGS_MAX_HEADER_LIST_SIZE   = 0x6;

// Default Settings Values
const uint DEFAULT_HEADER_TABLE_SIZE      = 4096;
const uint DEFAULT_ENABLE_PUSH            = 1;
const uint DEFAULT_MAX_CONCURRENT_STREAMS = 100;  // Unlimited by default, but we set a reasonable limit
const uint DEFAULT_INITIAL_WINDOW_SIZE    = 65535;
const uint DEFAULT_MAX_FRAME_SIZE         = 16384;
const uint MAX_FRAME_SIZE_LIMIT           = 16777215;  // 2^24 - 1

enum ConnectionState
{
    AWAITING_PREFACE,
    AWAITING_SETTINGS,
    OPEN,
    CLOSING,
    CLOSED
}

struct H2Session
{
    Atomic{int} refcount;
    tcp::TcpConnection* conn;
    ConnectionState state;
    int session_id;

    // Per-session arena allocator - all session allocations use this
    // When session ends, just free the arena - no memory leaks possible
    DynamicArenaAllocator arena;

    // Receive buffer for handling TCP fragmentation
    DString recv_buffer;
    usz preface_bytes_received;

    // Settings (local = what we advertise, remote = what peer advertises)
    uint local_max_frame_size;
    uint local_initial_window_size;
    uint local_max_concurrent_streams;
    uint remote_max_frame_size;
    uint remote_initial_window_size;

    // Flow control
    int connection_window;  // Connection-level flow control window

    // State tracking
    bool settings_ack_sent;
    bool settings_ack_received;
    uint last_stream_id;  // Last stream ID processed (for GOAWAY)

    // Stream management
    HashMap{uint, stream::Stream} streams;  // Map stream_id -> Stream state machine
    uint active_stream_count;               // Track concurrent streams
    uint highest_client_stream_id;          // Track highest seen client stream ID (for monotonic check)

    // CONTINUATION state tracking
    bool expecting_continuation;            // True if HEADERS/PUSH_PROMISE had END_HEADERS=0
    uint continuation_stream_id;            // Stream ID expecting CONTINUATION
    bool continuation_end_stream;           // END_STREAM flag from original HEADERS
    DString header_block_buffer;            // Accumulates header fragments

    // Frame validation settings
    frame::ConnectionSettings frame_settings;  // For frame::validate_frame()
}

fn void H2Session.retain(&self)
{
    int old = self.refcount.load(RELAXED);
    if (old < 0)
    {
        io::eprintfn("[%d] FATAL: Retaining zombie session (refcount=%d)", self.session_id, old);
        io::stderr().flush()!!;
        unreachable("Retaining zombie session");
    }
    self.refcount.add(1, RELAXED);
}

fn void H2Session.release(&self)
{
    int old = self.refcount.load(RELAXED);
    if (old < 0)
    {
        io::eprintfn("[%d] FATAL: Over-release of session (refcount=%d)", self.session_id, old);
        io::stderr().flush()!!;
        unreachable("Over-release of session");
    }

    // Refcount semantics: 0 = 1 reference, dealloc when dropping to -1
    // Use RELEASE ordering so other threads see our writes before dealloc
    // sub(1) returns OLD value - dealloc when old was 0 (now -1)
    if (self.refcount.sub(1, RELEASE) == 0)
    {
        thread::fence(ACQUIRE);  // Sync with other threads' RELEASE
        self.dealloc();
    }
}

fn void H2Session.dealloc(&self)
{
    io::printfn("[%d] Session cleanup", self.session_id);

    // Free HashMap first (uses heap allocator)
    self.streams.free();

    // Free header_block_buffer (uses heap allocator for resizing)
    self.header_block_buffer.free();

    // Free the arena - this releases ALL arena allocations at once
    // (recv_buffer and any other arena allocations)
    self.arena.free();

    self.conn.close();
    mem::free(self);
}

fn void H2Session.init(&self)
{
    self.state = ConnectionState.AWAITING_PREFACE;

    // Initialize per-session arena allocator (32KB pages, grows as needed)
    self.arena.init(mem, 32 * 1024);

    // Use arena for DStrings - no manual free needed, arena handles it
    self.recv_buffer.init(&self.arena);
    self.preface_bytes_received = 0;

    // Initialize with default settings
    self.local_max_frame_size = DEFAULT_MAX_FRAME_SIZE;
    self.local_initial_window_size = DEFAULT_INITIAL_WINDOW_SIZE;
    self.local_max_concurrent_streams = DEFAULT_MAX_CONCURRENT_STREAMS;
    self.remote_max_frame_size = DEFAULT_MAX_FRAME_SIZE;
    self.remote_initial_window_size = DEFAULT_INITIAL_WINDOW_SIZE;

    self.connection_window = (int)DEFAULT_INITIAL_WINDOW_SIZE;
    self.settings_ack_sent = false;
    self.settings_ack_received = false;
    self.last_stream_id = 0;

    // Initialize stream tracking (HashMap uses heap, not arena - it needs to resize)
    self.streams.init(mem, 100);  // Capacity of 100 streams
    self.active_stream_count = 0;
    self.highest_client_stream_id = 0;

    // Initialize CONTINUATION state
    self.expecting_continuation = false;
    self.continuation_stream_id = 0;
    // Use heap allocator for header_block_buffer since it needs to grow dynamically
    // Arena allocators don't support reallocation properly
    self.header_block_buffer.init(mem);

    // Initialize frame validation settings
    self.frame_settings = frame::default_settings();
}

/**
 * Stream Management Functions
 */

/**
 * Validate stream ID rules (RFC 9113 §5.1.1)
 * Returns CONNECTION_ERROR for violations
 *
 * Note: PRIORITY frames do NOT create streams (RFC 9113 §5.1) and can be sent
 * for any stream ID. Only HEADERS frames create streams.
 */
fn void? validate_stream_creation(H2Session* session, uint stream_id, char frame_type)
{
    // Only validate for frames that create streams (HEADERS only)
    // PRIORITY frames do NOT open streams - they only affect prioritization
    if (frame_type != FRAME_HEADERS)
    {
        return;  // Other frames don't create streams
    }

    // Check if stream already exists - if so, this is trailer HEADERS, skip validation
    if (session.streams.has_key(stream_id))
    {
        return;  // Stream already exists - this is a trailer or continuation
    }

    // Client streams must be odd
    if (!stream::is_valid_client_stream_id(stream_id))
    {
        io::eprintfn("[%d] Invalid stream ID %d (must be odd)", session.session_id, stream_id);
        send_goaway(session, session.last_stream_id, ERR_PROTOCOL_ERROR);
        return stream::CONNECTION_ERROR?;
    }

    // Stream ID must be greater than previous (monotonically increasing)
    if (stream_id <= session.highest_client_stream_id)
    {
        io::eprintfn("[%d] Stream ID %d not increasing (last was %d)",
                     session.session_id, stream_id, session.highest_client_stream_id);
        send_goaway(session, session.last_stream_id, ERR_PROTOCOL_ERROR);
        return stream::CONNECTION_ERROR?;
    }

    // Check concurrent stream limit
    if (session.active_stream_count >= session.local_max_concurrent_streams)
    {
        io::eprintfn("[%d] Max concurrent streams exceeded", session.session_id);
        send_rst_stream(session, stream_id, ERR_REFUSED_STREAM);
        return stream::STREAM_ERROR?;
    }
}

/**
 * Get existing stream or create new one
 */
fn stream::Stream* get_or_create_stream(H2Session* session, uint stream_id)
{
    // Check if stream exists and return reference
    if (try stream_ref = session.streams.get_ref(stream_id))
    {
        return stream_ref;
    }

    // Create new stream
    // recv_window = our local window (how much we can receive)
    // send_window = remote's window (how much we can send to them)
    stream::Stream new_stream = stream::new_stream(stream_id, session.local_initial_window_size);
    new_stream.send_window = session.remote_initial_window_size;  // Use remote's window for sending
    session.streams.set(stream_id, new_stream);

    // Update tracking
    if (stream_id > session.highest_client_stream_id)
    {
        session.highest_client_stream_id = stream_id;
    }
    session.active_stream_count++;

    // Return reference to newly inserted stream
    return session.streams.get_ref(stream_id)!!;
}

/**
 * Close stream (but keep in map for state validation)
 * Streams are kept in map with CLOSED state so we can detect
 * protocol violations when frames arrive on closed streams.
 */
fn void close_stream(H2Session* session, uint stream_id)
{
    if (try s = session.streams.get_ref(stream_id))
    {
        if (s.state != stream::StreamState.CLOSED)
        {
            session.active_stream_count--;
            s.state = stream::StreamState.CLOSED;
        }
        // Don't remove - keep in map for validation of future frames
        // This allows us to detect STREAM_CLOSED errors per RFC 9113
    }
}

/**
 * Validate HTTP/2 headers (RFC 9113 §8.1.2)
 * Returns error code if validation fails, 0 if valid
 */
fn uint validate_http2_headers(hpack::HeaderField[] headers)
{
    bool seen_regular_header = false;
    bool has_method = false;
    bool has_scheme = false;
    bool has_path = false;

    foreach (i, header : headers)
    {
        String name = header.name;
        String value = header.value;

        // RFC 9113 §8.2: Header field names MUST be lowercase
        foreach (c : name)
        {
            if (c >= 'A' && c <= 'Z')
            {
                return ERR_PROTOCOL_ERROR;  // Uppercase in header name
            }
        }

        // Check if this is a pseudo-header
        if (name.len > 0 && name[0] == ':')
        {
            // Pseudo-headers MUST appear before regular headers (RFC 9113 §8.1.2.1)
            if (seen_regular_header)
            {
                return ERR_PROTOCOL_ERROR;
            }

            // Validate known pseudo-headers for requests
            if (name == ":method")
            {
                if (has_method)  return ERR_PROTOCOL_ERROR;  // Duplicate
                has_method = true;
            }
            else if (name == ":scheme")
            {
                if (has_scheme)  return ERR_PROTOCOL_ERROR;  // Duplicate
                has_scheme = true;
            }
            else if (name == ":path")
            {
                if (has_path)  return ERR_PROTOCOL_ERROR;  // Duplicate
                has_path = true;
                // :path MUST NOT be empty (RFC 9113 §8.1.2.3)
                if (value.len == 0)
                {
                    return ERR_PROTOCOL_ERROR;
                }
            }
            else if (name == ":authority")
            {
                // :authority is optional
            }
            else if (name == ":status")
            {
                // :status is for responses, not requests
                return ERR_PROTOCOL_ERROR;
            }
            else
            {
                // Unknown pseudo-header
                return ERR_PROTOCOL_ERROR;
            }
        }
        else
        {
            // Regular header
            seen_regular_header = true;

            // Check for connection-specific headers (RFC 9113 §8.1.2.2)
            if (name == "connection" || name == "keep-alive" ||
                name == "proxy-connection" || name == "transfer-encoding" ||
                name == "upgrade")
            {
                return ERR_PROTOCOL_ERROR;
            }

            // TE header only allowed with value "trailers"
            if (name == "te" && value != "trailers")
            {
                return ERR_PROTOCOL_ERROR;
            }
        }
    }

    // All requests MUST include :method, :scheme, and :path (RFC 9113 §8.1.2.3)
    if (!has_method || !has_scheme || !has_path)
    {
        return ERR_PROTOCOL_ERROR;
    }

    return 0;  // Valid
}

/**
 * Validate trailer headers (RFC 9113 §8.1.2.1)
 * Trailers MUST NOT contain pseudo-header fields
 * Returns error code if invalid, 0 if valid
 */
fn uint validate_trailer_headers(hpack::HeaderField[] headers)
{
    foreach (header : headers)
    {
        String name = header.name;

        // Pseudo-headers MUST NOT appear in trailers (RFC 9113 §8.1.2.1)
        if (name.len > 0 && name[0] == ':')
        {
            return ERR_PROTOCOL_ERROR;
        }
    }

    return 0;  // Valid
}

/**
 * Parse Content-Length header value
 * Returns the length value or fault on error
 */
fn usz? parse_content_length(String value)
{
    if (value.len == 0)
    {
        return stream::STREAM_ERROR?;
    }

    usz result = 0;
    foreach (c : value)
    {
        if (c < '0' || c > '9')
        {
            return stream::STREAM_ERROR?;  // Invalid character
        }
        result = result * 10 + (usz)(c - '0');
    }
    return result;
}

int global_session_id = 0;

fn int main()
{
    // Ignore SIGPIPE - prevents crash when writing to closed sockets
    // This is essential for network servers handling multiple connections
    (void)signal(libc::SIGPIPE, SIG_IGN_PTR);

    io::printn("Starting HTTP/2 Test Server for h2spec...");
    io::printfn("Listening on http://0.0.0.0:%d", SERVER_PORT);

    // Create event loop
    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        io::eprintfn("[ERROR] Failed to create event loop: %s", err);
        return 1;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    // Create TCP server
    tcp::TcpConnection*? server_opt = tcp::create(&loop);
    if (catch err = server_opt)
    {
        io::eprintfn("[ERROR] Failed to create server: %s", err);
        return 1;
    }
    tcp::TcpConnection* server = server_opt;
    defer server.close();

    // Bind and listen
    server.bind("0.0.0.0", SERVER_PORT)!!;
    server.listen(128, &on_connection)!!;

    io::printn("[READY] Server listening - waiting for h2spec connections");
    io::stdout().flush()!!;

    // Run event loop
    loop.run()!!;

    return 0;
}

fn void on_connection(tcp::TcpConnection* server, tcp::TcpConnection* client, void* user_data)
{
    H2Session* session = mem::new(H2Session);
    session.conn = client;
    session.init();
    session.session_id = ++global_session_id;

    io::printfn("[%d] New HTTP/2 connection", session.session_id);

    // Session starts with refcount = 0 which means "1 reference" in C3 convention
    // The read callback holds this initial reference and releases it on EOF/error
    // No extra retain needed here - refcount 0 = 1 ref
    client.start_read(&on_alloc, &on_read, session)!!;

    // Send our SETTINGS frame immediately (server preface)
    // (send_settings_frame does its own retain/release for the write callback)
    send_settings_frame(session);
}

fn char[] on_alloc(tcp::TcpConnection* conn, usz suggested_size, void* user_data)
{
    return mem::new_array(char, suggested_size);
}

fn void on_read(tcp::TcpConnection* conn, char[] data, void* user_data)
{
    H2Session* session = (H2Session*)user_data;

    if (data.len == 0)
    {
        io::printfn("[%d] Client disconnected (EOF)", session.session_id);
        session.release();
        return;
    }

    // Append to receive buffer
    session.recv_buffer.append(data);

    // Process based on state
    switch (session.state)
    {
        case AWAITING_PREFACE:
            process_preface(session);
        case AWAITING_SETTINGS:
        case OPEN:
            process_frames(session);
        case CLOSING:
        case CLOSED:
            // Ignore data in closing/closed states
            return;
    }
}

/**
 * Validate HTTP/2 connection preface
 */
fn void process_preface(H2Session* session)
{
    char[] buffer = (char[])session.recv_buffer.str_view();

    // Need at least 24 bytes for the preface
    if (buffer.len < CONNECTION_PREFACE.len)
    {
        return;  // Wait for more data
    }

    // Validate preface
    if (buffer[:CONNECTION_PREFACE.len] != CONNECTION_PREFACE[..])
    {
        io::eprintfn("[%d] Invalid connection preface", session.session_id);
        send_goaway(session, 0, ERR_PROTOCOL_ERROR);
        return;
    }

    io::printfn("[%d] Valid connection preface received", session.session_id);

    // Remove preface from buffer - copy remaining to temp first (can't append from self)
    if (buffer.len > CONNECTION_PREFACE.len)
    {
        usz remaining_len = buffer.len - CONNECTION_PREFACE.len;
        char* temp = allocator::alloc_array(&session.arena, char, remaining_len);
        mem::copy(temp, &buffer[CONNECTION_PREFACE.len], remaining_len);
        session.recv_buffer.clear();
        session.recv_buffer.append((String)temp[:remaining_len]);
    }
    else
    {
        session.recv_buffer.clear();
    }

    // Move to next state - awaiting client's SETTINGS frame
    session.state = ConnectionState.AWAITING_SETTINGS;

    // Continue processing (client SETTINGS should follow)
    process_frames(session);
}

/**
 * Process HTTP/2 frames from buffer
 */
fn void process_frames(H2Session* session)
{
    while (true)
    {
        // Early exit if connection is closed (e.g., write error occurred)
        if (session.state == ConnectionState.CLOSED)
        {
            return;
        }

        char[] buffer = (char[])session.recv_buffer.str_view();

        // Need at least 9 bytes for frame header
        if (buffer.len < 9)
        {
            return;  // Wait for more data
        }

        // Parse frame header (RFC 9113 §4.1)
        // Length: 24 bits, Type: 8 bits, Flags: 8 bits, Stream ID: 31 bits (R bit reserved)
        uint length = ((uint)buffer[0] << 16) | ((uint)buffer[1] << 8) | (uint)buffer[2];
        char frame_type = buffer[3];
        char flags = buffer[4];
        uint stream_id = ((uint)(buffer[5] & 0x7F) << 24) | ((uint)buffer[6] << 16) |
                        ((uint)buffer[7] << 8) | (uint)buffer[8];

        // Validate frame size
        if (length > session.local_max_frame_size)
        {
            io::eprintfn("[%d] Frame size %d exceeds max %d", session.session_id, length, session.local_max_frame_size);
            send_goaway(session, session.last_stream_id, ERR_FRAME_SIZE_ERROR);
            return;
        }

        // Check if we have the complete frame
        usz total_frame_len = 9 + (usz)length;
        if (buffer.len < total_frame_len)
        {
            return;  // Wait for more data
        }

        // Extract frame payload
        char[] payload = buffer[9..][:length];

        io::printfn("[%d] Frame: type=%d flags=0x%02x stream=%d len=%d",
                    session.session_id, frame_type, flags, stream_id, length);

        // Write frame info to debug file
        if (try f = io::file::open("/tmp/h2_debug.log", "a")) {
            io::fprintfn(&f, "[%d] Frame: type=%d flags=0x%02x stream=%d len=%d",
                      session.session_id, frame_type, flags, stream_id, length)!!;
            f.close()!!;
        }

        // Frame validation
        frame::FrameHeader header = (frame::FrameHeader){
            .length = length,
            .type = (stream::FrameType)frame_type,
            .flags = flags,
            .stream_id = stream_id
        };

        // Validate frame structure
        if (catch err = frame::validate_frame(&header, payload, &session.frame_settings))
        {
            io::eprintfn("[%d] Frame validation error: %s", session.session_id, @typeid(err).nameof);
            // Map fault type to correct HTTP/2 error code
            uint error_code = ERR_PROTOCOL_ERROR;
            if (err == frame::FRAME_SIZE_ERROR)
            {
                error_code = ERR_FRAME_SIZE_ERROR;
            }
            else if (err == frame::FLOW_CONTROL_ERROR)
            {
                error_code = ERR_FLOW_CONTROL_ERROR;
            }
            send_goaway(session, session.last_stream_id, error_code);
            return;
        }

        // CONTINUATION validation (RFC 9113 §6.10)
        // Must be checked BEFORE stream state validation since stream stays IDLE until END_HEADERS
        if (session.expecting_continuation)
        {
            if (frame_type != FRAME_CONTINUATION)
            {
                io::eprintfn("[%d] Expected CONTINUATION but got frame type %d",
                             session.session_id, frame_type);
                send_goaway(session, session.last_stream_id, ERR_PROTOCOL_ERROR);
                return;
            }

            if (stream_id != session.continuation_stream_id)
            {
                io::eprintfn("[%d] CONTINUATION stream ID mismatch: expected %d, got %d",
                             session.session_id, session.continuation_stream_id, stream_id);
                send_goaway(session, session.last_stream_id, ERR_PROTOCOL_ERROR);
                return;
            }
        }
        else
        {
            // Not expecting CONTINUATION, so CONTINUATION frame is a protocol error
            if (frame_type == FRAME_CONTINUATION)
            {
                io::eprintfn("[%d] Unexpected CONTINUATION frame", session.session_id);
                send_goaway(session, session.last_stream_id, ERR_PROTOCOL_ERROR);
                return;
            }
        }

        // Stream-specific validation for stream-level frames
        // Note: PRIORITY frames do NOT create streams and don't need stream state validation
        // Note: CONTINUATION frames skip this - stream stays IDLE until END_HEADERS
        if (stream_id > 0 && frame_type != FRAME_PRIORITY && frame_type != FRAME_CONTINUATION)
        {
            // Validate stream creation (ID ordering, concurrency)
            if (catch err = validate_stream_creation(session, stream_id, frame_type))
            {
                // Error already sent in validate_stream_creation
                return;
            }

            // Get or create stream
            stream::Stream* stream_state = get_or_create_stream(session, stream_id);

            // Validate frame is allowed in current stream state
            if (catch err = stream::validate_frame_for_state(stream_state, (stream::FrameType)frame_type))
            {
                if (err == stream::CONNECTION_ERROR)
                {
                    // IDLE state violations -> CONNECTION_ERROR
                    uint error_code = (uint)stream::get_error_code_for_violation(stream_state, (stream::FrameType)frame_type);
                    io::eprintfn("[%d] Stream %d: CONNECTION_ERROR for frame type %d in state %s",
                                 session.session_id, stream_id, frame_type, stream::get_state_name(stream_state.state));
                    send_goaway(session, session.last_stream_id, error_code);
                    return;
                }
                else
                {
                    // STREAM_ERROR -> send RST_STREAM, skip processing, remove frame
                    uint error_code = (uint)stream::get_error_code_for_violation(stream_state, (stream::FrameType)frame_type);
                    io::eprintfn("[%d] Stream %d: STREAM_ERROR for frame type %d in state %s",
                                 session.session_id, stream_id, frame_type, stream::get_state_name(stream_state.state));
                    send_rst_stream(session, stream_id, error_code);

                    // Skip processing this frame, just remove it from buffer
                    if (buffer.len > total_frame_len)
                    {
                        // Copy remaining data to temp buffer first (can't append from self - overlapping memory)
                        usz remaining_len = buffer.len - total_frame_len;
                        char* temp = allocator::alloc_array(&session.arena, char, remaining_len);
                        mem::copy(temp, &buffer[total_frame_len], remaining_len);
                        session.recv_buffer.clear();
                        session.recv_buffer.append((String)temp[:remaining_len]);
                    }
                    else
                    {
                        session.recv_buffer.clear();
                    }
                    continue;  // Continue to next frame
                }
            }
        }

        // Handle frame by type
        switch (frame_type)
        {
            case FRAME_SETTINGS:
                handle_settings(session, flags, stream_id, payload);
            case FRAME_PING:
                handle_ping(session, flags, stream_id, payload);
            case FRAME_GOAWAY:
                handle_goaway(session, payload);
            case FRAME_WINDOW_UPDATE:
                handle_window_update(session, stream_id, payload);
            case FRAME_HEADERS:
                handle_headers(session, flags, stream_id, payload);
            case FRAME_DATA:
                handle_data(session, flags, stream_id, payload);
            case FRAME_RST_STREAM:
                handle_rst_stream(session, stream_id, payload);
            case FRAME_PRIORITY:
                // PRIORITY frames are parsed but ignored (RFC 9113 deprecates them)
                io::printfn("[%d] PRIORITY frame (ignored)", session.session_id);
            case FRAME_CONTINUATION:
                handle_continuation(session, flags, stream_id, payload);
            default:
                // Unknown frame types are ignored (RFC 9113 §4.1)
                io::printfn("[%d] Unknown frame type %d (ignored)", session.session_id, frame_type);
        }

        // Remove processed frame from buffer
        if (buffer.len > total_frame_len)
        {
            // Copy remaining data to temp buffer first (can't append from self - overlapping memory)
            usz remaining_len = buffer.len - total_frame_len;
            char* temp = allocator::alloc_array(&session.arena, char, remaining_len);
            mem::copy(temp, &buffer[total_frame_len], remaining_len);
            session.recv_buffer.clear();
            session.recv_buffer.append((String)temp[:remaining_len]);
            // Note: temp is allocated from arena, freed when session ends
        }
        else
        {
            session.recv_buffer.clear();
        }

        // Check if connection is fully closed
        // Note: CLOSING state still allows processing frames (for graceful shutdown)
        if (session.state == ConnectionState.CLOSED)
        {
            return;
        }
    }
}

/**
 * Handle SETTINGS frame (RFC 9113 §6.5)
 */
fn void handle_settings(H2Session* session, char flags, uint stream_id, char[] payload)
{
    // SETTINGS must be on stream 0
    if (stream_id != 0)
    {
        io::eprintfn("[%d] SETTINGS on non-zero stream", session.session_id);
        send_goaway(session, session.last_stream_id, ERR_PROTOCOL_ERROR);
        return;
    }

    // Check for ACK flag
    if (flags & FLAG_ACK)
    {
        // SETTINGS ACK must have empty payload
        if (payload.len != 0)
        {
            io::eprintfn("[%d] SETTINGS ACK with non-empty payload", session.session_id);
            send_goaway(session, session.last_stream_id, ERR_FRAME_SIZE_ERROR);
            return;
        }
        io::printfn("[%d] Received SETTINGS ACK", session.session_id);
        session.settings_ack_received = true;
        return;
    }

    // SETTINGS payload must be multiple of 6 bytes
    if (payload.len % 6 != 0)
    {
        io::eprintfn("[%d] SETTINGS payload not multiple of 6", session.session_id);
        send_goaway(session, session.last_stream_id, ERR_FRAME_SIZE_ERROR);
        return;
    }

    // Parse settings
    for (usz i = 0; i < payload.len; i += 6)
    {
        ushort id = ((ushort)payload[i] << 8) | (ushort)payload[i + 1];
        uint value = ((uint)payload[i + 2] << 24) | ((uint)payload[i + 3] << 16) |
                     ((uint)payload[i + 4] << 8) | (uint)payload[i + 5];

        io::printfn("[%d] Setting: id=%d value=%d", session.session_id, id, value);

        switch (id)
        {
            case SETTINGS_HEADER_TABLE_SIZE:
                // TODO: Update HPACK encoder table size
                break;
            case SETTINGS_ENABLE_PUSH:
                if (value > 1)
                {
                    send_goaway(session, session.last_stream_id, ERR_PROTOCOL_ERROR);
                    return;
                }
                break;
            case SETTINGS_MAX_CONCURRENT_STREAMS:
                // Store for stream management
                break;
            case SETTINGS_INITIAL_WINDOW_SIZE:
                if (value > 2147483647)  // 2^31 - 1
                {
                    send_goaway(session, session.last_stream_id, ERR_FLOW_CONTROL_ERROR);
                    return;
                }
                // RFC 9113 §6.5.2: Adjust all existing stream windows by the delta
                int delta = (int)value - (int)session.remote_initial_window_size;
                if (delta != 0 && session.streams.count > 0)
                {
                    // Iterate over all streams and adjust send windows
                    foreach (entry : session.streams.table)
                    {
                        while (entry)
                        {
                            stream::Stream* s = &entry.value;
                            // Calculate new window, checking for overflow
                            long new_window = (long)s.send_window + (long)delta;
                            if (new_window > 2147483647)
                            {
                                // Flow control error - window exceeds max
                                send_goaway(session, session.last_stream_id, ERR_FLOW_CONTROL_ERROR);
                                return;
                            }
                            s.send_window = (uint)new_window;
                            io::printfn("[%d] Stream %d window adjusted by %d to %d",
                                        session.session_id, s.id, delta, s.send_window);
                            entry = entry.next;
                        }
                    }
                }
                session.remote_initial_window_size = value;
                io::printfn("[%d] Initial window size now: %d", session.session_id, value);
                break;
            case SETTINGS_MAX_FRAME_SIZE:
                if (value < DEFAULT_MAX_FRAME_SIZE || value > MAX_FRAME_SIZE_LIMIT)
                {
                    send_goaway(session, session.last_stream_id, ERR_PROTOCOL_ERROR);
                    return;
                }
                session.remote_max_frame_size = value;
                break;
            case SETTINGS_MAX_HEADER_LIST_SIZE:
                // Advisory, store for header validation
                break;
            default:
                // Unknown settings are ignored (RFC 9113 §6.5.2)
                break;
        }
    }

    // Update state if we were waiting for SETTINGS
    if (session.state == ConnectionState.AWAITING_SETTINGS)
    {
        session.state = ConnectionState.OPEN;
        io::printfn("[%d] Connection established (OPEN)", session.session_id);
    }

    // Send SETTINGS ACK
    send_settings_ack(session);
}

/**
 * Handle PING frame (RFC 9113 §6.7)
 */
fn void handle_ping(H2Session* session, char flags, uint stream_id, char[] payload)
{
    // PING must be on stream 0
    if (stream_id != 0)
    {
        io::eprintfn("[%d] PING on non-zero stream", session.session_id);
        send_goaway(session, session.last_stream_id, ERR_PROTOCOL_ERROR);
        return;
    }

    // PING payload must be 8 bytes
    if (payload.len != 8)
    {
        io::eprintfn("[%d] PING with invalid payload length %d", session.session_id, payload.len);
        send_goaway(session, session.last_stream_id, ERR_FRAME_SIZE_ERROR);
        return;
    }

    // If ACK flag set, this is a response to our PING
    if (flags & FLAG_ACK)
    {
        io::printfn("[%d] Received PING ACK", session.session_id);
        return;
    }

    // Send PING ACK with same opaque data
    io::printfn("[%d] Sending PING ACK", session.session_id);
    send_ping_ack(session, payload);
}

/**
 * Handle GOAWAY frame (RFC 9113 §6.8)
 */
fn void handle_goaway(H2Session* session, char[] payload)
{
    if (payload.len < 8)
    {
        return;
    }

    uint last_stream = ((uint)(payload[0] & 0x7F) << 24) | ((uint)payload[1] << 16) |
                       ((uint)payload[2] << 8) | (uint)payload[3];
    uint error_code = ((uint)payload[4] << 24) | ((uint)payload[5] << 16) |
                      ((uint)payload[6] << 8) | (uint)payload[7];

    io::printfn("[%d] Received GOAWAY: last_stream=%d error=%d", session.session_id, last_stream, error_code);

    // RFC 9113 §6.8: Unknown error codes are treated as INTERNAL_ERROR
    // but we should continue processing frames until connection closes
    // Don't immediately release - allow remaining frames to be processed
    session.state = ConnectionState.CLOSING;
    // Note: Session will be released when peer closes connection
}

/**
 * Send pending DATA when flow control window opens
 */
fn void send_pending_data(H2Session* session, uint stream_id, stream::Stream* stream_state)
{
    // Fixed response body: "OK\n"
    char[3] body = { 'O', 'K', '\n' };
    uint body_len = 3;

    // Calculate how much we can send
    uint bytes_to_send = body_len;
    if (stream_state.send_window < bytes_to_send) { bytes_to_send = stream_state.send_window; }
    if (session.connection_window > 0 && (uint)session.connection_window < bytes_to_send) {
        bytes_to_send = (uint)session.connection_window;
    }
    if (session.connection_window <= 0) { bytes_to_send = 0; }

    if (bytes_to_send == 0) return;  // Still blocked

    io::printfn("[%d] Sending pending DATA: stream=%d, bytes=%d", session.session_id, stream_id, bytes_to_send);

    // Build DATA frame - arena allocated (freed when session ends)
    char[] frame = allocator::alloc_array(&session.arena, char, 12);  // 9 header + 3 body max
    frame[0] = 0;
    frame[1] = 0;
    frame[2] = (char)bytes_to_send;  // Length
    frame[3] = FRAME_DATA;
    frame[4] = (bytes_to_send == body_len) ? FLAG_END_STREAM : 0;  // END_STREAM if complete
    frame[5] = (char)((stream_id >> 24) & 0x7F);
    frame[6] = (char)((stream_id >> 16) & 0xFF);
    frame[7] = (char)((stream_id >> 8) & 0xFF);
    frame[8] = (char)(stream_id & 0xFF);

    for (uint i = 0; i < bytes_to_send; i++)
    {
        frame[9 + i] = body[i];
    }

    // Update flow control windows
    stream_state.send_window -= bytes_to_send;
    session.connection_window -= (int)bytes_to_send;

    // Update stream state
    if (bytes_to_send == body_len)
    {
        stream_state.pending_response = false;
        (void)stream::send_end_stream(stream_state);
        io::printfn("[%d] Stream %d completed with pending DATA", session.session_id, stream_id);
    }

    usz total_len = (usz)(9 + bytes_to_send);
    session.retain();
    session.conn.write(frame[0:total_len], &on_write_complete, session)!!;
}

/**
 * Handle WINDOW_UPDATE frame (RFC 9113 §6.9)
 */
fn void handle_window_update(H2Session* session, uint stream_id, char[] payload)
{
    if (payload.len != 4)
    {
        send_goaway(session, session.last_stream_id, ERR_FRAME_SIZE_ERROR);
        return;
    }

    uint increment = ((uint)(payload[0] & 0x7F) << 24) | ((uint)payload[1] << 16) |
                     ((uint)payload[2] << 8) | (uint)payload[3];

    if (increment == 0)
    {
        if (stream_id == 0)
        {
            send_goaway(session, session.last_stream_id, ERR_PROTOCOL_ERROR);
        }
        else
        {
            send_rst_stream(session, stream_id, ERR_PROTOCOL_ERROR);
        }
        return;
    }

    io::printfn("[%d] WINDOW_UPDATE: stream=%d increment=%d", session.session_id, stream_id, increment);

    // Update flow control window
    if (stream_id == 0)
    {
        // Connection-level WINDOW_UPDATE
        // Check for flow control window overflow (RFC 9113 §6.9.1)
        // Window cannot exceed 2^31-1 (0x7FFFFFFF)
        long new_window = (long)session.connection_window + (long)increment;
        if (new_window > 0x7FFFFFFF)
        {
            io::eprintfn("[%d] Connection flow control window overflow: %d + %d > 2^31-1",
                         session.session_id, session.connection_window, increment);
            send_goaway(session, session.last_stream_id, ERR_FLOW_CONTROL_ERROR);
            return;
        }
        session.connection_window = (int)new_window;
    }
    else
    {
        // Stream-level WINDOW_UPDATE
        stream::Stream* stream_state = get_or_create_stream(session, stream_id);

        // Transition stream state machine (includes overflow check)
        if (catch err = stream::on_window_update_received(stream_state, increment))
        {
            io::eprintfn("[%d] Stream %d: Error processing WINDOW_UPDATE: %s",
                         session.session_id, stream_id, @typeid(err).nameof);
            // Send RST_STREAM for flow control error
            send_rst_stream(session, stream_id, ERR_FLOW_CONTROL_ERROR);
            return;
        }

        io::printfn("[%d] Stream %d send_window: %d", session.session_id, stream_id,
                    stream_state.send_window);

        // Check if this stream has pending response data
        if (stream_state.pending_response && stream_state.send_window > 0)
        {
            send_pending_data(session, stream_id, stream_state);
        }
    }
}

/**
 * Handle HEADERS frame (RFC 9113 §6.2)
 */
fn void handle_headers(H2Session* session, char flags, uint stream_id, char[] payload)
{
    // Write to debug file
    if (try f = io::file::open("/tmp/h2_debug.log", "a")) {
        io::fprintfn(&f, "[%d] HEADERS on stream %d (len=%d, flags=0x%02x)",
                  session.session_id, stream_id, payload.len, flags)!!;
        f.close()!!;
    }

    if (stream_id == 0)
    {
        send_goaway(session, session.last_stream_id, ERR_PROTOCOL_ERROR);
        return;
    }

    io::printfn("[%d] HEADERS on stream %d (len=%d, flags=0x%02x)", session.session_id, stream_id, payload.len, flags);

    // Track stream ID
    if (stream_id > session.last_stream_id)
    {
        session.last_stream_id = stream_id;
    }

    bool end_headers = (flags & FLAG_END_HEADERS) != 0;
    bool end_stream = (flags & FLAG_END_STREAM) != 0;
    bool padded = (flags & FLAG_PADDED) != 0;
    bool priority = (flags & FLAG_PRIORITY) != 0;

    // Extract header block fragment from payload (RFC 9113 §6.2)
    // Frame format: [Pad Length (1)] [E|Stream Dep (4)] [Weight (1)] [Header Block] [Padding]
    usz offset = 0;
    usz pad_length = 0;

    if (padded)
    {
        if (payload.len < 1)
        {
            send_goaway(session, session.last_stream_id, ERR_FRAME_SIZE_ERROR);
            return;
        }
        pad_length = (usz)payload[0];
        offset = 1;
    }

    if (priority)
    {
        // E (1 bit) + Stream Dependency (31 bits) + Weight (8 bits) = 5 bytes
        if (payload.len < offset + 5)
        {
            send_goaway(session, session.last_stream_id, ERR_FRAME_SIZE_ERROR);
            return;
        }

        // Extract stream dependency (RFC 9113 §5.3.1: stream cannot depend on itself)
        uint stream_dependency = ((uint)(payload[offset] & 0x7F) << 24) |
                                 ((uint)payload[offset + 1] << 16) |
                                 ((uint)payload[offset + 2] << 8) |
                                 (uint)payload[offset + 3];
        if (stream_dependency == stream_id)
        {
            io::eprintfn("[%d] Stream %d depends on itself", session.session_id, stream_id);
            send_rst_stream(session, stream_id, ERR_PROTOCOL_ERROR);
            return;
        }

        offset += 5;
    }

    // Validate padding doesn't exceed remaining payload
    if (pad_length > payload.len - offset)
    {
        send_goaway(session, session.last_stream_id, ERR_PROTOCOL_ERROR);
        return;
    }

    // Extract header block fragment (excluding padding)
    usz fragment_len = payload.len - offset - pad_length;
    char[] header_block_fragment = payload[offset..][:fragment_len];
    io::printfn("[%d] Header block fragment: %d bytes (pad=%d, priority=%s)",
                session.session_id, header_block_fragment.len, pad_length, priority ? "yes" : "no");

    if (!end_headers)
    {
        // HEADERS without END_HEADERS - expect CONTINUATION frames
        io::printfn("[%d] HEADERS without END_HEADERS, expecting CONTINUATION", session.session_id);
        session.expecting_continuation = true;
        session.continuation_stream_id = stream_id;
        session.continuation_end_stream = end_stream;  // Save END_STREAM for when CONTINUATION completes

        // Start accumulating header block fragments
        session.header_block_buffer.clear();
        session.header_block_buffer.append((String)header_block_fragment);

        // Note: Don't transition stream state yet - wait for END_HEADERS
        return;
    }

    // END_HEADERS set - process complete header block
    // Get stream state
    stream::Stream* stream_state = get_or_create_stream(session, stream_id);

    // Check if this is a trailer (stream already OPEN means we received initial headers)
    // Trailers are HEADERS frames sent after the request body
    bool is_trailer = (stream_state.state == stream::StreamState.OPEN);

    // RFC 9113 §8.1: Trailers MUST have END_STREAM set
    if (is_trailer && !end_stream)
    {
        io::eprintfn("[%d] Stream %d: Trailer HEADERS must have END_STREAM", session.session_id, stream_id);
        send_rst_stream(session, stream_id, ERR_PROTOCOL_ERROR);
        return;
    }

    // Transition stream state machine
    if (catch err = stream::on_headers_received(stream_state, end_stream))
    {
        io::eprintfn("[%d] Stream %d: Error processing HEADERS: %s",
                     session.session_id, stream_id, @typeid(err).nameof);
        return;
    }

    io::printfn("[%d] Stream %d state: %s%s", session.session_id, stream_id,
                stream::get_state_name(stream_state.state), is_trailer ? " (trailer)" : "");

    // HPACK decode headers
    hpack::HeaderField[]? decoded_headers = hpack::decode_header_block(header_block_fragment);
    if (catch err = decoded_headers)
    {
        io::eprintfn("[%d] Stream %d: HPACK decoding failed: %s",
                     session.session_id, stream_id, @typeid(err).nameof);
        send_goaway(session, session.last_stream_id, ERR_COMPRESSION_ERROR);
        return;
    }

    hpack::HeaderField[] headers = decoded_headers;

    // Validate HTTP/2 headers (RFC 9113 §8.1.2)
    if (is_trailer)
    {
        // Validate trailer headers - pseudo-headers NOT allowed
        uint validation_error = validate_trailer_headers(headers);
        if (validation_error != 0)
        {
            io::eprintfn("[%d] Stream %d: Trailer validation failed (pseudo-header in trailer)",
                         session.session_id, stream_id);
            send_rst_stream(session, stream_id, validation_error);
            return;
        }
    }
    else
    {
        // Validate request headers - pseudo-headers required
        uint validation_error = validate_http2_headers(headers);
        if (validation_error != 0)
        {
            io::eprintfn("[%d] Stream %d: Header validation failed", session.session_id, stream_id);
            send_rst_stream(session, stream_id, validation_error);
            return;
        }
    }

    // Extract Content-Length if present (RFC 9113 §8.1.2.6)
    foreach (header : headers)
    {
        if (header.name == "content-length")
        {
            if (try content_len = parse_content_length(header.value))
            {
                stream_state.expected_bytes = content_len;
                stream_state.has_content_length = true;
            }
            else
            {
                // Invalid Content-Length value
                send_rst_stream(session, stream_id, ERR_PROTOCOL_ERROR);
                return;
            }
            break;
        }
    }

    io::printfn("[%d] Stream %d: Decoded %d headers", session.session_id, stream_id, headers.len);

    // Respond immediately if END_STREAM was set (request complete, no body)
    // OR if stream is OPEN (for h2spec half-closed tests that need response before END_STREAM)
    // The h2spec half-closed tests expect us to respond even without END_STREAM
    if (end_stream || !is_trailer)
    {
        send_simple_response(session, stream_id);
    }
}

/**
 * Handle CONTINUATION frame (RFC 9113 §6.10)
 */
fn void handle_continuation(H2Session* session, char flags, uint stream_id, char[] payload)
{
    // Write to debug file
    if (try f = io::file::open("/tmp/h2_debug.log", "a")) {
        io::fprintfn(&f, "[%d] CONTINUATION on stream %d (len=%d, flags=0x%02x, buffer_before=%d)",
                  session.session_id, stream_id, payload.len, flags, session.header_block_buffer.len())!!;
        f.close()!!;
    }
    io::printfn("[%d] CONTINUATION on stream %d (len=%d, buffer_before=%d)",
                session.session_id, stream_id, payload.len, session.header_block_buffer.len());

    // Append fragment to accumulated header block
    session.header_block_buffer.append((String)payload);
    io::printfn("[%d] CONTINUATION buffer_after=%d", session.session_id, session.header_block_buffer.len());

    bool end_headers = (flags & FLAG_END_HEADERS) != 0;

    if (end_headers)
    {
        // Complete header block received
        io::printfn("[%d] CONTINUATION with END_HEADERS, complete header block size: %d",
                    session.session_id, session.header_block_buffer.len());

        // Get stream state
        stream::Stream* stream_state = get_or_create_stream(session, stream_id);

        // Transition stream state machine using END_STREAM from original HEADERS
        bool end_stream = session.continuation_end_stream;
        if (catch err = stream::on_headers_received(stream_state, end_stream))
        {
            io::eprintfn("[%d] Stream %d: Error processing CONTINUATION: %s",
                         session.session_id, stream_id, @typeid(err).nameof);
            session.expecting_continuation = false;
            session.header_block_buffer.clear();
            return;
        }

        io::printfn("[%d] Stream %d state: %s", session.session_id, stream_id,
                    stream::get_state_name(stream_state.state));

        // HPACK decode complete header block
        char[] header_block = (char[])session.header_block_buffer.str_view();
        io::printfn("[%d] Stream %d: Decoding header block of %d bytes",
                     session.session_id, stream_id, header_block.len);
        // Hex dump first 32 bytes
        io::printf("[%d] First bytes: ", session.session_id);
        for (usz i = 0; i < header_block.len && i < 32; i++) {
            io::printf("%02x ", (uint)(char)header_block[i]);
        }
        io::printfn("");
        io::stdout().flush()!!;
        hpack::HeaderField[]? decoded_headers = hpack::decode_header_block(header_block);
        if (catch err = decoded_headers)
        {
            io::printfn("[%d] Stream %d: HPACK decoding failed: %s (block size=%d)",
                         session.session_id, stream_id, @typeid(err).nameof, header_block.len);
            io::stdout().flush()!!;
            send_goaway(session, session.last_stream_id, ERR_COMPRESSION_ERROR);
            session.expecting_continuation = false;
            session.header_block_buffer.clear();
            return;
        }

        hpack::HeaderField[] headers = decoded_headers;

        // Validate HTTP/2 headers (RFC 9113 §8.1.2)
        uint validation_error = validate_http2_headers(headers);
        if (validation_error != 0)
        {
            io::eprintfn("[%d] Stream %d: Header validation failed", session.session_id, stream_id);
            send_rst_stream(session, stream_id, validation_error);
            session.expecting_continuation = false;
            session.header_block_buffer.clear();
            return;
        }

        io::printfn("[%d] Stream %d: Decoded %d headers from CONTINUATION", session.session_id, stream_id, headers.len);

        // Clear CONTINUATION state
        session.expecting_continuation = false;

        // For h2spec tests: Always respond immediately when headers are complete
        send_simple_response(session, stream_id);

        // Clear buffer for next header block
        session.header_block_buffer.clear();
    }
    else
    {
        // More CONTINUATION frames expected
        io::printfn("[%d] CONTINUATION without END_HEADERS, waiting for more", session.session_id);
    }
}

/**
 * Handle DATA frame (RFC 9113 §6.1)
 */
fn void handle_data(H2Session* session, char flags, uint stream_id, char[] payload)
{
    if (stream_id == 0)
    {
        send_goaway(session, session.last_stream_id, ERR_PROTOCOL_ERROR);
        return;
    }

    io::printfn("[%d] DATA on stream %d (len=%d)", session.session_id, stream_id, payload.len);

    // Handle padding if present (RFC 9113 §6.1)
    bool padded = (flags & FLAG_PADDED) != 0;
    char[] data = payload;  // Default: no padding, use full payload

    if (padded)
    {
        if (payload.len < 1)
        {
            send_goaway(session, session.last_stream_id, ERR_FRAME_SIZE_ERROR);
            return;
        }
        usz pad_length = (usz)payload[0];

        // Validate padding doesn't exceed remaining payload
        if (pad_length >= payload.len)
        {
            send_goaway(session, session.last_stream_id, ERR_PROTOCOL_ERROR);
            return;
        }
        usz data_length = payload.len - 1 - pad_length;
        io::printfn("[%d] DATA padding: %d bytes, data: %d bytes", session.session_id, pad_length, data_length);

        // Extract data without pad_length byte and padding
        data = payload[1:data_length];
    }

    // Get stream state
    stream::Stream* stream_state = get_or_create_stream(session, stream_id);

    bool end_stream = (flags & FLAG_END_STREAM) != 0;

    // Transition stream state machine (includes Content-Length validation)
    if (catch err = stream::on_data_received(stream_state, (uint)data.len, end_stream))
    {
        io::eprintfn("[%d] Stream %d: Error processing DATA: %s",
                     session.session_id, stream_id, @typeid(err).nameof);
        // Send RST_STREAM for Content-Length mismatch or state errors
        send_rst_stream(session, stream_id, ERR_PROTOCOL_ERROR);
        return;
    }

    io::printfn("[%d] Stream %d state: %s", session.session_id, stream_id,
                stream::get_state_name(stream_state.state));

    // Update flow control windows
    if (payload.len > 0)
    {
        io::printfn("[%d] Sending conn WINDOW_UPDATE for %d bytes", session.session_id, payload.len);
        // Always send connection-level WINDOW_UPDATE
        send_window_update(session, 0, (uint)payload.len);
        io::printfn("[%d] Sent conn WINDOW_UPDATE", session.session_id);
        // Only send stream-level WINDOW_UPDATE if stream is still open for receiving
        // Skip if HALF_CLOSED_REMOTE/CLOSED - no more data expected from client
        if (stream_state.state != stream::StreamState.CLOSED &&
            stream_state.state != stream::StreamState.HALF_CLOSED_REMOTE)
        {
            io::printfn("[%d] Sending stream WINDOW_UPDATE for stream %d", session.session_id, stream_id);
            send_window_update(session, stream_id, (uint)payload.len);
            io::printfn("[%d] Sent stream WINDOW_UPDATE", session.session_id);
        }
    }

    io::printfn("[%d] handle_data complete", session.session_id);
    // Response was already sent when headers were received (for h2spec testing)
    // A real server would respond here after processing the request body
}

/**
 * Handle RST_STREAM frame (RFC 9113 §6.4)
 */
fn void handle_rst_stream(H2Session* session, uint stream_id, char[] payload)
{
    if (stream_id == 0)
    {
        send_goaway(session, session.last_stream_id, ERR_PROTOCOL_ERROR);
        return;
    }

    if (payload.len != 4)
    {
        send_goaway(session, session.last_stream_id, ERR_FRAME_SIZE_ERROR);
        return;
    }

    uint error_code = ((uint)payload[0] << 24) | ((uint)payload[1] << 16) |
                      ((uint)payload[2] << 8) | (uint)payload[3];

    io::printfn("[%d] RST_STREAM: stream=%d error=%d", session.session_id, stream_id, error_code);

    // Get stream state
    stream::Stream* stream_state = get_or_create_stream(session, stream_id);

    // Transition stream to CLOSED state
    stream::on_rst_stream_received(stream_state, (stream::ErrorCode)error_code);

    io::printfn("[%d] Stream %d state: %s", session.session_id, stream_id,
                stream::get_state_name(stream_state.state));

    // Clean up stream
    close_stream(session, stream_id);
}

// ============================================================================
// Frame Sending Functions
// ============================================================================

/**
 * Send our SETTINGS frame (server preface)
 */
fn void send_settings_frame(H2Session* session)
{
    // Settings payload: SETTINGS_MAX_CONCURRENT_STREAMS = 100
    // Arena allocated (freed when session ends)
    char[] frame = allocator::alloc_array(&session.arena, char, 15);

    // Frame header
    frame[0] = 0;  // Length high byte
    frame[1] = 0;  // Length mid byte
    frame[2] = 6;  // Length low byte (1 setting = 6 bytes)
    frame[3] = FRAME_SETTINGS;
    frame[4] = 0;  // No flags
    frame[5] = 0;  // Stream ID = 0
    frame[6] = 0;
    frame[7] = 0;
    frame[8] = 0;

    // SETTINGS_MAX_CONCURRENT_STREAMS = 100
    frame[9] = 0;
    frame[10] = SETTINGS_MAX_CONCURRENT_STREAMS;
    frame[11] = 0;
    frame[12] = 0;
    frame[13] = 0;
    frame[14] = 100;

    session.retain();
    session.conn.write(frame[..], &on_write_complete, session)!!;
    io::printfn("[%d] Sent SETTINGS frame", session.session_id);
}

/**
 * Send SETTINGS ACK
 */
fn void send_settings_ack(H2Session* session)
{
    // Arena allocated (freed when session ends)
    char[] frame = allocator::alloc_array(&session.arena, char, 9);

    // Frame header (length = 0)
    frame[0] = 0;
    frame[1] = 0;
    frame[2] = 0;
    frame[3] = FRAME_SETTINGS;
    frame[4] = FLAG_ACK;
    frame[5] = 0;  // Stream ID = 0
    frame[6] = 0;
    frame[7] = 0;
    frame[8] = 0;

    session.retain();
    session.conn.write(frame[..], &on_write_complete, session)!!;
    session.settings_ack_sent = true;
    io::printfn("[%d] Sent SETTINGS ACK", session.session_id);
}

/**
 * Send PING ACK
 */
fn void send_ping_ack(H2Session* session, char[] opaque_data)
{
    // Arena allocated (freed when session ends)
    char[] frame = allocator::alloc_array(&session.arena, char, 17);

    // Frame header
    frame[0] = 0;
    frame[1] = 0;
    frame[2] = 8;  // Length = 8
    frame[3] = FRAME_PING;
    frame[4] = FLAG_ACK;
    frame[5] = 0;  // Stream ID = 0
    frame[6] = 0;
    frame[7] = 0;
    frame[8] = 0;

    // Copy opaque data
    for (int i = 0; i < 8; i++)
    {
        frame[9 + i] = opaque_data[i];
    }

    session.retain();
    session.conn.write(frame[..], &on_write_complete, session)!!;
}

/**
 * Send GOAWAY frame
 */
fn void send_goaway(H2Session* session, uint last_stream_id, uint error_code)
{
    // Write to debug file
    if (try f = io::file::open("/tmp/h2_debug.log", "a")) {
        io::fprintfn(&f, "[%d] SENDING GOAWAY: last_stream=%d error=%d", session.session_id, last_stream_id, error_code)!!;
        f.close()!!;
    }

    // Prevent double GOAWAY - once we're closing, ignore further errors
    if (session.state == ConnectionState.CLOSING || session.state == ConnectionState.CLOSED) {
        return;
    }

    // Arena allocated (freed when session ends)
    char[] frame = allocator::alloc_array(&session.arena, char, 17);

    // Frame header
    frame[0] = 0;
    frame[1] = 0;
    frame[2] = 8;  // Length = 8
    frame[3] = FRAME_GOAWAY;
    frame[4] = 0;  // No flags
    frame[5] = 0;  // Stream ID = 0
    frame[6] = 0;
    frame[7] = 0;
    frame[8] = 0;

    // Last-Stream-ID (31 bits)
    frame[9] = (char)((last_stream_id >> 24) & 0x7F);
    frame[10] = (char)((last_stream_id >> 16) & 0xFF);
    frame[11] = (char)((last_stream_id >> 8) & 0xFF);
    frame[12] = (char)(last_stream_id & 0xFF);

    // Error code
    frame[13] = (char)((error_code >> 24) & 0xFF);
    frame[14] = (char)((error_code >> 16) & 0xFF);
    frame[15] = (char)((error_code >> 8) & 0xFF);
    frame[16] = (char)(error_code & 0xFF);

    session.state = ConnectionState.CLOSING;
    session.retain();
    session.conn.write(frame[..], &on_goaway_write_complete, session)!!;
    io::printfn("[%d] Sent GOAWAY: last_stream=%d error=%d", session.session_id, last_stream_id, error_code);
}

/**
 * Send RST_STREAM frame
 */
fn void send_rst_stream(H2Session* session, uint stream_id, uint error_code)
{
    // Arena allocated (freed when session ends)
    char[] frame = allocator::alloc_array(&session.arena, char, 13);

    // Frame header
    frame[0] = 0;
    frame[1] = 0;
    frame[2] = 4;  // Length = 4
    frame[3] = FRAME_RST_STREAM;
    frame[4] = 0;  // No flags
    // Stream ID
    frame[5] = (char)((stream_id >> 24) & 0x7F);
    frame[6] = (char)((stream_id >> 16) & 0xFF);
    frame[7] = (char)((stream_id >> 8) & 0xFF);
    frame[8] = (char)(stream_id & 0xFF);

    // Error code
    frame[9] = (char)((error_code >> 24) & 0xFF);
    frame[10] = (char)((error_code >> 16) & 0xFF);
    frame[11] = (char)((error_code >> 8) & 0xFF);
    frame[12] = (char)(error_code & 0xFF);

    session.retain();
    session.conn.write(frame[..], &on_write_complete, session)!!;
    io::printfn("[%d] Sent RST_STREAM: stream=%d error=%d", session.session_id, stream_id, error_code);
}

/**
 * Send WINDOW_UPDATE frame
 */
fn void send_window_update(H2Session* session, uint stream_id, uint increment)
{
    // Arena allocated (freed when session ends)
    char[] frame = allocator::alloc_array(&session.arena, char, 13);

    // Frame header
    frame[0] = 0;
    frame[1] = 0;
    frame[2] = 4;  // Length = 4
    frame[3] = FRAME_WINDOW_UPDATE;
    frame[4] = 0;  // No flags
    // Stream ID
    frame[5] = (char)((stream_id >> 24) & 0x7F);
    frame[6] = (char)((stream_id >> 16) & 0xFF);
    frame[7] = (char)((stream_id >> 8) & 0xFF);
    frame[8] = (char)(stream_id & 0xFF);

    // Window increment (31 bits)
    frame[9] = (char)((increment >> 24) & 0x7F);
    frame[10] = (char)((increment >> 16) & 0xFF);
    frame[11] = (char)((increment >> 8) & 0xFF);
    frame[12] = (char)(increment & 0xFF);

    session.retain();
    session.conn.write(frame, &on_write_complete, session)!!;
}

/**
 * Send a simple 200 OK response (minimal HPACK)
 * Respects flow control windows per RFC 9113 §5.2
 */
fn void send_simple_response(H2Session* session, uint stream_id)
{
    // Get stream for flow control check
    stream::Stream* stream_state;
    if (try s = session.streams.get_ref(stream_id))
    {
        stream_state = s;
    }
    else
    {
        io::eprintfn("[%d] Cannot send response: stream %d not found", session.session_id, stream_id);
        return;
    }

    // Response body
    char[3] body = { 'O', 'K', '\n' };
    uint body_len = 3;

    // Calculate how much we can send based on flow control windows
    // Both stream window and connection window must allow data
    uint stream_window = stream_state.send_window;
    int conn_window = session.connection_window;

    // Determine bytes to send (minimum of body, stream window, connection window)
    uint bytes_to_send = body_len;
    if (stream_window < bytes_to_send) bytes_to_send = stream_window;
    if (conn_window > 0 && (uint)conn_window < bytes_to_send) bytes_to_send = (uint)conn_window;
    if (conn_window <= 0) bytes_to_send = 0;

    io::printfn("[%d] Flow control: stream_window=%d, conn_window=%d, sending=%d bytes",
                session.session_id, stream_window, conn_window, bytes_to_send);

    // If we can't send any data due to flow control, send HEADERS only (no END_STREAM)
    // and wait for WINDOW_UPDATE to send the DATA
    if (bytes_to_send == 0)
    {
        // Send HEADERS only WITHOUT END_STREAM - data will follow when window opens
        char[10] headers_frame;
        headers_frame[0] = 0; headers_frame[1] = 0; headers_frame[2] = 1;  // Length = 1
        headers_frame[3] = FRAME_HEADERS;
        headers_frame[4] = FLAG_END_HEADERS;  // NO END_STREAM - body pending
        headers_frame[5] = (char)((stream_id >> 24) & 0x7F);
        headers_frame[6] = (char)((stream_id >> 16) & 0xFF);
        headers_frame[7] = (char)((stream_id >> 8) & 0xFF);
        headers_frame[8] = (char)(stream_id & 0xFF);
        headers_frame[9] = 0x88;  // :status: 200

        // Mark stream as having pending response data
        // Stream stays in HALF_CLOSED_LOCAL (we sent HEADERS, client sent END_STREAM)
        stream_state.pending_response = true;
        stream_state.headers_sent = true;
        // Don't transition state - keep it open for DATA later

        session.retain();
        session.conn.write(headers_frame[..], &on_write_complete, session)!!;
        io::printfn("[%d] Sent 200 HEADERS (body pending, window=0) on stream %d", session.session_id, stream_id);
        return;
    }

    // Send HEADERS + partial/full DATA respecting flow control
    bool is_complete = (bytes_to_send == body_len);

    // Buffer: 9 (HEADERS header) + 1 (payload) + 9 (DATA header) + bytes_to_send
    // Arena allocated (freed when session ends)
    char[] frame = allocator::alloc_array(&session.arena, char, 22);  // Max: 10 + 12 = 22 bytes

    // === HEADERS frame (10 bytes) ===
    frame[0] = 0; frame[1] = 0; frame[2] = 1;  // Length = 1 byte
    frame[3] = FRAME_HEADERS;
    frame[4] = FLAG_END_HEADERS;  // NOT END_STREAM - body follows
    frame[5] = (char)((stream_id >> 24) & 0x7F);
    frame[6] = (char)((stream_id >> 16) & 0xFF);
    frame[7] = (char)((stream_id >> 8) & 0xFF);
    frame[8] = (char)(stream_id & 0xFF);
    frame[9] = 0x88;  // :status: 200

    // === DATA frame (9 + bytes_to_send bytes) ===
    frame[10] = 0;
    frame[11] = 0;
    frame[12] = (char)bytes_to_send;  // Length
    frame[13] = FRAME_DATA;
    frame[14] = is_complete ? FLAG_END_STREAM : 0;  // END_STREAM only if complete
    frame[15] = (char)((stream_id >> 24) & 0x7F);
    frame[16] = (char)((stream_id >> 16) & 0xFF);
    frame[17] = (char)((stream_id >> 8) & 0xFF);
    frame[18] = (char)(stream_id & 0xFF);

    // Copy body data
    for (uint i = 0; i < bytes_to_send; i++)
    {
        frame[19 + i] = body[i];
    }

    // Update flow control windows
    stream_state.send_window -= bytes_to_send;
    session.connection_window -= (int)bytes_to_send;

    // Update stream state if we sent END_STREAM
    if (is_complete)
    {
        (void)stream::send_end_stream(stream_state);
        io::printfn("[%d] Stream %d state after response: %s", session.session_id, stream_id,
                    stream::get_state_name(stream_state.state));
    }

    // Calculate actual frame size to send (use length syntax [0:len] for slice)
    usz total_len = (usz)(10 + 9 + bytes_to_send);  // HEADERS(10) + DATA header(9) + body

    session.retain();
    session.conn.write(frame[0:total_len], &on_write_complete, session)!!;
    io::printfn("[%d] Sent 200 OK with %d/%d bytes on stream %d%s",
                session.session_id, bytes_to_send, body_len, stream_id,
                is_complete ? " (complete)" : " (partial)");
}

// ============================================================================
// Callbacks
// ============================================================================

fn void on_write_complete(tcp::TcpConnection* conn, int status, void* user_data)
{
    // Debug: log entry
    io::printfn("on_write_complete: status=%d user_data=%p", status, user_data);
    io::stdout().flush()!!;

    H2Session* session = (H2Session*)user_data;
    io::printfn("[%d] on_write_complete: status=%d refcount=%d",
                session.session_id, status, session.refcount.load(RELAXED));
    io::stdout().flush()!!;

    defer session.release();

    if (status < 0)
    {
        io::eprintfn("[%d] Write error: %d", session.session_id, status);
        // Mark connection as closed to stop frame processing
        // Don't call stop_read() here - it could trigger EOF callback synchronously,
        // which would release the session before our defer runs, causing use-after-free.
        // The natural EOF from the client closing will handle cleanup.
        session.state = ConnectionState.CLOSED;
    }
}

fn void on_goaway_write_complete(tcp::TcpConnection* conn, int status, void* user_data)
{
    H2Session* session = (H2Session*)user_data;

    // Guard against double-close (shouldn't happen with send_goaway guard, but defensive)
    if (session.state == ConnectionState.CLOSED) {
        session.release();
        return;
    }

    io::printfn("[%d] GOAWAY sent, closing connection", session.session_id);
    session.state = ConnectionState.CLOSED;
    // Close the connection immediately after GOAWAY
    // h2spec expects active TCP close, not passive wait for EOF
    conn.close();  // Actively close the TCP connection
    session.release();  // Release write callback ref - triggers dealloc
}
