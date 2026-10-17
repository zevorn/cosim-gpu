// SPDX-License-Identifier: Apache-2.0

//! Resolves guest image profiles through the shared Packer/Ansible catalog.

use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, ensure};
use cosim_topology::{DiskBus, DiskFormat, ImageProfile, Payload};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ImageState {
    pub profile: ImageSummary,
    pub status: String,
    pub input_key: Option<String>,
    pub inputs: Option<serde_json::Value>,
    pub artifact_directory: PathBuf,
    pub disk: PathBuf,
    pub disk_format: String,
    pub disk_id: String,
    pub disk_bus: String,
    pub kernel: Option<PathBuf>,
    pub kernel_cmdline: Option<String>,
    pub reasons: Vec<String>,
    pub commands: Vec<Vec<String>>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ImageSummary {
    pub id: String,
    pub role: String,
    pub distribution: String,
    pub release: String,
    pub architecture: String,
}

/// Inspects a selected image and adds its expected disk and kernel paths to the payload.
pub fn prepare_image_profile(
    payload: &mut Payload,
    workspace: &Path,
    build: bool,
) -> Result<Option<ImageState>> {
    let Some(ImageProfile { profile, .. }) = payload.image.as_ref() else {
        return Ok(None);
    };
    let mut state = inspect_profile_with_policy(workspace, profile, build)?;
    if build && state.status != "ready" {
        run_builder(workspace, "build", profile, false)?;
        state = inspect_profile_with_policy(workspace, profile, build)?;
    }
    if build {
        ensure!(
            state.status == "ready",
            "image profile {} is not ready: {}",
            profile,
            state.reasons.join("; ")
        );
    }
    let disk_format =
        serde_json::from_value::<DiskFormat>(serde_json::Value::String(state.disk_format.clone()))
            .context("decode image profile disk format")?;
    let disk_bus =
        serde_json::from_value::<DiskBus>(serde_json::Value::String(state.disk_bus.clone()))
            .context("decode image profile disk bus")?;
    cosim_topology::materialize_image_profile(
        payload,
        state.kernel.clone(),
        state.disk.clone(),
        &state.disk_id,
        disk_format,
        disk_bus,
        state.kernel_cmdline.clone(),
    )?;
    Ok(Some(state))
}

/// Reads profile and cache state without creating files or starting Packer.
pub fn inspect_profile(workspace: &Path, profile: &str) -> Result<ImageState> {
    inspect_profile_with_policy(workspace, profile, false)
}

fn inspect_profile_with_policy(
    workspace: &Path,
    profile: &str,
    write_verification_cache: bool,
) -> Result<ImageState> {
    let output = run_builder(workspace, "inspect", profile, write_verification_cache)?;
    serde_json::from_slice(&output).context("decode image profile inspection")
}

fn run_builder(
    workspace: &Path,
    operation: &str,
    profile: &str,
    write_verification_cache: bool,
) -> Result<Vec<u8>> {
    let mut command = Command::new("python3");
    command
        .arg("-m")
        .arg("resources.images.cli")
        .arg("--workspace")
        .arg(workspace)
        .arg(operation)
        .arg(profile)
        .current_dir(workspace)
        .env("PYTHONDONTWRITEBYTECODE", "1");
    if operation == "inspect" {
        command.arg("--json");
        if write_verification_cache {
            command.arg("--write-verification-cache");
        }
        let output = command
            .output()
            .context("start the guest image profile inspector")?;
        ensure!(
            output.status.success(),
            "image profile inspection failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
        Ok(output.stdout)
    } else {
        let status = command.status().context("start the guest image builder")?;
        ensure!(
            status.success(),
            "guest image {operation} failed for {profile}"
        );
        Ok(Vec::new())
    }
}
