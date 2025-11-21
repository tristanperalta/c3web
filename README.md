# c3web - HTTP Suite Library for C3

A HTTP implementation suite for the C3 programming language, providing HTTP/1.1, HTTP/2, HTTP/3, and WebSocket support built on top of the c3io library.

## Features

- **HTTP/1.1** (RFC 9112 compliant)
  - Incremental request parsing with streaming support
  - Chunked transfer encoding with trailer headers
  - Security hardening (request smuggling prevention, bare LF rejection, null byte detection)
  - Body validation with configurable size limits (413, 414 status codes)
  - HTTP version validation (505 status code)
- HTTP/2
- HTTP/3
- WebSockets

## Dependencies

- [c3io](https://github.com/tristanperalta/c3io) - Async I/O library for C3 (imported as `async::*`)
- libuv - Cross-platform asynchronous I/O
- C3 compiler

The c3io library is included as a git submodule in `lib/c3io.c3l`.

## Building

### Building the Library


```bash
# Clone with submodules
git clone --recursive https://github.com/tristanperalta/c3web.git

# Or if already cloned, initialize submodules
git submodule update --init --recursive

# Build c3io dependency (if not already built)
cd lib/c3io.c3l && c3c build && cd ../..

# Build the c3web library
c3c build c3web
```

This creates a static library at `build/c3web.a`.

### Building Examples

```bash
# Build and run the echo server
c3c build echo_server
./build/echo_server

# Test the server
curl -v http://localhost:8080/
curl -v -H "X-Custom: test" "http://localhost:8080/test?foo=bar"
```

See `examples/README.md` for more details.

## Testing

### Run All Tests

```bash
# Run test suite
c3c test
```
