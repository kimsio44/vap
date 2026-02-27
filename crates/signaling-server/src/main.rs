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
