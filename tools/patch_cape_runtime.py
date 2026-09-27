#!/usr/bin/env python3
"""Apply deterministic CAPE runtime integrations for RC66.

Every patch is marker-gated and requires the expected upstream anchor.
AutoDeploy calls this only after transaction backups have been created.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil

MARKER_ROOTER = "CAPE_INETSIM_AUTODEPLOY_ROUTE_V3"
MARKER_ANALYSIS = "CAPE_INETSIM_AUTODEPLOY_ROUTE_V3"
MARKER_NETWORK = "CAPE_INETSIM_AUTODEPLOY_TASK_NETWORK_V1"
MARKER_SUBMISSION = "CAPE_INETSIM_AUTODEPLOY_ROUTE_UI_V1"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")


def patch_rooter(path: Path) -> None:
    s = read(path)
    if s.count(MARKER_ROOTER):
        if s.count(MARKER_ROOTER) != 1:
            raise RuntimeError("rooter route marker is ambiguous")
        return

    anchor = '''def drop_enable(ipaddr, resultserver_port):
    run_iptables(
        "-t", "nat", "-I", "PREROUTING", "--source", ipaddr, "-p", "tcp", "--syn", "--dport", resultserver_port, "-j", "ACCEPT"
    )
'''
    replacement = '''def autodeploy_strict_drop_enable(ipaddr):
    """Block all forwarded analysis traffic for one task source."""
    while True:
        _, err = run_iptables("-D", "CAPE_REJECTED_SEGMENTS", "--source", ipaddr, "-j", "DROP")
        if err:
            break
    run_iptables("-I", "CAPE_REJECTED_SEGMENTS", "1", "--source", ipaddr, "-j", "DROP")


def autodeploy_strict_drop_disable(ipaddr):
    """Remove only the RC66 strict forward-drop rule for one task source."""
    while True:
        _, err = run_iptables("-D", "CAPE_REJECTED_SEGMENTS", "--source", ipaddr, "-j", "DROP")
        if err:
            break


# CAPE_INETSIM_AUTODEPLOY_ROUTE_V3
''' + anchor

    if anchor not in s:
        raise RuntimeError("rooter drop_enable anchor not found")
    s = s.replace(anchor, replacement, 1)

    old_drop = '''def drop_enable(ipaddr, resultserver_port):
'''
    new_drop = '''def drop_enable(ipaddr, resultserver_port):
    # CAPE_INETSIM_AUTODEPLOY_ROUTE_V3
    autodeploy_strict_drop_enable(ipaddr)
'''
    # The function was already prefixed above, so replace the first actual
    # native definition that still lacks the guard body.
    pos = s.find("def drop_enable(ipaddr, resultserver_port):", s.find("# CAPE_INETSIM_AUTODEPLOY_ROUTE_V3") + 1)
    if pos < 0:
        raise RuntimeError("native drop_enable definition missing after insertion")
    body_anchor = "def drop_enable(ipaddr, resultserver_port):\n    run_iptables(\n"
    if body_anchor not in s[pos:]:
        raise RuntimeError("native drop_enable body anchor missing")
    s = s.replace(
        body_anchor,
        "def drop_enable(ipaddr, resultserver_port):\n    # CAPE_INETSIM_AUTODEPLOY_ROUTE_V3\n    autodeploy_strict_drop_enable(ipaddr)\n    run_iptables(\n",
        1,
    )

    drop_disable_anchor = '''def drop_disable(ipaddr, resultserver_port):
'''
    # Insert the strict teardown immediately after the native function header.
    idx = s.find(drop_disable_anchor)
    if idx < 0:
        raise RuntimeError("native drop_disable definition missing")
    body_start = idx + len(drop_disable_anchor)
    if "autodeploy_strict_drop_disable(ipaddr)" not in s[body_start:body_start+180]:
        s = s[:body_start] + "    # CAPE_INETSIM_AUTODEPLOY_ROUTE_V3\n    autodeploy_strict_drop_disable(ipaddr)\n" + s[body_start:]

    handlers_anchor = '''handlers = {
'''
    if handlers_anchor not in s:
        raise RuntimeError("rooter handlers anchor missing")
    handler_line = '''    "autodeploy_strict_drop_enable": autodeploy_strict_drop_enable,
    "autodeploy_strict_drop_disable": autodeploy_strict_drop_disable,
'''
    s = s.replace(handlers_anchor, handlers_anchor + handler_line, 1)

    write(path, s)


def patch_analysis_manager(path: Path) -> None:
    s = read(path)
    if s.count(MARKER_ANALYSIS):
        if s.count(MARKER_ANALYSIS) != 1:
            raise RuntimeError("analysis-manager route marker is ambiguous")
        return

    anchor = '''        if self.task.route:
            self.route = self.task.route

        if self.route in ("none", "None", "drop", "false"):
'''
    replacement = '''        if self.task.route:
            self.route = self.task.route

        # CAPE_INETSIM_AUTODEPLOY_ROUTE_V3
        # A previous interrupted task may have left the RC66 strict forward
        # deny behind. Remove only that source-specific rule before selecting
        # the new task route; the selected route will add it back when needed.
        rooter("autodeploy_strict_drop_disable", self.machine.ip)

        if self.route in ("none", "None", "drop", "false"):
'''
    if anchor not in s:
        raise RuntimeError("analysis-manager route-selection anchor not found")
    s = s.replace(anchor, replacement, 1)

    write(path, s)


def patch_network(path: Path) -> None:
    s = read(path)
    if s.count(MARKER_NETWORK):
        if s.count(MARKER_NETWORK) != 1:
            raise RuntimeError("network processing marker is ambiguous")
        return

    import_anchor = '''from lib.cuckoo.common.path_utils import path_delete, path_exists, path_mkdir, path_read_file, path_write_file
'''
    import_replacement = import_anchor + '''# CAPE_INETSIM_AUTODEPLOY_TASK_NETWORK_V1
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

        # CAPE_INETSIM_AUTODEPLOY_TASK_NETWORK_V1
        # Show only network events attributed to the primary analysis process
        # or one of its descendants. The raw dump.pcap remains untouched.
        if proc_cfg.network.process_map:
            results = filter_network_to_task_process_tree(
                results,
                self.results.get("behavior", {}) if isinstance(self.results, dict) else {},
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
            raise RuntimeError("submission UI marker is ambiguous")
        return

    inetsim_anchor = '''                                        {% if inetsim %}
                                        <option value="inetsim">inetsim/fakenet-ng</option>
                                        {% endif %}
'''
    inetsim_replacement = '''                                        {% if inetsim %}
                                        <!-- CAPE_INETSIM_AUTODEPLOY_ROUTE_UI_V1 -->
                                        <option value="inetsim">Fake Internet — dedicated Ubuntu INetSim appliance</option>
                                        {% endif %}
'''
    if inetsim_anchor not in s:
        raise RuntimeError("submission INetSim option anchor not found")
    s=s.replace(inetsim_anchor,inetsim_replacement,1)

    none_anchor = '''                                        <option value="none" {% if route == "none" %} selected{% endif %}>Drop all VM
                                            traffic</option>
'''
    none_replacement = '''                                        <option value="drop" {% if route == "none" or route == "drop" %} selected{% endif %}>No network — strictly blocked (analysis egress)</option>
'''
    if none_anchor not in s:
        raise RuntimeError("submission no-network option anchor not found")
    s=s.replace(none_anchor,none_replacement,1)

    notice_anchor = '''                                </div>
                                <div class="mb-3">
                                    <label for="form_timeout" class="text-white-50">Timeout (seconds)</label>
'''
    notice_replacement = '''                                </div>
                                <!-- CAPE_INETSIM_AUTODEPLOY_ROUTE_UI_V1 -->
                                <div class="small text-white-50 mb-3">
                                    Internet = real external Internet via CAPE's configured dirty line.
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

    for rel in (
        "utils/rooter.py",
        "lib/cuckoo/core/analysis_manager.py",
        "modules/processing/network.py",
        "modules/processing/autodeploy_task_network.py",
        "web/templates/submission/index.html",
    ):
        if not (root / rel).is_file():
            raise SystemExit(f"patch output missing: {root / rel}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
