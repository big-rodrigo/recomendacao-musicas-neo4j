// 00_reset.cypher
// Remove todos os dados, projeções GDS e o índice vetorial para permitir recarga idempotente.
// Constraints são mantidas (01_schema.cypher usa IF NOT EXISTS).

// Projeções em memória do GDS (falham silenciosamente se não existirem)
CALL gds.graph.drop('taste', false) YIELD graphName RETURN graphName;
CALL gds.graph.drop('tasteSimilarity', false) YIELD graphName RETURN graphName;
CALL gds.graph.drop('social', false) YIELD graphName RETURN graphName;

DROP INDEX track_features IF EXISTS;

// Exclusão em lotes: um DETACH DELETE único em ~1,2 milhão de relacionamentos
// excede a memória de transação padrão.
MATCH (n)
CALL (n) { DETACH DELETE n } IN TRANSACTIONS OF 5000 ROWS;
