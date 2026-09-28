import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

MODULE = (
    ROOT
    / "src"
    / "inetsim_vm_logic.py"
)

spec = importlib.util.spec_from_file_location(
    "inetsim_vm_logic",
    MODULE,
)

logic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logic)


server = "10.77.50.2"
guest = "10.77.50.10"


network = {
    "dns": [
        {
            "request": "example.test",
            "type": "A",
            "answers": [
                {
                    "data": server,
                }
            ],
        }
    ],

    "tcp": [
        {
            "src": guest,
            "dst": server,
            "sport": 50001,
            "dport": 80,
        },
        {
            "src": guest,
            "dst": server,
            "sport": 50002,
            "dport": 443,
        },
    ],

    "udp": [
        {
            "src": guest,
            "dst": server,
            "sport": 51001,
            "dport": 53,
        }
    ],

    "http": [
        {
            "dst": server,
            "host": "example.test",
            "method": "GET",
            "uri": "/payload-check",
            "status": 200,
            "status_text": "OK",
            "user-agent": "CAPE-Test",
        }
    ],
}


result = logic.build_route_none_inetsim_context(
    network,
    server,
)


assert result["enabled"] is True
assert result["route"] == "none"
assert result["server"] == server

assert result["attribution_summary"]["task_domains"] == [
    "example.test"
]

assert (
    result["attribution_summary"]
    ["task_relevant_requests"]
    == 1
)

assert result["attribution_summary"]["background_http"] == 0
assert result["attribution_summary"]["background_requests"] == 0

assert result["summary"]["dns"] == 1
assert result["summary"]["http"] == 1
assert result["summary"]["https"] == 1

assert len(result["http_aggregated"]) == 1

event = result["http_aggregated"][0]

assert event["host"] == "example.test"
assert event["method"] == "GET"
assert event["path"] == "/payload-check"
assert event["count"] == 1
assert event["task_relevant"] is True
assert event["background"] is False

assert result["findings"]

print("PASS: route=none visual context enabled")
print("PASS: Task Domains populated")
print("PASS: Relevant Requests populated")
print("PASS: DNS summary populated")
print("PASS: HTTP summary populated")
print("PASS: HTTPS summary populated")
print("PASS: HTTP attribution structure populated")
print("PASS: Network Findings structure populated")
print("PASS: unsupported background attribution is not fabricated")
print("STATUS: ROUTE-NONE ANALYST CONTEXT READY")
