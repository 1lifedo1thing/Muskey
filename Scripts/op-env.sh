#!/usr/bin/env bash
# Runs a command with the 1Password service account token in its environment.
#
# The token lives in the login keychain rather than in a dotfile. Put it there once:
#
#   security add-generic-password -a "$USER" -s op-service-account -w '<token>' -U
#
# Then anything that needs a secret goes through here:
#
#   Scripts/op-env.sh op read "op://<vault>/<item>/<field>"
set -uo pipefail

SERVICE=${OP_KEYCHAIN_SERVICE:-op-service-account}

if [ $# -eq 0 ]; then
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

token=$(security find-generic-password -a "${USER:-$(id -un)}" -s "$SERVICE" -w 2>/dev/null)
if [ -z "$token" ]; then
  echo "no service account token in the keychain under '$SERVICE'." >&2
  exit 1
fi

OP_SERVICE_ACCOUNT_TOKEN="$token" exec "$@"
