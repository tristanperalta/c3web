# c3web - HTTP Suite Library for C3

A comprehensive HTTP implementation suite for the C3 programming language, providing HTTP/1.1, HTTP/2, HTTP/3, and WebSocket support built on top of the c3io library.

## Features

- **HTTP/1.1** - Full HTTP/1.1 protocol implementation
- **HTTP/2** - Modern binary protocol with multiplexing support
- **HTTP/3** - QUIC-based protocol for improved performance
- **WebSockets** - Real-time bidirectional communication

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
cd examples
c3c build echo_server
./out/echo_server
```

See `examples/README.md` for more details.
