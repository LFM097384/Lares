# LiveKit v1.13.6 — Config Verification Report

**Refs actually read (all HTTP 200):**

- `https://raw.githubusercontent.com/livekit/livekit/v1.13.6/pkg/config/config.go` — tag `v1.13.6` resolved, no fallback needed
- `https://raw.githubusercontent.com/livekit/livekit/v1.13.6/config-sample.yaml`
- `https://raw.githubusercontent.com/livekit/livekit/v1.13.6/pkg/service/turn.go`
- `https://raw.githubusercontent.com/livekit/livekit/v1.13.6/pkg/service/server.go`
- `https://raw.githubusercontent.com/livekit/livekit/v1.13.6/pkg/service/rtcservice.go`
- `https://raw.githubusercontent.com/livekit/livekit/v1.13.6/pkg/service/auth.go`
- `https://raw.githubusercontent.com/livekit/livekit/v1.13.6/go.mod`
- `https://raw.githubusercontent.com/livekit/mediatransportutil/f234b534b095/pkg/rtcconfig/config.go`
- `https://raw.githubusercontent.com/livekit/mediatransportutil/f234b534b095/pkg/rtcconfig/webrtc_config.go`

**Critical structural fact:** the `rtc:` YAML block is NOT fully defined in the livekit repo. `pkg/config/config.go` embeds an external struct inline:

```go
type RTCConfig struct {
	rtcconfig.RTCConfig `yaml:",inline"`
	...
}
```

`rtcconfig.RTCConfig` lives in `github.com/livekit/mediatransportutil`, pinned by `go.mod` to
`v0.0.0-20260821083140-f234b534b095`. All of `udp_port`, `tcp_port`, `port_range_start`,
`port_range_end`, `use_external_ip` are defined there, and because of `yaml:",inline"` they are
direct children of `rtc:`. The commit hash above is the exact dependency v1.13.6 builds against.

Docs URLs redirect: `docs.livekit.io/home/self-hosting/*` → `docs.livekit.io/transport/self-hosting/*`.
Append `.md` to get full text (HTML fetches return nav chrome only).

---

## 1. `port_range_start`/`port_range_end` vs `udp_port`, and precedence

### Field definitions and Go types

From `rtcconfig/config.go`:

```go
type RTCConfig struct {
	UDPPort                  PortRange        `yaml:"udp_port,omitempty"`
	TCPPort                  uint32           `yaml:"tcp_port,omitempty"`
	ICEPortRangeStart        uint32           `yaml:"port_range_start,omitempty"`
	ICEPortRangeEnd          uint32           `yaml:"port_range_end,omitempty"`
```

**`rtc.udp_port` is NOT an int — it is a `PortRange` struct**, confirming the suspicion in the task.

```go
type PortRange struct {
	Start int `yaml:"start,omitempty"`
	End   int `yaml:"end,omitempty"`
}

func (r *PortRange) UnmarshalString(str string) error {
	if str == "" { return nil }
	if strings.Contains(str, "-") {
		parts := strings.Split(str, "-")
		...
		if end <= start {
			return fmt.Errorf("end port %d must be greater than start port %d", end, start)
		}
		r.Start = start; r.End = end
		return nil
	}
	port, err := strconv.Atoi(str)
	...
	r.Start = port
	return nil
}

func (r *PortRange) Valid() bool { return r.Start != 0 }
```

It has a custom `UnmarshalYAML`, so **both `udp_port: 7882` and `udp_port: 7882-7892` are valid YAML**.
A bare int sets `Start` only, leaving `End == 0`.

### What each does

- **`port_range_start`/`port_range_end`** → passed to pion's ephemeral UDP port range. LiveKit
  advertises host ICE candidates on ports allocated from this range; each PeerConnection binds its
  own socket(s).
- **`udp_port`** → builds a **UDP mux**: one (or a few) long-lived UDP socket(s) demultiplexing ICE
  traffic for **all** participants by ufrag. Confirmed by `s.SetICEUDPMux(udpMux)`.

Note the mux is **multi-port capable, capped by CPU count**:

```go
availablePorts := rtcConf.UDPPort.ToSlice()
ports := make([]int, 0, len(availablePorts))
for i := 0; i < runtime.NumCPU() && i < len(availablePorts); i++ {
	ports = append(ports, availablePorts[i])
}
muxes, err := transport.CreateUDPMuxesFromPorts(ports, opts...)
...
udpMux = transport.NewMultiPortsUDPMux(muxes, standalonePortMuxes)
```

So `udp_port: 7882` (single int) **is** a true single-port mux for all participants. A range like
`7882-7892` opens up to `min(len(range), NumCPU)` mux sockets — still a fixed, tiny, participant-independent
set of ports. This is a scaling optimization, not per-participant allocation.

### PRECEDENCE — port range WINS

`rtcconfig/webrtc_config.go`, `NewWebRTCConfig()`:

```go
if !rtcConf.ForceTCP {
	networkTypes = append(networkTypes, webrtc.NetworkTypeUDP4, webrtc.NetworkTypeUDP6)
	if rtcConf.ICEPortRangeStart != 0 && rtcConf.ICEPortRangeEnd != 0 {
		if err := s.SetEphemeralUDPPortRange(uint16(rtcConf.ICEPortRangeStart), uint16(rtcConf.ICEPortRangeEnd)); err != nil {
			return nil, err
		}
	} else if rtcConf.UDPPort.Valid() {
		// ... build UDP mux ...
	}
}
```

**If both are set, `port_range_start`/`port_range_end` win and `udp_port` is silently ignored.**
There is no validation error, no warning — the `else if` simply never runs. This matches
`config-sample.yaml`:

> `# port_range_start & end must not be set for this config to take effect`
> `# udp_port: 7882-7892`

**⚠️ The official ports-firewall doc states the exact opposite and is WRONG.** Its table says of
`rtc.udp_port`: *"When this is set, rtc.port_range_start/end are not used"*
(https://docs.livekit.io/transport/self-hosting/ports-firewall.md). The source is authoritative:
the range wins. **Prefer the source. For a single-port deployment you must OMIT the range keys entirely.**

**Edge case (audit-worthy):** the guard requires **both** range endpoints non-zero. If you set only
`port_range_start` and also `udp_port`, the first branch is false and the **mux** is used instead —
a silent, surprising outcome. Set both or neither.

### Defaults and the fallback path

`config.go`:

```go
RTC: RTCConfig{ RTCConfig: rtcconfig.RTCConfig{
	UseExternalIP: false, TCPPort: 7881,
	ICEPortRangeStart: 0, ICEPortRangeEnd: 0, STUNServers: []string{},
}},
```

Baked-in defaults for the range are **0**, not 50000–60000. The real default is applied in
`RTCConfig.Validate(development bool)`:

```go
if !conf.UDPPort.Valid() && conf.ICEPortRangeStart == 0 {
	// to make it easier to run in dev mode/docker, default to single port
	if development {
		conf.UDPPort = PortRange{Start: 7882}
	} else {
		conf.ICEPortRangeStart = 50000
		conf.ICEPortRangeEnd = 60000
	}
}
```

So: configuring **only** `udp_port` leaves the range at 0/0 → mux is used. Configuring neither yields
50000–60000 in production, or single-port 7882 under `development: true`. Called from `NewConfig` via
`conf.RTC.Validate(conf.Development)`.

---

## 2. Is single-port UDP mux officially recommended for small/self-hosted deployments?

**No — no such recommendation exists in the official docs. Marked UNVERIFIED as a "recommendation".**

What the sources actually say:

- `config-sample.yaml` (the closest thing to guidance) recommends the opposite of a *single* port for performance:
  > `# when set, LiveKit will attempt to use a UDP mux so all UDP traffic goes through`
  > `# listed port(s). To maximize system performance, we recommend using a range of ports`
  > `# greater or equal to the number of vCPUs on the machine.`
- ports-firewall doc calls it `(optional) It's possible to handle all UDP traffic on a single port.` — neutral, not a recommendation.
- The deployment doc's "recommended config for a production deploy" uses the **port range**, not the mux:
  ```yaml
  rtc:
    tcp_port: 7881
    port_range_start: 50000
    port_range_end: 60000
    use_external_ip: true
  ```
  (https://docs.livekit.io/transport/self-hosting/deployment.md)
- The VM guide's firewall list also assumes the range: `50000-60000/UDP - WebRTC over UDP`
  (https://docs.livekit.io/transport/self-hosting/vm.md)

The only place LiveKit itself *chooses* single-port is **development mode** (`PortRange{Start: 7882}`),
which the source comments describe as "to make it easier to run in dev mode/docker".

**Practical read for a small production box:** the mux is a legitimate, fully supported production
mode (it is not dev-only), and it makes firewalling trivial. But if you use it, size it to vCPU count
per the sample-config comment rather than pinning a literal single port on a multi-core machine.

---

## 3. `rtc.tcp_port`

Purpose, per ports-firewall doc: *"ICE/TCP … Used when the client could not connect via UDP (e.g. VPN, corporate firewalls)"*. Default **7881**.

**Yes, it is a single multiplexed port.** From `webrtc_config.go`:

```go
if rtcConf.TCPPort != 0 {
	networkTypes = append(networkTypes, webrtc.NetworkTypeTCP4, webrtc.NetworkTypeTCP6)
	tcpListener, err = net.ListenTCP("tcp", &net.TCPAddr{ Port: int(rtcConf.TCPPort) })
	...
	tcpMux := ice.NewTCPMuxDefault(ice.TCPMuxParams{ Listener: tcpListener, ... })
	s.SetICETCPMux(tcpMux)
}
```

One listener, one `ice.TCPMuxDefault`, all participants. Type is `uint32`, a plain single port — **not**
a `PortRange` (contrast with `udp_port`).

Deployment constraints from `config-sample.yaml`:
> `# this port *cannot* be behind load balancer or TLS, and must be exposed on the node`
> `# WebRTC transports are encrypted and do not require additional encryption`
> `# only 80/443 on public IP are allowed if less than 1024`

Also note `s.SetICEUDPMux` and the TCP listener bind to **all interfaces** — `net.ListenTCP` is given
only a `Port`, no `IP`. Top-level `bind_addresses` does **not** constrain the RTC ports (see Q5).

---

## 4. UDP port consumption per participant in port-RANGE mode

**Documented answer: 2 ports per participant.** From the ports-firewall doc table, `ICE/UDP` row:

> *"LiveKit advertises these ports as WebRTC host candidates (**each participant in the room will use two ports**)"*

https://docs.livekit.io/transport/self-hosting/ports-firewall.md

So it is **per PeerConnection**, not per track — LiveKit uses two PeerConnections per participant
(publisher + subscriber), which is why the count is two. **The "two ports = two PeerConnections"
causal explanation is my inference; only the "two ports per participant" number is doc-cited.**
Ports are not per-track: many tracks are bundled onto one PeerConnection/socket.

**Sizing:** the default 50000–60000 gives 10,001 ports ≈ **~5,000 concurrent participants per node**,
which is far beyond what a single node's CPU/bandwidth will sustain anyway. The port range is
effectively never the binding constraint. Ports are released on disconnect but not instantly reusable
in practice (ICE teardown), so keep generous headroom.

I found **no** official formula beyond the "two ports" statement. Any more precise per-track or
per-transceiver claim would be **UNVERIFIED**.

In **mux mode**, port consumption is constant (`min(len(udp_port range), NumCPU)`) and independent
of participant count.

---

## 5. Exact YAML key names and nesting

All confirmed from `yaml:"..."` struct tags.

### Top-level (`pkg/config/config.go`, `type Config struct`)

| Key | Go type | Default | Tag source |
|---|---|---|---|
| `port` | `uint32` | **7880** | `Port uint32 \`yaml:"port,omitempty"\`` |
| `bind_addresses` | `[]string` | nil (→ all interfaces) | `BindAddresses []string \`yaml:"bind_addresses,omitempty"\`` |
| `keys` | `map[string]string` | `{}` | `Keys map[string]string \`yaml:"keys,omitempty"\`` |
| `key_file` | `string` | `""` | `KeyFile string \`yaml:"key_file,omitempty"\`` |
| `development` | `bool` | `false` | `Development bool \`yaml:"development,omitempty"\`` |
| `log_level` | `string` | `""` | **DEPRECATED** — see below |
| `logging` | struct | — | `Logging LoggingConfig \`yaml:"logging,omitempty"\`` |
| `region` | `string` | `""` | `Region string \`yaml:"region,omitempty"\`` |
| `prometheus_port` | `uint32` | 0 | **DEPRECATED** → use `prometheus.port` |

### Nested under `rtc:` (inlined from `rtcconfig.RTCConfig`)

| Key | Go type | Default |
|---|---|---|
| `rtc.tcp_port` | `uint32` | **7881** |
| `rtc.udp_port` | **`PortRange`** (int or `"a-b"`) | 0 (7882 if `development: true`) |
| `rtc.port_range_start` | `uint32` | 0 → **50000** via `Validate()` |
| `rtc.port_range_end` | `uint32` | 0 → **60000** via `Validate()` |
| `rtc.use_external_ip` | `bool` | **`false`** |

⚠️ `use_external_ip` is tagged **`yaml:"use_external_ip"` without `omitempty`**, unlike nearly every
other field. Harmless for reading; it just means it's always emitted when marshalling.

⚠️ **Default for `use_external_ip` is `false`**, but `config-sample.yaml` shows `use_external_ip: true`
and the deployment doc recommends `true` for cloud hosts. On a cloud VM with a NAT'd public IP you
**must** set it explicitly to `true` — or set `rtc.node_ip` — or ICE candidates will advertise the
private IP and no remote client will connect. Not a doc/source conflict; the sample is a
recommendation, the struct default is conservative.

### Nested under `turn:` (`type TURNConfig struct`)

| Key | Go type | Default |
|---|---|---|
| `turn.enabled` | `bool` | `false` |
| `turn.domain` | `string` | `""` |
| `turn.tls_port` | `int` | 0 |
| `turn.udp_port` | `int` (**plain int**, not PortRange) | 0 |
| `turn.external_tls` | `bool` | `false` |
| `turn.cert_file` | `string` | `""` |
| `turn.key_file` | `string` | `""` |
| `turn.bind_addresses` | `[]string` | `["0.0.0.0"]` |
| `turn.relay_range_start` | `uint16` | **30000** |
| `turn.relay_range_end` | `uint16` | **40000** (30002 in dev) |
| `turn.ttl_seconds` | `int` | 300 |
| `turn.per_user_relay_allocation_limit` | `int` | 12 |

Note the relay keys are `relay_range_start`/`relay_range_end` — **not** `relay_port_range_start`
(the Go field names are `RelayPortRangeStart`/`RelayPortRangeEnd`, which is a trap).

### Logging level — BOTH forms exist

```go
// Deprecated: LogLevel is deprecated
LogLevel string        `yaml:"log_level,omitempty"`
Logging  LoggingConfig `yaml:"logging,omitempty"`
```

`LoggingConfig` embeds `logger.Config` inline (from `github.com/livekit/protocol`), so the level key is
`logging.level`:

```go
type LoggingConfig struct {
	logger.Config `yaml:",inline"`
	PionLevel     string `yaml:"pion_level,omitempty"`
}
```

Precedence in `NewConfig`, explicit:

```go
if conf.LogLevel != "" {
	conf.Logging.Level = conf.LogLevel
}
if conf.Logging.Level == "" && conf.Development {
	conf.Logging.Level = "debug"
}
```

**Top-level `log_level` overrides `logging.level` when non-empty**, despite being deprecated.
**Recommendation: use `logging.level: info`.** Do not set both. Valid values per `config-sample.yaml`:
`debug, info, warn, error`. Sibling keys: `logging.pion_level` (default `"error"`), `logging.json`,
`logging.sample`.

⚠️ Note the deployment doc's recommended production config uses the **deprecated** `log_level: info`
form. It still works; prefer `logging.level`.

### `development` flag — exact effects

`development: true` (or CLI `--dev`) changes behavior in five concrete places:

1. **Default UDP mode** — single port 7882 instead of range 50000–60000 (`rtcconfig/config.go Validate`).
2. **TURN relay range** — 30000–30002 instead of 30000–40000 (`config.go NewConfig`).
3. **Log level** — defaults to `debug` when otherwise unset.
4. **API secret length check disabled** — `ValidateKeys()`:
   ```go
   if !conf.Development {
       for key, secret := range conf.Keys {
           if len(secret) < 32 {
               logger.Errorw("secret is too short, should be at least 32 characters for security", nil, "apiKey", key)
           }
       }
   }
   ```
5. **pprof/debug handlers mounted on the PUBLIC signalling port** (`pkg/service/server.go`):
   ```go
   mux := http.NewServeMux()
   if conf.Development {
       // pprof handlers are registered onto DefaultServeMux
       mux = http.DefaultServeMux
       mux.HandleFunc("/debug/goroutine", s.debugGoroutines)
       mux.HandleFunc("/debug/rooms", s.debugInfo)
   }
   ```
   It also skips the UDP receive-buffer check (`if !development { checkUDPReadBuffer() }`).

**🔴 Do NOT set `development: true` in production.** Effect 5 exposes unauthenticated `/debug/pprof/*`,
`/debug/goroutine`, and `/debug/rooms` on port 7880 — the auth middleware does not gate them (Q7).
For profiling in production, use the dedicated `debug_handler.port` instead (see note in Q7).

---

## 6. Built-in TURN with `tls_port` — certs and `external_tls`

All from `pkg/service/turn.go`, `NewTurnServer()`.

### `external_tls` semantics — confirmed exactly as hypothesized

```go
if turnConf.TLSPort > 0 {
	var listener net.Listener
	var listenerErr error

	if turnConf.ExternalTLS {
		listener, listenerErr = net.Listen("tcp", net.JoinHostPort(addr, strconv.Itoa(turnConf.TLSPort)))
	} else {
		cert, err := tls.LoadX509KeyPair(turnConf.CertFile, turnConf.KeyFile)
		if err != nil {
			return nil, errors.Wrap(err, "TURN tls cert required")
		}

		listener, listenerErr = tls.Listen("tcp", net.JoinHostPort(addr, strconv.Itoa(turnConf.TLSPort)),
			&tls.Config{
				MinVersion:   tls.VersionTLS12,
				Certificates: []tls.Certificate{cert},
			})
	}
```

- **`external_tls: true`** → `net.Listen` = **plaintext TCP** listener. TLS is terminated upstream by an
  L4 LB / proxy. LiveKit still advertises `tls_port` to clients as a TURN/TLS (`turns:`) candidate.
  **No cert is loaded or required.** Confirmed by `config-sample.yaml`:
  > `# set external_tls to true if using a L4 load balancer to terminate TLS. when enabled,`
  > `# LiveKit expects unencrypted traffic on tls_port, and still advertise tls_port as a TURN/TLS candidate.`
- **`external_tls: false`** (default) → LiveKit terminates TLS itself, **TLS 1.2 minimum**.

### `turn.cert_file` / `turn.key_file` — YES, they exist

```go
type TURNConfig struct {
	Enabled  bool   `yaml:"enabled,omitempty"`
	Domain   string `yaml:"domain,omitempty"`
	CertFile string `yaml:"cert_file,omitempty"`
	KeyFile  string `yaml:"key_file,omitempty"`
	...
```

### How the cert is obtained when `external_tls: false`

**Only from files you supply — `tls.LoadX509KeyPair(turnConf.CertFile, turnConf.KeyFile)`.
LiveKit has NO ACME/Let's Encrypt client and does NOT auto-provision certs.** Three supply routes,
per `config-sample.yaml`:

> `# Uses TLS. Requires cert and key pem files by either:`
> `# - using turn.secretName if deploying with our helm chart, or`
> `# - setting LIVEKIT_TURN_CERT and LIVEKIT_TURN_KEY env vars with file locations, or`
> `# - using cert_file and key_file below`

The env-var route is wired through CLI flags in `config.go updateFromCLI`:
```go
if c.IsSet("turn-cert") { conf.TURN.CertFile = c.String("turn-cert") }
if c.IsSet("turn-key")  { conf.TURN.KeyFile  = c.String("turn-key") }
```

The VM/docker-compose deployment path avoids this entirely by having **Caddy** obtain certs
(Let's Encrypt/ZeroSSL) and terminate TLS — i.e. it is an `external_tls: true` arrangement.
(https://docs.livekit.io/transport/self-hosting/vm.md)

### Startup validation (fail-fast — relevant for unattended boot)

```go
if turnConf.TLSPort <= 0 && turnConf.UDPPort <= 0 {
	return nil, errors.New("invalid TURN ports")
} else if turnConf.TLSPort > 0 {
	if turnConf.Domain == "" {
		return nil, errors.New("TURN domain required")
	}
	if !IsValidDomain(turnConf.Domain) {
		return nil, errors.New("TURN domain is not correct")
	}
}
```

With `turn.enabled: true` and any `tls_port`, **`turn.domain` is mandatory and must be a valid domain**,
or the process exits at startup. And with `external_tls: false`, a missing/unreadable cert is a hard
startup failure (`"TURN tls cert required"`).

**🔴 Additional hard startup requirement:** the TURN relay address generator requires a resolved node IP:
```go
var nodeIP string
if net.ParseIP(addr).To4() != nil { nodeIP = conf.RTC.NodeIP.V4 } else { nodeIP = conf.RTC.NodeIP.V6 }
if nodeIP == "" {
	return nil, errors.New("no matching node IP for relay")
}
```
Default `turn.bind_addresses` is `["0.0.0.0"]` (IPv4), so **an IPv4 node IP must resolve** — via
`use_external_ip: true` (STUN) or explicit `rtc.node_ip`. On a box where STUN discovery fails, TURN
startup fails. Relevant for an unattended production box.

### Port guidance (docs)

- `tls_port` default 5349; **must be 443 if not behind a load balancer**, since that's what's advertised to clients (deployment doc + config-sample).
- `udp_port` default 3478; 443 is useful where firewalls pass QUIC. Sample notes `# only 53/80/443 are allowed if less than 1024`.
- TURN/UDP, when enabled, **also serves as a STUN server** (ports-firewall doc).

⚠️ **Doc inconsistency:** the deployment doc's recommended production YAML sets `tls_port: 3478`
with the comment *"defaults to 3478. If not using a load balancer, must be set to 443."* — 3478 is the
**UDP** default, not the TLS default (5349). That snippet conflates the two. Treat the deployment-doc
TURN block as unreliable; use `config-sample.yaml` values.

---

## 7. Health / readiness HTTP endpoint

**Yes. The exact path is `/` (bare root) on the main HTTP port.** There is **no** `/healthz`.

Route registration, `pkg/service/server.go` (registration order matters — `/` is the catch-all, registered last):

```go
xtwirp.RegisterServer(mux, roomServer)
...
rtcService.SetupRoutes(mux)
whipService.SetupRoutes(mux)
mux.Handle("/agent", agentService)
mux.HandleFunc("/", s.defaultHandler)
```

```go
func (s *LivekitServer) defaultHandler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/" {
		s.healthCheck(w, r)
	} else {
		http.NotFound(w, r)
	}
}

func (s *LivekitServer) healthCheck(w http.ResponseWriter, _ *http.Request) {
	var updatedAt time.Time
	if s.Node().Stats != nil {
		updatedAt = time.Unix(s.Node().Stats.UpdatedAt, 0)
	}
	if time.Since(updatedAt) > 4*time.Second {
		w.WriteHeader(http.StatusNotAcceptable)
		_, _ = fmt.Fprintf(w, "Not Ready\nNode Updated At %s", updatedAt)
		return
	}

	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("OK"))
}
```

### Unauthenticated GET `/` — exact responses

- **Healthy:** `200 OK`, body exactly `OK` (2 bytes, no trailing newline).
- **Unhealthy/stale:** `406 Not Acceptable`, body `Not Ready\nNode Updated At <timestamp>`.
  Note **406**, not 503 — configure your monitor/LB accordingly.

**It is genuinely unauthenticated.** `APIKeyAuthMiddleware.ServeHTTP` (`pkg/service/auth.go`) only
rejects a request that presents a *malformed* `Authorization` header or a *bad* token. With **no**
credentials at all, `authToken` is `""`, the `if authToken != ""` block is skipped entirely, and it
calls `next.ServeHTTP(w, r)`. Confirmed: no token → passes through → health check runs.

It is a **readiness** check, not just liveness: it asserts node stats were refreshed within the last
4 seconds. Default `node_stats.stats_update_interval` is `2 * time.Second`, so a healthy node has
~2s of margin.

**🔴 Windows caveat — verify before relying on this.** `server.go` logs at startup:
```go
if runtime.GOOS == "windows" {
	logger.Infow("Windows detected, capacity management is unavailable")
}
```
If stats are not updated on Windows, `/` could return 406 permanently. **I did not trace the
Windows stats path — whether `/` works as a health check on Windows is UNVERIFIED.** On Linux
(the normal production target) this is a non-issue. Flagging because the authoring workstation
for this task is Windows; confirm against the actual deployment OS.

### Other paths (for completeness)

- `/rtc/validate` and `/rtc/v1/validate` — **NOT** health endpoints. They require a valid token;
  unauthenticated they return `401` (`validateInternal` → `if claims := GetGrants(...); claims == nil ... return http.StatusUnauthorized`). On success body is `success`.
- `/debug/pprof/*`, `/debug/goroutine`, `/debug/rooms` — served on a **separate** port only when
  `debug_handler.port` is set, and **unauthenticated**. Under `development: true` they land on the
  public 7880 instead. Do not expose either.
- ⚠️ **`config-sample.yaml` has a bug here.** It documents the key as:
  ```yaml
  # debug_handler_port:
  #   port: 7070
  ```
  but the struct tag is `DebugHandler DebugHandlerConfig \`yaml:"debug_handler,omitempty"\``. The
  correct key is **`debug_handler.port`**. `debug_handler_port` would be silently ignored — or, under
  strict mode (`decoder.KnownFields(strictMode)`), rejected. Source wins.
- Prometheus metrics are on their own port via `prometheus.port` (deprecated: `prometheus_port`), default `:6789/metrics`. Optional basic auth via `prometheus.username`/`prometheus.password` — **set both or neither**, or startup fails:
  ```go
  logger.Warnw("prometheus username or password is set but not both, set both or nothing for unauthenticated access", nil)
  err = errors.New("prometheus username or password is set but not both, ...")
  ```

---

## 8. Default HTTP/WebSocket port and signaling path

**Default port: 7880.** `DefaultConfig = Config{ Port: 7880, ... }`, corroborated by `config-sample.yaml`
(`port: 7880`) and the ports-firewall doc table.

**Signaling path: `/rtc`** (WebSocket upgrade). From `pkg/service/rtcservice.go`:

```go
func (s *RTCService) SetupRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/rtc", s.v0)
	mux.HandleFunc("/rtc/validate", s.v0Validate)
	mux.HandleFunc("/rtc/v1", s.v1)
	mux.HandleFunc("/rtc/v1/validate", s.v1Validate)
}
```

- `/rtc` — v0 signaling, what current SDKs use.
- `/rtc/v1` — newer variant requiring a `join_request` parameter (`needsJoinRequest=true`).

Non-WebSocket requests to `/rtc` get a bare **404**:
```go
if !websocket.IsWebSocketUpgrade(r) {
	w.WriteHeader(404)
	return
}
```

Clients are given the **base** URL (`wss://livekit.yourhost.com`) — the SDK appends `/rtc` itself.
The deployment doc shows `wss://livekit.yourhost.com` as the client endpoint.

Auth for signaling: token via `Authorization: Bearer <jwt>` header **or** `access_token` query param
(`accessTokenParam = "access_token"` in `auth.go`) — the latter is how browsers authenticate a WebSocket.

Other routes on 7880: Twirp APIs (RoomService, AgentDispatch, Egress, Ingress, SIP), `/agent`, WHIP
routes, and `/` (health). CORS is wide open by design — `AllowOriginFunc` returns `true` unconditionally;
`server.go` comments *"CORS is allowed, we rely on token authentication to prevent improper use"*.

---

## Summary of doc↔source conflicts (source preferred in all cases)

| # | Claim | Docs say | Source says |
|---|---|---|---|
| 1 | `udp_port` vs `port_range_*` precedence | ports-firewall: "When [udp_port] is set, rtc.port_range_start/end are not used" | **Opposite.** `if ICEPortRangeStart != 0 && ICEPortRangeEnd != 0 { range } else if UDPPort.Valid() { mux }` — range wins. `config-sample.yaml` agrees with source. |
| 2 | `turn.tls_port` default | deployment doc sample: `tls_port: 3478` / "defaults to 3478" | 5349 is the TLS default; 3478 is the **UDP** default. deployment doc conflates them. |
| 3 | debug handler key | `config-sample.yaml`: `debug_handler_port:` | Struct tag is `debug_handler`, with nested `port`. |
| 4 | log level key | deployment doc uses `log_level: info` | `log_level` is explicitly marked `// Deprecated`. Use `logging.level`. |

## Items marked UNVERIFIED

1. **Official recommendation of single-port mux for small/self-hosted deployments** — no such
   guidance found. Sample config leans the other way (size ports to vCPU count).
2. **Per-participant port count mechanism** — the "two ports" figure is doc-cited; the
   "because there are two PeerConnections" explanation is inference, not quoted.
3. **Health endpoint `/` behavior on Windows** — the "capacity management is unavailable" log
   suggests node stats may not update, which would make `/` return 406 permanently. Not traced.
