import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

MODULE = ROOT / "src" / "inetsim_vm_logic.py"

spec = importlib.util.spec_from_file_location(
    "inetsim_vm_logic",
    MODULE,
)

logic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logic)


def sample_network(server_ip, guest_ip):
    return {
        "dns": [
            {
                "request": "example.test",
                "type": "A",
                "answers": [
                    {
                        "data": server_ip,
                    }
                ],
            }
        ],
        "tcp": [
            {
                "src": guest_ip,
                "dst": server_ip,
                "sport": 50001,
                "dport": 80,
            },
            {
                "src": guest_ip,
                "dst": server_ip,
                "sport": 50002,
                "dport": 443,
            },
        ],
        "udp": [
            {
                "src": guest_ip,
                "dst": server_ip,
                "sport": 51001,
                "dport": 53,
            },
            {
                "src": guest_ip,
                "dst": server_ip,
                "sport": 51002,
                "dport": 123,
            },
        ],
        "http": [
            {
                "dst": server_ip,
                "host": "example.test",
                "uri": "/test",
            }
        ],
    }


def check_environment(server_ip, guest_ip):
    network = sample_network(server_ip, guest_ip)

    assert logic.network_uses_inetsim(
        network,
        server_ip,
    )

    result = logic.summarize_inetsim_network(
        network,
        server_ip,
    )

    assert result["enabled"] is True
    assert result["server_ip"] == server_ip
    assert result["source_ip"] == guest_ip

    assert result["dns_count"] == 1
    assert result["tcp_count"] == 2
    assert result["udp_count"] == 2
    assert result["http_count"] == 1

    assert result["domains"] == [
        "example.test",
    ]

    assert result["services"]["HTTP"] == 1
    assert result["services"]["HTTPS"] == 1
    assert result["services"]["DNS"] == 1
    assert result["services"]["NTP"] == 1


# ------------------------------------------------------------
# Test a documentation/example network.
# ------------------------------------------------------------

check_environment(
    "203.0.113.2",
    "203.0.113.10",
)

print(
    "PASS: route=none INetSim traffic detected "
    "with 203.0.113.2"
)


# ------------------------------------------------------------
# Test a completely different user's network.
# ------------------------------------------------------------

check_environment(
    "10.77.50.2",
    "10.77.50.10",
)

print(
    "PASS: same logic works with a different "
    "INetSim subnet"
)


# ------------------------------------------------------------
# Normal route=none task with no INetSim traffic.
# ------------------------------------------------------------

ordinary_network = {
    "dns": [],
    "tcp": [
        {
            "src": "10.0.0.10",
            "dst": "10.0.0.20",
            "dport": 80,
        }
    ],
    "udp": [],
    "http": [],
}

assert not logic.network_uses_inetsim(
    ordinary_network,
    "10.77.50.2",
)

print(
    "PASS: ordinary route=none task is NOT "
    "misclassified as INetSim"
)

print("PASS: DNS/TCP/UDP/HTTP summary validated")
print("STATUS: UNIVERSAL ROUTE-NONE DETECTION LOGIC READY")
