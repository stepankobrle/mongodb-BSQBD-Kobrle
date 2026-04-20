#!/bin/bash
echo "=== 04: Creating users and enabling keyfile auth ==="

# Create both users directly on configsvr1 primary (no auth needed in phase 1).
# Users are stored in configsvr's admin db and persist after phase 2 restart.
echo "Creating users on configsvr1 (direct connection, no auth)..."
mongosh --host configsvr1 --port 27017 <<'EOF'
use admin
db.createUser({
  user: "admin",
  pwd: "adminpass123",
  roles: [{ role: "root", db: "admin" }]
})
db.createUser({
  user: "filmuser",
  pwd: "filmpass123",
  roles: [{ role: "readWrite", db: "filmdb" }]
})
print("Users created!")
EOF

echo "Signaling phase 2: all nodes will now restart with keyfile auth..."
touch /init-data/phase2

echo "Waiting for cluster to restart (this takes ~20 seconds)..."
sleep 10

echo "Waiting for mongos1 to come back up with authentication..."
until mongosh --host mongos1 --port 27017 \
  -u admin -p adminpass123 --authenticationDatabase admin \
  --eval "db.adminCommand('ping')" --quiet 2>/dev/null; do
  sleep 3
done

echo "=== 04: Done - users created, keyfile auth is now active ==="
