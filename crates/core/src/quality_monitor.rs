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