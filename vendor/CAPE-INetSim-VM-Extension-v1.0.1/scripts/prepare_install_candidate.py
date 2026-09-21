#!/usr/bin/env python3

from ipaddress import IPv4Address
from pathlib import Path
import py_compile
import re
import shutil


SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent

CONFIG = ROOT / "src" / "inetsim-vm.conf"
HELPER = ROOT / "src" / "inetsim_vm_logic.py"

BUILD_ROOT = ROOT / "build"
CANDIDATE = BUILD_ROOT / "install-candidate"


def load_config(path):
    values = {}

    for raw in path.read_text().splitlines():

        line = raw.strip()

        if (
            not line
            or line.startswith("#")
            or "=" not in line
        ):
            continue

        key, value = line.split("=", 1)

        values[key.strip()] = value.strip()

    return values


def replace_once(text, old, new, description):

    count = text.count(old)

    if count != 1:
        raise SystemExit(
            f"ERROR: expected exactly one {description}; "
            f"found {count}"
        )

    return text.replace(old, new, 1)


config = load_config(CONFIG)


cape_root_value = config.get(
    "CAPE_ROOT",
    "",
)

if not cape_root_value:
    raise SystemExit(
        "ERROR: CAPE_ROOT is not configured"
    )


CAPE_ROOT = Path(cape_root_value)


server_ip = config.get(
    "INETSIM_SERVER_IP",
    "",
)


try:
    server_ip = str(
        IPv4Address(server_ip)
    )

except Exception as exc:
    raise SystemExit(
        "ERROR: INETSIM_SERVER_IP is invalid"
    ) from exc


if not CAPE_ROOT.is_dir():
    raise SystemExit(
        f"ERROR: CAPE_ROOT does not exist: "
        f"{CAPE_ROOT}"
    )


SOURCE_FILES = (
    "web/analysis/views.py",
    "web/analysis/templatetags/inetsim_tags.py",
    "web/templates/analysis/network/index.html",
    "web/templates/analysis/network/_inetsim_visual.html",
)


print()
print(
    "Building production installation candidate "
    "from CURRENT CAPE source"
)

print()
print(f"CAPE source: {CAPE_ROOT}")
print(f"Candidate:   {CANDIDATE}")
print(f"VM INetSim:  {server_ip}")
print()


# ============================================================
# Recreate candidate directory.
# ============================================================

if CANDIDATE.exists():
    shutil.rmtree(CANDIDATE)


CANDIDATE.mkdir(
    parents=True,
    exist_ok=True,
)


# ============================================================
# Copy current CAPE files.
# ============================================================

for relative in SOURCE_FILES:

    source = CAPE_ROOT / relative

    if not source.is_file():
        raise SystemExit(
            f"ERROR: required CAPE file missing: "
            f"{relative}"
        )

    destination = CANDIDATE / relative

    destination.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    shutil.copy2(
        source,
        destination,
    )

    print(
        f"[PASS] Current CAPE source copied: "
        f"{relative}"
    )


# ============================================================
# Add generic helper.
# ============================================================

if not HELPER.is_file():
    raise SystemExit(
        f"ERROR: helper source missing: {HELPER}"
    )


helper_destination = (
    CANDIDATE
    / "web"
    / "analysis"
    / "inetsim_vm_logic.py"
)


helper_destination.parent.mkdir(
    parents=True,
    exist_ok=True,
)


shutil.copy2(
    HELPER,
    helper_destination,
)


print(
    "[PASS] Generic INetSim task-network helper added"
)


# ============================================================
# Patch views.py.
# ============================================================

views = (
    CANDIDATE
    / "web"
    / "analysis"
    / "views.py"
)


text = views.read_text()


# Refuse partially installed source.

for marker in (
    "CAPE_INETSIM_VM_ROUTE_NONE_V1",
    "CAPE_INETSIM_VM_ROUTE_NONE_CONTEXT_V1",
):

    if marker in text:
        raise SystemExit(
            f"ERROR: extension marker already exists "
            f"in views.py: {marker}"
        )


old = '''            analysis_route = str(data.get("info", {}).get("route", "") or "").strip().lower()
            ajax_response["analysis_route"] = analysis_route
            ajax_response["is_inetsim_route"] = analysis_route == "inetsim"
'''


new = f'''            analysis_route = str(data.get("info", {{}}).get("route", "") or "").strip().lower()
            ajax_response["analysis_route"] = analysis_route

            # CAPE_INETSIM_VM_ROUTE_NONE_V1
            #
            # Existing route=inetsim behavior remains supported.
            #
            # For route=none, display the INetSim Visual only when
            # CAPE's task-local captured traffic actually reaches
            # the configured Ubuntu-VM INetSim endpoint.
            from .inetsim_vm_logic import network_uses_inetsim

            network_data = ajax_response.get("network", {{}}) or {{}}

            vm_inetsim_server_ip = "{server_ip}"

            uses_vm_inetsim = (
                analysis_route == "none"
                and network_uses_inetsim(
                    network_data,
                    vm_inetsim_server_ip,
                )
            )

            ajax_response["is_inetsim_route"] = (
                analysis_route == "inetsim"
                or uses_vm_inetsim
            )
'''


text = replace_once(
    text,
    old,
    new,
    "views.py INetSim route-selection anchor",
)


old = '''            ajax_response["inetsim"] = {}
'''


new = '''            ajax_response["inetsim"] = {}

            # CAPE_INETSIM_VM_ROUTE_NONE_CONTEXT_V1
            #
            # route=none does not depend on the old host-side
            # INetSim service.log. Build the Analyst context using
            # this CAPE task's captured network evidence.
            if uses_vm_inetsim:

                from .inetsim_vm_logic import (
                    build_route_none_inetsim_context,
                )

                ajax_response["inetsim"] = (
                    build_route_none_inetsim_context(
                        network_data,
                        vm_inetsim_server_ip,
                    )
                )
'''


text = replace_once(
    text,
    old,
    new,
    "views.py INetSim context anchor",
)


old = '''            if _path_safe(inetsim_events_path):
'''


new = '''            if (
                analysis_route == "inetsim"
                and _path_safe(inetsim_events_path)
            ):
'''


text = replace_once(
    text,
    old,
    new,
    "views.py legacy events-file anchor",
)


views.write_text(text)


print(
    "[PASS] Current views.py patched in candidate"
)


# ============================================================
# Patch template tags.
# ============================================================

tags = (
    CANDIDATE
    / "web"
    / "analysis"
    / "templatetags"
    / "inetsim_tags.py"
)


text = tags.read_text()


if "CAPE_INETSIM_VM_DYNAMIC_SERVER_V1" in text:

    raise SystemExit(
        "ERROR: dynamic-server extension marker "
        "already exists in inetsim_tags.py"
    )


legacy_match = re.search(
    r'^INETSIM_IP\s*=\s*["\']([^"\']+)["\']\s*$',
    text,
    re.MULTILINE,
)


if not legacy_match:

    raise SystemExit(
        "ERROR: unable to locate existing INETSIM_IP "
        "inside inetsim_tags.py"
    )


legacy_ip = legacy_match.group(1)


try:
    legacy_ip = str(
        IPv4Address(legacy_ip)
    )

except Exception as exc:
    raise SystemExit(
        "ERROR: existing INETSIM_IP is not "
        "a valid IPv4 address"
    ) from exc


original_line = legacy_match.group(0)


replacement = f'''{original_line}

# CAPE_INETSIM_VM_DYNAMIC_SERVER_V1
#
# VM address generated from the extension configuration.
# The existing host-INetSim address above remains the fallback.
INETSIM_VM_IP = "{server_ip}"


def _task_inetsim_ip(network):
    """
    Select the INetSim endpoint actually used by this task.
    """

    if not isinstance(network, dict):
        return INETSIM_IP

    for protocol in ("tcp", "udp"):

        for connection in network.get(protocol) or []:

            if not isinstance(connection, dict):
                continue

            if (
                str(connection.get("dst", "")).strip()
                == INETSIM_VM_IP
            ):
                return INETSIM_VM_IP

    for dns in network.get("dns") or []:

        if not isinstance(dns, dict):
            continue

        for answer in dns.get("answers") or []:

            if (
                isinstance(answer, dict)
                and str(answer.get("data", "")).strip()
                == INETSIM_VM_IP
            ):
                return INETSIM_VM_IP

    return INETSIM_IP


@register.filter(name="inetsim_server_ip")
def inetsim_server_ip(network):
    """Return the INetSim server used by this task."""

    return _task_inetsim_ip(network)
'''


text = replace_once(
    text,
    original_line,
    replacement,
    "inetsim_tags.py INETSIM_IP anchor",
)


text = text.replace(
    'str(conn.get("dst", "")) != INETSIM_IP',
    'str(conn.get("dst", "")) != _task_inetsim_ip(network)',
)


text = text.replace(
    'str(answer.get("data", "")) == INETSIM_IP',
    'str(answer.get("data", "")) == _task_inetsim_ip(network)',
)


tags.write_text(text)


print(
    "[PASS] Current inetsim_tags.py patched in candidate"
)

print(
    f"[INFO] Existing host-INetSim fallback detected: "
    f"{legacy_ip}"
)


# ============================================================
# Patch the visual dynamically.
# ============================================================

visual = (
    CANDIDATE
    / "web"
    / "templates"
    / "analysis"
    / "network"
    / "_inetsim_visual.html"
)


text = visual.read_text()


text = text.replace(
    f'{{% if answer.data == "{legacy_ip}" %}}',
    '{% if answer.data == network|inetsim_server_ip %}',
)


text = text.replace(
    f'{{% if conn.dst == "{legacy_ip}" %}}',
    '{% if conn.dst == network|inetsim_server_ip %}',
)


text = text.replace(
    legacy_ip,
    "{{ network|inetsim_server_ip }}",
)


visual.write_text(text)


print(
    "[PASS] Current INetSim visual patched dynamically"
)


# ============================================================
# Verify existing network tab structure.
# ============================================================

network_template = (
    CANDIDATE
    / "web"
    / "templates"
    / "analysis"
    / "network"
    / "index.html"
)


network_text = network_template.read_text()


if network_text.count("is_inetsim_route") < 2:

    raise SystemExit(
        "ERROR: existing INetSim Visual tab conditions "
        "were not found"
    )


print(
    "[PASS] Existing INetSim Visual tab structure preserved"
)


# ============================================================
# Candidate validation.
# ============================================================

views_text = views.read_text()
tags_text = tags.read_text()
visual_text = visual.read_text()


for marker, source_name in (
    (
        "CAPE_INETSIM_VM_ROUTE_NONE_V1",
        "views.py",
    ),
    (
        "CAPE_INETSIM_VM_ROUTE_NONE_CONTEXT_V1",
        "views.py",
    ),
    (
        "CAPE_INETSIM_VM_DYNAMIC_SERVER_V1",
        "inetsim_tags.py",
    ),
):

    combined = (
        views_text
        if source_name == "views.py"
        else tags_text
    )

    if combined.count(marker) != 1:

        raise SystemExit(
            f"ERROR: marker validation failed: "
            f"{marker}"
        )


if legacy_ip in visual_text:

    raise SystemExit(
        "ERROR: old server address remains "
        "hard-coded in candidate visual"
    )


if "{{ network|inetsim_server_ip }}" not in visual_text:

    raise SystemExit(
        "ERROR: dynamic server filter is missing "
        "from candidate visual"
    )


# ============================================================
# Python syntax validation.
# ============================================================

for python_file in (
    helper_destination,
    views,
    tags,
):

    py_compile.compile(
        str(python_file),
        doraise=True,
    )


print(
    "[PASS] Candidate Python files compile"
)


# ============================================================
# Build information.
# ============================================================

info = CANDIDATE / "INSTALL-CANDIDATE-INFO.txt"


info.write_text(
    "CAPE Ubuntu-VM INetSim Extension\n"
    "Production Installation Candidate\n\n"
    f"Source CAPE root: {CAPE_ROOT}\n"
    f"Configured VM INetSim: {server_ip}\n"
    f"Detected existing host INetSim: {legacy_ip}\n\n"
    "IMPORTANT:\n"
    "This directory was generated from the CURRENT CAPE "
    "installation.\n"
    "No production files were modified while building it.\n"
)


print()
print(
    "STATUS: PRODUCTION INSTALLATION CANDIDATE READY"
)

print(
    "No production CAPE file was modified."
)
