//! Relay-hosted previews are reachable by every workspace member through the
//! relay itself, so a dev server started by a hosted agent needs no tunnel.

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};

use crate::state::Shared;

pub async fn proxy_root(state: State<Shared>, id: Path<String>) -> Response {
    forward(state, id.0, String::new()).await
}

pub async fn proxy(state: State<Shared>, Path((id, path)): Path<(String, String)>) -> Response {
    forward(state, id, path).await
}

async fn forward(State(state): State<Shared>, id: String, path: String) -> Response {
    let Ok(Some(preview)) = state.store.preview(&id) else {
        return (StatusCode::NOT_FOUND, "no such preview").into_response();
    };
    if preview.local_only {
        return (
            StatusCode::CONFLICT,
            "this preview runs on a desktop; open it from that machine",
        )
            .into_response();
    }
    if preview.status != patchwork_core::models::PreviewStatus::Live {
        return (StatusCode::SERVICE_UNAVAILABLE, "preview is not running").into_response();
    }

    let target = format!("http://127.0.0.1:{}/{}", preview.port, path);
    let client = reqwest::Client::new();
    match client.get(&target).send().await {
        Ok(response) => {
            let status = StatusCode::from_u16(response.status().as_u16())
                .unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
            let mut headers = HeaderMap::new();
            if let Some(content_type) = response.headers().get(reqwest::header::CONTENT_TYPE) {
                if let Ok(value) = axum::http::HeaderValue::from_bytes(content_type.as_bytes()) {
                    headers.insert(axum::http::header::CONTENT_TYPE, value);
                }
            }
            match response.bytes().await {
                Ok(bytes) => (status, headers, Body::from(bytes)).into_response(),
                Err(err) => (StatusCode::BAD_GATEWAY, err.to_string()).into_response(),
            }
        }
        Err(err) => (
            StatusCode::BAD_GATEWAY,
            format!("preview did not answer: {err}"),
        )
            .into_response(),
    }
}
