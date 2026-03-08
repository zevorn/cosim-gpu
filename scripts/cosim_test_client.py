#!/usr/bin/env python3
"""
Standalone mock QEMU client for MI300X gem5 co-simulation testing.

This script connects to a running gem5 MI300X co-simulation server and
exercises the cosim protocol by simulating what QEMU's mi300x-gem5 PCIe
device would do during amdgpu driver initialization.

Usage:
    # Terminal 1: Start gem5 with the cosim config
    build/VEGA_X86/gem5.opt configs/example/gpufs/mi300_cosim.py

    # Terminal 2: Run this test client
    python3 scripts/cosim_test_client.py [--socket /tmp/gem5-mi300x.sock]

    # Or run in loopback mode (no gem5 needed, uses built-in mock server):
    python3 scripts/cosim_test_client.py --loopback

Exit codes:
    0 - All tests passed
    1 - One or more tests failed
    2 - Connection error
"""

import argparse
import socket
import struct
import sys
import os
import tempfile
import threading
import time

# ======================================================================
# Protocol definitions (matches mi300x_gem5_cosim.hh)
# ======================================================================

MSG_HDR_FORMAT = '<IIQQiI'
MSG_HDR_SIZE = struct.calcsize(MSG_HDR_FORMAT)

MSG_MMIO_READ    = 0x01
MSG_MMIO_WRITE   = 0x02
MSG_DB_READ      = 0x03
MSG_DB_WRITE     = 0x04
MSG_DMA_REQ      = 0x05
MSG_INIT         = 0x06
MSG_SHUTDOWN     = 0x07
MSG_CONFIG_READ  = 0x08
MSG_CONFIG_WRITE = 0x09
MSG_FRAME_READ   = 0x0A
MSG_FRAME_WRITE  = 0x0B

MSG_MMIO_RESP    = 0x81
MSG_IRQ_RAISE    = 0x82
MSG_INIT_RESP    = 0x86

MSG_TYPE_NAMES = {
    0x01: "MMIO_READ", 0x02: "MMIO_WRITE",
    0x03: "DB_READ", 0x04: "DB_WRITE",
    0x05: "DMA_REQ", 0x06: "INIT", 0x07: "SHUTDOWN",
    0x08: "CONFIG_READ", 0x09: "CONFIG_WRITE",
    0x0A: "FRAME_READ", 0x0B: "FRAME_WRITE",
    0x81: "MMIO_RESP", 0x82: "IRQ_RAISE", 0x83: "IRQ_LOWER",
    0x84: "DMA_READ", 0x85: "DMA_WRITE", 0x86: "INIT_RESP",
}

# MI300X MMIO register addresses
MI300X_FB_LOCATION_BASE = 0x60920
MI300X_FB_LOCATION_TOP = 0x60924
MI300X_MEM_SIZE_REG = 0x60928
MP0_SMN_C2PMSG_33 = 0x3B10C
GRBM_STATUS = 0xD000
GC_VERSION = 0xD080


def pack_msg(msg_type, size=0, addr=0, data=0, access_size=0, msg_id=0):
    return struct.pack(MSG_HDR_FORMAT,
                       msg_type, size, addr, data, access_size, msg_id)


def unpack_msg(buf):
    fields = struct.unpack(MSG_HDR_FORMAT, buf)
    return {
        'type': fields[0],
        'size': fields[1],
        'addr': fields[2],
        'data': fields[3],
        'access_size': fields[4],
        'id': fields[5],
    }


# ======================================================================
# Loopback mock server
# ======================================================================

class LoopbackServer:
    """Minimal mock gem5 server for loopback testing."""

    def __init__(self, sock_path):
        self.sock_path = sock_path
        self.regs = {
            MP0_SMN_C2PMSG_33: 0x80000000,
            MI300X_FB_LOCATION_BASE: 0x8000,
            MI300X_FB_LOCATION_TOP: 0x8400,
            MI300X_MEM_SIZE_REG: 16384,
            GRBM_STATUS: 0x00000000,
            GC_VERSION: 0x00090402,
        }
        self.config = {
            0x00: 0x74A11002,
            0x04: 0x00100007,
            0x2C: 0x0C341002,
        }
        self.server_sock = None
        self.thread = None

    def start(self):
        self.server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server_sock.bind(self.sock_path)
        self.server_sock.listen(2)
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def stop(self):
        if self.server_sock:
            self.server_sock.close()

    def _run(self):
        try:
            mmio_conn, _ = self.server_sock.accept()
            # Accept second connection (event) but don't use it
            self.server_sock.settimeout(2.0)
            try:
                event_conn, _ = self.server_sock.accept()
            except socket.timeout:
                event_conn = None

            while True:
                data = mmio_conn.recv(MSG_HDR_SIZE)
                if not data or len(data) < MSG_HDR_SIZE:
                    break
                msg = unpack_msg(data)
                t = msg['type']

                if t == MSG_INIT:
                    resp = pack_msg(msg_type=MSG_INIT_RESP,
                                   msg_id=msg['id'],
                                   data=16 * 1024**3)
                    mmio_conn.sendall(resp)
                elif t == MSG_MMIO_READ:
                    val = self.regs.get(msg['addr'], 0)
                    resp = pack_msg(msg_type=MSG_MMIO_RESP,
                                   msg_id=msg['id'], addr=msg['addr'],
                                   data=val, access_size=4)
                    mmio_conn.sendall(resp)
                elif t == MSG_MMIO_WRITE:
                    self.regs[msg['addr']] = msg['data']
                elif t == MSG_CONFIG_READ:
                    val = self.config.get(msg['addr'], 0)
                    resp = pack_msg(msg_type=MSG_MMIO_RESP,
                                   msg_id=msg['id'], addr=msg['addr'],
                                   data=val, access_size=4)
                    mmio_conn.sendall(resp)
                elif t == MSG_CONFIG_WRITE:
                    self.config[msg['addr']] = msg['data']
                elif t in (MSG_DB_WRITE, MSG_FRAME_WRITE):
                    pass
                elif t == MSG_FRAME_READ:
                    resp = pack_msg(msg_type=MSG_MMIO_RESP,
                                   msg_id=msg['id'], addr=msg['addr'],
                                   data=0, access_size=4)
                    mmio_conn.sendall(resp)
                elif t == MSG_SHUTDOWN:
                    break

            mmio_conn.close()
            if event_conn:
                event_conn.close()
        except Exception:
            pass


# ======================================================================
# Test client
# ======================================================================

class CosimTestClient:
    """Test client that exercises the gem5 cosim protocol."""

    def __init__(self, sock_path, verbose=False):
        self.sock_path = sock_path
        self.verbose = verbose
        self.sock = None
        self.event_sock = None
        self._msg_id = 0
        self.passed = 0
        self.failed = 0
        self.errors = []

    def _next_id(self):
        self._msg_id += 1
        return self._msg_id

    def _log(self, msg):
        if self.verbose:
            print(f"  [CLIENT] {msg}")

    def connect(self):
        """Connect MMIO and event sockets."""
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(10.0)
        self.sock.connect(self.sock_path)
        self._log(f"MMIO connected to {self.sock_path}")

        self.event_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.event_sock.settimeout(5.0)
        self.event_sock.connect(self.sock_path)
        self._log("Event socket connected")

    def close(self):
        """Send SHUTDOWN and close."""
        try:
            self.sock.sendall(
                pack_msg(msg_type=MSG_SHUTDOWN, msg_id=self._next_id()))
        except Exception:
            pass
        self.sock.close()
        if self.event_sock:
            self.event_sock.close()

    def _send_recv(self, msg_type, addr=0, data=0, access_size=4):
        """Send a request and receive response."""
        mid = self._next_id()
        self.sock.sendall(pack_msg(
            msg_type=msg_type, msg_id=mid,
            addr=addr, data=data, access_size=access_size))
        resp = unpack_msg(self.sock.recv(MSG_HDR_SIZE))
        type_name = MSG_TYPE_NAMES.get(msg_type, f"0x{msg_type:02x}")
        self._log(f"{type_name} addr=0x{addr:x} -> 0x{resp['data']:x}")
        return resp

    def _send_fire_forget(self, msg_type, addr=0, data=0, access_size=4):
        """Send a fire-and-forget message."""
        mid = self._next_id()
        self.sock.sendall(pack_msg(
            msg_type=msg_type, msg_id=mid,
            addr=addr, data=data, access_size=access_size))
        type_name = MSG_TYPE_NAMES.get(msg_type, f"0x{msg_type:02x}")
        self._log(f"{type_name} addr=0x{addr:x} data=0x{data:x}")

    def check(self, name, actual, expected):
        """Compare actual vs expected, like SSH output comparison."""
        if actual == expected:
            self.passed += 1
            print(f"  PASS: {name}: {actual}")
        else:
            self.failed += 1
            self.errors.append(name)
            print(f"  FAIL: {name}: got {actual}, expected {expected}")

    # --- Test steps ---

    def test_init(self):
        """Test INIT handshake."""
        mid = self._next_id()
        self.sock.sendall(pack_msg(
            msg_type=MSG_INIT, msg_id=mid, data=16 * 1024**3))
        resp = unpack_msg(self.sock.recv(MSG_HDR_SIZE))
        self.check("INIT handshake",
                   resp['type'], MSG_INIT_RESP)
        self.check("INIT vram_size",
                   resp['data'], 16 * 1024 * 1024 * 1024)

    def test_pci_enum(self):
        """Test PCI config space enumeration."""
        resp = self._send_recv(MSG_CONFIG_READ, addr=0x00)
        vendor = resp['data'] & 0xFFFF
        device = (resp['data'] >> 16) & 0xFFFF
        self.check("PCI VendorID", f"0x{vendor:04x}", "0x1002")
        self.check("PCI DeviceID", f"0x{device:04x}", "0x74a1")

    def test_psp_status(self):
        """Test PSP firmware ready status."""
        resp = self._send_recv(MSG_MMIO_READ, addr=MP0_SMN_C2PMSG_33)
        self.check("PSP firmware ready",
                   f"0x{resp['data']:08x}", "0x80000000")

    def test_fb_location(self):
        """Test MMHUB framebuffer location registers."""
        resp_base = self._send_recv(MSG_MMIO_READ, addr=MI300X_FB_LOCATION_BASE)
        resp_top = self._send_recv(MSG_MMIO_READ, addr=MI300X_FB_LOCATION_TOP)
        self.check("FB_LOCATION_BASE non-zero",
                   resp_base['data'] > 0, True)
        self.check("FB_LOCATION_TOP > BASE",
                   resp_top['data'] > resp_base['data'], True)

    def test_vram_size(self):
        """Test VRAM size register."""
        resp = self._send_recv(MSG_MMIO_READ, addr=MI300X_MEM_SIZE_REG)
        size_gb = resp['data'] / 1024
        self.check("VRAM size (GB)", size_gb, 16.0)

    def test_grbm_status(self):
        """Test GRBM status (should be idle)."""
        resp = self._send_recv(MSG_MMIO_READ, addr=GRBM_STATUS)
        self.check("GRBM_STATUS (idle)", resp['data'], 0)

    def test_gc_version(self):
        """Test GC version register (gfx942)."""
        resp = self._send_recv(MSG_MMIO_READ, addr=GC_VERSION)
        major = (resp['data'] >> 16) & 0xFF
        minor = (resp['data'] >> 8) & 0xFF
        stepping = resp['data'] & 0xFF
        gfx_ver = f"gfx{major}{minor:01x}{stepping:01x}"
        self.check("GC version", gfx_ver, "gfx942")

    def test_mmio_write_read(self):
        """Test MMIO write then read back."""
        self._send_fire_forget(MSG_MMIO_WRITE, addr=0x1234, data=0xBEEF)
        resp = self._send_recv(MSG_MMIO_READ, addr=0x1234)
        self.check("MMIO write/read", f"0x{resp['data']:x}", "0xbeef")

    def test_doorbell(self):
        """Test doorbell write (fire-and-forget, no crash = pass)."""
        self._send_fire_forget(MSG_DB_WRITE, addr=0x0, data=0x42)
        self.passed += 1
        print("  PASS: Doorbell write (no crash)")

    def run_all(self):
        """Run all test steps in sequence."""
        print("\n" + "=" * 60)
        print("MI300X Co-simulation Test Client")
        print("=" * 60)
        print(f"Connecting to {self.sock_path}...")

        try:
            self.connect()
        except (ConnectionRefusedError, FileNotFoundError) as e:
            print(f"ERROR: Cannot connect: {e}")
            return 2

        print("Connected. Running tests:\n")

        tests = [
            self.test_init,
            self.test_pci_enum,
            self.test_psp_status,
            self.test_fb_location,
            self.test_vram_size,
            self.test_grbm_status,
            self.test_gc_version,
            self.test_mmio_write_read,
            self.test_doorbell,
        ]

        for test in tests:
            try:
                test()
            except Exception as e:
                self.failed += 1
                self.errors.append(test.__name__)
                print(f"  ERROR: {test.__name__}: {e}")

        self.close()

        print(f"\n{'=' * 60}")
        print(f"Results: {self.passed} passed, {self.failed} failed")
        if self.errors:
            print(f"Failed tests: {', '.join(self.errors)}")
        print("=" * 60)

        return 0 if self.failed == 0 else 1


def main():
    parser = argparse.ArgumentParser(
        description="MI300X co-simulation test client")
    parser.add_argument("--socket", default="/tmp/gem5-mi300x.sock",
                       help="Unix socket path (default: /tmp/gem5-mi300x.sock)")
    parser.add_argument("--loopback", action="store_true",
                       help="Use built-in mock server (no gem5 needed)")
    parser.add_argument("-v", "--verbose", action="store_true",
                       help="Verbose output")
    args = parser.parse_args()

    server = None
    sock_path = args.socket

    if args.loopback:
        sock_path = tempfile.mktemp(suffix='.sock', prefix='cosim_lb_')
        server = LoopbackServer(sock_path)
        server.start()
        time.sleep(0.2)
        print(f"Loopback server started on {sock_path}")

    client = CosimTestClient(sock_path, verbose=args.verbose)
    rc = client.run_all()

    if server:
        server.stop()
        if os.path.exists(sock_path):
            os.unlink(sock_path)

    sys.exit(rc)


if __name__ == "__main__":
    main()
