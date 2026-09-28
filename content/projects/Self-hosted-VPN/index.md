---
title: "Reaching a Raspberry Pi Behind CGNAT: A Self-Hosted WireGuard Mesh, Hardened End to End"
date: 2026-09-28
draft: false
categories: [Networking & Infrastructure Security]
tags: [wireguard, networking, linux-hardening, raspberry-pi, oracle-cloud, troubleshooting]
---

## Summary

**The problem.** I wanted to open VS Code on my laptop anywhere — campus, a café, another
city — and work on my Raspberry Pi 5 at home as if it were local. But my home internet is
behind **CGNAT**: my ISP shares one public IP across many customers, so inbound
connections never reach my router at all. Port forwarding is not an option, not even a
bad one.

**The design.** A free-tier Oracle Cloud VPS with a real public IP acts as a rendezvous
point. The Pi dials **out** to it — which every NAT allows — and keeps a WireGuard tunnel
open. My laptop connects to the same VPS, which forwards traffic between the two. The
Pi's SSH port is never exposed to the internet; the only ways in are the home LAN or
holding a registered WireGuard key.

```
[Laptop 10.10.0.2] ──WireGuard──> [VPS 10.10.0.1] <──WireGuard── [Pi 10.10.0.3]
  split tunnel                    public IP, hub,            behind CGNAT,
                                  forwards peer↔peer         dials OUT only
```

**What I built and verified:**
- A hardened VPS hub: key-only SSH with root login off, default-deny firewall,
  fail2ban on the systemd journal, automatic security updates.
- A split-tunnel WireGuard mesh — only `10.10.0.0/24` rides the tunnel; normal browsing
  never touches the VPS.
- SSH and VS Code Remote-SSH into the Pi **from a mobile hotspot**, verified by the
  connection's source/destination addresses, not by "it seemed to work."
- A hardened Pi, changed over SSH with **no physical console**: narrow, source-scoped
  firewall rules applied under an automatic rollback timer.
- Rotation of two private keys that had been exposed in a chat transcript, plus a
  **PresharedKey** on every peer pair for post-quantum protection.

**The four debugging sessions that made this project worth writing up:**
1. **An invisible firewall.** The WireGuard handshake failed even with ufw *disabled*. The
   cause was a REJECT rule baked into the cloud provider's OS image, sitting above ufw
   where ufw couldn't see or remove it.
2. **A firewall policy nobody had exercised.** Two peers worked; adding a third broke
   peer-to-peer traffic, because the VPS had never had to *forward* before — and ufw's
   default forward policy is DROP.
3. **The theory I got wrong.** SSH over the tunnel was painfully slow. It looked exactly
   like an MTU problem, and it wasn't. Measuring each leg of the path separately found the
   real cause: specific CGNAT mappings carrying a flat ~340ms extra delay.
4. **A hypothesis refuted by my own later data.** I concluded the slow mapping had
   "degraded with age." Days later, a brand-new mapping was slow from its first second.
   The record keeps both the original claim and its correction.

**Result:** laptop → Pi ≈ 130ms end to end through Frankfurt, 0% packet loss, from home or
a hotspot. Cost: €0/month.

**Skills demonstrated:** WireGuard, Linux networking (iptables/nftables, ufw, routing,
MTU), SSH hardening, fail2ban, packet capture and per-hop latency analysis, cloud
networking (Oracle VCN, security lists), safe remote change management, key management,
and documenting decisions — including the ones that turned out wrong.

---

## The detailed version

### 1. Why a rendezvous server

I confirmed CGNAT by comparing the WAN address my router reported with the address the
outside world saw — they didn't match. That rules out every "expose a port at home"
approach. What remains is to reverse the direction: a machine with a real public IP sits
in the middle, and both ends connect *outward* to it.

**Why Oracle Cloud.** Its Always Free tier is permanent, not a 12-month trial, and gives a
real ARM instance (1 OCPU / 6 GB). This box is infrastructure meant to run indefinitely;
a time-limited free tier would only postpone a migration.

**Why WireGuard.** A small codebase that's easier to reason about and audit, a simple
config model, and a hub-and-peer topology that maps directly onto this problem.

**Design choices I made deliberately:**
- **Split tunnel** (`AllowedIPs = 10.10.0.0/24` on the laptop, not `0.0.0.0/0`). A full
  tunnel would route all my traffic through Frankfurt — an exit-node use case I don't
  need and don't want to pay the latency for. No MASQUERADE on the VPS, so it *cannot*
  act as an internet exit, by construction.
- **A `/24` subnet** for three devices. It costs nothing, and adding a NAS later is one
  more peer block with no redesign.
- **`PersistentKeepalive = 25` on the Pi.** Behind CGNAT, an idle NAT mapping expires and
  the VPS loses the path back to the Pi. The keepalive holds the mapping open.

### 2. Hardening the hub first

The VPS has a public IP, so it gets hardened *before* it becomes the VPN hub — the hub
shouldn't be the weak point of the design.

Before touching anything after a multi-week break, I re-checked the box's state and found
SSH **running but `disabled`** in systemd. A kernel update was about to force a reboot;
that combination would have locked me out with only the provider's serial console as a
way back. Five minutes of checking beat an afternoon of recovery.

The same check showed the systemd journal already full of brute-force attempts
(`Invalid user sshadmin`, repeated `root` logins) from all over the world — on a box that
was days old. That turned fail2ban from "a thing tutorials say to install" into a response
to observed traffic.

| Measure | Why |
|---|---|
| `apt full-upgrade` + reboot into the new kernel | A fresh cloud image isn't a patched one. |
| `PermitRootLogin no`, `PasswordAuthentication no` — explicitly set | Defaults allowed root via key and implied password auth. Validated with `sshd -t`, tested from a *new* session before closing the old one. |
| ufw default-deny; only 22/tcp and 51820/udp | Anything not explicitly allowed is unreachable, whatever vulnerability it has. |
| fail2ban (later reworked, see §4) | A firewall allow rule can't tell a login from a brute-force attempt; fail2ban watches the auth log and bans behavior. |
| unattended-upgrades | New CVEs don't wait for me to remember to log in. |

### 3. Debugging #1 — the firewall that ufw couldn't see

With both ends configured, the handshake never completed. The Pi kept sending; the VPS
received **zero bytes, ever**. I eliminated one layer at a time:

| Checked | Result |
|---|---|
| Cloud security list (UDP 51820) | Correct rule present |
| Network security group | None attached |
| `ufw disable`, as a test | **Still failed** — the key clue |
| Reverse-path filtering | Loose mode, not the culprit |
| UDP checksums (`tcpdump -vv`) | Fine |
| Socket bound correctly (`ss -ulnp`) | `0.0.0.0:51820` |
| WireGuard kernel debug logging | **Silent** while packets visibly hit the NIC |

If WireGuard logs *nothing* while packets arrive, the packets aren't reaching its socket.
So I dropped WireGuard from the question entirely: a plain `nc -u -l` listener on the same
port also received nothing. This was never a WireGuard problem — **UDP wasn't reaching
user space at all**, while TCP (SSH) worked the whole time.

`iptables -L -n -v --line-numbers` showed why: a protocol-agnostic
`REJECT ... icmp-host-prohibited` rule at position 6 of the INPUT chain, *above* ufw's
chains. It came from `/etc/iptables/rules.v4`, baked into the provider's Ubuntu ARM image
and loaded once at first boot by a persistence service that was itself half-removed. That
is exactly why disabling ufw changed nothing — the rule was never ufw's to disable.

I confirmed the diagnosis live with a temporary ACCEPT rule (the handshake appeared
instantly), then chose **full removal** over patching around it: backed up the
provider's ruleset, cleared it, removed the dangling persistence unit, and consolidated
everything into ufw. Two independent firewalls silently coexisting is exactly the kind of
thing that costs another multi-hour session later. A reboot confirmed the rule stayed gone
and the handshake re-established on its own.

**The lesson:** the most valuable signal was a *negative* result — "disabling the firewall
didn't help" — followed rigorously instead of explained away.

### 4. The fail2ban that looked broken, and the config that actually was

Next I found fail2ban's jail "active" with no firewall chain in sight. It looked broken;
it wasn't. Its iptables/nftables actions create their chain **on the first ban** for a
given IP family, not at start-up. A manual ban against a documentation address
(`203.0.113.50`) made the chain appear instantly.

Cross-checking that led to a real problem: `jail.local` was a full, unedited copy of the
978-line `jail.conf`. That freezes whatever defaults existed at copy time, and here it was
overriding the distribution's intended settings (`nftables` actions, `systemd` journal
backend) with older ones (`iptables-multiport`, a polling log watcher). It worked, but by
accident. I replaced it with a four-line override:

```ini
[DEFAULT]
bantime  = 10m
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 10.10.0.0/24
```

The nftables backend creates its chain at a priority ahead of ufw's, so rule-ordering
surprises like §3 can't bury it. The systemd backend reads the journal directly, removing
a dependency on a log file being written. The `ignoreip` entry trusts the WireGuard
subnet, not my home IP: reaching the VPS through the tunnel already requires a registered
private key, so that exemption trusts a **cryptographic identity**, not a spoofable
address. It also gives me a way back in if my public IP ever gets banned.

Afterward the logs showed real attackers being banned automatically, bans surviving both a
service restart and a reboot as `Restore Ban` entries, and one address block coming back
the moment each 10-minute ban expired.

### 5. Debugging #2 — the rule nobody had ever exercised

VPS ↔ Pi worked. I added the laptop as a third peer: handshakes on both ends, `ping` to
the Pi worked — and `ssh` to the Pi hung forever. `ssh -vvv` stalled at
`Connecting to 10.10.0.3 port 22`: not an auth problem, a delivery problem.

A capture on the Pi's WireGuard interface during an SSH attempt showed **zero packets
arriving**. So the fault sat at the one point every laptop → Pi packet crosses that a
two-node setup never used: the VPS **forwarding between peers**.

```
Chain FORWARD (policy DROP 30 packets, 1904 bytes)
```

`net.ipv4.ip_forward=1` only lets the *kernel* forward; ufw's own FORWARD policy is DROP
by default. With one peer, the VPS only ever terminated traffic, so that policy never
mattered. The second peer exercised it for the first time. I fixed it narrowly rather than
flipping the global policy:

```bash
sudo ufw route allow in on wg0 out on wg0
```

Peers can reach each other through the hub; nothing can be forwarded to or from any other
interface, so the "not an exit node" property holds. Verified with
`echo $SSH_CONNECTION` → `10.10.0.2 → 10.10.0.3`, and reboot-tested.

**The lesson:** a working system doesn't prove a *changed* system works. New topology
runs code paths that were never tested before.

### 6. Debugging #3 — slow SSH, and the theory I got wrong

Connected, but barely usable: about 20 seconds to log in, and 3–5 second freezes after
pasting text. Plain LAN SSH and direct SSH to the VPS were both instant. A longer ping
through the tunnel showed ~520ms average and **3.3% packet loss** — and at 500ms per round
trip, every lost TCP segment costs seconds in retransmission.

**The wrong turn.** The VPS's tunnel MTU was 8920 — inherited from the provider's
jumbo-frame internal network — while both peers used 1420. A don't-fragment ping from the
laptop returned "Message too long." It looked like proof. It wasn't: that error only meant
the laptop's own 1420 MTU correctly refused an oversized packet before it left the
machine. I lowered the VPS MTU anyway and SSH stayed slow. Two pieces of evidence finally
killed the theory: the Pi's physical interface had a standard 1500 MTU with plenty of
headroom, and a capture of a real SSH session showed a **132-byte** segment being
retransmitted three times — nowhere near any MTU limit.

**What actually worked: measuring each leg separately.**

| Leg | RTT | Loss |
|---|---|---|
| Laptop → VPS (inside the tunnel) | 70ms | 0% |
| VPS → Pi (inside the tunnel) | **406ms**, jitter 0.3ms | 0% |
| Pi → VPS | **406ms** | 0% |
| Pi → public internet, no tunnel | 57ms | 0% |

The laptop and the Pi were on the **same home connection, behind the same public IP** —
yet one got 70ms to the VPS and the other 406ms. And 406ms with 0.3ms of jitter doesn't
look like a real internet path; it looks like a deliberate, fixed hold.

To rule out the Pi — which also runs the house's DNS (Pi-hole in Docker) and was a
reasonable suspect — I captured on all its interfaces at once while pinging the VPS:

```
wg0  Out  ICMP echo request       t = 0
eth0 Out  UDP → VPS                t + 0.04ms   (encrypted, on the wire)
eth0 In   UDP ← VPS                t + 405.8ms  (outside world)
wg0  In   ICMP echo reply          t + 405.84ms (decrypted)
```

Under 0.1ms inside the Pi; **100% of the delay was outside it**. The only remaining
difference between the Pi and the laptop was the UDP flow itself. The Pi's config had no
fixed `ListenPort`, so restarting WireGuard gave it a new random source port — and a new
CGNAT mapping:

**406ms → 63ms instantly.** End to end, the laptop → Pi path went from 522ms with 3.3%
loss to 134ms with 0% loss. The remaining 134ms is simply the round trip through
Frankfurt, and SSH became comfortable to use.

Afterward I still pinned the VPS MTU to 1420 — not as a fix, but for consistency, and
because traffic the VPS *itself* originates would otherwise build oversized packets that
have to fragment on the way through a CGNAT.

### 7. Debugging #4 — correcting my own conclusion

In the moment I wrote that the long-lived flow had "degraded over time" — while noting
that I hadn't proven the mechanism, since I can't see inside my ISP. That caution paid
off. During key rotation days later (§10), the Pi picked up yet another new port, and
**the new flow was slow from its very first second.** Every Pi flow so far:

| Flow | RTT |
|---|---|
| Original, before the fix | 406ms |
| After a restart | 63ms |
| After a reboot | 63ms (stable for 8+ hours) |
| After key rotation | **404ms immediately** |
| After re-rolling the port | 58.6ms |

It isn't age; it's **which mapping a flow gets**. Some are bad from the start, and the bad
ones always carry the same ~340ms. The best fit is an ISP spreading flows across several
paths by hashing each flow's 5-tuple, with one slow path among them. That is still a
hypothesis — but it fits the data far better than my first one. Escaping a bad mapping
takes one command, with no restart and no config change:

```bash
sudo wg set wg0 listen-port 0   # rebind to a new random port → new flow, new mapping
```

I left the original "degraded over time" text in my notes with a correction beneath it.
The refutation is part of the record.

### 8. The acceptance test, and making it usable every day

Every test so far had the laptop on the same network as the Pi. So I switched to a phone
hotspot — confirming with `curl ifconfig.me` that my public IP had actually changed —
**without** toggling the tunnel. On the VPS, `wg show` showed the laptop's endpoint had
already moved to the hotspot's address, on its own.

```
ssh (from the hotspot) → echo $SSH_CONNECTION → 10.10.0.2 → 10.10.0.3
```

From a different network, into a Pi behind CGNAT whose SSH port has never been
internet-facing — entirely through the hub.

For daily use I wrote a `~/.ssh/config` with three aliases:
- **`pi`** — the tunnel, works anywhere.
- **`pi-lan`** — the home LAN. It isn't just faster; it's the **recovery path** when the
  tunnel is the thing that's broken.
- **`vps`** — the hub itself.

Two settings are deliberate. `IdentitiesOnly yes` offers each host only its correct key:
cycling through wrong keys counts as failed logins, and fail2ban on the VPS doesn't
whitelist my home IP. `ServerAliveInterval 30` keeps idle sessions alive through NAT.
VS Code Remote-SSH connects via `pi`, and I verified its session is tunneled the same way,
from its own integrated terminal.

One surprise: `pi-lan` connected over **IPv6 link-local** (`fe80::…%eth0`), because macOS
resolved the Pi's `.local` name to its link-local address. That's actually stronger proof
the connection never touched the tunnel — link-local traffic can't leave the LAN. But it
mattered for the next step.

### 9. Hardening the Pi with no console

The Pi's SSH was unreachable from the internet — but because of topology, not policy.
Topology can change without my touching the Pi: an ISP enabling IPv6 is enough. And
the constraints were tighter than on the VPS: the Pi is the home network's DNS server, and
I had no monitor or keyboard for it. A bad rule could break DNS for the whole house *and*
lock me out.

**Measure first.**
- `ip -6 addr show eth0 scope global` → empty. No global IPv6, so the Pi isn't reachable
  from the internet over IPv4 (CGNAT) *or* IPv6. Verified rather than assumed.
- `ss -tulnp` → SSH, mDNS (the thing resolving `my-pi.local`), and the kernel WireGuard
  socket. Pi-hole's ports didn't appear at all: its macvlan network gives it its own
  network stack, so LAN DNS never touches the host firewall.
- **ufw was already active** — set up during an earlier project and forgotten — with a
  broad `22/tcp ALLOW Anywhere`. Having run all day, it had already proven three things:
  WireGuard needs no inbound rule (the Pi initiates; replies ride connection tracking),
  Docker and ufw coexist here, and mDNS was already allowed by ufw's stock rules — which I
  confirmed in `before.rules` instead of adding a duplicate.

**Narrow rules, scoped by source:**

```bash
sudo ufw allow in on wg0 to any port 22 proto tcp                        # the tunnel
sudo ufw allow in on eth0 from 192.168.1.0/24 to any port 22 proto tcp   # LAN, IPv4
sudo ufw allow in on eth0 from fe80::/10 to any port 22 proto tcp        # LAN, IPv6 link-local
```

A simpler "allow 22 on eth0" would behave identically *today*. The source-scoped version
stays correct the day the Pi gets a global IPv6 address. The `fe80::/10` rule exists
because of the finding in §8: an IPv4-only LAN rule would have silently locked out the
recovery path.

**An order that can't strand me.** Add the new rules first; then, before deleting the
broad one, arm an automatic rollback:

```bash
sudo systemd-run --on-active=5min --unit=ufw-rollback /usr/sbin/ufw allow 22/tcp
```

It **re-adds** the old rule rather than disabling ufw, so the worst case is "back to where
I started," not "no firewall." And `systemd-run` survives the SSH session dying — the one
scenario a rollback exists for. Then: delete the old rules highest-number-first, test
*new* connections (recovery path first), cancel the timer, and confirm it's gone. I also
verified DNS on both paths afterward, because "I only touched SSH rules" is a prediction,
not a result.

**sshd.** Password and keyboard-interactive auth were already off, but root login via key
was allowed. Looking for *where* each setting lived showed that password auth had been
disabled by **cloud-init** at first boot — not by me. So I wrote a dedicated drop-in,
`/etc/ssh/sshd_config.d/10-hardening.conf`, that sorts before cloud-init's file. sshd uses
the first value it reads, so mine wins, and it no longer depends on a generated file. I
validated it with `sshd -t`, previewed the result with `sshd -T` before restarting, and
kept my session open.

The negative test was reported honestly: `ssh -l root` was rejected at the key-check stage,
because my key isn't in root's `authorized_keys`. That means the test **didn't** exercise
`PermitRootLogin no` itself. The setting is verified active via `sshd -T`; demonstrating it
live would have meant adding a root key — opening the very door being closed.

Everything was reboot-tested afterward.

### 10. Rotating exposed keys, and adding post-quantum PSKs

While debugging, two WireGuard private keys — the hub's and the laptop's — ended up in
plain text in a chat transcript. Contained, but an exposed private key is compromised in
principle, and I wanted to publish this writeup. So both were rotated. The Pi's key had
never been exposed and was left alone.

Since every config was open anyway, I added a **PresharedKey** to each peer pair. It's a
256-bit symmetric key mixed into WireGuard's handshake alongside the Curve25519 keypairs.
Elliptic-curve cryptography falls to a large enough quantum computer, and "harvest now,
decrypt later" is a real threat model: record traffic today, decrypt it in ten years.
Symmetric keys survive that — Grover's algorithm at most halves their strength, leaving
~128 bits of security. Honestly, it isn't strictly necessary for a home lab, since SSH
inside the tunnel is encrypted anyway. But the marginal cost was one line per config, and
I can explain exactly why it's there. It doesn't replace rotation; it's a separate layer.

The rule for the whole rotation: **no secret ever displayed on screen**.
- Configs were rewritten with `$(cat keyfile)` substitution inside a root shell running
  under `umask 077`.
- Secrets were checked by format instead of by eye: every WireGuard key is 44 base64
  characters, so a regex count confirmed each one was present and intact.
- The Pi's PSK went VPS → Pi through a pipe between two SSH sessions.
- The laptop's went through the clipboard into the WireGuard app, and the clipboard was
  cleared afterward.
- The Pi was reached over `pi-lan` throughout, since the tunnel drops mid-rotation.

Afterward, both old keys were accepted nowhere. I deleted the old key files **and** the
config backup that still contained one.

### 11. A decision, not an omission: no fail2ban on the Pi

My original plan included fail2ban on the Pi. Measured: not installed, and **zero** failed
SSH attempts in the whole available log window. I decided against it:
- To be safe, it would need `ignoreip` for the VPN subnet (or a key mistake bans me from a
  console-less box) and for the LAN (to protect the recovery path). But those are the
  **only** sources that can reach the Pi's SSH. It would have nothing left to ban.
- Password authentication is off, so brute force can't succeed in principle.
- It would add another firewall-rule writer next to Docker on the house's DNS server.

The real residual risk — a compromised device on my LAN probing the Pi — calls for
**visibility, not blocking**: shipping the Pi's SSH logs to a SIEM and alerting on
failures. That is a future project. I also recorded the conditions that would reopen
this decision: a global IPv6 address, password auth re-enabled, or untrusted devices on
the LAN.

---

## Final security posture

| From → To | Hub (VPS) SSH | Pi SSH |
|---|---|---|
| Internet | Key-only, root off, fail2ban | **Unreachable** — CGNAT, no global IPv6, *and* Pi firewall |
| Home LAN | Same as internet | Allowed (IPv4 `/24`, IPv6 link-local) |
| WireGuard peer | Allowed | Allowed via `wg0` — needs a registered key + PSK |

**Hub:** key-only SSH, root off · ufw default-deny, 22/tcp + 51820/udp, peer↔peer
forwarding only (no NAT, so not an exit node) · provider's hidden iptables ruleset
removed · fail2ban (nftables + systemd journal, WireGuard subnet trusted) ·
unattended-upgrades · tunnel MTU pinned to 1420.
**Pi:** source-scoped SSH-only firewall · sshd hardening in a drop-in it owns · outbound
WireGuard with keepalive · Pi-hole DNS verified unaffected.
**Keys:** rotated after exposure, PSK on every peer pair, every key file mode 600.

Measured: laptop → hub ≈ 70ms, Pi → hub ≈ 60ms, laptop → Pi ≈ 130ms, 0% loss, from home
or a hotspot.

## What I'd carry into the next project

- **A tool saying "active" is a claim, not proof.** ufw looked fine while a rule above it
  dropped everything; fail2ban looked broken while working as designed. Go one layer lower
  — packet captures, raw sockets, the effective config (`sshd -T`, `fail2ban-client -d`).
- **Measure each leg, not the whole path.** One end-to-end number hid a 406ms problem
  inside a 70ms one.
- **Wrong theories are data too.** The MTU detour and the refuted "degrades with age"
  conclusion are the most instructive parts of this project, which is why they're in
  here.
- **Say exactly what you proved.** "This flow is slow" was proven; "why" wasn't. Keeping
  those separate turned a later refutation into a footnote instead of a retraction.
- **Measure a machine before writing rules for it**, and **change machines you can't
  touch in an order that can't strand you.**
- **Own your configuration.** Twice, a working setup rested on something a tool had
  written — a stale fail2ban copy, cloud-init's sshd file. Both worked, and both got
  replaced with deliberate, documented config.

**Possible next steps:** escalating bans for repeat offenders on the hub; a health check
on the Pi that re-rolls a bad CGNAT mapping automatically; and forwarding the Pi's logs to
a SIEM, which is where the LAN-side risk actually belongs.
