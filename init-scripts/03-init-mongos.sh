#!/bin/bash
echo "=== 03: Configuring sharding via mongos (phase 1 - no auth) ==="

# Mongos started after seeing /init-data/configreplset-ready - wait for it to be up
echo "Waiting for mongos1..."
until mongosh --host mongos1 --port 27017 --eval "db.adminCommand('ping')" --quiet 2>/dev/null; do
  sleep 2
done
echo "mongos1 is ready"

echo "Adding shards and enabling sharding..."
mongosh --host mongos1 --port 27017 <<'EOF'
sh.addShard("shard1ReplSet/shard1svr1:27017,shard1svr2:27017,shard1svr3:27017")
sh.addShard("shard2ReplSet/shard2svr1:27017,shard2svr2:27017,shard2svr3:27017")
sh.addShard("shard3ReplSet/shard3svr1:27017,shard3svr2:27017,shard3svr3:27017")

sh.enableSharding("filmdb")

sh.shardCollection("filmdb.movies", { "id": "hashed" })
sh.shardCollection("filmdb.credits", { "movie_id": "hashed" })
sh.shardCollection("filmdb.ratings", { "userId": "hashed" })

print("Sharding configuration complete!")
EOF

echo "=== 03: Done - sharding configured ==="
