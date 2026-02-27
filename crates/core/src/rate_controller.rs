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