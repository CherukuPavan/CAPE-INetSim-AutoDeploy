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
    "icmp",
    "dns",
    "http",
    "http_ex",
    "https_ex",
    "hosts",
    "ftp",
    "smtp",
    "smtp_ex",
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


def _event_breakdown(network: Dict[str, Any]) -> Dict[str, int]:
    return {
        key: len(network.get(key) or [])
        for key in sorted(NETWORK_EVENT_LISTS)
        if isinstance(network.get(key), list)
    }


def _empty_network_view(network: Dict[str, Any], mode: str) -> Dict[str, Any]:
    before = _event_count(network)
    source_counts = _event_breakdown(network)

    for key in NETWORK_EVENT_LISTS:
        if isinstance(network.get(key), list):
            network[key] = []

    # These are derived packet-level aggregates that do not carry process
    # attribution. Leaving them populated could re-introduce background hosts.
    for key in ("domains", "unique_hosts", "unique_domains", "dead_hosts", "sorted"):
        if key in network:
            network[key] = [] if key != "sorted" else {}

    network["autodeploy_task_network"] = {
        "enabled": True,
        "mode": mode,
        "raw_pcap_preserved": True,
        "root_pid": None,
        "tracked_pids": 0,
        "source_event_count": before,
        "source_event_counts": source_counts,
        "suppressed_events": before,
        "kept_events": 0,
        "attribution_status": "suppressed-by-route" if mode == "strict-no-network" else "no-process-tree",
    }
    return network


def _collect_allowed_endpoints(network: Dict[str, Any]):
    ips: Set[str] = set()
    domains: Set[str] = set()

    for key in (
        "tcp", "udp", "icmp", "dns", "http", "http_ex", "https_ex",
        "smtp", "smtp_ex", "irc", "ssh", "tls",
    ):
        for event in network.get(key) or []:
            if not isinstance(event, dict):
                continue
            for field in ("src", "dst", "srcip", "dstip", "ip"):
                value = str(event.get(field) or "").strip()
                if value:
                    ips.add(value)
            for field in ("host", "hostname", "sni", "request"):
                value = str(event.get(field) or "").strip().lower().rstrip(".")
                if value:
                    domains.add(value)
            for answer in event.get("answers") or []:
                if isinstance(answer, dict):
                    value = str(answer.get("data") or answer.get("answer") or answer.get("ip") or "").strip()
                else:
                    value = str(answer or "").strip()
                if value:
                    ips.add(value)

    return ips, domains


def _filter_derived_aggregates(network: Dict[str, Any]) -> None:
    allowed_ips, allowed_domains = _collect_allowed_endpoints(network)

    hosts = network.get("hosts")
    if isinstance(hosts, list):
        kept_hosts = []
        for host in hosts:
            if not isinstance(host, dict):
                continue
            hip = str(host.get("ip") or "").strip()
            hname = str(host.get("host") or host.get("hostname") or host.get("name") or "").strip().lower().rstrip(".")
            if (hip and hip in allowed_ips) or (hname and hname in allowed_domains):
                kept_hosts.append(host)
        network["hosts"] = kept_hosts

    for key in ("unique_hosts", "unique_domains", "domains"):
        value = network.get(key)
        if not isinstance(value, list):
            continue
        if key == "domains" or key == "unique_domains":
            network[key] = [
                value0 for value0 in value
                if str(value0 or "").strip().lower().rstrip(".") in allowed_domains
            ]
        else:
            network[key] = [
                value0 for value0 in value
                if str(value0 or "").strip() in allowed_ips
            ]

    # Sorted packet-flow aggregates are generated from the PCAP without reliable
    # process attribution. The authoritative task view is the filtered lists above.
    if "sorted" in network:
        network["sorted"] = {}


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
    source_counts = _event_breakdown(network)
    metadata = {
        "enabled": True,
        "mode": "primary-process-tree",
        "raw_pcap_preserved": True,
        "root_pid": _as_pid(root.get("pid")) if root else None,
        "tracked_pids": 0,
        "source_event_count": before,
        "source_event_counts": source_counts,
        "suppressed_events": 0,
        "kept_events": 0,
        "attribution_status": "process-attributed",
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

    # Rebuild the packet-derived host/domain aggregates from the surviving,
    # process-attributed events so background-only aggregates cannot leak back
    # into the Network Analysis tabs.
    _filter_derived_aggregates(network)

    # CAPE's dead_hosts aggregate is packet-derived and has no process
    # attribution. Clear it so background-only failed connections cannot leak
    # back into the analyst-facing task-local view.
    network["dead_hosts"] = []

    after = _event_count(network)
    metadata["kept_events"] = after
    metadata["suppressed_events"] = max(metadata["suppressed_events"], before - after)
    if after == 0 and before > 0:
        metadata["attribution_status"] = "no-network-events-attributed"
    elif after > 0:
        metadata["attribution_status"] = "process-attributed"
    else:
        metadata["attribution_status"] = "no-network-events"

    network["autodeploy_task_network"] = metadata
    return network
