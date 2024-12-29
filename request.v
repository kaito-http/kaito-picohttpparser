module picohttpparser

import strconv

$if !windows {
	#include <unistd.h>
} $else {
	#include <io.h>
}

fn C.read(fd int, buf voidptr, count usize) int

const max_headers = 100

pub struct Header {
pub mut:
	name  string
	value string
}


// StreamBodyReader implements BodyReader for streaming request bodies
pub struct StreamBodyReader {
pub mut:
	fd              int    // socket file descriptor
	content_length  ?u64   // content length if known
	bytes_read      u64    // number of bytes read so far
	chunked         bool   // whether transfer encoding is chunked
	chunk_size      int    // current chunk size (-1 if not reading chunk)
	chunk_bytes_read int   // bytes read in current chunk
	buffer          []u8   // internal buffer for chunk headers etc
}

pub struct Request {
pub mut:
	prev_len int
	body_reader ?&StreamBodyReader // Optional body reader for streaming
	method      string
	path        string
	headers     [max_headers]Header
	num_headers int
	fd          int
}

// Pret contains the nr of bytes read, a negative number indicates an error
struct Pret {
pub mut:
	err string
	// -1 indicates a parse error and -2 means the request is parsed
	ret int
}

// parse_request parses a raw HTTP request and returns the number of bytes read.
// -1 indicates a parse error and -2 means the request is parsed
@[inline]
pub fn (mut r Request) parse_request(s string) !int {
	mut buf := s.str
	buf_end := unsafe { s.str + s.len }

	mut pret := Pret{}

	// if prev_len != 0, check if the request is complete
	// (a fast countermeasure against slowloris)
	if r.prev_len != 0 && unsafe { is_complete(buf, buf_end, r.prev_len, mut pret) == nil } {
		if pret.ret == -1 {
			return error(pret.err)
		}

		return pret.ret
	}

	buf = r.phr_parse_request(buf, buf_end, mut pret)
	if pret.ret == -1 {
		return error(pret.err)
	}

	if unsafe { buf == nil } {
		return pret.ret
	}

	pret.ret = unsafe { buf - s.str }
	r.prev_len = s.len

	// return nr of bytes
	return pret.ret
}

// get_body_reader returns the current body reader or creates one if needed
pub fn (r Request) get_body_reader(fd int) ?&StreamBodyReader {
	// if r.body_reader != none {
	// 	return r.body_reader
	// }
	reader := r.create_body_reader(fd)?
	// r.body_reader = reader
	return reader
}

// create_body_reader creates a new StreamBodyReader for the request
pub fn (r Request) create_body_reader(fd int) ?&StreamBodyReader {
	mut content_length := ?u64(none)
	mut is_chunked := false

	// Look for Content-Length or Transfer-Encoding headers
	for i := 0; i < r.num_headers; i++ {
		if r.headers[i].name.to_lower() == 'content-length' {
			content_length = r.headers[i].value.u64()
		} else if r.headers[i].name.to_lower() == 'transfer-encoding' && 
			r.headers[i].value.to_lower() == 'chunked' {
			is_chunked = true
		}
	}

	if content_length == none && !is_chunked {
		return none
	}

	mut reader := &StreamBodyReader{
		fd: fd
		content_length: content_length
		chunked: is_chunked
		chunk_size: -1
		buffer: []u8{len: 1024} // Buffer for chunk headers etc
	}

	return reader
}

// read implements BodyReader.read
pub fn (r &StreamBodyReader) read(mut buf []u8) !int {
	mut reader := unsafe { &StreamBodyReader(r) }
	if reader.chunked {
		return reader.read_chunked(mut buf)
	}

	// For Content-Length bodies
	if content_length := reader.content_length {
		remaining := content_length - reader.bytes_read
		if remaining == 0 {
			return -1 // EOF
		}

		// Read up to remaining bytes
		max_read := if remaining > u64(buf.len) { buf.len } else { int(remaining) }
		bytes_read := unsafe { C.read(reader.fd, &buf[0], max_read) }
		if bytes_read <= 0 {
			return error('Socket read error')
		}

		reader.bytes_read += u64(bytes_read)
		return bytes_read
	}

	return error('No content length or chunked encoding')
}

pub fn (mut r StreamBodyReader) read_all() ![]u8 {
	mut total_data := []u8{}
	mut buf := []u8{len: 1024}
	for {
		n := r.read(mut buf) or {
			return error('Failed to read body')
		}
		total_data << buf[..n]
		if n == -1 {
			break
		}
	}
	return total_data
}

// read_chunked reads the next chunk of data for chunked transfer encoding
fn (mut r StreamBodyReader) read_chunked(mut buf []u8) !int {
	if r.chunk_size == 0 {
		return -1 // EOF
	}

	if r.chunk_size == -1 {
		// Need to read next chunk header
		mut header := []u8{len: 32}
		mut pos := 0
		
		// Read until CRLF
		for pos < header.len {
			n := unsafe { C.read(r.fd, &header[pos], 1) }
			if n <= 0 {
				return error('Socket read error')
			}
			if pos > 0 && header[pos-1] == `\r` && header[pos] == `\n` {
				break
			}
			pos++
		}

		// Parse chunk size
		chunk_header := unsafe { tos(&header[0], pos-1) } // Exclude CRLF
		size := int(strconv.parse_int(chunk_header.trim_space(), 16, 32)!)
		r.chunk_size = size
		r.chunk_bytes_read = 0

		if r.chunk_size == 0 {
			// Read final CRLF
			mut crlf := []u8{len: 2}
			if unsafe { C.read(r.fd, &crlf[0], 2) } != 2 {
				return error('Socket read error')
			}
			return -1 // EOF
		}
	}

	// Read chunk data
	remaining := r.chunk_size - r.chunk_bytes_read
	max_read := if remaining > buf.len { buf.len } else { remaining }
	
	bytes_read := unsafe { C.read(r.fd, &buf[0], max_read) }
	if bytes_read <= 0 {
		return error('Socket read error')
	}

	r.chunk_bytes_read += bytes_read
	if r.chunk_bytes_read == r.chunk_size {
		// Read chunk's trailing CRLF
		mut crlf := []u8{len: 2}
		if unsafe { C.read(r.fd, &crlf[0], 2) } != 2 {
			return error('Socket read error')
		}
		r.chunk_size = -1 // Ready for next chunk
	}

	return bytes_read
}

// size implements BodyReader.size
pub fn (r &StreamBodyReader) size() ?u64 {
	return r.content_length
}

// close implements BodyReader.close
pub fn (r &StreamBodyReader) close() {
	// Nothing to do as fd is managed by picoev
}
