// SPDX-License-Identifier: Apache-2.0

//! Validated topology values consumed by planners and tools.

use std::collections::BTreeMap;
use std::fmt;
use std::num::NonZeroU32;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Result, ensure};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::adapter::{Adapter, CommandTemplate};
use crate::size::ByteSize;

/// A topology whose references, identifiers and resource declarations are valid.
///
/// Construct it with [`crate::load`]. All values are independent of the
/// system that will execute the topology.
#[non_exhaustive]
#[derive(Clone, Debug, Serialize)]
pub struct Topology {
    /// Canonical path of the loaded document.
    pub source: PathBuf,
    /// Expanded machine instances in declaration order.
    pub machines: Vec<Machine>,
}

impl Topology {
    /// Returns the number of expanded device instances.
    pub fn device_count(&self) -> usize {
        self.machines
            .iter()
            .map(|machine| machine.devices.len())
            .sum()
    }
}

/// A name of 1 to 48 ASCII letters, digits, underscores or hyphens.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct Identifier(String);

impl Identifier {
    pub(crate) fn new(value: impl Into<String>) -> Result<Self> {
        let value = value.into();
        ensure!(
            !value.is_empty()
                && value.len() <= 48
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_'),
            "invalid identifier {value:?}; use 1..48 letters, digits, underscores or hyphens"
        );
        Ok(Self(value))
    }

    /// Returns the identifier text.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Returns the identifier without ASCII case distinctions.
    pub(crate) fn folded(&self) -> String {
        self.0.to_ascii_lowercase()
    }
}

impl fmt::Display for Identifier {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// One QEMU host and the device processes connected to it.
#[non_exhaustive]
#[derive(Clone, Debug, Serialize)]
pub struct Machine {
    /// Machine identifier after count expansion.
    pub id: Identifier,
    /// The QEMU host process.
    pub host: Host,
    /// Device processes in declaration order.
    pub devices: Vec<Device>,
    /// Remote agent reserved for distributed execution.
    pub placement: Option<String>,
}

/// Guest boot and storage inputs supplied separately from machine hardware.
#[non_exhaustive]
#[derive(Clone, Debug, Serialize)]
pub struct Payload {
    /// Canonical path of the payload document.
    pub source: PathBuf,
    /// Guest image profile that supplies the boot kernel and root disk.
    pub image: Option<ImageProfile>,
    /// Direct kernel boot configuration.
    pub boot: Option<DirectBoot>,
    /// Storage attached to each machine in the topology.
    pub disks: Vec<Disk>,
}

/// A reusable guest image profile selected by a payload.
#[non_exhaustive]
#[derive(Clone, Debug, Serialize)]
pub struct ImageProfile {
    /// Profile identifier relative to `resources/images/profiles`.
    pub profile: String,
}

/// An executable and the environment it receives.
#[non_exhaustive]
#[derive(Clone, Debug, Serialize)]
pub struct Program {
    /// Absolute path, or a command name searched in `PATH`.
    pub binary: String,
    /// Explicit environment variables; other variables are not inherited.
    pub env: BTreeMap<String, String>,
}

/// QEMU host configuration.
#[non_exhaustive]
#[derive(Clone, Debug, Serialize)]
pub struct Host {
    /// Name of the host adapter kind.
    pub kind: String,
    /// Command template that renders the QEMU arguments.
    pub command: CommandTemplate,
    /// QEMU executable and environment.
    pub program: Program,
    /// Guest RAM size.
    pub memory: ByteSize,
    /// Alignment of guest RAM inside the memory pool.
    pub memory_align: ByteSize,
    /// MiniJinja template rendering guest physical RAM ranges.
    pub memory_map: Option<String>,
    /// Number of virtual CPUs.
    pub cpus: NonZeroU32,
    /// QEMU accelerator.
    pub accel: String,
    /// QEMU machine type and properties.
    pub machine: String,
    /// QEMU CPU model.
    pub cpu: Option<String>,
    /// QEMU display backend.
    pub display: Option<String>,
    /// QEMU monitor backend.
    pub monitor: Option<String>,
    /// Exit instead of rebooting the guest.
    pub no_reboot: bool,
    /// Guest serial output that marks the host ready.
    pub serial_ready: Option<SerialReady>,
    /// Additional QEMU arguments.
    pub args: Vec<String>,
}

/// Kernel, initial RAM disk and command line for direct boot.
#[non_exhaustive]
#[derive(Clone, Debug, Serialize)]
pub struct DirectBoot {
    /// Kernel image.
    pub kernel: PathBuf,
    /// Initial RAM disk.
    pub initrd: Option<PathBuf>,
    /// Kernel command line.
    pub cmdline: Option<String>,
}

/// A serial marker that completes host readiness.
#[non_exhaustive]
#[derive(Clone, Debug, Serialize)]
pub struct SerialReady {
    /// Text the guest prints on its serial console.
    pub marker: String,
    /// Deadline measured from host start; the run's readiness timeout applies otherwise.
    pub timeout: Option<Duration>,
}

/// A disk image attached to the host.
#[non_exhaustive]
#[derive(Clone, Debug, Serialize)]
pub struct Disk {
    /// Disk identifier, unique within its host.
    pub id: Identifier,
    /// Image that the disk reads or writes.
    pub source: PathBuf,
    /// Format of the source image.
    pub format: DiskFormat,
    /// Guest bus.
    pub bus: DiskBus,
    /// Whether the guest boots from this disk.
    pub boot: bool,
    /// How the host opens the source image.
    pub mode: DiskMode,
    /// Size of a source image created when it is missing.
    pub create: Option<ByteSize>,
}

/// Image formats supported for disk sources.
#[derive(
    Clone, Copy, Debug, Default, Deserialize, Eq, JsonSchema, Ord, PartialEq, PartialOrd, Serialize,
)]
#[serde(rename_all = "lowercase")]
pub enum DiskFormat {
    /// Raw image.
    Raw,
    /// QEMU copy-on-write image.
    #[default]
    Qcow2,
}

impl DiskFormat {
    /// Returns the QEMU format name.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Raw => "raw",
            Self::Qcow2 => "qcow2",
        }
    }
}

/// Guest buses for attached disks.
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, JsonSchema, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum DiskBus {
    /// virtio-blk PCI device.
    #[default]
    Virtio,
    /// NVMe controller.
    Nvme,
    /// IDE disk.
    Ide,
    /// SCSI disk on a virtio-scsi controller.
    Scsi,
}

/// Access to a disk source.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum DiskMode {
    /// The host opens the source read-only.
    ReadOnly,
    /// The host writes a per-machine overlay backed by the source.
    Overlay,
    /// The host writes the source directly.
    Direct,
}

/// Simulators that implement device models.
#[derive(Clone, Copy, Debug, Deserialize, Eq, JsonSchema, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum DeviceModel {
    /// gem5.
    Gem5,
    /// QEMU.
    Qemu,
}

/// Roles that an adapter kind can fill.
#[derive(Clone, Copy, Debug, Deserialize, Eq, JsonSchema, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    /// A device process connected through vfio-user.
    Device,
    /// The QEMU host process.
    Host,
}

/// A device process.
#[non_exhaustive]
#[derive(Clone, Debug, Serialize)]
pub struct Device {
    /// Device identifier after count expansion.
    pub id: Identifier,
    /// Name of the device kind.
    pub kind: String,
    /// Simulator that implements the device.
    pub model: DeviceModel,
    /// Launch contract.
    pub adapter: Adapter,
    /// Executable and environment.
    pub program: Program,
    /// Device-private regions in the machine memory pool.
    pub regions: Vec<MemoryRegion>,
    /// PCI identity reported by the model.
    pub pci: Pci,
    /// Guest configuration suggested by the device.
    pub guest_hints: GuestHints,
}

/// A device-private region in the machine memory pool.
#[non_exhaustive]
#[derive(Clone, Debug, Serialize)]
pub struct MemoryRegion {
    /// Region name, unique within its device.
    pub name: Identifier,
    /// Region size.
    pub size: ByteSize,
    /// Region alignment, a power of two.
    pub align: ByteSize,
}

/// PCI identity and host-side option ROM.
#[derive(Clone, Debug, Default, Deserialize, JsonSchema, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Pci {
    /// PCI vendor identifier.
    pub vendor_id: Option<u16>,
    /// PCI device identifier.
    pub device_id: Option<u16>,
    /// Number of MSI-X vectors.
    pub msix_vectors: Option<u16>,
    /// Option ROM exposed by the host's vfio-user PCI device.
    pub rom: Option<PathBuf>,
}

/// Guest configuration suggested by a device.
#[derive(Clone, Debug, Default, Deserialize, JsonSchema, Serialize)]
#[serde(deny_unknown_fields)]
pub struct GuestHints {
    /// Driver load command recorded in the plan.
    pub modprobe: Option<String>,
    /// Kernel command-line text appended for direct boot.
    pub cmdline: Option<String>,
}
