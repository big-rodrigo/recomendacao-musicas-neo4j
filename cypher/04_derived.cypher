// 04_derived.cypher
// Relacionamentos e propriedades derivados dos dados carregados.
//
//   (Track)-[:SIMILAR_TO {score}]->(Track)       vizinhos por atributos de áudio (índice vetorial)
//   (Genre)-[:CO_OCCURS_WITH {tracks}]-(Genre)   gêneros que classificam as mesmas faixas
//   (User)-[:SIMILAR_TASTE {score}]->(User)      Jaccard sobre faixas ouvidas (GDS Node Similarity)
//   User.tasteCommunity                           comunidade de gosto (GDS Louvain sobre SIMILAR_TASTE)
//   User.influence                                PageRank na rede FOLLOWS

// ---------------------------------------------------------------------------
// 1. Similaridade de conteúdo
// Índice vetorial HNSW sobre `features` (9 dimensões normalizadas em [0,1]).
// Distância euclidiana: com vetores não negativos a similaridade de cosseno
// fica concentrada perto de 1 e discrimina pouco entre faixas.
// ---------------------------------------------------------------------------
CREATE VECTOR INDEX track_features IF NOT EXISTS
FOR (t:Track) ON t.features
OPTIONS { indexConfig: {
  `vector.dimensions`: 9,
  `vector.similarity_function`: 'euclidean'
}};

CALL db.awaitIndexes(600);

// Para cada faixa, os 10 vizinhos mais próximos, excluindo outras edições da
// mesma música (mesmo songKey), que teriam vetor idêntico e score 1.0.
// Consulta 25 candidatos para compensar o filtro.
MATCH (t:Track)
CALL (t) {
  CALL db.index.vector.queryNodes('track_features', 25, t.features) YIELD node, score
  WITH t, node, score
  WHERE node <> t AND node.songKey <> t.songKey
  ORDER BY score DESC
  LIMIT 10
  MERGE (t)-[s:SIMILAR_TO]->(node)
  SET s.score = score
} IN TRANSACTIONS OF 2000 ROWS;

// ---------------------------------------------------------------------------
// 2. Coocorrência de gêneros (faixas classificadas em mais de um gênero)
// Relacionamento gravado em uma direção (g1.name < g2.name) e consultado sem direção.
// ---------------------------------------------------------------------------
MATCH (g1:Genre)<-[:HAS_GENRE]-(t:Track)-[:HAS_GENRE]->(g2:Genre)
WHERE g1.name < g2.name
WITH g1, g2, count(t) AS tracks
MERGE (g1)-[c:CO_OCCURS_WITH]->(g2)
SET c.tracks = tracks;

// ---------------------------------------------------------------------------
// 3. Similaridade de gosto entre usuários (GDS Node Similarity)
// Projeção bipartida User -> Track. Jaccard = |A ∩ B| / |A ∪ B| sobre as faixas
// ouvidas. topK = 20 vizinhos por usuário; similarityCutoff descarta pares triviais.
// O modo write sempre cria relacionamentos novos: os anteriores são removidos para
// que este script possa ser reexecutado isoladamente sem duplicar SIMILAR_TASTE.
// ---------------------------------------------------------------------------
MATCH ()-[r:SIMILAR_TASTE]->()
CALL (r) { DELETE r } IN TRANSACTIONS OF 10000 ROWS;

MATCH (u:User)-[:LISTENED]->(t:Track)
WITH gds.graph.project('taste', u, t, {
  sourceNodeLabels: labels(u), targetNodeLabels: labels(t), relationshipType: 'LISTENED'
}) AS g
RETURN g.graphName, g.nodeCount, g.relationshipCount;

CALL gds.nodeSimilarity.write('taste', {
  topK: 20,
  similarityCutoff: 0.02,
  writeRelationshipType: 'SIMILAR_TASTE',
  writeProperty: 'score'
}) YIELD nodesCompared, relationshipsWritten
RETURN nodesCompared, relationshipsWritten;

CALL gds.graph.drop('taste') YIELD graphName RETURN graphName;

// ---------------------------------------------------------------------------
// 4. Comunidades de gosto (Louvain sobre SIMILAR_TASTE, ponderado pelo score)
// concurrency = 1: com execução paralela a ordem de visita dos nós varia e o número
// de comunidades oscilou entre execuções (14 e 13) sobre os mesmos dados. Com
// concurrency = 1 a contagem se estabilizou; resta variação na 3ª casa da modularidade,
// atribuída à ordem de criação dos relacionamentos SIMILAR_TASTE na projeção.
// ---------------------------------------------------------------------------
MATCH (a:User)-[s:SIMILAR_TASTE]->(b:User)
WITH gds.graph.project('tasteSimilarity', a, b,
  { relationshipProperties: s { .score } },
  { undirectedRelationshipTypes: ['*'] }) AS g
RETURN g.graphName, g.nodeCount, g.relationshipCount;

CALL gds.louvain.write('tasteSimilarity', {
  relationshipWeightProperty: 'score',
  concurrency: 1,
  writeProperty: 'tasteCommunity'
}) YIELD communityCount, modularity
RETURN communityCount, modularity;

CALL gds.graph.drop('tasteSimilarity') YIELD graphName RETURN graphName;

// ---------------------------------------------------------------------------
// 5. Influência social (PageRank na rede FOLLOWS)
// Inclui usuários sem arestas para que todos recebam a propriedade.
// ---------------------------------------------------------------------------
MATCH (a:User)
OPTIONAL MATCH (a)-[:FOLLOWS]->(b:User)
WITH gds.graph.project('social', a, b) AS g
RETURN g.graphName, g.nodeCount, g.relationshipCount;

CALL gds.pageRank.write('social', {
  maxIterations: 30,
  dampingFactor: 0.85,
  writeProperty: 'influence'
}) YIELD nodePropertiesWritten, ranIterations
RETURN nodePropertiesWritten, ranIterations;

CALL gds.graph.drop('social') YIELD graphName RETURN graphName;
