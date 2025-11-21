/**
 * HTTP Status Codes
 *
 * Status code definitions per RFC 9110§15.
 */
module c3web::common::status;

<* HTTP status code type. *>
typedef HttpStatus = ushort;

// 1xx Informational
const HttpStatus STATUS_CONTINUE = 100;
const HttpStatus STATUS_SWITCHING_PROTOCOLS = 101;
const HttpStatus STATUS_PROCESSING = 102;
const HttpStatus STATUS_EARLY_HINTS = 103;

// 2xx Success
const HttpStatus STATUS_OK = 200;
const HttpStatus STATUS_CREATED = 201;
const HttpStatus STATUS_ACCEPTED = 202;
const HttpStatus STATUS_NON_AUTHORITATIVE = 203;
const HttpStatus STATUS_NO_CONTENT = 204;
const HttpStatus STATUS_RESET_CONTENT = 205;
const HttpStatus STATUS_PARTIAL_CONTENT = 206;
const HttpStatus STATUS_MULTI_STATUS = 207;
const HttpStatus STATUS_ALREADY_REPORTED = 208;
const HttpStatus STATUS_IM_USED = 226;

// 3xx Redirection
const HttpStatus STATUS_MULTIPLE_CHOICES = 300;
const HttpStatus STATUS_MOVED_PERMANENTLY = 301;
const HttpStatus STATUS_FOUND = 302;
const HttpStatus STATUS_SEE_OTHER = 303;
const HttpStatus STATUS_NOT_MODIFIED = 304;
const HttpStatus STATUS_USE_PROXY = 305;
const HttpStatus STATUS_TEMPORARY_REDIRECT = 307;
const HttpStatus STATUS_PERMANENT_REDIRECT = 308;

// 4xx Client Errors
const HttpStatus STATUS_BAD_REQUEST = 400;
const HttpStatus STATUS_UNAUTHORIZED = 401;
const HttpStatus STATUS_PAYMENT_REQUIRED = 402;
const HttpStatus STATUS_FORBIDDEN = 403;
const HttpStatus STATUS_NOT_FOUND = 404;
const HttpStatus STATUS_METHOD_NOT_ALLOWED = 405;
const HttpStatus STATUS_NOT_ACCEPTABLE = 406;
const HttpStatus STATUS_PROXY_AUTH_REQUIRED = 407;
const HttpStatus STATUS_REQUEST_TIMEOUT = 408;
const HttpStatus STATUS_CONFLICT = 409;
const HttpStatus STATUS_GONE = 410;
const HttpStatus STATUS_LENGTH_REQUIRED = 411;
const HttpStatus STATUS_PRECONDITION_FAILED = 412;
const HttpStatus STATUS_CONTENT_TOO_LARGE = 413;
const HttpStatus STATUS_URI_TOO_LONG = 414;
const HttpStatus STATUS_UNSUPPORTED_MEDIA_TYPE = 415;
const HttpStatus STATUS_RANGE_NOT_SATISFIABLE = 416;
const HttpStatus STATUS_EXPECTATION_FAILED = 417;
const HttpStatus STATUS_IM_A_TEAPOT = 418;  // RFC 2324
const HttpStatus STATUS_MISDIRECTED_REQUEST = 421;
const HttpStatus STATUS_UNPROCESSABLE_ENTITY = 422;
const HttpStatus STATUS_LOCKED = 423;
const HttpStatus STATUS_FAILED_DEPENDENCY = 424;
const HttpStatus STATUS_TOO_EARLY = 425;
const HttpStatus STATUS_UPGRADE_REQUIRED = 426;
const HttpStatus STATUS_PRECONDITION_REQUIRED = 428;
const HttpStatus STATUS_TOO_MANY_REQUESTS = 429;
const HttpStatus STATUS_HEADER_FIELDS_TOO_LARGE = 431;
const HttpStatus STATUS_UNAVAILABLE_LEGAL = 451;

// 5xx Server Errors
const HttpStatus STATUS_INTERNAL_SERVER_ERROR = 500;
const HttpStatus STATUS_NOT_IMPLEMENTED = 501;
const HttpStatus STATUS_BAD_GATEWAY = 502;
const HttpStatus STATUS_SERVICE_UNAVAILABLE = 503;
const HttpStatus STATUS_GATEWAY_TIMEOUT = 504;
const HttpStatus STATUS_HTTP_VERSION_NOT_SUPPORTED = 505;
const HttpStatus STATUS_VARIANT_ALSO_NEGOTIATES = 506;
const HttpStatus STATUS_INSUFFICIENT_STORAGE = 507;
const HttpStatus STATUS_LOOP_DETECTED = 508;
const HttpStatus STATUS_NOT_EXTENDED = 510;
const HttpStatus STATUS_NETWORK_AUTH_REQUIRED = 511;

/**
 * Get reason phrase for status code (RFC 9110§15).
 */
fn String status_reason(HttpStatus status) {
    switch (status) {
        // 1xx
        case STATUS_CONTINUE: return "Continue";
        case STATUS_SWITCHING_PROTOCOLS: return "Switching Protocols";
        case STATUS_PROCESSING: return "Processing";
        case STATUS_EARLY_HINTS: return "Early Hints";

        // 2xx
        case STATUS_OK: return "OK";
        case STATUS_CREATED: return "Created";
        case STATUS_ACCEPTED: return "Accepted";
        case STATUS_NON_AUTHORITATIVE: return "Non-Authoritative Information";
        case STATUS_NO_CONTENT: return "No Content";
        case STATUS_RESET_CONTENT: return "Reset Content";
        case STATUS_PARTIAL_CONTENT: return "Partial Content";
        case STATUS_MULTI_STATUS: return "Multi-Status";
        case STATUS_ALREADY_REPORTED: return "Already Reported";
        case STATUS_IM_USED: return "IM Used";

        // 3xx
        case STATUS_MULTIPLE_CHOICES: return "Multiple Choices";
        case STATUS_MOVED_PERMANENTLY: return "Moved Permanently";
        case STATUS_FOUND: return "Found";
        case STATUS_SEE_OTHER: return "See Other";
        case STATUS_NOT_MODIFIED: return "Not Modified";
        case STATUS_USE_PROXY: return "Use Proxy";
        case STATUS_TEMPORARY_REDIRECT: return "Temporary Redirect";
        case STATUS_PERMANENT_REDIRECT: return "Permanent Redirect";

        // 4xx
        case STATUS_BAD_REQUEST: return "Bad Request";
        case STATUS_UNAUTHORIZED: return "Unauthorized";
        case STATUS_PAYMENT_REQUIRED: return "Payment Required";
        case STATUS_FORBIDDEN: return "Forbidden";
        case STATUS_NOT_FOUND: return "Not Found";
        case STATUS_METHOD_NOT_ALLOWED: return "Method Not Allowed";
        case STATUS_NOT_ACCEPTABLE: return "Not Acceptable";
        case STATUS_PROXY_AUTH_REQUIRED: return "Proxy Authentication Required";
        case STATUS_REQUEST_TIMEOUT: return "Request Timeout";
        case STATUS_CONFLICT: return "Conflict";
        case STATUS_GONE: return "Gone";
        case STATUS_LENGTH_REQUIRED: return "Length Required";
        case STATUS_PRECONDITION_FAILED: return "Precondition Failed";
        case STATUS_CONTENT_TOO_LARGE: return "Content Too Large";
        case STATUS_URI_TOO_LONG: return "URI Too Long";
        case STATUS_UNSUPPORTED_MEDIA_TYPE: return "Unsupported Media Type";
        case STATUS_RANGE_NOT_SATISFIABLE: return "Range Not Satisfiable";
        case STATUS_EXPECTATION_FAILED: return "Expectation Failed";
        case STATUS_IM_A_TEAPOT: return "I'm a teapot";
        case STATUS_MISDIRECTED_REQUEST: return "Misdirected Request";
        case STATUS_UNPROCESSABLE_ENTITY: return "Unprocessable Entity";
        case STATUS_LOCKED: return "Locked";
        case STATUS_FAILED_DEPENDENCY: return "Failed Dependency";
        case STATUS_TOO_EARLY: return "Too Early";
        case STATUS_UPGRADE_REQUIRED: return "Upgrade Required";
        case STATUS_PRECONDITION_REQUIRED: return "Precondition Required";
        case STATUS_TOO_MANY_REQUESTS: return "Too Many Requests";
        case STATUS_HEADER_FIELDS_TOO_LARGE: return "Request Header Fields Too Large";
        case STATUS_UNAVAILABLE_LEGAL: return "Unavailable For Legal Reasons";

        // 5xx
        case STATUS_INTERNAL_SERVER_ERROR: return "Internal Server Error";
        case STATUS_NOT_IMPLEMENTED: return "Not Implemented";
        case STATUS_BAD_GATEWAY: return "Bad Gateway";
        case STATUS_SERVICE_UNAVAILABLE: return "Service Unavailable";
        case STATUS_GATEWAY_TIMEOUT: return "Gateway Timeout";
        case STATUS_HTTP_VERSION_NOT_SUPPORTED: return "HTTP Version Not Supported";
        case STATUS_VARIANT_ALSO_NEGOTIATES: return "Variant Also Negotiates";
        case STATUS_INSUFFICIENT_STORAGE: return "Insufficient Storage";
        case STATUS_LOOP_DETECTED: return "Loop Detected";
        case STATUS_NOT_EXTENDED: return "Not Extended";
        case STATUS_NETWORK_AUTH_REQUIRED: return "Network Authentication Required";

        default: return "Unknown Status";
    }
}

/**
 * Check if status code is informational (1xx).
 */
fn bool is_informational(HttpStatus status) {
    return status >= 100 && status < 200;
}

/**
 * Check if status code is successful (2xx).
 */
fn bool is_success(HttpStatus status) {
    return status >= 200 && status < 300;
}

/**
 * Check if status code is a redirection (3xx).
 */
fn bool is_redirection(HttpStatus status) {
    return status >= 300 && status < 400;
}

/**
 * Check if status code is a client error (4xx).
 */
fn bool is_client_error(HttpStatus status) {
    return status >= 400 && status < 500;
}

/**
 * Check if status code is a server error (5xx).
 */
fn bool is_server_error(HttpStatus status) {
    return status >= 500 && status < 600;
}

/**
 * Check if status code is an error (4xx or 5xx).
 */
fn bool is_error(HttpStatus status) {
    return status >= 400;
}
