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