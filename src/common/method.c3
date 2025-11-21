<*
 * HTTP Methods
 *
 * Defines HTTP request methods per RFC 9110 Section 9.
 *>
module c3web::common::method;

<* HTTP request methods (RFC 9110§9) *>
enum HttpMethod : char {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    CONNECT,
    OPTIONS,
    TRACE,
    PATCH,    // RFC 5789
}

faultdef INVALID_METHOD, METHOD_TOO_LONG;

<* Parse HTTP method from string. *>
fn HttpMethod? parse(String method_str) {
    switch (method_str) {
        case "GET": return HttpMethod.GET;
        case "HEAD": return HttpMethod.HEAD;
        case "POST": return HttpMethod.POST;
        case "PUT": return HttpMethod.PUT;
        case "DELETE": return HttpMethod.DELETE;
        case "CONNECT": return HttpMethod.CONNECT;
        case "OPTIONS": return HttpMethod.OPTIONS;
        case "TRACE": return HttpMethod.TRACE;
        case "PATCH": return HttpMethod.PATCH;
        default: return INVALID_METHOD?;
    }
}

<* Convert method to string representation. *>
fn String HttpMethod.to_string(HttpMethod method) {
    switch (method) {
        case HttpMethod.GET: return "GET";
        case HttpMethod.HEAD: return "HEAD";
        case HttpMethod.POST: return "POST";
        case HttpMethod.PUT: return "PUT";
        case HttpMethod.DELETE: return "DELETE";
        case HttpMethod.CONNECT: return "CONNECT";
        case HttpMethod.OPTIONS: return "OPTIONS";
        case HttpMethod.TRACE: return "TRACE";
        case HttpMethod.PATCH: return "PATCH";
    }
}

<*
 * Check if method is safe (RFC 9110§9.2.1).
 * Safe methods: GET, HEAD, OPTIONS, TRACE
 *>
fn bool HttpMethod.is_safe(HttpMethod method) {
    return method == HttpMethod.GET ||
           method == HttpMethod.HEAD ||
           method == HttpMethod.OPTIONS ||
           method == HttpMethod.TRACE;
}

<*
 * Check if method is idempotent (RFC 9110§9.2.2).
 * Idempotent methods: GET, HEAD, PUT, DELETE, OPTIONS, TRACE
 *>
fn bool HttpMethod.is_idempotent(HttpMethod method) {
    return method.is_safe() ||
           method == HttpMethod.PUT ||
           method == HttpMethod.DELETE;
}

<*
 * Check if method is cacheable (RFC 9110§9.2.3).
 * Cacheable methods: GET, HEAD, POST
 *>
fn bool HttpMethod.is_cacheable(HttpMethod method) {
    return method == HttpMethod.GET ||
           method == HttpMethod.HEAD ||
           method == HttpMethod.POST;
}
