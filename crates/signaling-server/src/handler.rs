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
