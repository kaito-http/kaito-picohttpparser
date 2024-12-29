module picohttpparser

pub fn test_parses_a_simple_get_request() {
	mut req := Request{}
	parsed := req.parse_request('GET / HTTP/1.1\r\nHost: example.com\r\n\r\n') or {
		assert false, 'error while parse request: ${err}'
		0
	}

	assert parsed == 37
	assert req.method == 'GET'
	assert req.path == '/'
	assert req.headers[0].name == 'Host'
	assert req.headers[0].value == 'example.com'
}

pub fn test_parses_multiple_headers() {
	mut req := Request{}
	parsed := req.parse_request('GET /foo?bar=baz HTTP/1.1\r\nHeader1: value1\r\nHeader2: value2\r\n\r\n') or {
		assert false, 'error while parse request: ${err}'
		0
	}
	assert parsed == 63
	assert req.headers[1].name == 'Header2'
	assert req.headers[1].value == 'value2'
}

pub fn test_parses_requests_with_bodies() {
	mut req := Request{}
	request := 'POST /data HTTP/1.1\r\nContent-Length: 8\r\n\r\nsomedata'
	parsed := req.parse_request(request) or {
		assert false, 'error while parse request: ${err}'
		0
	}
	assert parsed > 0
	assert req.method == 'POST'
	assert req.path == '/data'
	
	// Setup mock socket with the body data
	mut socket := &MockSocket{
		data: 'somedata'.bytes()
	}
	
	// Create body reader
	reader := req.create_body_reader(int(socket)) or {
		assert false, 'Failed to create body reader'
		return
	}
	
	// Read the body
	mut buf := []u8{len: 8}
	n := reader.read(mut buf) or {
		assert false, 'Failed to read body: ${err}'
		return
	}
	assert n == 8
	assert buf[..8] == 'somedata'.bytes()
}

pub fn test_handles_empty_requests() {
	mut req := Request{}
	parsed := req.parse_request('') or {
		assert false, 'error while parse request: ${err}'
		0
	}
	assert parsed == -2
}

pub fn test_handles_incomplete_requests() {
	mut req := Request{}
	partial_parsed := req.parse_request('GET /partial') or {
		assert false, 'error while parse request: ${err}'
		0
	}
	assert partial_parsed == -2
	assert req.prev_len == 0

	remaining_parsed := req.parse_request(' HTTP/1.1\r\n\r\n') or {
		assert err.msg() == 'error parsing request: invalid character "13"'
		0
	}
	assert remaining_parsed == 0
	assert req.method == ''
	assert req.path == ''
}

pub fn test_create_body_reader() {
	mut req := Request{}
	
	// Test with Content-Length header
	req.headers[0].name = 'Content-Length'
	req.headers[0].value = '10'
	req.num_headers = 1
	
	reader := req.create_body_reader(1) or {
		assert false, 'Failed to create body reader'
		return
	}
	assert reader.size() or { u64(0) } == u64(10)
	
	// Test with chunked encoding
	mut req2 := Request{}
	req2.headers[0].name = 'Transfer-Encoding'
	req2.headers[0].value = 'chunked'
	req2.num_headers = 1
	
	reader2 := req2.create_body_reader(1) or {
		assert false, 'Failed to create body reader'
		return
	}
	assert reader2.size() or { u64(0) } == u64(0)
	
	// Test with no body headers
	mut req3 := Request{}
	reader3 := req3.create_body_reader(1) or {
		// Expected to fail
		assert true
		return
	}
	assert false, 'Should not create reader without body headers'
}

pub fn test_get_body_reader() {
	mut req := Request{}
	
	// Test with Content-Length header
	req.headers[0].name = 'Content-Length'
	req.headers[0].value = '10'
	req.num_headers = 1
	
	// First call should create a new reader
	reader1 := req.get_body_reader(1) or {
		assert false, 'Failed to get body reader'
		return
	}
	assert reader1.size() or { u64(0) } == u64(10)
	
	// Second call should return the same reader
	reader2 := req.get_body_reader(1) or {
		assert false, 'Failed to get body reader'
		return
	}
	assert reader2 == reader1
	
	// Test with no body headers
	mut req2 := Request{}
	reader3 := req2.get_body_reader(1) or {
		// Expected to fail
		assert true
		return
	}
	assert false, 'Should not create reader without body headers'
}

// Mock socket for testing
struct MockSocket {
mut:
	data     []u8
	position int
}

fn mock_read(fd int, buf voidptr, count usize) int {
	mut socket := &MockSocket(fd)
	remaining := socket.data.len - socket.position
	if remaining == 0 {
		return 0 // EOF
	}
	
	to_read := if remaining > int(count) { int(count) } else { remaining }
	unsafe {
		vmemcpy(buf, &socket.data[socket.position], to_read)
	}
	socket.position += to_read
	return to_read
}

pub fn test_stream_body_reader() {
	// Setup mock socket with chunked data
	mut socket := &MockSocket{
		data: '5\r\nhello\r\n0\r\n\r\n'.bytes()
	}
	
	mut reader := StreamBodyReader{
		fd: int(socket)
		chunked: true
		chunk_size: -1
		buffer: []u8{len: 1024}
	}
	
	// Read first chunk
	mut buf := []u8{len: 10}
	n := reader.read(mut buf) or {
		assert false, 'Failed to read chunk: ${err}'
		return
	}
	assert n == 5
	assert buf[..5] == 'hello'.bytes()
	
	// Try reading after end
	n2 := reader.read(mut buf) or {
		// Expected EOF
		assert true
		return
	}
	assert false, 'Should return none at end of stream'
}

pub fn test_chunked_upload_request() {
	// Create a mock request with chunked encoding
	mut req := Request{}
	request_headers := 'POST /upload HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n'
	parsed := req.parse_request(request_headers) or {
		assert false, 'error while parse request: ${err}'
		0
	}
	assert parsed > 0
	assert req.method == 'POST'
	assert req.path == '/upload'
	
	// Setup mock socket with chunked data
	// Format: 5\r\nhello\r\n7\r\nworld!!\r\n0\r\n\r\n
	mut socket := &MockSocket{
		data: '5\r\nhello\r\n7\r\nworld!!\r\n0\r\n\r\n'.bytes()
	}
	
	// Create body reader
	reader := req.create_body_reader(int(socket)) or {
		assert false, 'Failed to create body reader'
		return
	}
	
	// Read chunks
	mut total_data := []u8{}
	mut buf := []u8{len: 1024}
	
	for {
		bytes_read := reader.read(mut buf) or {
			// EOF reached
			break
		}
		total_data << buf[..bytes_read]
	}
	
	// Verify the complete data
	assert total_data.len == 12
	assert unsafe { tos(total_data.data, total_data.len) } == 'helloworld!!'
}

pub fn test_content_length_upload_request() {
	// Create a mock request with Content-Length
	mut req := Request{}
	request_headers := 'POST /upload HTTP/1.1\r\nContent-Length: 12\r\n\r\n'
	parsed := req.parse_request(request_headers) or {
		assert false, 'error while parse request: ${err}'
		0
	}
	assert parsed > 0
	assert req.method == 'POST'
	assert req.path == '/upload'
	
	// Setup mock socket with fixed length data
	mut socket := &MockSocket{
		data: 'Hello World!'.bytes()
	}
	
	// Create body reader
	reader := req.create_body_reader(int(socket)) or {
		assert false, 'Failed to create body reader'
		return
	}
	
	// Verify content length
	content_length := reader.size() or { u64(0) }
	assert content_length == 12
	
	// Read data in smaller chunks
	mut total_data := []u8{}
	mut buf := []u8{len: 5} // Small buffer to test multiple reads
	
	for {
		bytes_read := reader.read(mut buf) or {
			// EOF reached
			break
		}
		total_data << buf[..bytes_read]
	}
	
	// Verify the complete data
	assert total_data.len == 12
	assert unsafe { tos(total_data.data, total_data.len) } == 'Hello World!'
}
