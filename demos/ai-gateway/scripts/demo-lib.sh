#!/usr/bin/env bash
# Shared by ../demo-podman and ../demo-kind. Not executable on its own.
#
# Everything here is the part that does not depend on the target: which
# providers exist, where their keys live, building the image, checking Ollama,
# and printing links. The two entry points hold only their own orchestration.
#
# Callers must have `set -euo pipefail` and must have cd'd to the demo root.

IMAGE="${PRAXIS_IMAGE:-praxis-experimental:ai-gw}"
OLLAMA_MODEL="qwen3.5:0.8b"

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

# provider -> the environment variable holding its key; blank means none.
#
# Adding a provider is four edits, not one: configs/<name>.yaml, a line here, and
# the key passthrough in BOTH compose/compose.yaml and compose/compose.quick.yaml
# -- compose only forwards variables it names, so a key missing from either file
# silently never reaches the gateway.
providers() {
  cat <<'LIST'
ollama
openai OPENAI_API_KEY
anthropic ANTHROPIC_API_KEY
openrouter OPENROUTER_API_KEY
LIST
}

provider_names() { providers | awk '{ printf "%s ", $1 }'; }
provider_key_vars() { providers | awk 'NF > 1 { print $2 }'; }

key_var_for() {
  providers | awk -v p="$1" '$1 == p { print $2; found = 1 } END { exit !found }'
}

# The model verify.sh should ask for. Ollama's is pulled for you; the hosted
# ones match the model each config writes a budget rule for.
default_model_for() {
  case "$1" in
    openai) printf 'gpt-4o' ;;
    anthropic) printf 'claude-sonnet-4-6' ;;
    openrouter) printf 'openai/gpt-4o' ;;
    *) printf '%s' "${OLLAMA_MODEL}" ;;
  esac
}

# --- credentials ------------------------------------------------------------
#
# Nothing is ever written inside the repository. In order of preference:
#
#   1. the variable is already exported -- used as-is, never stored
#   2. the OS keychain -- macOS Keychain, or libsecret on Linux
#   3. a file under $XDG_CONFIG_HOME, mode 600, outside any project directory
#
# Storing a key inside the repository was deliberately ruled out: that tree is
# read by coding agents, followed by backup and sync tools, and one `git add -f`
# away from a public branch.

CRED_SERVICE="praxis-ai-gateway-demo"
CRED_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/praxis-ai-gateway"
CRED_FILE="${CRED_DIR}/env"

# Which of the three stores this machine will use for a new key.
cred_backend() {
  if [ -n "${DEMO_CRED_BACKEND:-}" ]; then
    printf '%s' "${DEMO_CRED_BACKEND}"
  elif [ "$(uname -s)" = "Darwin" ] && command -v security > /dev/null 2>&1; then
    printf 'keychain'
  elif command -v secret-tool > /dev/null 2>&1; then
    printf 'libsecret'
  else
    printf 'file'
  fi
}

cred_load() {
  local var="$1" value=""
  case "$(cred_backend)" in
    keychain)
      value="$(security find-generic-password -a "${USER}" -s "${CRED_SERVICE}-${var}" -w 2> /dev/null || true)"
      ;;
    libsecret)
      value="$(secret-tool lookup service "${CRED_SERVICE}" key "${var}" 2> /dev/null || true)"
      ;;
  esac
  # The file is also read when a keychain is in use, so a key stored before one
  # was available keeps working.
  if [ -z "${value}" ] && [ -f "${CRED_FILE}" ]; then
    value="$(awk -F= -v k="${var}" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "${CRED_FILE}")"
  fi
  printf '%s' "${value}"
}

cred_store() {
  local var="$1" value="$2" tmp
  case "$(cred_backend)" in
    keychain)
      # -w takes the secret as an argument, so it is briefly visible to `ps` on
      # this machine. `security` offers no stdin form for a non-interactive
      # write, and the alternative -- leaving it in a file -- is worse.
      security add-generic-password -a "${USER}" -s "${CRED_SERVICE}-${var}" -w "${value}" -U
      printf '  stored in your macOS Keychain as %s-%s\n' "${CRED_SERVICE}" "${var}"
      ;;
    libsecret)
      printf '%s' "${value}" | secret-tool store --label="${CRED_SERVICE} ${var}" \
        service "${CRED_SERVICE}" key "${var}"
      printf '  stored in your login keyring as %s/%s\n' "${CRED_SERVICE}" "${var}"
      ;;
    *)
      mkdir -p "${CRED_DIR}"
      chmod 700 "${CRED_DIR}"
      touch "${CRED_FILE}"
      chmod 600 "${CRED_FILE}"
      # Rewrite rather than append: a second copy of the same name would
      # silently shadow the first, since the last line read wins.
      tmp="$(mktemp)"
      grep -v "^${var}=" "${CRED_FILE}" > "${tmp}" || true
      printf '%s=%s\n' "${var}" "${value}" >> "${tmp}"
      mv "${tmp}" "${CRED_FILE}"
      chmod 600 "${CRED_FILE}"
      printf '  stored in %s, mode 600\n' "${CRED_FILE}"
      ;;
  esac
}

# Exports every stored provider key that is not already set, so an explicit
# `OPENAI_API_KEY=... ./demo-podman up openai` still wins for that one run.
load_stored_keys() {
  local var value
  for var in $(provider_key_vars); do
    if [ -z "${!var:-}" ]; then
      value="$(cred_load "${var}")"
      if [ -n "${value}" ]; then
        export "${var}=${value}"
      fi
    fi
  done
}

ensure_key() {
  local var value
  var="$(key_var_for "${PROVIDER}")"
  [ -n "${var}" ] || return 0

  if [ -n "${!var:-}" ]; then
    printf '  using %s from the environment\n' "${var}"
    return 0
  fi

  if [ ! -r /dev/tty ]; then
    die "${PROVIDER} needs ${var} and there is no terminal to ask on. Export it instead: ${var}=... ${DEMO_CMD} up ${PROVIDER}"
  fi

  printf '\n%s needs an API key. It is passed to the gateway and nothing else;\n' "${PROVIDER}"
  printf 'your coding agent never holds it. Paste it, input is hidden:\n'
  printf '  %s: ' "${var}"
  read -rs value < /dev/tty
  printf '\n'
  [ -n "${value}" ] || die "no key entered"
  cred_store "${var}" "${value}"
  export "${var}=${value}"
}

# Forgets a stored key, for when it is rotated or no longer wanted.
forget_key() {
  local var="$1"
  case "$(cred_backend)" in
    keychain) security delete-generic-password -a "${USER}" -s "${CRED_SERVICE}-${var}" > /dev/null 2>&1 || true ;;
    libsecret) secret-tool clear service "${CRED_SERVICE}" key "${var}" 2> /dev/null || true ;;
  esac
  if [ -f "${CRED_FILE}" ]; then
    local tmp
    tmp="$(mktemp)"
    grep -v "^${var}=" "${CRED_FILE}" > "${tmp}" || true
    mv "${tmp}" "${CRED_FILE}"
    chmod 600 "${CRED_FILE}"
  fi
  printf '  forgot %s\n' "${var}"
}

# --- container image --------------------------------------------------------

# The engine is always named, never guessed: a machine with both installed
# would otherwise start the stack on one and leave you looking for it on the
# other.
require_engine() {
  command -v "$1" > /dev/null 2>&1 || die "$1 not found"
}

ensure_image() {
  local eng="$1"
  if "${eng}" image inspect "${IMAGE}" > /dev/null 2>&1; then
    printf '  image %s is present\n' "${IMAGE}"
    return 0
  fi
  say "building ${IMAGE} -- first run only, a few minutes"
  "${eng}" build --build-arg FEATURES=otel -t "${IMAGE}" -f ../../Containerfile ../..
}

# --- ollama -----------------------------------------------------------------

ensure_ollama() {
  [ "${PROVIDER}" = "ollama" ] || return 0
  curl --fail --silent --max-time 3 http://localhost:11434/api/tags > /dev/null 2>&1 \
    || die "Ollama is not answering on localhost:11434. Run 'ollama serve', or use a hosted provider instead."
  if curl --fail --silent --max-time 5 http://localhost:11434/api/tags | grep -q "\"${OLLAMA_MODEL}\""; then
    printf '  model %s is present\n' "${OLLAMA_MODEL}"
  else
    say "pulling ${OLLAMA_MODEL} -- about 0.5 GB, first run only"
    ollama pull "${OLLAMA_MODEL}"
  fi
}

# --- output -----------------------------------------------------------------

# print_urls <gateway> <admin> <perses> <prometheus> [grafana]
print_urls() {
  local gw="$1" admin="$2" perses="$3" prom="$4" grafana="${5:-}" d
  printf '\n  gateway     http://localhost:%s\n' "${gw}"
  printf '  metrics     http://localhost:%s/metrics\n' "${admin}"
  printf '  Prometheus  http://localhost:%s\n' "${prom}"
  printf '  Perses      http://localhost:%s\n' "${perses}"
  for d in ai-gateway-overview token-budget filter-latency traces; do
    printf '    %-20s http://localhost:%s/projects/praxis/dashboards/%s\n' \
      "${d}" "${perses}" "${d}"
  done
  if [ -n "${grafana}" ]; then
    printf '  Grafana     http://localhost:%s  (admin/admin)\n' "${grafana}"
  fi
  printf '\n  next:  %s verify\n\n' "${DEMO_CMD}"
}

# run_verify <gateway port> <prometheus port> [tempo port]
run_verify() {
  local -a args=("http://localhost:$1" "http://localhost:$2")
  if [ -n "${3:-}" ]; then
    args+=("http://localhost:$3")
  fi

  if [ "${PROVIDER}" = "ollama" ]; then
    MODEL="${OLLAMA_MODEL}" ./scripts/verify.sh "${args[@]}"
    return
  fi

  # The budget probe floods the gateway on purpose and a hosted provider bills
  # per admitted request, so it only runs against the local model.
  say "skipping the budget probe: ${PROVIDER} bills per request"
  # Anthropic is not OpenAI-shaped; verify.sh probes /v1/messages instead.
  local wire=openai
  if [ "${PROVIDER}" = "anthropic" ]; then
    wire=anthropic
  fi
  MODEL="${VERIFY_MODEL:-$(default_model_for "${PROVIDER}")}" WIRE="${wire}" SKIP_BUDGET=1 \
    ./scripts/verify.sh "${args[@]}"
}

# --- argument handling ------------------------------------------------------

# Sets PROVIDER from an explicit name, or ollama, and loads stored keys.
resolve_provider() {
  PROVIDER="${1:-ollama}"
  [ -f "configs/${PROVIDER}.yaml" ] \
    || die "no configs/${PROVIDER}.yaml. Known providers: $(provider_names)"
  load_stored_keys
}
