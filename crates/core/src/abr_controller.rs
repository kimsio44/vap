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