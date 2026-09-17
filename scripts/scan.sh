#!/usr/bin/env bash
# Scan an image with Trivy (run through Docker, no install needed) and enforce the policy:
#   - fail on any CRITICAL finding, OS packages or libraries
#   - fail if any CVE that blocked the official cubejs/cube image is present
# Usage: scripts/scan.sh <image> [report.json]
set -euo pipefail
IMAGE="${1:?image}"
OUT="${2:-trivy.json}"
TRIVY_IMAGE="aquasec/trivy:0.74.0"
BLOCKED_CVES="CVE-2022-41853 CVE-2019-10744 CVE-2026-4800"

mkdir -p "${HOME}/.cache/trivy"
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${HOME}/.cache/trivy:/root/.cache/trivy" \
  -v "${PWD}:/work" -w /work \
  "${TRIVY_IMAGE}" image \
    --scanners vuln --format json --output "/work/${OUT}" \
    --db-repository mirror.gcr.io/aquasec/trivy-db:2,ghcr.io/aquasecurity/trivy-db:2,public.ecr.aws/aquasecurity/trivy-db:2 \
    "${IMAGE}"

echo "== findings by severity"
jq -r '[.Results[]?.Vulnerabilities[]?] | group_by(.Severity) | map("\(.[0].Severity) \(length)") | .[]' "${OUT}"
echo "== CRITICAL / HIGH"
jq -r '.Results[]? as $r | $r.Vulnerabilities[]?
       | select(.Severity == "CRITICAL" or .Severity == "HIGH")
       | "\(.Severity)\t\(.VulnerabilityID)\t\(.PkgName)@\(.InstalledVersion)\tfixed=\(.FixedVersion // "none")\t\($r.Target)"' "${OUT}" | sort -u

fail=0
crit=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' "${OUT}")
if [ "${crit}" -ne 0 ]; then echo "FAIL: ${crit} CRITICAL finding(s)"; fail=1; fi
for cve in ${BLOCKED_CVES}; do
  if jq -e --arg c "${cve}" '[.Results[]?.Vulnerabilities[]? | select(.VulnerabilityID == $c)] | length > 0' "${OUT}" >/dev/null; then
    echo "FAIL: ${cve} is still present"; fail=1
  fi
done
if [ "${fail}" -eq 0 ]; then echo "PASS: 0 CRITICAL, blocked CVEs absent"; fi
exit "${fail}"
