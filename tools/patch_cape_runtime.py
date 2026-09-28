#!/usr/bin/env python3
"""Apply deterministic CAPE runtime integrations for RC66.

The live CAPE source is modified only after AutoDeploy has created protected
transaction backups. Patches are marker-gated and require unique upstream
anchors from the supported CAPEv2 compatibility layout.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil


MARKER_ROOTER = "CAPE_INETSIM_AUTODEPLOY_ROUTE_V4"
MARKER_ANALYSIS = "CAPE_INETSIM_AUTODEPLOY_ROUTE_V4"
MARKER_NETWORK = "CAPE_INETSIM_AUTODEPLOY_TASK_NETWORK_V2"
MARKER_NETWORK_UI = "CAPE_INETSIM_AUTODEPLOY_NETWORK_UI_V1"
MARKER_SUBMISSION = "CAPE_INETSIM_AUTODEPLOY_ROUTE_UI_V2"
MARKER_STARTUP = "CAPE_INETSIM_AUTODEPLOY_INETSIM_NO_NAT_V1"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")


def patch_rooter(path: Path) -> None:
    s = read(path)
    if s.count(MARKER_ROOTER):
        if s.count(MARKER_ROOTER) != 1:
            raise RuntimeError("RC66 rooter route marker is ambiguous")

        # Migrate only the known earlier V4 route-policy shape. Unknown V4
        # implementations fail closed rather than being silently overwritten.
        # Existing deployed V4 installations also used an ingress-interface
        # match in the per-task chain. On libvirt/KVM that can be vnetX at the
        # FORWARD hook, so retain the source/effective-egress policy but migrate
        # the known old function body to the tap-safe form.
        policy_start = s.find("def autodeploy_route_policy_set(")
        policy_marker = "\\n\\n# CAPE_INETSIM_AUTODEPLOY_ROUTE_V4"
        policy_end = s.find(policy_marker, policy_start) if policy_start >= 0 else -1
        if policy_start < 0 or policy_end < 0:
            raise RuntimeError("existing V4 rooter route policy function is missing")
        policy_block = s[policy_start:policy_end]
        if "if ingress_interface:" in policy_block:
            if policy_block.count("if ingress_interface:") != 3:
                raise RuntimeError("existing V4 rooter route policy has an unknown ingress-match shape")
            canonical_policy = '''def autodeploy_route_policy_set(ipaddr, ingress_interface="", allowed_interface="", resultserver_ip="", resultserver_port=""):
    """Allow only the selected analysis egress plus CAPE ResultServer traffic."""
    chain = _autodeploy_policy_chain(ipaddr)
    autodeploy_route_policy_reset(ipaddr)

    out, err = run(ServicePaths.iptables, "-N", chain)
    if err and "Chain already exists" not in err:
        raise RuntimeError("RC66 could not create policy chain %s: %s" % (chain, err.strip()))
    run(ServicePaths.iptables, "-F", chain)

    if resultserver_ip and resultserver_port:
        # Match the management source and ResultServer destination, but do not
        # pin the Linux FORWARD input device. On libvirt bridge networking the
        # packet may appear as the tap device rather than the bridge name.
        rule_pos = [
            "-I", chain, "1",
            "--source", ipaddr,
            "--destination", resultserver_ip,
            "-p", "tcp",
            "--dport", resultserver_port,
            "-j", "ACCEPT",
        ]
        _autodeploy_checked_rule(*rule_pos)

    if allowed_interface:
        pos = "2" if resultserver_ip and resultserver_port else "1"
        # Match only the source and selected egress device. The ingress
        # device is intentionally not constrained because libvirt bridge/tap
        # plumbing can expose the guest frame under vnetX at FORWARD.
        rule_pos = [
            "-I", chain, pos,
            "--source", ipaddr,
            "--destination", "0.0.0.0/0",
            "-o", allowed_interface,
            "-j", "ACCEPT",
        ]
        _autodeploy_checked_rule(*rule_pos)
        drop_pos = "3" if resultserver_ip and resultserver_port else "2"
    else:
        drop_pos = "2" if resultserver_ip and resultserver_port else "1"

    # Final source-scoped deny preserves the selected-route allowlist while
    # avoiding a dependency on the bridge's L3 input-device representation.
    rule_pos = ["-I", chain, drop_pos, "--source", ipaddr, "-j", "DROP"]
    _autodeploy_checked_rule(*rule_pos)

    # Enforce the per-task decision at the top of FORWARD. CAPE native's
    # ESTABLISHED/RELATED acceptance must not bypass the task policy.
    _autodeploy_checked_rule(
        "-I", "FORWARD", "1",
        "-j", chain,
    )
'''
            s = s[:policy_start] + canonical_policy + s[policy_end:]
        legacy_reset = (
            '    while True:\n'
            '        _, err = run_iptables("-D", "CAPE_REJECTED_SEGMENTS", "-j", chain)\n'
            '        if err:\n'
            '            break\n'
        )
        canonical_reset = (
            '    # Remove a jump left by any RC66 route-policy revision from both possible\n'
            '    # parent chains before recreating the task policy.\n'
            '    for parent in ("FORWARD", "CAPE_REJECTED_SEGMENTS"):\n'
            '        while True:\n'
            '            _, err = run_iptables("-D", parent, "-j", chain)\n'
            '            if err:\n'
            '                break\n'
        )
        if legacy_reset in s:
            s = s.replace(legacy_reset, canonical_reset, 1)

        legacy_insert = (
            '    # CAPE_REJECTED_SEGMENTS is traversed before CAPE_ACCEPTED_SEGMENTS, so the\n'
            '    # per-task policy is enforced before any broad forwarding allow rule.\n'
            '    _autodeploy_checked_rule(\n'
            '        "-I", "CAPE_REJECTED_SEGMENTS", "1",\n'
            '        "-j", chain,\n'
            '    )\n'
        )
        canonical_insert = (
            '    # Enforce the per-task decision at the top of FORWARD. CAPE native\'s\n'
            '    # ESTABLISHED/RELATED acceptance must not bypass the task policy.\n'
            '    _autodeploy_checked_rule(\n'
            '        "-I", "FORWARD", "1",\n'
            '        "-j", chain,\n'
            '    )\n'
        )
        if legacy_insert in s:
            s = s.replace(legacy_insert, canonical_insert, 1)

        if ("for parent in (\"FORWARD\", \"CAPE_REJECTED_SEGMENTS\")" not in s or
                '        "-I", "FORWARD", "1",' not in s):
            raise RuntimeError("existing V4 rooter route policy has an unknown shape; refusing upgrade")
        write(path, s)
        return

    anchor = "def drop_enable(ipaddr, resultserver_port):\n"
    if anchor not in s:
        raise RuntimeError("rooter drop_enable anchor not found")

    insert = '''def _autodeploy_policy_chain(ipaddr):
    """Return a stable, short iptables chain name for an IPv4 task source."""
    safe = "".join(ch if ch.isalnum() else "_" for ch in str(ipaddr))
    return ("CAPEAD_" + safe)[:28]


def autodeploy_route_policy_reset(ipaddr):
    """Remove only the RC66 per-source policy chain and its jump."""
    chain = _autodeploy_policy_chain(ipaddr)

    # Remove a jump left by any RC66 route-policy revision from both possible
    # parent chains before recreating the task policy.
    for parent in ("FORWARD", "CAPE_REJECTED_SEGMENTS"):
        while True:
            _, err = run_iptables("-D", parent, "-j", chain)
            if err:
                break

    # Chain-management operations must not receive rule-match/comment arguments.
    run(ServicePaths.iptables, "-F", chain)
    run(ServicePaths.iptables, "-X", chain)


def _autodeploy_checked_rule(*args):
    out, err = run_iptables(*args)
    if err:
        raise RuntimeError("RC66 iptables rule failed: %s" % err.strip())


def autodeploy_route_policy_set(ipaddr, ingress_interface="", allowed_interface="", resultserver_ip="", resultserver_port=""):
    """Allow only the selected analysis egress plus CAPE ResultServer traffic."""
    chain = _autodeploy_policy_chain(ipaddr)
    autodeploy_route_policy_reset(ipaddr)

    out, err = run(ServicePaths.iptables, "-N", chain)
    if err and "Chain already exists" not in err:
        raise RuntimeError("RC66 could not create policy chain %s: %s" % (chain, err.strip()))
    run(ServicePaths.iptables, "-F", chain)

    if resultserver_ip and resultserver_port:
        # Match the management source and ResultServer destination, but do not
        # pin the Linux FORWARD input device. On libvirt bridge networking the
        # packet may appear as the tap device rather than the bridge name.
        rule_pos = [
            "-I", chain, "1",
            "--source", ipaddr,
            "--destination", resultserver_ip,
            "-p", "tcp",
            "--dport", resultserver_port,
            "-j", "ACCEPT",
        ]
        _autodeploy_checked_rule(*rule_pos)

    if allowed_interface:
        pos = "2" if resultserver_ip and resultserver_port else "1"
        # Match only the source and selected egress device. The ingress
        # device is intentionally not constrained because libvirt bridge/tap
        # plumbing can expose the guest frame under vnetX at FORWARD.
        rule_pos = [
            "-I", chain, pos,
            "--source", ipaddr,
            "--destination", "0.0.0.0/0",
            "-o", allowed_interface,
            "-j", "ACCEPT",
        ]
        _autodeploy_checked_rule(*rule_pos)
        drop_pos = "3" if resultserver_ip and resultserver_port else "2"
    else:
        drop_pos = "2" if resultserver_ip and resultserver_port else "1"

    # Final source-scoped deny preserves the selected-route allowlist while
    # avoiding a dependency on the bridge's L3 input-device representation.
    rule_pos = ["-I", chain, drop_pos, "--source", ipaddr, "-j", "DROP"]
    _autodeploy_checked_rule(*rule_pos)

    # Enforce the per-task decision at the top of FORWARD. CAPE native's
    # ESTABLISHED/RELATED acceptance must not bypass the task policy.
    _autodeploy_checked_rule(
        "-I", "FORWARD", "1",
        "-j", chain,
    )


# CAPE_INETSIM_AUTODEPLOY_ROUTE_V4
'''
    s = s.replace(anchor, insert + anchor, 1)

    handlers_anchor = "handlers = {\n"
    if handlers_anchor not in s:
        raise RuntimeError("rooter handlers dictionary anchor not found")
    handler_lines = '''    "autodeploy_route_policy_reset": autodeploy_route_policy_reset,
    "autodeploy_route_policy_set": autodeploy_route_policy_set,
'''
    s = s.replace(handlers_anchor, handlers_anchor + handler_lines, 1)

    write(path, s)


def patch_analysis_manager(path: Path) -> None:
    s = read(path)
    if s.count(MARKER_ANALYSIS):
        if s.count(MARKER_ANALYSIS) != 1:
            raise RuntimeError("RC66 analysis-manager route marker is ambiguous")
        return

    route_start = '''        routing = Config("routing")
        self.route = routing.routing.route

        if self.task.route:
            self.route = self.task.route

'''
    route_replacement = '''        routing = Config("routing")
        self.route = routing.routing.route

        if self.task.route:
            self.route = self.task.route

        # CAPE_INETSIM_AUTODEPLOY_ROUTE_V4
        # Reset stale RC66 policy and any stale INetSim redirect from an
        # interrupted task before applying the new task's route.
        rooter("autodeploy_route_policy_reset", self.machine.ip)
        rooter(
            "inetsim_disable",
            self.machine.ip,
            str(routing.inetsim.server),
            str(routing.inetsim.dnsport),
            str(self.machine.resultserver_port),
            str(routing.inetsim.ports),
        )

'''
    if route_start not in s:
        raise RuntimeError("analysis-manager route start anchor not found")
    s = s.replace(route_start, route_replacement, 1)

    inetsim_anchor = '''        if self.route == "inetsim":
            self.rooter_response = rooter(
                "inetsim_enable",
                self.machine.ip,
                str(routing.inetsim.server),
                str(routing.inetsim.dnsport),
                str(self.machine.resultserver_port),
                str(routing.inetsim.ports),
            )

        elif self.route == "tor":
'''
    inetsim_replacement = '''        # RC66 Fake Internet route
        if self.route == "inetsim":
            self.rooter_response = rooter(
                "autodeploy_route_policy_set",
                self.machine.ip,
                self.machine.interface,
                self.interface,
                str(self.cfg.resultserver.ip),
                str(self.machine.resultserver_port),
            )
            self._rooter_response_check()
            self.rooter_response = rooter(
                "inetsim_enable",
                self.machine.ip,
                str(routing.inetsim.server),
                str(routing.inetsim.dnsport),
                str(self.machine.resultserver_port),
                str(routing.inetsim.ports),
            )

        elif self.route == "tor":
'''
    if inetsim_anchor not in s:
        raise RuntimeError("analysis-manager inetsim route anchor not found")
    s = s.replace(inetsim_anchor, inetsim_replacement, 1)

    drop_anchor = '''        elif str(self.route).lower() in ("none", "drop", "false"):
            self.rooter_response = rooter("drop_enable", self.machine.ip, str(self.machine.resultserver_port))
'''
    drop_replacement = '''        elif str(self.route).lower() in ("none", "drop", "false"):
            # RC66 No-network route: only the CAPE ResultServer control flow is
            # excepted; all other guest-originated forwarding is dropped.
            self.rooter_response = rooter(
                "autodeploy_route_policy_set",
                self.machine.ip,
                self.machine.interface,
                "",
                str(self.cfg.resultserver.ip),
                str(self.machine.resultserver_port),
            )
            self._rooter_response_check()
            self.rooter_response = rooter("drop_enable", self.machine.ip, str(self.machine.resultserver_port))
'''
    if drop_anchor not in s:
        raise RuntimeError("analysis-manager drop route anchor not found")
    s = s.replace(drop_anchor, drop_replacement, 1)

    internet_anchor = '''        self._rooter_response_check()

        # nexthop bind (self.interface is None for a gateway route, so the generic
'''
    internet_replacement = '''        # RC66 Internet route: allow only the discovered dirty line for this
        # source, plus the CAPE ResultServer control path.
        if self.route == "internet" and self.interface:
            self.rooter_response = rooter(
                "autodeploy_route_policy_set",
                self.machine.ip,
                self.machine.interface,
                self.interface,
                str(self.cfg.resultserver.ip),
                str(self.machine.resultserver_port),
            )
            self._rooter_response_check()

        self._rooter_response_check()

        # nexthop bind (self.interface is None for a gateway route, so the generic
'''
    if internet_anchor not in s:
        raise RuntimeError("analysis-manager generic route anchor not found")
    s = s.replace(internet_anchor, internet_replacement, 1)

    unroute_anchor = '''        if self.no_local_routing:
            rooter("delete_dev_from_vrf", self.machine.interface)
        elif self.rt_table:
            self.rooter_response = rooter("srcroute_disable", self.rt_table, self.machine.ip)
            self._rooter_response_check()

        if self.route == "inetsim":
'''
    unroute_replacement = '''        if self.no_local_routing:
            rooter("delete_dev_from_vrf", self.machine.interface)
        elif self.rt_table:
            self.rooter_response = rooter("srcroute_disable", self.rt_table, self.machine.ip)
            self._rooter_response_check()

        # RC66 policy teardown is performed before INetSim-specific teardown.
        rooter("autodeploy_route_policy_reset", self.machine.ip)

        if self.route == "inetsim":
'''
    if unroute_anchor not in s:
        raise RuntimeError("analysis-manager unroute route anchor not found")
    s = s.replace(unroute_anchor, unroute_replacement, 1)

    write(path, s)


def patch_network(path: Path) -> None:
    s = read(path)
    if s.count(MARKER_NETWORK):
        if s.count(MARKER_NETWORK) != 1:
            raise RuntimeError("RC66 network-processing marker is ambiguous")
        return

    import_anchor = '''from lib.cuckoo.common.path_utils import path_delete, path_exists, path_mkdir, path_read_file, path_write_file
'''
    import_replacement = import_anchor + '''# RC66 task-network helper import
from modules.processing.autodeploy_task_network import filter_network_to_task_process_tree
'''
    if import_anchor not in s:
        raise RuntimeError("network processing import anchor not found")
    s = s.replace(import_anchor, import_replacement, 1)

    run_anchor = '''        if proc_cfg.network.process_map:
            self._process_map(results)
            if proc_cfg.network.merge_behavior_map:
                self._merge_behavior_network(results)

        return results
'''
    run_replacement = '''        if proc_cfg.network.process_map:
            self._process_map(results)
            if proc_cfg.network.merge_behavior_map:
                self._merge_behavior_network(results)

        # CAPE_INETSIM_AUTODEPLOY_TASK_NETWORK_V2
        # Keep only network events attributed to the primary analysis process
        # or one of its descendants. Raw dump.pcap is not modified.
        if proc_cfg.network.process_map:
            results = filter_network_to_task_process_tree(
                results,
                self.results.get("behavior", {}) if isinstance(self.results, dict) else {},
                str(self.task.get("route") or ""),
            )

        return results
'''
    if run_anchor not in s:
        raise RuntimeError("network processing run anchor not found")
    s = s.replace(run_anchor, run_replacement, 1)
    write(path, s)


def patch_network_template(path: Path) -> None:
    s = read(path)
    if s.count(MARKER_NETWORK_UI):
        if s.count(MARKER_NETWORK_UI) != 1:
            raise RuntimeError("Network Analysis UI marker is ambiguous")
        return

    anchor = '    <ul class="nav nav-pills nav-fill bg-dark rounded shadow-sm p-1 mb-3" id="networkTabs" role="tablist">\n'
    notice = '''    {% if network.autodeploy_task_network.enabled %}
    <div class="alert alert-warning small" role="status">
        <strong>AutoDeploy Network Analysis:</strong>
        {% if network.autodeploy_task_network.mode == "strict-no-network" %}
            No-network mode intentionally hides analyst-facing network events. The raw PCAP remains preserved.
        {% elif network.autodeploy_task_network.attribution_status == "no-process-tree" %}
            CAPE parsed {{ network.autodeploy_task_network.source_event_count }} network event{{ network.autodeploy_task_network.source_event_count|pluralize }},
            but no task ProcessTree was available. The events are hidden to prevent background traffic from being attributed to the submitted task.
            The raw PCAP remains preserved.
        {% elif network.autodeploy_task_network.attribution_status == "no-network-events-attributed" %}
            CAPE parsed {{ network.autodeploy_task_network.source_event_count }} network event{{ network.autodeploy_task_network.source_event_count|pluralize }},
            but none could be safely attributed to the task ProcessTree. They are hidden to prevent background traffic leakage.
            The raw PCAP remains preserved.
        {% elif network.autodeploy_task_network.source_event_count == 0 %}
            No network events were produced by CAPE's network parser for this analysis.
        {% endif %}
        <span class="d-block mt-1 text-muted">
            Process-attributed events shown: {{ network.autodeploy_task_network.kept_events }}.
            Suppressed from analyst view: {{ network.autodeploy_task_network.suppressed_events }}.
        </span>
        <!-- CAPE_INETSIM_AUTODEPLOY_NETWORK_UI_V1 -->
    </div>
    {% endif %}
'''
    if anchor not in s:
        raise RuntimeError("Network Analysis tab anchor not found")
    s = s.replace(anchor, notice + anchor, 1)
    write(path, s)

def patch_submission(path: Path) -> None:
    s = read(path)
    if s.count(MARKER_SUBMISSION):
        if s.count(MARKER_SUBMISSION) != 1:
            raise RuntimeError("RC66 submission route marker is ambiguous")
        return

    inetsim_anchor = '''                                        {% if inetsim %}
                                        <option value="inetsim">inetsim/fakenet-ng</option>
                                        {% endif %}
'''
    inetsim_replacement = '''                                        {% if inetsim %}
                                        <!-- CAPE_INETSIM_AUTODEPLOY_ROUTE_UI_V2 -->
                                        <option value="inetsim">Fake Internet — dedicated Ubuntu INetSim appliance</option>
                                        {% endif %}
'''
    if inetsim_anchor not in s:
        raise RuntimeError("submission INetSim option anchor not found")
    s = s.replace(inetsim_anchor, inetsim_replacement, 1)

    none_anchor = '''                                        <option value="none" {% if route == "none" %} selected{% endif %}>Drop all VM
                                            traffic</option>
'''
    none_replacement = '''                                        <option value="drop" {% if route == "none" or route == "drop" %} selected{% endif %}>No network — strictly blocked (analysis egress)</option>
'''
    if none_anchor not in s:
        raise RuntimeError("submission no-network option anchor not found")
    s = s.replace(none_anchor, none_replacement, 1)

    notice_anchor = '''                                </div>
                                <div class="mb-3">
                                    <label for="form_timeout" class="text-white-50">Timeout (seconds)</label>
'''
    notice_replacement = '''                                </div>
                                <!-- RC66 route semantics notice -->
                                <div class="small text-white-50 mb-3">
                                    Internet = real external Internet via the discovered dirty line.
                                    Fake Internet = isolated Ubuntu INetSim appliance.
                                    No network = analysis-plane egress strictly blocked; CAPE control traffic remains available.
                                </div>
                                <div class="mb-3">
                                    <label for="form_timeout" class="text-white-50">Timeout (seconds)</label>
'''
    if notice_anchor not in s:
        raise RuntimeError("submission route notice anchor not found")
    s = s.replace(notice_anchor, notice_replacement, 1)
    write(path, s)


def patch_startup(path: Path) -> None:
    s = read(path)
    if s.count(MARKER_STARTUP):
        if s.count(MARKER_STARTUP) != 1:
            raise RuntimeError("INetSim startup NAT marker is ambiguous")
        return

    old = '''        # Disable & enable NAT on this network interface. Disable it just
        # in case we still had the same rule from a previous run.
        rooter("disable_nat", routing.inetsim.interface)
        rooter("enable_nat", routing.inetsim.interface)
'''
    new = '''        # CAPE_INETSIM_AUTODEPLOY_INETSIM_NO_NAT_V1
        # AutoDeploy's INetSim bridge is an isolated fake-Internet appliance.
        # route=inetsim uses DNAT + forwarding only; it must never be masqueraded.
        # Disable any stale CAPE-rooter MASQUERADE left by a prior CAPE startup.
        rooter("disable_nat", routing.inetsim.interface)
'''
    if old not in s:
        raise RuntimeError("INetSim startup NAT anchor not found")
    s = s.replace(old, new, 1)
    write(path, s)


def patch_all(root: Path, helper: Path) -> None:
    patch_rooter(root / "utils/rooter.py")
    patch_analysis_manager(root / "lib/cuckoo/core/analysis_manager.py")
    patch_network(root / "modules/processing/network.py")
    patch_network_template(root / "web/templates/analysis/network/index.html")
    patch_submission(root / "web/templates/submission/index.html")
    patch_startup(root / "lib/cuckoo/core/startup.py")

    target = root / "modules/processing/autodeploy_task_network.py"
    target.parent.mkdir(parents=True, exist_ok=True)
    expected = read(helper)
    if target.exists():
        current = read(target)
        if current != expected:
            # The helper is transaction-owned after RC66. Permit only a known
            # AutoDeploy helper migration; never overwrite arbitrary operator
            # modifications.
            legacy_signature = '"suppressed_events": before,\n        "kept_events": 0,\n'
            if legacy_signature not in current or "source_event_count" not in expected:
                raise RuntimeError("existing task-network helper differs from approved helper; refusing overwrite")
            shutil.copyfile(helper, target)
    else:
        shutil.copyfile(helper, target)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--helper-source", required=True)
    args = ap.parse_args()

    root = Path(args.root)
    helper = Path(args.helper_source)

    for rel in (
        "utils/rooter.py",
        "lib/cuckoo/core/analysis_manager.py",
        "modules/processing/network.py",
        "web/templates/analysis/network/index.html",
        "web/templates/submission/index.html",
        "lib/cuckoo/core/startup.py",
    ):
        if not (root / rel).is_file():
            raise SystemExit(f"missing required CAPE file: {root / rel}")

    patch_all(root, helper)

    checks = {
        "utils/rooter.py": MARKER_ROOTER,
        "lib/cuckoo/core/analysis_manager.py": MARKER_ANALYSIS,
        "modules/processing/network.py": MARKER_NETWORK,
        "web/templates/analysis/network/index.html": MARKER_NETWORK_UI,
        "web/templates/submission/index.html": MARKER_SUBMISSION,
        "lib/cuckoo/core/startup.py": MARKER_STARTUP,
    }
    for rel, marker in checks.items():
        if read(root / rel).count(marker) != 1:
            raise SystemExit(f"RC66 patch marker count is not exactly one: {rel}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
