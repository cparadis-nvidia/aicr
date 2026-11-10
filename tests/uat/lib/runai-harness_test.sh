#!/usr/bin/env bash
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
# Tests for tests/uat/lib/runai-harness.sh (#3302). Hermetic: curl, kubectl and
# openssl are stubs on PATH that record what they were asked and answer from
# canned JSON, so the control-plane protocol the harness speaks (form-encoded
# token exchange, bearer header through the stdin config, the request bodies
# for the cluster record and the Project) is pinned without a control plane.
# The cases that matter most are the negative ones: a secret must never reach
# argv, a missing credential must fail by name before any call, and the
# install-time token must be cleared whatever happens after it is written.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for tool in jq yq; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        if [[ -n "${CI:-}" ]]; then
            echo "FAIL: ${tool} is not installed; the Run:ai harness cannot be verified in CI" >&2
            exit 1
        fi
        echo "SKIP: ${tool} is not installed"
        exit 0
    fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/runai-harness-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
fails=0
ran=0
pass() { ran=$((ran + 1)); echo "  ok   $1"; }
fail() { ran=$((ran + 1)); echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# Stubs. curl reads its stdin config (the harness always passes -K -), appends
# it to ${STUB_LOG}.curl so a test can assert on the url/request/data lines and
# on the ABSENCE of secrets in argv (argv is logged separately), and answers
# from ${STUB_RESPONSES}/<n>.json in call order. kubectl logs argv and answers
# from STUB_KUBECTL_OUT. openssl writes two files so the TLS Secret path runs.
STUB_BIN="${WORK}/bin"; mkdir -p "${STUB_BIN}"
cat > "${STUB_BIN}/curl" <<'STUB'
#!/usr/bin/env bash
printf 'ARGV: %s\n' "$*" >> "${STUB_LOG}.curl-argv"
n=$(( $(cat "${STUB_LOG}.curl-count" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${STUB_LOG}.curl-count"
{ echo "--- call ${n}"; cat; } >> "${STUB_LOG}.curl"
# A body file (data-binary = "@path") is copied so the test can read it.
body="$(grep -o 'data-binary = "@[^"]*"' "${STUB_LOG}.curl" | tail -1 | sed 's/.*"@\(.*\)"/\1/')"
[[ -n "${body}" && -f "${body}" ]] && cp "${body}" "${STUB_LOG}.body-${n}"
if [[ -f "${STUB_RESPONSES}/${n}.rc" ]]; then rc="$(cat "${STUB_RESPONSES}/${n}.rc")"; else rc=0; fi
[[ -f "${STUB_RESPONSES}/${n}.json" ]] && cat "${STUB_RESPONSES}/${n}.json"
exit "${rc}"
STUB
cat > "${STUB_BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "${STUB_LOG}.kubectl"
case "$*" in
    *"get svc"*) printf '%s' "${STUB_LB_IP:-}" ;;
    *"get namespace"*) printf '%s' "${STUB_NS_JSON:-}" ;;
    *"-f -"*) cat >/dev/null ;;
    *) : ;;
esac
exit "${STUB_KUBECTL_RC:-0}"
STUB
cat > "${STUB_BIN}/openssl" <<'STUB'
#!/usr/bin/env bash
printf 'openssl %s\n' "$*" >> "${STUB_LOG}.openssl"
while [[ $# -gt 0 ]]; do case "$1" in -keyout) echo key > "$2"; shift ;; -out) echo crt > "$2"; shift ;; esac; shift; done
STUB
chmod +x "${STUB_BIN}"/*

# run_case <dir> <commands> [VAR=value...]: sources the harness in a subshell
# rooted at <dir> with the stubs first on PATH, then evals the commands.
run_case() {
    local dir="$1" cmds="$2"; shift 2
    mkdir -p "${dir}/responses"
    (
        cd "${dir}" || exit 99
        set -euo pipefail
        export PATH="${STUB_BIN}:${PATH}" STUB_LOG="${dir}/stub" STUB_RESPONSES="${dir}/responses" RUN_ID=12345
        export RUNAI_CP_URL="https://cp.example.test" RUNAI_CLIENT_ID="harness-client" RUNAI_CLIENT_SECRET="s3cr3t-value"
        unset RUNAI_CP_CA_FILE RUNAI_CLUSTER_URL
        local kv; for kv in "$@"; do export "${kv?}"; done
        # shellcheck source=tests/uat/lib/runai-harness.sh
        source "${SCRIPT_DIR}/runai-harness.sh"
        sleep() { SECONDS=$(( SECONDS + ${1%.*} )); }
        eval "${cmds}"
    ) < /dev/null > "${dir}/log" 2>&1
}
token_json='{"access_token":"tok-abc","token_type":"Bearer","expires_in":1800}'

# --- credential export -----------------------------------------------------
d="${WORK}/cred-ok"; mkdir -p "${d}"
run_case "${d}" 'printf "%s" "{\"url\":\"https://cp.example.test/\",\"clientId\":\"id1\",\"clientSecret\":\"sec1\",\"caCert\":\"PEM\"}" | runai_credential_export' \
    GITHUB_ENV="${d}/github.env" RUNNER_TEMP="${d}"; rc=$?
if [[ "${rc}" == 0 ]] && grep -qx 'RUNAI_CP_URL=https://cp.example.test' "${d}/github.env" \
   && grep -qx 'RUNAI_CLIENT_ID=id1' "${d}/github.env" && grep -qx 'RUNAI_CLIENT_SECRET=sec1' "${d}/github.env" \
   && grep -q "RUNAI_CP_CA_FILE=${d}/runai-cp-ca.pem" "${d}/github.env" && [[ "$(cat "${d}/runai-cp-ca.pem")" == "PEM" ]] \
   && grep -q '::add-mask::sec1' "${d}/log" && grep -q '::add-mask::id1' "${d}/log"; then
    pass "credential export publishes the three variables, the CA file path, trims the URL and masks id and secret"
else
    fail "credential export: rc=${rc}; env=$(cat "${d}/github.env" 2>/dev/null | tr '\n' ' '); log=$(cat "${d}/log")"
fi
if ! grep -q 'sec1' "${d}/log" | grep -v add-mask; then pass "credential export never echoes the secret except to the masker"; else fail "credential export echoed the secret"; fi

d="${WORK}/cred-missing"; mkdir -p "${d}"
run_case "${d}" 'printf "%s" "{\"url\":\"https://cp\",\"clientId\":\"id1\"}" | runai_credential_export' GITHUB_ENV="${d}/github.env"; rc=$?
[[ "${rc}" != 0 ]] && grep -q 'must carry url, clientId and clientSecret' "${d}/log" && [[ ! -s "${d}/github.env" ]] \
    && pass "credential export fails closed on a missing field and publishes nothing" \
    || fail "credential missing field: rc=${rc} log=$(cat "${d}/log")"

d="${WORK}/cred-scheme"; mkdir -p "${d}"
run_case "${d}" 'printf "%s" "{\"url\":\"http://cp\",\"clientId\":\"id1\",\"clientSecret\":\"s\"}" | runai_credential_export' GITHUB_ENV="${d}/github.env"; rc=$?
[[ "${rc}" != 0 ]] && grep -q 'must be https' "${d}/log" \
    && pass "credential export refuses a plaintext control-plane URL" \
    || fail "credential http url: rc=${rc} log=$(cat "${d}/log")"

d="${WORK}/cred-notjson"; mkdir -p "${d}"
run_case "${d}" 'printf "%s" "not json" | runai_credential_export' GITHUB_ENV="${d}/github.env"; rc=$?
[[ "${rc}" != 0 ]] && grep -q 'not a JSON object' "${d}/log" \
    && pass "credential export fails closed on a non-JSON payload" \
    || fail "credential not json: rc=${rc}"

# --- env guard --------------------------------------------------------------
d="${WORK}/env-missing"; mkdir -p "${d}"
run_case "${d}" 'unset RUNAI_CLIENT_SECRET; runai_prep_register'; rc=$?
[[ "${rc}" != 0 ]] && grep -q 'missing: RUNAI_CLIENT_SECRET' "${d}/log" && [[ ! -f "${d}/stub.curl" ]] \
    && pass "a missing credential variable fails prep by name before any control-plane call" \
    || fail "env guard: rc=${rc} log=$(cat "${d}/log")"

# --- token exchange ---------------------------------------------------------
d="${WORK}/token"; mkdir -p "${d}/responses"; printf '%s' "${token_json}" > "${d}/responses/1.json"
run_case "${d}" 'runai_token && echo "TOKEN_SET=${RUNAI_TOKEN}"'; rc=$?
if [[ "${rc}" == 0 ]] && grep -q 'TOKEN_SET=tok-abc' "${d}/log" \
   && grep -q 'url = "https://cp.example.test/api/v2/token"' "${d}/stub.curl" \
   && grep -q 'data-urlencode = "grant_type=client_credentials"' "${d}/stub.curl" \
   && grep -q 'data-urlencode = "client_secret=s3cr3t-value"' "${d}/stub.curl" \
   && grep -q 'max-time = 60' "${d}/stub.curl"; then
    pass "token exchange is form-encoded client_credentials at /api/v2/token through the stdin config"
else
    fail "token exchange: rc=${rc} log=$(cat "${d}/log") curl=$(cat "${d}/stub.curl" 2>/dev/null)"
fi
if ! grep -q 's3cr3t-value' "${d}/stub.curl-argv"; then pass "the client secret never appears on curl's argv"; else fail "client secret on argv: $(cat "${d}/stub.curl-argv")"; fi
if ! grep -q 'cacert' "${d}/stub.curl"; then pass "no CA option when RUNAI_CP_CA_FILE is unset"; else fail "unexpected cacert line"; fi

d="${WORK}/token-fail"; mkdir -p "${d}/responses"; echo 22 > "${d}/responses/1.rc"; printf '%s' '{"error":"invalid_client"}' > "${d}/responses/1.json"
run_case "${d}" 'runai_token'; rc=$?
[[ "${rc}" != 0 ]] && grep -q 'token request failed' "${d}/log" && grep -q 'invalid_client' "${d}/log" \
    && pass "a rejected token exchange fails with the control plane's own message" \
    || fail "token fail: rc=${rc} log=$(cat "${d}/log")"

# --- prep: cluster record + bundle args -------------------------------------
d="${WORK}/prep"; mkdir -p "${d}/responses"
printf '%s' "${token_json}" > "${d}/responses/1.json"
printf '%s' '{"uuid":"11111111-2222-3333-4444-555555555555","name":"aicr-uat-12345","tenantId":1001}' > "${d}/responses/2.json"
run_case "${d}" 'runai_prep_register && runai_bundle_args' STUB_LB_IP="203.0.113.7"; rc=$?
if [[ "${rc}" == 0 ]] \
   && grep -q 'url = "https://cp.example.test/api/v1/clusters"' "${d}/stub.curl" \
   && grep -q 'header = "Authorization: Bearer tok-abc"' "${d}/stub.curl" \
   && [[ "$(jq -r .name "${d}/stub.body-2")" == "aicr-uat-12345" ]] \
   && [[ "$(jq -r .clusterUuid "${d}/runai-harness.json")" == "11111111-2222-3333-4444-555555555555" ]] \
   && [[ "$(jq -r .clusterUrl "${d}/runai-harness.json")" == "https://runai-cluster.203-0-113-7.sslip.io" ]]; then
    pass "prep creates the cluster record named after the run and pins uuid and derived cluster.url in the state"
else
    fail "prep register: rc=${rc} log=$(cat "${d}/log") state=$(cat "${d}/runai-harness.json" 2>/dev/null)"
fi
want_args='--set runai:controlPlane.url=cp.example.test --set runai:cluster.uid=11111111-2222-3333-4444-555555555555 --set runai:cluster.url=https://runai-cluster.203-0-113-7.sslip.io'
got_args="$(grep -A6 'Run:ai cluster record' "${d}/log" | grep -v 'Run:ai cluster record' | tr '\n' ' ' | sed 's/ $//')"
[[ "${got_args}" == "${want_args}" ]] \
    && pass "bundle args carry the control-plane HOST, the uuid and cluster.url, and never the token" \
    || fail "bundle args: got '${got_args}' want '${want_args}'"
if ! grep -q 'bootstrapToken' "${d}/log"; then pass "bundle args never name the token path (it stays --dynamic in the config)"; else fail "bundle args mention the token"; fi

# Idempotent: a second prep reuses the record instead of creating another.
run_case "${d}" 'runai_prep_register'; rc=$?
[[ "${rc}" == 0 && "$(cat "${d}/stub.curl-count")" == 2 ]] \
    && pass "a re-run of prep reuses the cluster record in the state (no new control-plane call)" \
    || fail "prep idempotency: rc=${rc} calls=$(cat "${d}/stub.curl-count")"

d="${WORK}/prep-nolb"; mkdir -p "${d}/responses"
run_case "${d}" 'runai_prep_register' STUB_LB_IP=""; rc=$?
[[ "${rc}" != 0 ]] && grep -q 'cannot derive cluster.url' "${d}/log" && [[ ! -f "${d}/stub.curl" ]] \
    && pass "without an ingress LoadBalancer address and no RUNAI_CLUSTER_URL, prep fails closed before registering" \
    || fail "prep no LB: rc=${rc} log=$(cat "${d}/log")"

d="${WORK}/prep-url"; mkdir -p "${d}/responses"
printf '%s' "${token_json}" > "${d}/responses/1.json"; printf '%s' '{"uuid":"u-1"}' > "${d}/responses/2.json"
run_case "${d}" 'runai_prep_register' RUNAI_CLUSTER_URL="https://cluster.example.test" RUNAI_CLUSTER_NAME="my-cluster"; rc=$?
[[ "${rc}" == 0 && "$(jq -r .clusterUrl "${d}/runai-harness.json")" == "https://cluster.example.test" && "$(jq -r .name "${d}/stub.body-2")" == "my-cluster" ]] \
    && pass "RUNAI_CLUSTER_URL and RUNAI_CLUSTER_NAME override the derived defaults" \
    || fail "prep overrides: rc=${rc} state=$(cat "${d}/runai-harness.json" 2>/dev/null)"

# --- install: prerequisites, token into the stub, clear ---------------------
d="${WORK}/install"; mkdir -p "${d}/responses" "${d}/bundle/016-runai-cluster"
printf 'controlPlane:\n  bootstrapToken: ""\n' > "${d}/bundle/016-runai-cluster/cluster-values.yaml"
jq -n '{clusterUuid:"u-1", clusterUrl:"https://runai-cluster.203-0-113-7.sslip.io", clusterName:"aicr-uat-12345"}' > "${d}/runai-harness.json"
printf '%s' "${token_json}" > "${d}/responses/1.json"
printf '%s' '{"installationStr":"helm ...","bootstrapToken":"boot-TOKEN-xyz","repositoryName":"runai"}' > "${d}/responses/2.json"
echo "PEM" > "${d}/ca.pem"
run_case "${d}" 'runai_install_prepare && f="$(runai_bundle_values_file bundle)" && runai_mint_token_into "$f" 3.0.20 && echo "STUB=$(yq -r .controlPlane.bootstrapToken "$f")" && runai_clear_token "$f" && echo "CLEARED=[$(yq -r .controlPlane.bootstrapToken "$f")]"' \
    RUNAI_CP_CA_FILE="${d}/ca.pem"; rc=$?
if [[ "${rc}" == 0 ]] && grep -q 'STUB=boot-TOKEN-xyz' "${d}/log" && grep -q 'CLEARED=\[\]' "${d}/log" \
   && grep -q 'url = "https://cp.example.test/api/v1/clusters/u-1/cluster-install-info?version=3.0.20&remoteClusterUrl=https://runai-cluster.203-0-113-7.sslip.io"' "${d}/stub.curl" \
   && grep -q "cacert = \"${d}/ca.pem\"" "${d}/stub.curl"; then
    pass "install mints the token for the pinned version and cluster.url, writes it into the stub and clears it; the CA reaches curl"
else
    fail "install token: rc=${rc} log=$(cat "${d}/log") curl=$(cat "${d}/stub.curl" 2>/dev/null)"
fi
if ! grep -q 'boot-TOKEN-xyz' "${d}/stub.curl-argv" && ! grep -v 'STUB=' "${d}/log" | grep -q 'boot-TOKEN-xyz'; then
    pass "the bootstrap token never appears on argv or in the harness's own output"
else
    fail "token leaked: $(grep -n 'boot-TOKEN' "${d}/log" "${d}/stub.curl-argv")"
fi
if grep -q 'create secret tls runai-cluster-domain-tls-secret --cert=.* --key=' "${d}/stub.kubectl" \
   && grep -q 'create secret tls runai-cluster-domain-star-tls-secret' "${d}/stub.kubectl" \
   && grep -q 'create secret generic runai-ca-cert --from-file=runai-ca.pem=' "${d}/stub.kubectl" \
   && grep -q 'create namespace runai' "${d}/stub.kubectl" \
   && grep -q 'subjectAltName=DNS:runai-cluster.203-0-113-7.sslip.io,DNS:\*.runai-cluster.203-0-113-7.sslip.io' "${d}/stub.openssl"; then
    pass "install prerequisites: namespace, both cluster-domain TLS Secrets for the host and its wildcard, and the CA Secret"
else
    fail "install prerequisites: kubectl=$(cat "${d}/stub.kubectl" 2>/dev/null) openssl=$(cat "${d}/stub.openssl" 2>/dev/null)"
fi

d="${WORK}/install-notoken"; mkdir -p "${d}/responses" "${d}/bundle/016-runai-cluster"
printf 'controlPlane:\n  bootstrapToken: ""\n' > "${d}/bundle/016-runai-cluster/cluster-values.yaml"
jq -n '{clusterUuid:"u-1", clusterUrl:"https://c"}' > "${d}/runai-harness.json"
printf '%s' "${token_json}" > "${d}/responses/1.json"; printf '%s' '{"installationStr":"helm ...","clientSecret":"legacy"}' > "${d}/responses/2.json"
run_case "${d}" 'runai_mint_token_into bundle/016-runai-cluster/cluster-values.yaml 3.0.20'; rc=$?
[[ "${rc}" != 0 ]] && grep -q 'no bootstrapToken' "${d}/log" && [[ "$(yq -r .controlPlane.bootstrapToken "${d}/bundle/016-runai-cluster/cluster-values.yaml")" == "" ]] \
    && pass "an install-info response without bootstrapToken fails closed and leaves the stub empty (the pre-3.0 clientSecret is not accepted)" \
    || fail "install no token: rc=${rc} log=$(cat "${d}/log")"

# The trap in install_helm fires after `cd bundle`, so the path must survive a
# directory change: absolute, and still clearable from inside the bundle.
d="${WORK}/install-abspath"; mkdir -p "${d}/bundle/015-runai-cluster"
printf 'controlPlane:\n  bootstrapToken: "tok"\n' > "${d}/bundle/015-runai-cluster/cluster-values.yaml"
run_case "${d}" 'f="$(runai_bundle_values_file bundle)"; echo "F=${f}"; (cd bundle && runai_clear_token "${f}"); echo "AFTER=[$(yq -r .controlPlane.bootstrapToken "${f}")]"'; rc=$?
# `pwd` canonicalises TMPDIR's trailing slash, so match the suffix and the root.
[[ "${rc}" == 0 ]] && grep -q "^F=/.*/install-abspath/bundle/015-runai-cluster/cluster-values.yaml$" "${d}/log" && grep -q 'AFTER=\[\]' "${d}/log" \
    && pass "the values-file path is absolute and the stub clears from inside the bundle directory" \
    || fail "abs path: rc=${rc} log=$(cat "${d}/log")"

d="${WORK}/install-twobundles"; mkdir -p "${d}/bundle/016-runai-cluster" "${d}/bundle/017-runai-cluster"
touch "${d}/bundle/016-runai-cluster/cluster-values.yaml" "${d}/bundle/017-runai-cluster/cluster-values.yaml"
run_case "${d}" 'runai_bundle_values_file bundle'; rc=$?
[[ "${rc}" != 0 ]] && grep -q 'expected exactly one' "${d}/log" \
    && pass "an ambiguous bundle (two runai-cluster directories) is refused" \
    || fail "two bundles: rc=${rc}"

# --- install: Project --------------------------------------------------------
d="${WORK}/project"; mkdir -p "${d}/responses"
jq -n '{clusterUuid:"u-1", clusterUrl:"https://c"}' > "${d}/runai-harness.json"
printf '%s' "${token_json}" > "${d}/responses/1.json"
printf '%s' '{"nodepools":[{"id":"7","name":"default","clusterId":"u-1","isDefault":true}]}' > "${d}/responses/2.json"
printf '%s' '{"id":"42","name":"aicr-uat-12345","requestedNamespace":"runai-aicr-uat-12345","status":{"phase":"Creating"}}' > "${d}/responses/3.json"
run_case "${d}" 'runai_create_project'; rc=$?
if [[ "${rc}" == 0 ]] \
   && grep -q 'url = "https://cp.example.test/api/v1/node-pools?filterBy=clusterId==u-1"' "${d}/stub.curl" \
   && grep -q 'url = "https://cp.example.test/api/v1/org-unit/projects"' "${d}/stub.curl" \
   && [[ "$(jq -c '{name,clusterId,requestedNamespace,np:.resources[0].nodePool.id,cpu:.resources[0].cpu.deserved,mem:.resources[0].memory.deserved,units:.resources[0].memory.units,gpu:.resources[0].gpu.deserved}' "${d}/stub.body-3")" == '{"name":"aicr-uat-12345","clusterId":"u-1","requestedNamespace":"runai-aicr-uat-12345","np":"7","cpu":4000,"mem":8192,"units":"Mib","gpu":0}' ]] \
   && [[ "$(jq -r .projectId "${d}/runai-harness.json")" == "42" ]] \
   && [[ "$(jq -r .projectNamespace "${d}/runai-harness.json")" == "runai-aicr-uat-12345" ]]; then
    pass "the Project is created on the default node pool with an explicit CPU/memory quota, no GPU, and a pinned runai-<name> namespace"
else
    fail "project: rc=${rc} log=$(cat "${d}/log") body=$(cat "${d}/stub.body-3" 2>/dev/null)"
fi
run_case "${d}" 'runai_create_project'; rc=$?
[[ "${rc}" == 0 && "$(cat "${d}/stub.curl-count")" == 3 ]] \
    && pass "a re-run does not create a second Project" \
    || fail "project idempotency: rc=${rc} calls=$(cat "${d}/stub.curl-count")"

d="${WORK}/project-nopool"; mkdir -p "${d}/responses"
jq -n '{clusterUuid:"u-1"}' > "${d}/runai-harness.json"
printf '%s' "${token_json}" > "${d}/responses/1.json"; printf '%s' '{"nodepools":[]}' > "${d}/responses/2.json"
run_case "${d}" 'runai_create_project'; rc=$?
[[ "${rc}" != 0 ]] && grep -q 'no default node pool' "${d}/log" && [[ "$(cat "${d}/stub.curl-count")" == 2 ]] \
    && pass "no default node pool yet: the Project is not created and the phase fails with the reason" \
    || fail "project no pool: rc=${rc} log=$(cat "${d}/log")"

d="${WORK}/project-longname"; mkdir -p "${d}/responses"
jq -n '{clusterUuid:"u-1"}' > "${d}/runai-harness.json"
run_case "${d}" 'runai_create_project' RUNAI_PROJECT_NAME="$(printf 'x%.0s' $(seq 1 60))"; rc=$?
[[ "${rc}" != 0 ]] && grep -q 'not a DNS label' "${d}/log" && [[ ! -f "${d}/stub.curl" ]] \
    && pass "a Project whose namespace would exceed a DNS label is refused before any call" \
    || fail "project long name: rc=${rc}"

# --- conformance: namespace input --------------------------------------------
d="${WORK}/ns-ok"; mkdir -p "${d}/responses"
jq -n '{projectNamespace:"runai-aicr-uat-12345", projectId:"42"}' > "${d}/runai-harness.json"
run_case "${d}" 'runai_export_project_namespace && echo "EXPORTED=${AICR_RUNAI_PROJECT_NAMESPACE}"' \
    STUB_NS_JSON='{"metadata":{"name":"runai-aicr-uat-12345","labels":{"runai/queue":"aicr-uat-12345"}}}'; rc=$?
[[ "${rc}" == 0 ]] && grep -q 'EXPORTED=runai-aicr-uat-12345' "${d}/log" && grep -q 'runai/queue=aicr-uat-12345' "${d}/log" \
    && pass "a labelled Project namespace exports AICR_RUNAI_PROJECT_NAMESPACE" \
    || fail "ns ok: rc=${rc} log=$(cat "${d}/log")"

d="${WORK}/ns-nolabel"; mkdir -p "${d}/responses"
jq -n '{projectNamespace:"runai-aicr-uat-12345"}' > "${d}/runai-harness.json"
run_case "${d}" 'runai_export_project_namespace' STUB_NS_JSON='{"metadata":{"name":"runai-aicr-uat-12345","labels":{}}}' RUNAI_PROJECT_NAMESPACE_TIMEOUT_SECONDS=30; rc=$?
[[ "${rc}" != 0 ]] && grep -q 'did not appear with a runai/queue label within 30s' "${d}/log" \
    && pass "a namespace without the runai/queue label fails the wait, bounded by the budget" \
    || fail "ns no label: rc=${rc} log=$(cat "${d}/log")"

d="${WORK}/ns-nostate"; mkdir -p "${d}/responses"
run_case "${d}" 'runai_export_project_namespace'; rc=$?
[[ "${rc}" != 0 ]] && grep -q 'no Run:ai Project namespace' "${d}/log" \
    && pass "no Project in the state fails the export with the reason" \
    || fail "ns no state: rc=${rc}"

# --- unregister ---------------------------------------------------------------
d="${WORK}/unreg"; mkdir -p "${d}/responses"
jq -n '{clusterUuid:"u-1", projectId:"42"}' > "${d}/runai-harness.json"
printf '%s' "${token_json}" > "${d}/responses/1.json"
run_case "${d}" 'phase_unregister'; rc=$?
if [[ "${rc}" == 0 ]] \
   && grep -q 'url = "https://cp.example.test/api/v1/org-unit/projects/42"' "${d}/stub.curl" \
   && grep -q 'url = "https://cp.example.test/api/v1/clusters/u-1?force=true"' "${d}/stub.curl" \
   && [[ "$(grep -c 'request = "DELETE"' "${d}/stub.curl")" == 2 ]] \
   && [[ "$(jq -r .projectDeleted "${d}/runai-harness.json")" == "true" && "$(jq -r .clusterDeleted "${d}/runai-harness.json")" == "true" ]]; then
    pass "unregister deletes the Project then force-deletes the cluster record and marks both in the state"
else
    fail "unregister: rc=${rc} log=$(cat "${d}/log") curl=$(cat "${d}/stub.curl" 2>/dev/null)"
fi
# Project before cluster: the order of the two DELETE urls in the log.
[[ "$(grep -n 'url = ' "${d}/stub.curl" | grep -n 'projects/42' | cut -d: -f1)" == "2" ]] \
    && pass "the Project is deleted before the cluster record" || fail "delete order wrong: $(grep 'url = ' "${d}/stub.curl")"

d="${WORK}/unreg-fail"; mkdir -p "${d}/responses"
jq -n '{clusterUuid:"u-1", projectId:"42"}' > "${d}/runai-harness.json"
printf '%s' "${token_json}" > "${d}/responses/1.json"
echo 22 > "${d}/responses/2.rc"; printf '%s' '{"code":500,"message":"boom"}' > "${d}/responses/2.json"
run_case "${d}" 'phase_unregister'; rc=$?
[[ "${rc}" != 0 ]] && grep -q 'deleting Project 42 failed' "${d}/log" && [[ "$(jq -r .clusterDeleted "${d}/runai-harness.json")" == "true" ]] \
    && pass "a failed Project delete fails the phase but the cluster record is still deleted" \
    || fail "unregister fail: rc=${rc} log=$(cat "${d}/log") state=$(cat "${d}/runai-harness.json")"

d="${WORK}/unreg-nostate"; mkdir -p "${d}/responses"
run_case "${d}" 'unset RUNAI_CLIENT_SECRET; phase_unregister'; rc=$?
[[ "${rc}" == 0 ]] && grep -q 'nothing was registered' "${d}/log" && [[ ! -f "${d}/stub.curl" ]] \
    && pass "unregister with no state is a no-op, even without the credential" \
    || fail "unregister no state: rc=${rc} log=$(cat "${d}/log")"

# --- recipe predicate ---------------------------------------------------------
d="${WORK}/recipe"; mkdir -p "${d}"
cat > "${d}/with.yaml" <<'Y'
componentRefs:
  - name: kai-scheduler
    overrides:
      enabled: false
  - name: runai-cluster
    version: 3.0.20
Y
cat > "${d}/disabled.yaml" <<'Y'
componentRefs:
  - name: runai-cluster
    overrides:
      enabled: false
Y
cat > "${d}/without.yaml" <<'Y'
componentRefs:
  - name: kai-scheduler
Y
run_case "${d}" 'uat_recipe_declares_runai with.yaml && echo WITH; uat_recipe_declares_runai disabled.yaml || echo DISABLED; uat_recipe_declares_runai without.yaml || echo WITHOUT; uat_recipe_declares_runai missing.yaml || echo MISSING; echo "V=$(uat_recipe_runai_version with.yaml)"'
if grep -q '^WITH$' "${d}/log" && grep -q '^DISABLED$' "${d}/log" && grep -q '^WITHOUT$' "${d}/log" && grep -q '^MISSING$' "${d}/log" && grep -q '^V=3.0.20$' "${d}/log"; then
    pass "the recipe predicate counts only an enabled runai-cluster ref and reads its pinned version"
else
    fail "recipe predicate: $(cat "${d}/log")"
fi

echo
if (( fails > 0 )); then
    echo "FAILED: ${fails} of ${ran} runai-harness_test cases" >&2
    exit 1
fi
echo "All ${ran} runai-harness_test cases passed"
