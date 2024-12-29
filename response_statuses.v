module picohttpparser

pub const status_map = {
	200: 'OK'
	201: 'Created'
	204: 'No Content'
	400: 'Bad Request'
	401: 'Unauthorized'
	403: 'Forbidden'
	404: 'Not Found'
	500: 'Internal Server Error'
	502: 'Bad Gateway'
	503: 'Service Unavailable'
}

pub fn status_text(status int) string {
	return status_map[status] or { 'Unknown' }
}
