# Quickstart

Two paths, picked by who can reach the port. Both use the published image and a
config that ships inside it. Nothing to clone, nothing to edit.

## On your laptop

```bash
podman run --rm -p 127.0.0.1:8080:8080 \
  ghcr.io/praxis-proxy/experimental:main \
  -c /usr/share/praxis/demo/configs/laptop.yaml
```

```bash
curl http://localhost:8080/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"qwen3.8:27b","messages":[{"role":"user","content":"say hi"}]}'
```

Fronts Ollama on this machine and enforces a daily token budget. `docker` works
the same.

### Point a coding agent at it

```bash
ANTHROPIC_BASE_URL=http://localhost:8080 ANTHROPIC_AUTH_TOKEN=dummy \
ANTHROPIC_MODEL=qwen3.8:27b claude
```

```bash
cat >> ~/.codex/config.toml <<'EOF'

[model_providers.praxis]
name = "Praxis"
base_url = "http://localhost:8080/v1"
wire_api = "responses"
EOF
codex -c model_provider=praxis --model qwen3.8:27b
```

```bash
mkdir -p ~/.config/opencode && cat > ~/.config/opencode/opencode.json <<'EOF'
{ "$schema": "https://opencode.ai/config.json",
  "provider": { "praxis": { "npm": "@ai-sdk/openai-compatible",
    "options": { "baseURL": "http://localhost:8080/v1" },
    "models": { "qwen3.8:27b": {} } } },
  "model": "praxis/qwen3.8:27b", "small_model": "praxis/qwen3.8:27b" }
EOF
opencode
```

That last one **overwrites** an existing `opencode.json`. More, including why one
session produces several model names: **[coding-agents.md](coding-agents.md)**.

<details>
<summary>Add dashboards</summary>

Three more commands bring up Perses, Tempo, Prometheus and an OTel collector
around the same gateway:

```bash
id=$(podman create ghcr.io/praxis-proxy/experimental:main)
podman cp "$id:/usr/share/praxis/demo/compose.yaml" compose.yaml
podman rm "$id"
podman compose up -d
```

Dashboards on <http://localhost:8081>. Detail:
**[podman-quick.md](podman-quick.md)**, or **[podman.md](podman.md)** from a
checkout, or **[kind.md](kind.md)** on Kubernetes.

This posture sets `allow_public_admin` so Prometheus can scrape from another
container, which also exposes `/api/kv` and `/api/log-level` — praxis has no
metrics-only listener. Fine on your own machine, not on a server.

</details>

<details>
<summary>Use a hosted provider instead of Ollama</summary>

```bash
podman run --rm -p 127.0.0.1:8080:8080 -e OPENAI_API_KEY \
  ghcr.io/praxis-proxy/experimental:main \
  -c /usr/share/praxis/demo/configs/openai.yaml
```

`openai`, `anthropic` and `openrouter` all ship. The key stays in the gateway's
environment; your agent authenticates with a dummy the gateway strips and
replaces.

Anthropic is not OpenAI-shaped and praxis does not translate, so that one needs
an Anthropic-speaking client. Claude Code is one.

</details>

<details>
<summary>What this does not give you</summary>

- **No auth.** `laptop.yaml` has none, which is why the port is bound to
  `127.0.0.1`. Use `-p 8080:8080` and anyone on your network can spend your
  budget.
- **No dashboard by default.** Counters only, and from inside the container:
  `podman exec <container> curl -s http://127.0.0.1:9901/metrics`.
- **One budget for everyone.** Rules match request headers, not callers.
- **No response-path guardrails** (ai#580). Request-path callouts work.

</details>

## On a RHEL server

```bash
export PRAXIS_AUTH_PASSWORD=... OPENAI_API_KEY=sk-...
podman run -d --name praxis -p 8080:8080 \
  -e PRAXIS_AUTH_PASSWORD -e OPENAI_API_KEY \
  -e OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4317 \
  ghcr.io/praxis-proxy/experimental:main \
  -c /usr/share/praxis/demo/configs/server.yaml
```

```bash
curl -u praxis:$PRAXIS_AUTH_PASSWORD http://localhost:8080/v1/models
```

`server.yaml` differs from `laptop.yaml` only in what the exposed port forces:
auth is on, the upstream is OpenAI over TLS, and the daily cap is sized for about
$50 a month. It **refuses to start** without `PRAXIS_AUTH_PASSWORD` rather than
running open.

Admin stays on loopback. Scrape `127.0.0.1:9901` with a collector agent on the
host — the same one `OTEL_EXPORTER_OTLP_ENDPOINT` points at — rather than
exposing it.

Two different 401s will reach you, and the realm tells them apart:
`WWW-Authenticate: Basic realm="Praxis"` is the gateway refusing you, while
`Bearer realm="OpenAI API"` means you got through and the provider key is wrong.

<details>
<summary>Run it as a systemd service</summary>

`/etc/containers/systemd/praxis.container`, the RHEL-native way:

```ini
[Unit]
Description=Praxis AI gateway
After=network-online.target

[Container]
Image=ghcr.io/praxis-proxy/experimental:main
Exec=-c /usr/share/praxis/demo/configs/server.yaml
PublishPort=8080:8080
EnvironmentFile=/etc/praxis/secrets.env
Environment=OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4317

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
install -m 600 /dev/null /etc/praxis/secrets.env   # then put the two keys in it
systemctl daemon-reload && systemctl start praxis
```

Secrets go in that file, mode 600 and root-owned, not in the unit — unit files
are world-readable. To change the config rather than the defaults, copy it out
with `podman cp` and mount your own over
`/usr/share/praxis/demo/configs/server.yaml`.

</details>

<details>
<summary>What is still missing for production</summary>

- **`basic_auth` is an experimental filter** and says so on startup: it stores
  credentials in plaintext and is not suitable for production. It is a gate
  against strangers, not a user directory.
- **No TLS on the listener.** Terminate in front of it, or add a `tls:` block.
  Without it, basic-auth credentials cross the network in base64.
- **Auth publishes no identity.** `basic_auth` says who you are but budget rules
  match headers, so every authenticated caller shares the rule they match.
  Per-key budgets are deferred upstream.
- **No response-path guardrails** (ai#580).
- **Keys are read once at startup**, so rotating one means a restart.
- **One process, one budget.** `backend: memory` is per-process; sharing across
  replicas needs the `valkey` backend and therefore Valkey.

</details>

## More

**[budgets.md](budgets.md)** sizing a cap · **[coding-agents.md](coding-agents.md)**
harnesses · **[podman.md](podman.md)** and **[kind.md](kind.md)** the demo stacks
