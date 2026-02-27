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

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SessionCode(pub String);

impl Serialize for SessionCode {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for SessionCode {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(SessionCode(String::deserialize(d)?))
    }
}
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
