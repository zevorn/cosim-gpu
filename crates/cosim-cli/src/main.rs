// SPDX-License-Identifier: Apache-2.0

//! Exposes topology inspection and supervised execution through the command line.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use anyhow::{Context, Result};
use clap::builder::BoolishValueParser;
use clap::{ArgAction, Args, Parser, Subcommand};
use cosim_runtime::{Event, ExecEnv, RunOptions, SessionLayout, Shutdown, Status};
use tokio::signal::unix::{SignalKind, signal};
use tokio::sync::mpsc;

#[derive(Parser)]
#[command(
    name = "cosim",
    version,
    about = "Run QEMU and device models from a YAML topology"
)]
struct Cli {
    /// Directory searched for imports that are not relative to the importing file.
    #[arg(long, global = true, default_value = "samples")]
    samples: PathBuf,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Validate a topology; --assets also checks local input files.
    Validate {
        topology: PathBuf,
        /// Optional guest boot and storage inputs stored separately from the topology.
        #[arg(long)]
        payload: Option<PathBuf>,
        #[arg(long)]
        assets: bool,
    },
    /// Print machines and device connections as a Mermaid flowchart.
    Graph { topology: PathBuf },
    /// Print the JSON Schema of topology documents.
    Schema {
        /// Print the schema for a standalone payload document.
        #[arg(long)]
        payload: bool,
    },
    /// Start every process and supervise the session until it ends.
    Run {
        #[command(flatten)]
        target: Target,
        /// Validate and display the selected image and launch plan without building or launching.
        #[arg(long)]
        dry_run: bool,
        /// Seconds each process has to become ready.
        #[arg(long, default_value_t = 120)]
        ready_timeout: u64,
        /// Seconds to run after every process is ready.
        #[arg(long)]
        run_for: Option<u64>,
        /// Image helper used for disk creation and overlays.
        #[arg(long, default_value = "qemu-img")]
        qemu_img: String,
        /// End the session when standard input is closed.
        #[arg(
            long,
            env = "COSIM_STDIN_LIFELINE",
            action = ArgAction::SetTrue,
            value_parser = BoolishValueParser::new()
        )]
        stdin_lifeline: bool,
    },
    /// Remove resources of a stopped session and keep its logs.
    Clean { run_dir: PathBuf },
}

#[derive(Args)]
struct Target {
    topology: PathBuf,
    /// Guest boot and storage inputs stored separately from machine hardware.
    #[arg(long)]
    payload: Option<PathBuf>,
    /// New session directory; defaults to .cosim/<random name>.
    #[arg(long)]
    run_dir: Option<PathBuf>,
    /// New memory pool directory; defaults to /dev/shm/cosim-<name>-<hash> on Linux.
    #[arg(long)]
    pool_dir: Option<PathBuf>,
}

/// How the default run directory is named.
enum Purpose {
    DryRun,
    Run,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    // Children are spawned from this thread, which lives as long as the
    // launcher, so their parent-death signal fires only when the launcher exits.
    let result = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("start the async runtime")
        .and_then(|runtime| runtime.block_on(execute(cli)));
    match result {
        Ok(code) => code,
        Err(error) => {
            eprintln!("cosim: {error:#}");
            ExitCode::FAILURE
        }
    }
}

async fn execute(cli: Cli) -> Result<ExitCode> {
    match cli.command {
        Command::Validate {
            topology,
            payload,
            assets,
        } => {
            let topology = cosim_topology::load(&topology, &cli.samples)?;
            let mut payload = payload
                .as_deref()
                .map(cosim_topology::load_payload)
                .transpose()?;
            if let Some(payload) = &mut payload {
                let workspace = image_workspace()?;
                cosim_runtime::prepare_image_profile(payload, &workspace, false)?;
            }
            cosim_topology::validate_payload(&topology, payload.as_ref())?;
            SessionLayout::check_identifiers(&topology)?;
            let page_size = cosim_runtime::page_size()?;
            for machine in &topology.machines {
                machine
                    .memory_layout(page_size)
                    .with_context(|| format!("machine {}", machine.id))?;
            }
            if assets {
                cosim_runtime::check_assets(&topology, payload.as_ref())?;
            }
            println!(
                "valid: {} machines, {} devices",
                topology.machines.len(),
                topology.device_count()
            );
        }
        Command::Graph { topology } => {
            let topology = cosim_topology::load(&topology, &cli.samples)?;
            print!("{}", cosim_topology::graph(&topology));
        }
        Command::Schema { payload } => {
            let schema = if payload {
                cosim_topology::payload_schema()
            } else {
                cosim_topology::schema()
            };
            println!("{}", serde_json::to_string_pretty(&schema)?);
        }
        Command::Run {
            target,
            dry_run,
            ready_timeout,
            run_for,
            qemu_img,
            stdin_lifeline,
        } => {
            let topology = cosim_topology::load(&target.topology, &cli.samples)?;
            let mut payload = target
                .payload
                .as_deref()
                .map(cosim_topology::load_payload)
                .transpose()?;
            let original_payload = payload.clone();
            let image = if let Some(payload) = &mut payload {
                let workspace = image_workspace()?;
                cosim_runtime::prepare_image_profile(payload, &workspace, !dry_run)?
            } else {
                None
            };
            cosim_topology::validate_payload(&topology, payload.as_ref())?;
            let assets_payload =
                if dry_run && image.as_ref().is_some_and(|image| image.status != "ready") {
                    original_payload.as_ref()
                } else {
                    payload.as_ref()
                };
            cosim_runtime::check_assets(&topology, assets_payload)?;
            let layout = target.layout(if dry_run {
                Purpose::DryRun
            } else {
                Purpose::Run
            })?;
            let plan =
                cosim_runtime::plan(&topology, payload.as_ref(), &ExecEnv::local()?, &layout)?;
            if dry_run {
                let output = serde_json::json!({
                    "dry_run": true,
                    "image": image.as_ref(),
                    "launch": plan,
                });
                println!("{}", serde_json::to_string_pretty(&output)?);
                return Ok(ExitCode::SUCCESS);
            }
            let options = RunOptions::new(
                Duration::from_secs(ready_timeout),
                run_for.map(Duration::from_secs),
                qemu_img,
            )?;
            return run(&plan, &options, stdin_lifeline).await;
        }
        Command::Clean { run_dir } => cosim_runtime::clean(&run_dir)?,
    }
    Ok(ExitCode::SUCCESS)
}

fn image_workspace() -> Result<PathBuf> {
    match std::env::var_os("COSIM_WORKSPACE") {
        Some(workspace) if !workspace.is_empty() => {
            std::fs::canonicalize(PathBuf::from(workspace)).context("resolve COSIM_WORKSPACE")
        }
        Some(_) => anyhow::bail!("COSIM_WORKSPACE must not be empty"),
        None => std::env::current_dir().context("read the current workspace directory"),
    }
}

impl Target {
    fn layout(&self, purpose: Purpose) -> Result<SessionLayout> {
        let run_dir = self.run_dir.clone().unwrap_or_else(|| {
            let name = match purpose {
                Purpose::DryRun => "dry-run".to_owned(),
                Purpose::Run => {
                    let mut name = uuid::Uuid::new_v4().simple().to_string();
                    name.truncate(12);
                    name
                }
            };
            Path::new(".cosim").join(name)
        });
        let pool_dir = match &self.pool_dir {
            Some(pool_dir) => pool_dir.clone(),
            None => SessionLayout::default_pool_dir(&run_dir)?,
        };
        SessionLayout::new(&run_dir, &pool_dir)
    }
}

async fn run(
    plan: &cosim_runtime::Plan,
    options: &RunOptions,
    stdin_lifeline: bool,
) -> Result<ExitCode> {
    let shutdown = Shutdown::default();
    if stdin_lifeline {
        watch_stdin(&shutdown);
    }
    let mut interrupt = signal(SignalKind::interrupt())?;
    let mut terminate = signal(SignalKind::terminate())?;
    let (events, mut received) = mpsc::unbounded_channel();
    println!("session: {}", plan.layout.run_dir.display());
    let session = cosim_runtime::run(plan, options, &shutdown, events);
    tokio::pin!(session);
    let verdict = loop {
        tokio::select! {
            verdict = &mut session => break verdict?,
            Some(event) = received.recv() => print_event(&event),
            _ = interrupt.recv() => escalate(&shutdown),
            _ = terminate.recv() => escalate(&shutdown),
        }
    };
    while let Ok(event) = received.try_recv() {
        print_event(&event);
    }
    println!("[COSIM_VERDICT] {}", serde_json::to_string(&verdict)?);
    Ok(match verdict.status {
        Status::Pass => ExitCode::SUCCESS,
        Status::Fail => ExitCode::FAILURE,
    })
}

/// The first signal requests graceful shutdown; later signals force it.
fn escalate(shutdown: &Shutdown) {
    if shutdown.graceful.is_cancelled() {
        shutdown.force.cancel();
    } else {
        shutdown.graceful.cancel();
    }
}

/// Requests graceful shutdown when standard input reaches end of file.
///
/// A development-container client that disappears closes the container's
/// standard input, so the launcher inside notices even without a signal.
fn watch_stdin(shutdown: &Shutdown) {
    let graceful = shutdown.graceful.clone();
    std::thread::spawn(move || {
        let mut buffer = [0; 4096];
        let mut stdin = std::io::stdin().lock();
        while matches!(stdin.read(&mut buffer), Ok(count) if count > 0) {}
        graceful.cancel();
    });
}

fn print_event(event: &Event) {
    match event {
        Event::Started { process } => println!("started: {process}"),
        Event::Ready { process } => println!("ready: {process}"),
        Event::Exited { process, status } => println!("exited: {process} ({status})"),
        Event::Stopped { process } => println!("stopped: {process}"),
        _ => {}
    }
}
