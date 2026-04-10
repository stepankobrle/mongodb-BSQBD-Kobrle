#!/bin/bash
set -e

REPLSET=${MONGO_REPLSET:?MONGO_REPLSET environment variable is required}

echo "=== Shard Server Startup (replSet: $REPLSET) ==="

echo "Phase 1: Starting mongod WITHOUT keyfile..."
mongod --shardsvr --replSet "$REPLSET" --port 27017 --bind_ip_all &
MONGOD_PID=$!

echo "Waiting for phase 2 signal (/init-data/phase2)..."
while [ ! -f /init-data/phase2 ]; do
  if ! kill -0 $MONGOD_PID 2>/dev/null; then
    echo "ERROR: mongod died unexpectedly in phase 1"
    exit 1
  fi
  sleep 2
done

echo "Phase 2 signal received. Stopping mongod..."
kill $MONGOD_PID
wait $MONGOD_PID 2>/dev/null || true
sleep 3

echo "Phase 2: Starting mongod WITH keyfile..."
chmod 400 /etc/mongo/keyfile
chown mongodb:mongodb /etc/mongo/keyfile
exec mongod --shardsvr --replSet "$REPLSET" --port 27017 --keyFile /etc/mongo/keyfile --bind_ip_all
