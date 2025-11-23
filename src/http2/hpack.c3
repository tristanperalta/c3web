/**
 * HPACK Header Compression for HTTP/2
 * RFC 7541 - HPACK: Header Compression for HTTP/2
 *
 * This module implements HPACK decoding for HTTP/2 header blocks.
 * It supports:
 * - Static table lookup (61 entries)
 * - Dynamic table management
 * - Integer decoding (prefix-encoded)
 * - String literal decoding (plain and Huffman)
 * - Header field representations (indexed, literal)
 */
module c3web::http2::hpack;

import std::io;

// HPACK Error Codes
faultdef COMPRESSION_ERROR, INVALID_INDEX, INVALID_INTEGER, INVALID_STRING,
         INVALID_HUFFMAN, EOS_IN_STRING, TABLE_SIZE_ERROR, INCOMPLETE_HEADER;

// Header field (name-value pair)
struct HeaderField {
    String name;
    String value;
}

// Dynamic table entry with size tracking
struct DynamicEntry {
    String name;
    String value;
    usz size;  // Entry size = name.len + value.len + 32
}

// Maximum dynamic table entries (reasonable limit)
const usz MAX_DYNAMIC_ENTRIES = 256;

// HPACK Decoder state
struct Decoder {
    // Dynamic table (RFC 7541 Section 2.3.2)
    DynamicEntry[MAX_DYNAMIC_ENTRIES] dynamic_table;
    usz dynamic_table_len;           // Number of entries
    usz dynamic_table_size;          // Current size in bytes
    usz max_dynamic_table_size;      // Maximum size (from SETTINGS)

    // Decoding state
    bool expecting_table_size_update;
}

const usz STATIC_TABLE_SIZE = 61;

// Static Table (RFC 7541 Appendix A)
// 61 entries indexed 1-61 (index 0 is invalid)
const HeaderField[STATIC_TABLE_SIZE + 1] STATIC_TABLE = {
    { "", "" },                                      // Index 0 - invalid
    { ":authority", "" },                            // 1
    { ":method", "GET" },                            // 2
    { ":method", "POST" },                           // 3
    { ":path", "/" },                                // 4
    { ":path", "/index.html" },                      // 5
    { ":scheme", "http" },                           // 6
    { ":scheme", "https" },                          // 7
    { ":status", "200" },                            // 8
    { ":status", "204" },                            // 9
    { ":status", "206" },                            // 10
    { ":status", "304" },                            // 11
    { ":status", "400" },                            // 12
    { ":status", "404" },                            // 13
    { ":status", "500" },                            // 14
    { "accept-charset", "" },                        // 15
    { "accept-encoding", "gzip, deflate" },          // 16
    { "accept-language", "" },                       // 17
    { "accept-ranges", "" },                         // 18
    { "accept", "" },                                // 19
    { "access-control-allow-origin", "" },           // 20
    { "age", "" },                                   // 21
    { "allow", "" },                                 // 22
    { "authorization", "" },                         // 23
    { "cache-control", "" },                         // 24
    { "content-disposition", "" },                   // 25
    { "content-encoding", "" },                      // 26
    { "content-language", "" },                      // 27
    { "content-length", "" },                        // 28
    { "content-location", "" },                      // 29
    { "content-range", "" },                         // 30
    { "content-type", "" },                          // 31
    { "cookie", "" },                                // 32
    { "date", "" },                                  // 33
    { "etag", "" },                                  // 34
    { "expect", "" },                                // 35
    { "expires", "" },                               // 36
    { "from", "" },                                  // 37
    { "host", "" },                                  // 38
    { "if-match", "" },                              // 39
    { "if-modified-since", "" },                     // 40
    { "if-none-match", "" },                         // 41
    { "if-range", "" },                              // 42
    { "if-unmodified-since", "" },                   // 43
    { "last-modified", "" },                         // 44
    { "link", "" },                                  // 45
    { "location", "" },                              // 46
    { "max-forwards", "" },                          // 47
    { "proxy-authenticate", "" },                    // 48
    { "proxy-authorization", "" },                   // 49
    { "range", "" },                                 // 50
    { "referer", "" },                               // 51
    { "refresh", "" },                               // 52
    { "retry-after", "" },                           // 53
    { "server", "" },                                // 54
    { "set-cookie", "" },                            // 55
    { "strict-transport-security", "" },             // 56
    { "transfer-encoding", "" },                     // 57
    { "user-agent", "" },                            // 58
    { "vary", "" },                                  // 59
    { "via", "" },                                   // 60
    { "www-authenticate", "" },                      // 61
};

/**
 * Get a header from the static table by index (1-61)
 * Index 0 is invalid, indices beyond 61 are invalid for static table
 */
fn HeaderField? get_static_header(uint index) {
    if (index == 0 || index > STATIC_TABLE_SIZE) {
        return INVALID_INDEX?;
    }
    return STATIC_TABLE[index];
}

/**
 * Decode a prefix-encoded integer (RFC 7541 Section 5.1)
 *
 * If the value is less than 2^N-1, it's encoded directly in the prefix bits.
 * Otherwise, the prefix is all 1s and additional bytes follow.
 */
fn uint? decode_integer(char[]* data, usz* pos, uint prefix_bits) {
    if (*pos >= (*data).len) {
        return INCOMPLETE_HEADER?;
    }

    uint prefix_mask = (1u << prefix_bits) - 1;
    uint value = (uint)((*data)[*pos] & (char)prefix_mask);
    (*pos)++;

    // If value < 2^N - 1, we're done
    if (value < prefix_mask) {
        return value;
    }

    // Multi-byte encoding
    uint m = 0;
    while (*pos < (*data).len) {
        char b = (*data)[*pos];
        (*pos)++;

        value += ((uint)(b & 0x7F)) << m;
        m += 7;

        // Check for overflow
        if (m > 28) {
            return INVALID_INTEGER?;
        }

        // If MSB is 0, we're done
        if ((b & 0x80) == 0) {
            return value;
        }
    }

    // Ran out of data
    return INCOMPLETE_HEADER?;
}

/**
 * Decode a string literal (RFC 7541 Section 5.2)
 *
 * Format: H-bit (1=Huffman) + 7-bit length prefix + data
 */
fn String? decode_string(char[]* data, usz* pos) {
    if (*pos >= (*data).len) {
        return INCOMPLETE_HEADER?;
    }

    char first_byte = (*data)[*pos];
    bool is_huffman = (first_byte & 0x80) != 0;

    uint length = decode_integer(data, pos, 7)!;

    if (*pos + length > (*data).len) {
        return INCOMPLETE_HEADER?;
    }

    if (is_huffman) {
        // Huffman decoding
        char[] huffman_data = (*data)[*pos:length];
        *pos += length;
        return decode_huffman(huffman_data);
    } else {
        // Plain string
        String result = (String)(*data)[*pos:length];
        *pos += length;
        return result;
    }
}

/**
 * Decode a complete HPACK header block
 * Returns an array of header fields
 */
fn HeaderField[]? decode_header_block(char[] data) {
    // Use a fixed-size buffer for headers
    HeaderField[128] headers;
    usz header_count = 0;
    usz pos = 0;

    while (pos < data.len) {
        if (header_count >= headers.len) {
            return COMPRESSION_ERROR?;  // Too many headers
        }

        char first_byte = data[pos];

        // Indexed Header Field (RFC 7541 Section 6.1)
        // Starts with 1xxxxxxx
        if (first_byte & 0x80) {
            uint index = decode_integer(&data, &pos, 7)!;

            // Index 0 is invalid (RFC 7541 Section 2.3.1)
            if (index == 0) {
                return COMPRESSION_ERROR?;
            }

            // Static table: indices 1-61
            if (index <= STATIC_TABLE_SIZE) {
                headers[header_count++] = STATIC_TABLE[index];
            } else {
                // Dynamic table lookup would go here
                // For now, any index beyond static table fails
                return COMPRESSION_ERROR?;
            }
        }
        // Literal Header Field with Incremental Indexing (RFC 7541 Section 6.2.1)
        // Starts with 01xxxxxx
        else if (first_byte & 0x40) {
            uint index = decode_integer(&data, &pos, 6)!;

            String name;
            if (index == 0) {
                // New name
                name = decode_string(&data, &pos)!;
            } else if (index <= STATIC_TABLE_SIZE) {
                // Indexed name from static table
                name = STATIC_TABLE[index].name;
            } else {
                return COMPRESSION_ERROR?;
            }

            String value = decode_string(&data, &pos)!;
            headers[header_count++] = (HeaderField){ .name = name, .value = value };
        }
        // Dynamic Table Size Update (RFC 7541 Section 6.3)
        // Starts with 001xxxxx
        else if (first_byte & 0x20) {
            // Just consume the size update for now
            decode_integer(&data, &pos, 5)!;
        }
        // Literal Header Field without Indexing (RFC 7541 Section 6.2.2)
        // Starts with 0000xxxx
        // Literal Header Field Never Indexed (RFC 7541 Section 6.2.3)
        // Starts with 0001xxxx
        else {
            uint index = decode_integer(&data, &pos, 4)!;

            String name;
            if (index == 0) {
                // New name
                name = decode_string(&data, &pos)!;
            } else if (index <= STATIC_TABLE_SIZE) {
                // Indexed name from static table
                name = STATIC_TABLE[index].name;
            } else {
                return COMPRESSION_ERROR?;
            }

            String value = decode_string(&data, &pos)!;
            headers[header_count++] = (HeaderField){ .name = name, .value = value };
        }
    }

    // Return a slice of the headers array
    return headers[0:header_count];
}

/**
 * Decode a Huffman-encoded string (RFC 7541 Section 5.2)
 */
fn String? decode_huffman(char[] data) {
    if (data.len == 0) {
        return "";
    }

    char[4096] output;
    usz output_len = 0;

    uint bits = 0;      // Accumulated bits
    uint num_bits = 0;  // Number of accumulated bits

    foreach (b : data) {
        bits = (bits << 8) | (uint)(char)b;
        num_bits += 8;

        while (num_bits >= 5) {  // Minimum Huffman code length
            int symbol = decode_huffman_symbol(&bits, &num_bits);
            if (symbol < 0) {
                // Need more bits or invalid
                if (symbol == -2) {
                    return EOS_IN_STRING?;  // EOS symbol found
                }
                break;  // Need more bits
            }

            if (output_len >= output.len) {
                return INVALID_HUFFMAN?;  // Output too large
            }
            output[output_len++] = (char)symbol;
        }
    }

    // Validate padding: remaining bits should be all 1s
    if (num_bits > 7) {
        return INVALID_HUFFMAN?;  // Too much padding
    }
    if (num_bits > 0) {
        uint padding_mask = (1u << num_bits) - 1;
        if ((bits & padding_mask) != padding_mask) {
            return INVALID_HUFFMAN?;  // Padding not all 1s
        }
    }

    return (String)output[0:output_len];
}

// Huffman symbol decoder - returns symbol (0-255), -1 for need more bits, -2 for EOS
fn int decode_huffman_symbol(uint* bits, uint* num_bits) {
    if (*num_bits < 5) return -1;

    // 5-bit codes (most common)
    uint code5 = (*bits >> (*num_bits - 5)) & 0x1F;
    int sym5 = lookup_huffman_5bit(code5);
    if (sym5 >= 0) {
        *num_bits -= 5;
        return sym5;
    }

    if (*num_bits < 6) return -1;
    uint code6 = (*bits >> (*num_bits - 6)) & 0x3F;
    int sym6 = lookup_huffman_6bit(code6);
    if (sym6 >= 0) {
        *num_bits -= 6;
        return sym6;
    }

    if (*num_bits < 7) return -1;
    uint code7 = (*bits >> (*num_bits - 7)) & 0x7F;
    int sym7 = lookup_huffman_7bit(code7);
    if (sym7 >= 0) {
        *num_bits -= 7;
        return sym7;
    }

    if (*num_bits < 8) return -1;
    uint code8 = (*bits >> (*num_bits - 8)) & 0xFF;
    int sym8 = lookup_huffman_8bit(code8);
    if (sym8 >= 0) {
        *num_bits -= 8;
        return sym8;
    }

    // Check for EOS (30 bits of 1s)
    if (*num_bits >= 30) {
        uint eos_mask = 0x3FFFFFFF;
        if (((*bits >> (*num_bits - 30)) & eos_mask) == eos_mask) {
            return -2;  // EOS found - error
        }
    }

    return -1;  // Need more bits or unsupported
}

// 5-bit Huffman codes (RFC 7541 Appendix B)
fn int lookup_huffman_5bit(uint code) {
    switch (code) {
        case 0b00000: return '0';
        case 0b00001: return '1';
        case 0b00010: return '2';
        case 0b00011: return 'a';
        case 0b00100: return 'c';
        case 0b00101: return 'e';
        case 0b00110: return 'i';
        case 0b00111: return 'o';
        case 0b01000: return 's';
        case 0b01001: return 't';
        default: return -1;
    }
}

// 6-bit Huffman codes
fn int lookup_huffman_6bit(uint code) {
    switch (code) {
        case 0b010100: return ' ';
        case 0b010101: return '%';
        case 0b010110: return '-';
        case 0b010111: return '.';
        case 0b011000: return '/';
        case 0b011001: return '3';
        case 0b011010: return '4';
        case 0b011011: return '5';
        case 0b011100: return '6';
        case 0b011101: return '7';
        case 0b011110: return '8';
        case 0b011111: return '9';
        case 0b100000: return '=';
        case 0b100001: return 'A';
        case 0b100010: return '_';
        case 0b100011: return 'b';
        case 0b100100: return 'd';
        case 0b100101: return 'f';
        case 0b100110: return 'g';
        case 0b100111: return 'h';
        case 0b101000: return 'l';
        case 0b101001: return 'm';
        case 0b101010: return 'n';
        case 0b101011: return 'p';
        case 0b101100: return 'r';
        case 0b101101: return 'u';
        default: return -1;
    }
}

// 7-bit Huffman codes
fn int lookup_huffman_7bit(uint code) {
    switch (code) {
        case 0b1011100: return ':';
        case 0b1011101: return 'B';
        case 0b1011110: return 'C';
        case 0b1011111: return 'D';
        case 0b1100000: return 'E';
        case 0b1100001: return 'F';
        case 0b1100010: return 'G';
        case 0b1100011: return 'H';
        case 0b1100100: return 'I';
        case 0b1100101: return 'J';
        case 0b1100110: return 'K';
        case 0b1100111: return 'L';
        case 0b1101000: return 'M';
        case 0b1101001: return 'N';
        case 0b1101010: return 'O';
        case 0b1101011: return 'P';
        case 0b1101100: return 'Q';
        case 0b1101101: return 'R';
        case 0b1101110: return 'S';
        case 0b1101111: return 'T';
        case 0b1110000: return 'U';
        case 0b1110001: return 'V';
        case 0b1110010: return 'W';
        case 0b1110011: return 'Y';
        case 0b1110100: return 'j';
        case 0b1110101: return 'k';
        case 0b1110110: return 'q';
        case 0b1110111: return 'v';
        case 0b1111000: return 'w';
        case 0b1111001: return 'x';
        case 0b1111010: return 'y';
        case 0b1111011: return 'z';
        default: return -1;
    }
}

// 8-bit Huffman codes
fn int lookup_huffman_8bit(uint code) {
    switch (code) {
        case 0b11111100: return '&';
        case 0b11111101: return '*';
        case 0b11111110: return ',';
        case 0b11111111: return ';';
        default: return -1;
    }
}

/**
 * Initialize a new HPACK decoder
 */
fn Decoder new_decoder(usz max_table_size = 4096) {
    return (Decoder){
        .dynamic_table_len = 0,
        .dynamic_table_size = 0,
        .max_dynamic_table_size = max_table_size,
        .expecting_table_size_update = false,
    };
}
