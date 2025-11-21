// HTTP/1.1 Request Target Tests
// Tests RFC 9112 §3.2 (Request Target) compliance

module c3web::test::http1::request_target_test;

import c3web::http1::parser;
import c3web::common::method;
import std::net::url;

// Test origin-form request target (RFC 9112 §3.2.1)
// Most common form: "/path?query"
fn void test_origin_form_simple_path() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request = "GET /test/path HTTP/1.1\r\nHost: localhost\r\n\r\n";
    parser::ParseResult? result = p.feed((char[])request);

    assert(result!! == parser::ParseResult.COMPLETE, "Parse should complete");

    parser::Request* req = p.get_request();
    assert(req.target == "/test/path", "Target should match");
    assert(req.path == "/test/path", "Path should be extracted");
    assert(req.method == method::HttpMethod.GET, "Method should be GET");
}

fn void test_origin_form_with_query() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request = "GET /path?foo=bar&name=test HTTP/1.1\r\nHost: localhost\r\n\r\n";
    parser::ParseResult? result = p.feed((char[])request);

    assert(result!! == parser::ParseResult.COMPLETE);

    parser::Request* req = p.get_request();
    assert(req.path == "/path", "Path should not include query");
    assert(req.query.key_order.len() == 2, "Should have 2 query params");

    // Check query values
    url::UrlQueryValueList? foo_values = req.query.get("foo");
    assert(@ok(foo_values), "Should have 'foo' parameter");
    assert(foo_values!![0] == "bar", "foo should equal 'bar'");
}

fn void test_origin_form_url_encoded_path() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // Test URL-encoded path: /test%20path -> /test path
    String request = "GET /test%20path HTTP/1.1\r\nHost: localhost\r\n\r\n";
    parser::ParseResult? result = p.feed((char[])request);

    assert(result!! == parser::ParseResult.COMPLETE);

    parser::Request* req = p.get_request();
    assert(req.path == "/test path", "Path should be URL-decoded");
}

fn void test_origin_form_root_path() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    parser::ParseResult? result = p.feed((char[])request);

    assert(result!! == parser::ParseResult.COMPLETE);

    parser::Request* req = p.get_request();
    assert(req.path == "/", "Path should be root");
}

// Test absolute-form request target (RFC 9112 §3.2.2)
// Used with proxies: "http://example.com/path"
fn void test_absolute_form() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request = "GET http://example.com:8080/test HTTP/1.1\r\nHost: example.com\r\n\r\n";
    parser::ParseResult? result = p.feed((char[])request);

    assert(result!! == parser::ParseResult.COMPLETE);

    parser::Request* req = p.get_request();
    assert(req.target == "http://example.com:8080/test");
    assert(req.path == "/test", "Path should be extracted");
    assert(req.url.host == "example.com", "Host should match");
    assert(req.url.port == 8080, "Port should match");
}

// Test query parameter edge cases
fn void test_multiple_query_values() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // Same parameter multiple times
    String request = "GET /path?tag=foo&tag=bar&tag=baz HTTP/1.1\r\nHost: localhost\r\n\r\n";
    parser::ParseResult? result = p.feed((char[])request);

    assert(result!! == parser::ParseResult.COMPLETE);

    parser::Request* req = p.get_request();
    url::UrlQueryValueList? tag_values = req.query.get("tag");
    assert(@ok(tag_values), "Should have 'tag' parameter");
    assert(tag_values!!.len() == 3, "Should have 3 values for 'tag'");
    assert(tag_values!![0] == "foo");
    assert(tag_values!![1] == "bar");
    assert(tag_values!![2] == "baz");
}

fn void test_url_encoded_query_values() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    // Test URL-encoded query: "hello world" -> "hello%20world"
    String request = "GET /path?msg=hello%20world&name=test%2Buser HTTP/1.1\r\nHost: localhost\r\n\r\n";
    parser::ParseResult? result = p.feed((char[])request);

    assert(result!! == parser::ParseResult.COMPLETE);

    parser::Request* req = p.get_request();
    url::UrlQueryValueList? msg = req.query.get("msg");
    assert(msg!![0] == "hello world", "Query value should be decoded");

    url::UrlQueryValueList? name = req.query.get("name");
    assert(name!![0] == "test+user", "Plus sign should be preserved (not decoded to space in query)");
}

fn void test_empty_query_value() @test {
    parser::Parser p;
    p.init();
    defer p.free();

    String request = "GET /path?empty=&foo=bar HTTP/1.1\r\nHost: localhost\r\n\r\n";
    parser::ParseResult? result = p.feed((char[])request);

    assert(result!! == parser::ParseResult.COMPLETE);

    parser::Request* req = p.get_request();
    url::UrlQueryValueList? empty = req.query.get("empty");
    assert(@ok(empty), "Should have 'empty' parameter");
    assert(empty!![0] == "", "Value should be empty string");
}
