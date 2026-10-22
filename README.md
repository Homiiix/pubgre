# pubgre

`pubgre` carries a **real public IPv4 address** from one host to a router behind
another host over a routed GRE tunnel. It uses no NAT anywhere on that address's path.

```
[client router] ---- [local host] ===== GRE ===== [foreign host] ---- Internet
 WAN: T/mask           client-dev        egress-dev   egress-dev        T's provider
 gw:  GW (real)        proxy-ARPs GW                  proxy-ARPs T      gateway = GW
```

`T` is the transported IP and `GW` is its real provider gateway. The router puts `T`
on its WAN as an ordinary static address with gateway `GW`. It never learns a tunnel
exists, every inbound port reaches it, and the source addresses it sees are real.

It works on Ubuntu and Debian and needs root. It is a single bash script with no
hardcoded addresses or interfaces.

---

## Install

```bash
sudo bash pubgre install
```

The install step:

- copies the script to `/usr/local/sbin/pubgre`;
- writes the template unit `/etc/systemd/system/pubgre@.service`;
- creates `/etc/pubgre/` (config) and `/var/lib/pubgre/` (state), both mode 0700.

`pubgre` checks for `ip`, `iptables`, `systemctl`, `flock`, `ss`, `ping`, `modprobe`
and `timeout`, but **never installs packages**. `tcpdump`, `python3` and `nc` are
optional; `test` uses them for deeper diagnosis.

It never disables IPv6, creates swap, writes `/etc/sysctl.d`, or fetches anything from
the network.

## Quick start

On the **foreign** host (the one that owns `T`):

```bash
sudo pubgre create
```

It prompts for every value and shows auto-detected defaults in `[brackets]`. Nothing is
written until you confirm. At the end it prints a ready-made `pubgre create --role local
...` line for the peer, carrying the GRE key, link addresses, MTU and `T`/`GW`/mask.
Those values must match on both hosts.

On the **local** host, paste that line. It still asks for `--egress-dev` and
`--client-dev` and confirms everything.

Then:

```bash
sudo pubgre test NAME --preflight    # on BOTH hosts within the same ~45 s window
sudo pubgre up NAME                  # on both hosts
# router WAN: address T/mask, gateway GW, MTU = tunnel MTU (see below)
sudo pubgre test NAME                # on both hosts
sudo pubgre status NAME
```

## Commands

| command | what it does |
|---|---|
| `install` | install the binary and systemd template, check dependencies |
| `create [flags]` | define a tunnel; prompts for anything not given; validates; requires confirmation |
| `up NAME` | apply now, then enable and start `pubgre@NAME`, which reconciles every 15 s and survives reboot |
| `down NAME` | stop the service and reverse every change, including putting `T` back on its interface; the config is kept |
| `status [NAME]` | tunnel state, proxy ARP at this end plus evidence about the peer's end, routes and rules, MTU and MSS, iptables counters, 1-second throughput, drift |
| `test NAME [--port P]` | end-to-end proof that `T` works (see [Testing](#testing)) |
| `test NAME --preflight [--duration S]` | before `up`: verify GRE in both directions and probe the path MTU |
| `teardown NAME [--yes]` | `down` plus delete the config and state; when the last tunnel goes, restore `ip_forward` too |
| `reconcile NAME [--loop S \| --check]` | what the service runs; `--check` reports drift and changes nothing |

### `create` flags

| flag | role | meaning |
|---|---|---|
| `--role foreign\|local` | both | which end this is |
| `--name NAME` | both | `a-z0-9-`, at most 10 characters; the interface becomes `pg-NAME` |
| `--local-public IP` | both | this host's tunnel source address; must be on `--egress-dev` |
| `--remote-public IP` | both | the peer's tunnel source address |
| `--egress-dev NIC` | both | the NIC the outer GRE packets **must** use, even if it isn't the default route |
| `--egress-gw IP\|none` | both | the next hop on that NIC; `none` if the peer is on-link |
| `--tunnel-subnet` | both | `NET/30` (foreign takes .1, local .2), `NET/31`, or `FOREIGN_IP,LOCAL_IP` |
| `--gre-key N` | both | default is derived from the name and the endpoint pair, so it comes out the same on both hosts |
| `--mtu N` | both | default is egress MTU − 28 |
| `--transported-ip IP` | both | the public IP being carried (`T`) |
| `--transported-gw IP` | both | its real provider gateway (`GW`); must be inside `T/mask` |
| `--transported-mask M` | both | `24`, `/24` or `255.255.255.0`; the mask the router will use |
| `--transported-dev NIC` | foreign | the NIC on the provider segment where `T` lives (detected) |
| `--transported-mode onlink\|routed` | foreign | `onlink`: the provider ARPs for `T`, so proxy ARP is used. `routed`: the provider routes `T` to this host (detected) |
| `--client-dev NIC` | local | the dedicated link to the client router |
| `--client-arp-mode proxy\|gwaddr` | local | how the router's ARP for `GW` gets answered (see below) |
| `--router-mac off\|auto\|MAC` | local | pin the router's ARP entry (see below) |

## Design

### Foreign host

| what | how |
|---|---|
| tunnel | `ip tunnel add pg-NAME mode gre local L remote R key K ttl 255 dev EGRESS` |
| release `T` | `ip addr del T/mask dev TD`. The exact original (prefix, brd, scope, label, `noprefixroute`) is saved in `/var/lib/pubgre/NAME/orig`. If `T` is a primary address with secondaries, `promote_secondaries=1` is set first so they survive |
| answer ARP for `T` | `ip neigh add proxy T dev TD`, plus `neigh/TD/proxy_delay=0` |
| inbound | `T/32 dev pg-NAME` in the main table |
| outbound (source routing) | rule `from T lookup TM`. Table `TM` holds `default via GW dev TD onlink`, the provider subnet on-link, and a last-resort `blackhole default` |
| NAT | none. Two tagged `RETURN` rules exempt `T` from any NAT rules already on the host |

**Why a targeted proxy entry instead of `proxy_arp=1` on the provider NIC.** Blanket
`proxy_arp` makes Linux answer ARP for *any* address it routes out of another
interface. On a multi-homed host, that means answering for other customers' addresses
on the provider segment: ARP poisoning that gets ports shut down. The `ip neigh add
proxy` entry answers for `T` only. The kernel still replies only when forwarding is on
and the route to `T` leaves through a different interface (`pg-NAME`), so the reply is
always this host's own MAC. No second MAC ever appears on the port.

**Why `proxy_delay=0`.** By default Linux delays proxy replies to *broadcast* ARP
requests by a random amount up to 0.8 s. Gateways that retry quickly or give up early
can miss the reply.

### Local host

| what | how |
|---|---|
| tunnel | same construction, same egress pinning |
| towards the router | `T/32 dev CD` in the main table |
| from the router | rule `from T iif CD lookup TM`. Table `TM` holds `default dev pg-NAME` and `blackhole default` |
| answer the router's ARP for `GW` | `proxy` mode: `conf/CD/proxy_arp=1`, `neigh/CD/proxy_delay=0` |
| NAT | none (same tagged exemptions) |

How the proxy decision works: the router asks "who has `GW`? tell `T`". The kernel
looks up the route to `GW` *as if a packet from `T` had arrived on `CD`*. The rule
`from T iif CD` matches and sends it into the tunnel. Because that is a different
interface from `CD`, the kernel answers with `CD`'s MAC. You can reproduce the decision
by hand:

```bash
ip route get GW from T iif CD     # local host: must say "dev pg-NAME"
ip route get T from GW iif TD     # foreign host: must say "dev pg-NAME"
```

**`--client-arp-mode gwaddr`.** This mode puts `GW/32` on `CD` itself, so the host
*owns* the gateway address on that link. Use it when your router ignores ARP requests
from a sender address outside its subnet (see the router-ARP failure below), or when
`CD` is not a dedicated link. The trade-off is that a ping from the router to `GW` is
answered by the local host, not the real gateway.

**`--router-mac auto|MAC`.** This writes a permanent ARP entry for the router (`T` on
`CD`). `auto` learns the MAC from the router's first ARP and keeps it. Use it if the
router ignores the local host's ARP refreshes. `down` and `up` re-learn it, which you
need after replacing the router.

### Egress pinning (both hosts)

`dev EGRESS` on a GRE tunnel only makes the kernel look up the outer route with
`oif=EGRESS`. If the main table has no route to the peer out of that NIC, the tunnel is
dead. So each tunnel also owns a pin table:

```
rule  pref P+0: from L to R lookup TPIN
table TPIN:     R/32 via EGRESS_GW dev EGRESS onlink
                blackhole R/32 metric 4294967295   # never leak out of another NIC
```

The main table and the default route are never touched. A DHCP renewal or a failover
on another NIC changes nothing for the tunnel. If the egress NIC goes down, outer
packets are dropped rather than sent out the wrong uplink.

### Per-tunnel allocation (multiple tunnels per host)

| resource | value |
|---|---|
| interface | `pg-NAME` (alias `pubgre:NAME` marks ownership) |
| routing tables | `7100 + 3·i` (main), `+1` (pin), `+2` (test hairpin) |
| rule priorities | `7100 + 10·i` … `+9`: `+0` pin, `+1` source routing, `+5` test hairpin |
| GRE key | derived from the name and the endpoint pair, or `--gre-key`; must match both ends |
| route protocol | every route pubgre adds carries `proto 77` |
| iptables comment | `pubgre_NAME_<purpose>` |

`create` skips any table ID listed in `rt_tables` or already used by a rule or route,
and any rule priority already in use. It refuses a duplicate `T`, a duplicate
(local, remote, key), overlapping link addresses, or an existing kernel GRE tunnel with
the same parameters. Allocations are stored in `/var/lib/pubgre/NAME/alloc`.

### Reconciliation

`pubgre@NAME.service` runs `pubgre reconcile NAME --loop 15`. Every 15 seconds it
re-reads and re-validates the config, compares each item with the kernel, and changes
only what differs. It logs each change to the journal (`journalctl -u pubgre@NAME`).
When everything is already correct, a pass makes no changes and logs nothing.
`status` shows any drift, and `reconcile NAME --check` exits 1 if there is any.

## MTU math

```
outer IPv4 header      20
GRE header              4
GRE key                 4   (pubgre always uses a key)
                       ---
overhead               28

tunnel MTU  = path MTU − 28
TCP MSS     = tunnel MTU − 40      (IPv4 20 + TCP 20)
```

| egress | path MTU | tunnel MTU | MSS |
|---|---|---|---|
| Ethernet | 1500 | 1472 | 1432 |
| PPPoE | 1492 | 1464 | 1424 |
| filtered path measured by preflight, e.g. | 1450 | 1422 | 1382 |

- `create` defaults to egress MTU − 28.
- `test --preflight` measures the real path MTU with DF-set pings (binary search) and
  tells you if the configured MTU is too large. Set the same `mtu=` on both hosts.
- **TCP:** `TCPMSS --clamp-mss-to-pmtu` on `FORWARD -o pg-NAME` on both hosts rewrites
  the MSS in SYNs entering the tunnel to the tunnel's MTU − 40. Clamping each host's
  *outgoing* tunnel direction covers both directions: the foreign host clamps inbound
  SYNs from the Internet, and the local host clamps SYN-ACKs and SYNs from the router.
- **Everything else (UDP, ICMP, IPsec):** set the router's WAN MTU to the tunnel MTU.
  Otherwise oversize packets with DF set rely on ICMP "fragmentation needed" from the
  local host reaching the router, which works but costs a round trip.

## iptables rules

Every rule carries `-m comment --comment pubgre_NAME_<purpose>` and is inserted at
position 1 of its chain, so `ufw`, Docker and `FORWARD DROP` policies don't block it.
pubgre never flushes a table or chain. It adds and removes only rules with its own tag,
checking each with `-C` first. None of them matches a port, and none touches SSH.

| table / chain | purpose | rule | why |
|---|---|---|---|
| filter INPUT | `gre-in` | `-i EGRESS -s R -d L -p gre -j ACCEPT` | let the peer's GRE in even when INPUT policy is DROP |
| filter FORWARD | `fwd-in` | foreign: `-i TD -o pg -d T -j ACCEPT`; local: `-i pg -o CD -d T -j ACCEPT` | forward inbound traffic for `T`; the counter is the "packets for `T` arrived" evidence |
| filter FORWARD | `fwd-out` | foreign: `-i pg -o TD -s T -j ACCEPT`; local: `-i CD -o pg -s T -j ACCEPT` | forward the router's traffic; on the local host, a nonzero counter proves the router resolved `GW` |
| mangle FORWARD | `mss` | `-o pg -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu` | see [MTU math](#mtu-math) |
| nat PREROUTING | `nonat-in` | `-d T -j RETURN` | keep any existing DNAT rules away from `T` |
| nat POSTROUTING | `nonat-out` | `-s T -j RETURN` | keep any existing `MASQUERADE` / SNAT (for example from another GRE script) off `T` |

`pubgre test --preflight` adds temporary count-only rules tagged `pf-*` and removes
them when it exits. The reconciler also removes any that a crash left behind.

## sysctls

| sysctl | value | where | why |
|---|---|---|---|
| `net.ipv4.ip_forward` | 1 | global | routing |
| `conf.<dev>.forwarding` | 1 | `pg-NAME`, `TD` / `CD` | the proxy-ARP decision requires forwarding on the receiving interface |
| `conf.pg-NAME.rp_filter` | 2 | tunnel | loose reverse-path filtering. The effective value is `max(all, dev)`, so 2 is loose whatever `all` is |
| `conf.TD.rp_filter` | 2, only if it was 1 | foreign | inbound traffic for `T` comes from anywhere; strict mode drops it whenever `TD` isn't the default-route NIC |
| `neigh.<dev>.proxy_delay` | 0 | `TD` / `CD` | immediate proxy replies |
| `conf.CD.proxy_arp` | 1 | local, `proxy` mode | answer the router's ARP for `GW` |
| `conf.<dev>.promote_secondaries` | 1, only if needed | foreign | removing a primary `T` must not take its secondaries with it |
| `conf.pg-NAME.{accept,send}_redirects` | 0 | tunnel | no ICMP redirects across the tunnel |

Values are set at runtime only. Nothing is written to `/etc/sysctl.d`; the service
re-applies them after a reboot. The first original value of every pre-existing sysctl
goes into `/var/lib/pubgre/sysctl.orig`:

- `down` restores the ones on `TD` / `CD` unless another tunnel that is up uses the same NIC.
- `teardown` of the last tunnel also restores `ip_forward`.

## Safety rules

- **Management path.** `create`, `up` and `test --preflight` look at `$SSH_CONNECTION`
  and every established connection to the sshd port(s) read from `sshd_config`. They
  refuse, with an explanation, if:
  - `T` is the address you're connected to, or the address you're connecting from;
  - `T` is the source address of the default route;
  - pinning would move an SSH session between `L` and `R` onto another path;
  - proxy ARP would be enabled on the NIC your session arrives on;
  - `gwaddr` mode would claim your client's address.
- **Ownership.** pubgre only modifies or deletes an interface whose alias is
  `pubgre:NAME`. It only deletes ip rules that look up its own tables, and only routes
  with `proto 77` or in its own tables.
- **Config files** are parsed as strict `key=value` against a whitelist of keys. Every
  value is validated, and the file must be root-owned and not group- or
  world-writable. Nothing is sourced or evaluated.
- **DHCP-assigned `T`** is refused, because the DHCP client would fight over it.
- `T` in netplan, ifupdown or networkd config triggers a warning: the OS may re-add it
  on link events. The reconciler removes it again, but you should remove it from that
  config.
- **Teardown** reverses everything: rules, routes, tables, the proxy entry, the pinned
  neighbour, the `gwaddr` address, the interface and the sysctls, and it restores `T`
  to its original interface with its original attributes.

## Testing

### Preflight, before `up`, on both hosts at once

```bash
sudo pubgre test NAME --preflight
```

Each side brings up a temporary GRE interface with the real parameters, pings the
peer's link address every second, and counts GRE packets from the peer on `INPUT`. A
host can only *prove* its inbound direction, so you read the two reports together:

| this host: GRE from peer | this host: echo replies | meaning |
|---|---|---|
| yes | yes | both directions work |
| yes | no | peer → here works. If the **peer** reports *no GRE arrived*, then here → peer is filtered |
| no | no | the peer wasn't running in the same window, or peer → here is filtered. Re-run together; whichever side still sees nothing has its inbound direction filtered |

It also reports:
- GRE from the peer arriving at **another** address on the egress NIC (the peer's
  `--remote-public` is wrong);
- GRE from **other** sources (the peer sends from a different IP than you configured);
- the measured path MTU;
- when something fails, other source addresses on the egress NIC worth trying, since
  some providers drop GRE from one address and not another.

### Live test, after `up`

```bash
sudo pubgre test NAME [--port 80]
```

On both hosts:
- the peer's link address answers;
- full-size packets for the configured MTU pass with DF set.

On the foreign host:
- `T` is no longer local, the proxy entry exists, and the kernel's proxy decision for
  `T` is the tunnel;
- the provider gateway is resolved;
- **Inbound proof (hairpin).** It sends pings and a TCP connection from the host's own
  provider address to `T` *via the provider gateway*. The gateway has to ARP for `T`
  (this host answers), then deliver to this host's MAC, which forwards into the tunnel
  to the router. The router's reply comes back through the tunnel. The `fwd-in` counter
  and, when `tcpdump` is installed, a capture of the ARP exchange show where it stops.
  - **The gateway ARPs for `T`, this host replies, nothing arrives:** the provider is
    filtering proxied addresses (port security, IP-MAC binding).
  - **The gateway ARPs, this host doesn't reply:** a local problem (forwarding, the
    route, the proxy entry).
  - **No ARP and no packets:** the gateway refuses to hairpin. The test is
    inconclusive; ping `T` from any outside machine instead.
- TCP to the router: `open` or `refused` both prove the SYN reached the router and its
  answer came back. A timeout usually means the router's WAN firewall drops it.

On the local host:
- `proxy_arp` is on, and the kernel's proxy decision for `GW` (or `GW/32` in `gwaddr`
  mode) is the tunnel;
- the router has an ARP entry;
- **Round trip.** It pings the router's `T` and tries TCP from the local link address.
  To reply, the router must ARP for `GW`, so a reply proves its gateway ARP is answered.
- The `fwd-in` counter proves traffic for `T` is arriving from the tunnel.

The exit status is 0 only if every check passed.

## Debugging

### Proxy ARP failures

**Foreign side: the provider can't reach `T`.**

1. Check the kernel decision: `ip route get T from GW iif TD` must say `dev pg-NAME`.
   If it says `local`, `T` is still configured (`ip -4 addr | grep T`). If it says
   `dev TD`, the `T/32` route is missing.
2. Check `ip neigh show proxy` contains `T dev TD`, and that
   `sysctl net.ipv4.conf.TD.forwarding` is 1.
3. Watch the wire:
   ```bash
   tcpdump -lnni TD arp and host T
   ```
   You want `Request who-has T tell GW` followed by `Reply T is-at <this host's MAC>`.
   - Requests with no replies: steps 1 and 2.
   - No requests at all while someone outside pings `T`: the gateway's cache still has
     an entry, or the provider routes `T` elsewhere. Ask the provider, or wait for the
     cache to expire.
   - Requests and replies, but no traffic (`fwd-in` counter stays at 0): the provider
     is filtering. Typical causes are port security that allows only the IPs the
     provider assigned to this port, or an IP-to-MAC binding that expects `T` on a
     different MAC. Ask the provider to route `T` to your primary address instead,
     and use `--transported-mode routed`.

**Local side: the router can't reach its gateway.**

1. Check the kernel decision: `ip route get GW from T iif CD` must say `dev pg-NAME`.
2. Check `sysctl net.ipv4.conf.CD.proxy_arp` is 1.
3. Watch the wire:
   ```bash
   tcpdump -lnni CD arp
   ```
   - The router never asks for `GW`: its WAN config is wrong (check address, mask and
     gateway).
   - The router asks and gets no reply: steps 1 and 2.
   - The router asks and gets a reply, but the **local host's** requests for `T` go
     unanswered (`ip neigh show T dev CD` shows `FAILED` or `INCOMPLETE`): the router
     ignores ARP from senders outside its subnet. Use `--router-mac auto` or
     `--client-arp-mode gwaddr` (edit `/etc/pubgre/NAME.conf`, then `pubgre down NAME`
     and `pubgre up NAME`).

### Asymmetric routing

The `T` path must be symmetric: Internet → TD → tunnel → CD → router, and back the
same way. Breakages show up as one-way counters.

| symptom | look at | usual cause |
|---|---|---|
| foreign `fwd-in` rises, local `fwd-in` stays 0 | `tcpdump -ni EGRESS proto gre` on both hosts | GRE foreign → local is filtered, or the foreign host's outer route isn't pinned (`status` → "outer path") |
| local `fwd-out` rises, foreign `fwd-out` stays 0 | `ip route get 8.8.8.8 from T iif pg-NAME` on the foreign host | the source-routing rule or the `GW` route in table `TM` is missing; or reverse-path filtering drops on the tunnel (`nstat -az TcpExtIPReversePathFilter`) |
| the router's replies leave via the local ISP | `ip rule` on the local host | rule `from T iif CD` missing, so the router's packets fell through to the main table. pubgre's blackhole in `TM` should prevent this; check `status` → Drift |
| replies sourced from the foreign host's primary IP | `iptables -t nat -S POSTROUTING` | a MASQUERADE rule above pubgre's `nonat-out`. pubgre inserts at position 1 and the reconciler moves its rules back to the top within 15 s if another tool pushes them down. If it keeps flapping (see the journal), the other tool is re-inserting too: scope its rule with `! -s T` |
| everything works but large transfers stall | `ping -M do -s <mtu−28> <peer link address>` | MTU. Re-run the preflight and lower `mtu=` on both hosts; set the router's WAN MTU |
| traffic flaps every few minutes | `journalctl -u pubgre@NAME` | something else (netplan, networkd, another script) keeps re-adding `T` or changing routes; the journal shows what pubgre had to put back |

Useful one-liners:

```bash
watch -n1 "iptables -L FORWARD -v -n -x | grep pubgre_NAME"   # hop counters
ip -s link show pg-NAME                                        # tunnel rx/tx/errors
nstat -az | grep -i -E 'rpfilter|InNoRoutes|ReasmFails|FragFails'
ip -4 rule; ip route show table <TM>; ip route show table <TPIN>
pubgre reconcile NAME --check                                   # drift, no changes
```

## Files

| path | contents |
|---|---|
| `/usr/local/sbin/pubgre` | the script |
| `/etc/systemd/system/pubgre@.service` | template unit |
| `/etc/pubgre/NAME.conf` | validated `key=value` config (root, 0600) |
| `/var/lib/pubgre/NAME/alloc` | table IDs, rule priorities, interface name |
| `/var/lib/pubgre/NAME/orig` | `T`'s original address attributes, `gwaddr`/MAC-pin ownership |
| `/var/lib/pubgre/sysctl.orig` | first original value of each sysctl pubgre changed |
| `/run/pubgre/lock` | serialises the CLI and the reconcilers |

## Limitations

- IPv4 only. IPv6 is left untouched, and none of it is carried.
- One transported IP per tunnel. Create several tunnels for several IPs, possibly
  between the same two hosts; they get distinct keys.
- The router's MTU is your job; pubgre can only recommend a value.
- `status` and `test` see one host. Run them on both. Each reports counter-based
  evidence about the other end, but not the other end's configuration.
