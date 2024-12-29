module picohttpparser

$if !windows {
	#include <sys/socket.h>
}

pub interface StreamWriter {
	write(mut buf []u8) ?int
	size() ?u64
}

pub struct Response {
pub:
	fd        int
	date      &u8 = unsafe { nil }
	buf_start &u8 = unsafe { nil }
pub mut:
	buf &u8 = unsafe { nil }
}

@[inline]
pub fn (mut r Response) write_string(s string) {
	unsafe {
		vmemcpy(r.buf, s.str, s.len)
		r.buf += s.len
	}
}

@[inline]
pub fn (mut r Response) header(k string, v string) &Response {
	eprintln('Writing header ${k}: ${v}')
	r.write_string(k)
	r.write_string(': ')
	r.write_string(v)
	r.write_string('\r\n')
	return unsafe { r }
}

@[inline]
pub fn (mut r Response) body(body string) {
	eprintln('Writing body of length ${body.len}')
	// Write Content-Length header
	r.write_string('Content-Length: ')
	unsafe {
		r.buf += u64toa(r.buf, u64(body.len)) or { panic(err) }
	}
	r.write_string('\r\n')
	// End headers section
	r.write_string('\r\n')
	// Write body
	r.write_string(body)
	eprintln('Finished writing body')
}

@[inline]
pub fn (mut r Response) status(status int) {
	eprintln('Writing status ${status}')
	r.write_string('HTTP/1.1 ${status} ${status_text(status)}\r\n')
	// Add Date header by default
	if !isnil(r.date) {
		r.write_string('Date: ')
		unsafe { 
			r.write_string(tos(r.date, 29))
			r.write_string('\r\n')
		}
	}
}

@[inline]
pub fn (mut r Response) body_stream(mut stream StreamWriter) ? {
	// If stream provides size, we can set Content-Length	
	if size := stream.size() {
		r.write_string('Content-Length: ')
		unsafe {
			r.buf += u64toa(r.buf, size) or { panic(err) }
		}
		r.write_string('\r\n\r\n')

		mut buffer := []u8{len: 8192}
		for {
			bytes_read := stream.write(mut buffer) or { break }
			if bytes_read <= 0 {
				break
			}
			unsafe {
				vmemcpy(r.buf, &buffer[0], bytes_read)
				r.buf += bytes_read
			}
		}
	} else {
		// If size is unknown, use chunked transfer encoding
		r.write_string('Transfer-Encoding: chunked\r\n\r\n')

		mut buffer := []u8{len: 8192}
		for {
			bytes_read := stream.write(mut buffer) or { break }
			if bytes_read <= 0 {
				break
			}

			// Write chunk size
			unsafe {
				chunk_size := u64toa(r.buf, u64(bytes_read)) or { panic(err) }
				r.buf += chunk_size
				r.write_string('\r\n')

				// Write chunk data
				vmemcpy(r.buf, &buffer[0], bytes_read)
				r.buf += bytes_read
				r.write_string('\r\n')
			}
		}

		// Write final chunk
		r.write_string('0\r\n\r\n')
	}
}

fn C.send(sockfd int, buf voidptr, len usize, flags int) int

@[inline]
pub fn (mut r Response) end() int {
	n := unsafe { r.buf - r.buf_start }
	eprintln('Attempting to send ${n} bytes')
	if n <= 0 {
		eprintln('No bytes to send')
		return 0
	}
	
	// Debug: print the response buffer
	response_str := unsafe { tos(r.buf_start, n) }
	eprintln('Response buffer:\n${response_str}')
	
	mut total_sent := 0
	for total_sent < n {
		sent := C.send(r.fd, unsafe { r.buf_start + total_sent }, n - total_sent, 0)
		if sent <= 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				eprintln('Would block, retrying...')
				// Would block, try again after a tiny sleep to prevent CPU spin
				C.usleep(1000) // 1ms sleep
				continue
			}
			// Real error
			eprintln('send() error: ${C.errno}')
			return -1
		}
		total_sent += sent
		eprintln('Sent ${sent} bytes, total ${total_sent}/${n}')
	}
	eprintln('Successfully sent all ${n} bytes')
	return total_sent
}
