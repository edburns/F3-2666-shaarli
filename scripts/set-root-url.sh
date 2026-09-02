#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-shaarli.sh"

usage() {
  cat <<'EOF'
Usage: set-root-url.sh INSTANCE [--url URL] [--show]

Repair general.root_url in an existing Shaarli instance's configuration.

Shaarli cannot reliably discover its own base URL behind the Container Apps
ingress and Easy Auth sidecar. Without an explicit root_url it generates
absolute URLs with an empty host (https:///admin/...), which breaks the
bookmarklets, the RSS/Atom feed links, permalinks, and QR codes.

The configuration lives on the Azure Files share mounted at
/var/www/shaarli/data, so this edits the share directly. No container exec is
involved and the app may be scaled to zero.

Options:
  --url    Override the URL to write (default: the app's current ingress FQDN)
  --show   Print the current root_url and exit without modifying anything
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
override_url=""
show_only="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      [[ $# -ge 2 ]] || die "--url requires a value"
      override_url="$2"
      shift 2
      ;;
    --show)
      show_only="true"
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

require_command python3

ensure_azure_ready
load_instance "$instance_name"

if [[ -n "$override_url" ]]; then
  root_url="$override_url"
else
  fqdn="$(az containerapp show \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query properties.configuration.ingress.fqdn \
    -o tsv)"
  [[ -n "$fqdn" ]] ||
    die "instance '$instance_name' has no ingress FQDN; is public ingress enabled?"
  root_url="https://$fqdn/"
fi

# Shaarli requires the trailing slash; without it, generated paths concatenate
# badly against the configured base.
[[ "$root_url" == */ ]] || root_url="$root_url/"

storage_key="$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query '[0].value' \
  -o tsv)"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/shaarli-rooturl.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
config_file="$work_dir/config.json.php"

log "Downloading config.json.php from the $SHAARLI_DATA_SHARE share"
az storage file download \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$storage_key" \
  --share-name "$SHAARLI_DATA_SHARE" \
  --path config.json.php \
  --dest "$config_file" \
  --output none 2>/dev/null ||
  die "config.json.php not found on the share; complete the Shaarli install wizard first, then re-run"

if [[ "$show_only" == "true" ]]; then
  python3 - "$config_file" <<'PY'
import json
import re
import sys

raw = open(sys.argv[1], encoding="utf-8").read().strip()
match = re.match(r"^<\?php\s*/\*(.*)\*/\s*\?>$", raw, re.DOTALL)
config = json.loads(match.group(1) if match else raw)
current = config.get("general", {}).get("root_url")
print(current if current else "(not set)")
PY
  exit 0
fi

log "Setting general.root_url to $root_url"
python3 - "$config_file" "$root_url" <<'PY'
import json
import re
import sys

path, root_url = sys.argv[1], sys.argv[2]

raw = open(path, encoding="utf-8").read().strip()

# The file is JSON wrapped in a PHP comment so that a direct HTTP request for
# it returns nothing. The wrapper must survive the round trip.
match = re.match(r"^<\?php\s*/\*(.*)\*/\s*\?>$", raw, re.DOTALL)
if match is None:
    sys.exit("config.json.php is not in the expected '<?php /* ... */ ?>' form")

try:
    config = json.loads(match.group(1))
except json.JSONDecodeError as exc:
    sys.exit("config.json.php does not contain valid JSON: %s" % exc)

previous = config.get("general", {}).get("root_url")
config.setdefault("general", {})["root_url"] = root_url

with open(path, "w", encoding="utf-8") as handle:
    handle.write("<?php /*\n")
    handle.write(json.dumps(config, indent=4))
    handle.write("\n*/ ?>\n")

print("previous: %s" % (previous if previous else "(not set)"), file=sys.stderr)
PY

log "Uploading the patched configuration"
az storage file upload \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$storage_key" \
  --share-name "$SHAARLI_DATA_SHARE" \
  --source "$config_file" \
  --path config.json.php \
  --output none

printf '\nroot_url is now %s\n' "$root_url"
printf 'Reload the Tools page, delete the old bookmarklets, and drag the new ones.\n'
