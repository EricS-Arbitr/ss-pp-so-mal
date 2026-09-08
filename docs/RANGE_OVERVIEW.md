# Voltgrid Power

### A small electric utility. Fully instrumented. Under attack.

---

Most SIEM training environments treat the network as a backdrop. Logs arrive,
analysts triage them, and nothing an attacker does is constrained by where they
are.

**Voltgrid is built the other way round.** A 75-host power utility with a real
Active Directory forest, a real DMZ, and a genuinely segmented OT enclave
running gas-turbine plant equipment. Three Security Onion sensors watch it from
three different vantage points — and *which sensor sees an event tells you
where the adversary is standing*.

Lateral movement stops being a diagram and becomes something a defender
reconstructs from evidence.

---

## What defenders get

**A SIEM watching a real network.** Security Onion 2.4, distributed across a
manager, a search node and three sensors. Suricata and Zeek on every mirrored
segment. Elastic Agent on 42 Windows endpoints feeding process and file
telemetry into the same platform.

**Six analyst positions plus a forensics bench** — SIFT, REMnux and FLARE on the same segment — with tooling ready — and
deliberately excluded from the emulated-user population, so an analyst's own
activity never contaminates the host they investigate from.

**A network that is already busy.** 32 emulated users log in, browse, open
documents and move files continuously. Detections have to survive contact with
a network that is not quiet — because production never is.

**IT and OT, properly separated.** Corporate runs OSPF; the plant sits behind a
firewall boundary reachable only by static route, with its own domain
controller so routine OT identity traffic never crosses. An intrusion that
reaches the control station is a different event, on a different sensor, than
one that stops in the DMZ.

---

## What instructors get

**Two attack paths, usable together.** A Kali workstation for manual red team
operations, and scripted attack emulation targeting seven high-value hosts
spanning both sides of the firewall boundary. Start automated, continue by
hand; the defender's view does not change shape.

**Tunable visibility.** Endpoint coverage is an inventory group, not a
hard-coded list. Removing the plant control station from Sysmon coverage is a
one-line change that makes the OT enclave meaningfully harder to investigate —
and models how conservative utilities actually instrument process equipment.

**Repeatable builds.** The entire range is Ansible from a pinned tarball,
verified by two scripts that assert outcomes rather than exit codes. Stand it
up, run the exercise, rebuild it clean.

---

## The terrain

| | |
|---|---|
| **Scale** | 75 hosts across 13 host-bearing segments, plus 7 point-to-point transit links |
| **Identity** | `voltgrid.com` — three domain controllers, 40 domain members, 32 emulated users |
| **Corporate** | Services, Business Processing, Engineering, Legal, InfoSec |
| **Perimeter** | DMZ with public web, DNS and mail; simulated Internet beyond |
| **OT enclave** | Control network, gas turbine, turbine simulation and OT services — PLC, historian, vibration sensor, engineering workstation |
| **Security** | Security Onion grid plus six analyst workstations |
| **Routing** | OSPF core, eBGP at the ISP edge, static across the OT boundary |

---

## Training value

| Skill | How the range exercises it |
|---|---|
| Network forensics | Full packet visibility on three segments via layer-2 mirrors — Zeek connection, DNS, HTTP and file logs |
| Endpoint investigation | Sysmon and Elastic Agent process, file and network telemetry across 42 hosts |
| Lateral movement detection | Segment-aware sensor placement makes east-west movement observable as a change in *which* sensor carries the traffic |
| IT/OT boundary defence | A real firewall boundary with its own DC — crossing it is detectable, and the plant side gives deliberately reduced visibility |
| Alert triage under load | Continuous emulated user activity means signal must be separated from genuine background noise |
| Threat hunting | Dedicated analyst positions with the full Security Onion toolset and no synthetic activity of their own |

---

## Deployment

Ansible from a pinned, versioned tarball. Two to three hours from a clean
blueprint to a verified range, unattended. Verification asserts what actually
matters — that sensors are receiving packets, that Zeek is producing connection
records, that every endpoint is enrolled — not merely that the playbook exited
zero.

---

*Technical detail: see [RANGE_GUIDE.md](RANGE_GUIDE.md).*
