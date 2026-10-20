# Avaliação offline

Usuários avaliados: 300 | itens retidos: 2552 | K = 20

| Estratégia | HitRate@20 | Precision@20 | Recall@20 | Cobertura | Latência média (ms) |
|---|---:|---:|---:|---:|---:|
| popularidade (baseline) | 0.103 | 0.0057 | 0.0138 | 0.0003 | 1117.2 |
| popularidade por gênero | 0.410 | 0.0297 | 0.0676 | 0.0097 | 61.5 |
| colaborativa (Jaccard na consulta) | 0.457 | 0.0308 | 0.0708 | 0.0321 | 25.1 |
| colaborativa (GDS SIMILAR_TASTE) | 0.460 | 0.0313 | 0.0738 | 0.0332 | 19.7 |
| conteúdo (SIMILAR_TO + afinidade) | 0.037 | 0.0018 | 0.0050 | 0.0510 | 31.8 |
| social (curtidas de quem segue) | 0.183 | 0.0112 | 0.0273 | 0.0280 | 4.9 |
| híbrida (0.5 colab + 0.3 conteúdo + 0.2 social) | 0.417 | 0.0292 | 0.0649 | 0.0372 | 19.5 |
