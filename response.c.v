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
	r.write_string(k)
	r.write_string(': ')
	r.write_string(v)
	r.write_string('\r\n')
	return unsafe { r }
}

@[inline]
pub fn (mut r Response) body(body string) {
	r.write_string('Content-Length: ')
	unsafe {
		r.buf += u64toa(r.buf, u64(body.len)) or { panic(err) }
	}
	r.write_string('\r\n\r\n')
	r.write_string(body)
}

@[inline]
pub fn (mut r Response) status(status int) {
	r.write_string('HTTP/1.1 ${status} ${status_text(status)}\r\n')
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
	n := int(i64(r.buf) - i64(r.buf_start))
	// use send instead of write for windows compatibility
	if C.send(r.fd, r.buf_start, n, 0) != n {
		return -1
	}
	return n
}
