// 01_schema.cypher
// Constraints de unicidade (criam índices de suporte implicitamente) e índices auxiliares.
// Devem existir ANTES da carga: sem eles cada MERGE faz um label scan completo e a
// carga do catálogo passa de segundos para dezenas de minutos.

CREATE CONSTRAINT track_id    IF NOT EXISTS FOR (t:Track)    REQUIRE t.id   IS UNIQUE;
CREATE CONSTRAINT artist_name IF NOT EXISTS FOR (a:Artist)   REQUIRE a.name IS UNIQUE;
CREATE CONSTRAINT album_id    IF NOT EXISTS FOR (a:Album)    REQUIRE a.id   IS UNIQUE;
CREATE CONSTRAINT genre_name  IF NOT EXISTS FOR (g:Genre)    REQUIRE g.name IS UNIQUE;
CREATE CONSTRAINT user_id     IF NOT EXISTS FOR (u:User)     REQUIRE u.id   IS UNIQUE;
CREATE CONSTRAINT playlist_id IF NOT EXISTS FOR (p:Playlist) REQUIRE p.id   IS UNIQUE;

// songKey identifica a "mesma música" publicada sob IDs diferentes (single, álbum, coletânea).
CREATE INDEX track_song_key   IF NOT EXISTS FOR (t:Track) ON (t.songKey);
CREATE INDEX track_popularity IF NOT EXISTS FOR (t:Track) ON (t.popularity);

CALL db.awaitIndexes(300);
