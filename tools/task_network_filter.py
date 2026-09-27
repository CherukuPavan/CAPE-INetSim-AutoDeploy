#!/usr/bin/env python3
"""Task-attributed Network Analysis filtering for CAPE.

The raw PCAP is intentionally left untouched for forensic use. The analyst-
facing CAPE Network Analysis result is kept task-local by attributing events
to the primary analysis process tree. For route=drop/none, the analyst-facing
network result is intentionally empty because the route is a strict no-network
analysis path; raw PCAP remains available for forensic inspection.
"""

from __future__ import annotations

from typing import Any, Dict, Set


NETWORK_EVENT_LISTS = {
    "tcp",
    "udp",
    "dns",
    "http",
    "http_ex",
    "https_ex",
    "hosts",
    "ftp",
    "smtp",
    "irc",
    "ssh",
    "tls",
}


def _as_pid(value: Any):
    try:
        pid = int(value)
    except (TypeError, ValueError):
        return None
    return pid if pid > 0 else None


def _walk_tree(root: Dict[str, Any]) -> Set[int]:
    pids: Set[int] = set()
    stack = [root]
    while stack:
        node = stack.pop()
        if not isinstance(node, dict):
            continue
        pid = _as_pid(node.get("pid"))
        if pid is not None:
            pids.add(pid)
        children = node.get("children") or []
        if isinstance(children, list):
            stack.extend(children)
    return pids


def _event_pid(event: Dict[str, Any]):
    return _as_pid(event.get("process_id"))


def _event_count(network: Dict[str, Any]) -> int:
    total = 0
    for key in NETWORK_EVENT_LISTS:
        value = network.get(key)
        if isinstance(value, list):
            total += len(value)
    return total


def _empty_network_view(network: Dict[str, Any], mode: str) -> Dict[str, Any]:
    before = _event_count(network)
    for key in NETWORK_EVENT_LISTS:
        if isinstance(network.get(key), list):
            network[key] = []
    network["autodeploy_task_network"] = {
        "enabled": True,
        "mode": mode,
        "raw_pcap_preserved": True,
        "root_pid": None,
        "tracked_pids": 0,
        "suppressed_events": before,
        "kept_events": 0,
    }
    return network


def filter_network_to_task_process_tree(
    network: Dict[str, Any],
    behavior: Dict[str, Any],
    route: str = "",
) -> Dict[str, Any]:
    """Keep only network events attributed to the task's primary process tree.

    CAPE's ProcessTree is the authority for task-local process attribution.
    The first ProcessTree root is treated as the primary submitted-analysis
    process and every descendant is retained.

    For route=drop/none/false, the user-facing Network Analysis view is
    deliberately empty. This enforces the semantic contract that "No network"
    presents no network-analysis events, while the raw dump.pcap remains
    untouched and available for forensic inspection.
    """
    if not isinstance(network, dict):
        return {}

    route = str(route or "").strip().lower()
    if route in {"none", "drop", "false"}:
        return _empty_network_view(network, "strict-no-network")

    tree = behavior.get("processtree") if isinstance(behavior, dict) else None
    roots = tree if isinstance(tree, list) else []
    root = roots[0] if roots and isinstance(roots[0], dict) else None

    before = _event_count(network)
    metadata = {
        "enabled": True,
        "mode": "primary-process-tree",
        "raw_pcap_preserved": True,
        "root_pid": _as_pid(root.get("pid")) if root else None,
        "tracked_pids": 0,
        "suppressed_events": 0,
        "kept_events": 0,
    }

    if root is None:
        return _empty_network_view(network, "primary-process-tree-no-root")

    tracked = _walk_tree(root)
    metadata["tracked_pids"] = len(tracked)

    for key in NETWORK_EVENT_LISTS:
        value = network.get(key)
        if not isinstance(value, list):
            continue

        kept = []
        for event in value:
            if not isinstance(event, dict):
                metadata["suppressed_events"] += 1
                continue
            pid = _event_pid(event)
            if pid is not None and pid in tracked:
                kept.append(event)
            else:
                metadata["suppressed_events"] += 1
        network[key] = kept

    after = _event_count(network)
    metadata["kept_events"] = after
    metadata["suppressed_events"] = max(metadata["suppressed_events"], before - after)
    network["autodeploy_task_network"] = metadata
    return network
