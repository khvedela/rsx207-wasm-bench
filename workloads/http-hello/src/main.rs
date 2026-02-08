use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};
use tiny_http::{Header, Response, Server};

static COUNTER: AtomicU64 = AtomicU64::new(0);

fn main() {
    // Bind HTTP server
    let server = Server::http("0.0.0.0:8080").expect("failed to bind 0.0.0.0:8080");

    println!("[http-hello] listening on http://0.0.0.0:8080");

    // Handle incoming requests forever
    for request in server.incoming_requests() {
        // Explicitly build a tiny_http::Header
        let content_type =
            Header::from_str("Content-Type: text/plain; charset=utf-8").expect("invalid header");

        let path = request.url();
        let body = if path.starts_with("/state") {
            let next = COUNTER.fetch_add(1, Ordering::Relaxed) + 1;
            next.to_string()
        } else {
            "hello".to_string()
        };

        let response = Response::from_string(body).with_header(content_type);

        if let Err(e) = request.respond(response) {
            eprintln!("[http-hello] error responding: {}", e);
        }
    }
}
