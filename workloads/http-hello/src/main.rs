use std::str::FromStr;
use std::thread;
use tiny_http::{Header, Response, Server};

fn main() {
    // Bind HTTP server
    let server = Server::http("0.0.0.0:8080").expect("failed to bind 0.0.0.0:8080");

    println!("[http-hello] listening on http://0.0.0.0:8080");

    // Handle incoming requests forever
    for request in server.incoming_requests() {
        let url = request.url().to_string();
        let method = request.method().as_str().to_string();

        // Explicitly build a tiny_http::Header
        let content_type =
            Header::from_str("Content-Type: text/plain; charset=utf-8").expect("invalid header");

        let response = Response::from_string("hello").with_header(content_type);

        // Offload response to a short-lived thread so we don't block the loop
        thread::spawn(move || {
            if let Err(e) = request.respond(response) {
                eprintln!("[http-hello] error responding to {} {}: {}", method, url, e);
            }
        });
    }
}
