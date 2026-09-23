#!/usr/bin/env python3
"""Build an INetSim UI candidate from the CURRENT CAPE network template.

The extension is deliberately additive for modern CAPE:
- no assumptions about a pre-existing INetSim processing module/UI,
- no patch to analysis/views.py,
- one new helper, one new template-tag module, one new visual partial,
- two guarded insertions into analysis/network/index.html.

The candidate is generated from the target host's exact CAPE source, so source
layout drift is detected before any production file is changed.
"""

from ipaddress import IPv4Address
from pathlib import Path
import py_compile
import shutil

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent
CONFIG = ROOT / "src" / "inetsim-vm.conf"
HELPER = ROOT / "src" / "inetsim_vm_logic.py"
BUILD_ROOT = ROOT / "build"
CANDIDATE = BUILD_ROOT / "install-candidate"

MARKER = "CAPE_INETSIM_VM_ROUTE_NONE_V1"
MODERN_MARKER = "CAPE_INETSIM_VM_MODERN_NETWORK_V1"
TAG_MARKER = "CAPE_INETSIM_VM_DYNAMIC_SERVER_V2"


def load_config(path):
    values = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def fail(message):
    raise SystemExit("ERROR: " + message)


config = load_config(CONFIG)
cape_root_value = config.get("CAPE_ROOT", "")
if not cape_root_value:
    fail("CAPE_ROOT is not configured")
CAPE_ROOT = Path(cape_root_value)
if not CAPE_ROOT.is_dir():
    fail(f"CAPE_ROOT does not exist: {CAPE_ROOT}")

try:
    server_ip = str(IPv4Address(config.get("INETSIM_SERVER_IP", "")))
except Exception as exc:
    raise SystemExit("ERROR: INETSIM_SERVER_IP is invalid") from exc

network_source = CAPE_ROOT / "web/templates/analysis/network/index.html"
analysis_tags = CAPE_ROOT / "web/analysis/templatetags/__init__.py"
if not network_source.is_file():
    fail("modern CAPE network template is missing: web/templates/analysis/network/index.html")
if not analysis_tags.is_file():
    fail("CAPE analysis templatetags package is missing")
if not HELPER.is_file():
    fail("INetSim task-network helper source is missing")

source_text = network_source.read_text(encoding="utf-8")
if MARKER in source_text or MODERN_MARKER in source_text:
    fail("INetSim VM extension marker already exists in network/index.html")

if CANDIDATE.exists():
    shutil.rmtree(CANDIDATE)
CANDIDATE.mkdir(parents=True)

network_target = CANDIDATE / "web/templates/analysis/network/index.html"
network_target.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(network_source, network_target)

helper_target = CANDIDATE / "web/analysis/inetsim_vm_logic.py"
helper_target.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(HELPER, helper_target)

tags_target = CANDIDATE / "web/analysis/templatetags/inetsim_vm_tags.py"
tags_target.parent.mkdir(parents=True, exist_ok=True)
tags_target.write_text(
    f'''# {TAG_MARKER}
from django import template

try:
    from analysis.inetsim_vm_logic import (
        build_route_none_inetsim_context,
        network_uses_inetsim,
    )
except ImportError:
    # Isolated runtime-gate import path.
    from inetsim_vm_logic import (
        build_route_none_inetsim_context,
        network_uses_inetsim,
    )

register = template.Library()
INETSIM_VM_IP = "{server_ip}"


@register.filter(name="inetsim_vm_active")
def inetsim_vm_active(network):
    try:
        return bool(network_uses_inetsim(network or {{}}, INETSIM_VM_IP))
    except Exception:
        return False


@register.filter(name="inetsim_vm_context")
def inetsim_vm_context(network):
    try:
        return build_route_none_inetsim_context(network or {{}}, INETSIM_VM_IP)
    except Exception:
        return {{
            "enabled": False,
            "server": INETSIM_VM_IP,
            "summary": {{"dns": 0, "http": 0, "https": 0, "other": 0, "total": 0}},
            "dns": [],
            "http": [],
            "https": [],
            "findings": [],
            "attribution_summary": {{"task_domains": []}},
        }}


@register.filter(name="inetsim_vm_server_ip")
def inetsim_vm_server_ip(_network):
    return INETSIM_VM_IP
''',
    encoding="utf-8",
)

visual_target = CANDIDATE / "web/templates/analysis/network/_inetsim_vm_visual.html"
visual_target.parent.mkdir(parents=True, exist_ok=True)
visual_target.write_text(
    '''{% load inetsim_vm_tags %}
{% with inetsim=network|inetsim_vm_context %}
<div class="card bg-dark border-secondary mb-3">
  <div class="card-header">
    <i class="fas fa-flask me-2"></i>INetSim Visual
    <span class="text-muted ms-2">task-local captured evidence</span>
  </div>
  <div class="card-body">
    <p class="mb-2"><strong>INetSim server:</strong> {{ network|inetsim_vm_server_ip }}</p>
    <div class="row mb-3">
      <div class="col">DNS: <strong>{{ inetsim.summary.dns|default:0 }}</strong></div>
      <div class="col">HTTP: <strong>{{ inetsim.summary.http|default:0 }}</strong></div>
      <div class="col">HTTPS: <strong>{{ inetsim.summary.https|default:0 }}</strong></div>
      <div class="col">Other: <strong>{{ inetsim.summary.other|default:0 }}</strong></div>
    </div>

    {% if inetsim.attribution_summary.task_domains %}
    <h6>Domains resolved to INetSim</h6>
    <ul>
      {% for domain in inetsim.attribution_summary.task_domains %}
      <li><code>{{ domain }}</code></li>
      {% endfor %}
    </ul>
    {% endif %}

    {% if inetsim.http %}
    <h6>HTTP activity</h6>
    <div class="table-responsive">
      <table class="table table-sm table-dark table-striped">
        <thead><tr><th>Host</th><th>Method</th><th>Path</th><th>Status</th><th>Count</th></tr></thead>
        <tbody>
        {% for row in inetsim.http %}
          <tr>
            <td>{{ row.host|default:"-" }}</td>
            <td>{{ row.method|default:"-" }}</td>
            <td><code>{{ row.path|default:"/" }}</code></td>
            <td>{{ row.status|default:"-" }}</td>
            <td>{{ row.count|default:1 }}</td>
          </tr>
        {% endfor %}
        </tbody>
      </table>
    </div>
    {% endif %}

    {% if inetsim.dns %}
    <h6>DNS activity</h6>
    <div class="table-responsive">
      <table class="table table-sm table-dark table-striped">
        <thead><tr><th>Query</th><th>Type</th><th>Response</th></tr></thead>
        <tbody>
        {% for row in inetsim.dns %}
          <tr><td>{{ row.query }}</td><td>{{ row.type }}</td><td><code>{{ row.response }}</code></td></tr>
        {% endfor %}
        </tbody>
      </table>
    </div>
    {% endif %}

    {% if not inetsim.enabled %}
    <div class="text-muted">No task-local traffic to the configured INetSim endpoint was observed.</div>
    {% endif %}
  </div>
</div>
{% endwith %}
''',
    encoding="utf-8",
)

text = network_target.read_text(encoding="utf-8")
load_line = "{% load inetsim_vm_tags %}"
if load_line not in text:
    text = load_line + "\n" + text

tabs_pos = text.find('id="networkTabs"')
if tabs_pos < 0:
    fail("networkTabs anchor not found in current CAPE network template")
ul_close = text.find("</ul>", tabs_pos)
if ul_close < 0:
    fail("networkTabs closing </ul> not found")

nav = f'''        {{% if network|inetsim_vm_active %}}
        <!-- {MARKER} / {MODERN_MARKER} -->
        <li class="nav-item">
            <a class="nav-link" id="network_inetsim-tab" href="#network_inetsim_tab"
               data-bs-toggle="tab" role="tab" aria-controls="network_inetsim_tab" aria-selected="false">
                <i class="fas fa-flask me-2"></i>INetSim Visual
            </a>
        </li>
        {{% endif %}}
'''
text = text[:ul_close] + nav + text[ul_close:]

content_pos = text.find('<div class="tab-content">', ul_close + len(nav))
if content_pos < 0:
    fail("network tab-content anchor not found")
content_open_end = text.find(">", content_pos) + 1
pane = '''
        {% if network|inetsim_vm_active %}
        <div class="tab-pane fade" id="network_inetsim_tab">
            {% include "analysis/network/_inetsim_vm_visual.html" %}
        </div>
        {% endif %}
'''
text = text[:content_open_end] + pane + text[content_open_end:]
network_target.write_text(text, encoding="utf-8")

(CANDIDATE / "INSTALL-LAYOUT").write_text("modern-network-template-v1\n", encoding="utf-8")

# Static candidate gates.
patched = network_target.read_text(encoding="utf-8")
for marker in (MARKER, MODERN_MARKER):
    if patched.count(marker) != 1:
        fail(f"network template marker validation failed: {marker}")
if patched.count("network_inetsim-tab") != 1:
    fail("INetSim tab was not inserted exactly once")
if patched.count('id="network_inetsim_tab"') != 1:
    fail("INetSim pane was not inserted exactly once")
if "{% load inetsim_vm_tags %}" not in patched:
    fail("INetSim template-tag library was not loaded")

for p in (helper_target, tags_target):
    py_compile.compile(str(p), doraise=True)

print("[PASS] Modern CAPE network template detected")
print("[PASS] Current network/index.html patched in candidate only")
print("[PASS] Additive INetSim helper/tag/visual candidate generated")
print("[PASS] Candidate Python files compile")
print("STATUS: PRODUCTION INSTALLATION CANDIDATE READY")
