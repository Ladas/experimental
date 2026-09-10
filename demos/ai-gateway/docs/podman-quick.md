# The dashboards, without a checkout

Posture 2 of the [quickstart](quickstart.md), in full. No checkout, no
scripts: every config the stack needs is inside the gateway image, so the only
thing you download is the image.

> **Not yet on a published image.** The demo assets below land with this PR, and
> the published `:main` also predates the `token_rate_limit` cargo feature the
> demo needs. Until a build with both is pushed, produce the image yourself —
> from a checkout, `podman build --build-arg FEATURES=otel -t
> praxis-experimental:ai-gw -f Containerfile .` — and prefix the commands below
> with `PRAXIS_IMAGE=praxis-experimental:ai-gw`.

> **This bootstrap will get shorter.** `podman cp` is the standard way to take a
> file out of an image and works offline against the exact image you pulled, so
> the compose file can never disagree with it. Once there is a release, the
> primary form becomes a single `curl` of a release asset — the shape Immich uses
> and the de-facto standard for a no-clone compose stack — and a published OCI
> compose artifact would make it `podman compose -f oci://… up -d` with no local
> file at all.

## Prerequisites

- **podman** or docker
- **a model.** Either Ollama on this machine, or an API key for OpenAI,
  Anthropic or OpenRouter

## Run it

```bash
podman pull ghcr.io/praxis-proxy/experimental:main
id=$(podman create ghcr.io/praxis-proxy/experimental:main)
podman cp "$id:/usr/share/praxis/demo/compose.yaml" compose.yaml
podman rm "$id"
podman compose up -d
```

That is the whole thing. It defaults to Ollama on `localhost:11434` with
`qwen3.5:0.8b`; `ollama pull qwen3.5:0.8b` first if you do not have it.

For a hosted provider instead, name it and pass its key:

```bash
PRAXIS_PROVIDER=openai OPENAI_API_KEY=sk-... podman compose up -d
```

`openai`, `anthropic` and `openrouter` all work. The key stays in the gateway's
environment; it is not written to disk and never reaches your coding agent.

## Look at it

| | |
| --- | --- |
| Perses | <http://localhost:8081> |
| — overview | <http://localhost:8081/projects/praxis/dashboards/ai-gateway-overview> |
| — token budget | <http://localhost:8081/projects/praxis/dashboards/token-budget> |
| — filter latency | <http://localhost:8081/projects/praxis/dashboards/filter-latency> |
| — traces | <http://localhost:8081/projects/praxis/dashboards/traces> |
| gateway | <http://localhost:8080> |
| Prometheus | <http://localhost:9090> |

All four dashboards are provisioned from the image, so they always match the
binary they describe.

## Point a coding agent at it

Claude Code needs nothing but environment:

```bash
ANTHROPIC_BASE_URL=http://localhost:8080 \
ANTHROPIC_AUTH_TOKEN=dummy \
ANTHROPIC_MODEL=qwen3.8:27b \
  claude
```

The dummy is deliberate: the gateway strips it and substitutes its own key.
Codex and opencode need a provider block first, and one session can produce
several model names — **[coding-agents.md](coding-agents.md)** covers all three.

## Stop

```bash
podman compose down -v
```

---

<details>
<summary>How it works, and why there is nothing to mount</summary>

The image carries about 130 KB of demo assets under `/usr/share/praxis/demo`:
the four provider configs, the Tempo, Prometheus and collector configs, and the
Perses config, project, dashboards and datasources.

A one-shot `seed` service copies them into named volumes that the other services
mount, then exits. Nothing bind-mounts a path from your disk, which is what
removes the checkout — and it means the dashboards cannot drift from the gateway
version, because they ship together.

The seed runs as root only because a fresh named volume is root-owned; every
other container runs unprivileged.

</details>

<details>
<summary>Changing provider, and using docker</summary>

The seed only runs once and the volumes persist, so switching provider means
clearing them:

```bash
podman compose down -v
PRAXIS_PROVIDER=anthropic ANTHROPIC_API_KEY=sk-ant-... podman compose up -d
```

If the stack refuses to start, `podman compose logs seed` names the reason — an
unknown provider is the usual one, and it prints the valid names.

Every command here works with `docker` — swap the binary, nothing else changes.

Ports are overridable: `GATEWAY_PORT`, `ADMIN_PORT`, `PERSES_PORT`,
`PROMETHEUS_PORT`, `TEMPO_PORT`.

</details>

<details>
<summary>When you want to change things</summary>

This path is for trying the gateway. To edit a config, add a provider, run the
verification suite or deploy to Kubernetes, use the developer flow instead:
**[podman.md](podman.md)** and **[kind.md](kind.md)**.

</details>
