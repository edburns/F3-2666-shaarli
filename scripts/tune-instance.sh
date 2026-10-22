#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-shaarli.sh"

readonly TUNE_DEFAULT_CPU="0.5"
readonly TUNE_DEFAULT_MEMORY="1.0Gi"
readonly TUNE_DEFAULT_THUMBNAILS="none"

usage() {
  cat <<'EOF'
Usage: tune-instance.sh INSTANCE [--cpu N] [--memory NGi] [--thumbnails MODE]
                                 [--show] [--yes]

Apply the performance retrofit to an existing Shaarli instance.

Two changes, both in place. Neither touches the datastore, the app's hostname,
or the Entra registration:

  1. Raise the container's CPU and memory. Cold start is dominated by PHP
     startup, template compilation, and reading the datastore, all of which are
     CPU bound. Container Apps bills allocated resources by the second while a
     replica runs, so with minReplicas 0 an idle instance still costs nothing --
     the larger allocation only applies during the seconds a request is served.

  2. Set the thumbnail mode. "all" makes Shaarli fetch and resize a remote image
     for every bookmark on first display, which is the most expensive thing it
     can do on a small container, and the cache is discarded on every
     scale-to-zero cycle. "none" turns it off; "common" limits it to known media
     sites.

Scale-to-zero is left alone. Setting minReplicas to 1 would remove cold start
entirely but means paying for a continuously running replica.

Options:
  --cpu          vCPU allocation (default: 0.5)
  --memory       Memory allocation, must be 2Gi per vCPU (default: 1.0Gi)
  --thumbnails   none, common, or all (default: none)
  --show         Report the current settings and exit
  --yes          Do not prompt for confirmation
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ $# -ge 1 ]] || {
  usage >&2
  exit 2
}

instance_name="$1"
shift
cpu="$TUNE_DEFAULT_CPU"
memory="$TUNE_DEFAULT_MEMORY"
thumbnails="$TUNE_DEFAULT_THUMBNAILS"
show_only="false"
assume_yes="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu)
      [[ $# -ge 2 ]] || die "--cpu requires a value"
      cpu="$2"
      shift 2
      ;;
    --memory)
      [[ $# -ge 2 ]] || die "--memory requires a value"
      memory="$2"
      shift 2
      ;;
    --thumbnails)
      [[ $# -ge 2 ]] || die "--thumbnails requires a value"
      thumbnails="$2"
      shift 2
      ;;
    --show)
      show_only="true"
      shift
      ;;
    --yes)
      assume_yes="true"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "$thumbnails" in
  none | common | all) ;;
  *) die "--thumbnails must be one of: none, common, all" ;;
esac

# Container Apps only accepts CPU/memory pairs at a fixed 1:2 ratio. Getting
# this wrong produces an opaque server-side rejection, so check it here.
python3 - "$cpu" "$memory" <<'PY' || die "invalid --cpu/--memory combination"
import sys

raw_cpu, raw_memory = sys.argv[1], sys.argv[2]
if not raw_memory.endswith("Gi"):
    sys.exit("memory must be expressed in Gi, e.g. 1.0Gi")
try:
    cpu = float(raw_cpu)
    memory = float(raw_memory[:-2])
except ValueError:
    sys.exit("cpu and memory must be numeric")
if not 0.25 <= cpu <= 4.0:
    sys.exit("cpu must be between 0.25 and 4.0")
if abs(memory - cpu * 2) > 1e-9:
    sys.exit("Container Apps requires 2Gi of memory per vCPU; %s needs %.1fGi"
             % (raw_cpu, cpu * 2))
PY

require_command python3

ensure_azure_ready
load_instance "$instance_name"

app_json="$(az containerapp show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  -o json)"

container_name="$(printf '%s' "$app_json" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["properties"]["template"]["containers"][0]["name"])')"

printf 'Instance:       %s\n' "$instance_name"
printf 'Container App:  %s\n' "$APP_NAME"
printf '%s' "$app_json" | python3 -c '
import json
import sys

app = json.load(sys.stdin)["properties"]["template"]
container = app["containers"][0]
resources = container.get("resources", {})
scale = app.get("scale", {})
print("Current CPU:    %s" % resources.get("cpu"))
print("Current memory: %s" % resources.get("memory"))
print("Replicas:       min %s, max %s" % (
    scale.get("minReplicas"), scale.get("maxReplicas")))
'

storage_key="$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query '[0].value' \
  -o tsv)"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/shaarli-tune.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
config_file="$work_dir/config.json.php"

config_present="true"
az storage file download \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$storage_key" \
  --share-name "$SHAARLI_DATA_SHARE" \
  --path config.json.php \
  --dest "$config_file" \
  --output none 2>/dev/null || config_present="false"

if [[ "$config_present" == "true" ]]; then
  printf 'Thumbnails:     '
  python3 - "$config_file" <<'PY'
import json
import re
import sys

raw = open(sys.argv[1], encoding="utf-8").read().strip()
match = re.match(r"^<\?php\s*/\*(.*)\*/\s*\?>$", raw, re.DOTALL)
config = json.loads(match.group(1) if match else raw)
mode = config.get("thumbnails", {}).get("mode")
print(mode if mode else "(not set -- Shaarli's default applies)")
PY
else
  printf 'Thumbnails:     (config.json.php not found; install not yet completed)\n'
fi

if [[ "$show_only" == "true" ]]; then
  exit 0
fi

printf '\nWill apply: cpu=%s memory=%s thumbnails=%s\n' "$cpu" "$memory" "$thumbnails"
printf 'Scale-to-zero (minReplicas 0) will be left unchanged.\n'

if [[ "$assume_yes" != "true" ]]; then
  printf 'Proceed? [y/N] '
  read -r reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || die "aborted"
fi

# Patch the configuration first. It is a read-modify-write against a file the
# running app also owns, so doing it before the resource change -- while the app
# is most likely scaled to zero -- minimises the chance of clobbering a write.
if [[ "$config_present" == "true" ]]; then
  log "Setting thumbnails.mode to $thumbnails"
  python3 - "$config_file" "$thumbnails" <<'PY'
import json
import re
import sys

path, mode = sys.argv[1], sys.argv[2]

raw = open(path, encoding="utf-8").read().strip()

# The file is JSON wrapped in a PHP comment so a direct HTTP request for it
# returns nothing. The wrapper has to survive the round trip.
match = re.match(r"^<\?php\s*/\*(.*)\*/\s*\?>$", raw, re.DOTALL)
if match is None:
    sys.exit("config.json.php is not in the expected '<?php /* ... */ ?>' form")

try:
    config = json.loads(match.group(1))
except json.JSONDecodeError as exc:
    sys.exit("config.json.php does not contain valid JSON: %s" % exc)

config.setdefault("thumbnails", {})["mode"] = mode

with open(path, "w", encoding="utf-8") as handle:
    handle.write("<?php /*\n")
    handle.write(json.dumps(config, indent=4))
    handle.write("\n*/ ?>\n")
PY

  az storage file upload \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$storage_key" \
    --share-name "$SHAARLI_DATA_SHARE" \
    --source "$config_file" \
    --path config.json.php \
    --output none
else
  log "Skipping thumbnail mode; complete the Shaarli install wizard, then re-run"
fi

log "Updating container resources to cpu=$cpu memory=$memory"
az containerapp update \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --container-name "$container_name" \
  --cpu "$cpu" \
  --memory "$memory" \
  --output none

app_url="https://$(az containerapp show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn \
  -o tsv)"

# A resource change rolls out a new revision. Confirm the Easy Auth front end
# still answers before declaring success.
log "Verifying the endpoint after the new revision rolls out"
status_code=""
for _ in {1..30}; do
  status_code="$(curl --silent --show-error --output /dev/null \
    --write-out '%{http_code}' \
    --max-time 15 \
    "$app_url" || true)"
  if [[ "$status_code" == "302" || "$status_code" == "401" ]]; then
    break
  fi
  sleep 5
done
[[ "$status_code" == "302" || "$status_code" == "401" ]] ||
  die "the new revision did not become healthy (last HTTP status: ${status_code:-none}); check 'az containerapp revision list --name $APP_NAME --resource-group $RESOURCE_GROUP -o table'"

printf '\nDone. %s responded with HTTP %s.\n' "$app_url" "$status_code"
printf 'The first page load after an idle period still pays a cold start;\n'
printf 'load it twice to see the warm figure.\n'
