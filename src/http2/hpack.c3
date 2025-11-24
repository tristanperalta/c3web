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

import std::core::mem;

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
        // RFC 7541 Section 5.2: EOS in Huffman string is a decoding error
        // Map EOS_IN_STRING to COMPRESSION_ERROR for proper HTTP/2 error handling
        String? huffman_result = decode_huffman(huffman_data);
        if (catch err = huffman_result) {
            if (err == EOS_IN_STRING || err == INVALID_HUFFMAN) {
                return COMPRESSION_ERROR?;
            }
            return err?;
        }
        return huffman_result;
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
    return decode_header_block_with_settings(data, 4096);  // Default max table size
}

/**
 * Decode header block with configurable max dynamic table size
 */
fn HeaderField[]? decode_header_block_with_settings(char[] data, usz max_dynamic_table_size) {
    // Allocate headers buffer from temp allocator to avoid returning slice of stack memory
    const usz MAX_HEADERS = 128;
    HeaderField[] headers = mem::temp_array(HeaderField, MAX_HEADERS);
    usz header_count = 0;
    usz pos = 0;

    // Local dynamic table for this header block (RFC 7541 Section 2.3.2)
    // Dynamic table is LIFO - newest entry has lowest index (62)
    const usz MAX_DYN_ENTRIES = 64;
    HeaderField[] dynamic_table = mem::temp_array(HeaderField, MAX_DYN_ENTRIES);
    usz dyn_count = 0;

    // Track if we've seen regular header fields (RFC 7541 Section 4.2)
    // Dynamic table size updates MUST occur at the beginning of the header block
    bool seen_regular_header = false;

    while (pos < data.len) {
        if (header_count >= headers.len) {
            return COMPRESSION_ERROR?;  // Too many headers
        }

        char first_byte = data[pos];

        // Indexed Header Field (RFC 7541 Section 6.1)
        // Starts with 1xxxxxxx
        if (first_byte & 0x80) {
            seen_regular_header = true;
            uint index = decode_integer(&data, &pos, 7)!;

            // Index 0 is invalid (RFC 7541 Section 2.3.1)
            if (index == 0) {
                return COMPRESSION_ERROR?;
            }

            // Static table: indices 1-61
            if (index <= STATIC_TABLE_SIZE) {
                headers[header_count++] = STATIC_TABLE[index];
            } else {
                // Dynamic table: indices 62+ (RFC 7541 Section 2.3.3)
                // Dynamic index 62 = newest entry (dyn_count-1)
                uint dyn_index = index - (uint)STATIC_TABLE_SIZE - 1;  // 0-based index into our table
                if (dyn_index >= dyn_count) {
                    return COMPRESSION_ERROR?;
                }
                // Dynamic table is LIFO, so index 0 = newest = dyn_count-1
                usz actual_idx = dyn_count - 1 - (usz)dyn_index;
                headers[header_count++] = dynamic_table[actual_idx];
            }
        }
        // Literal Header Field with Incremental Indexing (RFC 7541 Section 6.2.1)
        // Starts with 01xxxxxx
        else if (first_byte & 0x40) {
            seen_regular_header = true;
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
            HeaderField hf = (HeaderField){ .name = name, .value = value };
            headers[header_count++] = hf;

            // Add to dynamic table (RFC 7541 Section 6.2.1)
            if (dyn_count < dynamic_table.len) {
                dynamic_table[dyn_count++] = hf;
            }
        }
        // Dynamic Table Size Update (RFC 7541 Section 6.3)
        // Starts with 001xxxxx
        else if (first_byte & 0x20) {
            // RFC 7541 Section 4.2: Dynamic table size updates MUST occur at the
            // beginning of the first header block following a change to SETTINGS
            if (seen_regular_header) {
                return COMPRESSION_ERROR?;  // Size update after headers is an error
            }

            uint new_size = decode_integer(&data, &pos, 5)!;

            // RFC 7541 Section 6.3: New size MUST be <= the value from SETTINGS
            if (new_size > max_dynamic_table_size) {
                return COMPRESSION_ERROR?;  // Exceeds maximum allowed size
            }
        }
        // Literal Header Field without Indexing (RFC 7541 Section 6.2.2)
        // Starts with 0000xxxx
        // Literal Header Field Never Indexed (RFC 7541 Section 6.2.3)
        // Starts with 0001xxxx
        else {
            seen_regular_header = true;
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
 *
 * RFC 7541 padding requirements:
 * - Padding MUST be at most 7 bits
 * - Padding MUST consist of 1-bits (most significant bits of EOS)
 * - A Huffman string containing EOS MUST be treated as a decoding error
 */
fn String? decode_huffman(char[] data) {
    if (data.len == 0) {
        return "";
    }

    // EOS detection is done in decode_huffman_symbol at symbol boundaries.
    // We cannot pre-scan for 30 consecutive 1-bits because valid Huffman codes
    // can produce 30+ consecutive 1s (e.g., multiple ';' characters encoded as 0xFF each).

    // Allocate output buffer from temp allocator to avoid returning slice of stack memory
    // Huffman decoding can expand data (worst case ~8x for repeated small symbols)
    usz max_output = data.len * 8;  // Generous upper bound
    if (max_output < 256) max_output = 256;
    char[] output = mem::temp_array(char, max_output);
    usz output_len = 0;

    ulong bits = 0;     // Accumulated bits (64-bit to prevent overflow)
    uint num_bits = 0;  // Number of accumulated bits
    usz byte_idx = 0;   // Current byte index

    // Phase 1: Accumulate initial bits for decoding
    while (byte_idx < data.len && num_bits < 30) {
        bits = (bits << 8) | (ulong)(char)data[byte_idx];
        num_bits += 8;
        byte_idx++;
    }

    // Phase 2: Decode symbols
    while (true) {
        // Try to decode while we have enough bits
        while (num_bits >= 5) {
            // Before checking EOS, ensure we have accumulated enough bits.
            // EOS is 30 bits, so we need at least 30 bits to detect it.
            // If we have fewer than 30 bits but more input available, accumulate first.
            while (num_bits < 30 && byte_idx < data.len) {
                bits = (bits << 8) | (ulong)(char)data[byte_idx];
                num_bits += 8;
                byte_idx++;
            }

            // Check for EOS at symbol boundary (must check BEFORE decoding)
            // EOS is 30 bits of 1s (0x3FFFFFFF). If we don't check here,
            // it would be decoded as multiple ';' characters (8-bit 0xFF each).
            if (num_bits >= 30) {
                ulong top30 = (bits >> (num_bits - 30)) & 0x3FFFFFFF;
                if (top30 == 0x3FFFFFFF) {
                    return EOS_IN_STRING?;  // EOS found at symbol boundary
                }
            }

            // RFC 7541 Section 5.2: Check for padding >7 bits
            // If all remaining bits in the input are 1s and we have >7 bits,
            // this is excessive padding, not more symbols to decode.
            // This handles the case where 8+ bits of 1s could be decoded as ';'
            // but should actually be treated as invalid padding.
            if (byte_idx >= data.len && num_bits > 7) {
                // Check if all remaining bits are 1s
                ulong mask = (1ul << num_bits) - 1;
                if ((bits & mask) == mask) {
                    // All remaining bits are 1s - this is padding >7 bits
                    return INVALID_HUFFMAN?;
                }
            }

            int symbol = decode_huffman_symbol(&bits, &num_bits);
            if (symbol < 0) {
                if (symbol == -2) {
                    return EOS_IN_STRING?;  // EOS symbol found
                }
                // Can't decode - need more bits or unsupported code
                break;  // Need more bits
            }

            if (output_len >= output.len) {
                return INVALID_HUFFMAN?;  // Output too large
            }
            output[output_len++] = (char)symbol;
        }

        // Add more bytes if available
        if (byte_idx >= data.len) {
            break;  // No more input
        }

        bits = (bits << 8) | (ulong)(char)data[byte_idx];
        num_bits += 8;
        byte_idx++;
    }

    // RFC 7541 Section 5.2: "A padding strictly longer than 7 bits MUST be
    // treated as a decoding error."
    if (num_bits > 7) {
        return INVALID_HUFFMAN?;  // Too much padding
    }

    // Validate padding bits are all 1s
    if (num_bits > 0) {
        ulong padding_mask = (1ul << num_bits) - 1;
        ulong actual_padding = bits & padding_mask;
        if (actual_padding != padding_mask) {
            return INVALID_HUFFMAN?;  // Padding not all 1s
        }
    }

    return (String)output[0:output_len];
}

// Huffman symbol decoder - returns symbol (0-255), -1 for need more bits, -2 for EOS
fn int decode_huffman_symbol(ulong* bits, uint* num_bits) {
    if (*num_bits < 5) return -1;

    // 5-bit codes (most common)
    uint code5 = (uint)((*bits >> (*num_bits - 5)) & 0x1F);
    int sym5 = lookup_huffman_5bit(code5);
    if (sym5 >= 0) {
        *num_bits -= 5;
        return sym5;
    }

    if (*num_bits < 6) return -1;
    uint code6 = (uint)((*bits >> (*num_bits - 6)) & 0x3F);
    int sym6 = lookup_huffman_6bit(code6);
    if (sym6 >= 0) {
        *num_bits -= 6;
        return sym6;
    }

    if (*num_bits < 7) return -1;
    uint code7 = (uint)((*bits >> (*num_bits - 7)) & 0x7F);
    int sym7 = lookup_huffman_7bit(code7);
    if (sym7 >= 0) {
        *num_bits -= 7;
        return sym7;
    }

    if (*num_bits < 8) return -1;
    uint code8 = (uint)((*bits >> (*num_bits - 8)) & 0xFF);
    int sym8 = lookup_huffman_8bit(code8);
    if (sym8 >= 0) {
        *num_bits -= 8;
        return sym8;
    }

    // 10-bit codes
    if (*num_bits < 10) return -1;
    uint code10 = (uint)((*bits >> (*num_bits - 10)) & 0x3FF);
    int sym10 = lookup_huffman_10bit(code10);
    if (sym10 >= 0) {
        *num_bits -= 10;
        return sym10;
    }

    // 11-bit codes
    if (*num_bits < 11) return -1;
    uint code11 = (uint)((*bits >> (*num_bits - 11)) & 0x7FF);
    int sym11 = lookup_huffman_11bit(code11);
    if (sym11 >= 0) {
        *num_bits -= 11;
        return sym11;
    }

    // 12-bit codes
    if (*num_bits < 12) return -1;
    uint code12 = (uint)((*bits >> (*num_bits - 12)) & 0xFFF);
    int sym12 = lookup_huffman_12bit(code12);
    if (sym12 >= 0) {
        *num_bits -= 12;
        return sym12;
    }

    // 13-bit codes
    if (*num_bits < 13) return -1;
    uint code13 = (uint)((*bits >> (*num_bits - 13)) & 0x1FFF);
    int sym13 = lookup_huffman_13bit(code13);
    if (sym13 >= 0) {
        *num_bits -= 13;
        return sym13;
    }

    // 14-bit codes
    if (*num_bits < 14) return -1;
    uint code14 = (uint)((*bits >> (*num_bits - 14)) & 0x3FFF);
    int sym14 = lookup_huffman_14bit(code14);
    if (sym14 >= 0) {
        *num_bits -= 14;
        return sym14;
    }

    // 15-bit codes
    if (*num_bits < 15) return -1;
    uint code15 = (uint)((*bits >> (*num_bits - 15)) & 0x7FFF);
    int sym15 = lookup_huffman_15bit(code15);
    if (sym15 >= 0) {
        *num_bits -= 15;
        return sym15;
    }

    // 19-bit codes
    if (*num_bits < 19) return -1;
    uint code19 = (uint)((*bits >> (*num_bits - 19)) & 0x7FFFF);
    int sym19 = lookup_huffman_19bit(code19);
    if (sym19 >= 0) {
        *num_bits -= 19;
        return sym19;
    }

    // 20-bit codes
    if (*num_bits < 20) return -1;
    uint code20 = (uint)((*bits >> (*num_bits - 20)) & 0xFFFFF);
    int sym20 = lookup_huffman_20bit(code20);
    if (sym20 >= 0) {
        *num_bits -= 20;
        return sym20;
    }

    // 21-bit codes
    if (*num_bits < 21) return -1;
    uint code21 = (uint)((*bits >> (*num_bits - 21)) & 0x1FFFFF);
    int sym21 = lookup_huffman_21bit(code21);
    if (sym21 >= 0) {
        *num_bits -= 21;
        return sym21;
    }

    // 22-bit codes
    if (*num_bits < 22) return -1;
    uint code22 = (uint)((*bits >> (*num_bits - 22)) & 0x3FFFFF);
    int sym22 = lookup_huffman_22bit(code22);
    if (sym22 >= 0) {
        *num_bits -= 22;
        return sym22;
    }

    // 23-bit codes
    if (*num_bits < 23) return -1;
    uint code23 = (uint)((*bits >> (*num_bits - 23)) & 0x7FFFFF);
    int sym23 = lookup_huffman_23bit(code23);
    if (sym23 >= 0) {
        *num_bits -= 23;
        return sym23;
    }

    // 24-bit codes
    if (*num_bits < 24) return -1;
    uint code24 = (uint)((*bits >> (*num_bits - 24)) & 0xFFFFFF);
    int sym24 = lookup_huffman_24bit(code24);
    if (sym24 >= 0) {
        *num_bits -= 24;
        return sym24;
    }

    // 25-bit codes
    if (*num_bits < 25) return -1;
    uint code25 = (uint)((*bits >> (*num_bits - 25)) & 0x1FFFFFF);
    int sym25 = lookup_huffman_25bit(code25);
    if (sym25 >= 0) {
        *num_bits -= 25;
        return sym25;
    }

    // 26-bit codes
    if (*num_bits < 26) return -1;
    uint code26 = (uint)((*bits >> (*num_bits - 26)) & 0x3FFFFFF);
    int sym26 = lookup_huffman_26bit(code26);
    if (sym26 >= 0) {
        *num_bits -= 26;
        return sym26;
    }

    // 27-bit codes
    if (*num_bits < 27) return -1;
    uint code27 = (uint)((*bits >> (*num_bits - 27)) & 0x7FFFFFF);
    int sym27 = lookup_huffman_27bit(code27);
    if (sym27 >= 0) {
        *num_bits -= 27;
        return sym27;
    }

    // 28-bit codes
    if (*num_bits < 28) return -1;
    uint code28 = (uint)((*bits >> (*num_bits - 28)) & 0xFFFFFFF);
    int sym28 = lookup_huffman_28bit(code28);
    if (sym28 >= 0) {
        *num_bits -= 28;
        return sym28;
    }

    // 30-bit codes (including EOS check)
    if (*num_bits < 30) return -1;
    uint code30 = (uint)((*bits >> (*num_bits - 30)) & 0x3FFFFFFF);
    // EOS is 30 bits of 1s (0x3FFFFFFF)
    if (code30 == 0x3FFFFFFF) {
        return -2;  // EOS found - error
    }
    int sym30 = lookup_huffman_30bit(code30);
    if (sym30 >= 0) {
        *num_bits -= 30;
        return sym30;
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

// 10-bit Huffman codes (RFC 7541 Appendix B)
fn int lookup_huffman_10bit(uint code) {
    switch (code) {
        case 0x3f8: return '!';   // 1111111000
        case 0x3f9: return '"';   // 1111111001
        case 0x3fa: return '(';   // 1111111010
        case 0x3fb: return ')';   // 1111111011
        case 0x3fc: return '?';   // 1111111100
        default: return -1;
    }
}

// 11-bit Huffman codes
fn int lookup_huffman_11bit(uint code) {
    switch (code) {
        case 0x7fa: return '\'';  // 11111111010
        case 0x7fb: return '+';   // 11111111011
        case 0x7fc: return '|';   // 11111111100
        default: return -1;
    }
}

// 12-bit Huffman codes
fn int lookup_huffman_12bit(uint code) {
    switch (code) {
        case 0xffa: return '#';   // 111111111010
        case 0xffb: return '>';   // 111111111011
        default: return -1;
    }
}

// 13-bit Huffman codes
fn int lookup_huffman_13bit(uint code) {
    switch (code) {
        case 0x1ff8: return 0;    // NUL: 1111111111000
        case 0x1ff9: return '$';  // 1111111111001
        case 0x1ffa: return '@';  // 1111111111010
        case 0x1ffb: return '[';  // 1111111111011
        case 0x1ffc: return ']';  // 1111111111100
        case 0x1ffd: return '~';  // 1111111111101
        default: return -1;
    }
}

// 14-bit Huffman codes
fn int lookup_huffman_14bit(uint code) {
    switch (code) {
        case 0x3ffc: return '^';  // 11111111111100
        case 0x3ffd: return '}';  // 11111111111101
        default: return -1;
    }
}

// 15-bit Huffman codes
fn int lookup_huffman_15bit(uint code) {
    switch (code) {
        case 0x7ffc: return '<';  // 111111111111100
        case 0x7ffd: return '`';  // 111111111111101
        case 0x7ffe: return '{';  // 111111111111110
        default: return -1;
    }
}

// 19-bit Huffman codes
fn int lookup_huffman_19bit(uint code) {
    switch (code) {
        case 0x7fff0: return '\\';  // 92
        case 0x7fff1: return 195;   // Latin-1 supplement
        case 0x7fff2: return 208;   // Latin-1 supplement
        default: return -1;
    }
}

// 20-bit Huffman codes
fn int lookup_huffman_20bit(uint code) {
    switch (code) {
        case 0xfffe6: return 128;
        case 0xfffe7: return 130;
        case 0xfffe8: return 131;
        case 0xfffe9: return 162;
        case 0xfffea: return 184;
        case 0xfffeb: return 194;
        case 0xfffec: return 224;
        case 0xfffed: return 226;
        default: return -1;
    }
}

// 21-bit Huffman codes
fn int lookup_huffman_21bit(uint code) {
    switch (code) {
        case 0x1fffdc: return 153;
        case 0x1fffdd: return 161;
        case 0x1fffde: return 167;
        case 0x1fffdf: return 172;
        case 0x1fffe0: return 176;
        case 0x1fffe1: return 177;
        case 0x1fffe2: return 179;
        case 0x1fffe3: return 209;
        case 0x1fffe4: return 216;
        case 0x1fffe5: return 217;
        case 0x1fffe6: return 227;
        case 0x1fffe7: return 229;
        case 0x1fffe8: return 230;
        default: return -1;
    }
}

// 22-bit Huffman codes
fn int lookup_huffman_22bit(uint code) {
    switch (code) {
        case 0x3fffd2: return 129;
        case 0x3fffd3: return 132;
        case 0x3fffd4: return 133;
        case 0x3fffd5: return 134;
        case 0x3fffd6: return 136;
        case 0x3fffd7: return 146;
        case 0x3fffd8: return 154;
        case 0x3fffd9: return 156;
        case 0x3fffda: return 160;
        case 0x3fffdb: return 163;
        case 0x3fffdc: return 164;
        case 0x3fffdd: return 169;
        case 0x3fffde: return 170;
        case 0x3fffdf: return 173;
        case 0x3fffe0: return 178;
        case 0x3fffe1: return 181;
        case 0x3fffe2: return 185;
        case 0x3fffe3: return 186;
        case 0x3fffe4: return 187;
        case 0x3fffe5: return 189;
        case 0x3fffe6: return 190;
        case 0x3fffe7: return 196;
        case 0x3fffe8: return 198;
        case 0x3fffe9: return 228;
        case 0x3fffea: return 232;
        case 0x3fffeb: return 233;
        default: return -1;
    }
}

// 23-bit Huffman codes
fn int lookup_huffman_23bit(uint code) {
    switch (code) {
        case 0x7fffd8: return 1;
        case 0x7fffd9: return 135;
        case 0x7fffda: return 137;
        case 0x7fffdb: return 138;
        case 0x7fffdc: return 139;
        case 0x7fffdd: return 140;
        case 0x7fffde: return 141;
        case 0x7fffdf: return 143;
        case 0x7fffe0: return 147;
        case 0x7fffe1: return 149;
        case 0x7fffe2: return 150;
        case 0x7fffe3: return 151;
        case 0x7fffe4: return 152;
        case 0x7fffe5: return 155;
        case 0x7fffe6: return 157;
        case 0x7fffe7: return 158;
        case 0x7fffe8: return 165;
        case 0x7fffe9: return 166;
        case 0x7fffea: return 168;
        case 0x7fffeb: return 174;
        case 0x7fffec: return 175;
        case 0x7fffed: return 180;
        case 0x7fffee: return 182;
        case 0x7fffef: return 183;
        case 0x7ffff0: return 188;
        case 0x7ffff1: return 191;
        case 0x7ffff2: return 197;
        case 0x7ffff3: return 231;
        case 0x7ffff4: return 239;
        default: return -1;
    }
}

// 24-bit Huffman codes
fn int lookup_huffman_24bit(uint code) {
    switch (code) {
        case 0xffffea: return 9;
        case 0xffffeb: return 142;
        case 0xffffec: return 144;
        case 0xffffed: return 145;
        case 0xffffee: return 148;
        case 0xffffef: return 159;
        case 0xfffff0: return 171;
        case 0xfffff1: return 206;
        case 0xfffff2: return 215;
        case 0xfffff3: return 225;
        case 0xfffff4: return 236;
        case 0xfffff5: return 237;
        default: return -1;
    }
}

// 25-bit Huffman codes
fn int lookup_huffman_25bit(uint code) {
    switch (code) {
        case 0x1ffffec: return 199;
        case 0x1ffffed: return 207;
        case 0x1ffffee: return 234;
        case 0x1ffffef: return 235;
        default: return -1;
    }
}

// 26-bit Huffman codes
fn int lookup_huffman_26bit(uint code) {
    switch (code) {
        case 0x3ffffe0: return 192;
        case 0x3ffffe1: return 193;
        case 0x3ffffe2: return 200;
        case 0x3ffffe3: return 201;
        case 0x3ffffe4: return 202;
        case 0x3ffffe5: return 205;
        case 0x3ffffe6: return 210;
        case 0x3ffffe7: return 213;
        case 0x3ffffe8: return 218;
        case 0x3ffffe9: return 219;
        case 0x3ffffea: return 238;
        case 0x3ffffeb: return 240;
        case 0x3ffffec: return 242;
        case 0x3ffffed: return 243;
        case 0x3ffffee: return 255;
        default: return -1;
    }
}

// 27-bit Huffman codes
fn int lookup_huffman_27bit(uint code) {
    switch (code) {
        case 0x7ffffde: return 203;
        case 0x7ffffdf: return 204;
        case 0x7ffffe0: return 211;
        case 0x7ffffe1: return 212;
        case 0x7ffffe2: return 214;
        case 0x7ffffe3: return 221;
        case 0x7ffffe4: return 222;
        case 0x7ffffe5: return 223;
        case 0x7ffffe6: return 241;
        case 0x7ffffe7: return 244;
        case 0x7ffffe8: return 245;
        case 0x7ffffe9: return 246;
        case 0x7ffffea: return 247;
        case 0x7ffffeb: return 248;
        case 0x7ffffec: return 250;
        case 0x7ffffed: return 251;
        case 0x7ffffee: return 252;
        case 0x7ffffef: return 253;
        case 0x7fffff0: return 254;
        default: return -1;
    }
}

// 28-bit Huffman codes
fn int lookup_huffman_28bit(uint code) {
    switch (code) {
        case 0xfffffe2: return 2;
        case 0xfffffe3: return 3;
        case 0xfffffe4: return 4;
        case 0xfffffe5: return 5;
        case 0xfffffe6: return 6;
        case 0xfffffe7: return 7;
        case 0xfffffe8: return 8;
        case 0xfffffe9: return 11;
        case 0xfffffea: return 12;
        case 0xfffffeb: return 14;
        case 0xfffffec: return 15;
        case 0xfffffed: return 16;
        case 0xfffffee: return 17;
        case 0xfffffef: return 18;
        case 0xffffff0: return 19;
        case 0xffffff1: return 20;
        case 0xffffff2: return 21;
        case 0xffffff3: return 23;
        case 0xffffff4: return 24;
        case 0xffffff5: return 25;
        case 0xffffff6: return 26;
        case 0xffffff7: return 27;
        case 0xffffff8: return 28;
        case 0xffffff9: return 29;
        case 0xffffffa: return 30;
        case 0xffffffb: return 31;
        case 0xffffffc: return 127;
        case 0xffffffd: return 220;
        case 0xffffffe: return 249;
        default: return -1;
    }
}

// 30-bit Huffman codes
fn int lookup_huffman_30bit(uint code) {
    switch (code) {
        case 0x3ffffffc: return 10;
        case 0x3ffffffd: return 13;
        case 0x3ffffffe: return 22;
        // 0x3fffffff is EOS - handled separately
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
