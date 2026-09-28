# INetSim functional acceptance probe

`tests/fixtures/inetsim-positive-probe.cmd` is a benign Windows 7/10 control task for validating the `route=inetsim` path. It intentionally performs DNS and HTTP against `cape-inetsim-accept.invalid`, which is expected to be synthesized by the INetSim appliance.

Use this control file for the positive acceptance task rather than an arbitrary malware sample. A malware sample that produces no network activity cannot establish that the INetSim route works.

Acceptance should require:

- raw PCAP contains packets;
- the report records `route=inetsim`;
- DNS/HTTP evidence contains the marker;
- the observed destination is task-local INetSim evidence;
- no `capeisim0` MASQUERADE/NAT-to-uplink path is present;
- analyst Network Analysis remains task-attributed.

The marker is intentionally under `.invalid` so the same probe does not accidentally validate against the real Internet.