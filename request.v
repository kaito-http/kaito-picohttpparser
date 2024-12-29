module picohttpparser

const max_headers = 100

pub struct Header {
pub mut:
	name  string
	value string
}

pub struct Request {
mut:
	prev_len int
pub mut:
	fd          int // socket file descriptor
	method      string
	path        string
	headers     [max_headers]Header
	num_headers int
	body        string
	body_reader &BodyReader = unsafe { nil }
}

// get_header returns the value of the specified header
pub fn (r &Request) get_header(name string) ?string {
	name_lower := name.to_lower()
	for i := 0; i < r.num_headers; i++ {
		if r.headers[i].name.to_lower() == name_lower {
			return r.headers[i].value
		}
	}
	return none
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

	r.body = unsafe { (&s.str[pret.ret]).vstring_literal_with_len(s.len - pret.ret) }
	r.prev_len = s.len

	// return nr of bytes
	return pret.ret
}

// parse_request_path sets the `path` and `method` fields
@[inline]
pub fn (mut r Request) parse_request_path(s string) !int {
	mut buf := s.str
	buf_end := unsafe { s.str + s.len }

	mut pret := Pret{}
	r.phr_parse_request_path(buf, buf_end, mut pret)
	if pret.ret == -1 {
		return error(pret.err)
	}

	return pret.ret
}

// parse_request_path_pipeline can parse the `path` and `method` of HTTP/1.1 pipelines.
// Call it again to parse the next request
@[inline]
pub fn (mut r Request) parse_request_path_pipeline(s string) !int {
	mut buf := unsafe { s.str + r.prev_len }
	buf_end := unsafe { s.str + s.len }

	mut pret := Pret{}
	r.phr_parse_request_path_pipeline(buf, buf_end, mut pret)
	if pret.ret == -1 {
		return error(pret.err)
	}

	if pret.ret > 0 {
		r.prev_len = pret.ret
	}
	return pret.ret
}

// get_body_reader returns the BodyReader if available
pub fn (r &Request) get_body_reader() ?&BodyReader {
	if r.body_reader == unsafe { nil } {
		return none
	}
	return r.body_reader
}

// client_wants_keep_alive returns true if the client wants to keep the connection alive
pub fn (r &Request) client_wants_keep_alive() bool {
	if connection := r.get_header('connection') {
		return connection.to_lower() != 'close'
	}
	// Default to keep-alive for HTTP/1.1
	return true
}