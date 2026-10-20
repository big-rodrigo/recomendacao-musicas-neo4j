"""Avaliação offline das estratégias de recomendação.

Protocolo:
  * generate_seed.py retira 20% das escutas de 300 usuários (holdout_listens.csv);
    essas escutas não são carregadas no grafo;
  * para cada usuário do holdout, cada estratégia gera K recomendações;
  * métricas: HitRate@K (>= 1 acerto), Precision@K, Recall@K, cobertura de catálogo
    (faixas distintas recomendadas / total de faixas) e latência média por consulta.

As consultas reproduzem a lógica de cypher/05_business_queries.cypher (Q2–Q6),
parametrizadas por $userId e $k. O baseline "popularidade" recomenda as faixas
com mais ouvintes na base que o usuário ainda não ouviu.

Uso:
    python scripts/evaluate.py [--k 20]
"""
import argparse
import csv
import os
import statistics
import time
from collections import defaultdict
from pathlib import Path

from neo4j import GraphDatabase

ROOT = Path(__file__).resolve().parent.parent
HOLDOUT = ROOT / "data" / "seed" / "holdout_listens.csv"
REPORT = ROOT / "docs" / "evaluation.md"

NOT_HEARD = """
  NOT (u)-[:LISTENED]->(rec)
  AND NOT EXISTS { (u)-[:LISTENED]->(h:Track) WHERE h.songKey = rec.songKey }
"""

STRATEGIES = {
    "popularidade (baseline)": f"""
        MATCH (u:User {{id: $userId}})
        MATCH (rec:Track)<-[:LISTENED]-()
        WHERE {NOT_HEARD}
        WITH rec, count(*) AS listeners
        ORDER BY listeners DESC LIMIT $k
        RETURN rec.id AS id
    """,
    "popularidade por gênero": f"""
        MATCH (u:User {{id: $userId}})-[l:LISTENED]->(:Track)-[:HAS_GENRE]->(g:Genre)
        WITH u, g, sum(l.playCount) AS plays ORDER BY plays DESC LIMIT 3
        MATCH (g)<-[:HAS_GENRE]-(rec:Track)<-[:LISTENED]-()
        WHERE {NOT_HEARD}
        WITH rec, count(*) AS listeners
        ORDER BY listeners DESC LIMIT $k
        RETURN rec.id AS id
    """,
    "colaborativa (Jaccard na consulta)": f"""
        MATCH (u:User {{id: $userId}})-[:LISTENED]->(t:Track)<-[:LISTENED]-(other:User)
        WITH u, other, count(DISTINCT t) AS shared
        WITH u, other, shared,
             COUNT {{ (u)-[:LISTENED]->() }} AS sizeU,
             COUNT {{ (other)-[:LISTENED]->() }} AS sizeO
        WITH u, other, toFloat(shared) / (sizeU + sizeO - shared) AS jaccard
        ORDER BY jaccard DESC LIMIT 25
        MATCH (other)-[l:LISTENED]->(rec:Track)
        WHERE {NOT_HEARD}
        WITH rec, sum(jaccard * log(1 + l.playCount)) AS score
        ORDER BY score DESC LIMIT $k
        RETURN rec.id AS id
    """,
    "colaborativa (GDS SIMILAR_TASTE)": f"""
        MATCH (u:User {{id: $userId}})-[s:SIMILAR_TASTE]->(:User)-[l:LISTENED]->(rec:Track)
        WHERE {NOT_HEARD}
        WITH rec, sum(s.score * log(1 + l.playCount)) AS score
        ORDER BY score DESC LIMIT $k
        RETURN rec.id AS id
    """,
    "conteúdo (SIMILAR_TO + afinidade)": f"""
        MATCH (u:User {{id: $userId}})-[l:LISTENED]->(fav:Track)
        WITH u, fav ORDER BY l.playCount DESC LIMIT 10
        MATCH (fav)-[s:SIMILAR_TO]->(rec:Track)
        WHERE {NOT_HEARD}
        WITH u, rec, sum(s.score) AS sim
        WITH rec, sim + toFloat(COUNT {{ (u)-[:LISTENED]->(x:Track)
                     WHERE EXISTS {{ (x)-[:HAS_GENRE]->(:Genre)<-[:HAS_GENRE]-(rec) }} }})
                     / COUNT {{ (u)-[:LISTENED]->() }} AS score
        ORDER BY score DESC, rec.popularity DESC LIMIT $k
        RETURN rec.id AS id
    """,
    "social (curtidas de quem segue)": f"""
        MATCH (u:User {{id: $userId}})-[:FOLLOWS]->(f:User)-[:LIKED]->(rec:Track)
        WHERE {NOT_HEARD}
        WITH rec, count(f) AS friends
        ORDER BY friends DESC, rec.popularity DESC LIMIT $k
        RETURN rec.id AS id
    """,
    "híbrida (0.5 colab + 0.3 conteúdo + 0.2 social)": f"""
        MATCH (u:User {{id: $userId}})
        CALL (u) {{
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
        }}
        WITH u, rec, raw, source
        WHERE {NOT_HEARD}
        WITH source, collect({{rec: rec, raw: raw}}) AS items, max(raw) AS maxRaw
        UNWIND items AS item
        WITH item.rec AS rec,
             item.raw / maxRaw * CASE source WHEN 'collaborative' THEN 0.5
                                             WHEN 'content' THEN 0.3 ELSE 0.2 END AS weighted
        WITH rec, sum(weighted) AS score
        ORDER BY score DESC LIMIT $k
        RETURN rec.id AS id
    """,
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--k", type=int, default=20)
    args = parser.parse_args()

    truth = defaultdict(set)
    with open(HOLDOUT, encoding="utf-8", newline="") as fh:
        for row in csv.DictReader(fh):
            truth[row["userId"]].add(row["trackId"])
    users = sorted(truth)

    driver = GraphDatabase.driver(
        os.getenv("NEO4J_URI", "bolt://localhost:7687"),
        auth=(os.getenv("NEO4J_USER", "neo4j"), os.getenv("NEO4J_PASSWORD", "musicgraph123")),
    )
    with driver.session() as session:
        total_tracks = session.run("MATCH (t:Track) RETURN count(t) AS n").single()["n"]
        results = []
        for name, query in STRATEGIES.items():
            hits, precisions, recalls, latencies = [], [], [], []
            recommended = set()
            for uid in users:
                start = time.perf_counter()
                recs = [r["id"] for r in session.run(query, userId=uid, k=args.k)]
                latencies.append((time.perf_counter() - start) * 1000)
                recommended.update(recs)
                n_hit = len(set(recs) & truth[uid])
                hits.append(1 if n_hit else 0)
                precisions.append(n_hit / args.k)
                recalls.append(n_hit / len(truth[uid]))
            results.append((name, statistics.mean(hits), statistics.mean(precisions),
                            statistics.mean(recalls), len(recommended) / total_tracks,
                            statistics.mean(latencies)))
            print(f"{name:50s} HR={results[-1][1]:.3f} P={results[-1][2]:.4f} "
                  f"R={results[-1][3]:.4f} cov={results[-1][4]:.4f} lat={results[-1][5]:.1f}ms")
    driver.close()

    k = args.k
    lines = [
        "# Avaliação offline",
        "",
        f"Usuários avaliados: {len(users)} | itens retidos: {sum(len(v) for v in truth.values())} "
        f"| K = {k}",
        "",
        f"| Estratégia | HitRate@{k} | Precision@{k} | Recall@{k} | Cobertura | Latência média (ms) |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for name, hr, p, r, cov, lat in results:
        lines.append(f"| {name} | {hr:.3f} | {p:.4f} | {r:.4f} | {cov:.4f} | {lat:.1f} |")
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\nRelatório: {REPORT}")


if __name__ == "__main__":
    main()
