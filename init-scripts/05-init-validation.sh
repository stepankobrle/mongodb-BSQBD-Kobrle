#!/bin/bash
echo "Creating validation schemas..."
sleep 40

mongosh --host mongos1 --port 27017 -u admin -p adminpass123 --authenticationDatabase admin <<EOF

use filmdb

// Validační schéma pro movies
db.createCollection("movies", {
  validator: {
    \$jsonSchema: {
      bsonType: "object",
      required: ["id", "title", "release_date"],
      properties: {
        id: {
          bsonType: "int",
          description: "ID filmu - povinné"
        },
        title: {
          bsonType: "string",
          description: "Název filmu - povinný"
        },
        release_date: {
          bsonType: "string",
          description: "Datum vydání - povinné"
        },
        budget: {
          bsonType: "int",
          description: "Rozpočet filmu"
        },
        revenue: {
          bsonType: "int",
          description: "Tržby filmu"
        },
        vote_average: {
          bsonType: "double",
          minimum: 0,
          maximum: 10,
          description: "Hodnocení musí být 0-10"
        }
      }
    }
  }
})

// Validační schéma pro credits
db.createCollection("credits", {
  validator: {
    \$jsonSchema: {
      bsonType: "object",
      required: ["movie_id", "title"],
      properties: {
        movie_id: {
          bsonType: "int",
          description: "ID filmu - povinné"
        },
        title: {
          bsonType: "string",
          description: "Název filmu - povinný"
        },
        cast: {
          bsonType: "array",
          description: "Seznam herců"
        },
        crew: {
          bsonType: "array",
          description: "Seznam štábu"
        }
      }
    }
  }
})

// Validační schéma pro ratings
db.createCollection("ratings", {
  validator: {
    \$jsonSchema: {
      bsonType: "object",
      required: ["userId", "movieId", "rating"],
      properties: {
        userId: {
          bsonType: "int",
          description: "ID uživatele - povinné"
        },
        movieId: {
          bsonType: "int",
          description: "ID filmu - povinné"
        },
        rating: {
          bsonType: "double",
          minimum: 0.5,
          maximum: 5.0,
          description: "Hodnocení musí být 0.5-5.0"
        }
      }
    }
  }
})

print("Validation schemas created!")
EOF