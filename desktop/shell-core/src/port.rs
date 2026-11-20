use std::io;
use std::net::TcpListener;

/// The loopback port the release should bind: `preferred` when it is free,
/// otherwise an OS-assigned free one.
///
/// This is check-then-use, so another process can still take the port between
/// the probe and the release binding it; the supervisor treats a release that
/// dies at boot as a boot failure and re-picks on the next attempt.
pub fn pick_port(preferred: u16) -> io::Result<u16> {
    if preferred != 0 {
        if let Ok(l) = TcpListener::bind(("127.0.0.1", preferred)) {
            drop(l);
            return Ok(preferred);
        }
    }
    let l = TcpListener::bind(("127.0.0.1", 0))?;
    Ok(l.local_addr()?.port())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    #[test]
    fn returns_preferred_when_free() {
        let probe = TcpListener::bind("127.0.0.1:0").unwrap();
        let free = probe.local_addr().unwrap().port();
        drop(probe);
        assert_eq!(pick_port(free).unwrap(), free);
    }

    #[test]
    fn falls_back_to_another_loopback_port_when_taken() {
        let taken = TcpListener::bind("127.0.0.1:0").unwrap();
        let busy = taken.local_addr().unwrap().port();
        let picked = pick_port(busy).unwrap();
        assert_ne!(picked, busy);
        assert_ne!(picked, 0);
        // The fallback really is bindable on loopback.
        TcpListener::bind(("127.0.0.1", picked)).unwrap();
    }
}
