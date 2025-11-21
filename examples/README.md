# c3web Examples

This directory contains example applications demonstrating c3web HTTP server functionality.

## Echo Server

A simple HTTP/1.1 server that echoes request details back to the client.

### Building

```bash
cd examples
c3c build echo_server
```

This will create the executable at `out/echo_server`.

### Running

```bash
./out/echo_server
```

The server will listen on `http://0.0.0.0:8080`.

### Testing

In a separate terminal, run the test script:

```bash
./test_echo.sh
```

Or test manually with curl:

```bash
# Simple GET request
curl http://localhost:8080/

# GET with custom headers
curl -H "X-Custom-Header: test" http://localhost:8080/path

# POST with body
curl -X POST -H "Content-Type: application/json" \
  -d '{"message": "Hello!"}' \
  http://localhost:8080/api/echo
```

### What It Demonstrates

The echo server demonstrates:

- **HTTP/1.1 parsing**: Incremental request parsing with c3web parser
- **Async I/O**: Non-blocking socket operations with c3io (libuv)
- **Request handling**: Custom request handlers with access to method, URI, headers, and body
- **Response generation**: Building and serializing HTTP responses
- **Keep-alive connections**: Connection reuse for multiple requests

### Implementation

The echo server consists of:

1. **Event loop setup**: Creates c3io event loop
2. **TCP server**: Binds to port and listens for connections
3. **Connection handler**: Wraps each TCP connection in HTTP connection wrapper
4. **Request handler**: Processes parsed HTTP requests and generates responses
5. **Response serialization**: Converts response to wire format and sends to client

See `echo_server.c3` for the complete implementation.
