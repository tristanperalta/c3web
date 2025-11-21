# Autobahn WebSocket Testsuite Integration

This directory contains the Autobahn testsuite integration for validating the c3web WebSocket implementation against RFC 6455 compliance.

## What is Autobahn?

[Autobahn|Testsuite](https://github.com/crossbario/autobahn-testsuite) is the industry-standard automated test suite for WebSocket protocol compliance. It contains **over 500 test cases** covering:

- Framing and protocol structure
- Pings/Pongs (control frames)
- Reserved bits
- Opcodes (TEXT, BINARY, CLOSE, PING, PONG, CONTINUATION)
- Message fragmentation and reassembly
- UTF-8 validation
- Performance and limits testing
- Close handshake protocol
- WebSocket compression (permessage-deflate)

## Prerequisites

- **Docker** - Required to run the Autobahn testsuite
- **c3c compiler** - To build the WebSocket echo server

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
./test/autobahn/run_autobahn.sh
```

This script will:
1. Build the c3web library
2. Build the WebSocket echo server
3. Start the server on port 9002
4. Run Autobahn testsuite (500+ tests)
5. Generate an HTML compliance report

### Manual Steps

If you prefer to run manually:

**1. Build the server:**
```bash
c3c build c3web
c3c build autobahn_server
```

**2. Start the WebSocket echo server:**
```bash
./build/autobahn_server
```

**3. In another terminal, run Autobahn:**
```bash
cd test/autobahn

docker run -it --rm \
  -v "${PWD}/fuzzingclient.json:/config/fuzzingclient.json" \
  -v "${PWD}/reports:/reports" \
  --add-host=host.docker.internal:host-gateway \
  crossbario/autobahn-testsuite:latest \
  wstest -m fuzzingclient -s /config/fuzzingclient.json
```

**4. View the results:**
```bash
# Linux
xdg-open test/autobahn/reports/index.html

# macOS
open test/autobahn/reports/index.html
```

## Understanding the Results

The HTML report categorizes test results as:

- ✅ **PASS** - Full RFC 6455 compliance
- ❌ **FAIL** - Protocol violation (must fix!)
- ⚠️ **NON-STRICT** - Minor issues, still usable
- ℹ️ **INFORMATIONAL** - Performance metrics

### Test Categories

The suite runs tests in these categories:

1. **1.x - Framing** - Basic frame structure
2. **2.x - Pings/Pongs** - Control frame handling
3. **3.x - Reserved Bits** - Protocol bit compliance
4. **4.x - Opcodes** - Operation code validation
5. **5.x - Fragmentation** - Message splitting/reassembly
6. **6.x - UTF-8** - Text encoding validation
7. **7.x - Close Handshake** - Connection termination
8. **9.x - Limits/Performance** - Stress testing
9. **12.x - WebSocket Compression** - permessage-deflate (if supported)

## Configuration

Edit `fuzzingclient.json` to customize:

```json
{
  "outdir": "./reports",
  "servers": [
    {
      "agent": "c3web WebSocket Server",
      "url": "ws://host.docker.internal:9002"
    }
  ],
  "cases": ["*"],              // Run all tests
  "exclude-cases": [],          // Skip specific tests
  "exclude-agent-cases": {}
}
```

## Implementation Details

The WebSocket echo server (`websocket_server.c3`):

- Uses c3io async event loop for non-blocking I/O
- Implements complete RFC 6455 handshake validation
- Echoes TEXT and BINARY messages back (standard for Autobahn)
- Handles control frames (PING → PONG, CLOSE handshake)
- Properly validates UTF-8 for TEXT frames
- Supports message fragmentation

## Troubleshooting

**Server fails to start:**
- Check if port 9002 is already in use: `lsof -i :9002`
- Try a different port (update both server code and fuzzingclient.json)

**Docker connection fails:**
- Ensure `--add-host=host.docker.internal:host-gateway` is set
- On Linux, you may need to use `--network=host` instead

**Tests hang or timeout:**
- Check server logs for errors
- Increase Docker timeout in configuration
- Ensure firewall allows connections to port 9002

## References

- [Autobahn|Testsuite Documentation](https://github.com/crossbario/autobahn-testsuite)
- [RFC 6455 - The WebSocket Protocol](https://datatracker.ietf.org/doc/html/rfc6455)
- [WebSocket.org Testing Guide](https://websocket.org/guides/testing/autobahn/)
