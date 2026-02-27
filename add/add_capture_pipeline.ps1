# add_capture_pipeline.ps1
# Ajoute le pipeline de capture DXGI (Phase 2.1)
# Lance depuis C:\Users\kimsd\OneDrive\Bureau\vap\

Write-Host "==> Phase 2.1 - Pipeline de capture DXGI..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Mise a jour Cargo.toml du crate core (ajout dependances Windows + H264)
# ---------------------------------------------------------------------------
$cargoPath = "crates\core\Cargo.toml"
$cargoContent = Get-Content $cargoPath -Raw

if ($cargoContent -notmatch "windows\s*=") {
    Add-Content $cargoPath @'

[target.'cfg(windows)'.dependencies]
windows = { version = "0.58", features = [
    "Win32_Graphics_Direct3D11",
    "Win32_Graphics_Dxgi",
    "Win32_Graphics_Dxgi_Common",
    "Win32_Graphics_Direct3D",
    "Win32_Foundation",
] }

openh264 = { version = "0.6", features = ["encoder"] }
'@
    Write-Host "  [OK] Cargo.toml mis a jour (windows + openh264)" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] Cargo.toml deja a jour" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# frame.rs
# ---------------------------------------------------------------------------
[System.IO.File]::WriteAllText("$PWD\crates\core\src\frame.rs", @'
use std::time::Instant;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PixelFormat { Bgra32, Yuv420p }

#[derive(Debug, Clone)]
pub struct RawFrame {
    pub data: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub format: PixelFormat,
    pub captured_at: Instant,
    pub seq: u64,
    pub has_changes: bool,
}

impl RawFrame {
    pub fn new(data: Vec<u8>, width: u32, height: u32, seq: u64) -> Self {
        Self {
            data, width, height,
            format: PixelFormat::Bgra32,
            captured_at: Instant::now(),
            seq,
            has_changes: true,
        }
    }

    pub fn stride(&self) -> u32 {
        match self.format {
            PixelFormat::Bgra32  => self.width * 4,
            PixelFormat::Yuv420p => self.width,
        }
    }

    pub fn expected_size(&self) -> usize {
        match self.format {
            PixelFormat::Bgra32  => (self.width * self.height * 4) as usize,
            PixelFormat::Yuv420p => (self.width * self.height * 3 / 2) as usize,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct CaptureStats {
    pub frames_captured: u64,
    pub frames_skipped: u64,
    pub frames_dropped: u64,
    pub actual_fps: f32,
    pub last_frame_size_bytes: usize,
}
'@)
Write-Host "  [OK] frame.rs" -ForegroundColor Green

# ---------------------------------------------------------------------------
# capture.rs
# ---------------------------------------------------------------------------
[System.IO.File]::WriteAllText("$PWD\crates\core\src\capture.rs", @'
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};
use crate::frame::RawFrame;
use crate::rate_controller::EncodingParams;

#[derive(Debug, thiserror::Error)]
pub enum CaptureError {
    #[error("DXGI initialization failed: {0}")]
    DxgiInit(String),
    #[error("Failed to acquire frame (timeout)")]
    Timeout,
    #[error("Display output lost")]
    OutputLost,
    #[error("Capture stopped")]
    Stopped,
    #[error("Internal error: {0}")]
    Internal(String),
}

#[derive(Debug, Clone)]
pub struct CaptureConfig {
    pub monitor_index: u32,
    pub acquire_timeout_ms: u32,
}

impl Default for CaptureConfig {
    fn default() -> Self {
        Self { monitor_index: 0, acquire_timeout_ms: 100 }
    }
}

#[derive(Clone)]
pub struct CaptureHandle {
    stop_flag: Arc<AtomicBool>,
    frame_counter: Arc<AtomicU64>,
}

impl CaptureHandle {
    pub fn stop(&self) {
        self.stop_flag.store(true, Ordering::Relaxed);
        info!("Capture stop requested");
    }
    pub fn frame_count(&self) -> u64 {
        self.frame_counter.load(Ordering::Relaxed)
    }
}

pub fn start_capture(
    config: CaptureConfig,
    params: EncodingParams,
) -> (CaptureHandle, mpsc::Receiver<RawFrame>) {
    let (frame_tx, frame_rx) = mpsc::channel::<RawFrame>(4);
    let stop_flag     = Arc::new(AtomicBool::new(false));
    let frame_counter = Arc::new(AtomicU64::new(0));

    let handle = CaptureHandle {
        stop_flag: stop_flag.clone(),
        frame_counter: frame_counter.clone(),
    };

    let config_clone = config.clone();
    std::thread::spawn(move || {
        info!(monitor = config_clone.monitor_index, fps = params.target_fps, "Starting capture thread");

        #[cfg(windows)]
        {
            if let Err(e) = capture_loop_windows(config_clone, params, frame_tx, stop_flag, frame_counter) {
                error!("Capture loop error: {}", e);
            }
        }
        #[cfg(not(windows))]
        capture_loop_stub(config_clone, params, frame_tx, stop_flag, frame_counter);

        info!("Capture thread exited");
    });

    (handle, frame_rx)
}

// ---------------------------------------------------------------------------
// Windows — DXGI Desktop Duplication
// ---------------------------------------------------------------------------

#[cfg(windows)]
fn capture_loop_windows(
    config: CaptureConfig,
    params: EncodingParams,
    tx: mpsc::Sender<RawFrame>,
    stop_flag: Arc<AtomicBool>,
    counter: Arc<AtomicU64>,
) -> Result<(), CaptureError> {
    use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_HARDWARE;
    use windows::Win32::Graphics::Direct3D11::{
        D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext,
        D3D11_CPU_ACCESS_READ, D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING,
        D3D11_BIND_FLAG, D3D11_RESOURCE_MISC_FLAG, D3D11_MAP_READ,
        ID3D11Texture2D,
    };
    use windows::Win32::Graphics::Dxgi::{
        CreateDXGIFactory1, IDXGIFactory1, IDXGIOutput1,
        DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_WAIT_TIMEOUT,
    };
    use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
    use windows::core::Interface;

    // --- 1. D3D11 Device ---
    let mut d3d_device: Option<ID3D11Device> = None;
    let mut d3d_context: Option<ID3D11DeviceContext> = None;
    unsafe {
        D3D11CreateDevice(None, D3D_DRIVER_TYPE_HARDWARE, None, Default::default(), None, 11, Some(&mut d3d_device), None, Some(&mut d3d_context))
            .map_err(|e| CaptureError::DxgiInit(e.to_string()))?;
    }
    let device  = d3d_device.ok_or_else(||  CaptureError::DxgiInit("No D3D11 device".into()))?;
    let context = d3d_context.ok_or_else(|| CaptureError::DxgiInit("No D3D11 context".into()))?;

    // --- 2. DXGI Output (moniteur) ---
    let factory: IDXGIFactory1 = unsafe { CreateDXGIFactory1().map_err(|e| CaptureError::DxgiInit(e.to_string()))? };
    let adapter = unsafe { factory.EnumAdapters1(0).map_err(|e| CaptureError::DxgiInit(format!("No adapter: {}", e)))? };
    let output  = unsafe { adapter.EnumOutputs(config.monitor_index).map_err(|e| CaptureError::DxgiInit(format!("Monitor {} not found: {}", config.monitor_index, e)))? };
    let output1: IDXGIOutput1 = output.cast().map_err(|e| CaptureError::DxgiInit(e.to_string()))?;

    let output_desc = unsafe { output1.GetDesc().map_err(|e| CaptureError::DxgiInit(e.to_string()))? };
    let src_width  = (output_desc.DesktopCoordinates.right  - output_desc.DesktopCoordinates.left) as u32;
    let src_height = (output_desc.DesktopCoordinates.bottom - output_desc.DesktopCoordinates.top)  as u32;
    info!(width = src_width, height = src_height, "DXGI output dimensions");

    // --- 3. Desktop Duplication ---
    let duplication = unsafe { output1.DuplicateOutput(&device).map_err(|e| CaptureError::DxgiInit(format!("DuplicateOutput: {}", e)))? };

    // --- 4. Staging texture CPU-readable ---
    let (scaled_w, scaled_h) = params.scaled_resolution(src_width, src_height);
    let staging_desc = D3D11_TEXTURE2D_DESC {
        Width: scaled_w, Height: scaled_h, MipLevels: 1, ArraySize: 1,
        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_STAGING,
        BindFlags: D3D11_BIND_FLAG(0),
        CPUAccessFlags: D3D11_CPU_ACCESS_READ,
        MiscFlags: D3D11_RESOURCE_MISC_FLAG(0),
    };
    let mut staging_opt = None;
    unsafe { device.CreateTexture2D(&staging_desc, None, Some(&mut staging_opt)).map_err(|e| CaptureError::DxgiInit(e.to_string()))? };
    let staging: ID3D11Texture2D = staging_opt.ok_or_else(|| CaptureError::DxgiInit("CreateTexture2D None".into()))?;

    // --- 5. Boucle de capture ---
    let mut seq: u64 = 0;
    let mut last_frame_time = Instant::now();

    info!("DXGI capture loop running at {}fps", params.target_fps);

    loop {
        if stop_flag.load(Ordering::Relaxed) { break; }

        let frame_interval = Duration::from_micros(1_000_000 / params.target_fps as u64);
        let elapsed = last_frame_time.elapsed();
        if elapsed < frame_interval { std::thread::sleep(frame_interval - elapsed); }

        let mut frame_info = Default::default();
        let mut desktop_resource = None;

        match unsafe { duplication.AcquireNextFrame(config.acquire_timeout_ms, &mut frame_info, &mut desktop_resource) } {
            Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => {
                debug!("No screen change, skipping");
                unsafe { let _ = duplication.ReleaseFrame(); }
                continue;
            }
            Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST => {
                warn!("DXGI output lost");
                unsafe { let _ = duplication.ReleaseFrame(); }
                return Err(CaptureError::OutputLost);
            }
            Err(e) => {
                error!("AcquireNextFrame: {}", e);
                unsafe { let _ = duplication.ReleaseFrame(); }
                continue;
            }
            Ok(()) => {}
        }

        if let Some(resource) = desktop_resource {
            if let Ok(frame_texture) = resource.cast::<ID3D11Texture2D>() {
                unsafe { context.CopyResource(&staging, &frame_texture); }
            }
        }
        unsafe { let _ = duplication.ReleaseFrame(); }

        // Map → CPU
        let mut mapped = Default::default();
        if unsafe { context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped)) }.is_err() {
            continue;
        }

        let row_pitch   = mapped.RowPitch as usize;
        let row_bytes   = (scaled_w * 4) as usize;
        let mut pixels  = vec![0u8; (scaled_w * scaled_h * 4) as usize];

        unsafe {
            let src = mapped.pData as *const u8;
            for row in 0..scaled_h as usize {
                std::ptr::copy_nonoverlapping(src.add(row * row_pitch), pixels.as_mut_ptr().add(row * row_bytes), row_bytes);
            }
            context.Unmap(&staging, 0);
        }

        seq += 1;
        counter.fetch_add(1, Ordering::Relaxed);
        last_frame_time = Instant::now();

        let frame = RawFrame::new(pixels, scaled_w, scaled_h, seq);
        match tx.try_send(frame) {
            Ok(()) => {}
            Err(mpsc::error::TrySendError::Full(_))   => { warn!("Frame channel full, dropping {}", seq); }
            Err(mpsc::error::TrySendError::Closed(_)) => { info!("Receiver dropped, stopping"); break; }
        }
    }

    info!("Capture loop finished after {} frames", seq);
    Ok(())
}

// ---------------------------------------------------------------------------
// Stub non-Windows
// ---------------------------------------------------------------------------

#[cfg(not(windows))]
fn capture_loop_stub(
    _config: CaptureConfig,
    params: EncodingParams,
    tx: mpsc::Sender<RawFrame>,
    stop_flag: Arc<AtomicBool>,
    counter: Arc<AtomicU64>,
) {
    warn!("DXGI not available — using stub (black frames)");
    let interval = Duration::from_micros(1_000_000 / params.target_fps as u64);
    let mut seq = 0u64;
    loop {
        if stop_flag.load(Ordering::Relaxed) { break; }
        std::thread::sleep(interval);
        seq += 1;
        let frame = RawFrame::new(vec![0u8; 1920 * 1080 * 4], 1920, 1080, seq);
        counter.fetch_add(1, Ordering::Relaxed);
        if tx.blocking_send(frame).is_err() { break; }
    }
}

// ---------------------------------------------------------------------------
// Conversion BGRA → YUV420p (BT.601)
// ---------------------------------------------------------------------------

pub fn bgra_to_yuv420p(bgra: &[u8], width: u32, height: u32) -> Vec<u8> {
    let w = width as usize;
    let h = height as usize;
    let mut yuv = vec![0u8; w * h * 3 / 2];
    let u_off = w * h;
    let v_off = w * h + w * h / 4;

    for row in 0..h {
        for col in 0..w {
            let i = (row * w + col) * 4;
            let b = bgra[i    ] as f32;
            let g = bgra[i + 1] as f32;
            let r = bgra[i + 2] as f32;

            let y = (0.257*r + 0.504*g + 0.098*b + 16.0).clamp(0.0,255.0) as u8;
            yuv[row * w + col] = y;

            if row % 2 == 0 && col % 2 == 0 {
                let u = (-0.148*r - 0.291*g + 0.439*b + 128.0).clamp(0.0,255.0) as u8;
                let v = ( 0.439*r - 0.368*g - 0.071*b + 128.0).clamp(0.0,255.0) as u8;
                let uv = (row/2)*(w/2) + col/2;
                yuv[u_off + uv] = u;
                yuv[v_off + uv] = v;
            }
        }
    }
    yuv
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_yuv_output_size() {
        let bgra = vec![0u8; 640 * 480 * 4];
        let yuv  = bgra_to_yuv420p(&bgra, 640, 480);
        assert_eq!(yuv.len(), 640 * 480 * 3 / 2);
    }

    #[test]
    fn test_black_pixel_y_value() {
        let bgra = vec![0u8; 4 * 4 * 4]; // 4x4 noir
        let yuv  = bgra_to_yuv420p(&bgra, 4, 4);
        assert!(yuv[0] >= 14 && yuv[0] <= 18, "Y for black ~16, got {}", yuv[0]);
    }

    #[test]
    fn test_white_pixel_y_value() {
        let bgra = vec![255u8; 4 * 4 * 4]; // 4x4 blanc
        let yuv  = bgra_to_yuv420p(&bgra, 4, 4);
        assert!(yuv[0] >= 230, "Y for white should be high, got {}", yuv[0]);
    }
}
'@)
Write-Host "  [OK] capture.rs (DXGI + conversion YUV)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Mise a jour lib.rs
# ---------------------------------------------------------------------------
[System.IO.File]::WriteAllText("$PWD\crates\core\src\lib.rs", @'
// ABR System
pub mod network_metrics;
pub mod quality_monitor;
pub mod rate_controller;
pub mod rtt_prober;
pub mod bandwidth_estimator;
pub mod abr_controller;

// Phase 2 - Video pipeline
pub mod frame;
pub mod capture;
pub mod encoder;
pub mod input_handler;

// Phase 3
pub mod webrtc_manager;
'@)
Write-Host "  [OK] lib.rs mis a jour" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Compilation + tests
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Compilation..." -ForegroundColor Cyan
cargo test -p remotedesk-core 2>&1

Write-Host ""
Write-Host "==> Phase 2.1 terminee !" -ForegroundColor Green
Write-Host "    Prochaine etape : encodeur H.264 (capture.rs -> encoder.rs)" -ForegroundColor Yellow
