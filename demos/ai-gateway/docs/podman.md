# Run the demo on podman

Five containers, no Kubernetes, about 250 MB. Seconds to start. Every command
below also exists as `./demo-docker`, which is the same script on docker.

This is the laptop-with-dashboards posture. Running the gateway anywhere other
people can reach changes what you should turn on: see
[quickstart.md](quickstart.md).

## 1. Start it

```bash
cd demos/ai-gateway
./demo-podman up ollama
```

Swap `ollama` for `openai`, `anthropic` or `openrouter`. The first run builds
the image, and the Ollama path pulls a 0.5 GB model.

A hosted provider asks for its key once and puts it in your **OS keychain**,
never in this repository.

<details>
<summary>The same thing by hand</summary>

```bash
cd demos/ai-gateway
podman build --build-arg FEATURES=otel -t praxis-experimental:ai-gw \
  -f ../../Containerfile ../..

ollama pull qwen3.5:0.8b                    # ollama only
export OPENAI_API_KEY=sk-...                # hosted only

cd compose && PRAXIS_PROVIDER=ollama podman compose up -d
```

`PRAXIS_PROVIDER` picks `configs/<name>.yaml`. Provider keys reach the gateway
from the environment compose runs in. On native Linux docker also pass
`-f compose.yaml -f compose.linux.yaml`.

</details>

## 2. Check it

```bash
./demo-podman verify
```

Seven checks, ending in `all checks passed`: the gateway serves a chat, refuses
the free tier once its budget is spent, leaves premium alone, traces to Tempo
and is scraped by Prometheus. The budget probe floods the gateway, so it is
skipped for hosted providers, which bill per admitted request.

## 3. Open the dashboards

| | |
| --- | --- |
| Perses | <http://localhost:8081> |
| — overview | <http://localhost:8081/projects/praxis/dashboards/ai-gateway-overview> |
| — token budget | <http://localhost:8081/projects/praxis/dashboards/token-budget> |
| — filter latency | <http://localhost:8081/projects/praxis/dashboards/filter-latency> |
| — traces | <http://localhost:8081/projects/praxis/dashboards/traces> |
| Prometheus | <http://localhost:9090> |
| gateway `/metrics` | <http://localhost:9901/metrics> |

Click a row in **Recent Traces** for its span waterfall. For more traffic first:
`GATEWAY=http://localhost:8080 ./scripts/rate-limit-demo.sh`.

## 4. Point a coding agent at it

Claude Code needs nothing but environment:

```bash
ANTHROPIC_BASE_URL=http://localhost:8080 \
ANTHROPIC_AUTH_TOKEN=dummy \
ANTHROPIC_MODEL=qwen3.8:27b \
  claude
```

The dummy is deliberate: the gateway strips it and substitutes its own, so the
agent never holds the real key.

Codex and opencode need a provider block first, and one session can produce
several model names, each wanting its own budget rule.
**[coding-agents.md](coding-agents.md)** covers all three.

## 5. Stop

```bash
./demo-podman down
```

---

<details>
<summary>Ports, and running both targets at once</summary>

All overridable, because the KIND target holds host ports too:

| | default | override |
| --- | --- | --- |
| gateway | 8080 | `GATEWAY_PORT` |
| admin and `/metrics` | 9901 | `ADMIN_PORT` |
| Perses | 8081 | `PERSES_PORT` |
| Prometheus | 9090 | `PROMETHEUS_PORT` |
| Tempo | 3200 | `TEMPO_PORT` |

`./demo-podman` reads the same variables, so `GATEWAY_PORT=18080 ./demo-podman
up ollama` moves the gateway and the printed links together.

</details>

<details>
<summary>Where the API key is stored</summary>

In order of preference, and nothing is ever written inside this repository:

1. **Already exported** — used as-is, never stored.
2. **OS keychain** — macOS Keychain, or libsecret on Linux.
3. **`$XDG_CONFIG_HOME/praxis-ai-gateway/env`**, mode 600, when neither exists.

`DEMO_CRED_BACKEND=file` forces the third. The key is passed to the gateway
container and nothing else, and the gateway strips whatever credential the
client sent before substituting it.

</details>

<details>
<summary>podman or docker, and reaching Ollama on the host</summary>

`./demo-docker` is a two-line wrapper that runs `./demo-podman` with the engine
set. The engine is never guessed from what happens to be installed: on a machine
with both, starting the stack on one and looking for it on the other is a
frustrating ten minutes. Both drive the same compose project, so pick one and
stay with it for a given stack.

On macOS `podman compose` delegates to the installed provider, so the full
compose spec applies — the Python `podman-compose` reimplementation has known
gaps and is not tested here. `podman build` produces an OCI image, which has no
`HEALTHCHECK` field; nothing here needs one, but `--format docker` restores
parity.

Containers resolve `host.docker.internal` natively on podman, Docker Desktop and
Rancher Desktop. Native Linux docker does not, which is what
`compose.linux.yaml` is for. **Do not** fold that entry into `compose.yaml`: on
Rancher Desktop it resolves to the VM instead of the host and the gateway
answers 502.

Ollama stays on its default `127.0.0.1` binding throughout.

</details>

<details>
<summary>Why the OTel collector is pinned to 0.108.0</summary>

To match the KIND target. From 0.123.0 it renames its self-metrics and replaces
`telemetry.metrics.address` with a `readers` array, either of which blanks the
export-health panels on one target only. Upgrade both together or not at all.

</details>
