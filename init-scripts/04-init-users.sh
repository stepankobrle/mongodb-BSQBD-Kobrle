#!/bin/bash
echo "Creating users..."
sleep 35

mongosh --host mongos1 --port 27017 <<EOF
// Admin uživatel
use admin
db.createUser({
  user: "admin",
  pwd: "adminpass123",
  roles: [
    { role: "root", db: "admin" }
  ]
})

// Aplikační uživatel pro filmdb
use filmdb
db.createUser({
  user: "filmuser",
  pwd: "filmpass123",
  roles: [
    { role: "readWrite", db: "filmdb" }
  ]
})

print("Users created!")
EOF