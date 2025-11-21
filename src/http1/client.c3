/**
 * HTTP/1.1 Client API
 *
 * High-level HTTP client with:
 * - Simple request methods (GET, POST, etc.)
 * - Automatic redirect following
 * - Request timeouts
 * - Connection pooling (keep-alive reuse)
 * - Async callback-based API
 */
module c3web::http1::client;

import c3web::http1::connection_pool;
import c3web::http1::client_connection;
import c3web::http1::client_request;
import c3web::http1::client_response;
import c3web::common::status;
import c3web::common::method;
import async::event_loop;
import async::timer;
import std::io;

faultdef CLIENT_ERROR, REQUEST_TIMEOUT, TOO_MANY_REDIRECTS, INVALID_URL;

/**
 * Request completion callback
 * @param client - The client instance
 * @param response - Response object (null on error)
 * @param body - Response body data
 * @param status - 0 on success, -1 on error
 * @param user_data - User-provided data
 */
alias RequestCallback = fn void(Client* client, client_response::ClientResponse* response,
                                char[] body, int status, void* user_data);

/**
 * HTTP Client with connection pooling
 */
struct Client {
    event_loop::EventLoop* loop;  // Borrowed reference
    connection_pool::ConnectionPool* pool;

    // Configuration
    usz max_redirects;       // Default: 5
    usz request_timeout_ms;  // Default: 30000 (30 seconds)
    bool follow_redirects;   // Default: true

    Allocator allocator;
}

/**
 * Internal request context (hidden from users)
 */
struct RequestContext {
    Client* client;
    client_request::ClientRequest request;
    RequestCallback user_callback;
    void* user_data;

    // Redirect tracking
    usz redirect_count;

    // Timeout handling
    timer::Timer* timeout_timer;

    // Active connection
    client_connection::ClientConnection* conn;

    // Completion tracking
    bool completed;

    Allocator allocator;
}

/**
 * Create HTTP client
 */
fn Client*? create(event_loop::EventLoop* loop, Allocator allocator = mem) @public
{
    Client* client = mem::new(Client);
    client.loop = loop;
    client.allocator = allocator;

    // Create connection pool
    client.pool = connection_pool::create(loop, allocator)!;

    // Default configuration
    client.max_redirects = 5;
    client.request_timeout_ms = 30000;  // 30 seconds
    client.follow_redirects = true;

    return client;
}

/**
 * Free client and close all connections
 */
fn void Client.free(&self) @public
{
    if (self.pool) {
        self.pool.free();
        self.loop.run_once();  // Process timer close callbacks
        self.pool = null;
    }

    mem::free(self);
}

/**
 * Configure max redirects to follow
 */
fn void Client.set_max_redirects(&self, usz max) @public
{
    self.max_redirects = max;
}

/**
 * Configure request timeout in milliseconds
 */
fn void Client.set_request_timeout(&self, usz timeout_ms) @public
{
    self.request_timeout_ms = timeout_ms;
}

/**
 * Configure whether to follow redirects
 */
fn void Client.set_follow_redirects(&self, bool follow) @public
{
    self.follow_redirects = follow;
}

/**
 * Delegate pool configuration: max connections per host
 */
fn void Client.set_max_connections_per_host(&self, usz max) @public
{
    self.pool.set_max_connections_per_host(max);
}

/**
 * Delegate pool configuration: idle timeout
 */
fn void Client.set_idle_timeout(&self, usz seconds) @public
{
    self.pool.set_idle_timeout(seconds);
}

/**
 * Delegate pool configuration: max total connections
 */
fn void Client.set_max_total_connections(&self, usz max) @public
{
    self.pool.set_max_total_connections(max);
}

/**
 * GET request
 */
fn void Client.get(&self, String url, RequestCallback callback, void* user_data = null) @public
{
    client_request::ClientRequest request = client_request::create_get(url, self.allocator)!!;
    self.request(&request, callback, user_data);
}

/**
 * POST request with body
 */
fn void Client.post(&self, String url, char[] body, String content_type,
                    RequestCallback callback, void* user_data = null) @public
{
    client_request::ClientRequest request = client_request::create_post(url, body, self.allocator)!!;
    request.set_header("Content-Type", content_type);
    self.request(&request, callback, user_data);
}

/**
 * POST request with JSON body
 */
fn void Client.post_json(&self, String url, String json,
                         RequestCallback callback, void* user_data = null) @public
{
    self.post(url, (char[])json, "application/json", callback, user_data);
}

/**
 * PUT request with body
 */
fn void Client.put(&self, String url, char[] body, String content_type,
                   RequestCallback callback, void* user_data = null) @public
{
    client_request::ClientRequest request = client_request::create_put(url, body, self.allocator)!!;
    request.set_header("Content-Type", content_type);
    self.request(&request, callback, user_data);
}

/**
 * DELETE request
 */
fn void Client.delete(&self, String url, RequestCallback callback, void* user_data = null) @public
{
    client_request::ClientRequest request = client_request::create_delete(url, self.allocator)!!;
    self.request(&request, callback, user_data);
}

/**
 * HEAD request
 */
fn void Client.head(&self, String url, RequestCallback callback, void* user_data = null) @public
{
    client_request::ClientRequest request = client_request::create_get(url, self.allocator)!!;
    request.set_method(method::HttpMethod.HEAD);
    self.request(&request, callback, user_data);
}

/**
 * Generic request method
 */
fn void Client.request(&self, client_request::ClientRequest* request,
                       RequestCallback callback, void* user_data = null) @public
{
    // Create request context
    RequestContext* ctx = mem::new(RequestContext);
    ctx.client = self;
    ctx.request = *request;  // Copy request
    ctx.user_callback = callback;
    ctx.user_data = user_data;
    ctx.redirect_count = 0;
    ctx.timeout_timer = null;
    ctx.conn = null;
    ctx.completed = false;
    ctx.allocator = self.allocator;

    // Start request execution
    execute_request(ctx);
}

// ============================================================================
// Internal Request Execution
// ============================================================================

/**
 * Execute request (may be called multiple times for redirects)
 */
fn void execute_request(RequestContext* ctx)
{
    if (ctx.completed) return;

    // Create timeout timer
    ctx.timeout_timer = timer::create(ctx.client.loop)!!;
    ctx.timeout_timer.start(
        ctx.client.request_timeout_ms,
        0,  // No repeat
        &on_request_timeout,
        ctx
    );

    // Get connection from pool
    ctx.client.pool.get_connection(
        ctx.request.url.host,
        (ushort)ctx.request.url.port,
        &on_connection_ready,
        ctx
    );
}

/**
 * Called when connection is ready (or failed)
 */
fn void on_connection_ready(client_connection::ClientConnection* conn, int status, void* user_data)
{
    RequestContext* ctx = (RequestContext*)user_data;

    if (ctx.completed) {
        // Timeout already occurred
        if (conn) ctx.client.pool.return_connection(conn);
        return;
    }

    if (status != 0 || !conn) {
        // Connection failed
        char[] empty;
        finish_request(ctx, null, empty, -1);
        return;
    }

    // Store connection
    ctx.conn = conn;

    // Send request
    if (catch err = conn.send_request(&ctx.request, &on_response_received, ctx)) {
        // Send failed
        char[] empty;
        finish_request(ctx, null, empty, -1);
    }
}

/**
 * Called when response is received
 */
fn void on_response_received(client_connection::ClientConnection* conn,
                             client_response::ClientResponse* response,
                             char[] body, void* user_data)
{
    RequestContext* ctx = (RequestContext*)user_data;

    if (ctx.completed) {
        // Timeout already occurred
        ctx.client.pool.return_connection(conn);
        return;
    }

    // Check if redirect
    if (ctx.client.follow_redirects && is_redirect(response.status)) {
        handle_redirect(ctx, response);
        return;
    }

    // Success - return to user
    finish_request(ctx, response, body, 0);
}

/**
 * Check if status code is a redirect
 */
fn bool is_redirect(status::HttpStatus stat)
{
    return stat == 301 ||  // Moved Permanently
           stat == 302 ||  // Found
           stat == 303 ||  // See Other
           stat == 307 ||  // Temporary Redirect
           stat == 308;    // Permanent Redirect
}

/**
 * Handle redirect response
 */
fn void handle_redirect(RequestContext* ctx, client_response::ClientResponse* response)
{
    // Check redirect limit
    ctx.redirect_count++;
    if (ctx.redirect_count > ctx.client.max_redirects) {
        io::eprintfn("Too many redirects (%d)", ctx.redirect_count);
        char[] empty;
        finish_request(ctx, null, empty, -1);
        return;
    }

    // Get Location header
    String? location = response.headers.get("Location");
    if (catch err = location) {
        io::eprintfn("Redirect without Location header");
        char[] empty;
        finish_request(ctx, null, empty, -1);
        return;
    }

    // Return current connection to pool
    if (ctx.conn) {
        ctx.client.pool.return_connection(ctx.conn);
        ctx.conn = null;
    }

    // Update request for redirect
    String location_url = location;

    // For 303 See Other, change method to GET
    if (response.status == 303) {
        ctx.request.set_method(method::HttpMethod.GET);
        char[] empty;
        ctx.request.set_body(empty);
    }

    // Parse new URL
    // TODO: For now, assume Location is a full URL with host
    // In a full implementation, we'd parse relative URLs
    ctx.request.set_url(location_url)!!;

    // Execute redirect request
    execute_request(ctx);
}

/**
 * Called when request timeout expires
 */
fn void on_request_timeout(timer::Timer* timer, void* user_data)
{
    RequestContext* ctx = (RequestContext*)user_data;

    if (ctx.completed) return;

    io::eprintfn("Request timeout");

    // Close timer
    timer.close();
    ctx.timeout_timer = null;

    // Close connection if active
    if (ctx.conn) {
        ctx.conn.close();
        ctx.conn = null;
    }

    // Finish with timeout error
    char[] empty;
    finish_request(ctx, null, empty, -1);
}

/**
 * Finish request and cleanup
 */
fn void finish_request(RequestContext* ctx, client_response::ClientResponse* response,
                       char[] body, int status)
{
    if (ctx.completed) return;
    ctx.completed = true;

    // Stop timeout timer
    if (ctx.timeout_timer) {
        ctx.timeout_timer.stop();
        ctx.timeout_timer.close();
        ctx.timeout_timer = null;
    }

    // Return connection to pool
    if (ctx.conn) {
        ctx.client.pool.return_connection(ctx.conn);
        ctx.conn = null;
    }

    // Notify user
    if (ctx.user_callback) {
        ctx.user_callback(ctx.client, response, body, status, ctx.user_data);
    }

    // Free context
    mem::free(ctx);
}
