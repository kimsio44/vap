# add_abr_system.ps1
# Lance depuis C:\Users\kimsd\OneDrive\Bureau\vap\
# Ajoute le système ABR (Adaptive Bitrate) au crate core

Write-Host "==> Ajout du systeme ABR..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# crates\core\src\network_metrics.rs
# ---------------------------------------------------------------------------
[System.IO.File]::WriteAllText("$PWD\crates\core\src\network_metrics.rs", @'
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
'@)
Write-Host "  [OK] network_metrics.rs" -ForegroundColor Green

# ---------------------------------------------------------------------------
# crates\core\src\rate_controller.rs
# ---------------------------------------------------------------------------
[System.IO.File]::WriteAllText("$PWD\crates\core\src\rate_controller.rs", @'
use serde::{Deserialize, Serialize};
use tracing::info;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum QualityLevel { High, Medium, Low }

#[derive(Debug, Clone)]
pub struct EncodingParams {
    pub target_fps: u32,
    pub target_bitrate_bps: u32,
    pub resolution_scale: f32,
    pub h264_qp: u32,
    pub keyframe_interval: u32,
    pub label: &'static str,
}

impl EncodingParams {
    pub fn scaled_resolution(&self, src_width: u32, src_height: u32) -> (u32, u32) {
        let w = ((src_width as f32 * self.resolution_scale) as u32) & !1;
        let h = ((src_height as f32 * self.resolution_scale) as u32) & !1;
        (w, h)
    }
}

fn params_high()   -> EncodingParams { EncodingParams { target_fps: 60, target_bitrate_bps: 4_000_000, resolution_scale: 1.0,  h264_qp: 20, keyframe_interval: 120, label: "High (60fps/4Mbps/Native)" } }
fn params_medium() -> EncodingParams { EncodingParams { target_fps: 30, target_bitrate_bps: 1_500_000, resolution_scale: 1.0,  h264_qp: 28, keyframe_interval: 90,  label: "Medium (30fps/1.5Mbps/Native)" } }
fn params_low()    -> EncodingParams { EncodingParams { target_fps: 15, target_bitrate_bps: 500_000,   resolution_scale: 0.75, h264_qp: 35, keyframe_interval: 60,  label: "Low (15fps/500Kbps/75%)" } }

pub struct RateController {
    current_params: EncodingParams,
    current_level: QualityLevel,
}

impl RateController {
    pub fn new() -> Self { Self { current_params: params_high(), current_level: QualityLevel::High } }

    pub fn apply_level(&mut self, level: QualityLevel) -> bool {
        if level == self.current_level { return false; }
        let new_params = match level { QualityLevel::High => params_high(), QualityLevel::Medium => params_medium(), QualityLevel::Low => params_low() };
        info!(from = self.current_params.label, to = new_params.label, "Encoding params updated");
        self.current_params = new_params;
        self.current_level = level;
        true
    }

    pub fn current_params(&self) -> &EncodingParams { &self.current_params }
    pub fn current_level(&self) -> &QualityLevel { &self.current_level }
    pub fn frame_interval_us(&self) -> u64 { 1_000_000 / self.current_params.target_fps as u64 }
}

impl Default for RateController { fn default() -> Self { Self::new() } }

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn test_resolution_scale() {
        let p = params_low();
        let (w, h) = p.scaled_resolution(1920, 1080);
        assert_eq!(w, 1440); assert_eq!(h, 810);
        assert_eq!(w % 2, 0); assert_eq!(h % 2, 0);
    }
    #[test]
    fn test_level_transitions() {
        let mut rc = RateController::new();
        assert!(rc.apply_level(QualityLevel::Medium));
        assert_eq!(rc.current_params().target_fps, 30);
        assert!(!rc.apply_level(QualityLevel::Medium));
        rc.apply_level(QualityLevel::Low);
        assert_eq!(rc.current_params().target_fps, 15);
    }
}
'@)
Write-Host "  [OK] rate_controller.rs" -ForegroundColor Green

# ---------------------------------------------------------------------------
# crates\core\src\quality_monitor.rs
# ---------------------------------------------------------------------------
[System.IO.File]::WriteAllText("$PWD\crates\core\src\quality_monitor.rs", @'
use std::collections::VecDeque;
use std::time::Duration;
use tracing::{debug, info};
use crate::network_metrics::NetworkMetrics;
use crate::rate_controller::QualityLevel;

pub const MONITOR_INTERVAL: Duration = Duration::from_secs(1);

const EWMA_ALPHA_DEGRADATION: f32 = 0.25;
const EWMA_ALPHA_IMPROVEMENT: f32 = 0.08;
const THRESHOLD_UP: f32   = 0.75;
const THRESHOLD_DOWN: f32 = 0.45;
const SAMPLES_TO_UPGRADE: u32   = 8;
const SAMPLES_TO_DOWNGRADE: u32 = 3;

pub struct QualityMonitor {
    smoothed_score: f32,
    current_level: QualityLevel,
    upgrade_counter: u32,
    downgrade_counter: u32,
    score_history: VecDeque<f32>,
}

#[derive(Debug, Clone)]
pub struct QualityDecision {
    pub level: QualityLevel,
    pub smoothed_score: f32,
    pub raw_score: f32,
    pub changed: bool,
    pub rtt_ms: u32,
    pub bandwidth_mbps: f32,
    pub packet_loss_pct: f32,
}

impl QualityMonitor {
    pub fn new() -> Self {
        Self { smoothed_score: 1.0, current_level: QualityLevel::High, upgrade_counter: 0, downgrade_counter: 0, score_history: VecDeque::with_capacity(10) }
    }

    pub fn update(&mut self, metrics: &NetworkMetrics) -> QualityDecision {
        let raw_score = metrics.quality_score();
        let alpha = if raw_score < self.smoothed_score { EWMA_ALPHA_DEGRADATION } else { EWMA_ALPHA_IMPROVEMENT };
        self.smoothed_score = alpha * raw_score + (1.0 - alpha) * self.smoothed_score;

        if self.score_history.len() >= 10 { self.score_history.pop_front(); }
        self.score_history.push_back(self.smoothed_score);

        debug!(raw = format!("{:.3}", raw_score), smoothed = format!("{:.3}", self.smoothed_score), level = ?self.current_level, "Quality update");

        let new_level = self.evaluate_level_transition();
        let changed = new_level != self.current_level;
        if changed {
            info!(from = ?self.current_level, to = ?new_level, score = format!("{:.3}", self.smoothed_score), "Quality level transition");
            self.current_level = new_level.clone();
        }

        QualityDecision { level: self.current_level.clone(), smoothed_score: self.smoothed_score, raw_score, changed, rtt_ms: metrics.rtt.as_millis() as u32, bandwidth_mbps: metrics.bandwidth_bps as f32 / 1_000_000.0, packet_loss_pct: metrics.packet_loss * 100.0 }
    }

    fn evaluate_level_transition(&mut self) -> QualityLevel {
        use QualityLevel::*;
        if self.smoothed_score < THRESHOLD_DOWN {
            self.downgrade_counter += 1; self.upgrade_counter = 0;
            if self.downgrade_counter >= SAMPLES_TO_DOWNGRADE {
                self.downgrade_counter = 0;
                return match self.current_level { High => Medium, Medium => Low, Low => Low };
            }
        } else if self.smoothed_score > THRESHOLD_UP {
            self.upgrade_counter += 1; self.downgrade_counter = 0;
            if self.upgrade_counter >= SAMPLES_TO_UPGRADE {
                self.upgrade_counter = 0;
                return match self.current_level { Low => Medium, Medium => High, High => High };
            }
        } else {
            self.upgrade_counter = self.upgrade_counter.saturating_sub(1);
            self.downgrade_counter = self.downgrade_counter.saturating_sub(1);
        }
        self.current_level.clone()
    }

    pub fn current_level(&self) -> &QualityLevel { &self.current_level }
    pub fn smoothed_score(&self) -> f32 { self.smoothed_score }
    pub fn score_history(&self) -> Vec<f32> { self.score_history.iter().copied().collect() }
    pub fn force_level(&mut self, level: QualityLevel) {
        info!(level = ?level, "Quality level forced by user");
        self.current_level = level; self.upgrade_counter = 0; self.downgrade_counter = 0;
    }
}

impl Default for QualityMonitor { fn default() -> Self { Self::new() } }
'@)
Write-Host "  [OK] quality_monitor.rs" -ForegroundColor Green

# ---------------------------------------------------------------------------
# crates\core\src\rtt_prober.rs
# ---------------------------------------------------------------------------
[System.IO.File]::WriteAllText("$PWD\crates\core\src\rtt_prober.rs", @'
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
'@)
Write-Host "  [OK] rtt_prober.rs" -ForegroundColor Green

# ---------------------------------------------------------------------------
# crates\core\src\bandwidth_estimator.rs
# ---------------------------------------------------------------------------
[System.IO.File]::WriteAllText("$PWD\crates\core\src\bandwidth_estimator.rs", @'
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
'@)
Write-Host "  [OK] bandwidth_estimator.rs" -ForegroundColor Green

# ---------------------------------------------------------------------------
# crates\core\src\abr_controller.rs
# ---------------------------------------------------------------------------
[System.IO.File]::WriteAllText("$PWD\crates\core\src\abr_controller.rs", @'
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, Mutex};
use tracing::info;
use crate::network_metrics::NetworkMetrics;
use crate::quality_monitor::{QualityMonitor, MONITOR_INTERVAL};
use crate::rate_controller::{EncodingParams, QualityLevel, RateController};

#[derive(Debug, Clone)]
pub struct EncodingParamsChanged {
    pub new_fps: u32,
    pub new_bitrate_bps: u32,
    pub new_resolution_scale: f32,
    pub reason: String,
}

#[derive(Clone)]
pub struct AbrController {
    inner: Arc<Mutex<AbrInner>>,
    change_tx: mpsc::UnboundedSender<EncodingParamsChanged>,
}

struct AbrInner {
    monitor: QualityMonitor,
    rate_ctrl: RateController,
    sample_count: u64,
}

impl AbrController {
    pub fn new() -> (Self, mpsc::UnboundedReceiver<EncodingParamsChanged>) {
        let (change_tx, change_rx) = mpsc::unbounded_channel();
        let ctrl = Self { inner: Arc::new(Mutex::new(AbrInner { monitor: QualityMonitor::new(), rate_ctrl: RateController::new(), sample_count: 0 })), change_tx };
        info!("ABR Controller initialized");
        (ctrl, change_rx)
    }

    pub async fn update(&self, rtt: Duration, bandwidth_bps: u64, packet_loss: f32) -> EncodingParams {
        let mut inner = self.inner.lock().await;
        inner.sample_count += 1;
        let metrics = NetworkMetrics { rtt, bandwidth_bps, packet_loss, measured_at: std::time::Instant::now(), sample_count: inner.sample_count as u32 };
        let decision = inner.monitor.update(&metrics);
        let changed = inner.rate_ctrl.apply_level(decision.level.clone());
        let params = inner.rate_ctrl.current_params();
        if changed {
            let _ = self.change_tx.send(EncodingParamsChanged {
                new_fps: params.target_fps, new_bitrate_bps: params.target_bitrate_bps, new_resolution_scale: params.resolution_scale,
                reason: format!("RTT={}ms BW={:.1}Mbps Loss={:.1}% Score={:.2}", rtt.as_millis(), bandwidth_bps as f32/1_000_000.0, packet_loss*100.0, decision.smoothed_score),
            });
        }
        clone_params(params)
    }

    pub async fn current_params(&self) -> EncodingParams { clone_params(self.inner.lock().await.rate_ctrl.current_params()) }
    pub async fn current_level(&self) -> QualityLevel { self.inner.lock().await.rate_ctrl.current_level().clone() }
    pub async fn force_level(&self, level: QualityLevel) {
        let mut inner = self.inner.lock().await;
        inner.monitor.force_level(level.clone());
        inner.rate_ctrl.apply_level(level);
    }
    pub async fn smoothed_score(&self) -> f32 { self.inner.lock().await.monitor.smoothed_score() }
}

fn clone_params(p: &EncodingParams) -> EncodingParams {
    EncodingParams { target_fps: p.target_fps, target_bitrate_bps: p.target_bitrate_bps, resolution_scale: p.resolution_scale, h264_qp: p.h264_qp, keyframe_interval: p.keyframe_interval, label: p.label }
}

pub async fn run_abr_monitor_task(
    abr: AbrController,
    mut rtt_rx: mpsc::UnboundedReceiver<crate::rtt_prober::RttMeasurement>,
    mut bw_rx: mpsc::UnboundedReceiver<crate::bandwidth_estimator::BandwidthEstimate>,
) {
    use tokio::time::{interval, MissedTickBehavior};
    let mut ticker = interval(MONITOR_INTERVAL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    let mut latest_rtt = Duration::from_millis(50);
    let mut latest_bw: u64 = 5_000_000;
    let mut latest_loss: f32 = 0.0;
    loop {
        tokio::select! {
            _ = ticker.tick() => {
                let params = abr.update(latest_rtt, latest_bw, latest_loss).await;
                info!(fps = params.target_fps, kbps = params.target_bitrate_bps/1000, scale = params.resolution_scale, "ABR tick");
            }
            Some(rtt_meas) = rtt_rx.recv() => { latest_rtt = rtt_meas.rtt; }
            Some(bw_est) = bw_rx.recv() => {
                latest_bw = bw_est.bandwidth_bps;
                if bw_est.inter_packet_delay_us > 5000 { latest_loss = (latest_loss + 0.02).min(0.5); }
                else { latest_loss = (latest_loss - 0.01).max(0.0); }
            }
            else => break,
        }
    }
}
'@)
Write-Host "  [OK] abr_controller.rs" -ForegroundColor Green

# ---------------------------------------------------------------------------
# crates\core\src\lib.rs
# ---------------------------------------------------------------------------
[System.IO.File]::WriteAllText("$PWD\crates\core\src\lib.rs", @'
pub mod network_metrics;
pub mod quality_monitor;
pub mod rate_controller;
pub mod rtt_prober;
pub mod bandwidth_estimator;
pub mod abr_controller;

pub mod webrtc_manager;
pub mod capture;
pub mod encoder;
pub mod input_handler;
'@)
Write-Host "  [OK] lib.rs mis a jour" -ForegroundColor Green

Write-Host ""
Write-Host "==> Test de compilation..." -ForegroundColor Cyan
cargo test -p remotedesk-core 2>&1
Write-Host ""
Write-Host "==> Termine ! Lance : cargo test -p remotedesk-core" -ForegroundColor Green
