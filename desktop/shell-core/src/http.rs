//! A deliberately tiny HTTP/1.1 GET client over a loopback `TcpStream`.
//!
//! The shell only ever makes two requests against its own release (a
//! readiness probe and the scheduler drain state), so a dependency-free client
//! is enough for the prototype. A production shell would use `reqwest`/`ureq`.

use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

#[derive(Debug, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub body: String,
}

/// `GET http://127.0.0.1:<port><path>`, optionally with a bearer token.
/// `Connection: close` is sent so the body is simply "read to EOF".
pub fn get(port: u16, path: &str, bearer: Option<&str>, timeout: Duration) -> io::Result<Response> {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let mut stream = TcpStream::connect_timeout(&addr, timeout)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;

    let mut req = format!(
        "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAccept: application/json\r\nConnection: close\r\n"
    );
    if let Some(token) = bearer {
        req.push_str(&format!("Authorization: Bearer {token}\r\n"));
    }
    req.push_str("\r\n");
    stream.write_all(req.as_bytes())?;

    let mut raw = Vec::new();
    // A reset after the response was fully sent is still a usable response.
    if let Err(e) = stream.read_to_end(&mut raw) {
        if raw.is_empty() {
            return Err(e);
        }
    }
    parse(&String::from_utf8_lossy(&raw))
}

fn parse(raw: &str) -> io::Result<Response> {
    let bad = |m: &str| io::Error::new(io::ErrorKind::InvalidData, m.to_string());
    let (head, body) = raw
        .split_once("\r\n\r\n")
        .ok_or_else(|| bad("no header terminator"))?;
    let status = head
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse::<u16>().ok())
        .ok_or_else(|| bad("bad status line"))?;
    Ok(Response {
        status,
        body: body.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    /// A one-shot server answering with `raw` after reading the request head.
    fn serve_once(raw: &'static str) -> (u16, thread::JoinHandle<String>) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let h = thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let mut buf = [0u8; 2048];
            let n = s.read(&mut buf).unwrap();
            s.write_all(raw.as_bytes()).unwrap();
            String::from_utf8_lossy(&buf[..n]).into_owned()
        });
        (port, h)
    }

    #[test]
    fn parses_status_and_body() {
        let (port, h) = serve_once("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi");
        let r = get(port, "/api/version", None, Duration::from_secs(2)).unwrap();
        assert_eq!(
            r,
            Response {
                status: 200,
                body: "hi".into()
            }
        );
        let req = h.join().unwrap();
        assert!(req.starts_with("GET /api/version HTTP/1.1\r\n"), "{req}");
        assert!(!req.to_lowercase().contains("authorization"));
    }

    #[test]
    fn sends_bearer_token() {
        let (port, h) = serve_once("HTTP/1.1 401 Unauthorized\r\n\r\n{}");
        let r = get(port, "/x", Some("tok"), Duration::from_secs(2)).unwrap();
        assert_eq!(r.status, 401);
        assert!(h.join().unwrap().contains("Authorization: Bearer tok\r\n"));
    }

    #[test]
    fn refused_connection_is_an_error() {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        drop(l);
        assert!(get(port, "/", None, Duration::from_millis(500)).is_err());
    }
}
