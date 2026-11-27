//! Real-time RDP network telemetry and adaptive visual quality control.
//!
//! Combines protocol-level MS-RDPBCGR AutoDetect characteristics, RDPEUDP2/V1
//! transport counters, kernel TCP socket statistics (when direct TCP is in use),
//! and rolling receive throughput / frame-rate measurements to report signal
//! quality and dynamically adjust EGFX visual quality + frame pacing to keep
//! frame delivery smooth under congestion, high latency, or packet loss.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant as StdInstant};

use tokio::net::TcpStream;
use tokio::time::Instant;

use crate::api::desktop::DesktopNetworkStats;
use crate::desktop_frame_flow::FrameFlowConfig;

pub(crate) const TRANSPORT_TCP: u8 = 0;
pub(crate) const TRANSPORT_UDP: u8 = 1;
pub(crate) const TRANSPORT_TUNNEL: u8 = 2;

pub(crate) const QUALITY_MODE_AUTO: u8 = 0;
pub(crate) const QUALITY_MODE_HIGH: u8 = 1;
pub(crate) const QUALITY_MODE_BALANCED: u8 = 2;
pub(crate) const QUALITY_MODE_LOW: u8 = 3;

const TCP_SAMPLE_INTERVAL_MS: u64 = 900;
const DEGRADE_STREAK_TICKS: u8 = 3;
const UPGRADE_STREAK_TICKS: u8 = 12;
const EGFX_RESET_COOLDOWN: Duration = Duration::from_secs(15);
// Hold recent active throughput/FPS briefly when an on-demand RDP/VNC screen goes
// static (e.g., while moving the pointer off the canvas to inspect the toolbar).
const IDLE_HOLD_TICKS: u8 = 4;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
#[repr(u8)]
pub(crate) enum QualityTier {
    #[default]
    High = 0,
    Balanced = 1,
    Low = 2,
}

impl QualityTier {
    pub(crate) fn as_u8(self) -> u8 {
        self as u8
    }

    pub(crate) fn from_mode(mode: u8) -> Option<Self> {
        match mode {
            QUALITY_MODE_HIGH => Some(Self::High),
            QUALITY_MODE_BALANCED => Some(Self::Balanced),
            QUALITY_MODE_LOW => Some(Self::Low),
            _ => None,
        }
    }

    /// EGFX capability flags target: `(thin_client, small_cache)`.
    pub(crate) fn egfx_flags(self) -> (bool, bool) {
        match self {
            Self::High => (false, false),
            Self::Balanced => (true, false),
            Self::Low => (true, true),
        }
    }

    /// Frame ACK pacing and congestion signaling for this quality tier.
    pub(crate) fn flow_config(self) -> FrameFlowConfig {
        match self {
            Self::High => FrameFlowConfig {
                ack_wait: Duration::from_millis(24),
                ack_limit: 8,
                congestion_hint_bytes: 0,
            },
            Self::Balanced => FrameFlowConfig {
                ack_wait: Duration::from_millis(33),
                ack_limit: 4,
                congestion_hint_bytes: 32 * 1024,
            },
            Self::Low => FrameFlowConfig {
                ack_wait: Duration::from_millis(50),
                ack_limit: 2,
                congestion_hint_bytes: 96 * 1024,
            },
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct TcpSocketSample {
    pub rtt_ms: Option<u32>,
    /// Cumulative retransmission / loss numerator (bytes or packets).
    pub loss_numerator: u64,
    /// Cumulative transferred denominator (matching numerator unit).
    pub loss_denominator: u64,
}

/// Lock-free rate-limited sampler invoked on the live `TcpStream` inside
/// `Transport::poll_read` / `poll_write`. Never duplicates or retains raw FDs.
pub(crate) struct TcpInfoSampler {
    started_at: StdInstant,
    last_sample_ms: AtomicU64,
    latest: Mutex<Option<TcpSocketSample>>,
}

impl Default for TcpInfoSampler {
    fn default() -> Self {
        Self {
            started_at: StdInstant::now(),
            last_sample_ms: AtomicU64::new(0),
            latest: Mutex::new(None),
        }
    }
}

impl TcpInfoSampler {
    pub(crate) fn maybe_sample(&self, stream: &TcpStream) {
        let elapsed_ms = self
            .started_at
            .elapsed()
            .as_millis()
            .min(u128::from(u64::MAX)) as u64;
        let prev = self.last_sample_ms.load(Ordering::Relaxed);
        if prev != 0 && elapsed_ms.saturating_sub(prev) < TCP_SAMPLE_INTERVAL_MS {
            return;
        }
        if self
            .last_sample_ms
            .compare_exchange(prev, elapsed_ms.max(1), Ordering::AcqRel, Ordering::Relaxed)
            .is_err()
        {
            return;
        }
        if let Some(sample) = query_tcp_info(stream) {
            if let Ok(mut guard) = self.latest.lock() {
                *guard = Some(sample);
            }
        }
    }

    pub(crate) fn latest(&self) -> Option<TcpSocketSample> {
        self.latest.lock().ok().and_then(|guard| *guard)
    }
}

#[cfg(target_os = "macos")]
fn query_tcp_info(stream: &TcpStream) -> Option<TcpSocketSample> {
    use std::mem::{size_of, MaybeUninit};
    use std::os::fd::AsRawFd;

    let mut info = MaybeUninit::<libc::tcp_connection_info>::zeroed();
    let mut len = size_of::<libc::tcp_connection_info>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::IPPROTO_TCP,
            libc::TCP_CONNECTION_INFO,
            info.as_mut_ptr().cast(),
            &mut len,
        )
    };
    if rc != 0 || (len as usize) < size_of::<libc::tcp_connection_info>() {
        return None;
    }
    let info = unsafe { info.assume_init() };
    let rtt_ms = if info.tcpi_srtt > 0 {
        Some(info.tcpi_srtt)
    } else if info.tcpi_rttcur > 0 {
        Some(info.tcpi_rttcur)
    } else {
        None
    };
    let loss_numerator = info
        .tcpi_txretransmitbytes
        .saturating_add(info.tcpi_rxoutoforderbytes);
    let loss_denominator = info.tcpi_txbytes.saturating_add(info.tcpi_rxbytes);
    Some(TcpSocketSample {
        rtt_ms,
        loss_numerator,
        loss_denominator,
    })
}

#[cfg(target_os = "linux")]
fn query_tcp_info(stream: &TcpStream) -> Option<TcpSocketSample> {
    use std::mem::{size_of, MaybeUninit};
    use std::os::fd::AsRawFd;

    // ABI-stable prefix of Linux `struct tcp_info` across glibc and musl.
    #[repr(C)]
    struct LinuxTcpInfo {
        tcpi_state: u8,
        tcpi_ca_state: u8,
        tcpi_retransmits: u8,
        tcpi_probes: u8,
        tcpi_backoff: u8,
        tcpi_options: u8,
        tcpi_wscale: u8,
        tcpi_delivery_flags: u8,
        tcpi_rto: u32,
        tcpi_ato: u32,
        tcpi_snd_mss: u32,
        tcpi_rcv_mss: u32,
        tcpi_unacked: u32,
        tcpi_sacked: u32,
        tcpi_lost: u32,
        tcpi_retrans: u32,
        tcpi_fackets: u32,
        tcpi_last_data_sent: u32,
        tcpi_last_ack_sent: u32,
        tcpi_last_data_recv: u32,
        tcpi_last_ack_recv: u32,
        tcpi_pmtu: u32,
        tcpi_rcv_ssthresh: u32,
        tcpi_rtt: u32,
        tcpi_rttvar: u32,
        tcpi_snd_ssthresh: u32,
        tcpi_snd_cwnd: u32,
        tcpi_advmss: u32,
        tcpi_reordering: u32,
        tcpi_rcv_rtt: u32,
        tcpi_rcv_space: u32,
        tcpi_total_retrans: u32,
        tcpi_pacing_rate: u64,
        tcpi_max_pacing_rate: u64,
        tcpi_bytes_acked: u64,
        tcpi_bytes_received: u64,
        tcpi_segs_out: u32,
        tcpi_segs_in: u32,
    }

    let mut info = MaybeUninit::<LinuxTcpInfo>::zeroed();
    let mut len = size_of::<LinuxTcpInfo>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::IPPROTO_TCP,
            libc::TCP_INFO,
            info.as_mut_ptr().cast(),
            &mut len,
        )
    };
    // Require at least through `tcpi_total_retrans` (104 bytes).
    if rc != 0 || (len as usize) < 104 {
        return None;
    }
    let info = unsafe { info.assume_init() };
    let rtt_ms = (info.tcpi_rtt > 0).then(|| info.tcpi_rtt.div_ceil(1000));
    let has_segs = (len as usize) >= size_of::<LinuxTcpInfo>();
    let loss_denominator = if has_segs {
        u64::from(info.tcpi_segs_out).saturating_add(u64::from(info.tcpi_segs_in))
    } else {
        0
    };
    let loss_numerator = u64::from(info.tcpi_total_retrans);
    Some(TcpSocketSample {
        rtt_ms,
        loss_numerator,
        loss_denominator,
    })
}

#[cfg(windows)]
fn query_tcp_info(stream: &TcpStream) -> Option<TcpSocketSample> {
    use std::mem::{size_of, MaybeUninit};
    use std::os::windows::io::AsRawSocket;
    use windows_sys::Win32::Networking::WinSock::{TCP_INFO_v0, WSAIoctl, SIO_TCP_INFO, SOCKET};

    let version: u32 = 0;
    let mut info = MaybeUninit::<TCP_INFO_v0>::zeroed();
    let mut returned: u32 = 0;
    let rc = unsafe {
        WSAIoctl(
            stream.as_raw_socket() as SOCKET,
            SIO_TCP_INFO,
            (&version as *const u32).cast(),
            size_of::<u32>() as u32,
            info.as_mut_ptr().cast(),
            size_of::<TCP_INFO_v0>() as u32,
            &mut returned,
            std::ptr::null_mut(),
            None,
        )
    };
    if rc != 0 || (returned as usize) < size_of::<TCP_INFO_v0>() {
        return None;
    }
    let info = unsafe { info.assume_init() };
    let rtt_ms = (info.RttUs > 0).then(|| info.RttUs.div_ceil(1000));
    let loss_numerator =
        u64::from(info.BytesRetrans).saturating_add(u64::from(info.BytesReordered));
    let loss_denominator = info.BytesOut.saturating_add(info.BytesIn);
    Some(TcpSocketSample {
        rtt_ms,
        loss_numerator,
        loss_denominator,
    })
}

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
fn query_tcp_info(_stream: &TcpStream) -> Option<TcpSocketSample> {
    None
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct TickOutcome {
    pub stats: DesktopNetworkStats,
    pub flow_config: FrameFlowConfig,
    /// Set when the controller wants to renegotiate EGFX capabilities for this tier.
    pub egfx_reset_target: Option<QualityTier>,
}

/// Tracks RDP link health (RTT, receive speed, bandwidth, packet loss, FPS)
/// and runs a hysteresis-protected adaptive quality state machine.
pub(crate) struct DesktopNetworkTracker {
    transport_kind: u8,
    quality_mode: u8,
    quality_tier: QualityTier,
    egfx_applied_tier: QualityTier,
    last_egfx_reset_at: Option<Instant>,

    // RTT sources
    handshake_rtt_ms: Option<u32>,
    autodetect_base_rtt_ms: Option<u32>,
    autodetect_avg_rtt_ms: Option<u32>,
    tcp_rtt_ms: Option<u32>,
    udp_rtt_ms: Option<u32>,

    // Bandwidth / throughput
    server_bandwidth_kbps: Option<u32>,
    observed_peak_kbps: Option<u32>,
    last_tick_at: Option<Instant>,
    prev_tick_ms: u64,
    rx_bytes_current: u64,
    rx_bytes_previous: u64,
    frames_current: u32,
    frames_previous: u32,
    throughput_kbps: u32,
    last_active_kbps: u32,
    rx_idle_ticks: u8,
    fps: u16,
    last_active_fps: u16,
    fps_idle_ticks: u8,

    // Packet loss / drops
    prev_tcp_loss: Option<(u64, u64)>,
    prev_udp_loss: Option<(u64, u64)>,
    packet_loss_permille: Option<u16>,
    last_egfx_drops: u64,
    recent_egfx_drops: u64,

    // Hysteresis counters
    degrade_streak: u8,
    upgrade_streak: u8,
}

impl DesktopNetworkTracker {
    pub(crate) fn new(transport_kind: u8, handshake_rtt: Option<Duration>) -> Self {
        let handshake_rtt_ms =
            handshake_rtt.map(|d| d.as_millis().clamp(1, u128::from(u32::MAX)) as u32);
        Self {
            transport_kind,
            quality_mode: QUALITY_MODE_AUTO,
            quality_tier: QualityTier::High,
            egfx_applied_tier: QualityTier::High,
            last_egfx_reset_at: None,
            handshake_rtt_ms,
            autodetect_base_rtt_ms: handshake_rtt_ms,
            autodetect_avg_rtt_ms: None,
            tcp_rtt_ms: None,
            udp_rtt_ms: None,
            server_bandwidth_kbps: None,
            observed_peak_kbps: None,
            last_tick_at: None,
            prev_tick_ms: 0,
            rx_bytes_current: 0,
            rx_bytes_previous: 0,
            frames_current: 0,
            frames_previous: 0,
            throughput_kbps: 0,
            last_active_kbps: 0,
            rx_idle_ticks: 0,
            fps: 0,
            last_active_fps: 0,
            fps_idle_ticks: 0,
            prev_tcp_loss: None,
            prev_udp_loss: None,
            packet_loss_permille: None,
            last_egfx_drops: 0,
            recent_egfx_drops: 0,
            degrade_streak: 0,
            upgrade_streak: 0,
        }
    }

    pub(crate) fn set_transport_kind(&mut self, transport_kind: u8) {
        if self.transport_kind != transport_kind {
            self.transport_kind = transport_kind;
            if transport_kind != TRANSPORT_UDP {
                self.udp_rtt_ms = None;
                self.prev_udp_loss = None;
            }
        }
    }

    pub(crate) fn observe_auto_detect(
        &mut self,
        base_rtt_ms: Option<u32>,
        average_rtt_ms: u32,
        bandwidth_kbps: Option<u32>,
    ) {
        if let Some(base) = base_rtt_ms {
            self.autodetect_base_rtt_ms = Some(base);
        } else if self.autodetect_base_rtt_ms.is_none() {
            self.autodetect_base_rtt_ms = Some(average_rtt_ms);
        }
        self.autodetect_avg_rtt_ms = Some(average_rtt_ms);
        if let Some(bw) = bandwidth_kbps.filter(|&bw| bw > 0) {
            self.server_bandwidth_kbps = Some(bw);
        }
    }

    pub(crate) fn observe_tcp_sample(&mut self, sample: TcpSocketSample) {
        if let Some(rtt) = sample.rtt_ms {
            self.tcp_rtt_ms = Some(rtt);
            self.autodetect_base_rtt_ms = Some(
                self.autodetect_base_rtt_ms
                    .map_or(rtt, |base| base.min(rtt)),
            );
        }
        if self.transport_kind != TRANSPORT_UDP && sample.loss_denominator > 0 {
            self.update_loss_ratio(
                &mut self.prev_tcp_loss.clone(),
                sample.loss_numerator,
                sample.loss_denominator,
                false,
            );
            self.prev_tcp_loss = Some((sample.loss_numerator, sample.loss_denominator));
        }
    }

    pub(crate) fn observe_udp_stats(&mut self, stats: ironrdp_rdpeudp_tokio::UdpTransportStats) {
        if let Some(rtt) = stats.srtt_ms {
            self.udp_rtt_ms = Some(rtt);
            self.autodetect_base_rtt_ms = Some(
                self.autodetect_base_rtt_ms
                    .map_or(rtt, |base| base.min(rtt)),
            );
        }
        let total = stats
            .packets_sent
            .saturating_add(stats.packets_retransmitted);
        if total > 0 || stats.recv_gaps {
            let prev = self.prev_udp_loss;
            self.update_loss_ratio(
                &mut prev.clone(),
                stats.packets_retransmitted,
                total,
                stats.recv_gaps,
            );
            self.prev_udp_loss = Some((stats.packets_retransmitted, total));
        }
    }

    fn update_loss_ratio(
        &mut self,
        prev: &mut Option<(u64, u64)>,
        numerator: u64,
        denominator: u64,
        recv_gaps: bool,
    ) {
        let Some((prev_num, prev_den)) = *prev else {
            // Establish baseline without counting historical handshake bursts.
            if self.packet_loss_permille.is_none() {
                self.packet_loss_permille = Some(if recv_gaps { 10 } else { 0 });
            }
            return;
        };
        let d_num = numerator.saturating_sub(prev_num);
        let d_den = denominator.saturating_sub(prev_den);
        let sample_permille = if let Some(ratio) = d_num.saturating_mul(1000).checked_div(d_den) {
            ratio.min(1000) as u16
        } else if recv_gaps {
            15
        } else {
            // Decay gently toward 0 when traffic is quiet.
            self.packet_loss_permille.unwrap_or(0) / 2
        };
        let smoothed = match self.packet_loss_permille {
            Some(old) => ((u32::from(old) * 2 + u32::from(sample_permille) + 1) / 3) as u16,
            None => sample_permille,
        };
        self.packet_loss_permille = Some(smoothed.min(1000));
    }

    pub(crate) fn record_rx_bytes(&mut self, bytes: usize) {
        self.rx_bytes_current = self.rx_bytes_current.saturating_add(bytes as u64);
    }

    pub(crate) fn record_frame_delivered(&mut self) {
        self.frames_current = self.frames_current.saturating_add(1);
    }

    pub(crate) fn observe_egfx_drops(&mut self, total_drops: u64) {
        let delta = total_drops.saturating_sub(self.last_egfx_drops);
        self.last_egfx_drops = total_drops;
        self.recent_egfx_drops = self.recent_egfx_drops.saturating_add(delta);
    }

    pub(crate) fn mark_egfx_applied(&mut self, tier: QualityTier, now: Instant) {
        self.egfx_applied_tier = tier;
        self.last_egfx_reset_at = Some(now);
    }

    pub(crate) fn set_quality_mode(
        &mut self,
        mode: u8,
        now: Instant,
        egfx_ready: bool,
    ) -> TickOutcome {
        let mode = if mode <= QUALITY_MODE_LOW {
            mode
        } else {
            QUALITY_MODE_AUTO
        };
        self.quality_mode = mode;
        self.degrade_streak = 0;
        self.upgrade_streak = 0;
        if let Some(forced) = QualityTier::from_mode(mode) {
            self.quality_tier = forced;
            let egfx_reset_target =
                (egfx_ready && self.egfx_applied_tier != forced).then_some(forced);
            return TickOutcome {
                stats: self.snapshot(),
                flow_config: self.quality_tier.flow_config(),
                egfx_reset_target,
            };
        }
        // Returning to Auto: re-evaluate immediately on next tick (or apply current tier).
        let egfx_reset_target = self.pending_egfx_reset(now, egfx_ready);
        TickOutcome {
            stats: self.snapshot(),
            flow_config: self.quality_tier.flow_config(),
            egfx_reset_target,
        }
    }

    /// Runs once per second to roll counters, compute signal level, and evaluate
    /// adaptive quality transitions.
    pub(crate) fn tick(
        &mut self,
        now: Instant,
        egfx_ready: bool,
        frame_backlog: usize,
    ) -> TickOutcome {
        let dt_ms = self
            .last_tick_at
            .map(|prev| {
                now.saturating_duration_since(prev)
                    .as_millis()
                    .clamp(250, 5000) as u64
            })
            .unwrap_or(1000);
        self.last_tick_at = Some(now);

        // When active across consecutive ticks, smooth over a two-second window.
        // On startup or immediately after an idle period (previous == 0), use
        // only dt_ms so the first active second is not artificially halved.
        // When the current tick is idle (current == 0), hold the recent active
        // reading briefly so hovering the toolbar doesn't cliff-drop to 0.
        let live_kbps = if self.rx_bytes_current > 0 {
            let (bytes, window_ms) = if self.rx_bytes_previous > 0 && self.prev_tick_ms > 0 {
                (
                    self.rx_bytes_current.saturating_add(self.rx_bytes_previous),
                    dt_ms.saturating_add(self.prev_tick_ms),
                )
            } else {
                (self.rx_bytes_current, dt_ms)
            };
            bytes
                .saturating_mul(8)
                .div_ceil(window_ms)
                .clamp(1, u64::from(u32::MAX)) as u32
        } else {
            0
        };
        let live_fps = if self.frames_current > 0 {
            let (frames, window_ms) = if self.frames_previous > 0 && self.prev_tick_ms > 0 {
                (
                    u64::from(self.frames_current.saturating_add(self.frames_previous)),
                    dt_ms.saturating_add(self.prev_tick_ms),
                )
            } else {
                (u64::from(self.frames_current), dt_ms)
            };
            frames
                .saturating_mul(1000)
                .div_ceil(window_ms)
                .clamp(1, u64::from(u16::MAX)) as u16
        } else {
            0
        };

        if live_kbps > 0 {
            self.throughput_kbps = live_kbps;
            self.last_active_kbps = live_kbps;
            self.rx_idle_ticks = 0;
            self.observed_peak_kbps = Some(
                self.observed_peak_kbps
                    .map_or(live_kbps, |peak| peak.max(live_kbps)),
            );
        } else {
            self.rx_idle_ticks = self.rx_idle_ticks.saturating_add(1);
            if self.rx_idle_ticks <= IDLE_HOLD_TICKS && self.last_active_kbps > 0 {
                self.throughput_kbps = self.last_active_kbps;
            } else {
                self.throughput_kbps = 0;
            }
        }

        if live_fps > 0 {
            self.fps = live_fps;
            self.last_active_fps = live_fps;
            self.fps_idle_ticks = 0;
        } else {
            self.fps_idle_ticks = self.fps_idle_ticks.saturating_add(1);
            if self.fps_idle_ticks <= IDLE_HOLD_TICKS && self.last_active_fps > 0 {
                self.fps = self.last_active_fps;
            } else {
                self.fps = 0;
            }
        }

        self.prev_tick_ms = dt_ms;
        self.rx_bytes_previous = self.rx_bytes_current;
        self.rx_bytes_current = 0;
        self.frames_previous = self.frames_current;
        self.frames_current = 0;

        if self.quality_mode == QUALITY_MODE_AUTO {
            self.evaluate_auto_quality(frame_backlog, live_fps);
        } else if let Some(forced) = QualityTier::from_mode(self.quality_mode) {
            self.quality_tier = forced;
        }
        self.recent_egfx_drops = 0;

        let egfx_reset_target = self.pending_egfx_reset(now, egfx_ready);
        TickOutcome {
            stats: self.snapshot(),
            flow_config: self.quality_tier.flow_config(),
            egfx_reset_target,
        }
    }

    fn pending_egfx_reset(&self, now: Instant, egfx_ready: bool) -> Option<QualityTier> {
        if !egfx_ready || self.egfx_applied_tier == self.quality_tier {
            return None;
        }
        if let Some(last) = self.last_egfx_reset_at {
            if now.saturating_duration_since(last) < EGFX_RESET_COOLDOWN {
                return None;
            }
        }
        Some(self.quality_tier)
    }

    pub(crate) fn current_rtt_ms(&self) -> Option<u32> {
        if self.transport_kind == TRANSPORT_UDP {
            self.udp_rtt_ms
                .or(self.autodetect_avg_rtt_ms)
                .or(self.tcp_rtt_ms)
                .or(self.handshake_rtt_ms)
        } else {
            self.tcp_rtt_ms
                .or(self.autodetect_avg_rtt_ms)
                .or(self.handshake_rtt_ms)
        }
    }

    pub(crate) fn effective_bandwidth_kbps(&self) -> Option<u32> {
        let live_or_peak = self
            .observed_peak_kbps
            .map_or(self.live_throughput_kbps(), |peak| {
                peak.max(self.live_throughput_kbps())
            });
        match (self.server_bandwidth_kbps, live_or_peak) {
            (Some(server), live) => Some(server.max(live)),
            (None, 0) => None,
            (None, live) => Some(live),
        }
    }

    fn live_throughput_kbps(&self) -> u32 {
        if self.last_tick_at.is_none() && self.throughput_kbps == 0 && self.rx_bytes_current > 0 {
            return self
                .rx_bytes_current
                .saturating_mul(8)
                .div_ceil(1000)
                .clamp(1, u64::from(u32::MAX)) as u32;
        }
        self.throughput_kbps
    }

    fn live_fps(&self) -> u16 {
        if self.last_tick_at.is_none() && self.fps == 0 && self.frames_current > 0 {
            return self.frames_current.min(u32::from(u16::MAX)) as u16;
        }
        self.fps
    }

    fn evaluate_auto_quality(&mut self, frame_backlog: usize, active_fps: u16) {
        let rtt = self.current_rtt_ms();
        let loss = self.packet_loss_permille.unwrap_or(0);
        let server_bw = self.server_bandwidth_kbps;
        let rtt_inflation = match (rtt, self.autodetect_base_rtt_ms) {
            (Some(curr), Some(base)) => curr.saturating_sub(base),
            _ => 0,
        };

        let severe = rtt.is_some_and(|r| r >= 220)
            || loss >= 35
            || server_bw.is_some_and(|bw| bw <= 800)
            || (active_fps > 0
                && active_fps <= 10
                && frame_backlog >= 2
                && (rtt.is_some_and(|r| r >= 140) || loss >= 20));

        let moderate = rtt.is_some_and(|r| r >= 100)
            || loss >= 10
            || server_bw.is_some_and(|bw| bw <= 3000)
            || rtt_inflation >= 60
            || self.recent_egfx_drops > 0
            || (frame_backlog >= 4 && active_fps > 0 && active_fps <= 18);

        let healthy = rtt.is_none_or(|r| r < 75)
            && loss < 5
            && server_bw.is_none_or(|bw| bw > 4500)
            && rtt_inflation < 30
            && self.recent_egfx_drops == 0
            && frame_backlog <= 1;

        let desired = if severe {
            QualityTier::Low
        } else if moderate {
            QualityTier::Balanced
        } else if healthy {
            QualityTier::High
        } else {
            // Inside hysteresis deadband: hold current tier.
            self.quality_tier
        };

        if desired > self.quality_tier {
            self.upgrade_streak = 0;
            self.degrade_streak = self.degrade_streak.saturating_add(1);
            if self.degrade_streak >= DEGRADE_STREAK_TICKS {
                self.quality_tier = desired;
                self.degrade_streak = 0;
            }
        } else if desired < self.quality_tier {
            self.degrade_streak = 0;
            self.upgrade_streak = self.upgrade_streak.saturating_add(1);
            if self.upgrade_streak >= UPGRADE_STREAK_TICKS {
                // Step up one tier at a time for smooth recovery.
                self.quality_tier = match self.quality_tier {
                    QualityTier::Low => QualityTier::Balanced,
                    QualityTier::Balanced | QualityTier::High => QualityTier::High,
                };
                self.upgrade_streak = 0;
            }
        } else {
            self.degrade_streak = 0;
            self.upgrade_streak = 0;
        }
    }

    pub(crate) fn signal_level(&self) -> u8 {
        let Some(rtt) = self.current_rtt_ms() else {
            return 0;
        };
        let loss = self.packet_loss_permille.unwrap_or(0);
        let bw = self.server_bandwidth_kbps;

        if rtt > 200 || loss >= 40 || bw.is_some_and(|b| b < 600) {
            1
        } else if rtt > 100 || loss >= 15 || bw.is_some_and(|b| b < 1500) {
            2
        } else if rtt > 45 || loss >= 5 || bw.is_some_and(|b| b < 4000) {
            3
        } else {
            4
        }
    }

    pub(crate) fn snapshot(&self) -> DesktopNetworkStats {
        DesktopNetworkStats {
            rtt_ms: self.current_rtt_ms(),
            throughput_kbps: self.live_throughput_kbps(),
            bandwidth_kbps: self.effective_bandwidth_kbps(),
            packet_loss_permille: self.packet_loss_permille,
            fps: self.live_fps(),
            signal_level: self.signal_level(),
            quality_tier: self.quality_tier.as_u8(),
            quality_mode: self.quality_mode,
            transport_kind: self.transport_kind,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signal_level_reflects_latency_loss_and_bandwidth() {
        let mut tracker = DesktopNetworkTracker::new(TRANSPORT_TCP, None);
        assert_eq!(tracker.signal_level(), 0);

        tracker.observe_auto_detect(Some(18), 20, Some(20_000));
        assert_eq!(tracker.signal_level(), 4);

        tracker.observe_auto_detect(Some(18), 70, Some(20_000));
        assert_eq!(tracker.signal_level(), 3);

        tracker.observe_auto_detect(Some(18), 150, Some(20_000));
        assert_eq!(tracker.signal_level(), 2);

        tracker.observe_auto_detect(Some(18), 260, Some(20_000));
        assert_eq!(tracker.signal_level(), 1);

        // Low latency with high packet loss still degrades signal level.
        tracker.observe_auto_detect(Some(15), 18, Some(20_000));
        tracker.packet_loss_permille = Some(45);
        assert_eq!(tracker.signal_level(), 1);

        // Low bandwidth degrades signal even on low RTT.
        tracker.packet_loss_permille = Some(0);
        tracker.observe_auto_detect(Some(15), 18, Some(500));
        assert_eq!(tracker.signal_level(), 1);
    }

    #[test]
    fn adaptive_quality_degrades_after_sustained_congestion_and_recovers_with_hysteresis() {
        let start = Instant::now();
        let mut tracker =
            DesktopNetworkTracker::new(TRANSPORT_TCP, Some(Duration::from_millis(20)));
        tracker.observe_auto_detect(Some(20), 22, Some(25_000));
        let initial = tracker.tick(start, true, 0);
        assert_eq!(initial.stats.quality_tier, QualityTier::High.as_u8());
        assert_eq!(initial.egfx_reset_target, None);

        // Single-tick latency spike must not thrash quality.
        tracker.observe_auto_detect(Some(20), 250, Some(25_000));
        assert_eq!(
            tracker
                .tick(start + Duration::from_secs(1), true, 0)
                .stats
                .quality_tier,
            QualityTier::High.as_u8()
        );
        // Back to healthy resets streak.
        tracker.observe_auto_detect(Some(20), 22, Some(25_000));
        tracker.tick(start + Duration::from_secs(2), true, 0);

        // Sustained severe latency/loss degrades to Low after 3 ticks.
        tracker.observe_auto_detect(Some(20), 240, Some(700));
        for sec in 3..=4 {
            assert_eq!(
                tracker
                    .tick(start + Duration::from_secs(sec), true, 2)
                    .stats
                    .quality_tier,
                QualityTier::High.as_u8()
            );
        }
        let degraded = tracker.tick(start + Duration::from_secs(5), true, 2);
        assert_eq!(degraded.stats.quality_tier, QualityTier::Low.as_u8());
        assert_eq!(degraded.egfx_reset_target, Some(QualityTier::Low));
        assert_eq!(degraded.flow_config.ack_limit, 2);
        tracker.mark_egfx_applied(QualityTier::Low, start + Duration::from_secs(5));

        // Sustained healthy network steps up one tier after 12 ticks (Low -> Balanced).
        tracker.observe_auto_detect(Some(20), 24, Some(25_000));
        for sec in 6..17 {
            let outcome = tracker.tick(start + Duration::from_secs(sec), true, 0);
            assert_eq!(outcome.stats.quality_tier, QualityTier::Low.as_u8());
        }
        let recovered_balanced = tracker.tick(start + Duration::from_secs(17), true, 0);
        assert_eq!(
            recovered_balanced.stats.quality_tier,
            QualityTier::Balanced.as_u8()
        );
        // Still within 15s EGFX reset cooldown (17 - 5 = 12 < 15), so pacing updates
        // immediately while EGFX reset waits for cooldown expiry.
        assert_eq!(recovered_balanced.egfx_reset_target, None);
        let after_cooldown = tracker.tick(start + Duration::from_secs(20), true, 0);
        assert_eq!(
            after_cooldown.egfx_reset_target,
            Some(QualityTier::Balanced)
        );
        tracker.mark_egfx_applied(QualityTier::Balanced, start + Duration::from_secs(20));

        // Another 12 healthy ticks recover Balanced -> High (1 at sec=20 + 10 in 21..31 + 1 at sec=32).
        for sec in 21..31 {
            tracker.tick(start + Duration::from_secs(sec), true, 0);
        }
        let recovered_high = tracker.tick(start + Duration::from_secs(32), true, 0);
        assert_eq!(recovered_high.stats.quality_tier, QualityTier::High.as_u8());
    }

    #[test]
    fn manual_quality_mode_overrides_auto_and_computes_throughput_and_loss() {
        let now = Instant::now();
        let mut tracker = DesktopNetworkTracker::new(TRANSPORT_UDP, None);
        tracker.observe_udp_stats(ironrdp_rdpeudp_tokio::UdpTransportStats {
            srtt_ms: Some(30),
            rto_ms: 200,
            packets_sent: 100,
            packets_retransmitted: 0,
            packets_received: 100,
            recv_gaps: false,
        });
        // Baseline packet loss sample.
        tracker.observe_udp_stats(ironrdp_rdpeudp_tokio::UdpTransportStats {
            srtt_ms: Some(35),
            rto_ms: 200,
            packets_sent: 190,
            packets_retransmitted: 10,
            packets_received: 200,
            recv_gaps: false,
        });
        tracker.record_rx_bytes(250_000);
        for _ in 0..30 {
            tracker.record_frame_delivered();
        }
        // Pre-first-tick snapshot already reflects initial frame/byte burst.
        let early = tracker.snapshot();
        assert_eq!(early.throughput_kbps, 2000);
        assert_eq!(early.fps, 30);

        let tick = tracker.tick(now, true, 0);
        assert_eq!(tick.stats.rtt_ms, Some(35));
        assert_eq!(tick.stats.throughput_kbps, 2000);
        assert_eq!(tick.stats.fps, 30);
        assert!(tick.stats.packet_loss_permille.unwrap() > 0);

        // Manual override takes effect immediately.
        let manual = tracker.set_quality_mode(QUALITY_MODE_LOW, now, true);
        assert_eq!(manual.stats.quality_mode, QUALITY_MODE_LOW);
        assert_eq!(manual.stats.quality_tier, QualityTier::Low.as_u8());
        assert_eq!(manual.egfx_reset_target, Some(QualityTier::Low));
    }

    #[test]
    fn idle_hold_preserves_recent_active_rate_then_transitions_to_idle_with_peak_bandwidth() {
        let start = Instant::now();
        let mut tracker =
            DesktopNetworkTracker::new(TRANSPORT_TCP, Some(Duration::from_millis(12)));

        // Small non-zero traffic never truncates down to 0 Kbps.
        tracker.record_rx_bytes(100);
        let light = tracker.tick(start, true, 0);
        assert_eq!(light.stats.throughput_kbps, 1);

        // Active second: 500 KB/s = 4000 Kbps, 40 FPS (resumed from 0 frames -> full 40 FPS!).
        tracker.record_rx_bytes(500_000);
        for _ in 0..40 {
            tracker.record_frame_delivered();
        }
        let active = tracker.tick(start + Duration::from_secs(1), true, 0);
        assert!(active.stats.throughput_kbps >= 2000);
        assert_eq!(active.stats.fps, 40);
        let peak = active.stats.bandwidth_kbps.unwrap();

        // Next 4 idle ticks hold the true active reading without half-decaying.
        for offset in 2..=5 {
            let held = tracker.tick(start + Duration::from_secs(offset), true, 0);
            assert_eq!(held.stats.throughput_kbps, active.stats.throughput_kbps);
            assert_eq!(held.stats.fps, 40);
            assert_eq!(held.stats.bandwidth_kbps, Some(peak));
        }

        // After IDLE_HOLD_TICKS (4) empty ticks, transitions to idle (0) while retaining peak bandwidth.
        let idle = tracker.tick(start + Duration::from_secs(6), true, 0);
        assert_eq!(idle.stats.throughput_kbps, 0);
        assert_eq!(idle.stats.fps, 0);
        assert_eq!(idle.stats.bandwidth_kbps, Some(peak));

        // Resuming activity after idle immediately reports full 1s rate without 50% ramp-up.
        tracker.record_rx_bytes(375_000);
        for _ in 0..60 {
            tracker.record_frame_delivered();
        }
        let resumed = tracker.tick(start + Duration::from_secs(7), true, 0);
        assert_eq!(resumed.stats.throughput_kbps, 3000);
        assert_eq!(resumed.stats.fps, 60);
    }
}
