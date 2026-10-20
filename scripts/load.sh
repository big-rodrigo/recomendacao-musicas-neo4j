#!/usr/bin/env bash
# Copia os CSVs para o diretório de import do Neo4j e executa os scripts Cypher em ordem.
#
# Uso (Linux/WSL, como usuário com permissão de escrita no diretório de import):
#   bash scripts/load.sh            # carga completa (reset + schema + catálogo + seed + derivados)
#   bash scripts/load.sh 04         # executa apenas os arquivos cujo nome começa com 04
#
# Variáveis de ambiente:
#   NEO4J_URI (bolt://localhost:7687)  NEO4J_USER (neo4j)  NEO4J_PASSWORD (musicgraph123)
#   NEO4J_IMPORT_DIR (/var/lib/neo4j/import)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URI="${NEO4J_URI:-bolt://localhost:7687}"
USER="${NEO4J_USER:-neo4j}"
PASS="${NEO4J_PASSWORD:-musicgraph123}"
IMPORT_DIR="${NEO4J_IMPORT_DIR:-/var/lib/neo4j/import}"
ONLY="${1:-0}"

mkdir -p "$IMPORT_DIR/music"
cp "$ROOT/data/raw/dataset.csv" "$IMPORT_DIR/music/"
for f in users prefers listens likes follows playlists playlist_tracks; do
  cp "$ROOT/data/seed/$f.csv" "$IMPORT_DIR/music/"
done
# O processo do Neo4j precisa de permissão de leitura nos arquivos copiados
chmod -R a+rX "$IMPORT_DIR/music"

for script in "$ROOT"/cypher/0[0-4]_*.cypher; do
  name="$(basename "$script")"
  [[ "$name" == "$ONLY"* ]] || continue
  echo "==> $name"
  start=$(date +%s)
  cypher-shell -a "$URI" -u "$USER" -p "$PASS" --format plain -f "$script"
  echo "    $(( $(date +%s) - start ))s"
done
