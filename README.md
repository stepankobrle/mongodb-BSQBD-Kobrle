# MongoDB Semestrální projekt – BSQBD

**Student:** Kobrle | **Škola:** FEI | **Předmět:** BSQBD (Big Data)
**Téma:** NoSQL dokumentová databáze – MongoDB 8.0 Sharded Cluster
**Databáze:** `filmdb` (filmy, herci, hodnocení)

## Dokumentace

- [dokumentace/dokumentace.md](dokumentace/dokumentace.md) – kompletní dokumentace projektu (7 kapitol)
- [dokumentace/obrazky/schema_architektury.svg](dokumentace/obrazky/schema_architektury.svg) – schéma architektury
- [dotazy/dotazy.md](dotazy/dotazy.md) – 30 dotazů v 5 kategoriích s komentáři
- [CLAUDE.md](CLAUDE.md) – interní checklist splnění zadání

---

## Spuštění projektu

### Požadavky

- Docker Desktop (Windows) nebo Docker Engine (Linux/Mac)
- Bash / Git Bash (pro Windows)
- Volný port: 27117, 27118, 3000

### Volitelná konfigurace (.env)

Projekt funguje bez úprav. Pro změnu hesel/portů zkopírujte [.env.example](.env.example) jako `.env` a upravte hodnoty:

```bash
cp .env.example .env
```

### Spuštění clusteru

```bash
docker compose up -d
```

Tento příkaz automaticky:
1. Vygeneruje keyfile pro interní autentizaci (`openssl rand -base64 756`)
2. Spustí 3 config servery, 3 shardy (každý 3 nody) a 2 mongos routery
3. Inicializuje replica sety a přidá shardy do clusteru
4. Vytvoří uživatele, validační schémata a indexy
5. Spustí MongoDB Compass Web na `http://localhost:3000`

Inicializace trvá cca **2–3 minuty**. Průběh lze sledovat přes:

```bash
docker logs -f mongo-init
```

### Import dat

Po úspěšném spuštění clusteru spusťte import dat:

```bash
docker exec -it mongo-init python /data/import_data.py
```

Nebo lokálně (vyžaduje Python 3 + pymongo + pandas):

```bash
pip install pymongo pandas
```

### Docker obrazy

Projekt využívá **oficiální obrazy z Docker Hub** (viz [dokumentace](dokumentace/dokumentace.md)):
- `mongo:8.0` (Official MongoDB image) – zvoleno pro nativní podporu všech funkcí v8.0.
- `haohanyang/compass-web:latest` (MongoCompass Web UI) – splňuje požadavek na webové UI (Compass).
- `alpine:3.19` (Keyfile generator) – minimalistický obraz pro generování klíčů.
- `python:3.11-slim` (Data import) – runtime pro importní skript.

### Přihlašovací údaje

| Uživatel   | Heslo          | Role                      |
|------------|----------------|---------------------------|
| `admin`    | `adminpass123` | root (správa clusteru)    |
| `filmuser` | `filmpass123`  | readWrite na filmdb       |

### Připojení k clusteru

```bash
# Přes mongosh (admin)
docker exec -it mongos1 mongosh -u admin -p adminpass123 --authenticationDatabase admin

# Přes Compass Web
http://localhost:3000
# Connection string: mongodb://filmuser:filmpass123@mongos1:27117/filmdb?authSource=filmdb
```

### Zastavení clusteru

```bash
# Zastavit (zachovat data)
docker compose down

# Zastavit a smazat veškerá data
docker compose down -v
```

---

## Architektura clusteru

```
1 cluster (filmdb)
├── Config servery (configReplSet) — 3 nody
├── Shard 1 (shard1ReplSet) — 3 nody (1 PRIMARY + 2 SECONDARY)
├── Shard 2 (shard2ReplSet) — 3 nody (1 PRIMARY + 2 SECONDARY)
├── Shard 3 (shard3ReplSet) — 3 nody (1 PRIMARY + 2 SECONDARY)
├── Mongos router 1 (port 27117)
├── Mongos router 2 (port 27118)
└── MongoCompass Web    (port 3000)
```

---

## Kolekce a datasety

| Kolekce   | Dataset              | Počet záznamů | Shard key              |
|-----------|----------------------|---------------|------------------------|
| `movies`  | TMDB 5000 Movies     | ~4 800        | `{ id: "hashed" }`     |
| `credits` | TMDB Credits         | ~4 800        | `{ movie_id: "hashed" }` |
| `ratings` | MovieLens Ratings    | ~100 000+     | `{ userId: "hashed" }` |

---

## Přehled dotazů

Všechny dotazy jsou k dispozici v [dotazy/dotazy.md](dotazy/dotazy.md).

Připojení před spuštěním dotazů:

```bash
docker exec -it mongos1 mongosh -u admin -p adminpass123 --authenticationDatabase admin
# pak:
use filmdb
```

### Kategorie 1: Agregační a analytické dotazy

| # | Co dotaz dělá |
|---|---------------|
| **1** | Průměrné hodnocení filmů podle žánru – rozloží pole `genres`, spočítá průměrné `vote_average` a počet filmů na žánr (min. 10 filmů), seřazeno od nejlépe hodnoceného. |
| **2** | Top 10 nejziskovějších filmů – vypočítá absolutní zisk a ROI (%) každého filmu, filtruje filmy s reálnými finančními daty. |
| **3** | Distribuce filmů do hodnotících skupin pomocí `$bucket` – rozdělí filmy do pásem hodnocení (0–4, 4–5, 5–6, 6–7, 7–8, 8–10) a zobrazí průměrný rozpočet a tržby každé skupiny. |
| **4** | Roční analýza filmové produkce (2000–2016) – pro každý rok zobrazí počet filmů, průměrné hodnocení, celkový rozpočet a tržby v miliardách USD. |
| **5** | Top produkční společnosti – seřadí společnosti s min. 5 filmy podle průměrného hodnocení a vypočítá jejich celkové ROI. |
| **6** | Multi-dimenzionální analýza pomocí `$facet` – paralelně analyzuje databázi ze tří pohledů najednou: top žánry, hodnotící skupiny a produkce po dekádách. |

### Kategorie 2: Propojování dat a vazby mezi datasety

| # | Co dotaz dělá |
|---|---------------|
| **7** | Nejčastěji obsazovaní herci – spočítá, v kolika filmech se každý herec v kolekci `credits` objevuje, a zobrazí ukázku filmografie. |
| **8** | Nejlépe hodnocené filmy s jejich režiséry – přes `$lookup` propojí `movies` s `credits` a z pole `crew` vyfiltruje člena s `job = "Director"`. |
| **9** | Nejúspěšnější režiséři – začíná z `credits`, filtruje režiséry, joinuje `movies` a agreguje průměrné hodnocení filmografie (min. 3 filmy, min. 100 hlasů). |
| **10** | Herci s nejvíce hlavními rolemi v akčních filmech – filtruje akční filmy, joinuje `credits` a omezí na protagonisty (`cast.order ≤ 3`). |
| **11** | Vliv velikosti hereckého obsazení na hodnocení a tržby – pomocí `$size` spočítá počet herců a `$switch` roztřídí filmy do kategorií obsazení. |
| **12** | Nejhodnocenější filmy uživateli s analýzou konzistence – ze `ratings` počítá standardní odchylku (`$stdDevSamp`) a klasifikuje filmy jako konzistentní / kontroverzní. |

### Kategorie 3: Transformace a obohacení dat

| # | Co dotaz dělá |
|---|---------------|
| **13** | Klasifikace filmů podle výše rozpočtu a analýza ROI – `$switch` roztřídí filmy na blockbustery / velké produkce / středorozpočtové / nízkorozpočtové a porovná jejich výkonnost. |
| **14** | Analýza mluvených jazyků ve světové kinematografii – rozloží pole `spoken_languages` a agreguje počty filmů, hodnocení a tržby za každý jazyk. |
| **15** | Obohacení dokumentu – přehledná karta filmu – pomocí `$addFields` přidá odvozená pole (rok, normalizované hodnocení, klasifikace délky, finanční úspěch, seznam žánrů) a `$unset` odstraní přebytečná pole. |
| **16** | Trendy filmového průmyslu po pětiletích (1980–2016) – vypočítá pětiletí jako `floor(rok/5)*5` a sleduje vývoj hodnocení, délky filmů a investic. |
| **17** | Aktivita uživatelů v čase – konvertuje Unix timestamp na datum, extrahuje rok a měsíc, agreguje počty hodnocení a unikátní uživatele na měsíc. |
| **18** | Segmentace uživatelů podle hodnotícího chování – dvoustupňová agregace: první seřadí uživatele podle aktivity a stylu hodnocení, druhý spočítá segmenty (např. "Superhodnotitel-Optimista"). |

### Kategorie 4: Indexy a optimalizace

| # | Co dotaz dělá |
|---|---------------|
| **19** | Srovnání COLLSCAN vs IXSCAN – `explain("executionStats")` ukáže, jak MongoDB prohledává neindexované vs indexované pole (`vote_average`, `vote_count`). |
| **20** | Fulltextové vyhledávání s relevance score – `$text` prohledá textový index na `title` a `overview`, `$meta: "textScore"` přidá relevance skóre a seřadí výsledky. |
| **21** | Vynucení konkrétního indexu pomocí `hint()` – tři varianty stejného dotazu: automatický výběr, explicitní compound index a vynucený COLLSCAN (`$natural`) pro srovnání výkonu. |
| **22** | Statistiky využití indexů – `$indexStats` zobrazí všechny indexy kolekce `movies`, počet jejich použití a datum začátku sledování. |
| **23** | Analytická kontrola referenční integrity – tři kontroly: osiřelá hodnocení v `ratings` bez záznamu v `movies`, osiřelé `credits`, a filmy s podezřele vysokým ROI (možná chybná data). |
| **24** | Targeted query vs scatter-gather – `explain()` porovná dotaz přes shard key `userId` (jde na 1 shard) s dotazem bez shard key (prochází všechny 3 shardy). |

### Kategorie 5: Distribuce dat, cluster a replikace

| # | Co dotaz dělá |
|---|---------------|
| **25** | Kompletní stav shardovaného clusteru – `sh.status()`, stav balanceru a aggregační pipeline nad `config.mongos` pro přehled aktivních routerů s časem posledního pingu. |
| **26** | Distribuce dat na shardech – `getShardDistribution()` pro všechny tři kolekce + `$collStats` pro přesné počty dokumentů a velikosti úložiště na každém shardu. |
| **27** | Stav replica setu shard1 – `rs.status()`, `rs.conf()` a aggregační pipeline nad `local.oplog.rs` pro přehled typů replikovaných operací za posledních 24 hodin. |
| **28** | Simulace výpadku PRIMARY nodu – krok za krokem: zastavení PRIMARY kontejneru, sledování Raft election (10–30 s) a ověření, že cluster zůstane dostupný a nový PRIMARY je zvolen. |
| **29** | Metadata shardů a distribuce chunků – `listShards`, metadata shardovaných kolekcí z `config.collections` a počty chunků na každém shardu pro kolekce `filmdb`. |
| **30** | Replikační lag a zdraví replikace – `rs.printSecondaryReplicationInfo()`, `db.getReplicationInfo()` a výpočet délky oplog okna (klíčová provozní metrika pro recovery SECONDARY nodu). |

---

## Struktura projektu

```
mongodb-BSQBD-Kobrle/
├── docker-compose.yml          # Orchestrace celého clusteru
├── CLAUDE.md                   # Interní dokumentace projektu
├── .env.example                # Vzorové env proměnné
├── init-scripts/
│   ├── 00-generate-keyfile.sh  # Generuje keyfile (openssl rand -base64 756)
│   ├── 01-init-configsvr.sh    # Inicializuje config replica set
│   ├── 02-init-shards.sh       # Inicializuje shard1, shard2, shard3
│   ├── 03-init-mongos.sh       # Přidává shardy, zapíná sharding na kolekcích
│   ├── 04-init-users.sh        # Vytváří admin a aplikační uživatele
│   ├── 05-init-validation.sh   # Validační schémata ($jsonSchema)
│   └── 06-init-indexes.sh      # Sekundární indexy
├── data/
│   ├── tmdb_5000_movies.csv    # Dataset TMDB Movies (Kaggle)
│   ├── tmdb_5000_credits.csv   # Dataset TMDB Credits (Kaggle)
│   ├── ratings_small.csv       # Dataset MovieLens Ratings (Kaggle)
│   ├── import_data.py          # Import dat do MongoDB
│   └── eda_import.ipynb        # EDA analýza v JupyterLab
├── dotazy/
│   └── dotazy.md               # 30 dotazů s příkazy a komentáři
└── dokumentace/
    ├── dokumentace.md          # Kompletní dokumentace (7 kapitol)
    └── obrazky/
        └── schema_architektury.svg  # Schéma architektury clusteru
```
