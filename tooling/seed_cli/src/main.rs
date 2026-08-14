#![deny(missing_docs)]
//! The Seed CLI to enable easy populate Macro with seed data.

mod config;
mod entity;
mod service;

use anyhow::Context;
use clap::Parser;
use entity::EntityCommand;
use fusionauth::FusionAuthClient;
use macro_entrypoint::MacroEntrypoint;
use macro_env::Environment;
use service::{auth::Auth, db::Db};
use sqlx::postgres::PgPoolOptions;

use crate::{
    config::{EnvVars, SeedCliContext},
    service::s3::S3,
};

/// The Seed CLI for populating Macro with seed data.
#[derive(Debug, Parser)]
#[command(name = "seed_cli", about = "Seed CLI to populate Macro with seed data")]
pub struct Cli {
    /// The entity and action to perform
    #[command(subcommand)]
    pub command: EntityCommand,
}

/// Entrypoint for cli
#[tokio::main]
pub async fn main() -> anyhow::Result<()> {
    // Force to use local tracing
    MacroEntrypoint::new(Environment::Local).init();
    let cli = Cli::parse();
    // The gmail entity talks only to Google — dispatch it before the required
    // env vars / database connection so it works without the local stack.
    if let EntityCommand::Gmail(args) = cli.command {
        return args.execute().await;
    }
    let env_vars = EnvVars::new()?;
    cli.command.validate_environment(&env_vars)?;
    tracing::trace!("initializing");

    let database_url = if in_compose_bootstrap() {
        // Inside the Compose network the service hostnames resolve directly;
        // rewriting `postgres:5432` to `localhost:5432` would break the
        // connection, so keep the URL as-is.
        env_vars.database_url.as_ref().to_string()
    } else {
        env_vars
            .database_url
            .replace("postgres:5432", "localhost:5432")
    };
    cli.command.pre_connect(&database_url).await?;

    let db = PgPoolOptions::new()
        .min_connections(1)
        .max_connections(95)
        .connect(&database_url)
        .await
        .context("could not connect to db")?;
    tracing::trace!("initialized db");

    let fusionauth_client = FusionAuthClient::new(
        env_vars.fusionauth_api_key_secret_key.to_string(),
        env_vars.fusionauth_client_id.to_string(),
        env_vars.fusionauth_client_secret_key.to_string(),
        if in_compose_bootstrap() {
            env_vars.fusionauth_base_url.as_ref().to_string()
        } else {
            transform_docker_url(&env_vars.fusionauth_base_url)
        },
        "".to_string(), // NOTE: Not needed. Oauth redirect uri
        "".to_string(), // NOTE: Not needed. Google Client id
        "".to_string(), // NOTE: Not needed. Google client secret
    );
    tracing::trace!("initialized fusionauth client");

    let context = SeedCliContext {
        db: Db::new(db),
        fusionauth_client: Auth::new(fusionauth_client),
        s3: S3::new(
            &env_vars.document_storage_bucket,
            macro_aws_config::s3_client().await,
        ),
        doc_content: crate::config::DocContentClients::from_env(),
    };

    cli.command.execute(context).await
}

/// Whether the seed CLI is running as the one-shot self-host Compose
/// bootstrap service (`SEED_BOOTSTRAP=true`). In that context the Compose
/// service hostnames (`postgres`, `fusionauth`, …) resolve directly on the
/// container network and must not be rewritten to `localhost`.
fn in_compose_bootstrap() -> bool {
    std::env::var("SEED_BOOTSTRAP").as_deref() == Ok("true")
}

/// Transforms the docker-network url to be localhost
fn transform_docker_url(url: &str) -> String {
    if let Some(rest) = url.strip_prefix("http://")
        && let Some(colon_pos) = rest.find(':')
    {
        return format!("http://localhost{}", &rest[colon_pos..]);
    }
    url.to_string()
}
