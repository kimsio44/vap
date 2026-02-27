# add_encoder.ps1
# Phase 2.2 — Encodeur H.264 via openh264
# Lance depuis C:\Users\kimsd\OneDrive\Bureau\vap\

Write-Host "==> Phase 2.2 - Encodeur H.264..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# encoder.rs
# ---------------------------------------------------------------------------
[System.IO.File]::WriteAllText("$PWD\crates\core\src\encoder.rs", @'
use std::time::Instant;
use tracing::{debug, error, info, warn};
use crate::capture::bgra_to_yuv420p;
use crate::frame::{PixelFormat, RawFrame};
use crate::rate_controller::EncodingParams;

// ---------------------------------------------------------------------------
// Types publics
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct EncodedFrame {
    pub data: Vec<u8>,
    pub is_keyframe: bool,
    pub timestamp: Instant,
    pub seq: u64,
    pub size_bytes: usize,
}

#[derive(Debug, thiserror::Error)]
pub enum EncoderError {
    #[error("Encoder initialization failed: {0}")]
    Init(String),
    #[error("Encoding failed: {0}")]
    Encode(String),
    #[error("Invalid frame dimensions: {width}x{height}")]
    InvalidDimensions { width: u32, height: u32 },
    #[error("Encoder not initialized")]
    NotInitialized,
}

// ---------------------------------------------------------------------------
// H264Encoder
// ---------------------------------------------------------------------------

pub struct H264Encoder {
    encoder: openh264::encoder::Encoder,
    pub params: EncodingParams,
    pub width: u32,
    pub height: u32,
    frames_since_keyframe: u32,
    frames_encoded: u64,
    bytes_emitted: u64,
}

impl H264Encoder {
    pub fn new(width: u32, height: u32, params: EncodingParams) -> Result<Self, EncoderError> {
        if width == 0 || height == 0 || width % 2 != 0 || height % 2 != 0 {
            return Err(EncoderError::InvalidDimensions { width, height });
        }
        let encoder = build_encoder(width, height, &params)?;
        info!(width, height, fps = params.target_fps, kbps = params.target_bitrate_bps / 1000, "H264Encoder initialized");
        Ok(Self { encoder, params, width, height, frames_since_keyframe: 0, frames_encoded: 0, bytes_emitted: 0 })
    }

    pub fn encode(&mut self, frame: &RawFrame) -> Result<EncodedFrame, EncoderError> {
        if frame.width != self.width || frame.height != self.height {
            return Err(EncoderError::InvalidDimensions { width: frame.width, height: frame.height });
        }

        // Convertir BGRA -> YUV420p si besoin
        let yuv = match frame.format {
            PixelFormat::Yuv420p => frame.data.clone(),
            PixelFormat::Bgra32  => bgra_to_yuv420p(&frame.data, frame.width, frame.height),
        };

        let w = self.width as usize;
        let h = self.height as usize;

        let yuv_buf = openh264::formats::YUVBuffer::new_with_data(w, h, &yuv);

        let force_idr = self.frames_since_keyframe == 0
            || self.frames_since_keyframe >= self.params.keyframe_interval;

        let bitstream = if force_idr {
            self.frames_since_keyframe = 0;
            self.encoder.encode_at(&yuv_buf, openh264::encoder::FrameType::IDR)
        } else {
            self.encoder.encode(&yuv_buf)
        }.map_err(|e| EncoderError::Encode(format!("{:?}", e)))?;

        self.frames_since_keyframe += 1;
        self.frames_encoded += 1;

        // Extraire NAL units avec prefixe Annex B
        let mut nal_data: Vec<u8> = Vec::new();
        for layer in bitstream.layers() {
            for nal in layer.nal_units() {
                nal_data.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
                nal_data.extend_from_slice(nal);
            }
        }

        let size_bytes = nal_data.len();
        self.bytes_emitted += size_bytes as u64;

        debug!(seq = frame.seq, size_bytes, is_keyframe = force_idr, "Frame encoded");

        Ok(EncodedFrame {
            data: nal_data,
            is_keyframe: force_idr,
            timestamp: frame.captured_at,
            seq: frame.seq,
            size_bytes,
        })
    }

    pub fn update_params(&mut self, new_params: EncodingParams) -> Result<(), EncoderError> {
        let changed = new_params.target_bitrate_bps != self.params.target_bitrate_bps
            || new_params.h264_qp != self.params.h264_qp;
        if !changed { return Ok(()); }
        info!(from = self.params.label, to = new_params.label, "Encoder params update");
        self.encoder = build_encoder(self.width, self.height, &new_params)?;
        self.params = new_params;
        self.frames_since_keyframe = 0;
        Ok(())
    }

    pub fn request_keyframe(&mut self) {
        self.frames_since_keyframe = u32::MAX;
        info!("Keyframe requested");
    }

    pub fn frames_encoded(&self) -> u64 { self.frames_encoded }
    pub fn bytes_emitted(&self) -> u64  { self.bytes_emitted }
    pub fn avg_frame_size(&self) -> usize {
        if self.frames_encoded == 0 { 0 } else { (self.bytes_emitted / self.frames_encoded) as usize }
    }
}

// ---------------------------------------------------------------------------
// Init openh264
// ---------------------------------------------------------------------------

fn build_encoder(width: u32, height: u32, params: &EncodingParams) -> Result<openh264::encoder::Encoder, EncoderError> {
    use openh264::encoder::{EncoderConfig, RateControlMode};

    let config = EncoderConfig::new()
        .set_bitrate_bps(params.target_bitrate_bps)
        .set_rate_control_mode(RateControlMode::Bitrate)
        .max_frame_rate(params.target_fps as f32)
        .enable_skip_frame(true);

    openh264::encoder::Encoder::with_config(config)
        .map_err(|e| EncoderError::Init(format!("{:?}", e)))
}

// ---------------------------------------------------------------------------
// Tâche tokio : Capture -> Encode
// ---------------------------------------------------------------------------

use tokio::sync::mpsc;

pub async fn run_encoder_task(
    mut frame_rx: mpsc::Receiver<RawFrame>,
    encoded_tx: mpsc::Sender<EncodedFrame>,
    initial_params: EncodingParams,
    mut params_rx: mpsc::Receiver<EncodingParams>,
) {
    let mut encoder: Option<H264Encoder> = None;
    info!("Encoder task started");

    loop {
        tokio::select! {
            Some(frame) = frame_rx.recv() => {
                // Init au premier frame (on connait les dimensions)
                if encoder.is_none() {
                    match H264Encoder::new(frame.width, frame.height, initial_params.clone()) {
                        Ok(enc) => { info!(w = frame.width, h = frame.height, "Encoder ready"); encoder = Some(enc); }
                        Err(e)  => { error!("Encoder init failed: {}", e); continue; }
                    }
                }

                let enc = encoder.as_mut().unwrap();
                match enc.encode(&frame) {
                    Ok(encoded) => {
                        if let Err(e) = encoded_tx.try_send(encoded) {
                            warn!("Encoded channel issue: {}", e);
                        }
                    }
                    Err(EncoderError::InvalidDimensions { width, height }) => {
                        warn!("Dimensions changed to {}x{}, reinit", width, height);
                        if let Ok(new_enc) = H264Encoder::new(width, height, enc.params.clone()) {
                            encoder = Some(new_enc);
                        }
                    }
                    Err(e) => error!("Encode error: {}", e),
                }
            }

            Some(new_params) = params_rx.recv() => {
                if let Some(enc) = encoder.as_mut() {
                    if let Err(e) = enc.update_params(new_params) {
                        error!("Params update failed: {}", e);
                    }
                }
            }

            else => {
                info!("Encoder task stopping");
                break;
            }
        }
    }

    if let Some(enc) = encoder {
        info!(frames = enc.frames_encoded(), mb = enc.bytes_emitted() / 1_000_000, "Encoder task done");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn test_params() -> EncodingParams {
        EncodingParams {
            target_fps: 30,
            target_bitrate_bps: 1_500_000,
            resolution_scale: 1.0,
            h264_qp: 28,
            keyframe_interval: 90,
            label: "test",
        }
    }

    fn black_yuv_frame(width: u32, height: u32, seq: u64) -> RawFrame {
        let yuv_size = (width * height * 3 / 2) as usize;
        let mut yuv = vec![16u8; (width * height) as usize];
        yuv.extend(vec![128u8; yuv_size - (width * height) as usize]);
        let mut frame = RawFrame::new(vec![0u8; (width * height * 4) as usize], width, height, seq);
        frame.data = yuv;
        frame.format = PixelFormat::Yuv420p;
        frame
    }

    #[test]
    fn test_encoder_init() {
        let result = H264Encoder::new(640, 480, test_params());
        assert!(result.is_ok(), "Encoder should initialize: {:?}", result.err());
    }

    #[test]
    fn test_rejects_odd_dimensions() {
        let result = H264Encoder::new(641, 480, test_params());
        assert!(matches!(result, Err(EncoderError::InvalidDimensions { .. })));
    }

    #[test]
    fn test_encode_black_yuv_frame() {
        let mut enc = H264Encoder::new(320, 240, test_params()).unwrap();
        let frame = black_yuv_frame(320, 240, 1);
        let result = enc.encode(&frame);
        assert!(result.is_ok(), "Encode failed: {:?}", result.err());
        let encoded = result.unwrap();
        assert!(encoded.is_keyframe, "First frame must be IDR");
        assert!(encoded.size_bytes > 0, "Output must not be empty");
    }

    #[test]
    fn test_encode_bgra_frame() {
        let mut enc = H264Encoder::new(320, 240, test_params()).unwrap();
        let frame = RawFrame::new(vec![0u8; 320 * 240 * 4], 320, 240, 1);
        let result = enc.encode(&frame);
        assert!(result.is_ok(), "BGRA encode failed: {:?}", result.err());
    }

    #[test]
    fn test_annex_b_prefix() {
        let mut enc = H264Encoder::new(320, 240, test_params()).unwrap();
        let frame = black_yuv_frame(320, 240, 1);
        let encoded = enc.encode(&frame).unwrap();
        if encoded.size_bytes >= 4 {
            assert_eq!(&encoded.data[..4], &[0x00, 0x00, 0x00, 0x01],
                "Must start with Annex B prefix");
        }
    }

    #[test]
    fn test_keyframe_interval() {
        let mut params = test_params();
        params.keyframe_interval = 3;
        let mut enc = H264Encoder::new(320, 240, params).unwrap();

        let f1 = enc.encode(&black_yuv_frame(320, 240, 1)).unwrap();
        let f2 = enc.encode(&black_yuv_frame(320, 240, 2)).unwrap();
        let f3 = enc.encode(&black_yuv_frame(320, 240, 3)).unwrap();
        let f4 = enc.encode(&black_yuv_frame(320, 240, 4)).unwrap();

        assert!(f1.is_keyframe,  "Frame 1 should be IDR");
        assert!(!f2.is_keyframe, "Frame 2 should not be IDR");
        assert!(!f3.is_keyframe, "Frame 3 should not be IDR");
        assert!(f4.is_keyframe,  "Frame 4 should be IDR (interval=3)");
    }
}
'@)
Write-Host "  [OK] encoder.rs" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Verifier que openh264 est bien dans Cargo.toml sans feature incorrecte
# ---------------------------------------------------------------------------
$cargo = Get-Content "crates\core\Cargo.toml" -Raw
if ($cargo -match 'features = \["encoder"\]') {
    $cargo = $cargo -replace 'openh264 = \{ version = "0\.6", features = \["encoder"\] \}', 'openh264 = { version = "0.6" }'
    [System.IO.File]::WriteAllText("$PWD\crates\core\Cargo.toml", $cargo)
    Write-Host "  [OK] Cargo.toml corrige (feature encoder supprimee)" -ForegroundColor Green
} else {
    Write-Host "  [OK] Cargo.toml deja correct" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Compilation + tests
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Compilation + tests..." -ForegroundColor Cyan
cargo test -p remotedesk-core 2>&1

Write-Host ""
Write-Host "==> Phase 2.2 terminee !" -ForegroundColor Green
Write-Host "    Prochaine etape : WebRTC peer connection (Phase 2.3)" -ForegroundColor Yellow
