import pandas as pd
import ast
from pymongo import MongoClient

DATA_DIR = 'data'

def parse_json_col(val):
    if pd.isna(val):
        return []
    try:
        return ast.literal_eval(val)
    except:
        return []

# --- Načtení CSV ---
print('Načítám CSV soubory...')
movies  = pd.read_csv(f'{DATA_DIR}/tmdb_5000_movies.csv')
credits = pd.read_csv(f'{DATA_DIR}/tmdb_5000_credits.csv')
ratings = pd.read_csv(f'{DATA_DIR}/ratings_small.csv')

# --- Příprava Movies ---
movies['id']                   = pd.to_numeric(movies['id'], errors='coerce').astype('Int64')
movies['budget']               = pd.to_numeric(movies['budget'], errors='coerce').fillna(0).astype(int)
movies['revenue']              = pd.to_numeric(movies['revenue'], errors='coerce').fillna(0).astype(int)
movies['vote_average']         = pd.to_numeric(movies['vote_average'], errors='coerce').fillna(0.0)
movies['vote_count']           = pd.to_numeric(movies['vote_count'], errors='coerce').fillna(0).astype(int)
movies['runtime']              = pd.to_numeric(movies['runtime'], errors='coerce').fillna(0).astype(int)
movies['genres']               = movies['genres'].apply(parse_json_col)
movies['keywords']             = movies['keywords'].apply(parse_json_col)
movies['production_companies'] = movies['production_companies'].apply(parse_json_col)
movies['production_countries'] = movies['production_countries'].apply(parse_json_col)
movies['spoken_languages']     = movies['spoken_languages'].apply(parse_json_col)
for col in ['release_date', 'title', 'overview', 'homepage', 'original_language', 'original_title', 'status', 'tagline']:
    movies[col] = movies[col].fillna('').astype(str)
movies = movies.dropna(subset=['id'])
movies['id'] = movies['id'].astype(int)

# --- Příprava Credits ---
credits['movie_id'] = pd.to_numeric(credits['movie_id'], errors='coerce').astype('Int64')
credits['cast']     = credits['cast'].apply(parse_json_col)
credits['crew']     = credits['crew'].apply(parse_json_col)
credits['title']    = credits['title'].fillna('').astype(str)
credits = credits.dropna(subset=['movie_id'])
credits['movie_id'] = credits['movie_id'].astype(int)

# --- Příprava Ratings ---
ratings['userId']    = ratings['userId'].astype(int)
ratings['movieId']   = ratings['movieId'].astype(int)
ratings['rating']    = ratings['rating'].astype(float)
ratings['timestamp'] = ratings['timestamp'].astype(int)

print(f'Movies:  {len(movies)} záznamů')
print(f'Credits: {len(credits)} záznamů')
print(f'Ratings: {len(ratings)} záznamů')

# --- Připojení k MongoDB ---
import os
MONGO_URI = os.environ.get(
    'MONGO_URI',
    'mongodb://filmuser:filmpass123@localhost:27117/filmdb?authSource=admin'
)
print('\nPřipojuji se k MongoDB...')
client = MongoClient(MONGO_URI)
db = client['filmdb']
print('Připojeno:', client.server_info()['version'])

# --- Přeskočit import pokud data už existují ---
if db['movies'].count_documents({}) > 0:
    print('Data již existují, import přeskočen.')
    client.close()
    exit(0)

# --- Import ---
def import_collection(name, dataframe, batch_size=1000):
    col = db[name]
    col.delete_many({})
    records = dataframe.to_dict('records')
    total = len(records)
    inserted = 0
    for i in range(0, total, batch_size):
        col.insert_many(records[i:i + batch_size])
        inserted += len(records[i:i + batch_size])
        print(f'  {name}: {inserted}/{total}', end='\r')
    print(f'  {name}: {inserted}/{total} – hotovo')

print('\n=== Import dat do MongoDB ===')
import_collection('movies',  movies)
import_collection('credits', credits)
import_collection('ratings', ratings)
print('=== Import dokončen ===')

# --- Ověření ---
for name in ['movies', 'credits', 'ratings']:
    print(f'{name}: {db[name].count_documents({})} dokumentů')

client.close()
