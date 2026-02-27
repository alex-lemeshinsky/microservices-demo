#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${1:-flash-aviary-488614-c1}"
DASHBOARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/dashboards" && pwd)"

for dashboard_file in "${DASHBOARD_DIR}"/*.json; do
  display_name="$(python3 - <<'PY' "${dashboard_file}"
import json,sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f)["displayName"])
PY
)"

  existing_name="$(
    gcloud monitoring dashboards list \
      --project "${PROJECT_ID}" \
      --format="value(name,displayName)" \
      | awk -F '\t' -v dn="${display_name}" '$2==dn {print $1; exit}'
  )"

  if [[ -n "${existing_name}" ]]; then
    etag="$(
      gcloud monitoring dashboards describe "${existing_name}" \
        --project "${PROJECT_ID}" \
        --format="value(etag)"
    )"

    tmp_config="$(mktemp)"
    python3 - <<'PY' "${dashboard_file}" "${tmp_config}" "${existing_name}" "${etag}"
import json, sys
src, dst, name, etag = sys.argv[1:5]
with open(src, "r", encoding="utf-8") as f:
    payload = json.load(f)
payload["name"] = name
payload["etag"] = etag
with open(dst, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
PY

    gcloud monitoring dashboards update "${existing_name}" \
      --project "${PROJECT_ID}" \
      --config-from-file="${tmp_config}" >/dev/null

    rm -f "${tmp_config}"
  else
    gcloud monitoring dashboards create \
      --project "${PROJECT_ID}" \
      --config-from-file="${dashboard_file}" >/dev/null
  fi

  echo "Applied dashboard: ${display_name}"
done

echo "Dashboards deployed to project: ${PROJECT_ID}"
