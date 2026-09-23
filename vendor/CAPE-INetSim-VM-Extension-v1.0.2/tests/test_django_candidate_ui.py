#!/usr/bin/env python3
"""Runtime gate for the additive modern-CAPE INetSim UI candidate."""

import sys
from pathlib import Path

from django.conf import settings
from django.template import Context, Engine
import django

if not settings.configured:
    settings.configure(
        DEBUG=False,
        SECRET_KEY="cape-inetsim-runtime-validator",
        USE_I18N=False,
        USE_TZ=False,
        DEFAULT_CHARSET="utf-8",
    )
django.setup()

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

import inetsim_vm_tags
import inetsim_vm_logic

required_filters = (
    "inetsim_vm_active",
    "inetsim_vm_context",
    "inetsim_vm_server_ip",
)
for name in required_filters:
    if name not in inetsim_vm_tags.register.filters:
        raise SystemExit(f"FAIL: Django filter missing: {name}")

server = str(inetsim_vm_tags.INETSIM_VM_IP).strip()
if not server:
    raise SystemExit("FAIL: configured VM INetSim address is empty")

engine = Engine(libraries={"inetsim_vm_tags": "inetsim_vm_tags"})
visual_source = (ROOT / "_inetsim_vm_visual.html").read_text(encoding="utf-8")
visual = engine.from_string(visual_source)

network = {
    "dns": [{
        "request": "modern-runtime.test",
        "type": "A",
        "answers": [{"data": server}],
    }],
    "hosts": [server],
    "tcp": [
        {"src": "198.51.100.10", "dst": server, "sport": 50001, "dport": 80},
        {"src": "198.51.100.10", "dst": server, "sport": 50002, "dport": 443},
    ],
    "udp": [
        {"src": "198.51.100.10", "dst": server, "sport": 51001, "dport": 53},
    ],
    "http": [{
        "dst": server,
        "host": "modern-runtime.test",
        "method": "GET",
        "uri": "/modern-cape",
        "status": 200,
        "status_text": "OK",
    }],
}

if not inetsim_vm_tags.inetsim_vm_active(network):
    raise SystemExit("FAIL: task-local INetSim traffic was not detected")

ctx = inetsim_vm_tags.inetsim_vm_context(network)
if not ctx.get("enabled"):
    raise SystemExit("FAIL: task-local INetSim context is not enabled")

rendered = visual.render(Context({"network": network}))
for expected in (server, "modern-runtime.test", "modern-cape", "INetSim Visual"):
    if expected not in rendered:
        raise SystemExit(f"FAIL: rendered visual missing {expected!r}")

unrelated = {
    "dns": [],
    "tcp": [{"src": "198.51.100.10", "dst": "203.0.113.55", "sport": 50000, "dport": 80}],
    "udp": [],
    "http": [],
}
if inetsim_vm_tags.inetsim_vm_active(unrelated):
    raise SystemExit("FAIL: unrelated task traffic incorrectly enabled INetSim visual")

other_server = "203.0.113.2"
other_network = {
    "dns": [{"request": "alternate.test", "type": "A", "answers": [{"data": other_server}]}],
    "tcp": [{"src": "203.0.113.10", "dst": other_server, "sport": 52001, "dport": 443}],
    "udp": [],
    "http": [],
}
if not inetsim_vm_logic.build_route_none_inetsim_context(other_network, other_server).get("enabled"):
    raise SystemExit("FAIL: helper is not subnet-independent")

print("PASS: modern CAPE template filters registered")
print("PASS: task-local INetSim evidence enables visual")
print("PASS: unrelated task traffic keeps visual hidden")
print("PASS: modern visual renders DNS/HTTP evidence")
print("PASS: helper remains subnet-independent")
print("STATUS: UNIVERSAL CAPE DJANGO CANDIDATE VALIDATION PASSED")
