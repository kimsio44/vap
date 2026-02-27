use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, Mutex};
use tracing::{debug, warn};

#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct PingMessage { pub seq: u32, pub sent_at_us: u64 }

#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct PongMessage { pub seq: u32, pub original_sent_at_us: u64 }

#[derive(Debug, Clone)]
pub struct RttMeasurement { pub rtt: Duration, pub seq: u32 }

pub trait DataChannelSender: Send + Sync {
    fn send_text(&self, msg: String) -> Result<(), String>;
}

pub struct RttProber {
    seq: u32,
    pending: Arc<Mutex<HashMap<u32, Instant>>>,
    tx: mpsc::UnboundedSender<RttMeasurement>,
    timeout: Duration,
}

impl RttProber {
    pub fn new(timeout: Duration) -> (Self, mpsc::UnboundedReceiver<RttMeasurement>) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Self { seq: 0, pending: Arc::new(Mutex::new(HashMap::new())), tx, timeout }, rx)
    }

    pub async fn send_ping<S: DataChannelSender>(&mut self, sender: &S) {
        self.seq = self.seq.wrapping_add(1);
        let seq = self.seq;
        let now = Instant::now();
        let sent_at_us = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_micros() as u64;
        let ping = PingMessage { seq, sent_at_us };
        match serde_json::to_string(&serde_json::json!({"type": "rtt_ping", "payload": ping})) {
            Ok(msg) => {
                if sender.send_text(msg).is_ok() {
                    let mut pending = self.pending.lock().await;
                    pending.insert(seq, now);
                    let timeout = self.timeout;
                    pending.retain(|_, sent| sent.elapsed() < timeout);
                }
            }
            Err(e) => warn!("Failed to serialize ping: {}", e),
        }
    }

    pub async fn handle_pong(&self, pong: PongMessage) {
        let mut pending = self.pending.lock().await;
        if let Some(sent_at) = pending.remove(&pong.seq) {
            let rtt = sent_at.elapsed();
            debug!(seq = pong.seq, rtt_ms = rtt.as_millis(), "RTT measured");
            let _ = self.tx.send(RttMeasurement { rtt, seq: pong.seq });
        } else {
            warn!(seq = pong.seq, "Received pong for unknown/expired ping");
        }
    }

    pub async fn packet_loss_estimate(&self) -> f32 {
        let pending = self.pending.lock().await;
        let expired = pending.values().filter(|sent| sent.elapsed() > self.timeout).count();
        if pending.is_empty() { 0.0 } else { expired as f32 / pending.len() as f32 }
    }
}

pub fn make_pong(ping: &PingMessage) -> PongMessage {
    PongMessage { seq: ping.seq, original_sent_at_us: ping.sent_at_us }
}