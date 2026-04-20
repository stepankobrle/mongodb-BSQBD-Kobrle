#!/bin/bash
echo "=== 05: Creating validation schemas ==="

mongosh --host mongos1 --port 27017 \
  -u admin -p adminpass123 --authenticationDatabase admin <<'EOF'

use filmdb

// Kolekce uz existuji (vytvoreny shardingem), pouzijeme collMod pro aplikaci validatoru
db.runCommand({
  collMod: "movies",
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["id", "title", "release_date"],
      properties: {
        id: {
          bsonType: "int",
          description: "ID filmu - povinne"
        },
        title: {
          bsonType: "string",
          description: "Nazev filmu - povinny"
        },
        release_date: {
          bsonType: "string",
          description: "Datum vydani - povinne"
        },
        budget: {
          bsonType: ["int", "long"],
          description: "Rozpocet filmu"
        },
        revenue: {
          bsonType: ["int", "long"],
          description: "Trzby filmu"
        },
        vote_average: {
          bsonType: "double",
          minimum: 0,
          maximum: 10,
          description: "Hodnoceni musi byt 0-10"
        }
      }
    }
  },
  validationLevel: "moderate"
})

db.runCommand({
  collMod: "credits",
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["movie_id", "title"],
      properties: {
        movie_id: {
          bsonType: "int",
          description: "ID filmu - povinne"
        },
        title: {
          bsonType: "string",
          description: "Nazev filmu - povinny"
        },
        cast: {
          bsonType: "array",
          description: "Seznam hercu"
        },
        crew: {
          bsonType: "array",
          description: "Seznam stabu"
        }
      }
    }
  },
  validationLevel: "moderate"
})

db.runCommand({
  collMod: "ratings",
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["userId", "movieId", "rating"],
      properties: {
        userId: {
          bsonType: "int",
          description: "ID uzivatele - povinne"
        },
        movieId: {
          bsonType: "int",
          description: "ID filmu - povinne"
        },
        rating: {
          bsonType: "double",
          minimum: 0.5,
          maximum: 5.0,
          description: "Hodnoceni musi byt 0.5-5.0"
        }
      }
    }
  },
  validationLevel: "moderate"
})

print("Validation schemas created!")
EOF

echo "=== 05: Done - validation schemas created ==="
