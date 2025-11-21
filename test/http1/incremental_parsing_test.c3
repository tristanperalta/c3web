// HTTP/1.1 Incremental Parsing Tests
// Tests that parser handles streaming data arriving in chunks

module c3web::test::http1::incremental_parsing_test;

import c3web::http1::parser;
import c3web::common::method;

// Test request line arriving in multiple chunks
fn void test_partial_request_line() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // Send partial request line
    parser::ParseResult? result1 = p.feed((char[])"GET /test HTTP/1");
    assert(result1!! == parser::ParseResult.MORE, "Should need more data");

    // Complete the request line and headers
    parser::ParseResult? result2 = p.feed((char[])".1\r\nHost: localhost\r\n\r\n");
    assert(result2!! == parser::ParseResult.COMPLETE, "Should complete");

    parser::Request* req = p.get_request();
    assert(req.method == method::HttpMethod.GET);
    assert(req.path == "/test");
}

fn void test_partial_headers() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // Send request line and partial headers
    parser::ParseResult? result1 = p.feed((char[])"GET / HTTP/1.1\r\nHost: localh");
    assert(result1!! == parser::ParseResult.MORE);

    // Complete host header
    parser::ParseResult? result2 = p.feed((char[])"ost\r\nUser-Agent: test");
    assert(result2!! == parser::ParseResult.MORE);

    // Complete headers
    parser::ParseResult? result3 = p.feed((char[])"\r\n\r\n");
    assert(result3!! == parser::ParseResult.COMPLETE);

    parser::Request* req = p.get_request();
    assert(req.headers.has("host"));
    assert(req.headers.has("user-agent"));
}

fn void test_one_byte_at_a_time() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request = "GET /path HTTP/1.1\r\nHost: localhost\r\n\r\n";

    // Feed one byte at a time
    for (usz i = 0; i < request.len; i++) {
        char[1] byte = { request[i] };
        parser::ParseResult? result = p.feed(&byte);

        if (i < request.len - 1) {
            assert(result!! == parser::ParseResult.MORE, "Should need more until last byte");
        } else {
            assert(result!! == parser::ParseResult.COMPLETE, "Should complete on last byte");
        }
    }

    parser::Request* req = p.get_request();
    assert(req.path == "/path");
}

fn void test_crlf_split_across_chunks() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // Split CRLF between chunks
    parser::ParseResult? result1 = p.feed((char[])"GET /test HTTP/1.1\r");
    assert(result1!! == parser::ParseResult.MORE);

    parser::ParseResult? result2 = p.feed((char[])"\nHost: localhost\r");
    assert(result2!! == parser::ParseResult.MORE);

    parser::ParseResult? result3 = p.feed((char[])"\n\r");
    assert(result3!! == parser::ParseResult.MORE);

    parser::ParseResult? result4 = p.feed((char[])"\n");
    assert(result4!! == parser::ParseResult.COMPLETE);

    parser::Request* req = p.get_request();
    assert(req.path == "/test");
}

fn void test_content_length_body_partial() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // Send headers with content-length
    parser::ParseResult? result1 = p.feed((char[])"POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\n");
    assert(result1!! == parser::ParseResult.MORE, "Should wait for body");

    // Send partial body
    parser::ParseResult? result2 = p.feed((char[])"hello");
    assert(result2!! == parser::ParseResult.MORE, "Should need more body data");

    // Complete body
    parser::ParseResult? result3 = p.feed((char[])"world");
    assert(result3!! == parser::ParseResult.COMPLETE, "Should complete with full body");

    parser::Request* req = p.get_request();
    char[] body = p.get_body();
    assert(body.len == 10);
    assert((String)body == "helloworld");
}

fn void test_multiple_requests_pipelined() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // First request
    parser::ParseResult? result1 = p.feed((char[])"GET /first HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(result1!! == parser::ParseResult.COMPLETE);
    assert(p.get_request().path == "/first");

    // Reset parser for next request (keep-alive)
    p.reset();

    // Second request
    parser::ParseResult? result2 = p.feed((char[])"GET /second HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(result2!! == parser::ParseResult.COMPLETE);
    assert(p.get_request().path == "/second");
}

fn void test_large_headers_incremental() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // Send request line
    parser::ParseResult? result = p.feed((char[])"GET / HTTP/1.1\r\n");
    assert(result!! == parser::ParseResult.MORE);

    // Send many small headers incrementally
    for (int i = 0; i < 50; i++) {
        String header = string::tformat("X-Header-%d: value-%d\r\n", i, i);
        parser::ParseResult? header_result = p.feed((char[])header);
        assert(header_result!! == parser::ParseResult.MORE);
    }

    // End headers
    parser::ParseResult? final_result = p.feed((char[])"\r\n");
    assert(final_result!! == parser::ParseResult.COMPLETE);

    parser::Request* req = p.get_request();
    assert(req.headers.count() >= 50, "Should have all headers");
}
