// 02_load_catalog.cypher
// Carga do catálogo a partir do CSV original do Kaggle (data/raw/dataset.csv),
// copiado para <import>/music/dataset.csv por scripts/load.sh.
//
// Características do arquivo tratadas aqui:
//   * 114.000 linhas, mas 89.741 track_id distintos: a mesma faixa aparece em até
//     9 gêneros (uma linha por par faixa-gênero)  -> MERGE em Track + HAS_GENRE por linha;
//   * em 720 faixas duplicadas a popularidade diverge entre linhas -> mantém o máximo;
//   * 1 linha (índice 65900) sem artista, álbum e nome            -> descartada;
//   * coluna `artists` com múltiplos artistas separados por ';'   -> split + posição;
//   * nomes de álbum não são únicos (46.590 nomes, 57.658 pares nome+artista principal)
//                                                                 -> chave composta;
//   * primeira coluna sem nome (índice do pandas)                  -> ignorada.
//
// A carga é feita em passes separados. Combinar MERGE de nós de labels diferentes e
// relacionamentos na mesma consulta com LOAD CSV introduz o operador Eager no plano,
// que materializa o arquivo inteiro em memória e anula o efeito do IN TRANSACTIONS.

// ---------------------------------------------------------------------------
// Passe 1: gêneros (114 valores distintos)
// ---------------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///music/dataset.csv' AS row
WITH DISTINCT row.track_genre AS genre
WHERE genre IS NOT NULL
MERGE (:Genre {name: genre});

// ---------------------------------------------------------------------------
// Passe 2: faixas com atributos de áudio tipados
// LOAD CSV entrega todos os campos como string; a conversão é explícita.
// `features` é o vetor normalizado em [0,1] usado pelo índice vetorial (04_derived).
// ---------------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///music/dataset.csv' AS row
WITH row
WHERE row.track_id IS NOT NULL AND coalesce(row.artists, '') <> '' AND coalesce(row.track_name, '') <> ''
CALL (row) {
  MERGE (t:Track {id: row.track_id})
  ON CREATE SET
    t.name             = row.track_name,
    t.popularity       = toInteger(row.popularity),
    t.durationMs       = toInteger(row.duration_ms),
    t.explicit         = toBoolean(row.explicit),
    t.danceability     = toFloat(row.danceability),
    t.energy           = toFloat(row.energy),
    t.key              = toInteger(row.key),
    t.loudness         = toFloat(row.loudness),
    t.mode             = toInteger(row.mode),
    t.speechiness      = toFloat(row.speechiness),
    t.acousticness     = toFloat(row.acousticness),
    t.instrumentalness = toFloat(row.instrumentalness),
    t.liveness         = toFloat(row.liveness),
    t.valence          = toFloat(row.valence),
    t.tempo            = toFloat(row.tempo),
    t.timeSignature    = toInteger(row.time_signature),
    t.songKey          = toLower(trim(row.track_name)) + '|' + toLower(trim(split(row.artists, ';')[0])),
    t.features         = [
      toFloat(row.danceability), toFloat(row.energy), toFloat(row.valence),
      toFloat(row.acousticness), toFloat(row.instrumentalness), toFloat(row.speechiness),
      toFloat(row.liveness),
      CASE WHEN toFloat(row.tempo) / 250.0 > 1.0 THEN 1.0 ELSE toFloat(row.tempo) / 250.0 END,
      CASE WHEN (toFloat(row.loudness) + 60.0) / 60.0 < 0.0 THEN 0.0
           WHEN (toFloat(row.loudness) + 60.0) / 60.0 > 1.0 THEN 1.0
           ELSE (toFloat(row.loudness) + 60.0) / 60.0 END
    ]
  ON MATCH SET
    t.popularity = CASE WHEN toInteger(row.popularity) > t.popularity
                        THEN toInteger(row.popularity) ELSE t.popularity END
} IN TRANSACTIONS OF 5000 ROWS;

// ---------------------------------------------------------------------------
// Passe 3: (Track)-[:HAS_GENRE]->(Genre)
// ---------------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///music/dataset.csv' AS row
WITH row WHERE row.track_id IS NOT NULL AND coalesce(row.artists, '') <> ''
CALL (row) {
  MATCH (t:Track {id: row.track_id})
  MATCH (g:Genre {name: row.track_genre})
  MERGE (t)-[:HAS_GENRE]->(g)
} IN TRANSACTIONS OF 5000 ROWS;

// ---------------------------------------------------------------------------
// Passe 4: artistas (29.859 nomes distintos após o split)
// ---------------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///music/dataset.csv' AS row
WITH row WHERE coalesce(row.artists, '') <> ''
UNWIND split(row.artists, ';') AS rawName
WITH DISTINCT trim(rawName) AS name
WHERE name <> ''
CALL (name) {
  MERGE (:Artist {name: name})
} IN TRANSACTIONS OF 5000 ROWS;

// ---------------------------------------------------------------------------
// Passe 5: (Track)-[:PERFORMED_BY {position}]->(Artist)
// position = 1 indica o artista principal.
// ---------------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///music/dataset.csv' AS row
WITH row WHERE row.track_id IS NOT NULL AND coalesce(row.artists, '') <> ''
CALL (row) {
  MATCH (t:Track {id: row.track_id})
  WITH t, [n IN split(row.artists, ';') | trim(n)] AS names
  UNWIND range(0, size(names) - 1) AS i
  WITH t, names[i] AS name, i
  WHERE name <> ''
  MATCH (a:Artist {name: name})
  MERGE (t)-[r:PERFORMED_BY]->(a)
  ON CREATE SET r.position = i + 1
} IN TRANSACTIONS OF 5000 ROWS;

// ---------------------------------------------------------------------------
// Passe 6: álbuns. Chave = nome do álbum + artista principal (normalizados).
// (Track)-[:IN_ALBUM]->(Album)-[:RELEASED_BY]->(Artist)
// ---------------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///music/dataset.csv' AS row
WITH row
WHERE row.track_id IS NOT NULL AND coalesce(row.album_name, '') <> '' AND coalesce(row.artists, '') <> ''
CALL (row) {
  WITH row, trim(split(row.artists, ';')[0]) AS mainArtist
  MATCH (t:Track {id: row.track_id})
  WHERE NOT (t)-[:IN_ALBUM]->()
  MERGE (al:Album {id: toLower(trim(row.album_name)) + '|' + toLower(mainArtist)})
  ON CREATE SET al.name = row.album_name
  MERGE (t)-[:IN_ALBUM]->(al)
  WITH al, mainArtist
  MATCH (a:Artist {name: mainArtist})
  MERGE (al)-[:RELEASED_BY]->(a)
} IN TRANSACTIONS OF 5000 ROWS;

// Conferência
MATCH (t:Track) WITH count(t) AS tracks
MATCH (a:Artist) WITH tracks, count(a) AS artists
MATCH (al:Album) WITH tracks, artists, count(al) AS albums
MATCH (g:Genre)
RETURN tracks, artists, albums, count(g) AS genres;
