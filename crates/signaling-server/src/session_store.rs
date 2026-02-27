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
