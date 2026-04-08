#!/bin/bash
echo "Initializing config server replica set..."
sleep 5

mongosh --port 27017 <<EOF
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