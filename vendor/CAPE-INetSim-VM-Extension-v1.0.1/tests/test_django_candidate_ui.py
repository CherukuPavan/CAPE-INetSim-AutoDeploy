#!/usr/bin/env python3

# ============================================================
# CAPE Ubuntu-VM INetSim Extension
# Universal Django candidate runtime validator
# ============================================================

import sys
from pathlib import Path

from django.conf import settings
from django.template import Context, Engine
import django


# ------------------------------------------------------------
# Minimal isolated Django configuration.
# ------------------------------------------------------------

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


import inetsim_tags
import inetsim_vm_logic


print("PASS: candidate inetsim_tags.py imported")
print("PASS: candidate inetsim_vm_logic.py imported")


# ------------------------------------------------------------
# Required Django filters.
# ------------------------------------------------------------

required_filters = (
    "inetsim_server_ip",
    "inetsim_service_activity",
    "inetsim_topology",
)


for filter_name in required_filters:

    if filter_name not in inetsim_tags.register.filters:

        raise SystemExit(
            f"FAIL: Django filter missing: {filter_name}"
        )


print("PASS: new dynamic server filter registered")
print("PASS: existing INetSim filters preserved")


# ------------------------------------------------------------
# Obtain addresses FROM THE CANDIDATE ITSELF.
#
# No SSL45 address is hard-coded here.
# ------------------------------------------------------------

vm_server = str(
    inetsim_tags.INETSIM_VM_IP
).strip()

legacy_server = str(
    inetsim_tags.INETSIM_IP
).strip()


if not vm_server:
    raise SystemExit(
        "FAIL: candidate VM-INetSim address is empty"
    )


if not legacy_server:
    raise SystemExit(
        "FAIL: existing host-INetSim fallback is empty"
    )


print(
    f"PASS: configured VM-INetSim server discovered: "
    f"{vm_server}"
)

print(
    f"PASS: legacy INetSim fallback discovered: "
    f"{legacy_server}"
)


# ------------------------------------------------------------
# Parse complete visual template.
# ------------------------------------------------------------

engine = Engine(
    libraries={
        "inetsim_tags": "inetsim_tags",
    }
)


template_source = (
    ROOT
    / "_inetsim_visual.html"
).read_text()


template = engine.from_string(
    template_source
)


print("PASS: complete candidate INetSim template parsed")


# ============================================================
# TEST 1 — configured Ubuntu-VM INetSim address
# ============================================================

vm_guest = "198.51.100.10"


vm_network = {

    "dns": [
        {
            "request": "portable-runtime.test",
            "type": "A",
            "answers": [
                {
                    "data": vm_server,
                }
            ],
        }
    ],

    "domains": [
        {
            "domain": "portable-runtime.test",
            "ip": vm_server,
        }
    ],

    "hosts": [
        vm_server,
    ],

    "tcp": [
        {
            "src": vm_guest,
            "dst": vm_server,
            "sport": 50001,
            "dport": 80,
        },
        {
            "src": vm_guest,
            "dst": vm_server,
            "sport": 50002,
            "dport": 443,
        },
    ],

    "udp": [
        {
            "src": vm_guest,
            "dst": vm_server,
            "sport": 51001,
            "dport": 53,
        }
    ],

    "http": [
        {
            "dst": vm_server,
            "host": "portable-runtime.test",
            "method": "GET",
            "uri": "/candidate-runtime-test",
            "status": 200,
            "status_text": "OK",
        }
    ],
}


context = (
    inetsim_vm_logic
    .build_route_none_inetsim_context(
        vm_network,
        vm_server,
    )
)


if not context.get("enabled"):
    raise SystemExit(
        "FAIL: route=none candidate context not enabled"
    )


print("PASS: route=none candidate context enabled")


selected = inetsim_tags.inetsim_server_ip(
    vm_network
)


if selected != vm_server:
    raise SystemExit(
        "FAIL: configured VM-INetSim server "
        "was not selected"
    )


print("PASS: configured VM-INetSim server selected dynamically")


rendered = template.render(
    Context(
        {
            "network": vm_network,
            "inetsim": context,
        }
    )
)


if vm_server not in rendered:
    raise SystemExit(
        "FAIL: configured VM-INetSim address "
        "was not rendered"
    )


print("PASS: configured VM-INetSim address rendered")


if "portable-runtime.test" not in rendered:
    raise SystemExit(
        "FAIL: task domain was not rendered"
    )


print("PASS: Task Domain rendered")


if "candidate-runtime-test" not in rendered:
    raise SystemExit(
        "FAIL: task HTTP evidence was not rendered"
    )


print("PASS: HTTP evidence rendered")


# ============================================================
# TEST 2 — generic helper with a completely different subnet
# ============================================================

other_server = "203.0.113.2"

other_network = {

    "dns": [
        {
            "request": "different-subnet.test",
            "type": "A",
            "answers": [
                {
                    "data": other_server,
                }
            ],
        }
    ],

    "tcp": [
        {
            "src": "203.0.113.10",
            "dst": other_server,
            "sport": 52001,
            "dport": 443,
        }
    ],

    "udp": [],
    "http": [],
}


other_context = (
    inetsim_vm_logic
    .build_route_none_inetsim_context(
        other_network,
        other_server,
    )
)


if not other_context.get("enabled"):
    raise SystemExit(
        "FAIL: universal helper failed "
        "on alternate subnet"
    )


print("PASS: generic route=none logic works on alternate subnet")


# ============================================================
# TEST 3 — existing host-based route=inetsim compatibility
# ============================================================

legacy_network = {

    "dns": [
        {
            "request": "legacy-runtime.test",
            "type": "A",
            "answers": [
                {
                    "data": legacy_server,
                }
            ],
        }
    ],

    "domains": [
        {
            "domain": "legacy-runtime.test",
            "ip": legacy_server,
        }
    ],

    "hosts": [
        legacy_server,
    ],

    "tcp": [
        {
            "src": "198.51.100.20",
            "dst": legacy_server,
            "sport": 53001,
            "dport": 80,
        }
    ],

    "udp": [],
    "http": [],
}


selected_legacy = (
    inetsim_tags
    .inetsim_server_ip(
        legacy_network
    )
)


if selected_legacy != legacy_server:
    raise SystemExit(
        "FAIL: legacy INetSim fallback was not preserved"
    )


print("PASS: existing route=inetsim server fallback preserved")


legacy_context = {

    "enabled": False,

    "summary": {},

    "attribution_summary": {
        "task_domains": [],
        "task_relevant_requests": 0,
        "background_http": 0,
        "background_requests": 0,
    },

    "dns": [],
    "http": [],
    "http_aggregated": [],
    "https": [],
    "other": [],
    "timeline": [],
    "findings": [],
}


legacy_rendered = template.render(
    Context(
        {
            "network": legacy_network,
            "inetsim": legacy_context,
        }
    )
)


if legacy_server not in legacy_rendered:
    raise SystemExit(
        "FAIL: legacy server was not rendered"
    )


print("PASS: existing route=inetsim visual compatibility preserved")


# ------------------------------------------------------------
# The legacy address must be dynamic, not literal HTML.
# ------------------------------------------------------------

if legacy_server in template_source:
    raise SystemExit(
        "FAIL: legacy INetSim server remains "
        "hard-coded in visual HTML"
    )


print("PASS: visual HTML contains no hard-coded legacy server")


print()
print(
    "STATUS: UNIVERSAL CAPE DJANGO "
    "CANDIDATE VALIDATION PASSED"
)
