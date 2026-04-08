#!/bin/bash
echo "Creating indexes..."
sleep 45

mongosh --host mongos1 --port 27017 -u admin -p adminpass123 --authenticationDatabase admin <<EOF

use filmdb

// Indexy pro movies
db.movies.createIndex({ "title": 1 })
db.movies.createIndex({ "release_date": 1 })
db.movies.createIndex({ "vote_average": -1 })
db.movies.createIndex({ "revenue": -1 })
db.movies.createIndex({ "budget": -1 })
db.movies.createIndex({ "title": "text", "overview": "text" })

// Indexy pro credits
db.credits.createIndex({ "movie_id": 1 })
db.credits.createIndex({ "title": 1 })

// Indexy pro ratings
db.ratings.createIndex({ "movieId": 1 })
db.ratings.createIndex({ "userId": 1 })
db.ratings.createIndex({ "rating": -1 })

print("Indexes created!")
EOF