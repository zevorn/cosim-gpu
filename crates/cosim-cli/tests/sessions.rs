// SPDX-License-Identifier: Apache-2.0

//! Sessions with real QEMU processes, disk images and signals.
//!
//! The tests need `qemu-system-<arch>`, `qemu-img` and `setpriv` in `PATH`.
//! `vfio_user_*` also needs the QEMU build from `just build-qemu`.

use std::ffi::OsString;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use nix::errno::Errno;
use nix::sys::signal::{self, Signal};
use nix::unistd::{AccessFlags, Pid, access};
use serde_json::Value;

const TIMEOUT: Duration = Duration::from_secs(60);

fn workspace() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn samples() -> PathBuf {
    workspace().join("samples")
}

fn directory_entries(path: &Path) -> Vec<PathBuf> {
    if !path.exists() {
        return Vec::new();
    }
    let mut entries = fs::read_dir(path)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect::<Vec<_>>();
    entries.sort();
    entries
}

/// A test directory below the workspace build directory.
fn directory() -> tempfile::TempDir {
    let root = workspace().join("build/tests/runtime");
    fs::create_dir_all(&root).unwrap();
    tempfile::Builder::new()
        .prefix("s")
        .tempdir_in(root)
        .unwrap()
}

/// Returns the host profile file and template for this architecture.
fn host_profile() -> (&'static str, &'static str) {
    if cfg!(target_arch = "aarch64") {
        ("hosts/host-arm-tcg.yaml", "host-arm-tcg")
    } else {
        ("hosts/host-x86-tcg.yaml", "host-x86-tcg")
    }
}

/// Writes a topology with paused TCG hosts that record their process IDs.
///
/// Each machine is `(id, extra host fields, device list)`.
fn topology(root: &Path, machines: &[(&str, &str, &str)], extra: &str) -> PathBuf {
    let (profile, template) = host_profile();
    let mut text = format!(
        "version: 1\nimports: [{}, {}]\n{extra}machines:\n",
        samples().join("hosts/qemu.yaml").display(),
        samples().join(profile).display()
    );
    for (id, host, devices) in machines {
        let pid = root.join(format!("{id}.pid"));
        text.push_str(&format!(
            "  - id: {id}\n    host: {{use: {template}, args: [-S, -nodefaults, -pidfile, {}]{host}}}\n",
            pid.display()
        ));
        if !devices.is_empty() {
            text.push_str(&format!("    devices: {devices}\n"));
        }
    }
    let path = root.join("topology.yaml");
    fs::write(&path, text).unwrap();
    path
}

#[test]
fn validate_dry_run_and_run_reject_guest_hints_without_payload() {
    let root = directory();
    let (profile, host) = host_profile();
    let topology = root.path().join("topology.yaml");
    fs::write(
        &topology,
        format!(
            "version: 1\nimports: [{}, {}, {}]\nmachines:\n  - id: m0\n    host: {{use: {host}}}\n    devices: [{{use: mi300x, guest_hints: {{cmdline: quiet}}}}]\n",
            samples().join("hosts/qemu.yaml").display(),
            samples().join(profile).display(),
            samples().join("devices/gpu/mi300x.yaml").display(),
        ),
    )
    .unwrap();
    let cases = [
        vec![OsString::from("validate"), topology.clone().into()],
        vec![OsString::from("run"), topology.clone().into()],
        vec![
            OsString::from("run"),
            topology.clone().into(),
            OsString::from("--dry-run"),
        ],
    ];
    for args in cases {
        let command = args[0].to_string_lossy();
        let (status, output) = Launcher::start(root.path(), &args, Stdio::null()).finish();
        assert!(!status.success(), "{command}: {output:#?}");
        assert!(
            output
                .iter()
                .any(|line| line.contains("guest_hints.cmdline requires payload boot.kernel")),
            "{command}: {output:#?}"
        );
    }
}

#[test]
fn run_dry_run_displays_image_and_launch_plan_without_writing_outputs() {
    let root = directory();
    let topology = samples().join("machines/host-only.yaml");
    let payload = samples().join("payloads/ubuntu-rocm7_0.yaml");
    let image_dir = workspace().join("build/images/guest/ubuntu/24.04/x86_64/rocm7_0");
    let image_existed = image_dir.exists();
    let dry_run_dir = workspace().join(".cosim/dry-run");
    let dry_run_dir_existed = dry_run_dir.exists();
    let verification_cache = workspace().join("build/cache/image-verification");
    let verification_cache_existed = verification_cache.exists();
    let verification_cache_before = directory_entries(&verification_cache);
    let args = [
        OsString::from("run"),
        topology.into(),
        OsString::from("--payload"),
        payload.into(),
        OsString::from("--dry-run"),
    ];
    let (status, output) = Launcher::start(root.path(), &args, Stdio::null()).finish();
    assert!(status.success(), "{output:#?}");
    let stdout = output
        .iter()
        .filter(|line| !line.starts_with("stderr: "))
        .cloned()
        .collect::<Vec<_>>()
        .join("\n");
    let plan: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(plan["dry_run"], true);
    assert_eq!(
        plan["image"]["profile"]["id"],
        "guest/ubuntu/24.04/x86_64/rocm7_0"
    );
    assert!(plan["launch"]["processes"].is_array());
    assert_eq!(image_dir.exists(), image_existed);
    assert_eq!(dry_run_dir.exists(), dry_run_dir_existed);
    assert_eq!(verification_cache.exists(), verification_cache_existed);
    assert_eq!(
        directory_entries(&verification_cache),
        verification_cache_before
    );
}

fn payload(root: &Path, fields: &str) -> PathBuf {
    let path = root.join("payload.yaml");
    fs::write(&path, format!("version: 1\n{fields}\n")).unwrap();
    path
}

/// A running `cosim` process and its output lines.
struct Launcher {
    child: Child,
    lines: mpsc::Receiver<String>,
    output: Vec<String>,
}

impl Launcher {
    /// Starts `cosim` without the standard-input lifeline.
    fn start(root: &Path, args: &[OsString], stdin: Stdio) -> Self {
        Self::spawn(root, args, stdin, None)
    }

    /// Starts `cosim`; `lifeline` sets `COSIM_STDIN_LIFELINE`.
    fn spawn(root: &Path, args: &[OsString], stdin: Stdio, lifeline: Option<&str>) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cosim"));
        match lifeline {
            Some(value) => command.env("COSIM_STDIN_LIFELINE", value),
            None => command.env_remove("COSIM_STDIN_LIFELINE"),
        };
        let mut child = command
            .current_dir(workspace())
            .arg("--samples")
            .arg(samples())
            .args(args)
            .env("COSIM_DISK_LOCK_DIR", root.join("locks"))
            .stdin(stdin)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let (sender, lines) = mpsc::channel();
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        for (stream, prefix) in [
            (Box::new(stdout) as Box<dyn std::io::Read + Send>, ""),
            (Box::new(stderr), "stderr: "),
        ] {
            let sender = sender.clone();
            thread::spawn(move || {
                for line in BufReader::new(stream).lines().map_while(Result::ok) {
                    if sender.send(format!("{prefix}{line}")).is_err() {
                        break;
                    }
                }
            });
        }
        Self {
            child,
            lines,
            output: Vec::new(),
        }
    }

    fn run(root: &Path, topology: &Path, extra: &[&str]) -> Self {
        let mut args = vec![
            OsString::from("run"),
            topology.into(),
            "--run-dir".into(),
            root.join("r").into(),
        ];
        args.extend(extra.iter().map(OsString::from));
        Self::start(root, &args, Stdio::null())
    }

    fn run_with_payload(root: &Path, topology: &Path, payload: &Path, extra: &[&str]) -> Self {
        let mut args = vec![
            OsString::from("run"),
            topology.into(),
            "--payload".into(),
            payload.into(),
            "--run-dir".into(),
            root.join("r").into(),
        ];
        args.extend(extra.iter().map(OsString::from));
        Self::start(root, &args, Stdio::null())
    }

    fn pid(&self) -> Pid {
        Pid::from_raw(i32::try_from(self.child.id()).unwrap())
    }

    /// Waits for an output line that starts with `prefix`.
    fn wait_for(&mut self, prefix: &str) -> String {
        let deadline = Instant::now() + TIMEOUT;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match self.lines.recv_timeout(remaining) {
                Ok(line) => {
                    self.output.push(line.clone());
                    if line.starts_with(prefix) {
                        return line;
                    }
                }
                Err(error) => panic!("no line {prefix:?} ({error}): {:#?}", self.output),
            }
        }
    }

    /// Waits for the launcher to exit and returns its status and output.
    fn finish(mut self) -> (ExitStatus, Vec<String>) {
        let deadline = Instant::now() + TIMEOUT;
        let status = loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                break status;
            }
            assert!(
                Instant::now() < deadline,
                "cosim did not exit: {:#?}",
                self.output
            );
            thread::sleep(Duration::from_millis(20));
        };
        while let Ok(line) = self.lines.recv_timeout(Duration::from_secs(5)) {
            self.output.push(line);
        }
        (status, std::mem::take(&mut self.output))
    }
}

impl Drop for Launcher {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn verdict(output: &[String]) -> Value {
    let line = output
        .iter()
        .find_map(|line| line.strip_prefix("[COSIM_VERDICT] "))
        .unwrap_or_else(|| panic!("no verdict: {output:#?}"));
    serde_json::from_str(line).unwrap()
}

fn read_pid(path: &Path) -> Pid {
    let deadline = Instant::now() + TIMEOUT;
    loop {
        if let Ok(text) = fs::read_to_string(path)
            && let Ok(pid) = text.trim().parse()
        {
            return Pid::from_raw(pid);
        }
        assert!(Instant::now() < deadline, "no pid file {}", path.display());
        thread::sleep(Duration::from_millis(20));
    }
}

fn alive(pid: Pid) -> bool {
    !matches!(signal::kill(pid, None), Err(Errno::ESRCH))
}

/// Returns whether process `pid` has `path` open through a descriptor.
#[cfg(target_os = "linux")]
fn holds(pid: Pid, path: &Path) -> bool {
    let path = fs::canonicalize(path).unwrap();
    fs::read_dir(format!("/proc/{pid}/fd"))
        .unwrap()
        .filter_map(|entry| fs::read_link(entry.ok()?.path()).ok())
        .any(|target| target == path)
}

/// Pool directory chosen by the launcher for the test run directory.
fn pool_dir(root: &Path) -> PathBuf {
    let plan: Value = serde_json::from_slice(&fs::read(root.join("r/plan.json")).unwrap()).unwrap();
    PathBuf::from(plan["layout"]["pool_dir"].as_str().unwrap())
}

fn qmp_command(reader: &mut BufReader<UnixStream>, command: Value) -> Value {
    serde_json::to_writer(reader.get_mut(), &command).unwrap();
    reader.get_mut().write_all(b"\n").unwrap();
    loop {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0, "QMP closed");
        let response: Value = serde_json::from_str(&line).unwrap();
        assert!(response.get("error").is_none(), "{response}");
        if let Some(result) = response.get("return") {
            return result.clone();
        }
    }
}

#[ignore = "requires QEMU"]
#[test]
fn hosts_run_for_a_duration_and_release_session_resources() {
    let root = directory();
    let root = root.path();
    let topology = topology(root, &[("a", "", ""), ("b", "", "")], "");
    let launcher = Launcher::run(root, &topology, &["--run-for", "1"]);
    let (status, output) = launcher.finish();
    assert!(status.success(), "{output:#?}");
    assert_eq!(verdict(&output)["status"], "PASS");
    assert!(output.iter().any(|line| line == "ready: a.host"));
    assert!(output.iter().any(|line| line == "ready: b.host"));
    let run = root.join("r");
    assert!(!pool_dir(root).exists(), "the pool directory remains");
    assert!(!run.join("a/qmp.sock").exists());
    assert!(run.join("a/host/output.log").is_file());
    assert!(run.join("a/layout.json").is_file());
    let recorded: Value =
        serde_json::from_slice(&fs::read(run.join("verdict.json")).unwrap()).unwrap();
    assert_eq!(recorded["users_stopped"], true);
    // QEMU removes its pid file when it exits after SIGTERM.
    assert!(!root.join("a.pid").exists());
}

#[ignore = "requires QEMU"]
#[test]
fn a_second_signal_forces_shutdown_of_a_stopped_host() {
    let root = directory();
    let root = root.path();
    let topology = topology(root, &[("m0", "", "")], "");
    let mut launcher = Launcher::run(root, &topology, &[]);
    launcher.wait_for("ready: m0.host");
    let qemu = read_pid(&root.join("m0.pid"));
    signal::kill(qemu, Signal::SIGSTOP).unwrap();
    signal::kill(launcher.pid(), Signal::SIGTERM).unwrap();
    thread::sleep(Duration::from_millis(500));
    let forced = Instant::now();
    signal::kill(launcher.pid(), Signal::SIGTERM).unwrap();
    let (status, output) = launcher.finish();
    assert!(
        forced.elapsed() < Duration::from_secs(3),
        "forced shutdown waited for the grace period: {output:#?}"
    );
    assert!(status.success(), "{output:#?}");
    assert_eq!(verdict(&output)["users_stopped"], true);
    assert!(!alive(qemu));
    assert!(!pool_dir(root).exists());
}

#[ignore = "requires QEMU"]
#[test]
fn launcher_death_kills_its_children_and_clean_removes_resources() {
    let root = directory();
    let root = root.path();
    let topology = topology(root, &[("m0", "", "")], "");
    let mut launcher = Launcher::run(root, &topology, &[]);
    launcher.wait_for("ready: m0.host");
    let qemu = read_pid(&root.join("m0.pid"));
    let run = root.join("r");
    #[cfg(target_os = "linux")]
    assert!(
        holds(qemu, &run.join("session.lock")),
        "QEMU does not hold the inherited session lock"
    );
    let refused = Launcher::start(root, &["clean".into(), run.clone().into()], Stdio::null());
    let (status, output) = refused.finish();
    assert!(!status.success(), "{output:#?}");
    assert!(
        output.iter().any(|line| line.contains("still running")),
        "{output:#?}"
    );
    signal::kill(launcher.pid(), Signal::SIGKILL).unwrap();
    let (status, _) = launcher.finish();
    assert!(!status.success());
    let deadline = Instant::now() + Duration::from_secs(10);
    while alive(qemu) {
        assert!(Instant::now() < deadline, "QEMU survived the launcher");
        thread::sleep(Duration::from_millis(20));
    }
    let pool = pool_dir(root);
    assert!(pool.join("m0/pool").is_file());
    assert!(!run.join("verdict.json").exists());
    let clean = Launcher::start(root, &["clean".into(), run.clone().into()], Stdio::null());
    let (status, output) = clean.finish();
    assert!(status.success(), "{output:#?}");
    assert!(!pool.exists());
    assert!(!run.join("m0/qmp.sock").exists());
    assert!(run.join("m0/host/output.log").is_file());
}

#[cfg(target_os = "linux")]
#[ignore = "requires QEMU and prlimit"]
#[test]
fn interrupted_metadata_does_not_publish_or_block_the_run_directory() {
    use std::os::unix::process::ExitStatusExt;

    let root = directory();
    let root = root.path();
    let topology = topology(root, &[("m0", "", "")], "");
    let run = root.join("r");
    // The kernel terminates the real launcher on its first metadata write.
    let output = Command::new("prlimit")
        .args(["--core=0:0", "--fsize=0:0", "--"])
        .arg(env!("CARGO_BIN_EXE_cosim"))
        .arg("--samples")
        .arg(samples())
        .arg("run")
        .arg(&topology)
        .arg("--run-dir")
        .arg(&run)
        .env_remove("COSIM_STDIN_LIFELINE")
        .env("COSIM_DISK_LOCK_DIR", root.join("locks"))
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(output.status.signal(), Some(Signal::SIGXFSZ as i32));
    assert!(!run.exists(), "incomplete run metadata was published");
    assert!(!root.join("m0.pid").exists());

    let (status, output) = Launcher::run(root, &topology, &["--run-for", "1"]).finish();
    assert!(status.success(), "{output:#?}");
    let clean = Launcher::start(root, &["clean".into(), run.into()], Stdio::null());
    let (status, output) = clean.finish();
    assert!(status.success(), "{output:#?}");
    assert!(!pool_dir(root).exists());
}

#[cfg(target_os = "linux")]
#[ignore = "requires QEMU and a dedicated 96 MiB /dev/shm"]
#[test]
fn bounded_memory_pool_rejects_a_competing_session_and_releases_capacity() {
    let root = directory();
    let statistics = nix::sys::statvfs::statvfs("/dev/shm").unwrap();
    assert_eq!(
        statistics.blocks() * statistics.fragment_size(),
        96 * 1024 * 1024
    );
    let first_dir = root.path().join("first");
    let second_dir = root.path().join("second");
    let retry_dir = root.path().join("retry");
    for directory in [&first_dir, &second_dir, &retry_dir] {
        fs::create_dir(directory).unwrap();
    }
    let first_topology = topology(&first_dir, &[("m0", "", "")], "");
    let second_topology = topology(&second_dir, &[("m1", "", "")], "");
    let mut first = Launcher::run(&first_dir, &first_topology, &[]);
    first.wait_for("ready: m0.host");
    let first_qemu = read_pid(&first_dir.join("m0.pid"));

    let (status, output) =
        Launcher::run(&second_dir, &second_topology, &["--run-for", "1"]).finish();
    assert!(
        !status.success(),
        "a competing session overcommitted tmpfs: {output:#?}"
    );
    assert!(
        verdict(&output)["reason"]
            .as_str()
            .unwrap()
            .contains("insufficient shared-memory capacity"),
        "{output:#?}"
    );
    assert!(!second_dir.join("m1.pid").exists());
    assert!(!pool_dir(&second_dir).exists());
    assert!(alive(first_qemu));

    signal::kill(first.pid(), Signal::SIGTERM).unwrap();
    let (status, output) = first.finish();
    assert!(status.success(), "{output:#?}");
    assert!(!pool_dir(&first_dir).exists());
    let retry_topology = topology(&retry_dir, &[("m1", "", "")], "");
    let (status, output) = Launcher::run(&retry_dir, &retry_topology, &["--run-for", "1"]).finish();
    assert!(status.success(), "{output:#?}");
    assert!(!pool_dir(&retry_dir).exists());
}

#[ignore = "requires QEMU"]
#[test]
fn cleaning_a_finished_session_keeps_a_later_pool_with_the_same_name() {
    let root = directory();
    let root = root.path();
    let pool = root.join("pool");
    let topology = topology(root, &[("m0", "", "")], "");
    let start = |name: &str, extra: &[&str]| {
        let mut args = vec![
            OsString::from("run"),
            topology.clone().into(),
            "--run-dir".into(),
            root.join(name).into(),
            "--pool-dir".into(),
            pool.clone().into(),
        ];
        args.extend(extra.iter().map(OsString::from));
        Launcher::start(root, &args, Stdio::null())
    };
    let (status, output) = start("first", &["--run-for", "1"]).finish();
    assert!(status.success(), "{output:#?}");
    let mut second = start("second", &[]);
    second.wait_for("ready: m0.host");

    let clean = Launcher::start(
        root,
        &["clean".into(), root.join("first").into()],
        Stdio::null(),
    );
    let (status, output) = clean.finish();
    assert!(status.success(), "{output:#?}");
    assert!(
        pool.join("m0/pool").is_file(),
        "cleanup removed the pool of a later session"
    );

    signal::kill(second.pid(), Signal::SIGTERM).unwrap();
    let (status, output) = second.finish();
    assert!(status.success(), "{output:#?}");
    assert!(!pool.exists());
}

#[ignore = "requires QEMU"]
#[test]
fn closed_standard_input_ends_a_lifeline_session() {
    let root = directory();
    let root = root.path();
    let topology = topology(root, &[("m0", "", "")], "");
    let args = [
        OsString::from("run"),
        topology.into(),
        "--run-dir".into(),
        root.join("r").into(),
    ];
    // scripts/dev.sh enables the lifeline with this variable.
    let mut launcher = Launcher::spawn(root, &args, Stdio::piped(), Some("1"));
    launcher.wait_for("ready: m0.host");
    drop(launcher.child.stdin.take());
    let (status, output) = launcher.finish();
    assert!(status.success(), "{output:#?}");
    assert!(output.iter().any(|line| line == "stopped: m0.host"));
    assert!(!pool_dir(root).exists());
}

#[ignore = "requires QEMU"]
#[test]
fn a_failed_device_prevents_the_host_start_and_releases_resources() {
    let root = directory();
    let root = root.path();
    let binary = if cfg!(target_arch = "aarch64") {
        "qemu-system-aarch64"
    } else {
        "qemu-system-x86_64"
    };
    let kinds = "kinds:\n  broken: {role: device, model: qemu, argv: [-machine, missing]}\n";
    let devices =
        format!("[{{id: dev, kind: broken, ready_log: never, runtime: {{binary: {binary}}}}}]");
    let topology = topology(root, &[("m0", "", &devices)], kinds);
    let launcher = Launcher::run(root, &topology, &[]);
    let (status, output) = launcher.finish();
    assert!(!status.success(), "{output:#?}");
    let verdict = verdict(&output);
    assert_eq!(verdict["status"], "FAIL");
    assert!(
        verdict["reason"]
            .as_str()
            .unwrap()
            .contains("before it was ready"),
        "{verdict}"
    );
    assert!(!output.iter().any(|line| line == "started: m0.host"));
    for expected in ["started: m0.dev", "stopped: m0.dev"] {
        assert_eq!(output.iter().filter(|line| *line == expected).count(), 1);
    }
    assert!(!pool_dir(root).exists());
}

#[ignore = "requires QEMU"]
#[test]
fn cancellation_and_timeout_before_readiness_emit_stopped_once() {
    for cancelled in [true, false] {
        let root = directory();
        let root = root.path();
        let topology = topology(
            root,
            &[("m0", ", serial: {wait_for: waiting-for-guest}", "")],
            "",
        );
        let mut launcher = Launcher::run(root, &topology, &["--ready-timeout", "1"]);
        launcher.wait_for("started: m0.host");
        if cancelled {
            signal::kill(launcher.pid(), Signal::SIGTERM).unwrap();
        }
        let (status, output) = launcher.finish();
        assert_eq!(status.success(), cancelled, "{output:#?}");
        for expected in ["started: m0.host", "stopped: m0.host"] {
            assert_eq!(
                output.iter().filter(|line| *line == expected).count(),
                1,
                "{output:#?}"
            );
        }
        assert!(!output.iter().any(|line| line == "ready: m0.host"));
        let verdict = verdict(&output);
        assert_eq!(verdict["users_stopped"], true);
        assert_eq!(verdict["cleanup_errors"], serde_json::json!([]));
        if !cancelled {
            assert!(
                verdict["reason"]
                    .as_str()
                    .unwrap()
                    .contains("readiness timed out"),
                "{verdict}"
            );
        }
        assert!(!pool_dir(root).exists());
    }
}

#[ignore = "requires QEMU and qemu-img"]
#[test]
fn invalid_explicit_image_helpers_leave_paths_available_for_retry() {
    let installed = std::env::split_paths(&std::env::var_os("PATH").unwrap())
        .map(|directory| directory.join("qemu-img"))
        .find(|path| path.is_file() && access(path, AccessFlags::X_OK).is_ok())
        .unwrap();
    for exists in [false, true] {
        let root = directory();
        let root = root.path();
        let helper = root.join("qemu-img");
        let image = root.join("image.raw");
        let pool = root.join("p");
        if exists {
            fs::copy(&installed, &helper).unwrap();
            fs::set_permissions(&helper, fs::Permissions::from_mode(0o644)).unwrap();
        }
        let payload = payload(
            root,
            &format!(
                "disks: [{{id: data, path: {}, format: raw, create: true, size: 1M, readonly: true}}]",
                image.display()
            ),
        );
        let topology = topology(root, &[("m0", "", "")], "");
        let extra = [
            "--qemu-img",
            helper.to_str().unwrap(),
            "--pool-dir",
            pool.to_str().unwrap(),
            "--run-for",
            "1",
        ];
        for _ in 0..2 {
            let (status, output) =
                Launcher::run_with_payload(root, &topology, &payload, &extra).finish();
            assert!(!status.success(), "{output:#?}");
            assert!(
                output
                    .iter()
                    .any(|line| line.contains("qemu-img executable is unavailable")),
                "{output:#?}"
            );
            for path in [root.join("r"), pool.clone(), image.clone()] {
                assert!(!path.exists(), "preflight created {}", path.display());
            }
        }
        if !exists {
            fs::copy(&installed, &helper).unwrap();
        }
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o755)).unwrap();
        let (status, output) =
            Launcher::run_with_payload(root, &topology, &payload, &extra).finish();
        assert!(status.success(), "{output:#?}");
        assert_eq!(verdict(&output)["status"], "PASS");
        assert_eq!(fs::metadata(&image).unwrap().len(), 1 << 20);
        assert!(!pool.exists());
    }
}

#[ignore = "requires QEMU and qemu-img"]
#[test]
fn disks_use_overlays_and_creation_without_touching_base_images() {
    let root = directory();
    let root = root.path();
    let images = root.join("images");
    fs::create_dir(&images).unwrap();
    let base = images.join("base.raw");
    fs::write(&base, vec![7u8; 1 << 20]).unwrap();
    let created = images.join("data.raw");
    let payload = payload(
        root,
        &format!(
            "disks: [{{id: root, backing: {}, format: raw, boot: true}}, \
             {{id: data, path: {}, format: raw, create: true, size: 2M, readonly: true}}]",
            base.display(),
            created.display()
        ),
    );
    let topology = topology(root, &[("m0", "", "")], "");
    let mut launcher = Launcher::run_with_payload(root, &topology, &payload, &["--run-for", "2"]);
    launcher.wait_for("ready: m0.host");
    let overlay = root.join("r/m0/root.qcow2");
    assert!(overlay.is_file(), "the overlay exists while the host runs");
    let (status, output) = launcher.finish();
    assert!(status.success(), "{output:#?}");
    assert!(!overlay.exists(), "the overlay remains after shutdown");
    assert_eq!(fs::read(&base).unwrap(), vec![7u8; 1 << 20]);
    assert_eq!(fs::metadata(&created).unwrap().len(), 2 << 20);
    let leftovers = fs::read_dir(&images)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .filter(|name| name.starts_with('.'))
        .collect::<Vec<_>>();
    assert!(
        leftovers.is_empty(),
        "temporary images remain: {leftovers:?}"
    );
}

#[ignore = "requires QEMU"]
#[test]
fn image_leases_exclude_readers_while_a_direct_writer_runs() {
    let writer_root = directory();
    let reader_root = directory();
    let image = writer_root.path().join("shared.raw");
    fs::write(&image, vec![0u8; 1 << 20]).unwrap();
    let alias = reader_root.path().join("alias.raw");
    fs::hard_link(&image, &alias).unwrap();
    let locks = writer_root.path().join("locks");

    let writer_payload = payload(
        writer_root.path(),
        &format!(
            "disks: [{{id: d, path: {}, format: raw, readonly: false, shared: false}}]",
            image.display()
        ),
    );
    let writer_topology = topology(writer_root.path(), &[("w", "", "")], "");
    let mut writer =
        Launcher::run_with_payload(writer_root.path(), &writer_topology, &writer_payload, &[]);
    writer.wait_for("ready: w.host");
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::MetadataExt;
        let metadata = fs::metadata(&image).unwrap();
        let lease = locks.join(format!("{}-{}", metadata.dev(), metadata.ino()));
        let qemu = read_pid(&writer_root.path().join("w.pid"));
        assert!(
            holds(qemu, &lease),
            "the host does not hold its image lease"
        );
    }

    let reader_payload = payload(
        reader_root.path(),
        &format!(
            "disks: [{{id: d, path: {}, format: raw, readonly: true}}]",
            alias.display()
        ),
    );
    let reader_topology = topology(reader_root.path(), &[("r", "", "")], "");
    let args = [
        OsString::from("run"),
        reader_topology.into(),
        "--payload".into(),
        reader_payload.into(),
        "--run-dir".into(),
        reader_root.path().join("r").into(),
    ];
    let reader = Launcher::start(writer_root.path(), &args, Stdio::null());
    let (status, output) = reader.finish();
    assert!(!status.success(), "{output:#?}");
    let reason = verdict(&output)["reason"].as_str().unwrap().to_owned();
    assert!(reason.contains("in use by another session"), "{reason}");
    assert!(locks.is_dir());

    signal::kill(writer.pid(), Signal::SIGTERM).unwrap();
    let (status, output) = writer.finish();
    assert!(status.success(), "{output:#?}");
}

#[ignore = "requires QEMU built with vfio-user support"]
#[test]
fn vfio_user_devices_start_before_the_host_and_stop_after_it() {
    let sample = if cfg!(target_arch = "aarch64") {
        "machines/qemu-device-aarch64.yaml"
    } else {
        "machines/qemu-device.yaml"
    };
    let root = directory();
    let root = root.path();
    let launcher = Launcher::run(root, &samples().join(sample), &["--run-for", "1"]);
    let (status, output) = launcher.finish();
    assert!(status.success(), "{output:#?}");
    let position = |matches: &dyn Fn(&str) -> bool| {
        output
            .iter()
            .position(|line| matches(line))
            .unwrap_or_else(|| panic!("missing event: {output:#?}"))
    };
    let device = |line: &str, event: &str| line.starts_with(event) && !line.ends_with(".host");
    let device_ready = position(&|line| device(line, "ready: m0."));
    let host_started = position(&|line| line == "started: m0.host");
    let host_stopped = position(&|line| line == "stopped: m0.host");
    let device_stopped = position(&|line| device(line, "stopped: m0."));
    assert!(device_ready < host_started, "{output:#?}");
    assert!(host_stopped < device_stopped, "{output:#?}");
    assert!(!pool_dir(root).exists());
}

#[ignore = "requires QEMU built with vfio-user support and gem5-resources"]
#[test]
fn vfio_user_option_rom_is_checked_and_exposed() {
    let root = directory();
    let root = root.path();
    let (profile, host) = host_profile();
    let (arch, device) = if cfg!(target_arch = "aarch64") {
        ("aarch64", "qemu-edu-aarch64")
    } else {
        ("x86_64", "qemu-edu")
    };
    let qemu = workspace().join(format!("build/qemu/qemu-system-{arch}"));
    let source = root.join("topology.yaml");
    let rom = fs::canonicalize(root).unwrap().join("guest, firmware.rom");
    fs::write(
        &source,
        format!(
            r#"version: 1
imports: [{}, {}, {}]
machines:
  - id: m0
    host: {{use: {host}, runtime: {{binary: {}}}}}
    devices:
      - {{id: edu, use: {device}, pci: {{rom: {rom}}}}}
"#,
            samples().join("hosts/qemu.yaml").display(),
            samples().join(profile).display(),
            samples().join("devices/pci/qemu-edu.yaml").display(),
            serde_json::to_string(&qemu).unwrap(),
            rom = serde_json::to_string(&rom).unwrap(),
        ),
    )
    .unwrap();

    let (status, output) = Launcher::run(root, &source, &[]).finish();
    assert!(!status.success(), "{output:#?}");
    assert!(
        output
            .iter()
            .any(|line| line.contains("missing PCI option ROM"))
    );
    assert!(!root.join("r").exists());

    fs::copy(
        workspace().join("third_party/gem5-resources/src/x86-ubuntu-gpu-ml/files/mi300.rom"),
        &rom,
    )
    .unwrap();
    let permissions = fs::metadata(&rom).unwrap().permissions();
    fs::set_permissions(&rom, fs::Permissions::from_mode(0o0)).unwrap();
    // Root may retain read access through CAP_DAC_OVERRIDE.
    if access(&rom, AccessFlags::R_OK).is_err() {
        let (status, output) = Launcher::run(root, &source, &[]).finish();
        assert!(!status.success(), "{output:#?}");
        assert!(
            output
                .iter()
                .any(|line| line.contains("read PCI option ROM")),
            "unreadable PCI option ROM was not reported: {output:#?}"
        );
        assert!(!root.join("r").exists());
    }
    fs::set_permissions(&rom, permissions).unwrap();
    let mut launcher = Launcher::run(root, &source, &[]);
    launcher.wait_for("ready: m0.host");
    let stream = UnixStream::connect(root.join("r/m0/qmp.sock")).unwrap();
    stream.set_read_timeout(Some(TIMEOUT)).unwrap();
    stream.set_write_timeout(Some(TIMEOUT)).unwrap();
    let mut reader = BufReader::new(stream);
    qmp_command(
        &mut reader,
        serde_json::json!({"execute": "qmp_capabilities"}),
    );
    let children = qmp_command(
        &mut reader,
        serde_json::json!({
            "execute": "qom-list",
            "arguments": {"path": "/machine/peripheral-anon"}
        }),
    );
    let client = children
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["type"] == "child<vfio-user-pci>")
        .unwrap_or_else(|| panic!("missing vfio-user client: {children}"));
    let path = format!(
        "/machine/peripheral-anon/{}",
        client["name"].as_str().unwrap()
    );
    let property = |name| {
        serde_json::json!({
            "execute": "qom-get",
            "arguments": {"path": path, "property": name}
        })
    };
    assert_eq!(
        qmp_command(&mut reader, property("romfile")),
        serde_json::to_value(fs::canonicalize(&rom).unwrap()).unwrap()
    );
    assert_eq!(
        qmp_command(&mut reader, property("romsize")),
        fs::metadata(&rom).unwrap().len().next_power_of_two()
    );
    drop(reader);
    signal::kill(launcher.pid(), Signal::SIGTERM).unwrap();
    let (status, output) = launcher.finish();
    assert!(status.success(), "{output:#?}");
    assert_eq!(verdict(&output)["status"], "PASS");
    assert!(!pool_dir(root).exists());
}
