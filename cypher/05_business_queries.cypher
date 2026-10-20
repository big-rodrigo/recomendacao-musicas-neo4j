// 05_business_queries.cypher
// Perguntas de negócio respondidas pelo grafo. Cada bloco é independente.
// Parâmetros de demonstração (cypher-shell e Neo4j Browser aceitam a sintaxe abaixo):

:param userId => 'u00029';
:param coldUserId => 'u02002';
:param trackId => '2SZWtoroRuSM60jzsXqVc9';

// ===========================================================================
// Q1. Qual é o perfil de escuta do usuário? (gêneros por volume de reprodução)
// ===========================================================================
MATCH (u:User {id: $userId})-[l:LISTENED]->(:Track)-[:HAS_GENRE]->(g:Genre)
RETURN g.name AS genre, count(*) AS tracks, sum(l.playCount) AS plays
ORDER BY plays DESC
LIMIT 10;

// ===========================================================================
// Q2. Filtragem colaborativa calculada na consulta.
// "Quais faixas, ainda não ouvidas por X, são ouvidas por usuários com histórico parecido?"
// Similaridade de Jaccard entre conjuntos de faixas; os 25 vizinhos mais próximos votam
// nas faixas candidatas com peso jaccard * log(1 + playCount).
// Exclui faixas já ouvidas e outras edições da mesma música (songKey).
// ===========================================================================
MATCH (u:User {id: $userId})-[:LISTENED]->(t:Track)<-[:LISTENED]-(other:User)
WITH u, other, count(DISTINCT t) AS shared
WITH u, other, shared,
     COUNT { (u)-[:LISTENED]->() }     AS sizeU,
     COUNT { (other)-[:LISTENED]->() } AS sizeO
WITH u, other, toFloat(shared) / (sizeU + sizeO - shared) AS jaccard
ORDER BY jaccard DESC
LIMIT 25
MATCH (other)-[l:LISTENED]->(rec:Track)
WHERE NOT (u)-[:LISTENED]->(rec)
  AND NOT EXISTS { (u)-[:LISTENED]->(h:Track) WHERE h.songKey = rec.songKey }
WITH rec, sum(jaccard * log(1 + l.playCount)) AS score, count(other) AS neighbors
ORDER BY score DESC
LIMIT 10
MATCH (rec)-[:PERFORMED_BY {position: 1}]->(a:Artist)
RETURN rec.name AS track, a.name AS artist, round(score, 3) AS score, neighbors;

// ===========================================================================
// Q3. Filtragem colaborativa com similaridade pré-computada (GDS -> SIMILAR_TASTE).
// Mesmo raciocínio de Q2, mas a vizinhança é lida de um relacionamento materializado,
// o que reduz o custo da consulta online.
// ===========================================================================
MATCH (u:User {id: $userId})-[s:SIMILAR_TASTE]->(other:User)-[l:LISTENED]->(rec:Track)
WHERE NOT (u)-[:LISTENED]->(rec)
  AND NOT EXISTS { (u)-[:LISTENED]->(h:Track) WHERE h.songKey = rec.songKey }
WITH rec, sum(s.score * log(1 + l.playCount)) AS score, count(other) AS neighbors
ORDER BY score DESC
LIMIT 10
MATCH (rec)-[:PERFORMED_BY {position: 1}]->(a:Artist)
RETURN rec.name AS track, a.name AS artist, round(score, 3) AS score, neighbors;

// ===========================================================================
// Q4. Recomendação baseada em conteúdo.
// "Quais faixas têm perfil sonoro parecido com as 10 faixas mais tocadas por X?"
// sim      = soma das similaridades SIMILAR_TO a partir das faixas favoritas;
// affinity = fração das faixas ouvidas por X que compartilham gênero com a candidata.
// O termo de afinidade reduz saltos de gênero causados por atributos de áudio
// parecidos entre estilos distintos (ex.: pagode ao vivo vs. trilha de Bollywood).
// ===========================================================================
MATCH (u:User {id: $userId})-[l:LISTENED]->(fav:Track)
WITH u, fav ORDER BY l.playCount DESC LIMIT 10
MATCH (fav)-[s:SIMILAR_TO]->(rec:Track)
WHERE NOT (u)-[:LISTENED]->(rec)
  AND NOT EXISTS { (u)-[:LISTENED]->(h:Track) WHERE h.songKey = rec.songKey }
WITH u, rec, sum(s.score) AS sim, collect(fav.name)[..2] AS because
WITH rec, sim, because,
     toFloat(COUNT { (u)-[:LISTENED]->(x:Track)
                     WHERE EXISTS { (x)-[:HAS_GENRE]->(:Genre)<-[:HAS_GENRE]-(rec) } })
     / COUNT { (u)-[:LISTENED]->() } AS affinity
WITH rec, because, sim, affinity, sim + affinity AS score
ORDER BY score DESC, rec.popularity DESC
LIMIT 10
MATCH (rec)-[:PERFORMED_BY {position: 1}]->(a:Artist)
RETURN rec.name AS track, a.name AS artist, round(sim, 3) AS sim,
       round(affinity, 3) AS affinity, round(score, 3) AS score, because;

// ===========================================================================
// Q5. Recomendação social.
// "O que as pessoas que X segue curtiram e X ainda não ouviu?"
// ===========================================================================
MATCH (u:User {id: $userId})-[:FOLLOWS]->(f:User)-[:LIKED]->(rec:Track)
WHERE NOT (u)-[:LISTENED]->(rec)
WITH rec, count(f) AS friends, collect(f.username)[..3] AS likedBy
ORDER BY friends DESC, rec.popularity DESC
LIMIT 10
MATCH (rec)-[:PERFORMED_BY {position: 1}]->(a:Artist)
RETURN rec.name AS track, a.name AS artist, friends, likedBy;

// ===========================================================================
// Q6. Recomendação híbrida com explicação.
// Combina os três sinais. Cada sinal é normalizado pelo seu máximo (0..1) e
// ponderado: colaborativo 0.5, conteúdo 0.3, social 0.2.
// `sources` indica quais sinais sustentam cada recomendação.
// ===========================================================================
MATCH (u:User {id: $userId})
CALL (u) {
  MATCH (u)-[s:SIMILAR_TASTE]->(:User)-[l:LISTENED]->(rec:Track)
  RETURN rec, sum(s.score * log(1 + l.playCount)) AS raw, 'collaborative' AS source
  UNION ALL
  MATCH (u)-[l:LISTENED]->(fav:Track)
  WITH u, fav ORDER BY l.playCount DESC LIMIT 10
  MATCH (fav)-[s:SIMILAR_TO]->(rec:Track)
  RETURN rec, sum(s.score) AS raw, 'content' AS source
  UNION ALL
  MATCH (u)-[:FOLLOWS]->(:User)-[:LIKED]->(rec:Track)
  RETURN rec, toFloat(count(*)) AS raw, 'social' AS source
}
WITH u, rec, raw, source
WHERE NOT (u)-[:LISTENED]->(rec)
  AND NOT EXISTS { (u)-[:LISTENED]->(h:Track) WHERE h.songKey = rec.songKey }
WITH source, collect({rec: rec, raw: raw}) AS items, max(raw) AS maxRaw
UNWIND items AS item
WITH item.rec AS rec, source,
     item.raw / maxRaw * CASE source WHEN 'collaborative' THEN 0.5
                                     WHEN 'content'       THEN 0.3
                                     ELSE 0.2 END AS weighted
WITH rec, sum(weighted) AS score, collect(source) AS sources
ORDER BY score DESC
LIMIT 10
MATCH (rec)-[:PERFORMED_BY {position: 1}]->(a:Artist)
RETURN rec.name AS track, a.name AS artist, round(score, 3) AS score, sources;

// ===========================================================================
// Q7. Cold start.
// "O que recomendar para um usuário recém-cadastrado, sem histórico?"
// Usa os gêneros declarados no onboarding (PREFERS) e prova social da base
// (número de curtidas), com popularidade do catálogo como desempate.
// 4 faixas por gênero declarado.
// ===========================================================================
MATCH (u:User {id: $coldUserId})-[:PREFERS]->(g:Genre)<-[:HAS_GENRE]-(t:Track)
WITH g, t, COUNT { (t)<-[:LIKED]-() } AS likes
ORDER BY likes DESC, t.popularity DESC
WITH g, collect({track: t, likes: likes})[..4] AS top
UNWIND top AS item
WITH g, item.track AS t, item.likes AS likes
MATCH (t)-[:PERFORMED_BY {position: 1}]->(a:Artist)
RETURN g.name AS genre, t.name AS track, a.name AS artist,
       likes, t.popularity AS popularity;

// ===========================================================================
// Q8. "Quem ouviu esta faixa também ouviu..." (item-item por coescuta)
// Similaridade de cosseno entre conjuntos de ouvintes.
// ===========================================================================
MATCH (t:Track {id: $trackId})<-[:LISTENED]-(u:User)-[:LISTENED]->(other:Track)
WHERE other.songKey <> t.songKey
WITH t, other, count(u) AS coListeners
WITH other, coListeners,
     toFloat(coListeners) / sqrt(COUNT { (t)<-[:LISTENED]-() } * COUNT { (other)<-[:LISTENED]-() }) AS cosine
ORDER BY cosine DESC, coListeners DESC
LIMIT 10
MATCH (other)-[:PERFORMED_BY {position: 1}]->(a:Artist)
RETURN other.name AS track, a.name AS artist, coListeners, round(cosine, 3) AS cosine;

// ===========================================================================
// Q9. Quais gêneros se sobrepõem no catálogo? (CO_OCCURS_WITH)
// Pares com sobreposição alta indicam taxonomias redundantes.
// ===========================================================================
MATCH (g1:Genre)-[c:CO_OCCURS_WITH]->(g2:Genre)
RETURN g1.name AS genreA, g2.name AS genreB, c.tracks AS sharedTracks
ORDER BY sharedTracks DESC
LIMIT 15;

// ===========================================================================
// Q10. Quais artistas transitam entre mais gêneros? (artistas "ponte")
// ===========================================================================
MATCH (a:Artist)<-[:PERFORMED_BY]-(:Track)-[:HAS_GENRE]->(g:Genre)
WITH a, collect(DISTINCT g.name) AS genres
RETURN a.name AS artist, size(genres) AS genreCount, genres[..6] AS sample
ORDER BY genreCount DESC
LIMIT 10;

// ===========================================================================
// Q11. Quais segmentos de ouvintes existem? (comunidades Louvain sobre SIMILAR_TASTE)
// ===========================================================================
MATCH (u:User)
WHERE u.tasteCommunity IS NOT NULL
WITH u.tasteCommunity AS community, count(u) AS members
MATCH (m:User {tasteCommunity: community})-[l:LISTENED]->(:Track)-[:HAS_GENRE]->(g:Genre)
WITH community, members, g.name AS genre, sum(l.playCount) AS plays
ORDER BY plays DESC
WITH community, members, collect(genre)[..4] AS topGenres
RETURN community, members, topGenres
ORDER BY members DESC;

// ===========================================================================
// Q12. Quem são os usuários mais influentes e o que eles curtem?
// (PageRank em FOLLOWS: candidatos para campanhas de divulgação/seeding)
// ===========================================================================
MATCH (u:User)
WITH u ORDER BY u.influence DESC LIMIT 10
OPTIONAL MATCH (u)-[:LIKED]->(:Track)-[:HAS_GENRE]->(g:Genre)
WITH u, g.name AS genre, count(*) AS n ORDER BY n DESC
WITH u, collect(genre)[..3] AS likedGenres
RETURN u.username AS user, u.country AS country, round(u.influence, 3) AS pageRank,
       COUNT { (u)<-[:FOLLOWS]-() } AS followers, likedGenres
ORDER BY pageRank DESC;
