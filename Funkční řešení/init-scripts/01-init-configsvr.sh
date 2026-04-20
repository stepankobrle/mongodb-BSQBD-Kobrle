#!/bin/bash
echo "=== 01: Initializing config server replica set ==="

wait_for_mongo() {
  local host=$1
  echo "  Waiting for MongoDB at $host..."
  until mongosh --host "$host" --port 27017 --eval "db.adminCommand('ping')" --quiet 2>/dev/null; do
    sleep 2
  done
  echo "  $host is ready"
}

wait_for_mongo configsvr1
wait_for_mongo configsvr2
wait_for_mongo configsvr3

echo "Initiating configReplSet..."
mongosh --host configsvr1 --port 27017 <<'EOF'
rs.initiate({
  _id: "configReplSet",
  configsvr: true,
  members: [
    { _id: 0, host: "configsvr1:27017" },
    { _id: 1, host: "configsvr2:27017" },
    { _id: 2, host: "configsvr3:27017" }
  ]
})
EOF

echo "Waiting for configReplSet primary to be elected..."
until mongosh --host configsvr1 --port 27017 --eval "rs.status().members.some(m => m.state === 1)" --quiet 2>/dev/null | grep -q "true"; do
  sleep 2
done
echo "configReplSet primary is ready"

touch /init-data/configreplset-ready
echo "=== 01: Done - configReplSet initialized, mongos can now start ==="
