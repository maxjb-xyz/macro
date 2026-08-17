//! Gmail inbox polling fallback for self-host deployments without Pub/Sub push.
//!
//! When `GMAIL_GCP_QUEUE` is empty the push `watch` is skipped and the sync
//! cursor is seeded from the mailbox profile. This loop is the other half of
//! that fallback: it periodically re-checks active inboxes so new mail still
//! arrives, just on a delay instead of in real time. Push deployments get the
//! webhook instead and never run this.

use models_email::gmail::inbox_sync::{
    GmailMessagePayload, InboxSyncOperation, InboxSyncPubsubMessage,
};
use sqlx::PgPool;
use sqs_client::SQS;
use std::time::Duration;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::outbound::email_api::GmailApi;

/// Runs the polling loop until `cancellation_token` is cancelled.
pub async fn run(
    db: PgPool,
    sqs: SQS,
    email_api: GmailApi,
    poll_interval: Duration,
    cancellation_token: CancellationToken,
) {
    loop {
        if cancellation_token.is_cancelled() {
            return;
        }

        poll_once(&db, &sqs, &email_api).await;

        tokio::select! {
            _ = tokio::time::sleep(poll_interval) => {}
            _ = cancellation_token.cancelled() => return,
        }
    }
}

/// Enqueues one inbox-sync trigger per active Gmail link.
async fn poll_once(db: &PgPool, sqs: &SQS, email_api: &GmailApi) {
    let link_ids = match fetch_active_gmail_link_ids(db).await {
        Ok(ids) => ids,
        Err(error) => {
            tracing::error!(error = ?error, "failed to fetch active Gmail links for poll");
            return;
        }
    };

    for link_id in link_ids {
        // In polling mode (no Pub/Sub topic) `register_subscription` skips the
        // Gmail watch and returns the profile historyId as the sync cursor.
        let subscription = match email_api.register_subscription(link_id).await {
            Ok(subscription) => subscription,
            Err(error) => {
                // AuthRequired means the grant died and the link is handled by
                // the reauth flow elsewhere; transient errors get another
                // chance on the next poll.
                tracing::debug!(%link_id, error = ?error, "skipping Gmail poll for link");
                continue;
            }
        };

        let cursor = subscription.cursor.as_str().to_string();
        let history_id = match cursor.parse::<u64>() {
            Ok(id) => id,
            Err(_) => {
                tracing::warn!(%link_id, %cursor, "Gmail profile returned a non-numeric history id");
                continue;
            }
        };

        let message = InboxSyncPubsubMessage {
            link_id,
            operation: InboxSyncOperation::GmailMessage(GmailMessagePayload { history_id }),
        };

        if let Err(error) = sqs.enqueue_gmail_inbox_sync_notification(message).await {
            tracing::warn!(%link_id, error = ?error, "failed to enqueue Gmail poll sync");
        }
    }
}

/// Returns the ids of Gmail links that are active and not awaiting reauth.
///
/// Uses a runtime query (not a `query_scalar!` macro) so the SQL is not subject
/// to the checked-in `.sqlx` offline cache, which would need a live database to
/// regenerate for a new statement.
#[allow(clippy::disallowed_methods, reason = "runtime query avoids regenerating the .sqlx cache in the fork")]
async fn fetch_active_gmail_link_ids(pool: &PgPool) -> Result<Vec<Uuid>, sqlx::Error> {
    sqlx::query_scalar(
        "SELECT id FROM email_links \
         WHERE is_sync_active = TRUE AND provider = 'GMAIL' AND needs_reauth = FALSE",
    )
    .fetch_all(pool)
    .await
}
