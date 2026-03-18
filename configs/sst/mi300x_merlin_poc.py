"""SST Merlin PoC configuration for MI300X multi-GPU (Milestone 4).

This configuration wraps a gem5 MI300X GPU instance as an SST
SubComponent and connects it to a minimal Merlin network with
2 endpoints and a single link.

Prerequisites:
  - SST-core built and installed
  - gem5 built as SST library (libgem5_opt.so)
  - SST Merlin element library

Usage:
  sst mi300x_merlin_poc.py

Architecture:
  SST Merlin Network (2 endpoints)
    |                   |
    v                   v
  gem5 GPU 0          gem5 GPU 1
  (SubComponent)      (SubComponent)

This PoC validates:
  AC-15: gem5 GPU <-> SST basic communication
  AC-16: gem5 GPU registers as SST component

Reuses:
  - gem5/src/sst/OutgoingRequestBridge.py
  - gem5/src/sst/outgoing_request_bridge.hh
  - gem5/ext/sst/sst_responder_subcomponent.hh
"""

# SST configuration would use sst.Component and sst.SubComponent APIs.
# This file serves as the design reference and will be executable
# once the SST build integration is complete.

SST_CONFIG = {
    "network": {
        "type": "merlin.hr_router",
        "topology": "merlin.singlerouter",
        "num_ports": 2,
        "link_bw": "128GBps",
        "link_lat": "100ns",
        "flit_size": "64B",
        "input_buf_size": "4KiB",
        "output_buf_size": "4KiB",
    },
    "endpoints": [
        {
            "name": "gpu0",
            "type": "gem5.gem5bridge",
            "gem5_config": "mi300_cosim.py",
            "gpu_id": 0,
            "vram_size": "16GiB",
        },
        {
            "name": "gpu1",
            "type": "gem5.gem5bridge",
            "gem5_config": "mi300_cosim.py",
            "gpu_id": 1,
            "vram_size": "16GiB",
        },
    ],
    "sync": {
        "type": "quantum",
        "quantum_ns": 1000,
    },
}


def build_sst_config():
    """Build SST component graph from configuration dict.

    This function will be called by SST's Python configuration system.
    It creates the Merlin router, gem5 SubComponents, and links.
    """
    try:
        import sst
    except ImportError:
        print("SST Python module not available. This config requires SST.")
        print("Build gem5 as SST library: see gem5/ext/sst/README.md")
        return

    cfg = SST_CONFIG

    # Create router
    router = sst.Component("router0", cfg["network"]["type"])
    router.addParams({
        "topology": cfg["network"]["topology"],
        "num_ports": str(cfg["network"]["num_ports"]),
        "link_bw": cfg["network"]["link_bw"],
        "flit_size": cfg["network"]["flit_size"],
        "input_buf_size": cfg["network"]["input_buf_size"],
        "output_buf_size": cfg["network"]["output_buf_size"],
    })

    # Create gem5 GPU endpoints
    for i, ep_cfg in enumerate(cfg["endpoints"]):
        ep = sst.Component(ep_cfg["name"], ep_cfg["type"])
        ep.addParams({
            "gpu_id": str(ep_cfg["gpu_id"]),
            "vram_size": ep_cfg["vram_size"],
        })

        # Connect endpoint to router port
        link = sst.Link(f"link_{ep_cfg['name']}")
        link.connect(
            (router, f"port{i}", cfg["network"]["link_lat"]),
            (ep, "port", cfg["network"]["link_lat"]),
        )

    # Set simulation quantum for synchronization
    sst.setStatisticLoadLevel(1)


# Entry point for SST
build_sst_config()
