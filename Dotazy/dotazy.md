# Dotazy – MongoDB Sharded Cluster – Filmová databáze

**Projekt:** BSQBD – NoSQL dokumentová databáze
**Student:** Kobrle
**Databáze:** filmdb (MongoDB 8.0 Sharded Cluster)

## Přehled kolekcí

| Kolekce   | Počet dokumentů | Shard key                |
| --------- | --------------- | ------------------------ |
| `movies`  | ~4 800          | `{ id: "hashed" }`       |
| `credits` | ~4 800          | `{ movie_id: "hashed" }` |
| `ratings` | ~100 000        | `{ userId: "hashed" }`   |

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
  {
    $group: {
      _id: "$genres.name",
      prumerne_hodnoceni: { $avg: "$vote_average" },
      prumerny_pocet_hlasu: { $avg: "$vote_count" },
      pocet_filmu: { $sum: 1 },
    },
  },
  { $match: { pocet_filmu: { $gte: 10 } } },
  { $sort: { prumerne_hodnoceni: -1 } },
  {
    $project: {
      _id: 1,
      prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
      prumerny_pocet_hlasu: { $round: ["$prumerny_pocet_hlasu", 0] },
      pocet_filmu: 1,
    },
  },
]);
```

**Komentář:** `$unwind` rozloží pole `genres` – každý film má více žánrů, takže každý žánr se stane samostatným dokumentem. `$group` agreguje filmy podle názvu žánru, `$avg` počítá průměry a `$sum: 1` počítá výskyty. `$match` po agregaci (ne před) filtruje žánry s malou vzorkem. `$project` s `$round` zaokrouhluje výsledky na 2 desetinná místa. Dotaz prochází všemi třemi shardy (scatter-gather), protože shard key `id` není součástí filtru.

---

### Dotaz 2: Top 10 nejziskovějších filmů s výpočtem ROI

**Úloha:** Najít 10 filmů s nejvyšším absolutním ziskem, vypočítat ROI (Return on Investment) a zobrazit jejich hodnocení.

```js
db.movies.aggregate([
  {
    $match: {
      budget: { $gt: 1000000 },
      revenue: { $gt: 0 },
    },
  },
  {
    $addFields: {
      zisk: { $subtract: ["$revenue", "$budget"] },
      roi_procent: {
        $round: [
          {
            $multiply: [
              { $divide: [{ $subtract: ["$revenue", "$budget"] }, "$budget"] },
              100,
            ],
          },
          1,
        ],
      },
    },
  },
  { $sort: { zisk: -1 } },
  { $limit: 10 },
  {
    $project: {
      _id: 0,
      title: 1,
      budget_mil: { $round: [{ $divide: ["$budget", 1000000] }, 1] },
      revenue_mil: { $round: [{ $divide: ["$revenue", 1000000] }, 1] },
      zisk_mil: { $round: [{ $divide: ["$zisk", 1000000] }, 1] },
      roi_procent: 1,
      vote_average: 1,
    },
  },
]);
```

**Komentář:** `$match` nejprve filtruje filmy s reálnými finančními daty (budget > 1M, revenue > 0) – odstraní filmy bez finančních dat. `$addFields` přidává dvě vypočtená pole: `zisk` jako aritmetický rozdíl tržeb a rozpočtu, `roi_procent` jako procentuální návratnost investice s vnořenou operací `$divide`/`$multiply`. Obě pole vznikají v jediném průchodu dokumentem. Hodnoty jsou v `$project` transformovány na miliony USD pomocí `$divide` pro čitelnost.

---

### Dotaz 3: Distribuce filmů do hodnotících skupin pomocí $bucket

**Úloha:** Rozdělit filmy do skupin podle hodnocení a pro každou skupinu zjistit počet filmů, průměrný rozpočet a průměrné tržby.

```js
db.movies.aggregate([
  { $match: { vote_count: { $gte: 50 } } },
  {
    $bucket: {
      groupBy: "$vote_average",
      boundaries: [0, 4, 5, 6, 7, 8, 10.1],
      default: "Nehodnoceno",
      output: {
        pocet_filmu: { $sum: 1 },
        prumerny_budget_mil: { $avg: { $divide: ["$budget", 1000000] } },
        prumerne_trzby_mil: { $avg: { $divide: ["$revenue", 1000000] } },
        prumerne_hodnoceni: { $avg: "$vote_average" },
      },
    },
  },
  {
    $project: {
      _id: 1,
      pocet_filmu: 1,
      prumerny_budget_mil: { $round: ["$prumerny_budget_mil", 1] },
      prumerne_trzby_mil: { $round: ["$prumerne_trzby_mil", 1] },
      prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
    },
  },
]);
```

**Komentář:** `$bucket` je specializovaná agregační fáze, která rozděluje dokumenty do předdefinovaných intervalů (buckets) podle hodnoty pole `vote_average`. Hranice `[0, 4, 5, 6, 7, 8, 10.1]` vytváří skupiny: méně než 4 (propadáky), 4–5, 5–6, 6–7, 7–8 a 8–10 (výborné). Klausule `default` zachytí dokumenty mimo rozsah (hodnocení přesně 0 nebo > 10). Výpočet finančních průměrů přímo v `output` eliminuje potřebu následného `$addFields`. Výsledek odhaluje, zda lépe hodnocené filmy mají i vyšší rozpočty a tržby.

---

### Dotaz 4: Roční analýza filmové produkce (2000–2016)

**Úloha:** Analyzovat trend počtu filmů, průměrného hodnocení, celkového rozpočtu a tržeb pro každý rok v období 2000–2016.

```js
db.movies.aggregate([
  { $match: { release_date: { $gt: "" } } },
  {
    $addFields: {
      rok: { $toInt: { $substr: ["$release_date", 0, 4] } },
    },
  },
  {
    $match: {
      rok: { $gte: 2000, $lte: 2016 },
      vote_count: { $gte: 20 },
    },
  },
  {
    $group: {
      _id: "$rok",
      pocet_filmu: { $sum: 1 },
      prumerne_hodnoceni: { $avg: "$vote_average" },
      celkovy_budget_mld: { $sum: "$budget" },
      celkove_trzby_mld: { $sum: "$revenue" },
      nejvyssi_hodnoceni: { $max: "$vote_average" },
    },
  },
  { $sort: { _id: 1 } },
  {
    $project: {
      rok: "$_id",
      pocet_filmu: 1,
      prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
      celkovy_budget_mld: {
        $round: [{ $divide: ["$celkovy_budget_mld", 1000000000] }, 2],
      },
      celkove_trzby_mld: {
        $round: [{ $divide: ["$celkove_trzby_mld", 1000000000] }, 2],
      },
      nejvyssi_hodnoceni: 1,
    },
  },
]);
```

**Komentář:** `$addFields` extrahuje rok z řetězce `release_date` pomocí `$substr` (první 4 znaky) a `$toInt` pro převod na číslo – nutné pro porovnávání v `$match`. `$match` filtruje rozsah let i minimální počet hodnocení (eliminuje filmy s jedním anonymním hodnocením). `$group` agreguje data po rocích s více akumulátory najednou: `$avg`, `$sum`, `$max`. `$project` přejmenuje `_id` na `rok` a transformuje absolutní hodnoty rozpočtů na miliardy USD pro lepší čitelnost trendů.

---

### Dotaz 5: Filmové produkční společnosti s nejlepším výkonem

**Úloha:** Zjistit, které produkční společnosti (s min. 5 filmy) dosahují nejvyššího průměrného hodnocení, a vypočítat jejich celkovou efektivitu investic.

```js
db.movies.aggregate([
  { $unwind: "$production_companies" },
  {
    $group: {
      _id: "$production_companies.name",
      pocet_filmu: { $sum: 1 },
      prumerne_hodnoceni: { $avg: "$vote_average" },
      celkove_trzby: { $sum: "$revenue" },
      celkovy_budget: { $sum: "$budget" },
    },
  },
  {
    $match: {
      pocet_filmu: { $gte: 5 },
      celkovy_budget: { $gt: 0 },
    },
  },
  {
    $addFields: {
      efektivita_roi: {
        $round: [
          {
            $multiply: [
              {
                $divide: [
                  { $subtract: ["$celkove_trzby", "$celkovy_budget"] },
                  "$celkovy_budget",
                ],
              },
              100,
            ],
          },
          1,
        ],
      },
    },
  },
  { $sort: { prumerne_hodnoceni: -1 } },
  { $limit: 10 },
  {
    $project: {
      _id: 1,
      pocet_filmu: 1,
      prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
      celkove_trzby_mld: {
        $round: [{ $divide: ["$celkove_trzby", 1000000000] }, 2],
      },
      efektivita_roi: 1,
    },
  },
]);
```

**Komentář:** `$unwind` rozloží pole `production_companies` – film může mít více producentů, každý se stane samostatným dokumentem (jeden film se pak počítá vícekrát). `$group` agreguje per-společnost statistiky. `$match` po agregaci (nikoli před) filtruje společnosti s malou filmografií a nulový budget (dělení nulou). `$addFields` přidá vlastní metriku ROI společnosti jako poměr celkových tržeb k celkovým investicím v procentech. Výsledek kombinuje kritickou i komerční úspěšnost.

---

### Dotaz 6: Multi-dimenzionální analýza pomocí $facet

**Úloha:** Paralelně analyzovat filmovou databázi ze tří pohledů najednou: rozložení podle žánrů, hodnotících skupin a dekád.

```js
db.movies.aggregate([
  { $match: { vote_count: { $gte: 100 }, release_date: { $gt: "" } } },
  {
    $facet: {
      top_zanry: [
        { $unwind: "$genres" },
        {
          $group: {
            _id: "$genres.name",
            pocet: { $sum: 1 },
            avg_hodnoceni: { $avg: "$vote_average" },
          },
        },
        { $sort: { pocet: -1 } },
        { $limit: 5 },
      ],
      hodnotici_skupiny: [
        {
          $bucket: {
            groupBy: "$vote_average",
            boundaries: [0, 5, 6, 7, 8, 10.1],
            default: "N/A",
            output: {
              pocet: { $sum: 1 },
              prumerny_budget_mil: { $avg: { $divide: ["$budget", 1000000] } },
            },
          },
        },
      ],
      po_dekadach: [
        {
          $addFields: {
            dekada: {
              $multiply: [
                {
                  $floor: {
                    $divide: [
                      { $toInt: { $substr: ["$release_date", 0, 4] } },
                      10,
                    ],
                  },
                },
                10,
              ],
            },
          },
        },
        {
          $group: {
            _id: "$dekada",
            pocet: { $sum: 1 },
            avg_hodnoceni: { $avg: "$vote_average" },
          },
        },
        { $sort: { _id: 1 } },
      ],
    },
  },
]);
```

**Komentář:** `$facet` je výjimečná fáze, která spustí více nezávislých agregačních pipeline nad identickou vstupní sadou dat v jediném průchodu kolekcí – výrazně efektivnější než tři separátní dotazy. Větev `top_zanry` kombinuje `$unwind` + `$group` + `$sort` + `$limit`. Větev `hodnotici_skupiny` používá `$bucket`. Větev `po_dekadach` vypočítá dekádu jako `floor(rok/10)*10` pomocí `$toInt`, `$substr`, `$floor`, `$divide` a `$multiply`. Celý dotaz vrátí jeden dokument s třemi vnořenými výsledky.

---

## KATEGORIE 2: Propojování dat a vazby mezi datasety

### Dotaz 7: Nejčastěji obsazovaní herci napříč celou databází

**Úloha:** Zjistit, kteří herci se v databázi TMDB Credits objevují v nejvíce filmech, a zobrazit ukázku jejich filmografie.

```js
db.credits.aggregate([
  { $unwind: "$cast" },
  {
    $group: {
      _id: "$cast.name",
      pocet_filmu: { $sum: 1 },
      filmy: { $push: "$title" },
    },
  },
  { $sort: { pocet_filmu: -1 } },
  { $limit: 10 },
  {
    $project: {
      _id: 1,
      pocet_filmu: 1,
      ukazka_filmu: { $slice: ["$filmy", 3] },
    },
  },
]);
```

**Komentář:** `$unwind` rozloží pole `cast` v kolekci `credits` – každý herec z každého filmu se stane samostatným dokumentem (z 4 800 záznamů vznikne řádově stovky tisíc dokumentů). `$group` seskupuje podle jména herce, `$sum: 1` počítá výskyty a `$push` shromažďuje názvy filmů do pole. `$project` s `$slice` zobrazí pouze prvních 3 filmy jako ukázku, aby byl výstup přehledný a pole `filmy` nepřetěžovalo výstup. Dotaz funguje pouze na kolekci `credits` (není potřeba `$lookup`).

---

### Dotaz 8: Nejlépe hodnocené filmy s jejich režiséry

**Úloha:** Ke každému vysoce hodnocenému filmu (≥ 7.5, min. 500 hlasů) dohledat jméno režiséra z kolekce credits přes vazbu `movies.id → credits.movie_id`.

```js
db.movies.aggregate([
  { $match: { vote_average: { $gte: 7.5 }, vote_count: { $gte: 500 } } },
  {
    $lookup: {
      from: "credits",
      localField: "id",
      foreignField: "movie_id",
      as: "info_o_hercich",
    },
  },
  { $unwind: { path: "$info_o_hercich", preserveNullAndEmptyArrays: false } },
  {
    $addFields: {
      reziser: {
        $arrayElemAt: [
          {
            $filter: {
              input: "$info_o_hercich.crew",
              as: "clen",
              cond: { $eq: ["$$clen.job", "Director"] },
            },
          },
          0,
        ],
      },
    },
  },
  {
    $project: {
      _id: 0,
      title: 1,
      vote_average: 1,
      vote_count: 1,
      release_date: 1,
      reziser_jmeno: "$reziser.name",
    },
  },
  { $sort: { vote_average: -1 } },
  { $limit: 15 },
]);
```

**Komentář:** `$lookup` realizuje JOIN mezi `movies` (`localField: id`) a `credits` (`foreignField: movie_id`) – tato vazba odpovídá datovému modelu obou TMDB kolekcí. V shardovaném clusteru mongos koordinuje `$lookup` přes všechny shardy obou kolekcí. `$filter` prochází pole `crew` a vrátí pouze členy s `job = "Director"`. `$arrayElemAt` s indexem 0 vezme prvního nalezeného režiséra (někteří filmy mají více spoluregistrovaných). Výsledkem je JOIN přes dvě shardované kolekce s filtrací vnořeného pole.

---

### Dotaz 9: Režiséři s nejvyšším průměrným hodnocením jejich filmů

**Úloha:** Identifikovat nejúspěšnější režiséry (min. 3 filmy, min. 100 hlasů na film) podle průměrného hodnocení TMDB.

```js
db.credits.aggregate([
  { $unwind: "$crew" },
  { $match: { "crew.job": "Director" } },
  {
    $lookup: {
      from: "movies",
      localField: "movie_id",
      foreignField: "id",
      as: "film_info",
    },
  },
  { $unwind: "$film_info" },
  { $match: { "film_info.vote_count": { $gte: 100 } } },
  {
    $group: {
      _id: "$crew.name",
      pocet_filmu: { $sum: 1 },
      prumerne_hodnoceni: { $avg: "$film_info.vote_average" },
      celkove_trzby_mld: { $sum: "$film_info.revenue" },
      filmy: { $push: "$film_info.title" },
    },
  },
  { $match: { pocet_filmu: { $gte: 3 } } },
  { $sort: { prumerne_hodnoceni: -1 } },
  { $limit: 10 },
  {
    $project: {
      _id: 1,
      pocet_filmu: 1,
      prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
      celkove_trzby_mld: {
        $round: [{ $divide: ["$celkove_trzby_mld", 1000000000] }, 2],
      },
      ukazka_filmu: { $slice: ["$filmy", 3] },
    },
  },
]);
```

**Komentář:** Pipeline začíná v `credits`, rozloží `crew` a okamžitě filtruje `Directors` – tím sníží objem dat před `$lookup`. `$lookup` přidá data z `movies`. Druhý `$match` po `$lookup` odfiltruje filmy s nedostatečným počtem hodnocení (eliminuje zkreslení průměru). `$group` agreguje celou kariéru každého režiséra. Dva `$match` příkazy v různých fázích pipeline ukazují, jak lze filtrovat vstup i výstup `$lookup`.

---

### Dotaz 10: Herci s nejvíce hlavními rolemi v akčních filmech

**Úloha:** Zjistit, kteří herci (v rolích order ≤ 3, tedy protagonisté) se nejčastěji objevují v akčních filmech, a jaké bylo průměrné hodnocení těchto filmů.

```js
db.movies.aggregate([
  { $unwind: "$genres" },
  { $match: { "genres.name": "Action" } },
  {
    $group: {
      _id: "$id",
      title: { $first: "$title" },
      vote_average: { $first: "$vote_average" },
    },
  },
  {
    $lookup: {
      from: "credits",
      localField: "_id",
      foreignField: "movie_id",
      as: "cast_info",
    },
  },
  { $unwind: "$cast_info" },
  { $unwind: "$cast_info.cast" },
  { $match: { "cast_info.cast.order": { $lte: 3 } } },
  {
    $group: {
      _id: "$cast_info.cast.name",
      pocet_action_filmu: { $sum: 1 },
      prumerne_hodnoceni_akce: { $avg: "$vote_average" },
      filmy: { $push: "$title" },
    },
  },
  { $sort: { pocet_action_filmu: -1 } },
  { $limit: 10 },
  {
    $project: {
      _id: 1,
      pocet_action_filmu: 1,
      prumerne_hodnoceni_akce: { $round: ["$prumerne_hodnoceni_akce", 2] },
      ukazka_filmu: { $slice: ["$filmy", 3] },
    },
  },
]);
```

**Komentář:** Komplexní pipeline se 7 fázemi: `$unwind` + `$match` filtruje akční filmy, `$group` odstraní duplicity vznikající po `$unwind` žánrů, `$lookup` přidá herce, dva `$unwind` rozloží vnořená data, druhý `$match` omezí na protagonisty (order ≤ 3). Výsledek ukazuje specializaci herců na akční žánr a korelaci s kvalitou filmů. `$lookup` zde jde opačným směrem než v dotazu 8 – od movie k cast.

---

### Dotaz 11: Vliv velikosti hereckého obsazení na hodnocení a tržby

**Úloha:** Analyzovat korelaci mezi počtem herců v obsazení a průměrným hodnocením a tržbami filmů.

```js
db.movies.aggregate([
  { $match: { vote_count: { $gte: 100 } } },
  {
    $lookup: {
      from: "credits",
      localField: "id",
      foreignField: "movie_id",
      as: "credits_data",
    },
  },
  { $unwind: { path: "$credits_data", preserveNullAndEmptyArrays: false } },
  { $addFields: { pocet_hercu: { $size: "$credits_data.cast" } } },
  {
    $group: {
      _id: {
        $switch: {
          branches: [
            { case: { $lte: ["$pocet_hercu", 10] }, then: "01–10 herců" },
            { case: { $lte: ["$pocet_hercu", 20] }, then: "11–20 herců" },
            { case: { $lte: ["$pocet_hercu", 30] }, then: "21–30 herců" },
            { case: { $lte: ["$pocet_hercu", 50] }, then: "31–50 herců" },
          ],
          default: "50+ herců",
        },
      },
      pocet_filmu: { $sum: 1 },
      prumerne_hodnoceni: { $avg: "$vote_average" },
      prumerne_trzby_mil: { $avg: { $divide: ["$revenue", 1000000] } },
    },
  },
  { $sort: { _id: 1 } },
  {
    $project: {
      _id: 1,
      pocet_filmu: 1,
      prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
      prumerne_trzby_mil: { $round: ["$prumerne_trzby_mil", 1] },
    },
  },
]);
```

**Komentář:** Po `$lookup` a `$unwind` přidá `$addFields` počet herců jako `$size` pole `cast` – jde o výpočet z vnořeného pole přineseného `$lookup`. Výsledek se seskupí do kategorií pomocí `$switch` přímo v `$group._id` – netriviální použití výrazu jako skupinového klíče. Výsledek odhaluje korelaci mezi rozsahem obsazení a komerčním úspěchem (větší produkce typicky investují do širšího obsazení a dosahují vyšších tržeb).

---

### Dotaz 12: Nejhodnocenější filmy uživateli s analýzou konzistence hodnocení

**Úloha:** Najít filmy s největším počtem uživatelských hodnocení a zjistit konzistenci hodnocení pomocí standardní odchylky.

```js
db.ratings.aggregate([
  {
    $group: {
      _id: "$movieId",
      pocet_hodnoceni: { $sum: 1 },
      prumerne_hodnoceni: { $avg: "$rating" },
      nejmensi: { $min: "$rating" },
      nejvetsi: { $max: "$rating" },
      smerodatna_odchylka: { $stdDevSamp: "$rating" },
      unikatni_hodnotitele: { $addToSet: "$userId" },
    },
  },
  {
    $addFields: {
      pocet_unikatnich: { $size: "$unikatni_hodnotitele" },
      konzistence: {
        $switch: {
          branches: [
            {
              case: { $lt: ["$smerodatna_odchylka", 0.8] },
              then: "Konzistentní",
            },
            {
              case: { $lt: ["$smerodatna_odchylka", 1.2] },
              then: "Středně variabilní",
            },
          ],
          default: "Kontroverzní",
        },
      },
    },
  },
  { $match: { pocet_hodnoceni: { $gte: 50 } } },
  { $sort: { pocet_hodnoceni: -1 } },
  { $limit: 10 },
  {
    $project: {
      _id: 1,
      pocet_hodnoceni: 1,
      prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
      smerodatna_odchylka: { $round: ["$smerodatna_odchylka", 2] },
      konzistence: 1,
      pocet_unikatnich: 1,
    },
  },
]);
```

**Komentář:** `$stdDevSamp` je statistický akumulátor, který vypočítá výběrovou standardní odchylku hodnocení pro každý film – nízká hodnota znamená shodu uživatelů, vysoká indikuje kontroverzní film. `$addToSet` shromáždí unikátní `userId` (bez duplicit), `$size` pak spočítá počet skutečných hodnotitelů. `$addFields` po `$group` klasifikuje filmy přes `$switch`. Dotaz kombinuje 5 různých akumulátorů v jednom `$group`.

---

## KATEGORIE 3: Transformace a obohacení dat

### Dotaz 13: Klasifikace filmů podle kategorie rozpočtu a analýza ROI

**Úloha:** Klasifikovat filmy do kategorií podle výše rozpočtu a analyzovat průměrnou ROI, hodnocení a procento ziskových filmů v každé kategorii.

```js
db.movies.aggregate([
  { $match: { budget: { $gt: 0 }, revenue: { $gt: 0 } } },
  {
    $addFields: {
      kategorie_rozpoctu: {
        $switch: {
          branches: [
            {
              case: { $gte: ["$budget", 100000000] },
              then: "Blockbuster (100M+ USD)",
            },
            {
              case: { $gte: ["$budget", 20000000] },
              then: "Velká produkce (20–100M USD)",
            },
            {
              case: { $gte: ["$budget", 5000000] },
              then: "Středorozpočtový (5–20M USD)",
            },
          ],
          default: "Nízkorozpočtový (<5M USD)",
        },
      },
      roi: {
        $round: [
          {
            $multiply: [
              { $divide: [{ $subtract: ["$revenue", "$budget"] }, "$budget"] },
              100,
            ],
          },
          1,
        ],
      },
    },
  },
  {
    $group: {
      _id: "$kategorie_rozpoctu",
      pocet_filmu: { $sum: 1 },
      prumerne_roi: { $avg: "$roi" },
      prumerne_hodnoceni: { $avg: "$vote_average" },
      prumerne_trzby_mil: { $avg: { $divide: ["$revenue", 1000000] } },
      uspesnych_podil: {
        $avg: { $cond: [{ $gt: ["$revenue", "$budget"] }, 1, 0] },
      },
    },
  },
  { $sort: { prumerne_roi: -1 } },
  {
    $project: {
      _id: 1,
      pocet_filmu: 1,
      prumerne_roi: { $round: ["$prumerne_roi", 1] },
      prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
      prumerne_trzby_mil: { $round: ["$prumerne_trzby_mil", 1] },
      uspesnost_procent: {
        $round: [{ $multiply: ["$uspesnych_podil", 100] }, 1],
      },
    },
  },
]);
```

**Komentář:** `$addFields` přidává dvě vypočtená pole: `kategorie_rozpoctu` klasifikuje filmy pomocí `$switch` a `roi` vypočítá ROI v procentech se zanořenými operátory. `$group` agreguje kategorie a v poli `uspesnych_podil` používá `$avg` na podmíněném výrazu `$cond` – elegantní způsob výpočtu procenta ziskových filmů bez separátního `$match`. Výsledek ukazuje, že nízkorozpočtové filmy mohou mít vyšší ROI než blockbustery.

---

### Dotaz 14: Analýza mluvených jazyků ve světové kinematografii

**Úloha:** Zjistit rozložení mluvených jazyků ve filmech a jejich vliv na průměrné hodnocení, tržby a celkový podíl na trhu.

```js
db.movies.aggregate([
  { $unwind: "$spoken_languages" },
  {
    $group: {
      _id: "$spoken_languages.name",
      pocet_filmu: { $sum: 1 },
      prumerne_hodnoceni: { $avg: "$vote_average" },
      prumerne_trzby: { $avg: "$revenue" },
      celkove_trzby: { $sum: "$revenue" },
    },
  },
  { $match: { pocet_filmu: { $gte: 15 } } },
  {
    $addFields: {
      podil_trzby_mld: {
        $round: [{ $divide: ["$celkove_trzby", 1000000000] }, 2],
      },
    },
  },
  { $sort: { pocet_filmu: -1 } },
  { $limit: 12 },
  {
    $project: {
      _id: 1,
      pocet_filmu: 1,
      prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
      prumerne_trzby_mil: {
        $round: [{ $divide: ["$prumerne_trzby", 1000000] }, 1],
      },
      podil_trzby_mld: 1,
    },
  },
]);
```

**Komentář:** `$unwind` rozloží pole `spoken_languages` – film může být ve více jazycích. `$group` agreguje per-jazyk statistiky s více akumulátory. `$addFields` po agregaci přidává celkový tržní podíl v miliardách. Výsledek odhaluje dominanci anglofonní kinematografie (English se očekávaně umístí první), ale také komerční výkon ostatních jazykových kinematografií. Srovnání `prumerne_hodnoceni` mezi jazyky ukazuje, zda existuje korelace mezi jazykem produkce a kritikou přijatým výsledkem.

---

### Dotaz 15: Obohacení dokumentu – přehledná karta filmu s odvozenými poli

**Úloha:** Transformovat dokument o filmu do přehledné karty přidáním normalizovaných hodnot, klasifikací a odstraněním nepotřebných polí.

```js
db.movies.aggregate([
  { $match: { vote_count: { $gte: 200 }, release_date: { $gt: "" } } },
  {
    $addFields: {
      rok_vydani: { $toInt: { $substr: ["$release_date", 0, 4] } },
      hodnoceni_normalizovane: {
        $round: [{ $multiply: ["$vote_average", 10] }, 0],
      },
      klasifikace_delky: {
        $switch: {
          branches: [
            { case: { $lt: ["$runtime", 90] }, then: "Krátký (<90 min)" },
            {
              case: { $lte: ["$runtime", 120] },
              then: "Standardní (90–120 min)",
            },
            { case: { $lte: ["$runtime", 150] }, then: "Dlouhý (120–150 min)" },
          ],
          default: "Epický (>150 min)",
        },
      },
      financni_uspech: {
        $cond: {
          if: { $and: [{ $gt: ["$budget", 0] }, { $gt: ["$revenue", 0] }] },
          then: {
            $cond: [
              { $gt: ["$revenue", { $multiply: ["$budget", 2] }] },
              "Velký úspěch",
              {
                $cond: [
                  { $gt: ["$revenue", "$budget"] },
                  "Ziskový",
                  "Ztrátový",
                ],
              },
            ],
          },
          else: "Data nedostupná",
        },
      },
      zanry_seznam: { $map: { input: "$genres", as: "g", in: "$$g.name" } },
    },
  },
  {
    $unset: [
      "genres",
      "keywords",
      "production_companies",
      "production_countries",
      "spoken_languages",
      "homepage",
      "tagline",
      "popularity",
      "_id",
    ],
  },
  { $sort: { vote_average: -1 } },
  { $limit: 10 },
]);
```

**Komentář:** `$addFields` přidává 5 odvozených polí najednou: `rok_vydani` extrakcí z řetězce, `hodnoceni_normalizovane` na škálu 0–100, `klasifikace_delky` přes `$switch`, `financni_uspech` přes vnořené `$cond` (trojstavová logika) a `zanry_seznam` přes `$map` pro transformaci pole objektů na pole řetězců. `$unset` odstraní přebytečná pole a zkrátí dokument. Kombinace `$addFields` + `$unset` je standardní vzor pro transformaci dokumentů před výstupem.

---

### Dotaz 16: Trendy filmového průmyslu po pětiletích (1980–2016)

**Úloha:** Zjistit, jak se vyvíjelo průměrné hodnocení, délka filmů, objem produkce a investice v pětiletých intervalech.

```js
db.movies.aggregate([
  {
    $addFields: {
      rok: { $toInt: { $substr: ["$release_date", 0, 4] } },
    },
  },
  { $match: { rok: { $gte: 1980, $lte: 2016 }, vote_count: { $gte: 30 } } },
  {
    $addFields: {
      petileti: { $multiply: [{ $floor: { $divide: ["$rok", 5] } }, 5] },
    },
  },
  {
    $group: {
      _id: "$petileti",
      pocet_filmu: { $sum: 1 },
      prumerne_hodnoceni: { $avg: "$vote_average" },
      prumerny_runtime_min: { $avg: "$runtime" },
      prumerny_budget_mil: { $avg: { $divide: ["$budget", 1000000] } },
      filmy_s_financnimi_daty: {
        $sum: { $cond: [{ $gt: ["$budget", 0] }, 1, 0] },
      },
    },
  },
  { $sort: { _id: 1 } },
  {
    $project: {
      obdobi: {
        $concat: [
          { $toString: "$_id" },
          "–",
          { $toString: { $add: ["$_id", 4] } },
        ],
      },
      pocet_filmu: 1,
      prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
      prumerny_runtime_min: { $round: ["$prumerny_runtime_min", 0] },
      prumerny_budget_mil: { $round: ["$prumerny_budget_mil", 1] },
      filmy_s_financnimi_daty: 1,
    },
  },
]);
```

**Komentář:** Dvoustupňové `$addFields`: nejprve extrakce roku, pak výpočet pětiletí jako `floor(rok/5)*5`. `$group` s `$sum` na podmíněném výrazu `$cond` počítá filmy s dostupnými finančními daty. `$project` transformuje `_id` na čitelný řetězec "1980–1984" pomocí `$concat` + `$toString` + `$add`. Výsledek zachycuje trendy: nárůst průměrné délky filmů, evoluci produkčních nákladů a změny v hodnocení mezi dekádami.

---

### Dotaz 17: Analýza aktivity uživatelů v čase podle roku a měsíce

**Úloha:** Zjistit, jak se vyvíjela aktivita hodnotitelů a průměrná hodnocení v jednotlivých měsících, přičemž timestamp je konvertován z Unix formátu.

```js
db.ratings.aggregate([
  {
    $addFields: {
      datum: { $toDate: { $multiply: ["$timestamp", 1000] } },
    },
  },
  {
    $addFields: {
      rok: { $year: "$datum" },
      mesic: { $month: "$datum" },
    },
  },
  {
    $group: {
      _id: { rok: "$rok", mesic: "$mesic" },
      pocet_hodnoceni: { $sum: 1 },
      prumerne_hodnoceni: { $avg: "$rating" },
      unikatni_uzivatele: { $addToSet: "$userId" },
    },
  },
  {
    $addFields: {
      pocet_uzivatelu: { $size: "$unikatni_uzivatele" },
    },
  },
  { $sort: { "_id.rok": 1, "_id.mesic": 1 } },
  {
    $project: {
      _id: 0,
      rok: "$_id.rok",
      mesic: "$_id.mesic",
      pocet_hodnoceni: 1,
      prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
      pocet_uzivatelu: 1,
    },
  },
  { $limit: 24 },
]);
```

**Komentář:** `$multiply` převede Unix timestamp (sekundy) na milisekundy, `$toDate` jej konvertuje na MongoDB Date objekt. Druhý `$addFields` extrahuje `$year` a `$month` z Date objektu – operace dostupné pouze na Date typech. `$addToSet` shromáždí unikátní `userId` (bez duplicit) a `$size` spočítá jejich počet až po `$group` v separátním `$addFields`. Složený klíč `{ rok, mesic }` v `$group._id` umožňuje granulární analýzu sezónnosti hodnocení.

---

### Dotaz 18: Segmentace uživatelů podle hodnotícího chování

**Úloha:** Segmentovat uživatele do skupin podle jejich aktivity a průměrného hodnocení, a zjistit složení komunity hodnotitelů.

```js
db.ratings.aggregate([
  {
    $group: {
      _id: "$userId",
      pocet_hodnoceni: { $sum: 1 },
      prumerne_hodnoceni: { $avg: "$rating" },
      hodnoceni_5hvezd: { $sum: { $cond: [{ $eq: ["$rating", 5.0] }, 1, 0] } },
      hodnoceni_1hvezda: {
        $sum: { $cond: [{ $lte: ["$rating", 1.0] }, 1, 0] },
      },
    },
  },
  {
    $addFields: {
      typ_uzivatele: {
        $switch: {
          branches: [
            {
              case: { $gte: ["$pocet_hodnoceni", 200] },
              then: "Superhodnotitel (200+)",
            },
            {
              case: { $gte: ["$pocet_hodnoceni", 50] },
              then: "Aktivní (50–199)",
            },
            {
              case: { $gte: ["$pocet_hodnoceni", 20] },
              then: "Příležitostný (20–49)",
            },
          ],
          default: "Nový (<20)",
        },
      },
      styl_hodnoceni: {
        $switch: {
          branches: [
            {
              case: { $gt: ["$prumerne_hodnoceni", 4.0] },
              then: "Optimista (>4.0)",
            },
            {
              case: { $lt: ["$prumerne_hodnoceni", 2.5] },
              then: "Kritik (<2.5)",
            },
          ],
          default: "Vyrovnaný (2.5–4.0)",
        },
      },
    },
  },
  {
    $group: {
      _id: { typ: "$typ_uzivatele", styl: "$styl_hodnoceni" },
      pocet_uzivatelu: { $sum: 1 },
      prumerny_pocet_hodnoceni: { $avg: "$pocet_hodnoceni" },
    },
  },
  { $sort: { pocet_uzivatelu: -1 } },
]);
```

**Komentář:** Dvoustupňová agregace: první `$group` agreguje hodnocení za každého uživatele a `$sum` s `$cond` počítá podmíněné součty (5hvězdičková a 1hvězdičková hodnocení bez `$filter`). `$addFields` klasifikuje uživatele dvěma `$switch` výrazy. Druhý `$group` seskupuje uživatele do segmentů podle kombinace (typ × styl). Výsledek ukazuje, kolik uživatelů je "optimistů-superhodnotitelů" vs "kritiků-nových hodnotitelů" apod.

---

## KATEGORIE 4: Indexy a optimalizace

### Dotaz 19: Dopad pořadí fází aggregační pipeline na výkon

**Úloha:** Demonstrovat, jak pořadí `$match` a `$group` v aggregační pipeline zásadně ovlivňuje využití indexu – správné pořadí umožní IXSCAN, špatné pořadí vynutí COLLSCAN celé kolekce.

```js
// Zachycení baseline přístupů k indexům před spuštěním dotazů
var toMap = function (arr) {
  return arr.reduce(function (acc, i) {
    acc[i.name] = i.accesses.ops;
    return acc;
  }, {});
};
var before = toMap(db.movies.aggregate([{ $indexStats: {} }]).toArray());

// Varianta A: $match PŘED $group → optimizer pushdownuje podmínku, využije compound index
var t0 = Date.now();
db.movies
  .aggregate([
    { $match: { vote_average: { $gte: 7.5 }, vote_count: { $gte: 500 } } },
    {
      $group: {
        _id: { $floor: "$vote_average" },
        pocet: { $sum: 1 },
        prumerne_trzby_mil: { $avg: { $divide: ["$revenue", 1000000] } },
        prumerny_budget_mil: { $avg: { $divide: ["$budget", 1000000] } },
      },
    },
    { $sort: { _id: -1 } },
  ])
  .toArray();
var timeA = Date.now() - t0;
var afterA = toMap(db.movies.aggregate([{ $indexStats: {} }]).toArray());

// Varianta B: $group PŘED $match → $match filtruje mezivýsledek, index nelze použít
var t1 = Date.now();
db.movies
  .aggregate([
    {
      $group: {
        _id: { $floor: "$vote_average" },
        pocet: { $sum: 1 },
        prumerne_trzby_mil: { $avg: { $divide: ["$revenue", 1000000] } },
        prumerny_budget_mil: { $avg: { $divide: ["$budget", 1000000] } },
      },
    },
    { $match: { _id: { $gte: 7 } } },
    { $sort: { _id: -1 } },
  ])
  .toArray();
var timeB = Date.now() - t1;
var afterB = toMap(db.movies.aggregate([{ $indexStats: {} }]).toArray());

// Srovnání časů
print("=== Časy spuštění ===");
print("  Varianta A ($match → $group) : " + timeA + " ms");
print("  Varianta B ($group → $match) : " + timeB + " ms");

// Které indexy byly zasaženy – delta přístupů (accesses.ops)
print("\n=== Delta přístupů k indexům ===");
Object.keys(afterB).forEach(function (name) {
  var dA = afterA[name] - before[name];
  var dB = afterB[name] - afterA[name];
  print("  " + name + " → A: +" + dA + "  B: +" + dB);
});
```

**Komentář:** Obě varianty vrátí logicky stejné výsledky, ale s odlišným využitím indexů. Ve variantě A stojí `$match` na poli `vote_average` jako první fáze pipeline – MongoDB optimizer pushdownuje podmínku na IXSCAN přes index `vote_average_-1`. Ve variantě B je `$match` na poli `_id` teprve po `$group` – mezivýsledek skupin (`{ _id: 7, pocet: ... }`) je nová struktura bez původního pole `vote_average`, takže index nelze použít. Místo nestabilního `explain()` (MongoDB 8.0 mění formát výstupu pro aggregate na mongos) dotaz měří dopad přímo přes `$indexStats`: zachytí `accesses.ops` každého indexu před i po každé variantě. Skutečný výstup potvrdí: `vote_average_-1 → A: +1  B: +0` – index byl zasažen pouze ve variantě A. Časový rozdíl (4 ms vs 6 ms) je malý kvůli velikosti datasetu (~4 800 filmů); na produkčních datech v řádu milionů by byl rozdíl dramatičtější.

---

### Dotaz 20: Fulltextové vyhledávání s relevance score

**Úloha:** Vyhledat filmy s tématikou vesmíru a mimozemšťanů pomocí textového indexu a seřadit výsledky podle relevance.

```js
db.movies.aggregate([
  {
    $match: {
      $text: { $search: "space alien future war galaxy" },
    },
  },
  {
    $addFields: {
      skore_relevance: { $meta: "textScore" },
    },
  },
  { $match: { vote_count: { $gte: 100 } } },
  { $sort: { skore_relevance: -1 } },
  {
    $project: {
      _id: 0,
      title: 1,
      vote_average: 1,
      skore_relevance: { $round: ["$skore_relevance", 3] },
      ukazka_popisu: { $substr: ["$overview", 0, 120] },
    },
  },
  { $limit: 10 },
]);
```

**Komentář:** `$text` operátor využívá existující textový index `{ title: "text", overview: "text" }` a prohledá oba indexované atributy zároveň – bez tohoto indexu by dotaz selhal s chybou. `{ $meta: "textScore" }` přidá relevance skóre: čím vyšší, tím lépe text odpovídá hledaným výrazům. MongoDB text index používá stemming (vyhledá i varianty slov: "war" → "wars") a stopwords (ignoruje "the", "and"). `$substr` zkrátí popis na 120 znaků. Tento dotaz nelze snadno přeformulovat přes shardovanou kolekci bez textového indexu – index je zde nezbytný.

---

### Dotaz 21: Vynucení konkrétního indexu pomocí hint() a srovnání výkonu

**Úloha:** Ukázat, jak volba `hint()` ovlivní aggregační pipeline – porovnat plán při automatickém výběru indexu, vynuceném indexu `{ vote_average: -1 }` a COLLSCAN na neindexovaném poli. Výsledky jsou zobrazeny přehledně přes pomocnou funkci `explainSummary`.

```js
// Pomocné funkce pro přehledný výstup explain napříč shardy (MongoDB 8.0)
function findStage(plan) {
  if (!plan) return null;
  if (plan.stage === "IXSCAN" || plan.stage === "COLLSCAN") return plan;
  return findStage(plan.inputStage);
}

function explainSummary(explainResult) {
  // MongoDB 8.0: shards jsou v executionStats.executionStages.shards
  var shardsList =
    (explainResult.executionStats &&
      explainResult.executionStats.executionStages &&
      explainResult.executionStats.executionStages.shards) ||
    [];

  if (shardsList.length === 0) {
    // Fallback: starší MongoDB nebo standalone
    var s = explainResult.executionStats || {};
    var leaf = findStage(
      explainResult.queryPlanner && explainResult.queryPlanner.winningPlan,
    );
    return [
      {
        shard: "standalone",
        stage: leaf ? leaf.stage : "neznamy",
        indexUsed: leaf ? leaf.indexName || "none" : "none",
        totalKeysExamined: s.totalKeysExamined || 0,
        totalDocsExamined: s.totalDocsExamined || 0,
        executionTimeMillis: s.executionTimeMillis || 0,
      },
    ];
  }

  return shardsList.map(function (shardData) {
    var leaf = findStage(shardData.executionStages);
    var s = shardData.executionStats || {};
    return {
      shard: shardData.shardName,
      stage: leaf ? leaf.stage : "neznamy",
      indexUsed: leaf ? leaf.indexName || "none" : "none",
      totalKeysExamined: s.totalKeysExamined || 0,
      totalDocsExamined: s.totalDocsExamined || 0,
      executionTimeMillis: s.executionTimeMillis || 0,
    };
  });
}

const pipeline = [
  { $match: { vote_average: { $gte: 7.0 }, vote_count: { $gte: 100 } } },
  {
    $group: {
      _id: null,
      pocet_filmu: { $sum: 1 },
      prumerne_hodnoceni: { $avg: "$vote_average" },
      prumerny_budget_mil: { $avg: { $divide: ["$budget", 1000000] } },
    },
  },
];

// Varianta A: MongoDB optimizer sám zvolí nejlepší index
print("=== Varianta A: Auto ===");
printjson(
  explainSummary(db.movies.aggregate(pipeline).explain("executionStats")),
);

// Varianta B: Explicitní hint na index { vote_average: -1 }
print("=== Varianta B: Hint (IXSCAN) ===");
printjson(
  explainSummary(
    db.movies
      .aggregate(pipeline, { hint: { vote_average: -1 } })
      .explain("executionStats"),
  ),
);

// Varianta C: COLLSCAN – dotaz na neindexované pole (original_language), index nelze použít
print("=== Varianta C: COLLSCAN (neindexované pole) ===");
printjson(
  explainSummary(
    db.movies
      .aggregate([
        { $match: { original_language: "en", vote_count: { $gte: 100 } } },
        { $group: { _id: null, pocet_filmu: { $sum: 1 } } },
      ])
      .explain("executionStats"),
  ),
);
```

**Komentář:** `findStage` rekurzivně prochází strom execution plánu a najde první `IXSCAN` nebo `COLLSCAN` uzel — nutné protože MongoDB 8.0 zanořuje plán do vrstev (`GROUP → SHARDING_FILTER → FETCH → IXSCAN`). `explainSummary` v MongoDB 8.0 hledá per-shard data v `executionStats.executionStages.shards` (změna oproti MongoDB 4.x, kde byla na top úrovni jako `explainResult.shards`). Varianta A ukáže, že optimizer sám správně zvolí compound index `vote_average_-1_vote_count_-1` (~330 klíčů na shard). Varianta B s `hint({ vote_average: -1 })` přinutí použít stejný index — výsledek je identický, což potvrzuje, že optimizer zvolil optimálně. Varianta C dotazuje neindexované pole `original_language` — MongoDB musí projít všechny dokumenty (`COLLSCAN`, ~1 600 na shard, `totalKeysExamined: 0`). Poznámka: `hint("$natural")` není podporován na shardovaných kolekcích v MongoDB 8.0, proto je COLLSCAN demonstrován přes neindexované pole.

---

### Dotaz 22: Statistiky využití indexů v kolekci movies

**Úloha:** Zjistit, které indexy jsou skutečně využívány, kolikrát, a identifikovat případné nevyužívané indexy.

```js
db.movies.aggregate([
  { $indexStats: {} },
  {
    $project: {
      nazev_indexu: "$name",
      pocet_pouziti: "$accesses.ops",
      sledovano_od: "$accesses.since",
      klic_indexu: "$key",
    },
  },
  { $sort: { pocet_pouziti: -1 } },
]);
```

**Komentář:** `$indexStats` je speciální agregační fáze, která vrátí statistiky o každém indexu v kolekci – bez dalších filtrů (proto není potřeba `$match`). Pole `accesses.ops` udává počet přístupů přes daný index od spuštění `$indexStats` sledování (`accesses.since`). V shardovaném clusteru dotaz agreguje statistiky ze všech shardů. Indexy s `pocet_pouziti: 0` jsou nevyužívané a zbytečně zpomalují zápisy a zabírají místo – v produkci by měly být odstraněny příkazem `db.movies.dropIndex(...)`.

---

### Dotaz 23: Analytická kontrola referenční integrity a kvality dat

**Úloha:** Ověřit referenční integritu mezi kolekcemi a identifikovat záznamy s chybějícími vazbami nebo podezřelými hodnotami – osiřelá hodnocení, osiřelé credits a filmy s anomálními finančními daty.

```js
// Kontrola 1: Hodnocení v ratings bez odpovídajícího záznamu v movies (osiřelá hodnocení)
db.ratings.aggregate([
  {
    $group: {
      _id: "$movieId",
      pocet_hodnoceni: { $sum: 1 },
      prumerne_hodnoceni: { $avg: "$rating" },
    },
  },
  {
    $lookup: {
      from: "movies",
      localField: "_id",
      foreignField: "id",
      as: "film_data",
    },
  },
  { $match: { film_data: { $size: 0 } } },
  { $sort: { pocet_hodnoceni: -1 } },
  { $limit: 10 },
  {
    $project: {
      _id: 0,
      movieId: "$_id",
      pocet_hodnoceni: 1,
      prumerne_hodnoceni: { $round: ["$prumerne_hodnoceni", 2] },
    },
  },
]);

// Kontrola 2: Credits bez odpovídajícího záznamu v movies (osiřelé credits)
db.credits.aggregate([
  {
    $lookup: {
      from: "movies",
      localField: "movie_id",
      foreignField: "id",
      as: "film_data",
    },
  },
  { $match: { film_data: { $size: 0 } } },
  {
    $project: {
      _id: 0,
      movie_id: 1,
      title: 1,
    },
  },
  { $limit: 10 },
]);

// Kontrola 3: Filmy s podezřele vysokým ROI (revenue > 50× budget) – možná chybná data
db.movies.aggregate([
  { $match: { budget: { $gt: 1000000 }, revenue: { $gt: 0 } } },
  {
    $addFields: {
      roi_nasobek: { $round: [{ $divide: ["$revenue", "$budget"] }, 1] },
    },
  },
  { $match: { roi_nasobek: { $gt: 50 } } },
  { $sort: { roi_nasobek: -1 } },
  {
    $project: {
      _id: 0,
      title: 1,
      release_date: 1,
      budget_mil: { $round: [{ $divide: ["$budget", 1000000] }, 2] },
      revenue_mil: { $round: [{ $divide: ["$revenue", 1000000] }, 2] },
      roi_nasobek: 1,
    },
  },
  { $limit: 10 },
]);
```

**Komentář:** Všechny tři části kontrolují reálnou konzistenci dat v databázi. Kontrola 1 aggreguje `ratings` po `movieId`, pak přes `$lookup` dohledá odpovídající film v `movies` – dokumenty s prázdným polem `film_data` jsou osiřelá hodnocení (MovieLens obsahuje filmy, které nejsou v TMDB). Kontrola 2 provede totéž pro `credits` – odhalí záznamy cast/crew pro filmy neexistující v movies. Kontrola 3 identifikuje potenciálně chybná finanční data: `$addFields` vypočítá ROI násobek a druhý `$match` (po transformaci) filtruje extrémní hodnoty – film s `revenue = 50× budget` je buď výjimečný hit (Blair Witch Project), nebo obsahuje chybný budget (nula nahrazená jinou hodnotou). Tato analytická práce nad živými daty ukazuje vazby mezi kolekcemi a dokumentuje kvalitu importovaných datasetů.

---

### Dotaz 24: Analýza query plánu pro ratings – targeted vs scatter-gather

**Úloha:** Porovnat efektivitu targeted query (přes shard key) oproti scatter-gather dotazu (bez shard key) na kolekci ratings.

```js
// Targeted query – dotaz přes shard key userId → jde pouze na 1 shard
db.ratings.find({ userId: 42 }).explain("executionStats");

// Scatter-gather – dotaz bez shard key → jde na všechny 3 shardy
db.ratings
  .find({ rating: { $gte: 4.5 }, movieId: { $in: [1, 2, 50, 110, 260] } })
  .explain("executionStats");

// Analytický dotaz s indexem na movieId (sekundární index)
db.ratings.aggregate([
  { $match: { movieId: 296 } },
  {
    $group: {
      _id: "$rating",
      pocet: { $sum: 1 },
    },
  },
  { $sort: { _id: -1 } },
]);
```

**Komentář:** Tři dotazy demonstrují různé strategie v shardovaném clusteru: (1) Targeted query s `userId` (shard key) – mongos vypočítá hash a pošle dotaz přesně na jeden shard; v `explain()` je `SHARDS_SCANNED: 1`. (2) Scatter-gather bez shard key – mongos rozešle dotaz na všechny 3 shardy a merguje výsledky; `SHARDS_SCANNED: 3` a výrazně vyšší latence. (3) Třetí dotaz ukazuje, jak sekundární index na `movieId` pomáhá v rámci scatter-gather dotazu – každý shard použije index místo COLLSCAN, ale dotaz stále prochází všemi shardy.

---

## KATEGORIE 5: Distribuce dat, cluster a replikace

### Dotaz 25: Kompletní stav shardovaného clusteru

**Úloha:** Zobrazit aktuální stav celého MongoDB clusteru – shardy, mongos routery, stav balanceru a doplnit analytický přehled aktivních mongos routerů a konfigurací shardovaných kolekcí z config databáze.

```js
// Spustit z mongos1 (filmdb):
// winpty docker exec -it mongos1 mongosh -u admin -p adminpass123 --authenticationDatabase admin filmdb
sh.status();
```

```js
// Stav balanceru a probíhající migrace chunků
db.adminCommand({ balancerStatus: 1 });
```

```js
// Agregace aktivních mongos routerů z config databáze s časem posledního pingu
// getSiblingDB("config") přepne kontext bez příkazu "use config"
db.getSiblingDB("config").mongos.aggregate([
  {
    $addFields: {
      sekund_od_pingu: {
        $round: [{ $divide: [{ $subtract: ["$$NOW", "$ping"] }, 1000] }, 0],
      },
    },
  },
  {
    $project: {
      _id: 0,
      adresa: "$_id",
      verze: "$mongoVersion",
      posledni_ping_datum: "$ping",
      sekund_od_pingu: 1,
      stav: {
        $cond: [{ $lte: ["$sekund_od_pingu", 30] }, "ONLINE", "NEDOSTUPNY"],
      },
    },
  },
  { $sort: { adresa: 1 } },
]);
```

```js
// Detekce nerovnoměrnosti chunků napříč shardy – imbalance větší než 3 chunky
// spouští automatický balancer (výchozí threshold v MongoDB 8.0)
db.getSiblingDB("config").chunks.aggregate([
  {
    $lookup: {
      from: "collections",
      localField: "uuid",
      foreignField: "uuid",
      as: "col",
    },
  },
  { $unwind: "$col" },
  { $match: { "col._id": /^filmdb/ } },
  {
    $group: {
      _id: { kolekce: "$col._id", shard: "$shard" },
      pocet_chunku: { $sum: 1 },
    },
  },
  {
    $group: {
      _id: "$_id.kolekce",
      shardy: { $push: { shard: "$_id.shard", chunky: "$pocet_chunku" } },
      max_chunky: { $max: "$pocet_chunku" },
      min_chunky: { $min: "$pocet_chunku" },
    },
  },
  {
    $addFields: {
      imbalance: { $subtract: ["$max_chunky", "$min_chunky"] },
      balancer_zasahne: { $gt: ["$imbalance", 3] },
    },
  },
  {
    $project: {
      _id: 0,
      kolekce: "$_id",
      shardy: 1,
      imbalance: 1,
      balancer_zasahne: 1,
    },
  },
  { $sort: { imbalance: -1 } },
]);
```

**Komentář:** `sh.status()` poskytuje celkový přehled clusteru: shardy, chunky, balancer. `balancerStatus` vrátí, zda balancer běží (`mode: full`) a zda probíhá migrace chunků – při migraci může dojít ke krátkému zvýšení latence zápisů. Třetí příkaz je aggregační pipeline nad `config.mongos` – interní kolekcí, kam každý mongos router zapisuje heartbeat. `$subtract` dvou Date hodnot (`"$$NOW"` a `"$ping"`) vrátí rozdíl v milisekundách, `$divide` jej převede na sekundy a `$cond` klasifikuje router jako `ONLINE` (≤ 30 s) nebo `NEDOSTUPNY` – výstup ukáže oba mongos routery s `sekund_od_pingu: 1–2` a stavem `ONLINE`. Čtvrtá část odhaluje imbalanci chunků: v MongoDB 8.0 `config.chunks` neobsahuje pole `ns` (namespace), ale UUID kolekce – proto je nutný `$lookup` na `config.collections`. Pipeline seskupí chunky dle kolekce a shardu, pak vypočítá `imbalance = max_chunky - min_chunky`. Skutečný výstup ukáže `imbalance: 0` pro všechny tři kolekce (každý shard má přesně 1 chunk) a `balancer_zasahne: false` – hashed sharding rovnoměrně rozdělil data bez nutnosti zásahu balanceru.

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
// Spustit na shard node (rs.* nefunguje na mongos):
// docker exec -it shard1svr3 mongosh

// Přehledný výpis stavu replica setu – jen relevantní pole
var primary = rs.status().members.find(function (m) {
  return m.stateStr === "PRIMARY";
});
rs.status().members.map(function (m) {
  return {
    jmeno: m.name,
    role: m.stateStr,
    zdravi: m.health === 1 ? "OK" : "DOWN",
    optimeDate: m.optimeDate,
    pingMs: m.pingMs || 0,
    lag_za_primarym_s:
      primary && m.optimeDate
        ? Math.round((primary.optimeDate - m.optimeDate) / 1000)
        : "n/a",
  };
});
```

```js
// Klíčové parametry konfigurace replica setu ze status (rs.conf() vyžaduje auth)
var st = rs.status();
printjson({
  nazev: st.set,
  heartbeatIntervalMs: st.heartbeatIntervalMillis,
  cleny: st.members.map(function (m) {
    return {
      host: m.name,
      role: m.stateStr,
      zdravi: m.health === 1 ? "OK" : "DOWN",
    };
  }),
});
```

```js
// Stav optime všech členů ze rs.status() (local db vyžaduje auth – nedostupná bez přihlášení)
var st = rs.status();
printjson({
  setName: st.set,
  lastCommittedOpTime: st.optimes && st.optimes.lastCommittedOpTime,
  appliedOpTime: st.optimes && st.optimes.appliedOpTime,
  cleny_optime: st.members.map(function (m) {
    return {
      host: m.name,
      role: m.stateStr,
      optimeDate: m.optimeDate,
      optimeDurableDate: m.optimeDurableDate,
    };
  }),
});
```

**Komentář:** Namísto surového `rs.status()` (stovky řádků JSON) mapování extrahuje jen klíčová pole: `stateStr` (PRIMARY/SECONDARY), `health` (1 = OK, 0 = DOWN), `optimeDate` (čas posledního replikovaného oplog záznamu) a `pingMs` (latence heartbeatu). Druhý blok zobrazí `heartbeatIntervalMillis` (výchozí 2 000 ms – jak často si nody posílají heartbeat) a přehled rolí všech členů — vše ze `rs.status()`, protože `rs.conf()` vyžaduje `replSetGetConfig` privilegium, které není dostupné přes localhost exception. Třetí blok zobrazí `lastCommittedOpTime` a `appliedOpTime` z `status.optimes` — timestamps posledního potvrzeného a aplikovaného oplog záznamu. `optimeDurableDate` u každého člena ukazuje, kdy byl záznam bezpečně uložen na disk (journaled). Přímý přístup do `local.oplog.rs` vyžaduje auth na `local` databázi, která není dostupná bez credentials na shard nodu.

---

### Dotaz 28: Simulace výpadku PRIMARY nodu a sledování automatické volby

**Úloha:** Simulovat výpadek PRIMARY nodu ve shard1, sledovat průběh automatické election a ověřit dostupnost clusteru během výpadku.

```bash
# ── TERMINÁL A: Shard konzole (zde běží rs.* příkazy) ──────────────────────
docker exec -it shard1svr1 mongosh
```

```js
// KROK 1 [TERMINÁL A – shard1svr1]: Zjistit aktuálního PRIMARY
var info = db.hello();
printjson({
  primary: info.primary,
  isWritablePrimary: info.isWritablePrimary,
  hosts: info.hosts,
  setName: info.setName,
});
```

```bash
# KROK 2 [TERMINÁL B – PowerShell/CMD]: Zastavit PRIMARY kontejner
docker stop shard1svr1
```

```bash
# KROK 3 [TERMINÁL A – stejné okno, nyní se přepojit na shard1svr2]:
docker exec -it shard1svr2 mongosh
```

```js
// KROK 4 [TERMINÁL A – shard1svr2]: Opakovat každých ~5 s, sledovat election
rs.status().members.map(function (m) {
  return {
    name: m.name,
    state: m.stateStr,
    health: m.health,
    optimeDate: m.optimeDate,
  };
});
```

```bash
# KROK 5 [TERMINÁL C – PowerShell/CMD]: Pokus o zápis přes mongos IHNED po docker stop
# Spustit co nejrychleji – election trvá 10–30 s, pak zápis opět projde
docker exec mongos1 mongosh -u admin -p adminpass123 --authenticationDatabase admin filmdb --eval "try { db.movies.insertOne({ id: NumberInt(999999), title: 'test-election', release_date: '2026-01-01' }, { writeConcern: { w: 'majority', wtimeout: 3000 } }); print('Zapis uspesny') } catch(e) { print('Zapis selhal: ' + (e.codeName || e.message || e)) }"
```

```bash
# KROK 6 [TERMINÁL B – PowerShell/CMD]: Obnovit výpadnutý node
docker start shard1svr1
```

```js
// KROK 7 [TERMINÁL A – shard1svr2]: Ověřit stav po obnově
//docker exec -it shard1svr1 mongosh
rs.status().members.map(function (m) {
  return { name: m.name, state: m.stateStr, health: m.health };
});
```

**Komentář:** `db.hello()` je moderní náhrada za deprecated `rs.isMaster()` (dostupná od MongoDB 5.0). Vrací `isWritablePrimary: true` na PRIMARY, `false` na SECONDARY. Po `docker stop shard1svr1` zbývající dva nody (shard1svr2, shard1svr3) zahájí Raft election: kandidát s nejaktuálnějším oplogem zahájí volbu a ostatní hlasují – při 2 z 3 hlasů je nový PRIMARY zvolen typicky do 10–30 sekund. KROK 5 demonstruje klíčové chování: pokus o zápis s `writeConcern: majority` během election skončí chybou `NotWritablePrimary` nebo `wtimeout` – toto je cena za CP garance (Consistency + Partition Tolerance z CAP teorému). Shard2 a shard3 zůstávají plně funkční – výpadek jednoho shardu neovlivní ostatní části clusteru. Po `docker start shard1svr1` se obnovený node připojí jako SECONDARY a replikuje chybějící oplog záznamy bez nutnosti full initial sync (dokud je v oplog okně).

---

### Dotaz 29: Analýza clusteru – metadata shardů a distribuce chunků

**Úloha:** Zobrazit konfiguraci clusteru z pohledu mongos a analyzovat rozmístění chunků v config databázi.

```js
// Spustit z mongos1 (filmdb):
// winpty docker exec -it mongos1 mongosh -u admin -p adminpass123 --authenticationDatabase admin filmdb

// Seznam všech registrovaných shardů
db.adminCommand({ listShards: 1 });
```

```js
// Metadata shardovaných kolekcí z config databáze
db.getSiblingDB("config")
  .collections.find({ _id: /^filmdb/ }, { _id: 1, key: 1, unique: 1 })
  .toArray();
```

```js
// Počty chunků na shardech pro kolekce filmdb – MongoDB 8.0 kompatibilní
// V MongoDB 6+ config.chunks neobsahuje pole "ns", místo toho používá UUID
// → nutný $lookup na config.collections pro získání jména kolekce
db.getSiblingDB("config").chunks.aggregate([
  {
    $lookup: {
      from: "collections",
      localField: "uuid",
      foreignField: "uuid",
      as: "kolekce",
    },
  },
  { $unwind: "$kolekce" },
  { $match: { "kolekce._id": /^filmdb/ } },
  {
    $group: {
      _id: { kolekce: "$kolekce._id", shard: "$shard" },
      pocet_chunku: { $sum: 1 },
    },
  },
  { $sort: { "_id.kolekce": 1, "_id.shard": 1 } },
  {
    $project: {
      _id: 0,
      kolekce: "$_id.kolekce",
      shard: "$_id.shard",
      pocet_chunku: 1,
    },
  },
]);
```

**Komentář:** `listShards` vrátí JSON s konfiguracemi všech tří shardů včetně replica set connection stringů (`shard1ReplSet/shard1svr1:27017,...`). `config.collections` uchovává shard key každé kolekce – výstup potvrdí hashed sharding: `{ movie_id: 'hashed' }`, `{ id: 'hashed' }`, `{ userId: 'hashed' }`. Důležitá změna v MongoDB 6+: `config.chunks` neobsahuje pole `ns` (namespace), ale UUID – proto je nutný `$lookup` na `config.collections`. Skutečný výstup ukáže 9 řádků (3 kolekce × 3 shardy), každý shard má přesně 1 chunk na kolekci (`pocet_chunku: 1`), což potvrzuje rovnoměrné hashed rozdělení. Balancer zasáhne jen při rozdílu > 3 chunky mezi shardy – v tomto případě je cluster perfektně vyvážený.

---

### Dotaz 30: Replikační lag a zdravotní stav replikace

**Úloha:** Zjistit replikační zpoždění SECONDARY nodů, ověřit stav oplog logu a zobrazit zdraví celé replikační skupiny.

```js
// Spustit na aktuálním PRIMARY shardu shard1 (uživatel admin existuje jen na config serveru,
// ne na shardech – proto se připojujeme bez přihlášení přes localhost exception).
// Aktuální PRIMARY zjistíš příkazem níže (spusť před tímto blokem):
//   docker exec shard1svr1 mongosh --eval "rs.status().members.map(m=>({n:m.name,s:m.stateStr}))"
// Pak spusť na PRIMARY (příklad pro shard1svr3):
//    docker exec -it shard1svr3 mongosh

// ── 1. Replikační lag SECONDARY nodů ──────────────────────────────────────────
var status = rs.status();
var primary = status.members.find(function (m) {
  return m.stateStr === "PRIMARY";
});

print("=== Replikační lag SECONDARY nodů ===");
printjson(
  status.members
    .filter(function (m) {
      return m.stateStr === "SECONDARY";
    })
    .map(function (m) {
      var lagMs = primary
        ? primary.optimeDate.getTime() - m.optimeDate.getTime()
        : null;
      return {
        jmeno: m.name,
        lag_ms: lagMs,
        lag_s: lagMs !== null ? Math.round(lagMs / 1000) : "n/a",
        stav: lagMs !== null && lagMs < 1000 ? "OK" : "POZOR",
        pingMs: m.pingMs || 0,
      };
    }),
);

// ── 2. Zdraví všech členů replica setu ───────────────────────────────────────
print("\n=== Zdraví členů replica setu ===");
printjson(
  status.members.map(function (m) {
    return {
      jmeno: m.name,
      stav: m.stateStr,
      zdravi: m.health === 1 ? "OK" : "DOWN",
      cas_optime: m.optimeDate,
      pingMs: m.pingMs || 0,
    };
  }),
);

// ── 3. Přehled replica setu ze status ────────────────────────────────────────
print("\n=== Přehled replica setu ===");
printjson({
  setName: status.set,
  heartbeatIntervalMs: status.heartbeatIntervalMillis,
  cleny: status.members.map(function (m) {
    return {
      host: m.name,
      role: m.stateStr,
      zdravi: m.health === 1 ? "OK" : "DOWN",
      cas_optime: m.optimeDate,
    };
  }),
});
```

**Komentář:** Celý dotaz je jeden blok — stačí zkopírovat a spustit na PRIMARY shardu (připojení bez přihlášení přes localhost exception). `rs.status()` je zavolán jednou a výsledek uložen do `status`, aby se nevolal dvakrát. Sekce 1 počítá `lag_ms` jako rozdíl `optimeDate` PRIMARY a každého SECONDARY — čas posledního replikovaného oplog záznamu. V naší konfiguraci by měl být lag < 1 000 ms (všechny nody na stejném hostiteli). Sekce 2 zobrazí zdraví všech členů. Sekce 3 čerpá data přímo ze `status` objektu (výsledek `rs.status()` načtený v sekci 1) — `status.heartbeatIntervalMillis` vrátí interval heartbeatu (výchozí 2 000 ms, jak často nody posílají heartbeat; při výpadku PRIMARY čeká SECONDARY `electionTimeoutMillis` = 10 000 ms bez heartbeatu, než spustí election nového PRIMARY). `rs.conf()` ani `serverStatus` nejsou použity, protože obě vyžadují `replSetGetConfig`/admin privilegia, která nejsou dostupná přes localhost exception na shard nodu.
