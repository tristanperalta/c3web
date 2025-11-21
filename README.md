# c3web - HTTP Suite Library for C3

A comprehensive HTTP implementation suite for the C3 programming language, providing HTTP/1.1, HTTP/2, HTTP/3, and WebSocket support built on top of the c3io library.

## Features

- **HTTP/1.1** - Full HTTP/1.1 protocol implementation
- **HTTP/2** - Modern binary protocol with multiplexing support
- **HTTP/3** - QUIC-based protocol for improved performance
- **WebSockets** - Real-time bidirectional communication

## Project Status

🚧 **Early Development** - This project is in active development and not yet ready for production use.

## Dependencies

- [c3io](https://github.com/tristanperalta/c3io) - Async I/O library for C3 (imported as `async::*`)
- libuv - Cross-platform asynchronous I/O
- C3 compiler (langrev 1)

The c3io library is included as a git submodule in `lib/c3io.c3l`.

## Project Structure

```
c3web/
├── src/              # Source files
│   ├── http1/       # HTTP/1.1 implementation
│   ├── http2/       # HTTP/2 implementation
│   ├── http3/       # HTTP/3 implementation
│   └── websocket/   # WebSocket implementation
├── test/            # Test files
├── build/           # Build output
└── project.json     # C3 project configuration
```

## Building

```bash
# Clone with submodules
git clone --recursive https://github.com/tristanperalta/c3web.git

# Or if already cloned, initialize submodules
git submodule update --init --recursive

# Build c3io dependency
cd lib/c3io.c3l && c3c build && cd ../..

# Build the project
c3c build

# Run tests
c3c test
```

## Usage

```c3
import c3web;
import async::tcp;  // c3io modules are under the async namespace

// Your HTTP code here
```

## Testing Resources

This project aims for conformance with HTTP specifications. The following testing tools are used:

### HTTP/2 Testing
- [h2spec](https://github.com/summerwind/h2spec) - HTTP/2 framing layer conformance tests

### HTTP General Testing
- [cache-tests.fyi](https://cache-tests.fyi) - HTTP caching behavior tests
- [REDbot](https://redbot.org/) - HTTP resource linter
- [httplint](https://httplint.com/) - HTTP message linter
- [Web Platform Tests](https://web-platform-tests.org/) - Specifically Fetch API tests

### Structured Data Testing
- [Structured Header Tests](https://github.com/httpwg/structured-header-tests) - Parsing and serialization tests
- [Content-Disposition Tests](https://github.com/httpwg/http-content-disposition-tests) - Header handling tests

### Documentation
HTTP Working Group documentation available at: `/home/tristan/sources/httpwg.github.io/`

## Roadmap

- [ ] HTTP/1.1 core implementation
  - [ ] Request/response parsing
  - [ ] Chunked transfer encoding
  - [ ] Connection management
  - [ ] Header handling
- [ ] HTTP/2 implementation
  - [ ] Frame parsing
  - [ ] Stream multiplexing
  - [ ] HPACK compression
  - [ ] Flow control
- [ ] HTTP/3 implementation
  - [ ] QUIC integration
  - [ ] QPACK compression
- [ ] WebSocket implementation
  - [ ] Handshake
  - [ ] Frame handling
  - [ ] Extensions support
- [ ] Testing suite
  - [ ] Unit tests
  - [ ] Integration tests
  - [ ] Conformance tests

## Contributing

This project follows semantic versioning (currently v0.1.0).

## Author

Tristan Peralta <tristan@peralta.ph>

## License

TBD

## Notes

**Important**: There is no official HTTP conformance test suite. The tests referenced above have not been vetted for correctness by the HTTP Working Group. The authority for conformance is always the relevant specification (RFCs).
