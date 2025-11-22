# WebSocket Implementation

RFC 6455 compliant WebSocket protocol implementation with RFC 7692 compression support.

## Status

**Complete** - Passes Autobahn testsuite (517 tests: 515 OK, 2 NON-STRICT)

## Components

| File | Description |
|------|-------------|
| `handshake.c3` | Opening handshake validation and Sec-WebSocket-Accept generation |
| `frame.c3` | Frame parsing/creation for all opcodes (Text, Binary, Close, Ping, Pong, Continuation) |
| `utf8.c3` | UTF-8 validation state machine with fragment support |
| `message.c3` | Message fragmentation and reassembly |
| `connection.c3` | Connection state management, close handshake, ping/pong |
| `compression.c3` | RFC 7692 permessage-deflate extension |

## Features

- Full frame parsing with masking/unmasking
- Text and binary message support
- Message fragmentation and reassembly
- UTF-8 validation for text frames (including across fragments)
- Control frame handling (Ping/Pong/Close)
- Close handshake with status codes (1000-1011)
- permessage-deflate compression (RFC 7692)

## Compression Notes

The compression implementation uses the miniz library for DEFLATE:

- Only `window_bits=15` is supported (miniz limitation)
- Server omits `server_max_window_bits` and `client_max_window_bits` in negotiation response
- Per RFC 7692, omitting these parameters means using the default (15)
- Supports `server_no_context_takeover` and `client_no_context_takeover` parameters

## Testing

```bash
# Run unit tests
c3c test

# Run Autobahn testsuite
./test/autobahn/run_autobahn.sh
```

### Autobahn Results

- **515 OK** - Full compliance
- **2 NON-STRICT** - Tests 6.4.3 and 6.4.4 (streaming UTF-8 "fail fast" validation)

The NON-STRICT tests send invalid UTF-8 split across TCP chunks within a single frame and expect immediate rejection. Our implementation validates UTF-8 after the complete frame is received, which is acceptable but not "fail fast".

## References

- [RFC 6455](https://tools.ietf.org/html/rfc6455) - The WebSocket Protocol
- [RFC 7692](https://tools.ietf.org/html/rfc7692) - Compression Extensions for WebSocket
