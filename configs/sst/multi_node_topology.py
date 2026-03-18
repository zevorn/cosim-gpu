"""Multi-node GPU cluster topology configurations (Milestone 5).

Defines network topologies for super-node scale-out via SST Merlin:
  - Fat-tree: hierarchical switching for balanced bandwidth
  - Dragonfly: low-diameter high-radix for large-scale clusters

Each node contains 8 GPUs connected via intra-node xGMI mesh.
Nodes connect via NIC/Ethernet (Ultra Ethernet or RoCE) through
the SST Merlin network.

Hybrid routing:
  - Intra-node GPU traffic -> xGMI mesh (low latency, 128 GB/s)
  - Inter-node GPU traffic -> NIC -> Ethernet -> NIC (higher latency)
"""


class NodeConfig:
    """Single compute node with 8 GPUs."""

    def __init__(self, node_id, gpus_per_node=8):
        self.node_id = node_id
        self.gpus_per_node = gpus_per_node
        self.gpu_base_id = node_id * gpus_per_node

    def gpu_ids(self):
        return list(range(self.gpu_base_id,
                          self.gpu_base_id + self.gpus_per_node))


class NICModel:
    """Network Interface Controller stub for inter-node communication.

    Models Ultra Ethernet / RoCE NIC with configurable parameters.
    Bridges between intra-node xGMI and inter-node Ethernet.
    """

    def __init__(self, node_id, bandwidth="100GBps", latency="1us"):
        self.node_id = node_id
        self.bandwidth = bandwidth
        self.latency = latency

    def is_local(self, src_gpu, dst_gpu, gpus_per_node=8):
        """Check if communication is intra-node (use xGMI) or
        inter-node (use NIC/Ethernet)."""
        src_node = src_gpu // gpus_per_node
        dst_node = dst_gpu // gpus_per_node
        return src_node == dst_node


def build_fat_tree(num_nodes, gpus_per_node=8,
                   inter_node_bw="100GBps", inter_node_lat="1us"):
    """Build fat-tree topology configuration for SST Merlin.

    Fat-tree with k-ary structure:
      - Leaf switches connect to node NICs
      - Spine switches provide full bisection bandwidth
    """
    nodes = [NodeConfig(i, gpus_per_node) for i in range(num_nodes)]
    nics = [NICModel(i, inter_node_bw, inter_node_lat)
            for i in range(num_nodes)]

    return {
        "topology": "merlin.fattree",
        "num_nodes": num_nodes,
        "gpus_per_node": gpus_per_node,
        "total_gpus": num_nodes * gpus_per_node,
        "nodes": nodes,
        "nics": nics,
        "inter_node": {
            "bandwidth": inter_node_bw,
            "latency": inter_node_lat,
        },
        "intra_node": {
            "type": "xgmi_mesh",
            "bandwidth": "128GBps",
            "latency": "100ns",
        },
    }


def build_dragonfly(num_nodes, gpus_per_node=8,
                    inter_node_bw="100GBps", inter_node_lat="1us"):
    """Build dragonfly topology configuration for SST Merlin.

    Dragonfly with group-based structure:
      - Intra-group: full mesh between routers
      - Inter-group: global links between groups
    """
    nodes = [NodeConfig(i, gpus_per_node) for i in range(num_nodes)]
    nics = [NICModel(i, inter_node_bw, inter_node_lat)
            for i in range(num_nodes)]

    return {
        "topology": "merlin.dragonfly",
        "num_nodes": num_nodes,
        "gpus_per_node": gpus_per_node,
        "total_gpus": num_nodes * gpus_per_node,
        "nodes": nodes,
        "nics": nics,
        "inter_node": {
            "bandwidth": inter_node_bw,
            "latency": inter_node_lat,
        },
        "intra_node": {
            "type": "xgmi_mesh",
            "bandwidth": "128GBps",
            "latency": "100ns",
        },
    }


# Pre-defined configurations for validation (AC-19, AC-20)
CONFIGS = {
    "2node_fattree": build_fat_tree(2),
    "4node_fattree": build_fat_tree(4),
    "8node_fattree": build_fat_tree(8),
    "2node_dragonfly": build_dragonfly(2),
    "4node_dragonfly": build_dragonfly(4),
    "8node_dragonfly": build_dragonfly(8),
}
