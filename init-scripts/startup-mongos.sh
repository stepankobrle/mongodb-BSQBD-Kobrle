#!/bin/bash
set -e

CONFIGDB="configReplSet/configsvr1:27017,configsvr2:27017,configsvr3:27017"

echo "=== Mongos Startup ==="

echo "Cekam na vygenerovany keyfile (/init-data/keyfile)..."
until [ -f /init-data/keyfile ]; do
  sleep 1
done
echo "Keyfile nalezen."

mkdir -p /etc/mongo
cp /init-data/keyfile /etc/mongo/keyfile
chmod 400 /etc/mongo/keyfile
chown mongodb:mongodb /etc/mongo/keyfile

echo "Waiting for config replica set to be initialized (/init-data/configreplset-ready)..."
while [ ! -f /init-data/configreplset-ready ]; do
  sleep 2
done

echo "Phase 1: Starting mongos WITHOUT keyfile..."
mongos --configdb "$CONFIGDB" --port 27017 --bind_ip_all &
MONGOS_PID=$!

echo "Waiting for phase 2 signal (/init-data/phase2)..."
while [ ! -f /init-data/phase2 ]; do
  if ! kill -0 $MONGOS_PID 2>/dev/null; then
    echo "ERROR: mongos died unexpectedly in phase 1"
    exit 1
  fi
  sleep 2
done

echo "Phase 2 signal received. Stopping mongos..."
kill $MONGOS_PID
wait $MONGOS_PID 2>/dev/null || true
sleep 3

echo "Phase 2: Starting mongos WITH keyfile..."
exec mongos --configdb "$CONFIGDB" --port 27017 --keyFile /etc/mongo/keyfile --bind_ip_all
