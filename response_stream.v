module picohttpparser

// flush writes any buffered data to the socket
pub fn (mut r Response) flush() ! {
	mut total := unsafe { usize(r.buf) - usize(r.buf_start) }
	if total == 0 {
		return
	}

	mut sent_bytes := usize(0)
	unsafe {
		// Loop until all data is sent or we get an error
		for sent_bytes < total {
			remaining := total - sent_bytes
			s := C.send(r.fd, r.buf_start + sent_bytes, remaining, 0)
			if s < 0 {
				if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
					// Non-fatal, try again
					C.usleep(1000) // Small sleep to prevent CPU spin
					continue
				}
				return error('send() failed')
			}
			if s == 0 {
				return error('socket closed during write')
			}
			sent_bytes += usize(s)
		}
		// Reset buffer after successful send
		r.buf = r.buf_start
	}
}

// stream_start initiates a chunked transfer response
pub fn (mut r Response) stream_start() ! {
	r.write_string('HTTP/1.1 200 OK\r\n')
	if !isnil(r.date) {
		r.write_string('Date: ')
		unsafe { r.write_string(tos(r.date, 29)) }
		r.write_string('\r\n')
	}
	r.write_string('Transfer-Encoding: chunked\r\n\r\n')
	r.flush()!
}

// stream_chunk writes one chunk of data in chunked format
pub fn (mut r Response) stream_chunk(data string) ! {
	// Write chunk size in hex
	chunk_size_hex := data.len.hex()
	r.write_string(chunk_size_hex)
	r.write_string('\r\n')

	// Write chunk data
	r.write_string(data)
	r.write_string('\r\n')

	// Flush immediately
	r.flush()!
}

// stream_end writes the final zero-size chunk and flushes
pub fn (mut r Response) stream_end() ! {
	r.write_string('0\r\n\r\n')
	r.flush()!
} 