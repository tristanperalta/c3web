// Simple HTTP/1.1 Test Client
// Provides low-level control for testing HTTP server behavior

module c3web::test::support::test_client;

import std::io;
import std::net::tcp;

struct TestClient {
    TcpSocket socket;
    char[8192] buffer;
    usz buffer_len;
}

faultdef CONNECTION_FAILED, SEND_FAILED, RECV_FAILED, PARSE_FAILED;

<* Connect to HTTP server *>
fn TestClient? connect(String host, ushort port) {
    TcpSocket? sock = tcp::connect(host, port);
    if (catch err = sock) {
        return CONNECTION_FAILED?;
    }

    TestClient client;
    client.socket = sock;
    client.buffer_len = 0;
    return client;
}

<* Send raw bytes to server *>
fn void? TestClient.send(&self, String data) {
    usz? written = self.socket.write((char[])data);
    if (catch err = written) {
        return SEND_FAILED?;
    }
}

<* Send HTTP request line *>
fn void? TestClient.send_request(&self, String method, String target, String version = "1.1") {
    self.send(string::tformat("%s %s HTTP/%s\r\n", method, target, version))!;
}

<* Send header line *>
fn void? TestClient.send_header(&self, String name, String value) {
    self.send(string::tformat("%s: %s\r\n", name, value))!;
}

<* Send end of headers *>
fn void? TestClient.send_headers_end(&self) {
    self.send("\r\n")!;
}

<* Send complete simple GET request *>
fn void? TestClient.send_get(&self, String path) {
    self.send_request("GET", path)!;
    self.send_header("Host", "localhost")!;
    self.send_headers_end()!;
}

<* Receive data from server *>
fn char[]? TestClient.recv(&self) {
    usz? bytes_read = self.socket.read(&self.buffer);
    if (catch err = bytes_read) {
        return RECV_FAILED?;
    }

    if (bytes_read == 0) {
        return (char[]){};  // EOF
    }

    self.buffer_len = bytes_read;
    return self.buffer[0:bytes_read];
}

<* Parse status line from response *>
fn ushort? parse_status_line(String response) {
    // Parse "HTTP/1.1 200 OK\r\n"
    usz? space1 = response.index_of_char(' ');
    if (catch err = space1) return PARSE_FAILED?;

    // Search for second space in remaining string
    String remainder = response[space1 + 1..];
    usz? space2_rel = remainder.index_of_char(' ');
    if (catch err = space2_rel) return PARSE_FAILED?;

    usz space2 = space1 + 1 + space2_rel;
    String status_code = response[space1 + 1 : space2 - space1 - 1];
    return status_code.to_ushort();
}

<* Close connection *>
fn void TestClient.close(&self) {
    self.socket.close()!!;
}
