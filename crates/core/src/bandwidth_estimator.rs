use tokio::sync::mpsc;
use tracing::{debug, info};

#[derive(Debug, Clone)]
pub struct BandwidthEstimate {
    pub bandwidth_bps: u64,
    pub confidence: f32,
    pub inter_packet_delay_us: i64,
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct ProbeAck {
    pub burst_id: u32,
    pub arrival_times_us: Vec<u64>,
    pub total_bytes_received: u64,
}

pub struct BandwidthEstimator {
    burst_id: u32,
    estimates: Vec<u64>,
    max_history: usize,
    tx: mpsc::UnboundedSender<BandwidthEstimate>,
}

impl BandwidthEstimator {
    pub fn new(max_history: usize) -> (Self, mpsc::UnboundedReceiver<BandwidthEstimate>) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Self { burst_id: 0, estimates: Vec::with_capacity(max_history), max_history, tx }, rx)
    }

    pub fn handle_ack(&mut self, ack: ProbeAck) {
        if ack.arrival_times_us.len() < 2 { return; }
        let first = ack.arrival_times_us.first().unwrap();
        let last  = ack.arrival_times_us.last().unwrap();
        let duration_us = last.saturating_sub(*first);
        if duration_us == 0 { return; }
        let bps = (ack.total_bytes_received * 1_000_000) / duration_us;
        let n = ack.arrival_times_us.len();
        let avg_gap = duration_us as i64 / (n as i64 - 1);
        let inter_packet_delay = avg_gap - 100;
        debug!(burst_id = ack.burst_id, mbps = bps as f32 / 1_000_000.0, delay_us = inter_packet_delay, "BW estimate");
        self.estimates.push(bps);
        if self.estimates.len() > self.max_history { self.estimates.remove(0); }
        let bw_estimate = self.percentile_estimate(0.15);
        let confidence = (self.estimates.len() as f32 / self.max_history as f32).min(1.0);
        if self.estimates.len() >= 3 {
            info!(mbps = format!("{:.2}", bw_estimate as f32 / 1_000_000.0), confidence = format!("{:.0}%", confidence * 100.0), "BW published");
        }
        let _ = self.tx.send(BandwidthEstimate { bandwidth_bps: bw_estimate, confidence, inter_packet_delay_us: inter_packet_delay });
    }

    fn percentile_estimate(&self, percentile: f32) -> u64 {
        if self.estimates.is_empty() { return 0; }
        let mut sorted = self.estimates.clone();
        sorted.sort_unstable();
        let idx = ((sorted.len() as f32 * percentile) as usize).min(sorted.len() - 1);
        sorted[idx]
    }

    pub fn latest_estimate(&self) -> Option<u64> { self.estimates.last().copied() }
}