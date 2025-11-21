# HTTP/2 Implementation

This directory contains the HTTP/2 protocol implementation.

## Components

- Binary framing layer
- Stream multiplexing
- Server push
- HPACK header compression
- Flow control
- Stream prioritization

## References

- [RFC 7540](https://tools.ietf.org/html/rfc7540) - HTTP/2 Specification
- [RFC 7541](https://tools.ietf.org/html/rfc7541) - HPACK Header Compression

## Testing

Use [h2spec](https://github.com/summerwind/h2spec) for conformance testing:
```bash
h2spec -p 8080
```
