# setup_remotedesk.ps1
# Lance ce script depuis le dossier où se trouve ton Cargo.toml racine
# Exemple : PS C:\Users\kimsd\Downloads\files> .\setup_remotedesk.ps1

Write-Host "==> Creation de la structure RemoteDesk..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Créer les dossiers
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path "crates\signaling-server\src" | Out-Null
New-Item -ItemType Directory -Force -Path "crates\core\src"             | Out-Null
New-Item -ItemType Directory -Force -Path "crates\desktop-app\src"      | Out-Null

Write-Host "  [OK] Dossiers crees" -ForegroundColor Green

# ---------------------------------------------------------------------------
# crates\signaling-server\Cargo.toml
# ---------------------------------------------------------------------------
@'
[package]
name = "signaling-server"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "signaling-server"
path = "src/main.rs"

[dependencies]
tokio = { workspace = true }
tokio-tungstenite = { workspace = true }
futures-util = { workspace = true }
serde = { workspace = true }
serde_json = { workspace = true }
tracing = { workspace = true }
tracing-subscriber = { workspace = true }
anyhow = { workspace = true }
thiserror = { workspace = true }
uuid = { workspace = true }
'@ | Set-Content -Encoding UTF8 "crates\signaling-server\Cargo.toml"

Write-Host "  [OK] crates\signaling-server\Cargo.toml" -ForegroundColor Green

# ---------------------------------------------------------------------------
# crates\signaling-server\src\main.rs
# ---------------------------------------------------------------------------
@'
mod handler;
mod protocol;
mod session_store;

use std::env;
use tokio::net::TcpListener;
use tracing::{info, error};
use tracing_subscriber::EnvFilter;
use session_store::SessionStore;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_target(false)
        .compact()
        .init();

    let port = env::var("SIGNALING_PORT").unwrap_or_else(|_| "8080".to_string());
    let addr = format!("0.0.0.0:{}", port);

    let listener = TcpListener::bind(&addr).await?;
    info!("RemoteDesk Signaling Server listening on ws://{}", addr);
    info!("Press Ctrl+C to stop");

    let store = SessionStore::new();

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                let store_clone = store.clone();
                tokio::spawn(async move {
                    handler::handle_connection(stream, store_clone).await;
                });
            }
            Err(e) => {
                error!("Failed to accept connection: {}", e);
            }
        }
    }
}
'@ | Set-Content -Encoding UTF8 "crates\signaling-server\src\main.rs"

Write-Host "  [OK] crates\signaling-server\src\main.rs" -ForegroundColor Green

# ---------------------------------------------------------------------------
# crates\signaling-server\src\protocol.rs
# ---------------------------------------------------------------------------
@'
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub type PeerId = Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    Register {
        session_code: SessionCode,
        role: PeerRole,
    },
    Join {
        session_code: SessionCode,
    },
    SdpOffer {
        target_id: PeerId,
        sdp: String,
    },
    SdpAnswer {
        target_id: PeerId,
        sdp: String,
    },
    IceCandidate {
        target_id: PeerId,
        candidate: IceCandidatePayload,
    },
    Ping,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    Registered {
        peer_id: PeerId,
        session_code: SessionCode,
    },
    PeerJoined {
        peer_id: PeerId,
        role: PeerRole,
    },
    SdpOffer {
        from_id: PeerId,
        sdp: String,
    },
    SdpAnswer {
        from_id: PeerId,
        sdp: String,
    },
    IceCandidate {
        from_id: PeerId,
        candidate: IceCandidatePayload,
    },
    Error {
        code: ErrorCode,
        message: String,
    },
    Pong,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SessionCode(pub String);

impl SessionCode {
    pub fn generate() -> Self {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .subsec_nanos();
        let n = (nanos % 900_000) + 100_000;
        Self(format!("{:03}-{:03}", n / 1000, n % 1000))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PeerRole {
    Host,
    Client,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IceCandidatePayload {
    pub candidate: String,
    pub sdp_mid: Option<String>,
    pub sdp_mline_index: Option<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ErrorCode {
    SessionNotFound,
    SessionFull,
    InvalidMessage,
    InternalError,
}
'@ | Set-Content -Encoding UTF8 "crates\signaling-server\src\protocol.rs"

Write-Host "  [OK] crates\signaling-server\src\protocol.rs" -ForegroundColor Green

# ---------------------------------------------------------------------------
# crates\signaling-server\src\session_store.rs
# ---------------------------------------------------------------------------
@'
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tokio_tungstenite::tungstenite::Message;
use tokio::sync::mpsc::UnboundedSender;
use tracing::{info, warn};
use crate::protocol::{PeerId, PeerRole, SessionCode, ServerMessage};

#[derive(Debug)]
pub struct ConnectedPeer {
    pub id: PeerId,
    pub role: PeerRole,
    pub session_code: Option<SessionCode>,
    pub tx: UnboundedSender<Message>,
}

impl ConnectedPeer {
    pub fn send(&self, msg: &ServerMessage) {
        let json = serde_json::to_string(msg).expect("serialization never fails");
        if let Err(e) = self.tx.send(Message::Text(json)) {
            warn!(peer_id = %self.id, "Failed to send message to peer: {}", e);
        }
    }
}

#[derive(Debug)]
pub struct Session {
    pub code: SessionCode,
    pub host_id: PeerId,
    pub client_id: Option<PeerId>,
}

#[derive(Clone, Default)]
pub struct SessionStore {
    inner: Arc<RwLock<StoreInner>>,
}

#[derive(Default)]
struct StoreInner {
    peers: HashMap<PeerId, ConnectedPeer>,
    sessions: HashMap<SessionCode, Session>,
}

impl SessionStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn add_peer(&self, peer: ConnectedPeer) {
        let id = peer.id;
        let mut store = self.inner.write().await;
        store.peers.insert(id, peer);
        info!(peer_id = %id, "Peer connected (total: {})", store.peers.len());
    }

    pub async fn remove_peer(&self, peer_id: &PeerId) {
        let mut store = self.inner.write().await;
        let session_code = store.peers.get(peer_id).and_then(|p| p.session_code.clone());
        store.peers.remove(peer_id);
        info!(peer_id = %peer_id, "Peer disconnected (total: {})", store.peers.len());
        if let Some(code) = session_code {
            store.sessions.remove(&code);
            info!(session = %code.as_str(), "Session cleaned up");
        }
    }

    pub async fn register_host(&self, peer_id: PeerId, session_code: SessionCode) -> Result<(), &'static str> {
        let mut store = self.inner.write().await;
        if store.sessions.contains_key(&session_code) {
            return Err("session_code_taken");
        }
        if let Some(peer) = store.peers.get_mut(&peer_id) {
            peer.session_code = Some(session_code.clone());
            peer.role = PeerRole::Host;
        } else {
            return Err("peer_not_found");
        }
        store.sessions.insert(session_code.clone(), Session {
            code: session_code.clone(),
            host_id: peer_id,
            client_id: None,
        });
        info!(session = %session_code.as_str(), host = %peer_id, "New session created");
        Ok(())
    }

    pub async fn join_session(&self, client_peer_id: PeerId, session_code: &SessionCode) -> Result<PeerId, &'static str> {
        let mut store = self.inner.write().await;
        let session = store.sessions.get_mut(session_code).ok_or("session_not_found")?;
        if session.client_id.is_some() {
            return Err("session_full");
        }
        let host_id = session.host_id;
        session.client_id = Some(client_peer_id);
        if let Some(peer) = store.peers.get_mut(&client_peer_id) {
            peer.session_code = Some(session_code.clone());
            peer.role = PeerRole::Client;
        }
        info!(session = %session_code.as_str(), client = %client_peer_id, host = %host_id, "Client joined session");
        Ok(host_id)
    }

    pub async fn send_to(&self, target_id: &PeerId, msg: &ServerMessage) {
        let store = self.inner.read().await;
        if let Some(peer) = store.peers.get(target_id) {
            peer.send(msg);
        } else {
            warn!(target = %target_id, "send_to: peer not found");
        }
    }
}
'@ | Set-Content -Encoding UTF8 "crates\signaling-server\src\session_store.rs"

Write-Host "  [OK] crates\signaling-server\src\session_store.rs" -ForegroundColor Green

# ---------------------------------------------------------------------------
# crates\signaling-server\src\handler.rs
# ---------------------------------------------------------------------------
@'
use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio_tungstenite::{accept_async, tungstenite::Message};
use tracing::{error, info, warn};
use uuid::Uuid;
use crate::protocol::*;
use crate::session_store::{ConnectedPeer, SessionStore};

pub async fn handle_connection(stream: TcpStream, store: SessionStore) {
    let addr = stream.peer_addr().expect("connected streams have peer addr");
    info!(addr = %addr, "New TCP connection");

    let ws_stream = match accept_async(stream).await {
        Ok(ws) => ws,
        Err(e) => {
            error!(addr = %addr, "WebSocket handshake failed: {}", e);
            return;
        }
    };

    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
    let peer_id: PeerId = Uuid::new_v4();

    store.add_peer(ConnectedPeer {
        id: peer_id,
        role: PeerRole::Client,
        session_code: None,
        tx: tx.clone(),
    }).await;

    info!(peer_id = %peer_id, addr = %addr, "Peer registered in store");

    let (mut ws_sink, mut ws_stream) = ws_stream.split();

    let write_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if let Err(e) = ws_sink.send(msg).await {
                warn!("Write error: {}", e);
                break;
            }
        }
    });

    while let Some(msg_result) = ws_stream.next().await {
        match msg_result {
            Ok(Message::Text(text)) => {
                match serde_json::from_str::<ClientMessage>(&text) {
                    Ok(client_msg) => {
                        dispatch_message(peer_id, client_msg, &store, &tx).await;
                    }
                    Err(e) => {
                        warn!(peer_id = %peer_id, "Invalid JSON: {}", e);
                        let err = ServerMessage::Error {
                            code: ErrorCode::InvalidMessage,
                            message: format!("Cannot parse message: {}", e),
                        };
                        let _ = tx.send(Message::Text(serde_json::to_string(&err).unwrap()));
                    }
                }
            }
            Ok(Message::Ping(data)) => { let _ = tx.send(Message::Pong(data)); }
            Ok(Message::Close(_)) | Err(_) => {
                info!(peer_id = %peer_id, "WebSocket closed");
                break;
            }
            _ => {}
        }
    }

    store.remove_peer(&peer_id).await;
    write_task.abort();
    info!(peer_id = %peer_id, "Connection cleaned up");
}

async fn dispatch_message(
    peer_id: PeerId,
    msg: ClientMessage,
    store: &SessionStore,
    tx: &mpsc::UnboundedSender<Message>,
) {
    match msg {
        ClientMessage::Register { session_code, role } => {
            if role != PeerRole::Host {
                send_error(tx, ErrorCode::InvalidMessage, "Only hosts can register sessions");
                return;
            }
            match store.register_host(peer_id, session_code.clone()).await {
                Ok(()) => {
                    info!(peer_id = %peer_id, session = %session_code.as_str(), "Host registered");
                    let resp = ServerMessage::Registered { peer_id, session_code };
                    let _ = tx.send(Message::Text(serde_json::to_string(&resp).unwrap()));
                }
                Err(e) => send_error(tx, ErrorCode::InternalError, &format!("Register failed: {}", e)),
            }
        }
        ClientMessage::Join { session_code } => {
            match store.join_session(peer_id, &session_code).await {
                Ok(host_id) => {
                    info!(peer_id = %peer_id, host = %host_id, "Client joined session");
                    let confirm = ServerMessage::Registered { peer_id, session_code: session_code.clone() };
                    let _ = tx.send(Message::Text(serde_json::to_string(&confirm).unwrap()));
                    store.send_to(&host_id, &ServerMessage::PeerJoined { peer_id, role: PeerRole::Client }).await;
                }
                Err("session_not_found") => send_error(tx, ErrorCode::SessionNotFound, "Session not found. Check the code."),
                Err("session_full")      => send_error(tx, ErrorCode::SessionFull, "Session already has a client."),
                Err(e)                   => send_error(tx, ErrorCode::InternalError, e),
            }
        }
        ClientMessage::SdpOffer { target_id, sdp } => {
            info!(from = %peer_id, to = %target_id, "Relaying SDP Offer");
            store.send_to(&target_id, &ServerMessage::SdpOffer { from_id: peer_id, sdp }).await;
        }
        ClientMessage::SdpAnswer { target_id, sdp } => {
            info!(from = %peer_id, to = %target_id, "Relaying SDP Answer");
            store.send_to(&target_id, &ServerMessage::SdpAnswer { from_id: peer_id, sdp }).await;
        }
        ClientMessage::IceCandidate { target_id, candidate } => {
            store.send_to(&target_id, &ServerMessage::IceCandidate { from_id: peer_id, candidate }).await;
        }
        ClientMessage::Ping => {
            let _ = tx.send(Message::Text(serde_json::to_string(&ServerMessage::Pong).unwrap()));
        }
    }
}

fn send_error(tx: &mpsc::UnboundedSender<Message>, code: ErrorCode, message: &str) {
    let msg = ServerMessage::Error { code, message: message.to_string() };
    let _ = tx.send(Message::Text(serde_json::to_string(&msg).unwrap()));
}
'@ | Set-Content -Encoding UTF8 "crates\signaling-server\src\handler.rs"

Write-Host "  [OK] crates\signaling-server\src\handler.rs" -ForegroundColor Green

# ---------------------------------------------------------------------------
# crates\core\Cargo.toml
# ---------------------------------------------------------------------------
@'
[package]
name = "remotedesk-core"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { workspace = true }
serde = { workspace = true }
serde_json = { workspace = true }
anyhow = { workspace = true }
thiserror = { workspace = true }
tracing = { workspace = true }
uuid = { workspace = true }
'@ | Set-Content -Encoding UTF8 "crates\core\Cargo.toml"

Write-Host "  [OK] crates\core\Cargo.toml" -ForegroundColor Green

# ---------------------------------------------------------------------------
# crates\core\src\lib.rs + stubs
# ---------------------------------------------------------------------------
@'
// Stub — sera complété en Phase 2
pub mod webrtc_manager;
pub mod capture;
pub mod encoder;
pub mod input_handler;
'@ | Set-Content -Encoding UTF8 "crates\core\src\lib.rs"

"// TODO Phase 2 - webrtc_manager" | Set-Content -Encoding UTF8 "crates\core\src\webrtc_manager.rs"
"// TODO Phase 2 - capture"        | Set-Content -Encoding UTF8 "crates\core\src\capture.rs"
"// TODO Phase 2 - encoder"        | Set-Content -Encoding UTF8 "crates\core\src\encoder.rs"
"// TODO Phase 2 - input_handler"  | Set-Content -Encoding UTF8 "crates\core\src\input_handler.rs"

Write-Host "  [OK] crates\core\src\" -ForegroundColor Green

# ---------------------------------------------------------------------------
# crates\desktop-app\Cargo.toml
# ---------------------------------------------------------------------------
@'
[package]
name = "desktop-app"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { workspace = true }
anyhow = { workspace = true }
tracing = { workspace = true }
tracing-subscriber = { workspace = true }
remotedesk-core = { path = "../core" }
'@ | Set-Content -Encoding UTF8 "crates\desktop-app\Cargo.toml"

Write-Host "  [OK] crates\desktop-app\Cargo.toml" -ForegroundColor Green

# ---------------------------------------------------------------------------
# crates\desktop-app\src\main.rs
# ---------------------------------------------------------------------------
@'
// Stub — sera remplacé par Tauri en Phase 4
fn main() {
    println!("RemoteDesk Desktop App — stub (Phase 4)");
}
'@ | Set-Content -Encoding UTF8 "crates\desktop-app\src\main.rs"

Write-Host "  [OK] crates\desktop-app\src\main.rs" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Résumé
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Structure creee avec succes !" -ForegroundColor Green
Write-Host ""
Write-Host "Lance maintenant :" -ForegroundColor Yellow
Write-Host "  cargo run -p signaling-server" -ForegroundColor White
Write-Host ""
Write-Host "Structure finale :" -ForegroundColor Cyan
Get-ChildItem -Recurse -Include "*.toml","*.rs" | Select-Object FullName | ForEach-Object {
    Write-Host "  $($_.FullName.Replace((Get-Location).Path + '\', ''))"
}
