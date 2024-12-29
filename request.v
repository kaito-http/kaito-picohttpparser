module picohttpparser

import strconv

$if !windows {
	#include <unistd.h>
	#include <errno.h>
} $else {
	#include <io.h>
	#include <winsock2.h>
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

// get_header returns the value of the specified header, or none if not found
pub fn (r Request) get_header(name string) ?string {
	lower_name := name.to_lower()
	for i := 0; i < r.num_headers; i++ {
		if r.headers[i].name.to_lower() == lower_name {
			return r.headers[i].value
		}
	}
	return none
}

// get_body_reader returns the current body reader or creates one if needed
pub fn (r Request) get_body_reader() ?&StreamBodyReader {
	return r.body_reader
}

// create_body_reader creates a new StreamBodyReader for the request
pub fn (r Request) create_body_reader(fd int) ?&StreamBodyReader {
	mut content_length := ?u64(none)
	mut is_chunked := false

	// Look for Content-Length or Transfer-Encoding headers
	if cl := r.get_header('content-length') {
		content_length = cl.u64()
	}
	if te := r.get_header('transfer-encoding') {
		is_chunked = te.to_lower() == 'chunked'
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
			return error('EOF')
		}

		// Read up to remaining bytes
		max_read := if remaining > u64(buf.len) { buf.len } else { int(remaining) }
		mut bytes_read := 0
		println('Attempting to read ${max_read} bytes, remaining: ${remaining}')
		unsafe {
			bytes_read = C.read(reader.fd, &buf[0], usize(max_read))
		}
		println('Read returned: ${bytes_read}')
		if bytes_read <= 0 {
			if bytes_read == 0 {
				return error('EOF')
			}
			// Check for non-fatal errors like EAGAIN/EWOULDBLOCK
			$if windows {
				if C.WSAGetLastError() == C.WSAEWOULDBLOCK {
					println('Got WSAEWOULDBLOCK')
					return error('EAGAIN')  // Would block, try again
				}
				println('Got WSA error: ${C.WSAGetLastError()}')
			} $else {
				if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
					println('Got EAGAIN/EWOULDBLOCK')
					return error('EAGAIN')  // Would block, try again
				}
				println('Got errno: ${C.errno}')
			}
			// Get the actual error number for better diagnostics
			$if windows {
				return error('Socket read error: WSA ${C.WSAGetLastError()}')
			} $else {
				return error('Socket read error: ${C.errno}')
			}
		}

		reader.bytes_read += u64(bytes_read)
		println('Updated bytes_read to ${reader.bytes_read}')
		return bytes_read
	}

	return error('No content length or chunked encoding')
}

// read_chunk attempts to read a single chunk of data
pub fn (mut r StreamBodyReader) read_chunk() !([]u8, bool) {
	mut buf := []u8{len: 1024}
	n := r.read(mut buf) or {
		if err.msg() == 'EAGAIN' {
			// Return empty chunk but indicate more data coming
			return []u8{}, false
		}
		if err.msg() == 'EOF' {
			// Return empty chunk and indicate we're done
			return []u8{}, true
		}
		return err
	}
	// Return the data we got and indicate more might be coming
	return buf[..n], false
}

// read_all reads the entire body, but returns partial data on EAGAIN
pub fn (mut r StreamBodyReader) read_all() ![]u8 {
	mut total_data := []u8{}
	
	for {
		chunk, done := r.read_chunk() or {
			return err
		}
		if chunk.len > 0 {
			total_data << chunk
		}
		if done {
			break
		}
	}
	
	return total_data
}

// read_chunked reads the next chunk of data for chunked transfer encoding
fn (mut r StreamBodyReader) read_chunked(mut buf []u8) !int {
	if r.chunk_size == 0 {
		return error('EOF')
	}

	if r.chunk_size == -1 {
		// Need to read next chunk header
		mut header := []u8{len: 32}
		mut pos := 0
		
		// Read until CRLF
		for pos < header.len {
			n := unsafe { C.read(r.fd, &header[pos], 1) }
			if n <= 0 {
				if n == 0 {
					return error('EOF')
				}
				return error('Socket read error 203')
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
				return error('Socket read error 221')
			}
			return error('EOF')
		}
	}

	// Read chunk data
	remaining := r.chunk_size - r.chunk_bytes_read
	max_read := if remaining > buf.len { buf.len } else { remaining }
	
	bytes_read := unsafe { C.read(r.fd, &buf[0], max_read) }
	if bytes_read <= 0 {
		if bytes_read == 0 {
			return error('EOF')
		}
		return error('Socket read error 236')
	}

	r.chunk_bytes_read += bytes_read
	if r.chunk_bytes_read == r.chunk_size {
		// Read chunk's trailing CRLF
		mut crlf := []u8{len: 2}
		if unsafe { C.read(r.fd, &crlf[0], 2) } != 2 {
			return error('Socket read error 244')
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
