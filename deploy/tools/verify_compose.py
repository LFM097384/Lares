"""Offline validation of deploy/docker-compose.yml.

Not part of the deployment. Emulates docker compose interpolation so we can
check the rendered LiveKit config and the port bindings without a Docker daemon.
"""
import re
import sys
import yaml

RAW = open("docker-compose.yml", encoding="utf-8").read()
DOC = yaml.safe_load(RAW)

# Values a real .env would provide.
ENV = {
    "LIVEKIT_API_KEY": "testkey",
    "LIVEKIT_API_SECRET": "testsecret",
    "LARES_DOMAIN": "rtc.example.org",
    "LIVEKIT_PUBLIC_URL": "wss://rtc.example.org:8444",
    "LARES_AUTH_MODE": "circle",
    "LARES_TLS_MODE": "dns",
}

VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*)|:\?([^}]*))?\}")


def interpolate(text, env):
    missing = []

    def sub(m):
        name, _, default, required = m.groups()
        if name in env and env[name] != "":
            return env[name]
        if default is not None:
            return default
        if required is not None:
            missing.append((name, required))
            return "<<MISSING>>"
        return ""

    return VAR.sub(sub, text), missing


problems = []

# ── 1. LiveKit config renders to valid YAML with the right semantics ──────────
content = DOC["configs"]["livekit_config"]["content"]
rendered, missing = interpolate(content, ENV)
if missing:
    problems.append(f"livekit config missing required vars: {missing}")

cfg = yaml.safe_load(rendered)
rtc = cfg["rtc"]

# THE critical one: LiveKit source checks port_range_* FIRST; if either is
# present the udp_port mux is silently ignored.
if "port_range_start" in rtc or "port_range_end" in rtc:
    problems.append("FATAL: port_range_* present -> udp_port mux silently ignored")

if not isinstance(rtc["udp_port"], int):
    problems.append(f"udp_port not an int after interpolation: {rtc['udp_port']!r}")
if not isinstance(rtc["tcp_port"], int):
    problems.append(f"tcp_port not an int: {rtc['tcp_port']!r}")
if rtc.get("use_external_ip") is not True:
    problems.append(f"use_external_ip should be True, got {rtc.get('use_external_ip')!r}")
if cfg["turn"]["enabled"] is not False:
    problems.append(f"turn.enabled should be bool False, got {cfg['turn']['enabled']!r}")
if not isinstance(cfg["room"]["max_participants"], int):
    problems.append("max_participants did not render as int")
if "log_level" in cfg:
    problems.append("deprecated top-level log_level present (overrides logging.level)")
if cfg["keys"] != {"testkey": "testsecret"}:
    problems.append(f"keys did not interpolate: {cfg['keys']!r}")

# A literal '$' in configs.content is interpolated by compose and would be
# silently blanked unless written '$$'.
leftover = [m for m in re.findall(r"\$(?!\{)", content)]
if leftover:
    problems.append(f"literal $ in configs.content must be escaped as $$: {len(leftover)}")

# ── 2. No service may bind the proxy's ports ─────────────────────────────────
OCCUPIED = {"443/tcp", "8443/tcp", "3443/udp", "9721/tcp", "2096/tcp", "22/tcp"}
bound = []
for name, svc in DOC["services"].items():
    for spec in svc.get("ports", []) or []:
        text, _ = interpolate(str(spec), ENV)
        proto = "udp" if text.endswith("/udp") else "tcp"
        text = text.replace("/udp", "").replace("/tcp", "")
        parts = text.split(":")
        host, container = parts[0], parts[-1]
        bound.append((name, f"{host}/{proto}", host, container))
        if f"{host}/{proto}" in OCCUPIED:
            problems.append(f"FATAL: service {name} binds occupied port {host}/{proto}")
        # LiveKit writes its port into ICE candidates; a host!=container
        # mapping would advertise an unreachable port.
        if host != container:
            problems.append(
                f"service {name}: host port {host} != container port {container}"
            )

print("Host ports bound:")
for name, pp, _, _ in bound:
    print(f"  {pp:<12} {name}")

# ── 3. Required-secret enforcement must exist ────────────────────────────────
for var in ("LARES_AUTH_MODE", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LARES_DOMAIN"):
    if f"${{{var}:?" not in RAW:
        problems.append(f"{var} lacks a :? fail-loud guard")

# ── 4. mem_limit set on every service ────────────────────────────────────────
for name, svc in DOC["services"].items():
    if "mem_limit" not in svc:
        problems.append(f"service {name} has no mem_limit")
    if "deploy" in svc and "mem_limit" in svc:
        problems.append(f"service {name} sets both mem_limit and deploy (conflict risk)")

print()
if problems:
    print("PROBLEMS:")
    for p in problems:
        print("  -", p)
    sys.exit(1)
print("ALL COMPOSE CHECKS PASSED")
