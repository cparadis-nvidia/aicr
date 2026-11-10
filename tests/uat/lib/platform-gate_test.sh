#!/bin/bash
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

# Guards both gates on the `platform` dispatch axis:
#
#   A. .github/workflows/uat-run.yaml, `resolve` job, "Resolve reservation row".
#      Answers "can this LANE serve a platform at all". run-kind, run-aws and
#      run-gcp forward the input; uat-azure.yaml declares no platform input and
#      builds TEST_CONFIG from intent alone, so a platform dispatched at an
#      Azure reservation would be dropped at the job boundary and that cell
#      would run its default per-intent config to completion and report
#      SUCCESS for a recipe nobody asked for. Nothing on that path fails,
#      because the default config exists, so the pipeline's own "test config
#      not found" check never fires. (Every cloud lane used to be in that
#      position; the EKS and GKE lanes gained the input for runai, #3302.)
#
#   B. Each forwarding lane's "Validate inputs". Answers "is this a value this
#      lane admits":
#        - uat-kind.yaml admits the empty one and nothing else: its cluster is
#          single-node nvkind and the only other platform in the tree, slurm,
#          needs four schedulable nodes. Admitting it would spend a slot on a
#          leased GPU runner before failing on three Pending slurmd pods. The
#          cell runs on uat-kind-sim.yaml instead.
#        - uat-aws.yaml and uat-gcp.yaml admit the empty one and runai, the
#          Run:ai cell (#3302), whose h100-training-runai-config.yaml they
#          carry.
#
# The two are deliberately separate: A is per-lane, B is per-value. Asserting
# both here keeps them from being merged into one duplicated list that drifts.
#
# Why it reads the workflows instead of holding a copy: each subject is
# EXTRACTED with yq at run time and executed verbatim, so this file cannot drift
# from the steps it protects. A transcribed copy would keep passing after
# someone edited the real one.
#
# Hermetic: `tools/uat-broker` is a local Go program that the resolve job's
# "Build uat-broker" step (also extracted and run here) builds from source, and `infra/uat/reservations.yaml` and the test configs are
# in-repo. No network, no cluster, no prebuilt binary.
#
# It never skips. A missing yq, a missing go, or a step that cannot be extracted
# is a FAILURE, not a skip: a suite that switches itself off when a dependency
# is absent reports green while checking nothing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve the subjects from SCRIPT_DIR, not from the caller's cwd, so the files
# under test are the ones in THIS worktree however the suite is invoked.
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RUN_WORKFLOW="${REPO_ROOT}/.github/workflows/uat-run.yaml"
KIND_WORKFLOW="${REPO_ROOT}/.github/workflows/uat-kind.yaml"
AWS_WORKFLOW="${REPO_ROOT}/.github/workflows/uat-aws.yaml"
GCP_WORKFLOW="${REPO_ROOT}/.github/workflows/uat-gcp.yaml"

fail=0
check() {
    local desc="$1" want="$2" got="$3"
    if [[ "${want}" != "${got}" ]]; then
        echo "FAIL: ${desc}: want '${want}', got '${got}'" >&2
        fail=1
    else
        echo "ok: ${desc}"
    fi
}

# Hard preconditions. Each aborts the suite rather than skipping a case.
abort() { echo "FAIL: $*" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || abort "yq is not on PATH; it is required to extract the steps under test"
command -v go >/dev/null 2>&1 || abort "go is not on PATH; the extracted build step builds tools/uat-broker from source"
[[ -f "${RUN_WORKFLOW}" ]] || abort "workflow not found: ${RUN_WORKFLOW}"
[[ -f "${KIND_WORKFLOW}" ]] || abort "workflow not found: ${KIND_WORKFLOW}"
[[ -f "${AWS_WORKFLOW}" ]] || abort "workflow not found: ${AWS_WORKFLOW}"
[[ -f "${GCP_WORKFLOW}" ]] || abort "workflow not found: ${GCP_WORKFLOW}"

WORK="$(mktemp -d)" || abort "could not create a temporary directory"
trap 'rm -rf "${WORK}"' EXIT

# extract_step <workflow> <yq job selector> <step name> <dest> <marker>
#
# yq prints the literal "null" (exit 0) when the selection matches nothing, so
# an empty or null extraction has to be rejected explicitly: a suite run against
# an empty subject would report every case as it pleased. The marker confirms
# the step that came back is the one intended, so a rename cannot silently hand
# the suite a different step.
extract_step() {
    local wf="$1" job="$2" name="$3" dest="$4" marker="$5"
    yq -r "${job}.steps[] | select(.name == \"${name}\") | .run" "${wf}" \
       > "${dest}" 2>"${WORK}/yq.err" \
       || abort "yq failed on ${wf}: $(cat "${WORK}/yq.err")"
    if [[ ! -s "${dest}" ]] || [[ "$(cat "${dest}")" == "null" ]]; then
        abort "could not extract the '${name}' step from ${wf} (renamed or removed?)"
    fi
    grep -q -- "${marker}" "${dest}" \
        || abort "the extracted '${name}' step from ${wf} lacks '${marker}'; wrong step extracted"
    echo "ok: extracted '${name}' from $(basename "${wf}") ($(wc -l < "${dest}" | tr -d ' ') lines)"
}

BUILD_STEP="${WORK}/build-step.sh"
RESOLVE_STEP="${WORK}/resolve-step.sh"
KIND_STEP="${WORK}/kind-validate-step.sh"
AWS_STEP="${WORK}/aws-validate-step.sh"
GCP_STEP="${WORK}/gcp-validate-step.sh"
extract_step "${RUN_WORKFLOW}" '.jobs.resolve' 'Build uat-broker' \
             "${BUILD_STEP}" 'tools/uat-broker'
extract_step "${RUN_WORKFLOW}" '.jobs.resolve' 'Resolve reservation row' \
             "${RESOLVE_STEP}" 'uat-broker reservations'
extract_step "${KIND_WORKFLOW}" '.jobs["uat-kind"]' 'Validate inputs' \
             "${KIND_STEP}" 'unsupported platform'
extract_step "${AWS_WORKFLOW}" '.jobs["uat-aws"]' 'Validate inputs' \
             "${AWS_STEP}" 'unsupported platform'
extract_step "${GCP_WORKFLOW}" '.jobs["uat-gcp"]' 'Validate inputs' \
             "${GCP_STEP}" 'unsupported platform'

# ---------------------------------------------------------------------------
# Gate A: uat-run.yaml, can this lane serve a platform at all
# ---------------------------------------------------------------------------

# The resolve step runs the ./bin/uat-broker an earlier step of the same job
# builds, so build it once here the same way.
( cd "${REPO_ROOT}" && bash "${BUILD_STEP}" ) > "${WORK}/build.log" 2>&1 \
    || abort "the extracted 'Build uat-broker' step failed: $(cat "${WORK}/build.log")"

# run_resolve <reservation> <platform> -> rc, publishing into ${WORK}/row.txt.
# cwd is the repo root because the step resolves ./tools and ./bin relative to
# it, exactly as it does on a runner. The nvsentinel_remediation axis (gate C
# below) is held at its dispatch defaults unless the caller exports overrides.
run_resolve() {
    : > "${WORK}/row.txt"
    ( cd "${REPO_ROOT}" \
      && RESERVATION="$1" SLOT=0 PLATFORM="$2" GITHUB_OUTPUT="${WORK}/row.txt" \
         NVSENTINEL_REMEDIATION="${NVSENTINEL_REMEDIATION:-none}" \
         INTENT="${INTENT:-training}" LIFECYCLE="${LIFECYCLE:-nightly}" \
         DEPLOYER="${DEPLOYER:-helmfile}" AICR_VERSION="${AICR_VERSION:-}" \
         bash "${RESOLVE_STEP}" ) > "${WORK}/step.log" 2>&1
}
lane_verdict() {
    if run_resolve "$1" "$2"; then echo accept; else echo reject; fi
}

# Preconditions on the registry rows the cases below name. Without these, a
# renamed or deleted reservation would surface as a puzzling accept/reject
# mismatch instead of naming the missing row.
for pair in "aws-h100:aws" "gcp-h100:gcp" "azure-h100:azure" "kind-h100:kind"; do
    res="${pair%%:*}"; want_cloud="${pair##*:}"
    run_resolve "${res}" ""
    check "reservation ${res} resolves and publishes cloud=${want_cloud}" \
        "cloud=${want_cloud}" "$(grep '^cloud=' "${WORK}/row.txt")"
done

# REJECT: a non-empty platform at a lane that cannot serve it. These are the
# false-green dispatches gate A exists to stop. Azure is the one cloud lane
# that still declares no platform input.
check "azure lane rejects platform=slurm" "reject" "$(lane_verdict azure-h100 slurm)"
check "azure lane rejects platform=runai" "reject" "$(lane_verdict azure-h100 runai)"

# Gate A is an ALLOWLIST of lanes, not a denylist of platform values. These two
# discriminate the shapes: a denylist naming slurm would let both through.
check "azure lane rejects platform=kubeflow, not just slurm" "reject" "$(lane_verdict azure-h100 kubeflow)"
check "azure lane rejects a platform that exists nowhere"    "reject" "$(lane_verdict azure-h100 nosuch)"

# ACCEPT: every path that must keep working. The four empty-platform cases are
# the backward-compatibility guarantee for every cell that predates this input.
check "aws lane accepts an empty platform"   "accept" "$(lane_verdict aws-h100 '')"
check "gcp lane accepts an empty platform"   "accept" "$(lane_verdict gcp-h100 '')"
check "azure lane accepts an empty platform" "accept" "$(lane_verdict azure-h100 '')"
check "kind lane accepts an empty platform"  "accept" "$(lane_verdict kind-h100 '')"
check "kind lane accepts platform=slurm"     "accept" "$(lane_verdict kind-h100 slurm)"
check "aws lane accepts platform=runai"      "accept" "$(lane_verdict aws-h100 runai)"
check "gcp lane accepts platform=runai"      "accept" "$(lane_verdict gcp-h100 runai)"

# Deliberate division of responsibility: gate A answers "can this LANE serve a
# platform at all", gate B answers "is this a value the lane has a config
# for". Asserting the accepts here pins that split for every forwarding lane.
check "kind lane accepts an unknown platform, value validation is gate B's job" \
    "accept" "$(lane_verdict kind-h100 nosuch)"
check "aws lane accepts an unknown platform, value validation is gate B's job" \
    "accept" "$(lane_verdict aws-h100 nosuch)"
check "gcp lane accepts an unknown platform, value validation is gate B's job" \
    "accept" "$(lane_verdict gcp-h100 nosuch)"

# What actually stops a cloud lane from starting is that no `cloud` output is
# published on the rejected path, NOT that the step exits non-zero: run-aws,
# run-gcp and run-azure carry `always()`, which runs a job whose `needs` failed.
# With no output, their `needs.resolve.outputs.cloud == '<cloud>'` compares the
# empty string against a literal and cannot match. Asserting the absence keeps
# a future edit from moving the publish back above the gate.
run_resolve azure-h100 slurm
check "a rejected dispatch publishes NO row at all" "0" \
    "$(wc -l < "${WORK}/row.txt" | tr -d ' ')"
check "a rejected dispatch publishes no cloud output" "0" \
    "$(grep -c '^cloud=' "${WORK}/row.txt")"

# The rejection has to name the platform and the lane, or an operator reading a
# red run has to go source-diving to learn what was wrong with the dispatch.
check "the rejection names the platform" "1" \
    "$(grep -c "platform='slurm'" "${WORK}/step.log")"
check "the rejection names the resolved lane" "1" \
    "$(grep -c "'azure' lane" "${WORK}/step.log")"

# ---------------------------------------------------------------------------
# Gate C: uat-run.yaml, can this cell compose an NVSentinel remediation mixin
# ---------------------------------------------------------------------------

# remediation_verdict <reservation> <step> [VAR=value...] -> accept | reject.
# The subshell keeps each case's overrides from leaking into the next.
remediation_verdict() {
    local res="$1" step="$2"; shift 2
    if ( export NVSENTINEL_REMEDIATION="${step}"; local kv; for kv in "$@"; do export "${kv?}"; done
         run_resolve "${res}" '' ); then
        echo accept
    else
        echo reject
    fi
}

check "none is accepted everywhere it was before"     "accept" "$(remediation_verdict aws-h100 none)"
check "aws accepts quarantine"                        "accept" "$(remediation_verdict aws-h100 quarantine)"
check "aws accepts remediation"                       "accept" "$(remediation_verdict aws-h100 remediation)"
check "azure accepts remediation"                     "accept" "$(remediation_verdict azure-h100 remediation)"
check "gcp accepts quarantine"                        "accept" "$(remediation_verdict gcp-h100 quarantine)"
# The GKE managed driver cannot host janitor's GPU reset, so the bundle would
# refuse nvsentinel-remediation; refusing here costs no lease.
check "gcp rejects remediation"                       "reject" "$(remediation_verdict gcp-h100 remediation)"
check "kind rejects quarantine"                       "reject" "$(remediation_verdict kind-h100 quarantine)"
check "an unknown step is rejected"                   "reject" "$(remediation_verdict aws-h100 observe)"
check "inference is rejected"                         "reject" "$(remediation_verdict aws-h100 remediation INTENT=inference)"
check "a daytime lifecycle is rejected"               "reject" "$(remediation_verdict aws-h100 quarantine LIFECYCLE=daytime-up)"
check "the argocd deployer is rejected"               "reject" "$(remediation_verdict aws-h100 remediation DEPLOYER=argocd)"
check "a released aicr_version is rejected"           "reject" "$(remediation_verdict aws-h100 remediation AICR_VERSION=v1.0.0)"

remediation_verdict aws-h100 remediation INTENT=inference >/dev/null
check "a rejected remediation dispatch publishes no cloud output" "0" \
    "$(grep -c '^cloud=' "${WORK}/row.txt")"
check "the rejection names the failed bound" "1" \
    "$(grep -c "intent must be training" "${WORK}/step.log")"

# ---------------------------------------------------------------------------
# Gate B: uat-kind.yaml, is this a value the kind lane has a config for
# ---------------------------------------------------------------------------

# Every case below passes an EXISTING TEST_CONFIG, so a rejection can only come
# from the platform allowlist and never from the file-existence check that
# follows it. The one case that probes that check supplies a missing path on
# purpose.
KIND_CONFIG="tests/uat/kind/tests/h100-training-config.yaml"
[[ -f "${REPO_ROOT}/${KIND_CONFIG}" ]] || abort "fixture missing: ${KIND_CONFIG}"

run_kind() { # <platform> [test-config]
    ( cd "${REPO_ROOT}" \
      && INTENT=training PLATFORM="$1" LIFECYCLE=nightly \
         TEST_CONFIG="${2:-${KIND_CONFIG}}" KIND_CLUSTER_NAME=uat-kind-training \
         bash "${KIND_STEP}" ) > "${WORK}/kind.log" 2>&1
}
value_verdict() {
    if run_kind "$@"; then echo accept; else echo reject; fi
}

# The empty value is the backward-compatibility guarantee for every cell that
# predates this input, and it is now the ONLY admitted value.
check "kind allowlist accepts an empty platform" "accept" "$(value_verdict '')"
check "kind allowlist rejects slurm"             "reject" "$(value_verdict slurm)"

# The gate is an allowlist of the values this lane admits, not a denylist that
# names slurm. Written the other way round -- reject slurm, accept the rest --
# it would pass the case above and let all three of these through to a
# TEST_CONFIG path that does not exist.
check "kind allowlist rejects kubeflow" "reject" "$(value_verdict kubeflow)"
check "kind allowlist rejects dynamo"   "reject" "$(value_verdict dynamo)"
check "kind allowlist rejects a platform that exists nowhere" "reject" "$(value_verdict nosuch)"

# Comparison stays verbatim, with no normalization added on top. A rewrite that
# trimmed or stripped whitespace before comparing would map a whitespace-only
# dispatch onto the accepted empty value, and the lane would silently run its
# default config for a request that asked for something else.
check "kind allowlist rejects Slurm"                    "reject" "$(value_verdict Slurm)"
check "kind allowlist rejects a leading-space platform" "reject" "$(value_verdict ' slurm')"
check "kind allowlist rejects a whitespace-only platform" "reject" "$(value_verdict ' ')"

# An operator reading a red run must learn what was wrong AND where the cell
# they wanted actually runs, or the rejection just moves the source-diving.
run_kind Slurm
check "the kind rejection names the offending value" "1" \
    "$(grep -c "unsupported platform: 'Slurm'" "${WORK}/kind.log")"
check "the kind rejection points at the lane that serves the cell" "1" \
    "$(grep -c 'uat-kind-sim.yaml' "${WORK}/kind.log")"

# The file-existence check behind the allowlist must stay fail-closed: it is
# what catches an admitted platform whose config was never added.
check "kind lane rejects an admitted platform whose config is missing" \
    "reject" "$(value_verdict '' 'tests/uat/kind/tests/does-not-exist.yaml')"

# ---------------------------------------------------------------------------
# Gate B, cloud lanes: uat-aws.yaml and uat-gcp.yaml admit runai and nothing else
# ---------------------------------------------------------------------------

# Both steps are run verbatim with the job-level env they read: the cloud
# cluster-config (in-repo), a TEST_CONFIG that exists so a rejection can only
# come from the platform allowlist, and a scratch GITHUB_ENV for the account
# and region exports the aws step writes before its lifecycle gates.
AWS_CONFIG="tests/uat/aws/tests/h100-training-runai-config.yaml"
GCP_CONFIG="tests/uat/gcp/tests/h100-training-runai-config.yaml"
[[ -f "${REPO_ROOT}/${AWS_CONFIG}" ]] || abort "fixture missing: ${AWS_CONFIG}"
[[ -f "${REPO_ROOT}/${GCP_CONFIG}" ]] || abort "fixture missing: ${GCP_CONFIG}"

run_cloud() { # <aws|gcp> <platform> [test-config]
    local cloud="$1" platform="$2" cfg="${3:-}" step cluster_cfg
    : > "${WORK}/github.env"
    case "${cloud}" in
        aws) step="${AWS_STEP}"; cluster_cfg="tests/uat/aws/cluster-config.yaml"; cfg="${cfg:-${AWS_CONFIG}}" ;;
        gcp) step="${GCP_STEP}"; cluster_cfg="tests/uat/gcp/cluster-config.yaml"; cfg="${cfg:-${GCP_CONFIG}}" ;;
    esac
    ( cd "${REPO_ROOT}" \
      && INTENT=training PLATFORM="${platform}" LIFECYCLE=nightly SLUG=ah1 SLOT=0 \
         DEPLOYER=helmfile TEST_CONFIG="${cfg}" CLUSTER_CONFIG="${cluster_cfg}" \
         DEPLOYMENT_ID=aicr-uat-test GITHUB_ENV="${WORK}/github.env" \
         bash "${step}" ) > "${WORK}/${cloud}.log" 2>&1
}
cloud_verdict() {
    if run_cloud "$@"; then echo accept; else echo reject; fi
}

for cloud in aws gcp; do
    check "${cloud} allowlist accepts an empty platform" "accept" "$(cloud_verdict "${cloud}" '')"
    check "${cloud} allowlist accepts runai"             "accept" "$(cloud_verdict "${cloud}" runai)"
    # An allowlist of the values this lane admits, not a denylist: every other
    # value in the tree, and every value that exists nowhere, is refused.
    check "${cloud} allowlist rejects slurm"    "reject" "$(cloud_verdict "${cloud}" slurm)"
    check "${cloud} allowlist rejects kubeflow" "reject" "$(cloud_verdict "${cloud}" kubeflow)"
    check "${cloud} allowlist rejects a platform that exists nowhere" "reject" "$(cloud_verdict "${cloud}" nosuch)"
    # Verbatim comparison, as on the kind lane: no normalization may map a
    # padded or capitalised value onto an admitted one.
    check "${cloud} allowlist rejects Runai"                    "reject" "$(cloud_verdict "${cloud}" Runai)"
    check "${cloud} allowlist rejects a leading-space platform" "reject" "$(cloud_verdict "${cloud}" ' runai')"
    run_cloud "${cloud}" Runai
    check "the ${cloud} rejection names the offending value" "1" \
        "$(grep -c "unsupported platform: 'Runai'" "${WORK}/${cloud}.log")"
    # The file-existence check stays behind the allowlist, fail-closed.
    check "${cloud} lane rejects an admitted platform whose config is missing" \
        "reject" "$(cloud_verdict "${cloud}" runai "tests/uat/${cloud}/tests/does-not-exist.yaml")"
done

if [[ "${fail}" -ne 0 ]]; then
    echo "FAILED" >&2
    exit 1
fi
echo "PASSED"
