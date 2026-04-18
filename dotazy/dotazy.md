# Dotazy – MongoDB Sharded Cluster – Filmová databáze

**Projekt:** BSQBD – NoSQL dokumentová databáze
**Student:** Kobrle
**Databáze:** filmdb (MongoDB 8.0 Sharded Cluster)

## Přehled kolekcí

| Kolekce | Počet dokumentů | Shard key |
|---------|----------------|-----------|
| `movies` | ~4 800 | `{ id: "hashed" }` |
| `credits` | ~4 800 | `{ movie_id: "hashed" }` |
| `ratings` | ~100 000 | `{ userId: "hashed" }` |

## Připojení k clusteru

```bash
docker exec -it mongos1 mongosh -u admin -p adminpass123 --authenticationDatabase admin
use filmdb
```

---

## KATEGORIE 1: Agregační a analytické dotazy

### Dotaz 1: Průměrné hodnocení filmů podle žánru

**Úloha:** Zjistit průměrné hodnocení, průměrný počet hlasů a počet filmů pro každý žánr (min. 10 filmů), seřazené od nejlépe hodnoceného.

```js
db.movies.aggregate([
  { $unwind: "$genres" },
  { $group: {
    _id: "$genres.name",
    prumerne_hodnoceni: { $avg: "$vote_average" },
    prumerny_pocet_hlasu: { $avg: "$vote_count" },
    pocet_filmu: { $sum: 1 }
  }},
  { $match: { pocet_filmu: { $gte: 10 } } },
  { $sort: { prumerne_hodnoceni: -1 } },
  { $project: {
    _id: 1,
    prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
    prumerny_pocet_hlasu: { $round: ["$prumerny_pocet_hlasu", 0] },
    pocet_filmu: 1
  }}
])
```

**Komentář:** `$unwind` rozloží pole `genres` – každý film má více žánrů, takže každý žánr se stane samostatným dokumentem. `$group` agreguje filmy podle názvu žánru, `$avg` počítá průměry a `$sum: 1` počítá výskyty. `$match` po agregaci (ne před) filtruje žánry s malou vzorkem. `$project` s `$round` zaokrouhluje výsledky na 2 desetinná místa. Dotaz prochází všemi třemi shardy (scatter-gather), protože shard key `id` není součástí filtru.

---

### Dotaz 2: Top 10 nejziskovějších filmů s výpočtem ROI

**Úloha:** Najít 10 filmů s nejvyšším absolutním ziskem, vypočítat ROI (Return on Investment) a zobrazit jejich hodnocení.

```js
db.movies.aggregate([
  { $match: {
    budget: { $gt: 1000000 },
    revenue: { $gt: 0 }
  }},
  { $addFields: {
    zisk: { $subtract: ["$revenue", "$budget"] },
    roi_procent: {
      $round: [{
        $multiply: [
          { $divide: [{ $subtract: ["$revenue", "$budget"] }, "$budget"] },
          100
        ]
      }, 1]
    }
  }},
  { $sort: { zisk: -1 } },
  { $limit: 10 },
  { $project: {
    _id: 0,
    title: 1,
    budget_mil: { $round: [{ $divide: ["$budget", 1000000] }, 1] },
    revenue_mil: { $round: [{ $divide: ["$revenue", 1000000] }, 1] },
    zisk_mil: { $round: [{ $divide: ["$zisk", 1000000] }, 1] },
    roi_procent: 1,
    vote_average: 1
  }}
])
```

**Komentář:** `$match` nejprve filtruje filmy s reálnými finančními daty (budget > 1M, revenue > 0) – odstraní filmy bez finančních dat. `$addFields` přidává dvě vypočtená pole: `zisk` jako aritmetický rozdíl tržeb a rozpočtu, `roi_procent` jako procentuální návratnost investice s vnořenou operací `$divide`/`$multiply`. Obě pole vznikají v jediném průchodu dokumentem. Hodnoty jsou v `$project` transformovány na miliony USD pomocí `$divide` pro čitelnost.

---

### Dotaz 3: Distribuce filmů do hodnotících skupin pomocí $bucket

**Úloha:** Rozdělit filmy do skupin podle hodnocení a pro každou skupinu zjistit počet filmů, průměrný rozpočet a průměrné tržby.

```js
db.movies.aggregate([
  { $match: { vote_count: { $gte: 50 } } },
  { $bucket: {
    groupBy: "$vote_average",
    boundaries: [0, 4, 5, 6, 7, 8, 10.1],
    default: "Nehodnoceno",
    output: {
      pocet_filmu: { $sum: 1 },
      prumerny_budget_mil: { $avg: { $divide: ["$budget", 1000000] } },
      prumerne_trzby_mil: { $avg: { $divide: ["$revenue", 1000000] } },
      prumerne_hodnoceni: { $avg: "$vote_average" }
    }
  }},
  { $project: {
    _id: 1,
    pocet_filmu: 1,
    prumerny_budget_mil: { $round: ["$prumerny_budget_mil", 1] },
    prumerne_trzby_mil: { $round: ["$prumerne_trzby_mil", 1] },
    prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] }
  }}
])
```

**Komentář:** `$bucket` je specializovaná agregační fáze, která rozděluje dokumenty do předdefinovaných intervalů (buckets) podle hodnoty pole `vote_average`. Hranice `[0, 4, 5, 6, 7, 8, 10.1]` vytváří skupiny: méně než 4 (propadáky), 4–5, 5–6, 6–7, 7–8 a 8–10 (výborné). Klausule `default` zachytí dokumenty mimo rozsah (hodnocení přesně 0 nebo > 10). Výpočet finančních průměrů přímo v `output` eliminuje potřebu následného `$addFields`. Výsledek odhaluje, zda lépe hodnocené filmy mají i vyšší rozpočty a tržby.

---

### Dotaz 4: Roční analýza filmové produkce (2000–2016)

**Úloha:** Analyzovat trend počtu filmů, průměrného hodnocení, celkového rozpočtu a tržeb pro každý rok v období 2000–2016.

```js
db.movies.aggregate([
  { $addFields: {
    rok: { $toInt: { $substr: ["$release_date", 0, 4] } }
  }},
  { $match: {
    rok: { $gte: 2000, $lte: 2016 },
    vote_count: { $gte: 20 }
  }},
  { $group: {
    _id: "$rok",
    pocet_filmu: { $sum: 1 },
    prumerne_hodnoceni: { $avg: "$vote_average" },
    celkovy_budget_mld: { $sum: "$budget" },
    celkove_trzby_mld: { $sum: "$revenue" },
    nejvyssi_hodnoceni: { $max: "$vote_average" }
  }},
  { $sort: { _id: 1 } },
  { $project: {
    rok: "$_id",
    pocet_filmu: 1,
    prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
    celkovy_budget_mld: { $round: [{ $divide: ["$celkovy_budget_mld", 1000000000] }, 2] },
    celkove_trzby_mld: { $round: [{ $divide: ["$celkove_trzby_mld", 1000000000] }, 2] },
    nejvyssi_hodnoceni: 1
  }}
])
```

**Komentář:** `$addFields` extrahuje rok z řetězce `release_date` pomocí `$substr` (první 4 znaky) a `$toInt` pro převod na číslo – nutné pro porovnávání v `$match`. `$match` filtruje rozsah let i minimální počet hodnocení (eliminuje filmy s jedním anonymním hodnocením). `$group` agreguje data po rocích s více akumulátory najednou: `$avg`, `$sum`, `$max`. `$project` přejmenuje `_id` na `rok` a transformuje absolutní hodnoty rozpočtů na miliardy USD pro lepší čitelnost trendů.

---

### Dotaz 5: Filmové produkční společnosti s nejlepším výkonem

**Úloha:** Zjistit, které produkční společnosti (s min. 5 filmy) dosahují nejvyššího průměrného hodnocení, a vypočítat jejich celkovou efektivitu investic.

```js
db.movies.aggregate([
  { $unwind: "$production_companies" },
  { $group: {
    _id: "$production_companies.name",
    pocet_filmu: { $sum: 1 },
    prumerne_hodnoceni: { $avg: "$vote_average" },
    celkove_trzby: { $sum: "$revenue" },
    celkovy_budget: { $sum: "$budget" }
  }},
  { $match: {
    pocet_filmu: { $gte: 5 },
    celkovy_budget: { $gt: 0 }
  }},
  { $addFields: {
    efektivita_roi: {
      $round: [{
        $multiply: [
          { $divide: [{ $subtract: ["$celkove_trzby", "$celkovy_budget"] }, "$celkovy_budget"] },
          100
        ]
      }, 1]
    }
  }},
  { $sort: { prumerne_hodnoceni: -1 } },
  { $limit: 10 },
  { $project: {
    _id: 1, pocet_filmu: 1,
    prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
    celkove_trzby_mld: { $round: [{ $divide: ["$celkove_trzby", 1000000000] }, 2] },
    efektivita_roi: 1
  }}
])
```

**Komentář:** `$unwind` rozloží pole `production_companies` – film může mít více producentů, každý se stane samostatným dokumentem (jeden film se pak počítá vícekrát). `$group` agreguje per-společnost statistiky. `$match` po agregaci (nikoli před) filtruje společnosti s malou filmografií a nulový budget (dělení nulou). `$addFields` přidá vlastní metriku ROI společnosti jako poměr celkových tržeb k celkovým investicím v procentech. Výsledek kombinuje kritickou i komerční úspěšnost.

---

### Dotaz 6: Multi-dimenzionální analýza pomocí $facet

**Úloha:** Paralelně analyzovat filmovou databázi ze tří pohledů najednou: rozložení podle žánrů, hodnotících skupin a dekád.

```js
db.movies.aggregate([
  { $match: { vote_count: { $gte: 100 }, release_date: { $gt: "" } } },
  { $facet: {
    "top_zanry": [
      { $unwind: "$genres" },
      { $group: {
        _id: "$genres.name",
        pocet: { $sum: 1 },
        avg_hodnoceni: { $avg: "$vote_average" }
      }},
      { $sort: { pocet: -1 } },
      { $limit: 5 }
    ],
    "hodnotici_skupiny": [
      { $bucket: {
        groupBy: "$vote_average",
        boundaries: [0, 5, 6, 7, 8, 10.1],
        default: "N/A",
        output: {
          pocet: { $sum: 1 },
          prumerny_budget_mil: { $avg: { $divide: ["$budget", 1000000] } }
        }
      }}
    ],
    "po_dekadach": [
      { $addFields: {
        dekada: {
          $multiply: [
            { $floor: { $divide: [{ $toInt: { $substr: ["$release_date", 0, 4] } }, 10] } },
            10
          ]
        }
      }},
      { $group: {
        _id: "$dekada",
        pocet: { $sum: 1 },
        avg_hodnoceni: { $avg: "$vote_average" }
      }},
      { $sort: { _id: 1 } }
    ]
  }}
])
```

**Komentář:** `$facet` je výjimečná fáze, která spustí více nezávislých agregačních pipeline nad identickou vstupní sadou dat v jediném průchodu kolekcí – výrazně efektivnější než tři separátní dotazy. Větev `top_zanry` kombinuje `$unwind` + `$group` + `$sort` + `$limit`. Větev `hodnotici_skupiny` používá `$bucket`. Větev `po_dekadach` vypočítá dekádu jako `floor(rok/10)*10` pomocí `$toInt`, `$substr`, `$floor`, `$divide` a `$multiply`. Celý dotaz vrátí jeden dokument s třemi vnořenými výsledky.

---

## KATEGORIE 2: Propojování dat a vazby mezi datasety

### Dotaz 7: Nejčastěji obsazovaní herci napříč celou databází

**Úloha:** Zjistit, kteří herci se v databázi TMDB Credits objevují v nejvíce filmech, a zobrazit ukázku jejich filmografie.

```js
db.credits.aggregate([
  { $unwind: "$cast" },
  { $group: {
    _id: "$cast.name",
    pocet_filmu: { $sum: 1 },
    filmy: { $push: "$title" }
  }},
  { $sort: { pocet_filmu: -1 } },
  { $limit: 10 },
  { $project: {
    _id: 1,
    pocet_filmu: 1,
    ukazka_filmu: { $slice: ["$filmy", 3] }
  }}
])
```

**Komentář:** `$unwind` rozloží pole `cast` v kolekci `credits` – každý herec z každého filmu se stane samostatným dokumentem (z 4 800 záznamů vznikne řádově stovky tisíc dokumentů). `$group` seskupuje podle jména herce, `$sum: 1` počítá výskyty a `$push` shromažďuje názvy filmů do pole. `$project` s `$slice` zobrazí pouze prvních 3 filmy jako ukázku, aby byl výstup přehledný a pole `filmy` nepřetěžovalo výstup. Dotaz funguje pouze na kolekci `credits` (není potřeba `$lookup`).

---

### Dotaz 8: Nejlépe hodnocené filmy s jejich režiséry

**Úloha:** Ke každému vysoce hodnocenému filmu (≥ 7.5, min. 500 hlasů) dohledat jméno režiséra z kolekce credits přes vazbu `movies.id → credits.movie_id`.

```js
db.movies.aggregate([
  { $match: { vote_average: { $gte: 7.5 }, vote_count: { $gte: 500 } } },
  { $lookup: {
    from: "credits",
    localField: "id",
    foreignField: "movie_id",
    as: "info_o_hercich"
  }},
  { $unwind: { path: "$info_o_hercich", preserveNullAndEmptyArrays: false } },
  { $addFields: {
    reziser: {
      $arrayElemAt: [
        { $filter: {
          input: "$info_o_hercich.crew",
          as: "clen",
          cond: { $eq: ["$$clen.job", "Director"] }
        }},
        0
      ]
    }
  }},
  { $project: {
    _id: 0,
    title: 1,
    vote_average: 1,
    vote_count: 1,
    release_date: 1,
    reziser_jmeno: "$reziser.name"
  }},
  { $sort: { vote_average: -1 } },
  { $limit: 15 }
])
```

**Komentář:** `$lookup` realizuje JOIN mezi `movies` (`localField: id`) a `credits` (`foreignField: movie_id`) – tato vazba odpovídá datovému modelu obou TMDB kolekcí. V shardovaném clusteru mongos koordinuje `$lookup` přes všechny shardy obou kolekcí. `$filter` prochází pole `crew` a vrátí pouze členy s `job = "Director"`. `$arrayElemAt` s indexem 0 vezme prvního nalezeného režiséra (někteří filmy mají více spoluregistrovaných). Výsledkem je JOIN přes dvě shardované kolekce s filtrací vnořeného pole.

---

### Dotaz 9: Režiséři s nejvyšším průměrným hodnocením jejich filmů

**Úloha:** Identifikovat nejúspěšnější režiséry (min. 3 filmy, min. 100 hlasů na film) podle průměrného hodnocení TMDB.

```js
db.credits.aggregate([
  { $unwind: "$crew" },
  { $match: { "crew.job": "Director" } },
  { $lookup: {
    from: "movies",
    localField: "movie_id",
    foreignField: "id",
    as: "film_info"
  }},
  { $unwind: "$film_info" },
  { $match: { "film_info.vote_count": { $gte: 100 } } },
  { $group: {
    _id: "$crew.name",
    pocet_filmu: { $sum: 1 },
    prumerne_hodnoceni: { $avg: "$film_info.vote_average" },
    celkove_trzby_mld: { $sum: "$film_info.revenue" },
    filmy: { $push: "$film_info.title" }
  }},
  { $match: { pocet_filmu: { $gte: 3 } } },
  { $sort: { prumerne_hodnoceni: -1 } },
  { $limit: 10 },
  { $project: {
    _id: 1, pocet_filmu: 1,
    prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
    celkove_trzby_mld: { $round: [{ $divide: ["$celkove_trzby_mld", 1000000000] }, 2] },
    ukazka_filmu: { $slice: ["$filmy", 3] }
  }}
])
```

**Komentář:** Pipeline začíná v `credits`, rozloží `crew` a okamžitě filtruje `Directors` – tím sníží objem dat před `$lookup`. `$lookup` přidá data z `movies`. Druhý `$match` po `$lookup` odfiltruje filmy s nedostatečným počtem hodnocení (eliminuje zkreslení průměru). `$group` agreguje celou kariéru každého režiséra. Dva `$match` příkazy v různých fázích pipeline ukazují, jak lze filtrovat vstup i výstup `$lookup`.

---

### Dotaz 10: Herci s nejvíce hlavními rolemi v akčních filmech

**Úloha:** Zjistit, kteří herci (v rolích order ≤ 3, tedy protagonisté) se nejčastěji objevují v akčních filmech, a jaké bylo průměrné hodnocení těchto filmů.

```js
db.movies.aggregate([
  { $unwind: "$genres" },
  { $match: { "genres.name": "Action" } },
  { $group: { _id: "$id", title: { $first: "$title" }, vote_average: { $first: "$vote_average" } } },
  { $lookup: {
    from: "credits",
    localField: "_id",
    foreignField: "movie_id",
    as: "cast_info"
  }},
  { $unwind: "$cast_info" },
  { $unwind: "$cast_info.cast" },
  { $match: { "cast_info.cast.order": { $lte: 3 } } },
  { $group: {
    _id: "$cast_info.cast.name",
    pocet_action_filmu: { $sum: 1 },
    prumerne_hodnoceni_akce: { $avg: "$vote_average" },
    filmy: { $push: "$title" }
  }},
  { $sort: { pocet_action_filmu: -1 } },
  { $limit: 10 },
  { $project: {
    _id: 1, pocet_action_filmu: 1,
    prumerne_hodnoceni_akce: { $round: ["$prumerne_hodnoceni_akce", 2] },
    ukazka_filmu: { $slice: ["$filmy", 3] }
  }}
])
```

**Komentář:** Komplexní pipeline se 7 fázemi: `$unwind` + `$match` filtruje akční filmy, `$group` odstraní duplicity vznikající po `$unwind` žánrů, `$lookup` přidá herce, dva `$unwind` rozloží vnořená data, druhý `$match` omezí na protagonisty (order ≤ 3). Výsledek ukazuje specializaci herců na akční žánr a korelaci s kvalitou filmů. `$lookup` zde jde opačným směrem než v dotazu 8 – od movie k cast.

---

### Dotaz 11: Vliv velikosti hereckého obsazení na hodnocení a tržby

**Úloha:** Analyzovat korelaci mezi počtem herců v obsazení a průměrným hodnocením a tržbami filmů.

```js
db.movies.aggregate([
  { $match: { vote_count: { $gte: 100 } } },
  { $lookup: {
    from: "credits",
    localField: "id",
    foreignField: "movie_id",
    as: "credits_data"
  }},
  { $unwind: { path: "$credits_data", preserveNullAndEmptyArrays: false } },
  { $addFields: { pocet_hercu: { $size: "$credits_data.cast" } } },
  { $group: {
    _id: {
      $switch: {
        branches: [
          { case: { $lte: ["$pocet_hercu", 10] }, then: "01–10 herců" },
          { case: { $lte: ["$pocet_hercu", 20] }, then: "11–20 herců" },
          { case: { $lte: ["$pocet_hercu", 30] }, then: "21–30 herců" },
          { case: { $lte: ["$pocet_hercu", 50] }, then: "31–50 herců" }
        ],
        default: "50+ herců"
      }
    },
    pocet_filmu: { $sum: 1 },
    prumerne_hodnoceni: { $avg: "$vote_average" },
    prumerne_trzby_mil: { $avg: { $divide: ["$revenue", 1000000] } }
  }},
  { $sort: { _id: 1 } },
  { $project: {
    _id: 1, pocet_filmu: 1,
    prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
    prumerne_trzby_mil: { $round: ["$prumerne_trzby_mil", 1] }
  }}
])
```

**Komentář:** Po `$lookup` a `$unwind` přidá `$addFields` počet herců jako `$size` pole `cast` – jde o výpočet z vnořeného pole přineseného `$lookup`. Výsledek se seskupí do kategorií pomocí `$switch` přímo v `$group._id` – netriviální použití výrazu jako skupinového klíče. Výsledek odhaluje korelaci mezi rozsahem obsazení a komerčním úspěchem (větší produkce typicky investují do širšího obsazení a dosahují vyšších tržeb).

---

### Dotaz 12: Nejhodnocenější filmy uživateli s analýzou konzistence hodnocení

**Úloha:** Najít filmy s největším počtem uživatelských hodnocení a zjistit konzistenci hodnocení pomocí standardní odchylky.

```js
db.ratings.aggregate([
  { $group: {
    _id: "$movieId",
    pocet_hodnoceni: { $sum: 1 },
    prumerne_hodnoceni: { $avg: "$rating" },
    nejmensi: { $min: "$rating" },
    nejvetsi: { $max: "$rating" },
    smerodatna_odchylka: { $stdDevSamp: "$rating" },
    unikatni_hodnotitele: { $addToSet: "$userId" }
  }},
  { $addFields: {
    pocet_unikatnich: { $size: "$unikatni_hodnotitele" },
    konzistence: {
      $switch: {
        branches: [
          { case: { $lt: ["$smerodatna_odchylka", 0.8] }, then: "Konzistentní" },
          { case: { $lt: ["$smerodatna_odchylka", 1.2] }, then: "Středně variabilní" }
        ],
        default: "Kontroverzní"
      }
    }
  }},
  { $match: { pocet_hodnoceni: { $gte: 50 } } },
  { $sort: { pocet_hodnoceni: -1 } },
  { $limit: 10 },
  { $project: {
    _id: 1, pocet_hodnoceni: 1,
    prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
    smerodatna_odchylka: { $round: ["$smerodatna_odchylka", 2] },
    konzistence: 1,
    pocet_unikatnich: 1
  }}
])
```

**Komentář:** `$stdDevSamp` je statistický akumulátor, který vypočítá výběrovou standardní odchylku hodnocení pro každý film – nízká hodnota znamená shodu uživatelů, vysoká indikuje kontroverzní film. `$addToSet` shromáždí unikátní `userId` (bez duplicit), `$size` pak spočítá počet skutečných hodnotitelů. `$addFields` po `$group` klasifikuje filmy přes `$switch`. Dotaz kombinuje 5 různých akumulátorů v jednom `$group`.

---

## KATEGORIE 3: Transformace a obohacení dat

### Dotaz 13: Klasifikace filmů podle kategorie rozpočtu a analýza ROI

**Úloha:** Klasifikovat filmy do kategorií podle výše rozpočtu a analyzovat průměrnou ROI, hodnocení a procento ziskových filmů v každé kategorii.

```js
db.movies.aggregate([
  { $match: { budget: { $gt: 0 }, revenue: { $gt: 0 } } },
  { $addFields: {
    kategorie_rozpoctu: {
      $switch: {
        branches: [
          { case: { $gte: ["$budget", 100000000] }, then: "Blockbuster (100M+ USD)" },
          { case: { $gte: ["$budget", 20000000] }, then: "Velká produkce (20–100M USD)" },
          { case: { $gte: ["$budget", 5000000] }, then: "Středorozpočtový (5–20M USD)" }
        ],
        default: "Nízkorozpočtový (<5M USD)"
      }
    },
    roi: {
      $round: [{
        $multiply: [
          { $divide: [{ $subtract: ["$revenue", "$budget"] }, "$budget"] },
          100
        ]
      }, 1]
    }
  }},
  { $group: {
    _id: "$kategorie_rozpoctu",
    pocet_filmu: { $sum: 1 },
    prumerne_roi: { $avg: "$roi" },
    prumerne_hodnoceni: { $avg: "$vote_average" },
    prumerne_trzby_mil: { $avg: { $divide: ["$revenue", 1000000] } },
    uspesnych_podil: { $avg: { $cond: [{ $gt: ["$revenue", "$budget"] }, 1, 0] } }
  }},
  { $sort: { prumerne_roi: -1 } },
  { $project: {
    _id: 1, pocet_filmu: 1,
    prumerne_roi: { $round: ["$prumerne_roi", 1] },
    prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
    prumerne_trzby_mil: { $round: ["$prumerne_trzby_mil", 1] },
    uspesnost_procent: { $round: [{ $multiply: ["$uspesnych_podil", 100] }, 1] }
  }}
])
```

**Komentář:** `$addFields` přidává dvě vypočtená pole: `kategorie_rozpoctu` klasifikuje filmy pomocí `$switch` a `roi` vypočítá ROI v procentech se zanořenými operátory. `$group` agreguje kategorie a v poli `uspesnych_podil` používá `$avg` na podmíněném výrazu `$cond` – elegantní způsob výpočtu procenta ziskových filmů bez separátního `$match`. Výsledek ukazuje, že nízkorozpočtové filmy mohou mít vyšší ROI než blockbustery.

---

### Dotaz 14: Analýza mluvených jazyků ve světové kinematografii

**Úloha:** Zjistit rozložení mluvených jazyků ve filmech a jejich vliv na průměrné hodnocení, tržby a celkový podíl na trhu.

```js
db.movies.aggregate([
  { $unwind: "$spoken_languages" },
  { $group: {
    _id: "$spoken_languages.name",
    pocet_filmu: { $sum: 1 },
    prumerne_hodnoceni: { $avg: "$vote_average" },
    prumerne_trzby: { $avg: "$revenue" },
    celkove_trzby: { $sum: "$revenue" }
  }},
  { $match: { pocet_filmu: { $gte: 15 } } },
  { $addFields: {
    podil_trzby_mld: { $round: [{ $divide: ["$celkove_trzby", 1000000000] }, 2] }
  }},
  { $sort: { pocet_filmu: -1 } },
  { $limit: 12 },
  { $project: {
    _id: 1, pocet_filmu: 1,
    prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
    prumerne_trzby_mil: { $round: [{ $divide: ["$prumerne_trzby", 1000000] }, 1] },
    podil_trzby_mld: 1
  }}
])
```

**Komentář:** `$unwind` rozloží pole `spoken_languages` – film může být ve více jazycích. `$group` agreguje per-jazyk statistiky s více akumulátory. `$addFields` po agregaci přidává celkový tržní podíl v miliardách. Výsledek odhaluje dominanci anglofonní kinematografie (English se očekávaně umístí první), ale také komerční výkon ostatních jazykových kinematografií. Srovnání `prumerne_hodnoceni` mezi jazyky ukazuje, zda existuje korelace mezi jazykem produkce a kritikou přijatým výsledkem.

---

### Dotaz 15: Obohacení dokumentu – přehledná karta filmu s odvozenými poli

**Úloha:** Transformovat dokument o filmu do přehledné karty přidáním normalizovaných hodnot, klasifikací a odstraněním nepotřebných polí.

```js
db.movies.aggregate([
  { $match: { vote_count: { $gte: 200 }, release_date: { $gt: "" } } },
  { $addFields: {
    rok_vydani: { $toInt: { $substr: ["$release_date", 0, 4] } },
    hodnoceni_normalizovane: { $round: [{ $multiply: ["$vote_average", 10] }, 0] },
    klasifikace_delky: {
      $switch: {
        branches: [
          { case: { $lt: ["$runtime", 90] }, then: "Krátký (<90 min)" },
          { case: { $lte: ["$runtime", 120] }, then: "Standardní (90–120 min)" },
          { case: { $lte: ["$runtime", 150] }, then: "Dlouhý (120–150 min)" }
        ],
        default: "Epický (>150 min)"
      }
    },
    financni_uspech: {
      $cond: {
        if: { $and: [{ $gt: ["$budget", 0] }, { $gt: ["$revenue", 0] }] },
        then: {
          $cond: [
            { $gt: ["$revenue", { $multiply: ["$budget", 2] }] }, "Velký úspěch",
            { $cond: [{ $gt: ["$revenue", "$budget"] }, "Ziskový", "Ztrátový"] }
          ]
        },
        else: "Data nedostupná"
      }
    },
    zanry_seznam: { $map: { input: "$genres", as: "g", in: "$$g.name" } }
  }},
  { $unset: ["genres", "keywords", "production_companies", "production_countries",
             "spoken_languages", "homepage", "tagline", "popularity", "_id"] },
  { $sort: { vote_average: -1 } },
  { $limit: 10 }
])
```

**Komentář:** `$addFields` přidává 5 odvozených polí najednou: `rok_vydani` extrakcí z řetězce, `hodnoceni_normalizovane` na škálu 0–100, `klasifikace_delky` přes `$switch`, `financni_uspech` přes vnořené `$cond` (trojstavová logika) a `zanry_seznam` přes `$map` pro transformaci pole objektů na pole řetězců. `$unset` odstraní přebytečná pole a zkrátí dokument. Kombinace `$addFields` + `$unset` je standardní vzor pro transformaci dokumentů před výstupem.

---

### Dotaz 16: Trendy filmového průmyslu po pětiletích (1980–2016)

**Úloha:** Zjistit, jak se vyvíjelo průměrné hodnocení, délka filmů, objem produkce a investice v pětiletých intervalech.

```js
db.movies.aggregate([
  { $addFields: {
    rok: { $toInt: { $substr: ["$release_date", 0, 4] } }
  }},
  { $match: { rok: { $gte: 1980, $lte: 2016 }, vote_count: { $gte: 30 } } },
  { $addFields: {
    petileti: { $multiply: [{ $floor: { $divide: ["$rok", 5] } }, 5] }
  }},
  { $group: {
    _id: "$petileti",
    pocet_filmu: { $sum: 1 },
    prumerne_hodnoceni: { $avg: "$vote_average" },
    prumerny_runtime_min: { $avg: "$runtime" },
    prumerny_budget_mil: { $avg: { $divide: ["$budget", 1000000] } },
    filmy_s_financnimi_daty: { $sum: { $cond: [{ $gt: ["$budget", 0] }, 1, 0] } }
  }},
  { $sort: { _id: 1 } },
  { $project: {
    obdobi: { $concat: [{ $toString: "$_id" }, "–", { $toString: { $add: ["$_id", 4] } }] },
    pocet_filmu: 1,
    prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
    prumerny_runtime_min: { $round: ["$prumerny_runtime_min", 0] },
    prumerny_budget_mil: { $round: ["$prumerny_budget_mil", 1] },
    filmy_s_financnimi_daty: 1
  }}
])
```

**Komentář:** Dvoustupňové `$addFields`: nejprve extrakce roku, pak výpočet pětiletí jako `floor(rok/5)*5`. `$group` s `$sum` na podmíněném výrazu `$cond` počítá filmy s dostupnými finančními daty. `$project` transformuje `_id` na čitelný řetězec "1980–1984" pomocí `$concat` + `$toString` + `$add`. Výsledek zachycuje trendy: nárůst průměrné délky filmů, evoluci produkčních nákladů a změny v hodnocení mezi dekádami.

---

### Dotaz 17: Analýza aktivity uživatelů v čase podle roku a měsíce

**Úloha:** Zjistit, jak se vyvíjela aktivita hodnotitelů a průměrná hodnocení v jednotlivých měsících, přičemž timestamp je konvertován z Unix formátu.

```js
db.ratings.aggregate([
  { $addFields: {
    datum: { $toDate: { $multiply: ["$timestamp", 1000] } }
  }},
  { $addFields: {
    rok: { $year: "$datum" },
    mesic: { $month: "$datum" }
  }},
  { $group: {
    _id: { rok: "$rok", mesic: "$mesic" },
    pocet_hodnoceni: { $sum: 1 },
    prumerne_hodnoceni: { $avg: "$rating" },
    unikatni_uzivatele: { $addToSet: "$userId" }
  }},
  { $addFields: {
    pocet_uzivatelu: { $size: "$unikatni_uzivatele" }
  }},
  { $sort: { "_id.rok": 1, "_id.mesic": 1 } },
  { $project: {
    _id: 0,
    rok: "$_id.rok",
    mesic: "$_id.mesic",
    pocet_hodnoceni: 1,
    prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
    pocet_uzivatelu: 1
  }},
  { $limit: 24 }
])
```

**Komentář:** `$multiply` převede Unix timestamp (sekundy) na milisekundy, `$toDate` jej konvertuje na MongoDB Date objekt. Druhý `$addFields` extrahuje `$year` a `$month` z Date objektu – operace dostupné pouze na Date typech. `$addToSet` shromáždí unikátní `userId` (bez duplicit) a `$size` spočítá jejich počet až po `$group` v separátním `$addFields`. Složený klíč `{ rok, mesic }` v `$group._id` umožňuje granulární analýzu sezónnosti hodnocení.

---

### Dotaz 18: Segmentace uživatelů podle hodnotícího chování

**Úloha:** Segmentovat uživatele do skupin podle jejich aktivity a průměrného hodnocení, a zjistit složení komunity hodnotitelů.

```js
db.ratings.aggregate([
  { $group: {
    _id: "$userId",
    pocet_hodnoceni: { $sum: 1 },
    prumerne_hodnoceni: { $avg: "$rating" },
    hodnoceni_5hvezd: { $sum: { $cond: [{ $eq: ["$rating", 5.0] }, 1, 0] } },
    hodnoceni_1hvezda: { $sum: { $cond: [{ $lte: ["$rating", 1.0] }, 1, 0] } }
  }},
  { $addFields: {
    typ_uzivatele: {
      $switch: {
        branches: [
          { case: { $gte: ["$pocet_hodnoceni", 200] }, then: "Superhodnotitel (200+)" },
          { case: { $gte: ["$pocet_hodnoceni", 50] }, then: "Aktivní (50–199)" },
          { case: { $gte: ["$pocet_hodnoceni", 20] }, then: "Příležitostný (20–49)" }
        ],
        default: "Nový (<20)"
      }
    },
    styl_hodnoceni: {
      $switch: {
        branches: [
          { case: { $gt: ["$prumerne_hodnoceni", 4.0] }, then: "Optimista (>4.0)" },
          { case: { $lt: ["$prumerne_hodnoceni", 2.5] }, then: "Kritik (<2.5)" }
        ],
        default: "Vyrovnaný (2.5–4.0)"
      }
    }
  }},
  { $group: {
    _id: { typ: "$typ_uzivatele", styl: "$styl_hodnoceni" },
    pocet_uzivatelu: { $sum: 1 },
    prumerny_pocet_hodnoceni: { $avg: "$pocet_hodnoceni" }
  }},
  { $sort: { pocet_uzivatelu: -1 } }
])
```

**Komentář:** Dvoustupňová agregace: první `$group` agreguje hodnocení za každého uživatele a `$sum` s `$cond` počítá podmíněné součty (5hvězdičková a 1hvězdičková hodnocení bez `$filter`). `$addFields` klasifikuje uživatele dvěma `$switch` výrazy. Druhý `$group` seskupuje uživatele do segmentů podle kombinace (typ × styl). Výsledek ukazuje, kolik uživatelů je "optimistů-superhodnotitelů" vs "kritiků-nových hodnotitelů" apod.

---

## KATEGORIE 4: Indexy a optimalizace

### Dotaz 19: Srovnání výkonu dotazu s indexem a bez indexu

**Úloha:** Demonstrovat rozdíl v query plánu aggregační pipeline na neindexovaném vs indexovaném poli pomocí `explain("executionStats")`.

```js
// Pipeline na neindexované pole original_language → COLLSCAN v každém shardu
db.movies.aggregate(
  [
    { $match: { original_language: "fr", vote_count: { $gte: 100 } } },
    { $group: {
      _id: "$original_language",
      pocet_filmu: { $sum: 1 },
      prumerne_hodnoceni: { $avg: "$vote_average" },
      prumerny_budget_mil: { $avg: { $divide: ["$budget", 1000000] } }
    }}
  ]
).explain("executionStats")

// Pipeline na indexované pole vote_average → IXSCAN (využije index { vote_average: -1, vote_count: -1 })
db.movies.aggregate(
  [
    { $match: { vote_average: { $gte: 8.0 }, vote_count: { $gte: 200 } } },
    { $group: {
      _id: { $floor: "$vote_average" },
      pocet_filmu: { $sum: 1 },
      prumerny_budget_mil: { $avg: { $divide: ["$budget", 1000000] } },
      prumerne_trzby_mil: { $avg: { $divide: ["$revenue", 1000000] } }
    }},
    { $sort: { _id: -1 } }
  ]
).explain("executionStats")
```

**Komentář:** `explain("executionStats")` na aggregační pipeline odhalí, jak MongoDB zpracovává první fázi `$match`. U první pipeline (pole `original_language` bez indexu) uvidíme `stage: "COLLSCAN"` – MongoDB prochází všechny dokumenty (~4 800) a `docsExamined` odpovídá celkovému počtu. U druhé pipeline (compound index `{ vote_average: -1, vote_count: -1 }`) uvidíme `stage: "IXSCAN"` – MongoDB přečte pouze klíče indexu splňující podmínku, `totalKeysExamined` bude výrazně nižší. V shardovaném clusteru `explain()` navíc odhalí fázi `SHARD_MERGE`, kde mongos agreguje výsledky ze všech tří shardů, přičemž každý shard provádí svůj `$match` + `$group` lokálně před odesláním partial výsledků.

---

### Dotaz 20: Fulltextové vyhledávání s relevance score

**Úloha:** Vyhledat filmy s tématikou vesmíru a mimozemšťanů pomocí textového indexu a seřadit výsledky podle relevance.

```js
db.movies.aggregate([
  { $match: {
    $text: { $search: "space alien future war galaxy" }
  }},
  { $addFields: {
    skore_relevance: { $meta: "textScore" }
  }},
  { $match: { vote_count: { $gte: 100 } } },
  { $sort: { skore_relevance: -1 } },
  { $project: {
    _id: 0,
    title: 1,
    vote_average: 1,
    skore_relevance: { $round: ["$skore_relevance", 3] },
    ukazka_popisu: { $substr: ["$overview", 0, 120] }
  }},
  { $limit: 10 }
])
```

**Komentář:** `$text` operátor využívá existující textový index `{ title: "text", overview: "text" }` a prohledá oba indexované atributy zároveň – bez tohoto indexu by dotaz selhal s chybou. `{ $meta: "textScore" }` přidá relevance skóre: čím vyšší, tím lépe text odpovídá hledaným výrazům. MongoDB text index používá stemming (vyhledá i varianty slov: "war" → "wars") a stopwords (ignoruje "the", "and"). `$substr` zkrátí popis na 120 znaků. Tento dotaz nelze snadno přeformulovat přes shardovanou kolekci bez textového indexu – index je zde nezbytný.

---

### Dotaz 21: Vynucení konkrétního indexu pomocí hint() a srovnání výkonu

**Úloha:** Ukázat, jak volba `hint()` ovlivní aggregační pipeline – porovnat plán při automatickém výběru indexu, vynuceném compound indexu a vynuceném COLLSCAN.

```js
// Varianta A: MongoDB optimizer sám zvolí nejlepší index pro pipeline
db.movies.aggregate(
  [
    { $match: { vote_average: { $gte: 7.0 }, vote_count: { $gte: 100 } } },
    { $group: {
      _id: null,
      pocet_filmu: { $sum: 1 },
      prumerne_hodnoceni: { $avg: "$vote_average" },
      prumerny_budget_mil: { $avg: { $divide: ["$budget", 1000000] } }
    }}
  ]
).explain("executionStats")

// Varianta B: Explicitní hint na compound index { vote_average, vote_count }
db.movies.aggregate(
  [
    { $match: { vote_average: { $gte: 7.0 }, vote_count: { $gte: 100 } } },
    { $group: {
      _id: null,
      pocet_filmu: { $sum: 1 },
      prumerne_hodnoceni: { $avg: "$vote_average" },
      prumerny_budget_mil: { $avg: { $divide: ["$budget", 1000000] } }
    }}
  ],
  { hint: { vote_average: -1, vote_count: -1 } }
).explain("executionStats")

// Varianta C: Vynucení COLLSCAN – přirozené pořadí bez indexu
db.movies.aggregate(
  [
    { $match: { vote_average: { $gte: 7.0 }, vote_count: { $gte: 100 } } },
    { $group: {
      _id: null,
      pocet_filmu: { $sum: 1 },
      prumerne_hodnoceni: { $avg: "$vote_average" },
      prumerny_budget_mil: { $avg: { $divide: ["$budget", 1000000] } }
    }}
  ],
  { hint: "$natural" }
).explain("executionStats")
```

**Komentář:** `hint()` jako volba aggregační pipeline (MongoDB 4.2+) přinutí optimizer použít konkrétní index nebo COLLSCAN bez ohledu na statistiky. Varianta A ukáže, jaký index optimizer sám zvolí (obvykle compound index pokrývající obě pole z `$match`). Varianta B explicitně vynutí compound index `{ vote_average: -1, vote_count: -1 }` – výsledkem by měl být stejný nebo podobný plán jako v A. Varianta C s `"$natural"` vynutí COLLSCAN i přes existující indexy – `executionTimeMillis` výrazně vzroste a `totalDocsExamined` bude roven celkovému počtu dokumentů kolekce. Toto trojí srovnání dokazuje, že pro tento dotaz compound index snižuje náklady řádově, a vysvětluje, proč `hint()` slouží k ladění nebo obcházení suboptimálního plánu při zastaralých statistikách.

---

### Dotaz 22: Statistiky využití indexů v kolekci movies

**Úloha:** Zjistit, které indexy jsou skutečně využívány, kolikrát, a identifikovat případné nevyužívané indexy.

```js
db.movies.aggregate([
  { $indexStats: {} },
  { $project: {
    nazev_indexu: "$name",
    pocet_pouziti: "$accesses.ops",
    sledovano_od: "$accesses.since",
    klic_indexu: "$key"
  }},
  { $sort: { pocet_pouziti: -1 } }
])
```

**Komentář:** `$indexStats` je speciální agregační fáze, která vrátí statistiky o každém indexu v kolekci – bez dalších filtrů (proto není potřeba `$match`). Pole `accesses.ops` udává počet přístupů přes daný index od spuštění `$indexStats` sledování (`accesses.since`). V shardovaném clusteru dotaz agreguje statistiky ze všech shardů. Indexy s `pocet_pouziti: 0` jsou nevyužívané a zbytečně zpomalují zápisy a zabírají místo – v produkci by měly být odstraněny příkazem `db.movies.dropIndex(...)`.

---

### Dotaz 23: Analytická kontrola referenční integrity a kvality dat

**Úloha:** Ověřit referenční integritu mezi kolekcemi a identifikovat záznamy s chybějícími vazbami nebo podezřelými hodnotami – osiřelá hodnocení, osiřelé credits a filmy s anomálními finančními daty.

```js
// Kontrola 1: Hodnocení v ratings bez odpovídajícího záznamu v movies (osiřelá hodnocení)
db.ratings.aggregate([
  { $group: {
    _id: "$movieId",
    pocet_hodnoceni: { $sum: 1 },
    prumerne_hodnoceni: { $avg: "$rating" }
  }},
  { $lookup: {
    from: "movies",
    localField: "_id",
    foreignField: "id",
    as: "film_data"
  }},
  { $match: { film_data: { $size: 0 } } },
  { $sort: { pocet_hodnoceni: -1 } },
  { $limit: 10 },
  { $project: {
    _id: 0,
    movieId: "$_id",
    pocet_hodnoceni: 1,
    prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] }
  }}
])

// Kontrola 2: Credits bez odpovídajícího záznamu v movies (osiřelé credits)
db.credits.aggregate([
  { $lookup: {
    from: "movies",
    localField: "movie_id",
    foreignField: "id",
    as: "film_data"
  }},
  { $match: { film_data: { $size: 0 } } },
  { $project: {
    _id: 0,
    movie_id: 1,
    title: 1
  }},
  { $limit: 10 }
])

// Kontrola 3: Filmy s podezřele vysokým ROI (revenue > 50× budget) – možná chybná data
db.movies.aggregate([
  { $match: { budget: { $gt: 1000000 }, revenue: { $gt: 0 } } },
  { $addFields: {
    roi_nasobek: { $round: [{ $divide: ["$revenue", "$budget"] }, 1] }
  }},
  { $match: { roi_nasobek: { $gt: 50 } } },
  { $sort: { roi_nasobek: -1 } },
  { $project: {
    _id: 0,
    title: 1,
    release_date: 1,
    budget_mil: { $round: [{ $divide: ["$budget", 1000000] }, 2] },
    revenue_mil: { $round: [{ $divide: ["$revenue", 1000000] }, 2] },
    roi_nasobek: 1
  }},
  { $limit: 10 }
])
```

**Komentář:** Všechny tři části kontrolují reálnou konzistenci dat v databázi. Kontrola 1 aggreguje `ratings` po `movieId`, pak přes `$lookup` dohledá odpovídající film v `movies` – dokumenty s prázdným polem `film_data` jsou osiřelá hodnocení (MovieLens obsahuje filmy, které nejsou v TMDB). Kontrola 2 provede totéž pro `credits` – odhalí záznamy cast/crew pro filmy neexistující v movies. Kontrola 3 identifikuje potenciálně chybná finanční data: `$addFields` vypočítá ROI násobek a druhý `$match` (po transformaci) filtruje extrémní hodnoty – film s `revenue = 50× budget` je buď výjimečný hit (Blair Witch Project), nebo obsahuje chybný budget (nula nahrazená jinou hodnotou). Tato analytická práce nad živými daty ukazuje vazby mezi kolekcemi a dokumentuje kvalitu importovaných datasetů.

---

### Dotaz 24: Analýza query plánu pro ratings – targeted vs scatter-gather

**Úloha:** Porovnat efektivitu targeted query (přes shard key) oproti scatter-gather dotazu (bez shard key) na kolekci ratings.

```js
// Targeted query – dotaz přes shard key userId → jde pouze na 1 shard
db.ratings.find({ userId: 42 }).explain("executionStats")

// Scatter-gather – dotaz bez shard key → jde na všechny 3 shardy
db.ratings.find(
  { rating: { $gte: 4.5 }, movieId: { $in: [1, 2, 50, 110, 260] } }
).explain("executionStats")

// Analytický dotaz s indexem na movieId (sekundární index)
db.ratings.aggregate([
  { $match: { movieId: 296 } },
  { $group: {
    _id: "$rating",
    pocet: { $sum: 1 }
  }},
  { $sort: { _id: -1 } }
])
```

**Komentář:** Tři dotazy demonstrují různé strategie v shardovaném clusteru: (1) Targeted query s `userId` (shard key) – mongos vypočítá hash a pošle dotaz přesně na jeden shard; v `explain()` je `SHARDS_SCANNED: 1`. (2) Scatter-gather bez shard key – mongos rozešle dotaz na všechny 3 shardy a merguje výsledky; `SHARDS_SCANNED: 3` a výrazně vyšší latence. (3) Třetí dotaz ukazuje, jak sekundární index na `movieId` pomáhá v rámci scatter-gather dotazu – každý shard použije index místo COLLSCAN, ale dotaz stále prochází všemi shardy.

---

## KATEGORIE 5: Distribuce dat, cluster a replikace

### Dotaz 25: Kompletní stav shardovaného clusteru

**Úloha:** Zobrazit aktuální stav celého MongoDB clusteru – shardy, mongos routery, stav balanceru a doplnit analytický přehled aktivních mongos routerů a konfigurací shardovaných kolekcí z config databáze.

```js
// Spustit z mongos1
sh.status()
```

```js
// Stav balanceru a probíhající migrace chunků
db.adminCommand({ balancerStatus: 1 })
```

```js
// Agregace aktivních mongos routerů z config databáze s časem posledního pingu
use config
db.mongos.aggregate([
  { $addFields: {
    posledni_ping_datum: {
      $toDate: { $multiply: [{ $tsSecond: "$ping" }, 1000] }
    }
  }},
  { $project: {
    _id: 0,
    adresa: "$_id",
    verze: "$mongoVersion",
    posledni_ping_datum: 1
  }},
  { $sort: { adresa: 1 } }
])
```

**Komentář:** `sh.status()` poskytuje celkový přehled clusteru: shardy, chunky, balancer. `balancerStatus` vrátí, zda balancer běží a zda aktuálně probíhá migrace chunků – při migraci může dojít ke krátkému zvýšení latence zápisů. Třetí příkaz je aggregační pipeline nad `config.mongos` – interní kolekcí, kam každý mongos router zapisuje heartbeat. `$tsSecond` extrahuje sekundy z BSON Timestamp `ping` a `$toDate` jej převede na čitelný datum – výsledek ukáže, kdy naposledy každý mongos hlásil svůj stav config serverům. Mongos, který přestal pingnout (rozdíl větší než ~30 sekund), je pravděpodobně nedostupný.

---

### Dotaz 26: Distribuce dat na shardech pro všechny kolekce

**Úloha:** Zobrazit přesné rozložení dokumentů a dat mezi shardy pro kolekce movies, credits a ratings, a doplnit přesné počty dokumentů a velikosti úložiště na každém shardu pomocí `$collStats`.

```js
use filmdb

db.movies.getShardDistribution()

db.credits.getShardDistribution()

db.ratings.getShardDistribution()
```

```js
// Přesné počty dokumentů a velikost úložiště na každém shardu pro kolekci ratings
// (největší kolekce – nejlépe ilustruje rovnoměrnost hashed shardingu)
use filmdb
db.ratings.aggregate([
  { $collStats: { storageStats: {} } },
  { $project: {
    _id: 0,
    shard: 1,
    pocet_dokumentu: "$storageStats.count",
    velikost_mb: { $round: [{ $divide: ["$storageStats.storageSize", 1048576] }, 2] },
    prumerny_dokument_b: { $round: ["$storageStats.avgObjSize", 0] },
    pocet_indexu: "$storageStats.nindexes"
  }},
  { $sort: { pocet_dokumentu: -1 } }
])
```

**Komentář:** `getShardDistribution()` vrátí pro každou kolekci podrobné statistiky: počet dokumentů a velikost dat na každém shardu, procentuální podíl a počet chunků. U hashed shardingu by mělo být rozložení přibližně rovnoměrné (~33 % na každý shard). `$collStats` s `storageStats` je aggregační pipeline fáze, která vrátí per-shard statistiky přímo z storage enginu – jeden dokument za každý shard. `$divide` převede bajty na megabajty, `avgObjSize` ukáže průměrnou velikost dokumentu hodnocení. Porovnáním `pocet_dokumentu` mezi shardy lze ověřit, jak dobře hashed sharding na `userId` rozložil 100 000+ hodnocení – ideálně by odchylka neměla překročit ~5 %. Shard key `{ userId: "hashed" }` zaručuje rovnoměrné rozložení i při skewnutém vstupním rozložení userId.

---

### Dotaz 27: Stav replica setu a detaily replikace shard1

**Úloha:** Zobrazit detailní stav replica setu shard1 – seznam členů, jejich role (PRIMARY/SECONDARY) a synchronizační stav, a doplnit analýzu oplog logu pro přehled o typech a objemu replikovaných operací.

```js
// Připojit se přímo na shard1svr1:
// docker exec -it shard1svr1 mongosh -u admin -p adminpass123 --authenticationDatabase admin

rs.status()
```

```js
// Konfigurace replica setu – heartbeat interval, election timeout, priorita nodů
rs.conf()
```

```js
// Analýza typů operací v oplog logu PRIMARY za posledních 24 hodin
use local
db.oplog.rs.aggregate([
  { $match: {
    ts: { $gte: new Timestamp(Math.floor(Date.now() / 1000) - 86400, 0) }
  }},
  { $group: {
    _id: "$op",
    pocet: { $sum: 1 }
  }},
  { $addFields: {
    popis_operace: {
      $switch: {
        branches: [
          { case: { $eq: ["$_id", "i"] }, then: "INSERT" },
          { case: { $eq: ["$_id", "u"] }, then: "UPDATE" },
          { case: { $eq: ["$_id", "d"] }, then: "DELETE" },
          { case: { $eq: ["$_id", "c"] }, then: "COMMAND" },
          { case: { $eq: ["$_id", "n"] }, then: "NOOP (heartbeat)" }
        ],
        default: "OSTATNÍ"
      }
    }
  }},
  { $sort: { pocet: -1 } }
])
```

**Komentář:** `rs.status()` vrátí kompletní stav replica setu: `stateStr` (PRIMARY/SECONDARY), `health`, `optimeDate` (čas posledního oplog záznamu) a `pingMs` (latence heartbeatu). `rs.conf()` doplní konfiguraci: `heartbeatIntervalMillis` (výchozí 2 000 ms), `electionTimeoutMillis` (výchozí 10 000 ms) a `priority` každého člena – node s `priority: 0` se nikdy nestane PRIMARY. Třetí příkaz je aggregační pipeline nad `local.oplog.rs` – ringbuffer replikovaných operací. `$match` s `new Timestamp(unix_sek, 0)` omezí analýzu na posledních 24 hodin. `$group` sečte operace podle typu (`op` pole) a `$addFields` s `$switch` přeloží jednopísmenné kódy na čitelné názvy. Výsledek ukáže, zda převažují INSERTy (import dat), UPDATE nebo NOOP heartbeaty.

---

### Dotaz 28: Simulace výpadku PRIMARY nodu a sledování automatické volby

**Úloha:** Simulovat výpadek PRIMARY nodu ve shard1, sledovat průběh automatické election a ověřit dostupnost clusteru během výpadku.

```js
// KROK 1: Zjistit aktuálního PRIMARY (spustit na shard1svr1)
rs.isMaster()
```

```bash
# KROK 2: Zastavit PRIMARY kontejner (simulace výpadku hardwaru)
docker stop shard1svr1
```

```bash
# KROK 3: Připojit se na shard1svr2 a sledovat election
docker exec -it shard1svr2 mongosh -u admin -p adminpass123 --authenticationDatabase admin
```

```js
// KROK 4: Opakovaně spouštět pro sledování průběhu election (10–30 sekund)
rs.status().members.map(m => ({
  name: m.name,
  state: m.stateStr,
  health: m.health
}))
```

```bash
# KROK 5: Obnovit výpadnutý node
docker start shard1svr1
```

```js
// KROK 6: Ověřit znovupřipojení jako SECONDARY
rs.status().members.map(m => ({ name: m.name, state: m.stateStr }))
```

**Komentář:** MongoDB replica set s 3 nody toleruje výpadek 1 nodu díky majority quorum (2 ze 3). Po výpadku PRIMARY zahájí zbývající SECONDARY nody Raft election protokol: (1) node s nejaktuálnějším oplogem zahájí volbu, (2) ostatní nody hlasují, (3) nový PRIMARY je zvolen typicky do 10–30 sekund. Během election jsou zápisy dočasně nedostupné (čtení s `readPreference: secondaryPreferred` funguje). `writeConcern: majority` zajišťuje, že všechna potvrzená data jsou na min. 2 nodech a nepřijdou se obnovením výpadnutého nodu. Shard2 a shard3 zůstávají plně funkční – výpadek jednoho shardu neovlivní ostatní.

---

### Dotaz 29: Analýza clusteru – metadata shardů a distribuce chunků

**Úloha:** Zobrazit konfiguraci clusteru z pohledu mongos a analyzovat rozmístění chunků v config databázi.

```js
// Seznam všech registrovaných shardů
db.adminCommand({ listShards: 1 })
```

```js
// Metadata shardovaných kolekcí z config databáze
use config

db.collections.find(
  { _id: /^filmdb/ },
  { _id: 1, key: 1, unique: 1 }
)
```

```js
// Počty chunků na shardech pro kolekce filmdb
db.chunks.aggregate([
  { $match: { ns: /^filmdb/ } },
  { $group: {
    _id: { ns: "$ns", shard: "$shard" },
    pocet_chunku: { $sum: 1 }
  }},
  { $sort: { "_id.ns": 1, "_id.shard": 1 } }
])
```

**Komentář:** `listShards` vrátí JSON s konfiguracemi všech zaregistrovaných shardů. Config databáze (`config`) je interní databáze MongoDB clusteru uložená na config serverech (configReplSet) – nikoliv na datových shardech. `config.collections` uchovává definice shardovaných kolekcí a shard keys, `config.chunks` mapování chunků na shardy s jejich hash rozsahy (MinKey/MaxKey pro hashed sharding). Analýza chunků ověřuje rovnoměrnost rozložení dat – balancer automaticky přesouvá chunky, pokud rozdíl mezi shardey přesáhne threshold (výchozí: 3 chunky).

---

### Dotaz 30: Replikační lag a zdravotní stav replikace

**Úloha:** Zjistit replikační zpoždění SECONDARY nodů, ověřit stav oplog logu a zobrazit zdraví celé replikační skupiny.

```js
// Spustit na PRIMARY shard1svr1:
// docker exec -it shard1svr1 mongosh -u admin -p adminpass123 --authenticationDatabase admin

// Replikační statistiky pro SECONDARY nody
rs.printSecondaryReplicationInfo()
```

```js
// Detailní informace o oplog logu PRIMARY nodu
db.getReplicationInfo()
```

```js
// Přehled zdraví všech členů replica setu s lagy
rs.status().members.map(m => ({
  jmeno: m.name,
  stav: m.stateStr,
  zdravi: m.health,
  cas_optime: m.optimeDate,
  pingMs: m.pingMs || 0
}))
```

```js
// Analytický výpočet oplog okna – jak daleko zpět sahá replikační historie PRIMARY
// (určuje, jak dlouho může být SECONDARY offline a stále se resynchronizovat)
use local
db.oplog.rs.aggregate([
  { $group: {
    _id: null,
    celkovy_pocet_zaznamu: { $sum: 1 },
    nejstarsi_ts: { $min: "$ts" },
    nejnovejsi_ts: { $max: "$ts" }
  }},
  { $project: {
    _id: 0,
    celkovy_pocet_zaznamu: 1,
    nejstarsi_datum: { $toDate: { $multiply: [{ $tsSecond: "$nejstarsi_ts" }, 1000] } },
    nejnovejsi_datum: { $toDate: { $multiply: [{ $tsSecond: "$nejnovejsi_ts" }, 1000] } },
    oplog_okno_hodin: {
      $round: [{
        $divide: [
          { $subtract: [{ $tsSecond: "$nejnovejsi_ts" }, { $tsSecond: "$nejstarsi_ts" }] },
          3600
        ]
      }, 1]
    }
  }}
])
```

**Komentář:** `rs.printSecondaryReplicationInfo()` zobrazí pro každý SECONDARY `behind` (zpoždění za PRIMARY v sekundách) – v naší konfiguraci by měl být lag < 1 sekundy, protože všechny nody běží na stejném hostiteli. `db.getReplicationInfo()` vrátí velikost oplog a časové razítko prvního a posledního záznamu. Čtvrtá část je aggregační pipeline nad `local.oplog.rs`: `$group` s `$min` a `$max` na BSON Timestamp poli `ts` najde nejstarší a nejnovější oplog záznam, `$tsSecond` extrahuje unixový čas v sekundách (dostupné v MongoDB 5.1+), `$subtract` vypočítá délku okna v sekundách a `$divide` převede na hodiny. `oplog_okno_hodin` je klíčová provozní metrika – pokud SECONDARY byl offline déle, než toto okno, musí provést full initial sync místo inkrementální replikace z oplog. `writeConcern: majority` garantuje, že data jsou zapsána na min. 2 nody před potvrzením klientovi.
