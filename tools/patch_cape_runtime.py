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
MARKER_SUBMISSION = "CAPE_INETSIM_AUTODEPLOY_ROUTE_UI_V2"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")


def patch_rooter(path: Path) -> None:
    s = read(path)
    if s.count(MARKER_ROOTER):
        if s.count(MARKER_ROOTER) != 1:
            raise RuntimeError("RC66 rooter route marker is ambiguous")
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

    # The jump is a CAPE-rooter-tagged rule, so CAPE cleanup_rooter() will also
    # remove it if Rooter restarts unexpectedly between analysis tasks.
    while True:
        _, err = run_iptables("-D", "CAPE_REJECTED_SEGMENTS", "-j", chain)
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
        rule_pos = ["-I", chain, "1", "--source", ipaddr]
        if ingress_interface:
            rule_pos += ["-i", ingress_interface]
        rule_pos += [
            "--destination", resultserver_ip,
            "-p", "tcp",
            "--dport", resultserver_port,
            "-j", "ACCEPT",
        ]
        _autodeploy_checked_rule(*rule_pos)

    if allowed_interface:
        pos = "2" if resultserver_ip and resultserver_port else "1"
        rule_pos = ["-I", chain, pos, "--source", ipaddr]
        if ingress_interface:
            rule_pos += ["-i", ingress_interface]
        rule_pos += ["-o", allowed_interface, "-j", "ACCEPT"]
        _autodeploy_checked_rule(*rule_pos)
        drop_pos = "3" if resultserver_ip and resultserver_port else "2"
    else:
        drop_pos = "2" if resultserver_ip and resultserver_port else "1"

    rule_pos = ["-I", chain, drop_pos, "--source", ipaddr]
    if ingress_interface:
        rule_pos += ["-i", ingress_interface]
    rule_pos += ["-j", "DROP"]
    _autodeploy_checked_rule(*rule_pos)

    # CAPE_REJECTED_SEGMENTS is traversed before CAPE_ACCEPTED_SEGMENTS, so the
    # per-task policy is enforced before any broad forwarding allow rule.
    _autodeploy_checked_rule(
        "-I", "CAPE_REJECTED_SEGMENTS", "1",
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


def patch_all(root: Path, helper: Path) -> None:
    patch_rooter(root / "utils/rooter.py")
    patch_analysis_manager(root / "lib/cuckoo/core/analysis_manager.py")
    patch_network(root / "modules/processing/network.py")
    patch_submission(root / "web/templates/submission/index.html")

    target = root / "modules/processing/autodeploy_task_network.py"
    target.parent.mkdir(parents=True, exist_ok=True)
    expected = read(helper)
    if target.exists():
        if read(target) != expected:
            raise RuntimeError("existing task-network helper differs from approved helper; refusing overwrite")
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
        "web/templates/submission/index.html",
    ):
        if not (root / rel).is_file():
            raise SystemExit(f"missing required CAPE file: {root / rel}")

    patch_all(root, helper)

    checks = {
        "utils/rooter.py": MARKER_ROOTER,
        "lib/cuckoo/core/analysis_manager.py": MARKER_ANALYSIS,
        "modules/processing/network.py": MARKER_NETWORK,
        "web/templates/submission/index.html": MARKER_SUBMISSION,
    }
    for rel, marker in checks.items():
        if read(root / rel).count(marker) != 1:
            raise SystemExit(f"RC66 patch marker count is not exactly one: {rel}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
