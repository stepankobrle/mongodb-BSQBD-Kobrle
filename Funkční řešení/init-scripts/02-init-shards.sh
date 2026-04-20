#!/bin/bash
echo "=== 02: Initializing shard replica sets ==="

wait_for_mongo() {
  local host=$1
  echo "  Waiting for MongoDB at $host..."
  until mongosh --host "$host" --port 27017 --eval "db.adminCommand('ping')" --quiet 2>/dev/null; do
    sleep 2
  done
  echo "  $host is ready"
}

wait_for_primary() {
  local host=$1
  echo "  Waiting for primary at $host..."
  until mongosh --host "$host" --port 27017 --eval "rs.status().members.some(m => m.state === 1)" --quiet 2>/dev/null | grep -q "true"; do
    sleep 2
  done
  echo "  Primary elected at $host"
}

# --- Shard 1 ---
wait_for_mongo shard1svr1
wait_for_mongo shard1svr2
wait_for_mongo shard1svr3

echo "Initiating shard1ReplSet..."
mongosh --host shard1svr1 --port 27017 <<'EOF'
rs.initiate({
  _id: "shard1ReplSet",
  members: [
    { _id: 0, host: "shard1svr1:27017" },
    { _id: 1, host: "shard1svr2:27017" },
    { _id: 2, host: "shard1svr3:27017" }
  ]
})
EOF
wait_for_primary shard1svr1

# --- Shard 2 ---
wait_for_mongo shard2svr1
wait_for_mongo shard2svr2
wait_for_mongo shard2svr3

echo "Initiating shard2ReplSet..."
mongosh --host shard2svr1 --port 27017 <<'EOF'
rs.initiate({
  _id: "shard2ReplSet",
  members: [
    { _id: 0, host: "shard2svr1:27017" },
    { _id: 1, host: "shard2svr2:27017" },
    { _id: 2, host: "shard2svr3:27017" }
  ]
})
EOF
wait_for_primary shard2svr1

# --- Shard 3 ---
wait_for_mongo shard3svr1
wait_for_mongo shard3svr2
wait_for_mongo shard3svr3

echo "Initiating shard3ReplSet..."
mongosh --host shard3svr1 --port 27017 <<'EOF'
rs.initiate({
  _id: "shard3ReplSet",
  members: [
    { _id: 0, host: "shard3svr1:27017" },
    { _id: 1, host: "shard3svr2:27017" },
    { _id: 2, host: "shard3svr3:27017" }
  ]
})
EOF
wait_for_primary shard3svr1

echo "=== 02: Done - all shard replica sets initialized ==="
