#!/bin/bash
echo "Initializing shard replica sets..."
sleep 5

# Shard 1
mongosh --host shard1svr1 --port 27017 <<EOF
rs.initiate({
  _id: "shard1ReplSet",
  members: [
    { _id: 0, host: "shard1svr1:27017" },
    { _id: 1, host: "shard1svr2:27017" },
    { _id: 2, host: "shard1svr3:27017" }
  ]
})
EOF

# Shard 2
mongosh --host shard2svr1 --port 27017 <<EOF
rs.initiate({
  _id: "shard2ReplSet",
  members: [
    { _id: 0, host: "shard2svr1:27017" },
    { _id: 1, host: "shard2svr2:27017" },
    { _id: 2, host: "shard2svr3:27017" }
  ]
})
EOF

# Shard 3
mongosh --host shard3svr1 --port 27017 <<EOF
rs.initiate({
  _id: "shard3ReplSet",
  members: [
    { _id: 0, host: "shard3svr1:27017" },
    { _id: 1, host: "shard3svr2:27017" },
    { _id: 2, host: "shard3svr3:27017" }
  ]
})
EOF