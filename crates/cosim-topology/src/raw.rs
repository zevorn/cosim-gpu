// SPDX-License-Identifier: Apache-2.0

//! Decoded YAML documents before template expansion and validation.

use std::collections::BTreeMap;
use std::path::PathBuf;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::model::{DeviceModel, DiskBus, DiskFormat, GuestHints, Pci, Role};
use crate::size::ByteSize;

/// A topology document.
#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct Document {
    pub(crate) version: u32,
    #[serde(default)]
    pub(crate) imports: Vec<String>,
    #[schemars(with = "BTreeMap<String, Template>")]
    #[serde(default)]
    pub(crate) templates: BTreeMap<String, Value>,
    #[serde(default)]
    pub(crate) kinds: BTreeMap<String, Kind>,
    #[schemars(with = "Vec<Machine>")]
    #[serde(default)]
    pub(crate) machines: Vec<Value>,
}

/// A payload document, kept separate from machine hardware.
#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct PayloadDocument {
    pub(crate) version: u32,
    pub(crate) image: Option<PayloadImage>,
    #[serde(default)]
    pub(crate) boot: Boot,
    #[serde(default)]
    pub(crate) disks: Vec<Disk>,
    #[serde(default)]
    pub(crate) snapshot: bool,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct PayloadImage {
    pub(crate) profile: String,
}

/// A reusable machine, host or device fragment.
#[expect(dead_code, reason = "the type only describes the document schema")]
#[derive(JsonSchema)]
#[serde(untagged)]
enum Template {
    Machine(Box<Machine>),
    Host(Box<Host>),
    Device(Box<Device>),
}

/// A declared adapter kind.
#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct Kind {
    pub(crate) role: Role,
    pub(crate) model: DeviceModel,
    #[serde(default)]
    pub(crate) argv: Vec<String>,
    pub(crate) command: Option<String>,
    pub(crate) max_devices: Option<usize>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct Machine {
    pub(crate) id: Option<String>,
    #[expect(dead_code, reason = "template references are expanded before decoding")]
    #[serde(default, rename = "use")]
    pub(crate) template: Option<String>,
    pub(crate) count: Option<usize>,
    pub(crate) host: Option<Host>,
    #[serde(default)]
    pub(crate) devices: Vec<Device>,
    pub(crate) placement: Option<Placement>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct Placement {
    pub(crate) agent: String,
}

#[derive(Debug, Default, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct Runtime {
    pub(crate) binary: Option<String>,
    #[serde(default)]
    pub(crate) env: BTreeMap<String, String>,
    #[serde(default)]
    pub(crate) argv: Vec<String>,
    pub(crate) command: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct Host {
    #[expect(dead_code, reason = "template references are expanded before decoding")]
    #[serde(default, rename = "use")]
    pub(crate) template: Option<String>,
    pub(crate) kind: Option<String>,
    #[serde(default)]
    pub(crate) runtime: Runtime,
    pub(crate) memory: Option<ByteSize>,
    pub(crate) memory_map: Option<String>,
    pub(crate) memory_align: Option<ByteSize>,
    pub(crate) cpus: Option<u32>,
    pub(crate) accel: Option<String>,
    pub(crate) machine: Option<String>,
    pub(crate) cpu: Option<String>,
    pub(crate) display: Option<String>,
    pub(crate) monitor: Option<String>,
    #[serde(default)]
    pub(crate) no_reboot: bool,
    #[serde(default)]
    pub(crate) serial: Serial,
    #[serde(default)]
    pub(crate) args: Vec<String>,
}

#[derive(Debug, Default, Deserialize, JsonSchema, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Boot {
    pub(crate) kernel: Option<PathBuf>,
    pub(crate) initrd: Option<PathBuf>,
    pub(crate) cmdline: Option<String>,
}

#[derive(Debug, Default, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct Serial {
    pub(crate) wait_for: Option<String>,
    /// Seconds allowed for `wait_for`, measured from host start.
    pub(crate) timeout: Option<u64>,
}

#[derive(Debug, Deserialize, JsonSchema, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Disk {
    pub(crate) id: String,
    pub(crate) path: Option<PathBuf>,
    pub(crate) backing: Option<PathBuf>,
    #[serde(default)]
    pub(crate) format: DiskFormat,
    #[serde(default)]
    pub(crate) bus: DiskBus,
    #[serde(default)]
    pub(crate) boot: bool,
    #[serde(default)]
    pub(crate) create: bool,
    pub(crate) size: Option<ByteSize>,
    pub(crate) readonly: Option<bool>,
    pub(crate) shared: Option<bool>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct Device {
    pub(crate) id: Option<String>,
    #[expect(dead_code, reason = "template references are expanded before decoding")]
    #[serde(default, rename = "use")]
    pub(crate) template: Option<String>,
    pub(crate) count: Option<usize>,
    pub(crate) kind: Option<String>,
    pub(crate) config: Option<PathBuf>,
    pub(crate) ready_log: Option<String>,
    #[serde(default)]
    pub(crate) runtime: Runtime,
    #[serde(default)]
    pub(crate) memory_regions: Vec<MemoryRegion>,
    #[serde(default)]
    pub(crate) pci: Pci,
    #[serde(default)]
    pub(crate) args: Map<String, Value>,
    #[serde(default)]
    pub(crate) guest_hints: GuestHints,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct MemoryRegion {
    pub(crate) name: String,
    pub(crate) size: ByteSize,
    pub(crate) align: Option<ByteSize>,
}
