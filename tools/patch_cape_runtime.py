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
    count = s.count(MARKER_ROOTER)
    if count:
        if count != 1:
            raise RuntimeError("RC66 rooter route marker is ambiguous")
        return

    anchor = '''def drop_enable(ipaddr, resultserver_port):
'''
    if anchor not in s:
        raise RuntimeError("rooter drop_enable anchor not found")

    helper = StringHelper if False else None
    insert = '''def autodeploy_route_policy_reset(ipaddr):
    """Remove only CAPE-rooter route-policy rules for this source."""
    try:
        out, _ = run(ServicePaths.iptables, "-S", "CAPE_REJECTED_SEGMENTS")
    except Exception:
        return

    for line in reversed(out.splitlines()):
        parts = line.split()
        if len(parts) < 3 or parts[0] != "-A" or parts[1] != "CAPE_REJECTED_SEGMENTS":
            continue
        if "--source" not in parts:
            continue
        try:
            src = parts[parts.index("--source") + 1]
        except (ValueError, IndexError):
            continue
        if src != ipaddr or "CAPE-rooter" not in line:
            continue

        delete = ["-D", "CAPE_REJECTED_SEGMENTS"] + parts[2:]
        while "-m" in delete:
            try:
                idx = delete.index("-m")
            except ValueError:
                break
            if idx + 3 < len(delete) and delete[idx + 1] == "comment" and delete[idx + 2] == "--comment" and delete[idx + 3] == "CAPE-rooter":
                del delete[idx:idx + 4]
            else:
                break
        run(ServicePaths.iptables, *delete)


def autodeploy_route_policy_set(ipaddr, allowed_interface="", resultserver_ip="", resultserver_port=""):
    """Permit one task route only, then deny every other forwarded destination."""
    autodeploy_route_policy_reset(ipaddr)

    if resultserver_ip and resultserver_port:
        run_iptables(
            "-I", "CAPE_REJECTED_SEGMENTS", "1",
            "--source", ipaddr,
            "--destination", resultserver_ip,
            "-p", "tcp",
            "--dport", resultserver_port,
            "-j", "ACCEPT",
        )

    if allowed_interface:
        position = "2" if resultserver_ip and resultserver_port else "1"
        run_iptables(
            "-I", "CAPE_REJECTED_SEGMENTS", position,
            "--source", ipaddr,
            "-o", allowed_interface,
            "-j", "ACCEPT",
        )
        drop_position = "3" if resultserver_ip and resultserver_port else "2"
    else:
        drop_position = "2" if resultserver_ip and resultserver_port else "1"

    run_iptables(
        "-I", "CAPE_REJECTED_SEGMENTS", drop_position,
        "--source", ipaddr,
        "-j", "DROP",
    )


# CAPE_INETSIM_AUTODEPLOY_ROUTE_V4
'''
    # The unused expression above is replaced below; it exists only to keep
    # this generated text entirely literal and deterministic.
    insert = insert.replace("    helper = StringHelper if False else None\n", "")
    s = s.replace(anchor, insert + anchor, 1)

    handlers_anchor = '''handlers = {
'''
    if handlers_anchor not in s:
        raise RuntimeError("rooter handlers dictionary anchor not found")
    handler_lines = '''    "autodeploy_route_policy_reset": autodeploy_route_policy_reset,
    "autodeploy_route_policy_set": autodeploy_route_policy_set,
'''
    s = s.replace(handlers_anchor, handlers_anchor + handler_lines, 1)

    write(path, s)


def patch_analysis_manager(path: Path) -> None:
    s = read(path)
    count = s.count(MARKER_ANALYSIS)
    if count:
        if count != 1:
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
        # Remove stale policy from an interrupted prior task before selecting
        # the current route. INetSim cleanup removes only CAPE's own source-
        # specific diversion rules; the route policy below then becomes the
        # single allow-list for forwarded analysis traffic.
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
    s=s.replace(route_start,route_replacement,1)

    route_policy_anchor = '''        if self.route == "inetsim":
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
    route_policy_replacement = '''        # CAPE_INETSIM_AUTODEPLOY_ROUTE_V4
        if self.route == "inetsim":
            self.rooter_response = rooter(
                "autodeploy_route_policy_set",
                self.machine.ip,
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
    if route_policy_anchor not in s:
        raise RuntimeError("analysis-manager inetsim route anchor not found")
    s=s.replace(route_policy_anchor,route_policy_replacement,1)

    drop_anchor = '''        elif str(self.route).lower() in ("none", "drop", "false"):
            self.rooter_response = rooter("drop_enable", self.machine.ip, str(self.machine.resultserver_port))
'''
    drop_replacement = '''        elif str(self.route).lower() in ("none", "drop", "false"):
            self.rooter_response = rooter("autodeploy_route_policy_set", self.machine.ip, "", str(self.cfg.resultserver.ip), str(self.machine.resultserver_port))
            self._rooter_response_check()
            self.rooter_response = rooter("drop_enable", self.machine.ip, str(self.machine.resultserver_port))
'''
    if drop_anchor not in s:
        raise RuntimeError("analysis-manager drop route anchor not found")
    s=s.replace(drop_anchor,drop_replacement,1)

    internet_anchor = '''        self._rooter_response_check()

        # nexthop bind (self.interface is None for a gateway route, so the generic
'''
    internet_replacement = '''        # CAPE_INETSIM_AUTODEPLOY_ROUTE_V4
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
    s=s.replace(internet_anchor,internet_replacement,1)

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

        # CAPE_INETSIM_AUTODEPLOY_ROUTE_V4
        rooter("autodeploy_route_policy_reset", self.machine.ip)

        if self.route == "inetsim":
'''
    if unroute_anchor not in s:
        raise RuntimeError("analysis-manager unroute route anchor not found")
    s=s.replace(unroute_anchor,unroute_replacement,1)

    write(path,s)


def patch_network(path: Path) -> None:
    s=read(path)
    count=s.count(MARKER_NETWORK)
    if count:
        if count != 1:
            raise RuntimeError("RC66 network-processing marker is ambiguous")
        return

    import_anchor='''from lib.cuckoo.common.path_utils import path_delete, path_exists, path_mkdir, path_read_file, path_write_file
'''
    import_replacement=import_anchor+'''# CAPE_INETSIM_AUTODEPLOY_TASK_NETWORK_V2
from modules.processing.autodeploy_task_network import filter_network_to_task_process_tree
'''
    if import_anchor not in s:
        raise RuntimeError("network processing import anchor not found")
    s=s.replace(import_anchor,import_replacement,1)

    run_anchor='''        if proc_cfg.network.process_map:
            self._process_map(results)
            if proc_cfg.network.merge_behavior_map:
                self._merge_behavior_network(results)

        return results
'''
    run_replacement='''        if proc_cfg.network.process_map:
            self._process_map(results)
            if proc_cfg.network.merge_behavior_map:
                self._merge_behavior_network(results)

        # CAPE_INETSIM_AUTODEPLOY_TASK_NETWORK_V2
        # Keep only task-process-tree-attributed network events in the analyst
        # view. Raw dump.pcap is preserved unchanged.
        if proc_cfg.network.process_map:
            results = filter_network_to_task_process_tree(
                results,
                self.results.get("behavior", {}) if isinstance(self.results, dict) else {},
            )

        return results
'''
    if run_anchor not in s:
        raise RuntimeError("network processing run anchor not found")
    s=s.replace(run_anchor,run_replacement,1)
    write(path,s)


def patch_submission(path: Path) -> None:
    s=read(path)
    count=s.count(MARKER_SUBMISSION)
    if count:
        if count != 1:
            raise RuntimeError("RC66 submission route marker is ambiguous")
        return

    inetsim_anchor='''                                        {% if inetsim %}
                                        <option value="inetsim">inetsim/fakenet-ng</option>
                                        {% endif %}
'''
    inetsim_replacement='''                                        {% if inetsim %}
                                        <!-- CAPE_INETSIM_AUTODEPLOY_ROUTE_UI_V2 -->
                                        <option value="inetsim">Fake Internet — dedicated Ubuntu INetSim appliance</option>
                                        {% endif %}
'''
    if inetsim_anchor not in s:
        raise RuntimeError("submission INetSim option anchor not found")
    s=s.replace(inetsim_anchor,inetsim_replacement,1)

    none_anchor='''                                        <option value="none" {% if route == "none" %} selected{% endif %}>Drop all VM
                                            traffic</option>
'''
    none_replacement='''                                        <option value="drop" {% if route == "none" or route == "drop" %} selected{% endif %}>No network — strictly blocked (analysis egress)</option>
'''
    if none_anchor not in s:
        raise RuntimeError("submission no-network option anchor not found")
    s=s.replace(none_anchor,none_replacement,1)

    notice_anchor='''                                </div>
                                <div class="mb-3">
                                    <label for="form_timeout" class="text-white-50">Timeout (seconds)</label>
'''
    notice_replacement='''                                </div>
                                <!-- CAPE_INETSIM_AUTODEPLOY_ROUTE_UI_V2 -->
                                <div class="small text-white-50 mb-3">
                                    Internet = real external Internet via the discovered host dirty line.
                                    Fake Internet = isolated Ubuntu INetSim appliance.
                                    No network = analysis-plane egress strictly blocked; CAPE control traffic remains available.
                                </div>
                                <div class="mb-3">
                                    <label for="form_timeout" class="text-white-50">Timeout (seconds)</label>
'''
    if notice_anchor not in s:
        raise RuntimeError("submission route notice anchor not found")
    s=s.replace(notice_anchor,notice_replacement,1)
    write(path,s)


def patch_all(root: Path, helper: Path) -> None:
    patch_rooter(root / "utils/rooter.py")
    patch_analysis_manager(root / "lib/cuckoo/core/analysis_manager.py")
    patch_network(root / "modules/processing/network.py")
    patch_submission(root / "web/templates/submission/index.html")

    target=root / "modules/processing/autodeploy_task_network.py"
    target.parent.mkdir(parents=True,exist_ok=True)
    expected=read(helper)
    if target.exists():
        if read(target) != expected:
            raise RuntimeError("existing task-network helper differs from approved helper; refusing overwrite")
    else:
        shutil.copyfile(helper,target)


def main() -> int:
    ap=argparse.ArgumentParser()
    ap.add_argument("--root",required=True)
    ap.add_argument("--helper-source",required=True)
    args=ap.parse_args()

    root=Path(args.root)
    helper=Path(args.helper_source)

    for rel in (
        "utils/rooter.py",
        "lib/cuckoo/core/analysis_manager.py",
        "modules/processing/network.py",
        "web/templates/submission/index.html",
    ):
        if not (root/rel).is_file():
            raise SystemExit(f"missing required CAPE file: {root/rel}")

    patch_all(root,helper)

    for rel in (
        "utils/rooter.py",
        "lib/cuckoo/core/analysis_manager.py",
        "modules/processing/network.py",
        "modules/processing/autodeploy_task_network.py",
        "web/templates/submission/index.html",
    ):
        if not (root/rel).is_file():
            raise SystemExit(f"patch output missing: {root/rel}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
