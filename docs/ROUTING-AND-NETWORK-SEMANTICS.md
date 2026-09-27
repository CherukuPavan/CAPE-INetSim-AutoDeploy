# Routing and Network-Analysis Semantics

## Internet

The Internet route is task-scoped. AutoDeploy discovers the host's current real
default-route interface and configures CAPE to use that dirty line with NAT
enabled. The task source address is explicitly forwarded by CAPE for that
analysis. AutoDeploy does not install the INetSim redirect for Internet tasks.

## Fake Internet

The Fake Internet route is CAPE route=inetsim. The destination is the
deployment-owned Ubuntu INetSim VM on the isolated libvirt bridge. The isolated
bridge has no libvirt NAT/forwarding and no physical uplink.

## No network

The No network route is CAPE route=drop. AutoDeploy adds a source-specific
DROP to CAPE's rejected forwarding chain before the accepted chain. Required
CAPE ResultServer traffic is excepted only when it is actually forwarded
through the host. This is strict analysis-plane egress blocking; the CAPE
control plane remains available.

## Network Analysis purity

The raw dump.pcap is preserved for forensic use. The analyst-facing Network
Analysis result is filtered to the first CAPE behavior ProcessTree root and its
descendants. Events without a process_id in that task tree are omitted.

The report receives an autodeploy_task_network metadata object containing the
root PID, tracked PID count, kept event count, suppressed event count, and a
flag that the raw PCAP was preserved.

This deliberately suppresses background or unattributed Windows network
activity instead of presenting it as malware traffic. CAPE Agent, ResultServer,
and required Windows services remain available for control and collection.

## Transaction safety

Every CAPE file touched by this feature is backed up before modification and
protected by post-change SHA-256 state. Unknown layouts or ambiguous patch
anchors fail closed.
