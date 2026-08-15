use axum::{Json, extract::State, routing::get};
use serde::Serialize;
use utoipa::ToSchema;

use crate::api::context::ApiContext;

/// Runtime report of which external integrations this deployment has configured.
///
/// The web client fetches this once at startup to hide SSO buttons, the
/// Gmail/GitHub/Outlook connect flows, and Stripe billing UI when the matching
/// provider is not configured (graceful degradation for self-host).
#[derive(Debug, Serialize, ToSchema)]
pub struct Capabilities {
    pub google_login: bool,
    pub github_login: bool,
    pub microsoft_login: bool,
    pub stripe_billing: bool,
}

#[utoipa::path(
    get,
    path = "/capabilities",
    operation_id = "capabilities",
    responses((status = 200, body = Capabilities))
)]
pub async fn handler(State(ctx): State<ApiContext>) -> Json<Capabilities> {
    Json(Capabilities {
        google_login: ctx.google_login_configured,
        github_login: ctx.github_login_configured,
        microsoft_login: ctx.microsoft_login_configured,
        stripe_billing: ctx.stripe_configured,
    })
}

pub fn router() -> axum::Router<ApiContext> {
    axum::Router::new().route("/", get(handler))
}
