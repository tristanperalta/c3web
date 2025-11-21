/**
 * UTF-8 Validator for WebSocket
 *
 * RFC 3629 compliant UTF-8 validation using DFA (Deterministic Finite Automaton).
 * Required by RFC 6455 §8.1 for WebSocket text frames.
 *
 * Implementation based on Bjoern Hoehrmann's UTF-8 DFA decoder (public domain):
 * http://bjoern.hoehrmann.de/utf-8/decoder/dfa/
 *
 * Validates:
 * - 1-4 byte UTF-8 sequences
 * - Rejects overlong encodings (security)
 * - Rejects surrogates (U+D800-U+DFFF)
 * - Rejects code points > U+10FFFF
 * - Supports streaming/incremental validation
 */
module c3web::websocket::utf8;

// UTF-8 DFA states
const char UTF8_ACCEPT = 0;
const char UTF8_REJECT = 12;

// UTF-8 character class lookup table (256 entries)
// Maps each byte to its character class for DFA transitions
const char[256] UTF8_CHAR_CLASS = {
    // 00-7F: ASCII (single byte)
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,

    // 80-BF: Continuation bytes
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,  7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,

    // C0-C1: Invalid (overlong encoding of ASCII)
    8,8,
    // C2-DF: 2-byte sequence lead
    2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,  2,2,2,2,2,2,2,2,2,2,2,2,2,2,

    // E0-EF: 3-byte sequence lead
    10,3,3,3,3,3,3,3,3,3,3,3,3,4,3,3,

    // F0-F4: 4-byte sequence lead
    11,6,6,6,5,
    // F5-FF: Invalid (would encode > U+10FFFF)
    8,8,8,8,8,8,8,8,8,8,8
};

// UTF-8 DFA state transition table (108 entries = 12 states * 9 character classes)
// Given current state and character class, determines next state
const char[108] UTF8_TRANSITIONS = {
    // State 0 (ACCEPT): Expecting start of new sequence
    0,12,24,36,60,96,84,12,12,12,48,72,  // Classes 0-11
    // State 12 (REJECT): Invalid sequence
    12,12,12,12,12,12,12,12,12,12,12,12,
    // State 24: Expecting 1 more byte
    12, 0,12,12,12,12,12, 0,12, 0,12,12,
    // State 36: Expecting 2 more bytes (normal 3-byte)
    12,24,12,12,12,12,12,24,12,24,12,12,
    // State 48: Expecting 2 more bytes (3-byte starting with E0)
    12,12,12,12,12,12,12,24,12,12,12,12,
    // State 60: Expecting 1 more byte (after 3-byte E0 lead)
    12,24,12,12,12,12,12,12,12,24,12,12,
    // State 72: Expecting 3 more bytes (4-byte starting with F0)
    // F0 requires second byte 90-BF (classes 7, 9) to avoid overlong
    12,12,12,12,12,12,12,36,12,36,12,12,
    // State 84: Expecting 3 more bytes (4-byte starting with F1-F3)
    // F1-F3 accept second byte 80-BF (classes 1, 7, 9)
    12,36,12,12,12,12,12,36,12,36,12,12,
    // State 96: Expecting 2 more bytes (4-byte starting with F4)
    // F4 requires second byte 80-8F (class 1 only) to stay within U+10FFFF
    12,36,12,12,12,12,12,12,12,12,12,12
};

/**
 * UTF-8 Validator with DFA state tracking
 */
struct Utf8Validator
{
    char state;          // Current DFA state (UTF8_ACCEPT or intermediate)
    uint codepoint;      // Accumulated code point value
}

/**
 * Initialize validator to ACCEPT state
 */
fn void Utf8Validator.init(&self) @public
{
    self.state = UTF8_ACCEPT;
    self.codepoint = 0;
}

/**
 * Validate UTF-8 data incrementally
 *
 * Can be called multiple times with chunks of data. Maintains state
 * across calls, allowing multi-byte sequences to span chunk boundaries.
 *
 * @param data - Chunk of bytes to validate
 * @return true if valid so far, false if invalid UTF-8 detected
 */
fn bool Utf8Validator.validate_incremental(&self, char[] data) @public
{
    foreach (byte : data)
    {
        // Get character class for this byte
        char type = UTF8_CHAR_CLASS[byte];

        // Accumulate code point
        if (self.state != UTF8_ACCEPT)
        {
            // Continuation byte: add 6 bits
            self.codepoint = (byte & 0x3F) | (self.codepoint << 6);
        }
        else
        {
            // Lead byte: initialize code point
            self.codepoint = (0xFF >> type) & byte;
        }

        // Transition to next state
        self.state = UTF8_TRANSITIONS[self.state + type];

        // Check for rejection
        if (self.state == UTF8_REJECT)
        {
            return false;
        }

        // When we complete a character (back to ACCEPT), validate code point
        if (self.state == UTF8_ACCEPT)
        {
            // Reject surrogate code points (U+D800 - U+DFFF)
            // RFC 3629: UTF-8 encodings of surrogates are invalid
            if (self.codepoint >= 0xD800 && self.codepoint <= 0xDFFF)
            {
                self.state = UTF8_REJECT;
                return false;
            }

            // Reject code points beyond valid Unicode range (> U+10FFFF)
            if (self.codepoint > 0x10FFFF)
            {
                self.state = UTF8_REJECT;
                return false;
            }

            // Valid character completed
            self.codepoint = 0;
        }
    }

    // No errors found in this chunk
    // Note: May be in intermediate state (incomplete sequence)
    return true;
}

/**
 * Check if validator is in complete state
 *
 * After processing all data, this should return true. If false, it means
 * a multi-byte sequence was started but not completed (incomplete UTF-8).
 *
 * @return true if in ACCEPT state (no partial sequences), false otherwise
 */
fn bool Utf8Validator.is_complete(&self) @public
{
    return self.state == UTF8_ACCEPT;
}

/**
 * Reset validator to initial state
 *
 * Use this to reuse the validator for a new message after completing
 * or aborting validation of a previous message.
 */
fn void Utf8Validator.reset(&self) @public
{
    self.state = UTF8_ACCEPT;
    self.codepoint = 0;
}
