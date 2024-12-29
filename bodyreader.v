module picohttpparser

import socket

pub struct BodyReader {
pub:
    fd             int
pub mut:
    leftover       []u8
    content_length u64
    bytes_read     u64
    chunked        bool
    closed         bool
}

// clear_leftover clears any leftover data
pub fn (mut br BodyReader) clear_leftover() {
    br.leftover.clear()
}

// set_leftover sets the leftover data
pub fn (mut br BodyReader) set_leftover(data []u8) {
    br.leftover = data.clone()
}

// is_closed returns whether the reader is closed
pub fn (br &BodyReader) is_closed() bool {
    return br.closed
}

// read_all reads the entire body from the socket until content_length is reached
pub fn (mut br BodyReader) read_all() ![]u8 {
    if br.closed {
        return []u8{} // empty if closed
    }
    mut result := []u8{}

    // First consume leftover
    if br.leftover.len > 0 {
        result << br.leftover
        br.bytes_read += u64(br.leftover.len)
        br.leftover.clear()
    }

    // Example for non-chunked:
    if !br.chunked {
        for br.bytes_read < br.content_length {
            needed := br.content_length - br.bytes_read
            mut buf := []u8{len: 8192}
            to_read := if needed < u64(buf.len) { int(needed) } else { buf.len }
            r := socket.read_socket(br.fd, buf.data, to_read, 0)
            if r == 0 {
                // socket closed
                br.closed = true
                break
            }
            if r < 0 {
                if !socket.is_fatal_error(br.fd) {
                    // EAGAIN: user can retry
                    break
                }
                return error('BodyReader read error')
            }
            result << buf[..r]
            br.bytes_read += u64(r)
        }
    } else {
        // TODO: Implement chunked transfer encoding
        return error('Chunked read not yet implemented')
    }

    return result
} 