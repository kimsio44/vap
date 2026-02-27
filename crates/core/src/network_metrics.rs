use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct NetworkMetrics {
    pub rtt: Duration,
    pub bandwidth_bps: u64,
    pub packet_loss: f32,
    pub measured_at: Instant,
    pub sample_count: u32,
}

impl NetworkMetrics {
    pub fn default_good() -> Self {
        Self {
            rtt: Duration::from_millis(20),
            bandwidth_bps: 10_000_000,
            packet_loss: 0.0,
            measured_at: Instant::now(),
            sample_count: 0,
        }
    }

    pub fn quality_score(&self) -> f32 {
        let rtt_score = rtt_score(self.rtt);
        let bw_score = bandwidth_score(self.bandwidth_bps);
        let loss_score = loss_score(self.packet_loss);
        (rtt_score * 0.30 + bw_score * 0.35 + loss_score * 0.35).clamp(0.0, 1.0)
    }
}

fn rtt_score(rtt: Duration) -> f32 {
    let ms = rtt.as_millis() as f32;
    if ms <= 20.0 { 1.0 }
    else if ms <= 80.0  { 1.0 - (ms - 20.0) / 60.0 * 0.3 }
    else if ms <= 200.0 { 0.7 - (ms - 80.0) / 120.0 * 0.5 }
    else { (0.2 - (ms - 200.0) / 300.0 * 0.2).max(0.0) }
}

fn bandwidth_score(bps: u64) -> f32 {
    let mbps = bps as f32 / 1_000_000.0;
    if mbps >= 5.0 { 1.0 }
    else if mbps >= 0.2 { (mbps - 0.2) / 4.8 }
    else { 0.0 }
}

fn loss_score(loss: f32) -> f32 {
    if loss <= 0.01 { 1.0 }
    else if loss <= 0.15 { 1.0 - (loss - 0.01) / 0.14 }
    else { 0.0 }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn test_perfect_network() {
        let m = NetworkMetrics { rtt: Duration::from_millis(5), bandwidth_bps: 20_000_000, packet_loss: 0.0, measured_at: Instant::now(), sample_count: 10 };
        assert!(m.quality_score() > 0.95);
    }
    #[test]
    fn test_bad_network() {
        let m = NetworkMetrics { rtt: Duration::from_millis(250), bandwidth_bps: 300_000, packet_loss: 0.08, measured_at: Instant::now(), sample_count: 10 };
        assert!(m.quality_score() < 0.4);
    }
}