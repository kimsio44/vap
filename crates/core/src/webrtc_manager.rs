// crates/core/src/webrtc_manager.rs
//
// WebRTC Manager â€” gere la PeerConnection entre hote et client.
//
// Roles selon le peer :
//   HOST   : cree l'Offer SDP, envoie les frames H.264 via MediaTrack,
//             recoit les inputs clavier/souris via DataChannel
//   CLIENT : recoit l'Offer, repond avec Answer SDP,
//             recoit la video, envoie les inputs
//
// Signaling (echange SDP + ICE) : via le signaling server WebSocket (Phase 1)
// Donnees (video + inputs)      : directement P2P via WebRTC

use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::{error, info, warn, debug};

use webrtc::api::APIBuilder;
use webrtc::api::interceptor_registry::register_default_interceptors;
use webrtc::api::media_engine::{MediaEngine, MIME_TYPE_H264};
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::interceptor::registry::Registry;
use webrtc::peer_connection::RTCPeerConnection;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::rtp_transceiver::rtp_codec::{
    RTCRtpCodecCapability, RTCRtpCodecParameters, RTPCodecType,
};
use webrtc::track::track_local::track_local_static_sample::TrackLocalStaticSample;
use webrtc::track::track_local::TrackLocal;
use webrtc::data_channel::RTCDataChannel;
use webrtc::data_channel::data_channel_init::RTCDataChannelInit;
use webrtc::media::Sample;
use bytes::Bytes;

use crate::encoder::EncodedFrame;

// ---------------------------------------------------------------------------
// Erreurs
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error)]
pub enum WebRtcError {
    #[error("WebRTC internal error: {0}")]
    Internal(String),
    #[error("SDP error: {0}")]
    Sdp(String),
    #[error("ICE error: {0}")]
    Ice(String),
    #[error("Connection failed")]
    ConnectionFailed,
}

impl From<webrtc::Error> for WebRtcError {
    fn from(e: webrtc::Error) -> Self {
        WebRtcError::Internal(e.to_string())
    }
}

// ---------------------------------------------------------------------------
// Messages de signaling (echanges avec le serveur WebSocket Phase 1)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct IceCandidate {
    pub candidate: String,
    pub sdp_mid: Option<String>,
    pub sdp_mline_index: Option<u16>,
}

#[derive(Debug)]
pub enum SignalingOut {
    /// SDP Offer a envoyer au pair distant
    SdpOffer(String),
    /// SDP Answer a envoyer au pair distant
    SdpAnswer(String),
    /// ICE candidate a envoyer au pair distant
    IceCandidate(IceCandidate),
}

#[derive(Debug)]
pub enum SignalingIn {
    /// SDP Offer recu du pair distant
    SdpOffer(String),
    /// SDP Answer recu du pair distant
    SdpAnswer(String),
    /// ICE candidate recu du pair distant
    IceCandidate(IceCandidate),
}

// ---------------------------------------------------------------------------
// Configuration WebRTC
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct WebRtcConfig {
    /// Serveurs STUN/TURN pour le passage NAT
    pub ice_servers: Vec<String>,
    /// FPS cible pour le MediaTrack (doit correspondre au capturer)
    pub target_fps: u32,
}

impl Default for WebRtcConfig {
    fn default() -> Self {
        Self {
            ice_servers: vec![
                "stun:stun.l.google.com:19302".to_string(),
                "stun:stun1.l.google.com:19302".to_string(),
            ],
            target_fps: 60,
        }
    }
}

// ---------------------------------------------------------------------------
// WebRtcManager â€” cree et gere la PeerConnection
// ---------------------------------------------------------------------------

pub struct WebRtcManager {
    peer_connection: Arc<RTCPeerConnection>,
    video_track: Option<Arc<TrackLocalStaticSample>>,
    data_channel: Option<Arc<RTCDataChannel>>,
    config: WebRtcConfig,
}

impl WebRtcManager {
    /// Cree un nouveau WebRtcManager (hote ou client selon l'usage)
    pub async fn new(config: WebRtcConfig) -> Result<Self, WebRtcError> {
        // 1. MediaEngine avec codec H.264
        let mut media_engine = MediaEngine::default();
        media_engine.register_codec(
            RTCRtpCodecParameters {
                capability: RTCRtpCodecCapability {
                    mime_type:     MIME_TYPE_H264.to_owned(),
                    clock_rate:    90000, // Standard RTP clock pour video
                    channels:      0,
                    sdp_fmtp_line: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f".to_owned(),
                    rtcp_feedback: vec![],
                },
                payload_type: 102,
                ..Default::default()
            },
            RTPCodecType::Video,
        ).map_err(|e| WebRtcError::Internal(e.to_string()))?;

        // 2. Interceptors (RTCP, NACK, etc.)
        let mut registry = Registry::new();
        registry = register_default_interceptors(registry, &mut media_engine)
            .map_err(|e| WebRtcError::Internal(e.to_string()))?;

        // 3. API WebRTC
        let api = APIBuilder::new()
            .with_media_engine(media_engine)
            .with_interceptor_registry(registry)
            .build();

        // 4. Configuration ICE (STUN/TURN)
        let ice_servers: Vec<RTCIceServer> = config.ice_servers.iter().map(|url| {
            RTCIceServer {
                urls: vec![url.clone()],
                ..Default::default()
            }
        }).collect();

        let rtc_config = RTCConfiguration {
            ice_servers,
            ..Default::default()
        };

        // 5. Creer la PeerConnection
        let peer_connection = Arc::new(
            api.new_peer_connection(rtc_config).await
                .map_err(|e| WebRtcError::Internal(e.to_string()))?
        );

        info!("WebRTC PeerConnection created");

        Ok(Self {
            peer_connection,
            video_track: None,
            data_channel: None,
            config,
        })
    }

    // -----------------------------------------------------------------------
    // Setup HOTE : ajoute la video track + data channel + genere l'Offer
    // -----------------------------------------------------------------------

    /// Configure le manager comme hote (partage son ecran).
    /// Retourne le SDP Offer a envoyer au client via le signaling server.
    pub async fn setup_as_host(
        &mut self,
        signaling_tx: mpsc::UnboundedSender<SignalingOut>,
        input_tx: mpsc::UnboundedSender<InputEvent>,
    ) -> Result<String, WebRtcError> {
        // 1. Creer la video track H.264
        let video_track = Arc::new(TrackLocalStaticSample::new(
            RTCRtpCodecCapability {
                mime_type: MIME_TYPE_H264.to_owned(),
                clock_rate: 90000,
                sdp_fmtp_line: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f".to_owned(),
                ..Default::default()
            },
            "video".to_string(),
            "remotedesk-screen".to_string(),
        ));

        // 2. Ajouter la track a la PeerConnection
        let sender = self.peer_connection
            .add_track(Arc::clone(&video_track) as Arc<dyn TrackLocal + Send + Sync>)
            .await
            .map_err(|e| WebRtcError::Internal(e.to_string()))?;

        // Lire les RTCP packets (feedback de qualite du client)
        let pc_clone = Arc::clone(&self.peer_connection);
        tokio::spawn(async move {
            let mut rtcp_buf = vec![0u8; 1500];
            while let Ok((_, _)) = sender.read(&mut rtcp_buf).await {}
            info!("RTCP reader stopped");
        });

        self.video_track = Some(Arc::clone(&video_track));

        // 3. Creer le DataChannel pour les inputs clavier/souris
        let data_channel = self.peer_connection
            .create_data_channel(
                "inputs",
                Some(RTCDataChannelInit {
                    ordered: Some(false),      // Non-ordonnÃ© pour les inputs (latence < fiabilite)
                    max_retransmits: Some(0),  // Best-effort
                    ..Default::default()
                }),
            )
            .await
            .map_err(|e| WebRtcError::Internal(e.to_string()))?;

        // Handler : reception des inputs du client
        let input_tx_clone = input_tx.clone();
        data_channel.on_message(Box::new(move |msg| {
            let input_tx = input_tx_clone.clone();
            Box::pin(async move {
                if let Ok(text) = std::str::from_utf8(&msg.data) {
                    if let Ok(event) = serde_json::from_str::<InputEvent>(text) {
                        let _ = input_tx.send(event);
                    }
                }
            })
        }));

        self.data_channel = Some(data_channel);

        // 4. Handler ICE candidates
        let sig_tx = signaling_tx.clone();
        self.peer_connection.on_ice_candidate(Box::new(move |candidate| {
            let sig_tx = sig_tx.clone();
            Box::pin(async move {
                if let Some(c) = candidate {
                    match c.to_json() {
                        Ok(init) => {
                            let _ = sig_tx.send(SignalingOut::IceCandidate(IceCandidate {
                                candidate: init.candidate,
                                sdp_mid: init.sdp_mid,
                                sdp_mline_index: init.sdp_mline_index,
                            }));
                        }
                        Err(e) => warn!("ICE candidate to JSON failed: {}", e),
                    }
                }
            })
        }));

        // 5. Handler etat de connexion
        self.peer_connection.on_peer_connection_state_change(Box::new(|state| {
            Box::pin(async move {
                info!(state = ?state, "PeerConnection state changed");
                if state == RTCPeerConnectionState::Failed {
                    error!("PeerConnection FAILED");
                }
            })
        }));

        // 6. Generer l'Offer SDP
        let offer = self.peer_connection.create_offer(None).await
            .map_err(|e| WebRtcError::Sdp(e.to_string()))?;

        self.peer_connection.set_local_description(offer.clone()).await
            .map_err(|e| WebRtcError::Sdp(e.to_string()))?;

        let sdp = offer.sdp.clone();
        info!("SDP Offer created ({} bytes)", sdp.len());

        Ok(sdp)
    }

    // -----------------------------------------------------------------------
    // Setup CLIENT : recoit l'Offer, genere l'Answer
    // -----------------------------------------------------------------------

    /// Configure le manager comme client (recoit l'ecran).
    /// Prend le SDP Offer de l'hote, retourne le SDP Answer.
    pub async fn setup_as_client(
        &mut self,
        offer_sdp: String,
        signaling_tx: mpsc::UnboundedSender<SignalingOut>,
        frame_tx: mpsc::UnboundedSender<Vec<u8>>, // Frames H.264 decodees (NAL units)
    ) -> Result<String, WebRtcError> {
        // 1. Handler video track entrante
        let frame_tx_clone = frame_tx.clone();
        self.peer_connection.on_track(Box::new(move |track, _, _| {
            let frame_tx = frame_tx_clone.clone();
            Box::pin(async move {
                info!("Remote video track received: {}", track.codec().capability.mime_type);
                // Lire les RTP packets et les transmettre au decodeur
                loop {
                    match track.read_rtp().await {
                        Ok((rtp_packet, _)) => {
                            // Extraire le payload RTP (NAL units H.264)
                            let _ = frame_tx.send(rtp_packet.payload.to_vec());
                        }
                        Err(e) => {
                            debug!("Track read ended: {}", e);
                            break;
                        }
                    }
                }
            })
        }));

        // 2. Handler DataChannel entrant (inputs)
        self.peer_connection.on_data_channel(Box::new(|dc| {
            Box::pin(async move {
                info!("DataChannel received: {}", dc.label());
                // Le client utilise ce canal pour envoyer ses inputs
                // (connecte a input_handler.rs en Phase 3)
            })
        }));

        // 3. Handler ICE candidates
        let sig_tx = signaling_tx.clone();
        self.peer_connection.on_ice_candidate(Box::new(move |candidate| {
            let sig_tx = sig_tx.clone();
            Box::pin(async move {
                if let Some(c) = candidate {
                    if let Ok(init) = c.to_json() {
                        let _ = sig_tx.send(SignalingOut::IceCandidate(IceCandidate {
                            candidate: init.candidate,
                            sdp_mid: init.sdp_mid,
                            sdp_mline_index: init.sdp_mline_index,
                        }));
                    }
                }
            })
        }));

        // 4. Handler etat connexion
        self.peer_connection.on_peer_connection_state_change(Box::new(|state| {
            Box::pin(async move {
                info!(state = ?state, "PeerConnection state changed");
            })
        }));

        // 5. Appliquer l'Offer
        let offer = RTCSessionDescription::offer(offer_sdp)
            .map_err(|e| WebRtcError::Sdp(e.to_string()))?;
        self.peer_connection.set_remote_description(offer).await
            .map_err(|e| WebRtcError::Sdp(e.to_string()))?;

        // 6. Generer l'Answer
        let answer = self.peer_connection.create_answer(None).await
            .map_err(|e| WebRtcError::Sdp(e.to_string()))?;
        self.peer_connection.set_local_description(answer.clone()).await
            .map_err(|e| WebRtcError::Sdp(e.to_string()))?;

        let sdp = answer.sdp.clone();
        info!("SDP Answer created ({} bytes)", sdp.len());

        Ok(sdp)
    }

    // -----------------------------------------------------------------------
    // Signaling entrant (appele quand on recoit des messages du serveur WS)
    // -----------------------------------------------------------------------

    pub async fn handle_signaling(&self, msg: SignalingIn) -> Result<(), WebRtcError> {
        match msg {
            SignalingIn::SdpAnswer(sdp) => {
                let answer = RTCSessionDescription::answer(sdp)
                    .map_err(|e| WebRtcError::Sdp(e.to_string()))?;
                self.peer_connection.set_remote_description(answer).await
                    .map_err(|e| WebRtcError::Sdp(e.to_string()))?;
                info!("Remote SDP Answer applied");
            }
            SignalingIn::SdpOffer(sdp) => {
                let offer = RTCSessionDescription::offer(sdp)
                    .map_err(|e| WebRtcError::Sdp(e.to_string()))?;
                self.peer_connection.set_remote_description(offer).await
                    .map_err(|e| WebRtcError::Sdp(e.to_string()))?;
                info!("Remote SDP Offer applied");
            }
            SignalingIn::IceCandidate(ice) => {
                use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;
                let candidate = RTCIceCandidateInit {
                    candidate:          ice.candidate,
                    sdp_mid:            ice.sdp_mid,
                    sdp_mline_index:    ice.sdp_mline_index,
                    username_fragment:  None,
                };
                self.peer_connection.add_ice_candidate(candidate).await
                    .map_err(|e| WebRtcError::Ice(e.to_string()))?;
                debug!("ICE candidate added");
            }
        }
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Envoi de frames video (hote uniquement)
    // -----------------------------------------------------------------------

    /// Envoie une frame H.264 encodee sur la video track WebRTC.
    /// A appeler pour chaque EncodedFrame produite par l'encodeur.
    pub async fn send_video_frame(&self, frame: &EncodedFrame) -> Result<(), WebRtcError> {
        let track = self.video_track.as_ref()
            .ok_or_else(|| WebRtcError::Internal("No video track â€” call setup_as_host first".into()))?;

        // Calculer la duree en unite RTP (90kHz clock)
        // Pour 60fps : 90000 / 60 = 1500 unites RTP par frame
        let rtp_duration = 90000 / self.config.target_fps as u32;

        let sample = Sample {
            data:     Bytes::copy_from_slice(&frame.data),
            duration: std::time::Duration::from_secs(1) / self.config.target_fps,
            ..Default::default()
        };

        track.write_sample(&sample).await
            .map_err(|e| WebRtcError::Internal(format!("write_sample: {}", e)))?;

        debug!(seq = frame.seq, bytes = frame.size_bytes, "RTP frame sent");
        Ok(())
    }

    /// Ferme proprement la PeerConnection
    pub async fn close(&self) {
        if let Err(e) = self.peer_connection.close().await {
            warn!("PeerConnection close error: {}", e);
        }
        info!("WebRTC connection closed");
    }

    pub fn peer_connection(&self) -> Arc<RTCPeerConnection> {
        Arc::clone(&self.peer_connection)
    }
}

// ---------------------------------------------------------------------------
// InputEvent â€” messages clavier/souris envoyes par le client via DataChannel
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum InputEvent {
    MouseMove   { x: f32, y: f32 },
    MouseDown   { button: u8, x: f32, y: f32 },
    MouseUp     { button: u8, x: f32, y: f32 },
    MouseScroll { delta_x: f32, delta_y: f32 },
    KeyDown     { key_code: u32, modifiers: u8 },
    KeyUp       { key_code: u32, modifiers: u8 },
    Ping        { seq: u32 },
    Pong        { seq: u32 },
}

// ---------------------------------------------------------------------------
// Tache principale : boucle d'envoi video
// ---------------------------------------------------------------------------

/// Connecte le canal encoded_rx (sortie encodeur) a la video track WebRTC.
/// Tourne en boucle jusqu'a fermeture du canal.
pub async fn run_video_send_task(
    manager: Arc<tokio::sync::Mutex<WebRtcManager>>,
    mut encoded_rx: mpsc::Receiver<EncodedFrame>,
) {
    info!("Video send task started");
    let mut frames_sent = 0u64;
    let mut bytes_sent = 0u64;

    while let Some(frame) = encoded_rx.recv().await {
        let mgr = manager.lock().await;
        match mgr.send_video_frame(&frame).await {
            Ok(()) => {
                frames_sent += 1;
                bytes_sent += frame.size_bytes as u64;
                if frames_sent % 300 == 0 {
                    info!(
                        frames = frames_sent,
                        mb_sent = bytes_sent / 1_000_000,
                        "Video send stats"
                    );
                }
            }
            Err(e) => {
                warn!("send_video_frame error: {}", e);
            }
        }
    }

    info!(frames = frames_sent, mb = bytes_sent / 1_000_000, "Video send task done");
}