#!/bin/sh
# Dynamicke generovani keyfile pro MongoDB internal authentication.
# Skript se spousti v samostatnem kontejneru pred startem mongo nodu
# a ulozi vygenerovany keyfile do sdileneho volume init_data.

set -e

KEYFILE=/init-data/keyfile

if [ -f "$KEYFILE" ]; then
  echo "Keyfile jiz existuje ve sdilenem volume ($KEYFILE) - preskakuji generovani."
  exit 0
fi

echo "=== 00: Generuji novy keyfile pres openssl ==="
apk add --no-cache openssl >/dev/null 2>&1 || true

openssl rand -base64 756 > "$KEYFILE"
chmod 400 "$KEYFILE"

echo "Keyfile vygenerovan: $KEYFILE"
ls -la "$KEYFILE"
echo "=== 00: Hotovo ==="
