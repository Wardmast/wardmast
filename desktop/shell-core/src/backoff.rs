use std::time::Duration;

#[derive(Debug, Clone)]
pub struct Backoff {
    pub base: Duration,
    pub max: Duration,
    pub reset_after: Duration,
    attempts: u32,
}

impl Backoff {
    pub fn new(base: Duration, max: Duration, reset_after: Duration) -> Self {
        Backoff {
            base,
            max,
            reset_after,
            attempts: 0,
        }
    }
    /// The delay before the next restart, given how long the run that just
    /// ended stayed up. A run that lasted `reset_after` or more was healthy,
    /// so the curve starts over; otherwise the delay doubles up to `max`.
    pub fn next_delay(&mut self, uptime: Duration) -> Duration {
        if uptime >= self.reset_after {
            self.attempts = 0;
        }
        let factor = 1u32.checked_shl(self.attempts.min(31)).unwrap_or(u32::MAX);
        self.attempts = self.attempts.saturating_add(1);
        self.base.saturating_mul(factor).min(self.max)
    }

    pub fn reset(&mut self) {
        self.attempts = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secs(n: u64) -> Duration {
        Duration::from_secs(n)
    }

    #[test]
    fn doubles_until_capped() {
        let mut b = Backoff::new(secs(1), secs(8), secs(60));
        let got: Vec<_> = (0..5).map(|_| b.next_delay(secs(0))).collect();
        assert_eq!(got, vec![secs(1), secs(2), secs(4), secs(8), secs(8)]);
    }

    #[test]
    fn a_long_healthy_run_resets_the_curve() {
        let mut b = Backoff::new(secs(1), secs(8), secs(60));
        b.next_delay(secs(0));
        b.next_delay(secs(0));
        assert_eq!(b.next_delay(secs(61)), secs(1));
        assert_eq!(b.next_delay(secs(1)), secs(2));
    }

    #[test]
    fn does_not_overflow_on_many_attempts() {
        let mut b = Backoff::new(secs(1), secs(30), secs(60));
        for _ in 0..200 {
            assert!(b.next_delay(secs(0)) <= secs(30));
        }
    }
}
