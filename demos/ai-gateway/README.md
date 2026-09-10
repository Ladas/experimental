# AI Gateway demo

A Praxis AI gateway in front of a real model, enforcing per-tier token budgets,
with dashboards built from its own traces. Point a coding agent at it and watch
the requests land.

## Quickstart

**[docs/quickstart.md](docs/quickstart.md)** — pick where you are running it and
follow the steps. Every path uses the published image and needs no checkout:

Two paths, picked by who can reach the port: **your laptop**, where dashboards
and a hosted provider are optional extras, and **a server**, where auth is not
optional. It also has the Claude Code, Codex and opencode blocks.

The laptop path, in full:

```bash
podman run --rm -p 127.0.0.1:8080:8080 \
  ghcr.io/praxis-proxy/experimental:main \
  -c /usr/share/praxis/demo/configs/laptop.yaml
```

## Providers

| | Needs | Wire format |
| --- | --- | --- |
| `ollama` | Ollama running locally. No key, no cost | OpenAI |
| `openai` | `OPENAI_API_KEY` | OpenAI |
| `anthropic` | `ANTHROPIC_API_KEY` | Anthropic `/v1/messages` |
| `openrouter` | `OPENROUTER_API_KEY` | OpenAI |

Pick one with `PRAXIS_PROVIDER` on the demo stack, or `-c` on a bare run. Each
is one file, `configs/<provider>.yaml`,
holding the same filters over a different upstream. Keys reach the gateway only;
your agent authenticates with a dummy the gateway strips and replaces. Adding a
fifth means that config plus its key variable in `scripts/demo-lib.sh` and in
both compose files — see the comment on `providers()`.

Anthropic is the odd one: it is not OpenAI-shaped and praxis does not translate,
so the client has to speak Anthropic too. Claude Code does.

## Developer manuals

For changing configs, adding a provider, running the verification suite, or
deploying to Kubernetes:

| | Good for | Needs | |
| --- | --- | --- | --- |
| **podman**, or docker | editing and re-running quickly | ~1 GB | **[docs/podman.md](docs/podman.md)** |
| **KIND** via forge | closest to a real deployment | ~4 GB | **[docs/kind.md](docs/kind.md)** |

Both come down to two commands, and both can run at once because their ports
differ:

```bash
./demo-podman up ollama && ./demo-podman verify
./demo-kind    up ollama && ./demo-kind    verify
```

[docs/budgets.md](docs/budgets.md) explains the tiers, the reservations and
refunds, how to size a cap that means something, and why the limit only trips
under concurrent load.

---

<details>
<summary>What is running, and why</summary>

| Component | Why it is here |
| --- | --- |
| **praxis** | the gateway under test: budgets requests per tier, routes upstream, emits the traces |
| **the model** | Ollama or a hosted API, so token counts and latencies are real rather than mocked |
| **OTel collector** | what praxis exports spans to. Its own metrics drive the export-health panels, so removing it would blank them |
| **Tempo** | stores traces, and its metrics generator derives the span metrics the latency dashboards query |
| **Prometheus** | scrapes praxis and the collector, and receives Tempo's generated span metrics |
| **Perses** | one UI for both metrics and traces, and the same dashboards work on OpenShift through the Cluster Observability Operator |
| **Grafana** (KIND only) | the original dashboards, kept until the Perses ports are confirmed equivalent |

</details>

<details>
<summary>Resources it needs</summary>

Measured on this stack, idle after a demo run:

| | podman | KIND |
| --- | --- | --- |
| Memory | **~250 MB** across 5 containers | **~2.3 GB** for the node, 19 pods |
| Largest | Tempo 114 MB, Prometheus 46 MB | the kube-prometheus-stack |
| Images | ~850 MB pulled | the above plus the KIND node image |
| Startup | seconds | ~3 minutes, mostly Helm |

Give the container VM **2 GB** for podman and **6 GB** for KIND. Ollama runs on
the host; the demo model is 0.5 GB, and the 27B model the coding-agent examples
use wants about 20 GB.

</details>

<details>
<summary>Where things live</summary>

| Path | What it is |
| --- | --- |
| `compose/compose.quick.yaml` | the checkout-free stack, baked into the image as `/usr/share/praxis/demo/compose.yaml` |
| `demo-podman`, `demo-docker`, `demo-kind` | the developer entry points; `demo-docker` is a wrapper |
| `scripts/demo-lib.sh` | what they share: providers, credentials, image, links |
| `configs/laptop.yaml`, `configs/server.yaml` | ready-to-use defaults per deployment target |
| `configs/<provider>.yaml` | one per provider, for the demo stack |
| `compose/` | the podman target: services, Tempo, Prometheus, Perses |
| `forge.yaml`, `manifests/` | the KIND target: cluster, stacks, Kubernetes objects |
| `observability/perses/` | Perses config, project, dashboards, per-target datasources |
| `scripts/verify.sh` | the checks, for either target |

</details>

## This is a demo configuration

No authentication, an admin endpoint bound to all interfaces, and SSRF guards
relaxed so the gateway can reach a model server on the host. Do not copy it into
anything that faces a network you do not control.
