#!/bin/bash
echo "Waiting for shards to be ready..."
sleep 30

# Přidání shardů do clusteru
mongosh --host mongos1 --port 27017 <<EOF
sh.addShard("shard1ReplSet/shard1svr1:27017,shard1svr2:27017,shard1svr3:27017")
sh.addShard("shard2ReplSet/shard2svr1:27017,shard2svr2:27017,shard2svr3:27017")
sh.addShard("shard3ReplSet/shard3svr1:27017,shard3svr2:27017,shard3svr3:27017")

// Zapnutí shardingu pro databázi
sh.enableSharding("filmdb")

// Sharding pro kolekce
sh.shardCollection("filmdb.movies", { "id": "hashed" })
sh.shardCollection("filmdb.credits", { "movie_id": "hashed" })
sh.shardCollection("filmdb.ratings", { "userId": "hashed" })

print("Sharding setup complete!")
EOF