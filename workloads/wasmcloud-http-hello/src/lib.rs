use wasmcloud_component::http;

struct Component;

http::export!(Component);

static mut COUNTER: u64 = 0;

impl http::Server for Component {
    fn handle(
        request: http::IncomingRequest,
    ) -> http::Result<http::Response<impl http::OutgoingBody>> {
        let path = request.uri().path();
        let body = if path.starts_with("/state") {
            let next = unsafe {
                // wasm components are single-threaded in this benchmark
                COUNTER += 1;
                COUNTER
            };
            next.to_string()
        } else {
            "hello".to_string()
        };

        Ok(http::Response::new(body))
    }
}
