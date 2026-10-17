// SPDX-License-Identifier: Apache-2.0

//! Loads YAML topology descriptions into validated values.
//!
//! The crate reads only topology documents. Values that depend on the
//! executing system, such as page size, `PATH` and session paths, are
//! supplied by callers through [`PageSize`], [`DeviceContext`] and
//! [`HostContext`].

mod adapter;
mod graph;
mod layout;
mod loader;
mod model;
mod raw;
mod resolve;
mod size;

pub use adapter::{
    Adapter, CommandTemplate, DeviceContext, Gem5Mi300x, HostContext, HostDevice, HostDisk, Launch,
    Probe, QemuDevice, TemplateDevice,
};
pub use graph::graph;
pub use layout::{DeviceRegions, GuestRange, MemoryLayout, PageSize, Region};
pub use loader::{load, load_payload, load_payload_with_workspace, load_with_workspace};
pub use model::{
    Device, DeviceModel, DirectBoot, Disk, DiskBus, DiskFormat, DiskMode, GuestHints, Host,
    Identifier, ImageProfile, Machine, MemoryRegion, Payload, Pci, Program, Role, SerialReady,
    Topology,
};
pub use size::ByteSize;

/// Validates optional payload constraints that depend on a topology.
pub fn validate_payload(topology: &Topology, payload: Option<&Payload>) -> anyhow::Result<()> {
    resolve::validate_payload(topology, payload)
}

/// Adds the verified kernel and root disk selected by a payload image profile.
pub fn materialize_image_profile(
    payload: &mut Payload,
    kernel: Option<std::path::PathBuf>,
    disk: std::path::PathBuf,
    disk_id: &str,
    disk_format: DiskFormat,
    disk_bus: DiskBus,
    kernel_cmdline: Option<String>,
) -> anyhow::Result<()> {
    resolve::materialize_image_profile(
        payload,
        kernel,
        disk,
        disk_id,
        disk_format,
        disk_bus,
        kernel_cmdline,
    )
}

/// Generates the JSON Schema of standalone payload documents.
pub fn payload_schema() -> schemars::Schema {
    schemars::schema_for!(raw::PayloadDocument)
}

/// Generates the JSON Schema of topology documents.
pub fn schema() -> schemars::Schema {
    schemars::schema_for!(raw::Document)
}
