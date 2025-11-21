/**
 * HTTP/1.1 Connection Pool
 *
 * Manages a pool of HTTP connections with:
 * - Keep-alive connection reuse
 * - Per-host connection limits
 * - Automatic idle connection cleanup
 * - Checkout/checkin lifecycle management
 */
module c3web::http1::connection_pool;

import c3web::http1::client_connection;
import async::event_loop;
import async::timer;
import std::collections::map;
import std::collections::list;
import std::time;
import std::io;

faultdef POOL_ERROR, POOL_AT_LIMIT, POOL_SHUTDOWN;

/**
 * Checked-out connection tracking
 */
struct CheckedOutEntry {
    client_connection::ClientConnection* conn;
    long checkout_time;  // Unix timestamp when checked out
}

/**
 * Connection pool with keep-alive reuse
 */
struct ConnectionPool {
    event_loop::EventLoop* loop;  // Borrowed reference (not owned)

    // Available connections (idle, ready to reuse)
    HashMap{String, List{client_connection::ClientConnection*}} available;

    // Checked-out connections (in use by requests)
    List{CheckedOutEntry} checked_out;

    // Configuration
    usz max_connections_per_host;  // Default: 6 (browser behavior)
    usz max_total_connections;     // Default: 100
    usz max_idle_time_sec;         // Default: 60 seconds

    // Cleanup timer (runs periodically)
    timer::Timer* cleanup_timer;
    usz cleanup_interval_ms;       // Default: 10000 (10 seconds)

    bool shutting_down;  // Prevent new connections during cleanup

    Allocator allocator;
}

/**
 * Create connection pool
 */
fn ConnectionPool*? create(event_loop::EventLoop* loop, Allocator allocator = mem) @public
{
    ConnectionPool* pool = mem::new(ConnectionPool);
    pool.loop = loop;  // Borrow event loop
    pool.available.init(allocator);
    pool.checked_out.init(allocator);

    // Default configuration
    pool.max_connections_per_host = 6;    // Like browsers
    pool.max_total_connections = 100;
    pool.max_idle_time_sec = 60;          // 1 minute
    pool.cleanup_interval_ms = 10000;     // 10 seconds

    pool.shutting_down = false;
    pool.allocator = allocator;

    // Start cleanup timer
    pool.cleanup_timer = timer::create(loop)!;
    pool.cleanup_timer.start(
        pool.cleanup_interval_ms,
        pool.cleanup_interval_ms,  // Repeat
        &on_cleanup_tick,
        pool
    );

    return pool;
}

/**
 * Free connection pool and close all connections
 */
fn void ConnectionPool.free(&self) @public
{
    self.shutting_down = true;

    // Stop cleanup timer
    if (self.cleanup_timer) {
        self.cleanup_timer.stop();
        self.cleanup_timer.close();
        self.cleanup_timer = null;
    }

    // Close all available connections
    self.available.@each(; String host, List{client_connection::ClientConnection*} conns)
    {
        for (usz i = 0; i < conns.len(); i++) {
            client_connection::ClientConnection* conn = conns.get(i);
            conn.close();
        }
        conns.free();
        host.free(self.allocator);  // Free host key
    };
    self.available.free();

    // Close all checked-out connections
    for (usz i = 0; i < self.checked_out.len(); i++) {
        CheckedOutEntry entry = self.checked_out.get(i);
        entry.conn.close();
    }
    self.checked_out.free();

    mem::free(self);
}

/**
 * Configure max connections per host
 */
fn void ConnectionPool.set_max_connections_per_host(&self, usz max) @public
{
    self.max_connections_per_host = max;
}

/**
 * Configure max total connections
 */
fn void ConnectionPool.set_max_total_connections(&self, usz max) @public
{
    self.max_total_connections = max;
}

/**
 * Configure idle timeout in seconds
 */
fn void ConnectionPool.set_idle_timeout(&self, usz seconds) @public
{
    self.max_idle_time_sec = seconds;
}

/**
 * Configure cleanup interval in milliseconds
 */
fn void ConnectionPool.set_cleanup_interval(&self, usz ms) @public
{
    self.cleanup_interval_ms = ms;

    // Restart timer with new interval
    if (self.cleanup_timer) {
        self.cleanup_timer.stop();
        self.cleanup_timer.start(ms, ms, &on_cleanup_tick, self);
    }
}

/**
 * Get connection (checkout) - reuses existing or creates new
 */
fn void ConnectionPool.get_connection(&self, String host, ushort port,
                                      client_connection::ConnectCallback callback,
                                      void* user_data = null) @public
{
    if (self.shutting_down) {
        callback(null, -1, user_data);  // Error: pool shutdown
        return;
    }

    // Try to get from available pool
    String host_key = host;
    if (try conns_ref = self.available.get_ref(host_key)) {
        while (conns_ref.len() > 0) {
            client_connection::ClientConnection* conn = conns_ref.pop()!!;

            // Check if still usable
            if (conn.is_reusable()) {
                // Move to checked-out
                CheckedOutEntry entry;
                entry.conn = conn;
                entry.checkout_time = (long)time::now().to_seconds();
                self.checked_out.push(entry);

                // Notify caller with existing connection
                callback(conn, 0, user_data);
                return;
            } else {
                // Connection died, close it
                conn.close();
            }
        }
    }

    // No available connection - check limits before creating
    usz host_count = self.get_host_connection_count(host);
    if (host_count >= self.max_connections_per_host) {
        // At per-host limit
        callback(null, -1, user_data);
        return;
    }

    usz total_count = self.get_total_connection_count();
    if (total_count >= self.max_total_connections) {
        // At total limit
        callback(null, -1, user_data);
        return;
    }

    // Create new connection
    client_connection::ClientConnection*? new_conn_result =
        client_connection::connect(self.loop, host, port, callback, user_data);

    if (catch err = new_conn_result) {
        // Connection failed
        callback(null, -1, user_data);
        return;
    }

    client_connection::ClientConnection* new_conn = new_conn_result;

    // Add to checked-out
    CheckedOutEntry entry;
    entry.conn = new_conn;
    entry.checkout_time = (long)time::now().to_seconds();
    self.checked_out.push(entry);
}

/**
 * Return connection (checkin) - adds to available pool or closes
 */
fn void ConnectionPool.return_connection(&self, client_connection::ClientConnection* conn) @public
{
    if (self.shutting_down) {
        conn.close();
        return;
    }

    // Remove from checked-out
    for (usz i = 0; i < self.checked_out.len(); i++) {
        CheckedOutEntry entry = self.checked_out.get(i);
        if (entry.conn == conn) {
            self.checked_out.remove_at(i);
            break;
        }
    }

    // Check if reusable
    if (!conn.is_reusable()) {
        conn.close();
        return;
    }

    // Add to available pool
    String host_key = conn.host.copy(self.allocator);

    if (try conns_ref = self.available.get_ref(host_key)) {
        conns_ref.push(conn);
    } else {
        List{client_connection::ClientConnection*} new_list;
        new_list.init(self.allocator);
        new_list.push(conn);
        self.available.set(host_key, new_list);
    }
}

/**
 * Remove connection from pool (force removal)
 */
fn void ConnectionPool.remove_connection(&self, client_connection::ClientConnection* conn) @public
{
    // Remove from checked-out if present
    for (usz i = 0; i < self.checked_out.len(); i++) {
        CheckedOutEntry entry = self.checked_out.get(i);
        if (entry.conn == conn) {
            self.checked_out.remove_at(i);
            break;
        }
    }

    // Remove from available if present
    String host_key = conn.host;
    if (try conns_ref = self.available.get_ref(host_key)) {
        for (usz i = 0; i < conns_ref.len(); i++) {
            if (conns_ref.get(i) == conn) {
                conns_ref.remove_at(i);
                break;
            }
        }
    }

    conn.close();
}

/**
 * Get count of available connections for a host
 */
fn usz ConnectionPool.get_available_count(&self, String host) @public
{
    if (try conns_ref = self.available.get_ref(host)) {
        return conns_ref.len();
    }
    return 0;
}

/**
 * Get count of checked-out connections for a host
 */
fn usz ConnectionPool.get_checked_out_count(&self, String host) @public
{
    usz count = 0;
    for (usz i = 0; i < self.checked_out.len(); i++) {
        CheckedOutEntry entry = self.checked_out.get(i);
        if (entry.conn.host == host) {
            count++;
        }
    }
    return count;
}

/**
 * Get total connection count for a host (available + checked out)
 */
fn usz ConnectionPool.get_host_connection_count(&self, String host) @public
{
    return self.get_available_count(host) + self.get_checked_out_count(host);
}

/**
 * Get total connection count across all hosts
 */
fn usz ConnectionPool.get_total_connection_count(&self) @public
{
    usz total = 0;

    // Count available
    self.available.@each(; String host, List{client_connection::ClientConnection*} conns)
    {
        total += conns.len();
    };

    // Count checked-out
    total += self.checked_out.len();

    return total;
}

/**
 * Force close all idle connections immediately
 */
fn void ConnectionPool.close_idle_connections(&self) @public
{
    long now = (long)time::now().to_seconds();

    self.available.@each_entry(; entry)
    {
        List{client_connection::ClientConnection*}* conns = &entry.value;
        for (usz i = 0; i < conns.len(); /* manual */) {
            client_connection::ClientConnection* conn = conns.get(i);

            if (conn.idle_seconds() > (long)self.max_idle_time_sec) {
                // Expired - close and remove
                conn.close();
                conns.remove_at(i);  // Don't increment i
            } else {
                i++;  // Keep this connection
            }
        }
    };
}

// ============================================================================
// Internal Callbacks
// ============================================================================

/**
 * Cleanup timer callback - periodically closes idle connections
 */
fn void on_cleanup_tick(timer::Timer* timer, void* user_data)
{
    ConnectionPool* pool = (ConnectionPool*)user_data;

    if (pool.shutting_down) return;

    // Close idle connections
    pool.close_idle_connections();
}
