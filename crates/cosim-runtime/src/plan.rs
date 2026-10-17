// SPDX-License-Identifier: Apache-2.0

//! Execution plans resolved for the local system.

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};
use cosim_topology::{
    ByteSize, DeviceContext, DeviceModel, Disk, DiskFormat, DiskMode, HostContext, HostDevice,
    HostDisk, Identifier, Launch, Machine, MemoryLayout, Payload, Probe, Program, Topology,
};
use nix::unistd::{self, AccessFlags};
use serde::Serialize;

use crate::env::{self, ExecEnv};
use crate::layout::SessionLayout;

/// Maximum Unix socket path length, including the terminating NUL.
const SOCKET_PATH_LIMIT: usize = if cfg!(target_os = "linux") { 108 } else { 104 };

/// Everything a session needs: commands, environments, paths and memory layouts.
///
/// `cosim run --dry-run` prints this value and `cosim run` executes it unchanged.
#[non_exhaustive]
#[derive(Clone, Debug, Serialize)]
pub struct Plan {
    /// Topology document the plan was built from.
    pub source: PathBuf,
    /// Optional payload document applied to every machine.
    pub payload: Option<Payload>,
    /// Host facts used for planning.
    pub env: ExecEnv,
    /// Session directories.
    pub layout: SessionLayout,
    /// Machines in topology order.
    pub machines: Vec<MachinePlan>,
    /// Processes ordered so that dependencies precede their dependents.
    pub processes: Vec<ProcessPlan>,
}

/// Resources of one machine.
#[non_exhaustive]
#[derive(Clone, Debug, Serialize)]
pub struct MachinePlan {
    /// Machine identifier.
    pub id: Identifier,
    /// Memory pool file.
    pub pool: PathBuf,
    /// Layout of the memory pool.
    pub memory: MemoryLayout,
    /// Disks in declaration order.
    pub disks: Vec<DiskPlan>,
    /// Remote agent reserved for distributed execution.
    pub placement: Option<String>,
    /// Distinct driver load commands suggested by devices.
    pub guest_hints: Vec<String>,
}

/// A disk source and the file its host opens.
#[non_exhaustive]
#[derive(Clone, Debug, Serialize)]
pub struct DiskPlan {
    /// Disk identifier.
    pub id: Identifier,
    /// Image the disk reads or writes.
    pub source: PathBuf,
    /// Format of the source image.
    pub source_format: DiskFormat,
    /// How the host opens the source.
    pub mode: DiskMode,
    /// Size of a source image created when it is missing.
    pub create: Option<ByteSize>,
    /// File passed to QEMU: the source or a session overlay.
    pub target: PathBuf,
    /// Format of the target.
    pub target_format: DiskFormat,
    /// Log of image helper invocations.
    pub log: PathBuf,
}

/// Roles of processes in a plan.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum NodeRole {
    /// A device process.
    Device,
    /// The QEMU host process.
    Host,
}

/// A resolved process.
#[non_exhaustive]
#[derive(Clone, Debug, Serialize)]
pub struct ProcessPlan {
    /// Process identifier, `<machine>.<device>` or `<machine>.host`.
    pub id: String,
    /// Index of the owning machine.
    pub machine: usize,
    /// Process role.
    pub role: NodeRole,
    /// Absolute path of the executable.
    pub program: PathBuf,
    /// Arguments, excluding the executable.
    pub argv: Vec<String>,
    /// Complete environment of the process.
    pub env: BTreeMap<String, String>,
    /// Working directory.
    pub directory: PathBuf,
    /// Combined standard output and error log.
    pub output_log: PathBuf,
    /// Sockets the process creates; the session removes them after it stops.
    pub endpoints: Vec<PathBuf>,
    /// Readiness conditions in evaluation order.
    pub probes: Vec<Probe>,
    /// Indices of earlier processes that must be ready first.
    pub dependencies: Vec<usize>,
}

/// Resolves commands, paths and executables without creating files or
/// starting processes.
pub fn plan(
    topology: &Topology,
    payload: Option<&Payload>,
    env: &ExecEnv,
    layout: &SessionLayout,
) -> Result<Plan> {
    SessionLayout::check_identifiers(topology)?;
    cosim_topology::validate_payload(topology, payload)?;
    // Lock files outlive sessions, so they cannot live in a directory that a
    // session removes.
    ensure!(
        !env.disk_lock_dir.starts_with(&layout.pool_dir),
        "the disk lock directory {} must be outside the pool directory {}",
        env.disk_lock_dir.display(),
        layout.pool_dir.display()
    );
    let mut machines = Vec::with_capacity(topology.machines.len());
    let mut processes = Vec::new();
    for (index, machine) in topology.machines.iter().enumerate() {
        let planned = plan_machine(index, machine, payload, env, layout, &mut processes)
            .with_context(|| format!("machine {}", machine.id))?;
        machines.push(planned);
    }
    Ok(Plan {
        source: topology.source.clone(),
        payload: payload.cloned(),
        env: env.clone(),
        layout: layout.clone(),
        machines,
        processes,
    })
}

fn plan_machine(
    index: usize,
    machine: &Machine,
    payload: Option<&Payload>,
    env: &ExecEnv,
    layout: &SessionLayout,
    processes: &mut Vec<ProcessPlan>,
) -> Result<MachinePlan> {
    let memory = machine.memory_layout(env.page_size)?;
    let pool = layout.pool(&machine.id);
    let payload_disks = payload.map_or(&[][..], |payload| payload.disks.as_slice());
    let disks = payload_disks
        .iter()
        .map(|disk| disk_plan(disk, &machine.id, layout))
        .collect::<Result<Vec<_>>>()?;
    let mut dependencies = Vec::with_capacity(machine.devices.len());
    let mut sockets = Vec::with_capacity(machine.devices.len());
    for device in &machine.devices {
        let directory = layout.device_dir(&machine.id, &device.id);
        let socket = layout.device_socket(&machine.id, &device.id);
        let qmp = layout.device_qmp(&machine.id, &device.id);
        let output_log = SessionLayout::output_log(&directory);
        let launch = device.launch(&DeviceContext {
            machine,
            layout: &memory,
            pool: &pool,
            socket: &socket,
            qmp: &qmp,
            output_log: &output_log,
            node_dir: &directory,
            run_dir: &layout.run_dir,
        })?;
        dependencies.push(processes.len());
        processes.push(process(
            ProcessSpec {
                id: format!("{}.{}", machine.id, device.id),
                machine: index,
                role: NodeRole::Device,
                program: &device.program,
                qemu: device.model == DeviceModel::Qemu,
                launch,
                directory,
                output_log,
                dependencies: Vec::new(),
            },
            env,
        )?);
        sockets.push(socket);
    }
    let directory = layout.host_dir(&machine.id);
    let qmp = layout.host_qmp(&machine.id);
    let serial = layout.host_serial(&machine.id);
    let serial_log = layout.serial_log(&machine.id);
    let output_log = SessionLayout::output_log(&directory);
    let context = HostContext {
        machine,
        layout: &memory,
        pool: &pool,
        qmp: &qmp,
        serial: &serial,
        serial_log: &serial_log,
        node_dir: &directory,
        run_dir: &layout.run_dir,
        boot: payload.and_then(|payload| payload.boot.as_ref()),
        disks: disks
            .iter()
            .zip(payload_disks)
            .map(|(plan, disk)| HostDisk {
                disk,
                path: &plan.target,
                format: plan.target_format,
                readonly: plan.mode == DiskMode::ReadOnly,
            })
            .collect(),
        devices: machine
            .devices
            .iter()
            .zip(&sockets)
            .map(|(device, socket)| HostDevice { device, socket })
            .collect(),
    };
    let launch = machine.host.launch(&context)?;
    processes.push(process(
        ProcessSpec {
            id: format!("{}.host", machine.id),
            machine: index,
            role: NodeRole::Host,
            program: &machine.host.program,
            qemu: true,
            launch,
            directory,
            output_log,
            dependencies,
        },
        env,
    )?);
    let mut guest_hints = Vec::new();
    for hint in machine
        .devices
        .iter()
        .filter_map(|device| device.guest_hints.modprobe.as_ref())
    {
        if !guest_hints.contains(hint) {
            guest_hints.push(hint.clone());
        }
    }
    Ok(MachinePlan {
        id: machine.id.clone(),
        pool,
        memory,
        disks,
        placement: machine.placement.clone(),
        guest_hints,
    })
}

struct ProcessSpec<'a> {
    id: String,
    machine: usize,
    role: NodeRole,
    program: &'a Program,
    qemu: bool,
    launch: Launch,
    directory: PathBuf,
    output_log: PathBuf,
    dependencies: Vec<usize>,
}

fn process(spec: ProcessSpec<'_>, env: &ExecEnv) -> Result<ProcessPlan> {
    let id = spec.id.clone();
    let resolve = || -> Result<ProcessPlan> {
        let mut environment = spec.program.env.clone();
        let search_path = match environment.get("PATH") {
            Some(path) => env::absolute_search_path(OsStr::new(path))?,
            None => env.search_path.clone(),
        };
        let program = resolve_program(&spec.program.binary, &search_path)?;
        environment.insert("PATH".to_owned(), search_path);
        environment
            .entry("LANG".to_owned())
            .or_insert_with(|| "C".to_owned());
        let argv = spec.launch.argv;
        ensure!(
            argv.iter().all(|argument| !argument.contains('\0')),
            "arguments contain NUL bytes"
        );
        ensure!(
            !spec.qemu
                || !argv
                    .iter()
                    .any(|argument| matches!(argument.as_str(), "-daemonize" | "--daemonize")),
            "QEMU must stay in the foreground; -daemonize is incompatible with process ownership"
        );
        let endpoints = spec
            .launch
            .probes
            .iter()
            .filter_map(|probe| match probe {
                Probe::Socket { path } | Probe::Qmp { path } => Some(path.clone()),
                Probe::Log { .. } => None,
            })
            .collect::<Vec<_>>();
        for endpoint in &endpoints {
            ensure!(
                endpoint.as_os_str().len() < SOCKET_PATH_LIMIT,
                "Unix socket path is too long: {}; choose a shorter --run-dir",
                endpoint.display()
            );
        }
        Ok(ProcessPlan {
            id: spec.id,
            machine: spec.machine,
            role: spec.role,
            program,
            argv,
            env: environment,
            directory: spec.directory,
            output_log: spec.output_log,
            endpoints,
            probes: spec.launch.probes,
            dependencies: spec.dependencies,
        })
    };
    resolve().with_context(|| format!("process {id}"))
}

/// Finds an executable by absolute path or `PATH` search.
pub(crate) fn resolve_program(binary: &str, search_path: &str) -> Result<PathBuf> {
    if binary.contains('/') {
        return Ok(std::path::absolute(binary)?);
    }
    std::env::split_paths(search_path)
        .map(|directory| directory.join(binary))
        .find(|candidate| executable(candidate))
        .with_context(|| format!("executable {binary} was not found in PATH"))
}

/// Returns whether `path` is a file the current user may execute.
pub(crate) fn executable(path: &Path) -> bool {
    path.is_file() && unistd::access(path, AccessFlags::X_OK).is_ok()
}

fn disk_plan(disk: &Disk, machine: &Identifier, layout: &SessionLayout) -> Result<DiskPlan> {
    ensure!(
        !disk.source.starts_with(&layout.run_dir) && !disk.source.starts_with(&layout.pool_dir),
        "disk {} source must be outside the session directories",
        disk.id
    );
    let overlay = disk.mode == DiskMode::Overlay;
    Ok(DiskPlan {
        id: disk.id.clone(),
        source: disk.source.clone(),
        source_format: disk.format,
        mode: disk.mode,
        create: disk.create,
        target: if overlay {
            layout.overlay(machine, &disk.id)
        } else {
            disk.source.clone()
        },
        target_format: if overlay {
            DiskFormat::Qcow2
        } else {
            disk.format
        },
        log: layout.disk_log(machine, &disk.id),
    })
}
