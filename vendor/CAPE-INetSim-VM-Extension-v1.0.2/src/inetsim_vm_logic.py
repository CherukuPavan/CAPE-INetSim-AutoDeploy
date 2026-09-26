"""
Reusable CAPE Ubuntu-VM INetSim detection helpers.

This module contains no machine-specific IP addresses.

Its purpose is to determine whether a CAPE task actually used the
configured INetSim server and to summarize task-local network activity.
"""

from collections import Counter
from ipaddress import IPv4Address


TCP_SERVICES = {
    21: "FTP",
    25: "SMTP",
    80: "HTTP",
    110: "POP3",
    443: "HTTPS",
    465: "SMTPS",
    990: "FTPS",
    995: "POP3S",
    6667: "IRC",
}

UDP_SERVICES = {
    53: "DNS",
    69: "TFTP",
    123: "NTP",
    514: "Syslog",
}


def validate_ipv4(value):
    """Return a normalized IPv4 address or raise ValueError."""
    return str(IPv4Address(str(value).strip()))


def _connections_to(network, protocol, server_ip):
    """Return task connections whose destination is the INetSim server."""
    if not isinstance(network, dict):
        return []

    rows = []

    for connection in network.get(protocol) or []:
        if not isinstance(connection, dict):
            continue

        if str(connection.get("dst", "")).strip() == server_ip:
            rows.append(connection)

    return rows


def _dns_to(network, server_ip):
    """
    Return DNS records whose answers point to the INetSim server.

    This uses CAPE's task-local DNS results, not a global INetSim log.
    """
    if not isinstance(network, dict):
        return []

    rows = []

    for dns in network.get("dns") or []:
        if not isinstance(dns, dict):
            continue

        answers = dns.get("answers") or []

        points_to_inetsim = any(
            isinstance(answer, dict)
            and str(answer.get("data", "")).strip() == server_ip
            for answer in answers
        )

        if points_to_inetsim:
            rows.append(dns)

    return rows


def _http_to(network, server_ip):
    """Return HTTP records explicitly associated with the INetSim server."""
    if not isinstance(network, dict):
        return []

    rows = []

    for event in network.get("http") or []:
        if not isinstance(event, dict):
            continue

        destination = str(
            event.get("dst", "")
            or event.get("dstip", "")
            or event.get("ip", "")
        ).strip()

        if destination == server_ip:
            rows.append(event)

    return rows


def network_uses_inetsim(network, server_ip):
    """
    True only when task-local network evidence points to server_ip.

    Evidence may come from:
      * TCP destination
      * UDP destination
      * DNS answer
      * HTTP destination

    This means route='none' alone is NOT enough to show the INetSim tab.
    """
    server_ip = validate_ipv4(server_ip)

    return bool(
        _connections_to(network, "tcp", server_ip)
        or _connections_to(network, "udp", server_ip)
        or _dns_to(network, server_ip)
        or _http_to(network, server_ip)
    )


def summarize_inetsim_network(network, server_ip):
    """
    Build a simple task-local summary for the INetSim visualization.

    No global service.log is required.
    """
    server_ip = validate_ipv4(server_ip)

    tcp = _connections_to(network, "tcp", server_ip)
    udp = _connections_to(network, "udp", server_ip)
    dns = _dns_to(network, server_ip)
    http = _http_to(network, server_ip)

    domains = []
    seen = set()

    for event in dns:
        request = str(event.get("request", "") or "").strip()

        if request and request not in seen:
            domains.append(request)
            seen.add(request)

    services = Counter()

    for connection in tcp:
        try:
            port = int(connection.get("dport"))
        except (TypeError, ValueError):
            port = None

        name = TCP_SERVICES.get(
            port,
            f"TCP/{port}" if port is not None else "TCP",
        )

        services[name] += 1

    for connection in udp:
        try:
            port = int(connection.get("dport"))
        except (TypeError, ValueError):
            port = None

        name = UDP_SERVICES.get(
            port,
            f"UDP/{port}" if port is not None else "UDP",
        )

        services[name] += 1

    source_counts = Counter()

    for connection in tcp + udp:
        source = str(connection.get("src", "") or "").strip()

        if source:
            source_counts[source] += 1

    source_ip = ""

    if source_counts:
        source_ip = source_counts.most_common(1)[0][0]

    return {
        "enabled": network_uses_inetsim(network, server_ip),
        "server_ip": server_ip,
        "source_ip": source_ip,
        "dns_count": len(dns),
        "tcp_count": len(tcp),
        "udp_count": len(udp),
        "http_count": len(http),
        "domains": domains,
        "services": dict(sorted(services.items())),
        "total_connections": len(tcp) + len(udp),
    }


# ============================================================
# CAPE_INETSIM_VM_ROUTE_NONE_CONTEXT_V1
# ============================================================

def _normalized_host(value):
    """Normalize host/domain names for task-local correlation."""

    return str(value or "").strip().lower().rstrip(".")


def _http_destination(event):
    """Extract a destination IP from common CAPE HTTP fields."""

    if not isinstance(event, dict):
        return ""

    return str(
        event.get("dst", "")
        or event.get("dstip", "")
        or event.get("ip", "")
        or ""
    ).strip()


def _http_host(event):
    """Extract the HTTP Host value defensively."""

    if not isinstance(event, dict):
        return ""

    return str(
        event.get("host", "")
        or event.get("hostname", "")
        or ""
    ).strip()


def _http_path(event):
    """Extract the HTTP URL/path defensively."""

    if not isinstance(event, dict):
        return ""

    return str(
        event.get("uri", "")
        or event.get("path", "")
        or event.get("url", "")
        or "/"
    ).strip()


def _http_method(event):
    """Return a normalized HTTP method."""

    if not isinstance(event, dict):
        return ""

    return str(
        event.get("method", "")
        or "GET"
    ).strip().upper()


def _http_status(event):
    """Return HTTP status information when CAPE has it."""

    if not isinstance(event, dict):
        return "", ""

    status = (
        event.get("status")
        or event.get("status_code")
        or ""
    )

    status_text = (
        event.get("status_text")
        or event.get("reason")
        or ""
    )

    return str(status), str(status_text)


def _http_user_agent(event):
    """Extract common CAPE user-agent field names."""

    if not isinstance(event, dict):
        return ""

    return str(
        event.get("user-agent", "")
        or event.get("user_agent", "")
        or event.get("useragent", "")
        or ""
    ).strip()


def _task_domains_for_server(network, server_ip):
    """
    Return domains whose CAPE DNS answers point at the configured
    Ubuntu-VM INetSim server.
    """

    domains = []
    seen = set()

    for event in _dns_to(network, server_ip):

        domain = _normalized_host(
            event.get("request", "")
        )

        if domain and domain not in seen:
            domains.append(domain)
            seen.add(domain)

    return domains


def _route_none_http_rows(network, server_ip, task_domains):
    """
    Build HTTP evidence using only this CAPE task.

    An HTTP event is accepted when:
      * its destination is the INetSim server, OR
      * its Host belongs to a domain that DNS mapped to INetSim.
    """

    if not isinstance(network, dict):
        return []

    domain_set = {
        _normalized_host(domain)
        for domain in task_domains
    }

    groups = {}

    for event in network.get("http") or []:

        if not isinstance(event, dict):
            continue

        destination = _http_destination(event)
        host = _http_host(event)
        host_key = _normalized_host(host)

        if (
            destination != server_ip
            and host_key not in domain_set
        ):
            continue

        method = _http_method(event)
        path = _http_path(event)
        status, status_text = _http_status(event)
        user_agent = _http_user_agent(event)

        key = (
            host,
            method,
            path,
            status,
            status_text,
            user_agent,
        )

        if key not in groups:

            groups[key] = {
                "host": host,
                "method": method,
                "path": path,
                "url": path,
                "status": status,
                "status_text": status_text,
                "user_agent": user_agent,
                "count": 0,

                # This evidence is task-local CAPE traffic.
                "task_relevant": True,
                "background": False,

                # CAPE's generic HTTP structure may not provide
                # a relative timestamp in every release.
                "first_seen": None,
            }

        groups[key]["count"] += 1

    return list(groups.values())


def _route_none_dns_rows(network, server_ip):
    """Build visual-compatible DNS evidence."""

    rows = []

    for event in _dns_to(network, server_ip):

        request = str(
            event.get("request", "") or ""
        ).strip()

        query_type = str(
            event.get("type", "") or ""
        ).strip()

        answers = []

        for answer in event.get("answers") or []:

            if not isinstance(answer, dict):
                continue

            value = str(
                answer.get("data", "") or ""
            ).strip()

            if value:
                answers.append(value)

        rows.append({
            "query": request,
            "type": query_type,
            "response": ", ".join(answers),
            "time": 0.0,
            "task_relevant": True,
        })

    return rows


def _route_none_https_rows(network, server_ip):
    """
    Represent task-local TCP/443 connections as HTTPS/TLS evidence.

    We do not invent certificate or TLS-handshake details that CAPE
    did not actually provide.
    """

    rows = []

    for connection in _connections_to(
        network,
        "tcp",
        server_ip,
    ):

        try:
            port = int(connection.get("dport"))
        except (TypeError, ValueError):
            continue

        if port != 443:
            continue

        try:
            source_port = int(connection.get("sport"))
        except (TypeError, ValueError):
            source_port = ""

        rows.append({
            "time": 0.0,
            "source_port": source_port,
            "port": 443,
            "error": "",
            "confidence": "task-network",
        })

    return rows


def build_route_none_inetsim_context(network, server_ip):
    """
    Build the visual data model for Ubuntu-VM INetSim analyses
    submitted with CAPE route=inetsim.

    This function uses only task-local CAPE network evidence.
    It never reads or fabricates global INetSim service-log data.
    """

    server_ip = validate_ipv4(server_ip)

    base = {
        "enabled": False,
        "route": "inetsim",
        "server": server_ip,
        "mode": "route-inetsim-task-network",

        "correlation": {
            "method": "CAPE task-local network evidence",
            "source_ip_rewritten_by_rooter": False,
        },

        "summary": {
            "dns": 0,
            "http": 0,
            "https": 0,
            "other": 0,
            "total": 0,
        },

        "dns": [],
        "http": [],
        "http_aggregated": [],
        "https": [],
        "other": [],
        "timeline": [],
        "findings": [],

        "attribution_summary": {
            "task_domains": [],
            "task_relevant_requests": 0,
            "background_http": 0,
            "background_requests": 0,
        },
    }

    if not network_uses_inetsim(
        network,
        server_ip,
    ):
        return base

    task_domains = _task_domains_for_server(
        network,
        server_ip,
    )

    dns_rows = _route_none_dns_rows(
        network,
        server_ip,
    )

    http_rows = _route_none_http_rows(
        network,
        server_ip,
        task_domains,
    )

    https_rows = _route_none_https_rows(
        network,
        server_ip,
    )

    tcp = _connections_to(
        network,
        "tcp",
        server_ip,
    )

    udp = _connections_to(
        network,
        "udp",
        server_ip,
    )

    http_request_count = sum(
        item.get("count", 0)
        for item in http_rows
    )

    known_transport_events = (
        http_request_count
        + len(https_rows)
        + len(dns_rows)
    )

    total_transport_connections = (
        len(tcp)
        + len(udp)
    )

    other_count = max(
        0,
        total_transport_connections
        - len(https_rows)
        - len(dns_rows)
    )

    total = (
        len(dns_rows)
        + http_request_count
        + len(https_rows)
        + other_count
    )

    base["enabled"] = True

    base["dns"] = dns_rows
    base["http"] = http_rows
    base["http_aggregated"] = http_rows
    base["https"] = https_rows

    base["summary"] = {
        "dns": len(dns_rows),
        "http": http_request_count,
        "https": len(https_rows),
        "other": other_count,
        "total": total,
    }

    base["attribution_summary"] = {
        "task_domains": task_domains,
        "task_relevant_requests": http_request_count,

        # We deliberately do not label traffic as background
        # without stronger process/log correlation evidence.
        "background_http": 0,
        "background_requests": 0,
    }

    summary = summarize_inetsim_network(
        network,
        server_ip,
    )

    source_ip = summary.get(
        "source_ip",
        "",
    )

    base["source_ip"] = source_ip

    base["findings"] = [
        {
            "level": "observed",
            "category": "Network",
            "title": "Ubuntu-VM INetSim traffic observed",
            "detail": (
                f"CAPE task-local traffic reached "
                f"INetSim server {server_ip}"
            ),
            "count": total_transport_connections,
        }
    ]

    if task_domains:

        base["findings"].append({
            "level": "observed",
            "category": "DNS",
            "title": "Domains resolved to INetSim",
            "detail": ", ".join(task_domains),
            "count": len(task_domains),
        })

    if http_request_count:

        base["findings"].append({
            "level": "observed",
            "category": "HTTP",
            "title": "Task-local HTTP requests observed",
            "detail": (
                f"{http_request_count} HTTP request(s) "
                f"were associated with the INetSim endpoint"
            ),
            "count": http_request_count,
        })

    return base
