//! Authenticated reverse proxy for web previews running on any execution host.
//!
//! The browser always talks to the workspace relay. The execution host keeps
//! its ports on loopback and answers relay requests over its existing outbound
//! connection, so previews need no public port or separate tunnel account.

use std::time::Duration;

use axum::body::{to_bytes, Body};
use axum::extract::ws::{Message as WsMessage, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, Request, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use base64::Engine;
use futures::{SinkExt, StreamExt};
use patchwork_core::host::RelayToHost;
use patchwork_core::models::PreviewStatus;
use patchwork_core::new_id;

use crate::state::Shared;

const MAX_BODY: usize = 16 * 1024 * 1024;

pub async fn proxy_root(
    state: State<Shared>,
    id: Path<String>,
    websocket: Result<WebSocketUpgrade, axum::extract::ws::rejection::WebSocketUpgradeRejection>,
    request: Request,
) -> Response {
    forward(state.0, id.0, String::new(), websocket.ok(), request).await
}

pub async fn proxy(
    State(state): State<Shared>,
    Path((id, path)): Path<(String, String)>,
    websocket: Result<WebSocketUpgrade, axum::extract::ws::rejection::WebSocketUpgradeRejection>,
    request: Request,
) -> Response {
    forward(state, id, path, websocket.ok(), request).await
}

async fn forward(
    state: Shared,
    id: String,
    path: String,
    websocket: Option<WebSocketUpgrade>,
    request: Request,
) -> Response {
    let Some((grant, from_query)) = preview_grant(&request) else {
        return (StatusCode::UNAUTHORIZED, "preview access expired").into_response();
    };
    if !state.valid_preview_grant(&id, &grant) {
        return (StatusCode::UNAUTHORIZED, "preview access expired").into_response();
    }

    let Ok(Some(preview)) = state.store.preview(&id) else {
        return (StatusCode::NOT_FOUND, "no such preview").into_response();
    };
    if preview.status != PreviewStatus::Live {
        return (StatusCode::SERVICE_UNAVAILABLE, "preview is not running").into_response();
    }

    if let Some(websocket) = websocket {
        let target_path = target_path(&path, request.uri().query());
        let headers = proxy_headers(request.headers());
        let websocket = match websocket_protocol(request.headers()) {
            Some(protocol) => websocket.protocols([protocol]),
            None => websocket,
        };
        let socket_state = state.clone();
        let host_id = preview.host_id;
        let preview_id = preview.id;
        let response = websocket.on_upgrade(move |socket| {
            bridge_socket(socket_state, host_id, preview_id, target_path, headers, socket)
        });
        return response.into_response();
    }

    let method = request.method().to_string();
    let target_path = target_path(&path, request.uri().query());
    let headers = proxy_headers(request.headers());
    let body = match to_bytes(request.into_body(), MAX_BODY).await {
        Ok(body) => base64::engine::general_purpose::STANDARD.encode(body),
        Err(_) => return (StatusCode::PAYLOAD_TOO_LARGE, "preview request is too large").into_response(),
    };

    let request_id = new_id();
    let (tx, rx) = tokio::sync::oneshot::channel();
    state.preview_waiters.write().await.insert(request_id.clone(), tx);
    if !state
        .send_to_host(
            &preview.host_id,
            RelayToHost::PreviewRequest {
                request_id: request_id.clone(),
                preview_id: preview.id,
                method,
                path: target_path,
                headers,
                body,
            },
        )
        .await
    {
        state.preview_waiters.write().await.remove(&request_id);
        return (StatusCode::SERVICE_UNAVAILABLE, "preview host is offline").into_response();
    }

    let reply = match tokio::time::timeout(Duration::from_secs(60), rx).await {
        Ok(Ok(reply)) => reply,
        _ => {
            state.preview_waiters.write().await.remove(&request_id);
            return (StatusCode::GATEWAY_TIMEOUT, "preview did not answer").into_response();
        }
    };
    if let Some(error) = reply.error {
        return (StatusCode::BAD_GATEWAY, error).into_response();
    }
    let body = match base64::engine::general_purpose::STANDARD.decode(reply.body) {
        Ok(body) if body.len() <= MAX_BODY => body,
        _ => return (StatusCode::BAD_GATEWAY, "preview returned an invalid response").into_response(),
    };
    let status = StatusCode::from_u16(reply.status).unwrap_or(StatusCode::BAD_GATEWAY);
    let mut response = Response::new(Body::from(body));
    *response.status_mut() = status;
    for (name, value) in reply.headers {
        let lower = name.to_ascii_lowercase();
        if matches!(
            lower.as_str(),
            "clear-site-data" | "connection" | "content-length" | "transfer-encoding" | "upgrade"
        ) {
            continue;
        }
        let Some(value) = rewrite_response_header(&lower, &value) else {
            continue;
        };
        if let (Ok(name), Ok(value)) = (
            axum::http::HeaderName::try_from(name),
            HeaderValue::from_str(&value),
        ) {
            response.headers_mut().append(name, value);
        }
    }
    if from_query {
        let secure = if state.public_url.starts_with("https://") { "; Secure" } else { "" };
        if let Ok(cookie) = HeaderValue::from_str(&format!(
            "patchwork_preview={grant}; HttpOnly; SameSite=Lax; Path=/; Max-Age=7200{secure}"
        )) {
            response.headers_mut().append(axum::http::header::SET_COOKIE, cookie);
        }
    }
    response
}

async fn bridge_socket(
    state: Shared,
    host_id: String,
    preview_id: String,
    path: String,
    headers: Vec<(String, String)>,
    socket: WebSocket,
) {
    let socket_id = new_id();
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    state.preview_sockets.write().await.insert(socket_id.clone(), tx);
    if !state
        .send_to_host(
            &host_id,
            RelayToHost::PreviewSocketOpen {
                socket_id: socket_id.clone(),
                preview_id,
                path,
                headers,
            },
        )
        .await
    {
        state.preview_sockets.write().await.remove(&socket_id);
        return;
    }
    match tokio::time::timeout(Duration::from_secs(10), rx.recv()).await {
        Ok(Some(crate::state::PreviewSocketEvent::Ready(None))) => {}
        _ => {
            state.preview_sockets.write().await.remove(&socket_id);
            return;
        }
    }

    let (mut writer, mut reader) = socket.split();
    loop {
        tokio::select! {
            incoming = reader.next() => {
                match incoming {
                    Some(Ok(WsMessage::Text(data))) => {
                        let _ = state.send_to_host(
                            &host_id,
                            RelayToHost::PreviewSocketData {
                                socket_id: socket_id.clone(),
                                data: data.to_string(),
                                binary: false,
                            },
                        ).await;
                    }
                    Some(Ok(WsMessage::Binary(data))) => {
                        let _ = state.send_to_host(
                            &host_id,
                            RelayToHost::PreviewSocketData {
                                socket_id: socket_id.clone(),
                                data: base64::engine::general_purpose::STANDARD.encode(data),
                                binary: true,
                            },
                        ).await;
                    }
                    Some(Ok(WsMessage::Close(_))) => {
                        // tungstenite queued the required close reply while reading.
                        let _ = writer.flush().await;
                        tokio::time::sleep(Duration::from_millis(50)).await;
                        break;
                    }
                    Some(Err(_)) | None => break,
                    _ => {}
                }
            }
            outgoing = rx.recv() => {
                match outgoing {
                    Some(crate::state::PreviewSocketEvent::Data { data, binary: false }) => {
                        if writer.send(WsMessage::Text(data.into())).await.is_err() { break; }
                    }
                    Some(crate::state::PreviewSocketEvent::Data { data, binary: true }) => {
                        let Ok(data) = base64::engine::general_purpose::STANDARD.decode(data) else { break };
                        if writer.send(WsMessage::Binary(data.into())).await.is_err() { break; }
                    }
                    Some(crate::state::PreviewSocketEvent::Close) => {
                        let _ = writer.send(WsMessage::Close(None)).await;
                        tokio::time::sleep(Duration::from_millis(50)).await;
                        break;
                    }
                    None => break,
                    Some(crate::state::PreviewSocketEvent::Ready(_)) => {}
                }
            }
        }
    }
    state.preview_sockets.write().await.remove(&socket_id);
    let _ = state
        .send_to_host(&host_id, RelayToHost::PreviewSocketClose { socket_id })
        .await;
}

fn websocket_protocol(headers: &HeaderMap) -> Option<String> {
    headers
        .get(axum::http::header::SEC_WEBSOCKET_PROTOCOL)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(',').map(str::trim).find(|value| !value.is_empty()))
        .map(str::to_string)
}

fn preview_grant(request: &Request) -> Option<(String, bool)> {
    if let Some(grant) = request
        .uri()
        .query()
        .and_then(|query| {
            query.split('&').find_map(|pair| {
                let (key, value) = pair.split_once('=')?;
                (key == "grant").then(|| value.to_string())
            })
        })
    {
        return Some((grant, true));
    }
    request
        .headers()
        .get(axum::http::header::COOKIE)
        .and_then(|value| value.to_str().ok())
        .and_then(|cookies| {
            cookies.split(';').find_map(|cookie| {
                let (name, value) = cookie.trim().split_once('=')?;
                (name == "patchwork_preview").then(|| (value.to_string(), false))
            })
        })
}

fn target_path(path: &str, query: Option<&str>) -> String {
    let query = query
        .map(|query| {
            query
                .split('&')
                .filter(|pair| pair.split_once('=').map(|(key, _)| key) != Some("grant"))
                .collect::<Vec<_>>()
                .join("&")
        })
        .filter(|query| !query.is_empty());
    format!("/{}{}", path, query.map(|query| format!("?{query}")).unwrap_or_default())
}

fn proxy_headers(headers: &HeaderMap) -> Vec<(String, String)> {
    headers
        .iter()
        .filter(|(name, _)| {
            !matches!(
                name.as_str(),
                "authorization" | "connection" | "content-length" | "host" | "proxy-authorization" | "transfer-encoding" | "upgrade"
            )
        })
        .filter_map(|(name, value)| {
            let value = value.to_str().ok()?;
            let value = if name == axum::http::header::COOKIE {
                value
                    .split(';')
                    .filter(|cookie| !cookie.trim().starts_with("patchwork_preview="))
                    .collect::<Vec<_>>()
                    .join(";")
            } else {
                value.to_string()
            };
            (!value.is_empty()).then(|| (name.to_string(), value))
        })
        .collect()
}

fn rewrite_response_header(name: &str, value: &str) -> Option<String> {
    if name == "set-cookie" {
        let mut parts = value.split(';');
        let cookie = parts.next()?.trim();
        if cookie
            .split_once('=')
            .is_some_and(|(name, _)| name.trim().eq_ignore_ascii_case("patchwork_preview"))
        {
            return None;
        }
        return Some(
            std::iter::once(cookie)
                .chain(parts.map(str::trim).filter(|part| {
                    !part
                        .split_once('=')
                        .is_some_and(|(name, _)| name.trim().eq_ignore_ascii_case("domain"))
                }))
                .collect::<Vec<_>>()
                .join("; "),
        );
    }
    if name != "location" {
        return Some(value.to_string());
    }
    Some(
        reqwest::Url::parse(value)
            .ok()
            .filter(|url| matches!(url.host_str(), Some("127.0.0.1" | "localhost")))
            .map(|url| format!("{}{}", url.path(), url.query().map(|query| format!("?{query}")).unwrap_or_default()))
            .unwrap_or_else(|| value.to_string()),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grants_do_not_reach_the_preview_application() {
        assert_eq!(target_path("checkout", Some("grant=secret&q=hat")), "/checkout?q=hat");
    }

    #[test]
    fn requested_websocket_protocol_is_preserved() {
        let headers = HeaderMap::from_iter([(
            axum::http::header::SEC_WEBSOCKET_PROTOCOL,
            HeaderValue::from_static("vite-hmr, fallback"),
        )]);
        assert_eq!(websocket_protocol(&headers).as_deref(), Some("vite-hmr"));
    }

    #[test]
    fn preview_response_headers_stay_on_the_preview_origin() {
        assert_eq!(
            rewrite_response_header("location", "http://127.0.0.1:5173/login?next=/"),
            Some("/login?next=/".into())
        );
        assert_eq!(
            rewrite_response_header("set-cookie", "theme=dark; Domain=patchwork.sh; Path=/"),
            Some("theme=dark; Path=/".into())
        );
        assert_eq!(
            rewrite_response_header("set-cookie", "patchwork_preview=stolen; Path=/"),
            None
        );
    }

    #[tokio::test]
    async fn a_preview_is_fetched_through_its_execution_host() {
        use patchwork_core::host::HostToRelay;
        use patchwork_core::models::Preview;
        use tower::ServiceExt;

        let path = std::env::temp_dir().join(format!("patchwork-preview-{}.sqlite", new_id()));
        let store = crate::store::Store::open(&path).unwrap();
        store.create_workspace("ws", "Test").unwrap();
        store
            .upsert_preview(&Preview {
                id: "preview".into(),
                task_id: "task".into(),
                host_id: "host".into(),
                run_id: Some("run".into()),
                label: "App".into(),
                port: 5173,
                url: String::new(),
                status: PreviewStatus::Live,
                local_only: false,
                created_at: 1,
                stopped_at: None,
            })
            .unwrap();
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://relay/w/ws".into(),
            "relay-host".into(),
        ));
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        state
            .hosts
            .write()
            .await
            .insert("host".into(), crate::state::HostConn { tx });
        let response_state = state.clone();
        tokio::spawn(async move {
            if let Some(RelayToHost::PreviewRequest {
                request_id,
                method,
                path,
                ..
            }) = rx.recv().await
            {
                assert_eq!(method, "GET");
                assert_eq!(path, "/hello?q=hat");
                crate::orchestrator::handle_host_message(
                    &response_state,
                    "host",
                    HostToRelay::PreviewResponse {
                        request_id,
                        status: 200,
                        headers: vec![("content-type".into(), "text/plain".into())],
                        body: base64::engine::general_purpose::STANDARD.encode("hello"),
                        error: None,
                    },
                )
                .await;
            }
        });

        let grant = state.grant_preview("preview");
        let response = crate::api::router(state.clone())
            .oneshot(
                axum::http::Request::builder()
                    .uri(format!("/preview/preview/hello?grant={grant}&q=hat"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            to_bytes(response.into_body(), 1024).await.unwrap().as_ref(),
            b"hello"
        );
        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
    }
}
