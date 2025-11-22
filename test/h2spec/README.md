# h2spec HTTP/2 Conformance Testsuite Integration

This directory contains the h2spec testsuite integration for validating the c3web HTTP/2 implementation against RFC 9113 compliance.

## What is h2spec?

[h2spec](https://github.com/summerwind/h2spec) is the industry-standard conformance testing tool for HTTP/2 implementations. It contains **~147 test cases** covering:

- Starting HTTP/2 (connection preface, SETTINGS)
- HTTP Frame handling (all frame types)
- Streams and Multiplexing
- Frame Definitions (DATA, HEADERS, PRIORITY, RST_STREAM, SETTINGS, PUSH_PROMISE, PING, GOAWAY, WINDOW_UPDATE, CONTINUATION)
- Error Codes
- HTTP Message Exchanges

## Prerequisites

- **Docker** - Required to run h2spec
- **c3c compiler** - To build the HTTP/2 test server

Install Docker:
```bash
# Linux (Ubuntu/Debian)
sudo apt-get install docker.io

# macOS
brew install --cask docker

# Or download from https://docs.docker.com/get-docker/
```

## Running the Tests

### Quick Start

From the project root, run:

```bash
./test/h2spec/run_h2spec.sh
```

This script will:
1. Build the c3web library
2. Build the HTTP/2 test server
3. Start the server on port 8080
4. Run h2spec testsuite (~147 tests)
5. Display results and save output

### Command Options

```bash
# Run all tests
./test/h2spec/run_h2spec.sh

# Run in strict mode (recommended for full compliance)
./test/h2spec/run_h2spec.sh --strict

# Run specific section
./test/h2spec/run_h2spec.sh -s 3        # Section 3: Starting HTTP/2
./test/h2spec/run_h2spec.sh -s 6.5      # Section 6.5: SETTINGS

# Verbose output
./test/h2spec/run_h2spec.sh -v

# JSON output
./test/h2spec/run_h2spec.sh --json

# Custom port
H2SPEC_PORT=9000 ./test/h2spec/run_h2spec.sh
```

### Manual Steps

If you prefer to run manually:

**1. Build the server:**
```bash
c3c build c3web
c3c build h2spec_server
```

**2. Start the HTTP/2 server:**
```bash
./build/h2spec_server
```

**3. In another terminal, run h2spec:**
```bash
# Via Docker (recommended)
docker run --rm --network=host summerwind/h2spec -p 8080 --strict

# Or if h2spec is installed locally
h2spec -p 8080 --strict
```

## Understanding the Results

h2spec output shows:

- **Passed** - Test passed
- **Failed** - Protocol violation (must fix!)
- **Skipped** - Test skipped (e.g., TLS-only tests)

### Test Categories (RFC 9113 Sections)

| Section | Description | Tests |
|---------|-------------|-------|
| 3 | Starting HTTP/2 | ~19 |
| 4 | HTTP Frames | ~53 |
| 5 | Streams and Multiplexing | ~63 |
| 6.1 | DATA | ~12 |
| 6.2 | HEADERS | ~19 |
| 6.3 | PRIORITY | ~6 |
| 6.4 | RST_STREAM | ~8 |
| 6.5 | SETTINGS | ~38 |
| 6.7 | PING | ~8 |
| 6.8 | GOAWAY | ~8 |
| 6.9 | WINDOW_UPDATE | ~21 |
| 6.10 | CONTINUATION | ~19 |
| 7 | Error Codes | ~1 |
| 8 | HTTP Message Exchanges | ~29 |

## Test Server Implementation

The HTTP/2 test server (`h2_server.c3`) implements:

- Connection preface handling (`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`)
- SETTINGS frame exchange
- Basic frame parsing
- Simple request/response handling

As the HTTP/2 implementation progresses, this server will be expanded to pass more h2spec tests.

## Troubleshooting

**Server fails to start:**
- Check if port 8080 is already in use: `lsof -i :8080`
- Try a different port: `H2SPEC_PORT=9000 ./run_h2spec.sh`

**Docker connection fails:**
- Ensure `--network=host` is used
- On Docker Desktop for Mac/Windows, you may need to use `host.docker.internal` instead

**Tests hang or timeout:**
- Check server logs in `/tmp/h2spec_server.log`
- Ensure the server is responding to the connection preface

**h2spec image not found:**
```bash
docker pull summerwind/h2spec:latest
```

## Progress Tracking

As HTTP/2 implementation progresses:

| Component | h2spec Sections | Status |
|-----------|-----------------|--------|
| Connection Preface | 3.x | Not Started |
| SETTINGS | 6.5 | Not Started |
| Frame Parsing | 4.x | Not Started |
| Stream Management | 5.x | Not Started |
| HPACK | 8.x (partial) | Not Started |
| Flow Control | 6.9 | Not Started |
| Error Handling | 7.x | Not Started |

## References

- [h2spec GitHub](https://github.com/summerwind/h2spec)
- [RFC 9113 - HTTP/2](https://datatracker.ietf.org/doc/html/rfc9113)
- [RFC 7541 - HPACK](https://datatracker.ietf.org/doc/html/rfc7541)
