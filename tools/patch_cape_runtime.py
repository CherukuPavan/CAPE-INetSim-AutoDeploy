#!/usr/bin/env python3
"""Apply deterministic CAPE runtime integrations for CAPE-INetSim-AutoDeploy.

This tool is run only after AutoDeploy has created checksummed backups.
Every source patch is marker-gated and requires one unique known anchor.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil


MARKER_ROOTER = "CAPE_INETSIM_AUTODEPLOY_ROUTE_V3"
MARKER_NETWORK = "CAPE_INETSIM_AUTODEPLOY_TASK_NETWORK_V1"
MARKER_SUBMISSION = "CAPE_INETSIM_AUTODEPLOY_ROUTE_UI_V1"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def patch_rooter(path: Path) -> None:
    s = read(path)
    if s.count(MARKER_ROOTER):
        if s.count(MARKER_ROOTER) != 1:
            raise RuntimeError("rooter route marker is ambiguous")
        return

    old_sig = 'def drop_enable(ipaddr, resultserver_port):'
    new_sig = 'def drop_enable(ipaddr, resultserver_port, resultserver_ip=""):'
    if old_sig not in s:
        raise RuntimeError("rooter drop_enable signature not found")
    s = s.replace(old_sig, new_sig, 1)

    old = '''    run_iptables("-A", "OUTPUT", "--destination", ipaddr, "-j", "DROP")


def drop_disable(ipaddr, resultserver_port):'''
    new = '''    run_iptables("-A", "OUTPUT", "--destination", ipaddr, "-j", "DROP")

    # CAPE_INETSIM_AUTODEPLOY_ROUTE_V3
    # The native drop handler does not block forwarded guest traffic. CAPE's
    # rejected chain is evaluated before accepted segments, so this is a
    # strict analysis-plane egress deny. ResultServer traffic is excepted only
    # when it is actually forwarded through the host.
    if resultserver_ip and resultserver_port:
        run_iptables("-D", "CAPE_REJECTED_SEGMENTS", "--source", ipaddr,
                     "--destination", resultserver_ip, "-p", "tcp",
                     "--dport", resultserver_port, "-j", "ACCEPT")
        run_iptables("-D", "CAPE_REJECTED_SEGMENTS", "--source", ipaddr, "-j", "DROP")
        run_iptables("-I", "CAPE_REJECTED_SEGMENTS", "1", "--source", ipaddr,
                     "--destination", resultserver_ip, "-p", "tcp",
                     "--dport", resultserver_port, "-j", "ACCEPT")
        run_iptables("-I", "CAPE_REJECTED_SEGMENTS", "2", "--source", ipaddr, "-j", "DROP")
    else:
        run_iptables("-D", "CAPE_REJECTED_SEGMENTS", "--source", ipaddr, "-j", "DROP")
        run_iptables("-I", "CAPE_REJECTED_SEGMENTS", "1", "--source", ipaddr, "-j", "DROP")


def drop_disable(ipaddr, resultserver_port, resultserver_ip=""):'''
    if old not in s:
        raise RuntimeError("rooter drop_enable anchor not found")
    s = s.replace(old, new, 1)

    old2 = '''    # run_iptables("-D", "OUTPUT", "--destination", ipaddr, "-j", "LOG")
    run_iptables("-D", "OUTPUT", "--destination", ipaddr, "-j", "DROP")
'''
    new2 = '''    # run_iptables("-D", "OUTPUT", "--destination", ipaddr, "-j", "LOG")
    run_iptables("-D", "OUTPUT", "--destination", ipaddr, "-j", "DROP")
    # CAPE_INETSIM_AUTODEPLOY_ROUTE_V3
    while True:
        out, err = run_iptables("-D", "CAPE_REJECTED_SEGMENTS", "--source", ipaddr, "-j", "DROP")
        if err:
            break
    if resultserver_ip and resultserver_port:
        while True:
            out, err = run_iptables(
                "-D", "CAPE_REJECTED_SEGMENTS", "--source", ipaddr,
                "--destination", resultserver_ip, "-p", "tcp",
                "--dport", resultserver_port, "-j", "ACCEPT"
            )
            if err:
                break
'''
    if old2 not in s:
        raise RuntimeError("rooter drop_disable anchor not found")
    s = s.replace(old2, new2, 1)
    write(path, s)


def patch_analysis_manager(path: Path) -> None:
    s = read(path)
    if MARKER_ROOTER in s:
        return

    old = '''        if self.route == "inetsim":
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
    new = '''        # CAPE_INETSIM_AUTODEPLOY_ROUTE_V3
        # Remove stale per-source policy from a previous interrupted task
        # before installing the selected route.
        if self.route == "inetsim":
            rooter(
                "autodeploy_strict_drop_disable",
                self.machine.ip,
                str(self.machine.resultserver_port),
                str(self.cfg.resultserver.ip),
            )
            rooter(
                "autodeploy_internet_disable",
                self.machine.ip,
                str(routing.routing.internet),
            )
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
    if old not in s:
        raise RuntimeError("analysis-manager inetsim branch anchor not found")
    s = s.replace(old, new, 1)

    old_drop = '''        elif str(self.route).lower() in ("none", "drop", "false"):
            self.rooter_response = rooter("drop_enable", self.machine.ip, str(self.machine.resultserver_port))
'''
    new_drop = '''        elif str(self.route).lower() in ("none", "drop", "false"):
            rooter(
                "inetsim_disable",
                self.machine.ip,
                str(routing.inetsim.server),
                str(routing.inetsim.dnsport),
                str(self.machine.resultserver_port),
                str(routing.inetsim.ports),
            )
            rooter(
                "autodeploy_internet_disable",
                self.machine.ip,
                str(routing.routing.internet),
            )
            self.rooter_response = rooter(
                "autodeploy_strict_drop_enable",
                self.machine.ip,
                str(self.machine.resultserver_port),
                str(self.cfg.resultserver.ip),
            )
'''
    if old_drop not in s:
        raise RuntimeError("analysis-manager drop branch anchor not found")
    s = s.replace(old_drop, new_drop, 1)

    old_tail = '''        self._rooter_response_check()

        # nexthop bind (self.interface is None for a gateway route, so the generic
'''
    new_tail = '''        # CAPE_INETSIM_AUTODEPLOY_ROUTE_V3
        # Internet uses the guest's existing default route toward the CAPE
        # host, while the host explicitly forwards/NATs this task source to
        # the discovered dirty line. This avoids inheriting VPN/INetSim policy.
        if self.route == "internet":
            if not self.interface or not rooter("nic_available", self.interface):
                self.log.error("AutoDeploy Internet route interface is unavailable; failing closed to drop")
                self.route = "drop"
                self.interface = None
                self.rt_table = None
                self.rooter_response = rooter(
                    "autodeploy_strict_drop_enable",
                    self.machine.ip,
                    str(self.machine.resultserver_port),
                    str(self.cfg.resultserver.ip),
                )
            else:
                rooter(
                    "inetsim_disable",
                    self.machine.ip,
                    str(routing.inetsim.server),
                    str(routing.inetsim.dnsport),
                    str(self.machine.resultserver_port),
                    str(routing.inetsim.ports),
                )
                rooter(
                    "autodeploy_strict_drop_disable",
                    self.machine.ip,
                    str(self.machine.resultserver_port),
                    str(self.cfg.resultserver.ip),
                )
                self.rooter_response = rooter(
                    "autodeploy_internet_enable",
                    self.machine.ip,
                    self.machine.interface,
                    self.interface,
                )
                self._rooter_response_check()
                self.interface = None
                self.rt_table = None

        self._rooter_response_check()

        # nexthop bind (self.interface is None for a gateway route, so the generic
'''
    if old_tail not in s:
        raise RuntimeError("analysis-manager route-tail anchor not found")
    s = s.replace(old_tail, new_tail, 1)

    old_unroute = '''    def unroute_network(self):
        routing = Config("routing")
        if self.interface:
'''
    new_unroute = '''    def unroute_network(self):
        routing = Config("routing")
        # CAPE_INETSIM_AUTODEPLOY_ROUTE_V3
        if self.route == "internet" and not self.interface:
            self.rooter_response = rooter(
                "autodeploy_internet_disable",
                self.machine.ip,
                str(routing.routing.internet),
            )
            self._rooter_response_check()
            self._unroute_nexthop()
            return
        if self.interface:
'''
    if old_unroute not in s:
        raise RuntimeError("analysis-manager unroute anchor not found")
    s=s.replace(old_unroute,new_unroute,1)

    old_unroute_drop='''        elif str(self.route).lower() in ("none", "drop", "false"):
            self.rooter_response = rooter("drop_disable", self.machine.ip, str(self.machine.resultserver_port))
'''
    new_unroute_drop='''        elif str(self.route).lower() in ("none", "drop", "false"):
            self.rooter_response = rooter("drop_disable", self.machine.ip, str(self.machine.resultserver_port))
            rooter(
                "autodeploy_strict_drop_disable",
                self.machine.ip,
                str(self.machine.resultserver_port),
                str(self.cfg.resultserver.ip),
            )
'''
    if old_unroute_drop not in s:
        raise RuntimeError("analysis-manager drop teardown anchor not found")
    s=s.replace(old_unroute_drop,new_unroute_drop,1)
    write(path,s)


def patch_network(path: Path) -> None:
    s=read(path)
    if s.count(MARKER_NETWORK):
        if s.count(MARKER_NETWORK)!=1:
            raise RuntimeError("network filter marker is ambiguous")
        return

    old_import='from lib.cuckoo.common.path_utils import path_delete, path_exists, path_mkdir, path_read_file, path_write_file\n'
    new_import=old_import+'# CAPE_INETSIM_AUTODEPLOY_TASK_NETWORK_V1\nfrom modules.processing.autodeploy_task_network import filter_network_to_task_process_tree\n'
    if old_import not in s:
        raise RuntimeError("network import anchor not found")
    s=s.replace(old_import,new_import,1)

    old_call='''        if proc_cfg.network.process_map:
            self._process_map(results)
            if proc_cfg.network.merge_behavior_map:
                self._merge_behavior_network(results)

        return results
'''
    new_call='''        if proc_cfg.network.process_map:
            self._process_map(results)
            if proc_cfg.network.merge_behavior_map:
                self._merge_behavior_network(results)

        # CAPE_INETSIM_AUTODEPLOY_TASK_NETWORK_V1
        if proc_cfg.network.process_map:
            results = filter_network_to_task_process_tree(
                results,
                self.results.get("behavior", {}) if isinstance(self.results, dict) else {},
            )

        return results
'''
    if old_call not in s:
        raise RuntimeError("network run anchor not found")
    s=s.replace(old_call,new_call,1)
    write(path,s)


def patch_submission(path: Path) -> None:
    s=read(path)
    if s.count(MARKER_SUBMISSION):
        if s.count(MARKER_SUBMISSION)!=1:
            raise RuntimeError("submission UI marker is ambiguous")
        return

    old='''                                        {% if inetsim %}
                                        <option value="inetsim">inetsim/fakenet-ng</option>
                                        {% endif %}
'''
    new='''                                        {% if inetsim %}
                                        <!-- CAPE_INETSIM_AUTODEPLOY_ROUTE_UI_V1 -->
                                        <option value="inetsim">Fake Internet — dedicated Ubuntu INetSim appliance</option>
                                        {% endif %}
'''
    if old not in s:
        raise RuntimeError("submission inetsim option anchor not found")
    s=s.replace(old,new,1)

    old2='''                                        <option value="none" {% if route == "none" %} selected{% endif %}>Drop all VM
                                            traffic</option>
'''
    new2='''                                        <option value="drop" {% if route == "none" or route == "drop" %} selected{% endif %}>No network — strictly blocked (analysis egress)</option>
'''
    if old2 not in s:
        raise RuntimeError("submission none option anchor not found")
    s=s.replace(old2,new2,1)

    anchor='''                                </div>
                                <div class="mb-3">
                                    <label for="form_timeout" class="text-white-50">Timeout (seconds)</label>
'''
    notice='''                                </div>
                                <!-- CAPE_INETSIM_AUTODEPLOY_ROUTE_UI_V1 -->
                                <div class="small text-white-50 mb-3">
                                    Internet = real external Internet via the configured dirty line.
                                    Fake Internet = isolated Ubuntu INetSim appliance.
                                    No network = analysis-plane egress strictly blocked; CAPE control traffic remains available.
                                </div>
                                <div class="mb-3">
                                    <label for="form_timeout" class="text-white-50">Timeout (seconds)</label>
'''
    if anchor not in s:
        raise RuntimeError("submission route notice anchor not found")
    s=s.replace(anchor,notice,1)
    write(path,s)


def patch_all(root: Path, helper: Path) -> None:
    patch_rooter(root/"utils/rooter.py")
    patch_analysis_manager(root/"lib/cuckoo/core/analysis_manager.py")
    patch_network(root/"modules/processing/network.py")
    patch_submission(root/"web/templates/submission/index.html")
    target=root/"modules/processing/autodeploy_task_network.py"
    target.parent.mkdir(parents=True,exist_ok=True)
    expected=read(helper)
    if target.exists():
        if read(target) != expected:
            raise RuntimeError("existing task-network helper differs; refusing overwrite")
    else:
        shutil.copyfile(helper,target)


def main() -> int:
    ap=argparse.ArgumentParser()
    ap.add_argument("--root",required=True)
    ap.add_argument("--helper-source",required=True)
    a=ap.parse_args()
    root=Path(a.root)
    for rel in (
        "utils/rooter.py",
        "lib/cuckoo/core/analysis_manager.py",
        "modules/processing/network.py",
        "web/templates/submission/index.html",
    ):
        if not (root/rel).is_file():
            raise SystemExit(f"missing required CAPE file: {root/rel}")
    patch_all(root,Path(a.helper_source))
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
