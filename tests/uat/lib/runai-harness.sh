# Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# shellcheck shell=bash
#
# Run:ai control-plane harness for the platform=runai UAT cells (NVIDIA/aicr#3302,
# "Validation contract"). AICR installs only the Run:ai cluster side; the control
# plane is a long-lived CI fixture this file talks to over its REST API. Per run:
#
#   prep         POST /api/v1/clusters {name}            -> cluster record, uuid
#                (the uuid, the control-plane host and the cluster URL become the
#                 --set values of `aicr bundle`)
#   install      namespace runai + the two TLS Secrets the chart expects, the
#                control-plane CA Secret when the fixture uses a private CA,
#                GET /api/v1/clusters/{uuid}/cluster-install-info -> bootstrap
#                token, written into cluster-values.yaml right before deploy.sh
#                and cleared right after; then POST /api/v1/org-unit/projects
#                with an explicit CPU and memory quota -> namespace runai-<name>
#   conformance  wait for that namespace to carry the runai/queue label, export
#                AICR_RUNAI_PROJECT_NAMESPACE for the gang-scheduling check
#   unregister   DELETE the Project, then DELETE /api/v1/clusters/{uuid}?force=true
#
# Credential. The harness authenticates as a control-plane service account
# (client_credentials at POST /api/v2/token). It reaches the lane as three
# environment variables, RUNAI_CP_URL, RUNAI_CLIENT_ID and RUNAI_CLIENT_SECRET
# (plus RUNAI_CP_CA_FILE when the control plane serves a private CA), which the
# workflow fills from the cloud secret manager its OIDC identity already reaches
# (runai_credential_export below). Nothing here reads a GitHub secret, and no
# value of the credential, nor the bootstrap token, is ever printed or persisted
# beyond the install-time stub the chart's install.sh needs. Token-bearing curl
# arguments travel through a curl config on stdin (-K -), never argv, so a
# process listing on a shared runner cannot read them.
#
# Non-secret per-run state (cluster uuid and name, Project id and namespace)
# lives in RUNAI_HARNESS_STATE in $PWD so the phases, which run as separate
# workflow steps, share it; it is uploaded with the failure-debug artifacts.
#
# Source guard: constants and functions only, no side effects at source time.
# Sourced by phases.sh and standalone by the workflows' credential step.

RUNAI_HARNESS_STATE="${RUNAI_HARNESS_STATE:-runai-harness.json}"
# Every control-plane call is bounded; the API is a handful of small JSON
# exchanges, so a minute is already generous for a healthy fixture.
RUNAI_API_TIMEOUT_SECONDS="${RUNAI_API_TIMEOUT_SECONDS:-60}"
# How long conformance waits for the Project namespace to appear with its
# runai/queue label. The agent syncs projects from the control plane every 10s
# and KAI Resource Management creates the namespace from the Project CR, so a
# healthy cluster needs well under a minute; the budget covers an agent that is
# still connecting after a fresh install.
RUNAI_PROJECT_NAMESPACE_TIMEOUT_SECONDS="${RUNAI_PROJECT_NAMESPACE_TIMEOUT_SECONDS:-600}"
# Project quota for the gang test, on the default node pool. Run:ai gives a
# Project with no explicit CPU and memory quota zero of each, and the
# gang-scheduling check runs two CPU-only pods (100m / 128Mi each), so the
# quota is explicit and deliberately small. GPUs: none deserved; the check
# requests none.
RUNAI_PROJECT_CPU_MILLICORES="${RUNAI_PROJECT_CPU_MILLICORES:-4000}"
RUNAI_PROJECT_MEMORY_MIB="${RUNAI_PROJECT_MEMORY_MIB:-8192}"
# Names. The cluster record and the Project default to the run id so concurrent
# runs against one control plane cannot collide; both are overridable for local
# reproduction. Run:ai names the Project namespace runai-<project>, and the
# harness pins that with requestedNamespace rather than inferring it.
RUNAI_CLUSTER_NAME="${RUNAI_CLUSTER_NAME:-}"
RUNAI_PROJECT_NAME="${RUNAI_PROJECT_NAME:-}"
# Where the chart's registration hooks look for the cluster-domain
# certificates (component values.yaml and the Run:ai install docs). The lane
# issues a self-signed certificate for the cluster URL's host and its
# wildcard, valid for the run only.
RUNAI_NAMESPACE="${RUNAI_NAMESPACE:-runai}"
RUNAI_TLS_SECRET="${RUNAI_TLS_SECRET:-runai-cluster-domain-tls-secret}"
RUNAI_TLS_STAR_SECRET="${RUNAI_TLS_STAR_SECRET:-runai-cluster-domain-star-tls-secret}"
RUNAI_TLS_DAYS="${RUNAI_TLS_DAYS:-7}"
# Secret the chart reads the control-plane CA from (global.customCA at 3.0.20)
# when the fixture does not serve a publicly trusted certificate.
RUNAI_CA_SECRET="${RUNAI_CA_SECRET:-runai-ca-cert}"
RUNAI_CA_SECRET_KEY="${RUNAI_CA_SECRET_KEY:-runai-ca.pem}"
# cluster.url: the FQDN the control plane reaches this cluster at. The chart has
# no default, the hooks need it, and the UAT clusters have no DNS of their own,
# so unless RUNAI_CLUSTER_URL names one the lane derives
# https://runai-cluster.<lb-ip-dashed>.sslip.io from the ingress controller's
# LoadBalancer address (Run:ai requires an ingress controller or Gateway API on
# the cluster, DependenciesFulfilled checks for one). No controller, no address,
# no URL: the lane fails closed rather than registering an unreachable cluster.
RUNAI_CLUSTER_URL="${RUNAI_CLUSTER_URL:-}"
RUNAI_INGRESS_SERVICE="${RUNAI_INGRESS_SERVICE:-ingress-nginx/ingress-nginx-controller}"
# The cloud secret manager entry the workflows read the credential from; one
# name on every cloud so the lane documentation has one thing to say. Its value
# is the JSON runai_credential_export documents.
RUNAI_HARNESS_SECRET_NAME="${RUNAI_HARNESS_SECRET_NAME:-aicr-uat-runai-harness}"

# runai_credential_export reads the harness credential JSON on stdin and
# publishes it to the following workflow steps through GITHUB_ENV, masked.
# The workflows call it through the runai-credential-export executable beside
# this file, since the workflow audit rejects a `source` in a credential step.
#
#   {"url": "https://runai.example.com", "clientId": "...", "clientSecret": "...",
#    "caCert": "-----BEGIN CERTIFICATE-----\n..."}   (caCert optional)
#
# Fails closed on malformed JSON or a missing field so a half-provisioned
# fixture fails this step by name, not a phase later with an opaque 401. The
# CA, when present, is written to a file under RUNNER_TEMP and only its path is
# exported. Intended for the workflow step; locally, export the RUNAI_*
# variables yourself.
runai_credential_export() {
  : "${GITHUB_ENV:?runai_credential_export publishes through GITHUB_ENV; export RUNAI_CP_URL, RUNAI_CLIENT_ID and RUNAI_CLIENT_SECRET yourself outside GitHub Actions}"
  local xtrace="" payload url client_id client_secret ca_cert
  case "$-" in *x*) xtrace=1 ;; esac
  set +x
  payload="$(cat)"
  if ! printf '%s' "${payload}" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "::error::Run:ai harness credential is not a JSON object" >&2
    [[ -n "${xtrace}" ]] && set -x
    return 1
  fi
  url="$(printf '%s' "${payload}" | jq -r '.url // ""')"
  client_id="$(printf '%s' "${payload}" | jq -r '.clientId // ""')"
  client_secret="$(printf '%s' "${payload}" | jq -r '.clientSecret // ""')"
  ca_cert="$(printf '%s' "${payload}" | jq -r '.caCert // ""')"
  if [[ -z "${url}" || -z "${client_id}" || -z "${client_secret}" ]]; then
    echo "::error::Run:ai harness credential must carry url, clientId and clientSecret" >&2
    [[ -n "${xtrace}" ]] && set -x
    return 1
  fi
  if [[ "${url}" != https://* ]]; then
    echo "::error::Run:ai harness credential url must be https://..., got a value with another scheme" >&2
    [[ -n "${xtrace}" ]] && set -x
    return 1
  fi
  echo "::add-mask::${client_id}"
  echo "::add-mask::${client_secret}"
  {
    echo "RUNAI_CP_URL=${url%/}"
    echo "RUNAI_CLIENT_ID=${client_id}"
    echo "RUNAI_CLIENT_SECRET=${client_secret}"
  } >> "${GITHUB_ENV}"
  if [[ -n "${ca_cert}" ]]; then
    local ca_file="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/runai-cp-ca.pem"
    (umask 077 && printf '%s\n' "${ca_cert}" > "${ca_file}")
    echo "RUNAI_CP_CA_FILE=${ca_file}" >> "${GITHUB_ENV}"
  fi
  echo "Run:ai harness credential exported for ${url%/} (client id and secret masked)"
  [[ -n "${xtrace}" ]] && set -x
  return 0
}

# runai_require_env fails closed, by name, when the credential is absent, so a
# lane dispatched without the fixture stops before it registers anything.
runai_require_env() {
  local missing=()
  [[ -n "${RUNAI_CP_URL:-}" ]]        || missing+=(RUNAI_CP_URL)
  [[ -n "${RUNAI_CLIENT_ID:-}" ]]     || missing+=(RUNAI_CLIENT_ID)
  [[ -n "${RUNAI_CLIENT_SECRET:-}" ]] || missing+=(RUNAI_CLIENT_SECRET)
  if (( ${#missing[@]} > 0 )); then
    echo "::error::platform=runai needs the control-plane harness credential; missing: ${missing[*]} (see docs/contributor/uat.md, The Run:ai lane)" >&2
    return 1
  fi
  if [[ -n "${RUNAI_CP_CA_FILE:-}" && ! -s "${RUNAI_CP_CA_FILE}" ]]; then
    echo "::error::RUNAI_CP_CA_FILE=${RUNAI_CP_CA_FILE} is set but not a readable file" >&2
    return 1
  fi
  for tool in curl jq kubectl openssl yq; do
    command -v "${tool}" >/dev/null 2>&1 || { echo "::error::${tool} not on PATH (needed by the Run:ai harness)" >&2; return 1; }
  done
  return 0
}

# runai_cp_host strips the scheme and any path from RUNAI_CP_URL: the chart's
# controlPlane.url is a host (tenant-name.run.ai), the API calls need the URL.
runai_cp_host() {
  local host="${RUNAI_CP_URL#https://}"
  host="${host#http://}"
  printf '%s' "${host%%/*}"
}

# uat_recipe_declares_runai: true when the resolved recipe ($1, default
# recipe.yaml) carries an enabled runai-cluster component. A ref disabled
# through overrides.enabled: false does not count, matching the bundler's
# RecipeDeclares, so a lane that happens to run a non-runai recipe never
# touches the control plane.
uat_recipe_declares_runai() {
  local recipe="${1:-recipe.yaml}"
  [[ -f "${recipe}" ]] || return 1
  # `!= false`, not `// true`: yq's alternative operator treats false like
  # null, so `(.overrides.enabled // true)` would read a disabled ref as on.
  [[ "$(yq -r '[.componentRefs[]? | select(.name == "runai-cluster" and .overrides.enabled != false)] | length > 0' "${recipe}" 2>/dev/null)" == "true" ]]
}

# uat_recipe_runai_version prints the runai-cluster chart version the resolved
# recipe pins; cluster-install-info needs it to mint a token for that version.
uat_recipe_runai_version() {
  local recipe="${1:-recipe.yaml}" v
  v="$(yq -r '[.componentRefs[]? | select(.name == "runai-cluster") | .version] | .[0] // ""' "${recipe}" 2>/dev/null)"
  if [[ -z "${v}" || "${v}" == "null" ]]; then
    echo "::error::${recipe} pins no version for runai-cluster; cannot mint a bootstrap token" >&2
    return 1
  fi
  printf '%s' "${v}"
}

# runai_state_get <jq filter> prints a field of the per-run state, empty when
# the state or the field is absent.
runai_state_get() {
  [[ -s "${RUNAI_HARNESS_STATE}" ]] || return 0
  jq -r "${1} // \"\"" "${RUNAI_HARNESS_STATE}" 2>/dev/null || true
}

# runai_state_set <key> <value> upserts one string field of the per-run state.
runai_state_set() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if [[ -s "${RUNAI_HARNESS_STATE}" ]]; then
    jq --arg k "${key}" --arg v "${value}" '.[$k] = $v' "${RUNAI_HARNESS_STATE}" > "${tmp}"
  else
    jq -n --arg k "${key}" --arg v "${value}" '{($k): $v}' > "${tmp}"
  fi
  mv "${tmp}" "${RUNAI_HARNESS_STATE}"
}

# runai_curl_config prints the curl options every API call shares: bounded,
# fail on HTTP errors but keep the body for the diagnostic, the private CA when
# the fixture needs one, and the bearer token as a header. It is consumed by
# `curl -K -` on stdin so the token is never an argument.
runai_curl_config() {
  echo "silent"
  echo "show-error"
  echo "fail-with-body"
  echo "max-time = ${RUNAI_API_TIMEOUT_SECONDS}"
  [[ -n "${RUNAI_CP_CA_FILE:-}" ]] && echo "cacert = \"${RUNAI_CP_CA_FILE}\""
  [[ -n "${RUNAI_TOKEN:-}" ]] && echo "header = \"Authorization: Bearer ${RUNAI_TOKEN}\""
  return 0
}

# runai_token authenticates with client_credentials at POST /api/v2/token
# (form-encoded, snake_case; a JSON body is a 400 there) and sets RUNAI_TOKEN.
# The client secret reaches curl through the stdin config, never argv, and
# xtrace is forced off around the exchange.
runai_token() {
  local xtrace="" response rc=0
  case "$-" in *x*) xtrace=1 ;; esac
  set +x
  RUNAI_TOKEN=""
  response="$({
    runai_curl_config
    echo "url = \"${RUNAI_CP_URL}/api/v2/token\""
    echo "request = \"POST\""
    echo "data-urlencode = \"grant_type=client_credentials\""
    echo "data-urlencode = \"client_id=${RUNAI_CLIENT_ID}\""
    echo "data-urlencode = \"client_secret=${RUNAI_CLIENT_SECRET}\""
  } | curl -K -)" || rc=$?
  if (( rc != 0 )); then
    echo "::error::Run:ai control plane ${RUNAI_CP_URL}: token request failed (curl rc=${rc}); response body: $(printf '%s' "${response}" | head -c 300)" >&2
    [[ -n "${xtrace}" ]] && set -x
    return 1
  fi
  RUNAI_TOKEN="$(printf '%s' "${response}" | jq -r '.access_token // ""' 2>/dev/null)"
  if [[ -z "${RUNAI_TOKEN}" ]]; then
    echo "::error::Run:ai control plane ${RUNAI_CP_URL}: token response carried no access_token" >&2
    [[ -n "${xtrace}" ]] && set -x
    return 1
  fi
  export RUNAI_TOKEN
  [[ -n "${xtrace}" ]] && set -x
  return 0
}

# runai_api <METHOD> <path> [json body] calls the control plane with the bearer
# token, printing the response body. The path must start with /. A body is
# written to a temp file and sent as JSON. On an HTTP error the body (which
# carries the control plane's own message) is on stderr, bounded.
runai_api() {
  local method="$1" path="$2" body="${3:-}" tmp="" response rc=0
  : "${RUNAI_TOKEN:?runai_api called before runai_token}"
  if [[ -n "${body}" ]]; then
    tmp="$(mktemp)"
    printf '%s' "${body}" > "${tmp}"
  fi
  response="$({
    runai_curl_config
    echo "url = \"${RUNAI_CP_URL}${path}\""
    echo "request = \"${method}\""
    if [[ -n "${tmp}" ]]; then
      echo "header = \"Content-Type: application/json\""
      echo "data-binary = \"@${tmp}\""
    fi
  } | curl -K -)" || rc=$?
  [[ -n "${tmp}" ]] && rm -f "${tmp}"
  if (( rc != 0 )); then
    echo "Run:ai API ${method} ${path} failed (curl rc=${rc}): $(printf '%s' "${response}" | head -c 500)" >&2
    return 1
  fi
  printf '%s' "${response}"
}

# runai_cluster_url resolves cluster.url once per run and pins it in the state so
# prep (bundle --set), install (certificates, install-info) and the chart agree.
runai_cluster_url() {
  local url
  url="$(runai_state_get .clusterUrl)"
  if [[ -z "${url}" ]]; then
    if [[ -n "${RUNAI_CLUSTER_URL}" ]]; then
      url="${RUNAI_CLUSTER_URL}"
    else
      local ns="${RUNAI_INGRESS_SERVICE%%/*}" svc="${RUNAI_INGRESS_SERVICE#*/}" ip
      ip="$(kubectl -n "${ns}" get svc "${svc}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
      if [[ -z "${ip}" ]]; then
        echo "::error::cannot derive cluster.url: Service ${RUNAI_INGRESS_SERVICE} has no LoadBalancer address. Run:ai needs an ingress controller on the cluster (DependenciesFulfilled); set RUNAI_CLUSTER_URL or RUNAI_INGRESS_SERVICE" >&2
        return 1
      fi
      url="https://runai-cluster.${ip//./-}.sslip.io"
    fi
    runai_state_set clusterUrl "${url}"
  fi
  printf '%s' "${url}"
}

# runai_prep_register creates the cluster record (idempotent on re-run: a uuid
# already in the state is reused) and resolves cluster.url. Runs in phase_prep
# before `aicr bundle`, which needs the uuid.
runai_prep_register() {
  runai_require_env || return 1
  local name uuid url
  url="$(runai_cluster_url)" || return 1
  uuid="$(runai_state_get .clusterUuid)"
  name="$(runai_state_get .clusterName)"
  if [[ -z "${uuid}" ]]; then
    name="${RUNAI_CLUSTER_NAME:-aicr-uat-${RUN_ID}}"
    runai_token || return 1
    local created
    created="$(runai_api POST /api/v1/clusters "$(jq -n --arg n "${name}" '{name: $n}')")" || {
      echo "::error::Run:ai: creating cluster record '${name}' failed" >&2; return 1; }
    uuid="$(printf '%s' "${created}" | jq -r '.uuid // ""')"
    if [[ -z "${uuid}" ]]; then
      echo "::error::Run:ai: cluster record response carried no uuid: $(printf '%s' "${created}" | head -c 300)" >&2
      return 1
    fi
    runai_state_set clusterName "${name}"
    runai_state_set clusterUuid "${uuid}"
    runai_state_set controlPlaneHost "$(runai_cp_host)"
  fi
  echo "Run:ai cluster record: name=${name} uuid=${uuid} cluster.url=${url} control plane=$(runai_cp_host)"
}

# runai_bundle_args prints, one per line, the `aicr bundle` arguments that
# register this run's cluster: the three required values, plus the private-CA
# switch when the fixture needs one. The bootstrap token is NOT here: the test
# config declares it --dynamic, so it is filled at install time only.
runai_bundle_args() {
  local uuid url
  uuid="$(runai_state_get .clusterUuid)"
  url="$(runai_state_get .clusterUrl)"
  if [[ -z "${uuid}" || -z "${url}" ]]; then
    echo "::error::runai_bundle_args: no cluster record in ${RUNAI_HARNESS_STATE}; run prep first" >&2
    return 1
  fi
  printf -- '--set\nrunai:controlPlane.url=%s\n' "$(runai_cp_host)"
  printf -- '--set\nrunai:cluster.uid=%s\n' "${uuid}"
  printf -- '--set\nrunai:cluster.url=%s\n' "${url}"
  if [[ -n "${RUNAI_CP_CA_FILE:-}" ]]; then
    printf -- '--set\nrunai:global.customCA.enabled=true\n'
  fi
}

# runai_install_prepare creates what the chart expects before its hooks run:
# the runai namespace, the two cluster-domain TLS Secrets (self-signed for the
# cluster URL's host and its wildcard, valid RUNAI_TLS_DAYS days), and the
# control-plane CA Secret when RUNAI_CP_CA_FILE is set. Idempotent.
runai_install_prepare() {
  local url host tlsdir
  url="$(runai_cluster_url)" || return 1
  host="${url#https://}"; host="${host%%/*}"
  echo "::group::Run:ai install prerequisites (namespace ${RUNAI_NAMESPACE}, TLS Secrets for ${host})"
  kubectl create namespace "${RUNAI_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  tlsdir="$(mktemp -d)"
  if ! (umask 077 && openssl req -x509 -newkey rsa:2048 -nodes -days "${RUNAI_TLS_DAYS}" \
        -keyout "${tlsdir}/tls.key" -out "${tlsdir}/tls.crt" \
        -subj "/CN=${host}" -addext "subjectAltName=DNS:${host},DNS:*.${host}" >/dev/null 2>&1); then
    echo "::error::openssl could not issue the cluster-domain certificate for ${host}" >&2
    rm -rf "${tlsdir}"; echo "::endgroup::"; return 1
  fi
  local secret
  for secret in "${RUNAI_TLS_SECRET}" "${RUNAI_TLS_STAR_SECRET}"; do
    if ! kubectl -n "${RUNAI_NAMESPACE}" create secret tls "${secret}" \
        --cert="${tlsdir}/tls.crt" --key="${tlsdir}/tls.key" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; then
      echo "::error::could not apply Secret ${RUNAI_NAMESPACE}/${secret}" >&2
      rm -rf "${tlsdir}"; echo "::endgroup::"; return 1
    fi
    echo "Secret ${RUNAI_NAMESPACE}/${secret} applied"
  done
  rm -rf "${tlsdir}"
  if [[ -n "${RUNAI_CP_CA_FILE:-}" ]]; then
    if ! kubectl -n "${RUNAI_NAMESPACE}" create secret generic "${RUNAI_CA_SECRET}" \
        --from-file="${RUNAI_CA_SECRET_KEY}=${RUNAI_CP_CA_FILE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; then
      echo "::error::could not apply Secret ${RUNAI_NAMESPACE}/${RUNAI_CA_SECRET}" >&2
      echo "::endgroup::"; return 1
    fi
    echo "Secret ${RUNAI_NAMESPACE}/${RUNAI_CA_SECRET} applied (control-plane CA)"
  fi
  echo "::endgroup::"
}

# runai_mint_token_into <cluster-values.yaml> <chart version> mints a bootstrap
# token for this run's cluster record (GET cluster-install-info; every call
# mints a fresh two-hour token) and writes it into the --dynamic stub of the
# runai-cluster bundle directory. The token never appears on argv or stdout:
# yq reads it from the environment. The caller clears the stub afterwards with
# runai_clear_token.
runai_mint_token_into() {
  local values_file="$1" version="$2" uuid url xtrace="" info token rc=0
  uuid="$(runai_state_get .clusterUuid)"
  url="$(runai_state_get .clusterUrl)"
  if [[ -z "${uuid}" || -z "${url}" ]]; then
    echo "::error::runai_mint_token_into: no cluster record in ${RUNAI_HARNESS_STATE}; run prep first" >&2
    return 1
  fi
  [[ -f "${values_file}" ]] || { echo "::error::${values_file} not found; the bundle carries no runai-cluster cluster-values.yaml" >&2; return 1; }
  case "$-" in *x*) xtrace=1 ;; esac
  set +x
  runai_token || { [[ -n "${xtrace}" ]] && set -x; return 1; }
  info="$(runai_api GET "/api/v1/clusters/${uuid}/cluster-install-info?version=${version}&remoteClusterUrl=${url}")" || rc=1
  if (( rc == 0 )); then
    token="$(printf '%s' "${info}" | jq -r '.bootstrapToken // ""')"
    [[ -n "${token}" ]] || { echo "::error::cluster-install-info carried no bootstrapToken (control plane older than 3.0?)" >&2; rc=1; }
  fi
  if (( rc == 0 )); then
    RUNAI_BOOTSTRAP_TOKEN="${token}" yq -i '.controlPlane.bootstrapToken = strenv(RUNAI_BOOTSTRAP_TOKEN)' "${values_file}" || rc=1
  fi
  [[ -n "${xtrace}" ]] && set -x
  if (( rc == 0 )); then
    echo "bootstrap token minted for cluster ${uuid} (version ${version}) and written into $(basename "$(dirname "${values_file}")")/cluster-values.yaml"
  fi
  return "${rc}"
}

# runai_clear_token <cluster-values.yaml> resets the stub so the token does not
# stay at rest on the runner. Helm's release Secret still holds it (two-hour
# expiry); see the component values.yaml.
runai_clear_token() {
  local values_file="$1"
  [[ -f "${values_file}" ]] || return 0
  yq -i '.controlPlane.bootstrapToken = ""' "${values_file}" \
    && echo "bootstrap token stub cleared in ${values_file}"
}

# runai_bundle_values_file prints the runai-cluster cluster-values.yaml of the
# helm bundle at $1 (default bundle), failing when there is not exactly one.
# The path is absolute: install_helm clears the stub from an EXIT trap inside
# the subshell that has `cd`-ed into the bundle, where a relative path would
# miss the file and leave the token at rest.
runai_bundle_values_file() {
  local bundle="${1:-bundle}" matches=() abs
  abs="$(cd "${bundle}" 2>/dev/null && pwd)" || { echo "::error::bundle directory ${bundle} not found" >&2; return 1; }
  while IFS= read -r f; do matches+=("${f}"); done < <(find "${abs}" -maxdepth 2 -path '*-runai-cluster/cluster-values.yaml' 2>/dev/null | sort)
  if (( ${#matches[@]} != 1 )); then
    echo "::error::expected exactly one *-runai-cluster/cluster-values.yaml under ${bundle}, found ${#matches[@]}" >&2
    return 1
  fi
  printf '%s' "${matches[0]}"
}

# runai_create_project creates the Run:ai Project the gang test runs in, with an
# explicit CPU and memory quota on the cluster's default node pool, and pins its
# namespace (runai-<name>) in the state. Idempotent on re-run.
runai_create_project() {
  local uuid name ns pool_id project_id
  uuid="$(runai_state_get .clusterUuid)"
  [[ -n "${uuid}" ]] || { echo "::error::runai_create_project: no cluster record in ${RUNAI_HARNESS_STATE}" >&2; return 1; }
  project_id="$(runai_state_get .projectId)"
  if [[ -n "${project_id}" ]]; then
    echo "Run:ai Project already created: id=${project_id} namespace=$(runai_state_get .projectNamespace)"
    return 0
  fi
  name="${RUNAI_PROJECT_NAME:-aicr-uat-${RUN_ID}}"
  ns="runai-${name}"
  if (( ${#ns} > 63 )) || ! [[ "${ns}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "::error::Project namespace '${ns}' is not a DNS label; set RUNAI_PROJECT_NAME" >&2
    return 1
  fi
  runai_token || return 1
  local pools
  pools="$(runai_api GET "/api/v1/node-pools?filterBy=clusterId==${uuid}")" || return 1
  pool_id="$(printf '%s' "${pools}" | jq -r '[.nodepools[]? | select(.isDefault == true or .name == "default")] | .[0].id // ""')"
  if [[ -z "${pool_id}" ]]; then
    echo "::error::Run:ai: cluster ${uuid} reports no default node pool yet: $(printf '%s' "${pools}" | head -c 300)" >&2
    return 1
  fi
  local body created
  body="$(jq -n --arg n "${name}" --arg c "${uuid}" --arg ns "${ns}" --arg p "${pool_id}" \
    --argjson cpu "${RUNAI_PROJECT_CPU_MILLICORES}" --argjson mem "${RUNAI_PROJECT_MEMORY_MIB}" '{
      name: $n, clusterId: $c, requestedNamespace: $ns,
      resources: [{
        nodePool: {id: $p, name: "default"},
        gpu:    {deserved: 0, limit: null, overQuotaWeight: 2},
        cpu:    {deserved: $cpu, limit: null, overQuotaWeight: 2},
        memory: {deserved: $mem, limit: null, overQuotaWeight: 2, units: "Mib"}
      }]
    }')"
  created="$(runai_api POST /api/v1/org-unit/projects "${body}")" || {
    echo "::error::Run:ai: creating Project '${name}' failed" >&2; return 1; }
  project_id="$(printf '%s' "${created}" | jq -r '.id // ""')"
  if [[ -z "${project_id}" ]]; then
    echo "::error::Run:ai: Project response carried no id: $(printf '%s' "${created}" | head -c 300)" >&2
    return 1
  fi
  runai_state_set projectName "${name}"
  runai_state_set projectId "${project_id}"
  runai_state_set projectNamespace "${ns}"
  echo "Run:ai Project created: name=${name} id=${project_id} namespace=${ns} nodePool=${pool_id} quota cpu=${RUNAI_PROJECT_CPU_MILLICORES}m memory=${RUNAI_PROJECT_MEMORY_MIB}Mi"
}

# runai_project_namespace_label prints the runai/queue label of namespace $1,
# empty when the namespace or the label is absent.
runai_project_namespace_label() {
  kubectl get namespace "$1" -o json 2>/dev/null | jq -r '.metadata.labels["runai/queue"] // ""' 2>/dev/null || true
}

# runai_export_project_namespace waits, bounded, for the Project namespace to
# exist with its runai/queue label (the agent syncs the Project from the
# control plane, KAI Resource Management creates the namespace), then exports
# AICR_RUNAI_PROJECT_NAMESPACE for `aicr validate`, which forwards it to the
# gang-scheduling check only. Fails closed: the check itself fails without the
# input, so a lane that could not produce it must stop here with the reason.
runai_export_project_namespace() {
  local ns deadline label project_id
  ns="$(runai_state_get .projectNamespace)"
  project_id="$(runai_state_get .projectId)"
  if [[ -z "${ns}" ]]; then
    echo "::error::no Run:ai Project namespace in ${RUNAI_HARNESS_STATE}; the install phase creates the Project" >&2
    return 1
  fi
  echo "::group::Wait for Run:ai Project namespace ${ns} (runai/queue label, budget ${RUNAI_PROJECT_NAMESPACE_TIMEOUT_SECONDS}s)"
  deadline=$(( SECONDS + RUNAI_PROJECT_NAMESPACE_TIMEOUT_SECONDS ))
  while :; do
    label="$(runai_project_namespace_label "${ns}")"
    if [[ -n "${label}" ]]; then
      echo "namespace ${ns} carries runai/queue=${label}"
      break
    fi
    if (( SECONDS >= deadline )); then
      echo "::error::namespace ${ns} did not appear with a runai/queue label within ${RUNAI_PROJECT_NAMESPACE_TIMEOUT_SECONDS}s" >&2
      kubectl get namespace "${ns}" --show-labels 2>&1 | head -5 >&2 || true
      kubectl -n "${RUNAI_NAMESPACE}" get runaiconfig runai -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}' 2>&1 | head -10 >&2 || true
      kubectl get projects.kai.resources 2>&1 | head -10 >&2 || true
      if [[ -n "${project_id}" ]] && runai_token 2>/dev/null; then
        runai_api GET "/api/v1/org-unit/projects/${project_id}" 2>/dev/null | jq -c '{name, status}' >&2 || true
      fi
      echo "::endgroup::"
      return 1
    fi
    sleep 10
  done
  echo "::endgroup::"
  export AICR_RUNAI_PROJECT_NAMESPACE="${ns}"
  echo "AICR_RUNAI_PROJECT_NAMESPACE=${ns} exported for the gang-scheduling check"
}

# phase_unregister deletes what the harness created in the control plane: the
# Project, then the cluster record (force, so the control plane does not wait
# for the agent to disconnect). A missing state file means prep never
# registered anything and is not an error; a 404 means it is already gone. Any
# other API failure fails the phase, because a leaked record keeps a Project
# and a cluster alive in the shared fixture.
phase_unregister() {
  local uuid project_id rc=0
  if [[ ! -s "${RUNAI_HARNESS_STATE}" ]]; then
    echo "no ${RUNAI_HARNESS_STATE}: nothing was registered with the Run:ai control plane"
    return 0
  fi
  runai_require_env || return 1
  uuid="$(runai_state_get .clusterUuid)"
  project_id="$(runai_state_get .projectId)"
  runai_token || return 1
  if [[ -n "${project_id}" && "$(runai_state_get .projectDeleted)" != "true" ]]; then
    if runai_api DELETE "/api/v1/org-unit/projects/${project_id}" >/dev/null 2>"${RUNAI_HARNESS_STATE}.err" \
       || grep -q '"code": *404\|HTTP/[0-9.]* 404\|not found' -i "${RUNAI_HARNESS_STATE}.err"; then
      runai_state_set projectDeleted true
      echo "Run:ai Project ${project_id} deleted"
    else
      echo "::error::Run:ai: deleting Project ${project_id} failed: $(head -c 300 "${RUNAI_HARNESS_STATE}.err")" >&2
      rc=1
    fi
    rm -f "${RUNAI_HARNESS_STATE}.err"
  fi
  if [[ -n "${uuid}" && "$(runai_state_get .clusterDeleted)" != "true" ]]; then
    if runai_api DELETE "/api/v1/clusters/${uuid}?force=true" >/dev/null 2>"${RUNAI_HARNESS_STATE}.err" \
       || grep -q '"code": *404\|HTTP/[0-9.]* 404\|not found' -i "${RUNAI_HARNESS_STATE}.err"; then
      runai_state_set clusterDeleted true
      echo "Run:ai cluster record ${uuid} deleted"
    else
      echo "::error::Run:ai: deleting cluster record ${uuid} failed: $(head -c 300 "${RUNAI_HARNESS_STATE}.err")" >&2
      rc=1
    fi
    rm -f "${RUNAI_HARNESS_STATE}.err"
  fi
  return "${rc}"
}
