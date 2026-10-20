// 03_load_seed.cypher
// Carga dos dados sintéticos de interação gerados por scripts/generate_seed.py.
// holdout_listens.csv NÃO é carregado: é usado apenas por scripts/evaluate.py.

// ---------------------------------------------------------------------------
// Usuários
// ---------------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///music/users.csv' AS row
CALL (row) {
  MERGE (u:User {id: row.userId})
  SET u.username   = row.username,
      u.country    = row.country,
      u.birthYear  = toInteger(row.birthYear),
      u.signupDate = date(row.signupDate),
      u.status     = row.status
} IN TRANSACTIONS OF 5000 ROWS;

// ---------------------------------------------------------------------------
// Preferências declaradas no onboarding: base para cold start
// ---------------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///music/prefers.csv' AS row
CALL (row) {
  MATCH (u:User {id: row.userId})
  MATCH (g:Genre {name: row.genre})
  MERGE (u)-[:PREFERS]->(g)
} IN TRANSACTIONS OF 5000 ROWS;

// ---------------------------------------------------------------------------
// Histórico de escuta agregado por par usuário-faixa
// ---------------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///music/listens.csv' AS row
CALL (row) {
  MATCH (u:User {id: row.userId})
  MATCH (t:Track {id: row.trackId})
  MERGE (u)-[l:LISTENED]->(t)
  SET l.playCount  = toInteger(row.playCount),
      l.lastPlayed = date(row.lastPlayed)
} IN TRANSACTIONS OF 5000 ROWS;

// ---------------------------------------------------------------------------
// Curtidas (sinal explícito)
// ---------------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///music/likes.csv' AS row
CALL (row) {
  MATCH (u:User {id: row.userId})
  MATCH (t:Track {id: row.trackId})
  MERGE (u)-[l:LIKED]->(t)
  SET l.likedAt = date(row.likedAt)
} IN TRANSACTIONS OF 5000 ROWS;

// ---------------------------------------------------------------------------
// Rede social (direcionada)
// ---------------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///music/follows.csv' AS row
CALL (row) {
  MATCH (a:User {id: row.followerId})
  MATCH (b:User {id: row.followedId})
  MERGE (a)-[f:FOLLOWS]->(b)
  SET f.since = date(row.since)
} IN TRANSACTIONS OF 5000 ROWS;

// ---------------------------------------------------------------------------
// Playlists
// ---------------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///music/playlists.csv' AS row
CALL (row) {
  MATCH (u:User {id: row.ownerId})
  MERGE (p:Playlist {id: row.playlistId})
  SET p.name = row.name, p.createdAt = date(row.createdAt)
  MERGE (u)-[:CREATED]->(p)
} IN TRANSACTIONS OF 5000 ROWS;

LOAD CSV WITH HEADERS FROM 'file:///music/playlist_tracks.csv' AS row
CALL (row) {
  MATCH (p:Playlist {id: row.playlistId})
  MATCH (t:Track {id: row.trackId})
  MERGE (p)-[c:CONTAINS]->(t)
  SET c.position = toInteger(row.position)
} IN TRANSACTIONS OF 5000 ROWS;

// Conferência
CALL () { MATCH (u:User) RETURN count(u) AS users }
CALL () { MATCH ()-[r:LISTENED]->() RETURN count(r) AS listened }
CALL () { MATCH ()-[r:LIKED]->() RETURN count(r) AS liked }
CALL () { MATCH ()-[r:FOLLOWS]->() RETURN count(r) AS follows }
CALL () { MATCH ()-[r:CONTAINS]->() RETURN count(r) AS playlistItems }
RETURN users, listened, liked, follows, playlistItems;
