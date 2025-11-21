// Simple HTTP/1.1 Echo Server
// Demonstrates c3web HTTP/1.1 implementation with c3io.
// Responds with request details (method, path, headers).

import std::io;
import async::event_loop;
import async::tcp;
import c3web::http1::connection;
import c3web::http1::parser;
import c3web::http1::response;
import c3web::common::method;
import c3web::common::status;

// HTTP request handler - echoes request details back to client.
fn void handle_request(connection::Connection* conn, parser::Request* request, response::Response* resp) {
    // Build response body with request details
    DString body;
    body.tinit(4096);

    body.appendf("Echo Server - Request Details\n");
    body.appendf("==============================\n\n");

    body.appendf("Method: %s\n", request.method.to_string());
    body.appendf("Target: %s\n", request.target);
    body.appendf("Version: %s\n\n", request.version.to_string(tmem));

    body.appendf("Headers:\n");
    body.appendf("--------\n");

    // Iterate through headers
    request.headers.headers.@each(; String key, String value) {
        body.appendf("%s: %s\n", key, value);
    };

    // Check if there's a body
    char[] request_body = conn.parser.get_body();
    if (request_body.len > 0) {
        body.appendf("\nBody (%d bytes):\n", request_body.len);
        body.appendf("----------------\n");
        body.append((String)request_body);
        body.append("\n");
    }

    // Set response
    resp.set_status(status::STATUS_OK);
    resp.set_content_type("text/plain; charset=utf-8")!!;
    resp.write_string(body.str_view())!!;
}

// Called when a new client connects to the server.
fn void on_connection(tcp::TcpConnection* server, tcp::TcpConnection* client, void* user_data) {
    io::printfn("New client connected!");

    // Create HTTP connection wrapper
    connection::Connection* conn = connection::create_connection(
        client,
        &handle_request,
        null
    );

    // Start reading HTTP requests
    conn.start_reading()!!;
}

fn int main() {
    io::printfn("c3web Echo Server");
    io::printfn("=================\n");

    // Create event loop
    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt) {
        io::eprintfn("Failed to create event loop");
        return 1;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    // Create TCP server
    tcp::TcpConnection*? server_opt = tcp::create(&loop);
    if (catch err = server_opt) {
        io::eprintfn("Failed to create server");
        return 1;
    }
    tcp::TcpConnection* server = server_opt;
    defer server.close();

    // Bind to port
    String host = "0.0.0.0";
    ushort port = 8080;
    server.bind(host, port)!!;

    io::printfn("Server listening on http://%s:%d", host, port);
    io::printfn("Press Ctrl+C to stop\n");

    // Start accepting connections
    server.listen(128, &on_connection)!!;

    // Run event loop
    loop.run()!!;

    return 0;
}
