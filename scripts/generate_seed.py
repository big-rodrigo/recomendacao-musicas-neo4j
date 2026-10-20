"""Gera dados sintéticos de usuários sobre o catálogo do Spotify Tracks Dataset.

O dataset original contém apenas o catálogo (faixas, artistas, álbuns, gêneros e
atributos de áudio). Um sistema de recomendação precisa de sinais de interação,
então este script gera, de forma determinística (seed fixa):

    users.csv            usuários (id, nome de usuário, país, ano de nascimento, data de cadastro)
    prefers.csv          gêneros declarados no onboarding (User)-[:PREFERS]->(Genre)
    listens.csv          histórico agregado (User)-[:LISTENED {playCount, lastPlayed}]->(Track)
    likes.csv            curtidas (User)-[:LIKED {likedAt}]->(Track)
    follows.csv          rede social (User)-[:FOLLOWS {since}]->(User)
    playlists.csv        playlists criadas (User)-[:CREATED]->(Playlist)
    playlist_tracks.csv  conteúdo das playlists (Playlist)-[:CONTAINS {position}]->(Track)
    holdout_listens.csv  escutas retidas (não carregadas) para avaliação offline

Premissas do modelo gerador (para que os sinais sejam coerentes, e não ruído):
  * cada usuário tem um gênero-âncora e 1–3 gêneros vizinhos, escolhidos pela
    proximidade dos centróides de atributos de áudio entre gêneros;
  * o país influencia a escolha do gênero-âncora (ex.: BR -> mpb, sertanejo...);
  * dentro de um gênero, a escolha da faixa é ponderada pela popularidade;
  * a probabilidade de curtir cresce com o número de reproduções;
  * a rede social apresenta homofilia: 70% dos follows ligam usuários com
    gêneros em comum.

Uso:
    python scripts/generate_seed.py
"""
import csv
import math
import random
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw" / "dataset.csv"
OUT = ROOT / "data" / "seed"
SAMPLE = ROOT / "data" / "sample"

SEED = 42
N_ACTIVE_USERS = 2000
N_COLD_USERS = 60
POOL_PER_GENRE = 150          # faixas mais populares de cada gênero elegíveis para escuta
N_NEIGHBOR_GENRES = 6         # vizinhos considerados ao montar o perfil de gosto
N_HOLDOUT_USERS = 300
HOLDOUT_FRACTION = 0.2
SAMPLE_ROWS = 300

FEATURES = ["danceability", "energy", "valence", "acousticness",
            "instrumentalness", "speechiness", "liveness"]

COUNTRY_WEIGHTS = {"BR": 40, "US": 18, "MX": 8, "AR": 5, "PT": 5, "ES": 5,
                   "GB": 6, "DE": 4, "JP": 5, "KR": 4}
COUNTRY_GENRES = {
    "BR": ["brazil", "mpb", "sertanejo", "forro", "pagode", "samba", "funk"],
    "PT": ["brazil", "mpb", "pop"],
    "MX": ["latin", "latino", "reggaeton", "salsa", "spanish"],
    "AR": ["tango", "latin", "latino", "spanish"],
    "ES": ["spanish", "latin", "reggaeton"],
    "JP": ["j-pop", "j-rock", "anime", "j-idol", "j-dance"],
    "KR": ["k-pop"],
    "GB": ["british", "indie", "alt-rock"],
    "DE": ["german", "techno", "minimal-techno"],
    "US": ["pop", "hip-hop", "country", "r-n-b", "rock"],
}

START = date(2025, 1, 1)
END = date(2026, 10, 15)


def rand_date(rng: random.Random, start: date = START, end: date = END) -> str:
    return (start + timedelta(days=rng.randint(0, (end - start).days))).isoformat()


def feature_vector(row: dict) -> list[float]:
    """Mesmo vetor normalizado (0..1) usado no Cypher (02_load_catalog.cypher)."""
    vec = [float(row[f]) for f in FEATURES]
    vec.append(min(float(row["tempo"]) / 250.0, 1.0))
    vec.append(min(max((float(row["loudness"]) + 60.0) / 60.0, 0.0), 1.0))
    return vec


def load_catalog():
    tracks = {}
    with open(RAW, encoding="utf-8", newline="") as fh:
        for row in csv.DictReader(fh):
            if not row["artists"] or not row["track_name"]:
                continue  # 1 linha sem artista/nome no dataset original
            tid = row["track_id"]
            pop = int(row["popularity"])
            t = tracks.get(tid)
            if t is None:
                tracks[tid] = {"pop": pop, "genres": {row["track_genre"]},
                               "vec": feature_vector(row)}
            else:
                t["genres"].add(row["track_genre"])
                t["pop"] = max(t["pop"], pop)  # mesma faixa pode ter popularidade diferente entre linhas
    return tracks


def genre_structures(tracks):
    by_genre = defaultdict(list)
    for tid, t in tracks.items():
        for g in t["genres"]:
            by_genre[g].append(tid)

    centroids, mean_pop = {}, {}
    for g, tids in by_genre.items():
        dim = len(tracks[tids[0]]["vec"])
        centroids[g] = [sum(tracks[t]["vec"][i] for t in tids) / len(tids) for i in range(dim)]
        mean_pop[g] = sum(tracks[t]["pop"] for t in tids) / len(tids)

    neighbors = {}
    for g, c in centroids.items():
        dist = sorted((math.dist(c, c2), g2) for g2, c2 in centroids.items() if g2 != g)
        neighbors[g] = [g2 for _, g2 in dist[:N_NEIGHBOR_GENRES]]

    pools = {}
    for g, tids in by_genre.items():
        ranked = sorted((t for t in tids if tracks[t]["pop"] > 0),
                        key=lambda t: tracks[t]["pop"], reverse=True)[:POOL_PER_GENRE]
        pools[g] = (ranked, [(tracks[t]["pop"] + 1) ** 1.5 for t in ranked])
    return pools, neighbors, mean_pop


def weighted_sample_without_replacement(rng, items, weights, k):
    # Efraimidis-Spirakis: chave = u^(1/w)
    keyed = sorted(((rng.random() ** (1.0 / w), it) for it, w in zip(items, weights)), reverse=True)
    return [it for _, it in keyed[:k]]


def main() -> None:
    rng = random.Random(SEED)
    tracks = load_catalog()
    pools, neighbors, mean_pop = genre_structures(tracks)
    genres = sorted(pools)
    countries, cweights = zip(*COUNTRY_WEIGHTS.items())

    users, prefers, listens, likes, follows = [], [], [], [], []
    playlists, playlist_tracks, holdout = [], [], []
    taste = {}

    # ---- usuários ativos -------------------------------------------------
    for i in range(1, N_ACTIVE_USERS + 1):
        uid = f"u{i:05d}"
        country = rng.choices(countries, cweights)[0]
        local = [g for g in COUNTRY_GENRES.get(country, []) if g in pools]
        if local and rng.random() < 0.5:
            anchor = rng.choice(local)
        else:
            anchor = rng.choices(genres, [mean_pop[g] for g in genres])[0]
        extra = rng.sample(neighbors[anchor], rng.randint(1, 3))
        user_genres = [anchor] + extra
        gweights = [0.55] + [0.45 / len(extra)] * len(extra)
        taste[uid] = set(user_genres)

        users.append([uid, f"user_{i:05d}", country, rng.randint(1960, 2010),
                      rand_date(rng, date(2020, 1, 1), date(2024, 12, 31)), "active"])
        prefers.append([uid, anchor])
        if rng.random() < 0.5:
            prefers.append([uid, extra[0]])

        n_tracks = max(15, min(200, int(rng.lognormvariate(3.6, 0.5))))
        per_genre = defaultdict(int)
        for _ in range(n_tracks):
            g = rng.choice(genres) if rng.random() < 0.05 else rng.choices(user_genres, gweights)[0]
            per_genre[g] += 1

        chosen = {}
        for g, k in per_genre.items():
            pool, w = pools[g]
            for tid in weighted_sample_without_replacement(rng, pool, w, k):
                if tid in chosen:
                    continue
                boost = 2.0 if g == anchor else 1.0
                chosen[tid] = max(1, min(300, int(1 + rng.expovariate(1 / (5 * boost)))))
        for tid, pc in chosen.items():
            listens.append([uid, tid, pc, rand_date(rng)])

    # ---- holdout para avaliação offline -----------------------------------
    by_user = defaultdict(list)
    for row in listens:
        by_user[row[0]].append(row)
    eligible = [u for u, rows in by_user.items() if len(rows) >= 20]
    held_users = set(rng.sample(eligible, N_HOLDOUT_USERS))
    kept = []
    for u, rows in by_user.items():
        if u in held_users:
            rows = rows[:]
            rng.shuffle(rows)
            cut = int(len(rows) * HOLDOUT_FRACTION)
            holdout.extend(rows[:cut])
            kept.extend(rows[cut:])
        else:
            kept.extend(rows)
    listens = sorted(kept, key=lambda r: (r[0], r[1]))
    holdout.sort(key=lambda r: (r[0], r[1]))

    # ---- curtidas (derivadas das escutas mantidas) ------------------------
    for uid, tid, pc, last in listens:
        if rng.random() < min(0.85, 0.05 + pc / 25):
            likes.append([uid, tid, last])

    # ---- usuários sem histórico (cold start) ------------------------------
    for j in range(1, N_COLD_USERS + 1):
        i = N_ACTIVE_USERS + j
        uid = f"u{i:05d}"
        country = rng.choices(countries, cweights)[0]
        users.append([uid, f"user_{i:05d}", country, rng.randint(1960, 2010),
                      rand_date(rng, date(2026, 10, 1), date(2026, 10, 15)), "new"])
        gs = rng.sample(genres, rng.randint(1, 3))
        taste[uid] = set(gs)
        for g in gs:
            prefers.append([uid, g])

    # ---- rede social com homofilia ----------------------------------------
    active_ids = [u[0] for u in users if u[5] == "active"]
    by_genre_users = defaultdict(list)
    for u in active_ids:
        for g in taste[u]:
            by_genre_users[g].append(u)
    for u in [x[0] for x in users]:
        k = rng.randint(2, 15) if u in taste and u in by_user else rng.randint(0, 3)
        targets = set()
        for _ in range(k * 3):
            if len(targets) >= k:
                break
            if rng.random() < 0.7:
                g = rng.choice(sorted(taste[u]))
                cand = rng.choice(by_genre_users[g]) if by_genre_users[g] else rng.choice(active_ids)
            else:
                cand = rng.choice(active_ids)
            if cand != u:
                targets.add(cand)
        for v in sorted(targets):
            follows.append([u, v, rand_date(rng)])

    # ---- playlists --------------------------------------------------------
    kept_by_user = defaultdict(list)
    for uid, tid, pc, _ in listens:
        kept_by_user[uid].append(tid)
    pid = 0
    for u in active_ids:
        if rng.random() >= 0.35:
            continue
        for _ in range(rng.randint(1, 3)):
            pid += 1
            g = rng.choice(sorted(taste[u]))
            size = rng.randint(8, 30)
            own = [t for t in kept_by_user[u] if g in tracks[t]["genres"]]
            picked = rng.sample(own, min(len(own), int(size * 0.7)))
            pool, w = pools[g]
            for t in weighted_sample_without_replacement(rng, pool, w, size):
                if len(picked) >= size:
                    break
                if t not in picked:
                    picked.append(t)
            plid = f"p{pid:05d}"
            playlists.append([plid, u, f"{g} mix #{pid}", rand_date(rng)])
            for pos, t in enumerate(picked, start=1):
                playlist_tracks.append([plid, t, pos])

    # ---- escrita ----------------------------------------------------------
    OUT.mkdir(parents=True, exist_ok=True)
    SAMPLE.mkdir(parents=True, exist_ok=True)
    files = {
        "users.csv": (["userId", "username", "country", "birthYear", "signupDate", "status"], users),
        "prefers.csv": (["userId", "genre"], prefers),
        "listens.csv": (["userId", "trackId", "playCount", "lastPlayed"], listens),
        "likes.csv": (["userId", "trackId", "likedAt"], likes),
        "follows.csv": (["followerId", "followedId", "since"], follows),
        "playlists.csv": (["playlistId", "ownerId", "name", "createdAt"], playlists),
        "playlist_tracks.csv": (["playlistId", "trackId", "position"], playlist_tracks),
        "holdout_listens.csv": (["userId", "trackId", "playCount", "lastPlayed"], holdout),
    }
    for name, (header, rows) in files.items():
        for target, data in ((OUT / name, rows), (SAMPLE / name, rows[:SAMPLE_ROWS])):
            with open(target, "w", encoding="utf-8", newline="") as fh:
                w = csv.writer(fh)
                w.writerow(header)
                w.writerows(data)
        print(f"{name:22s} {len(rows):>8d} linhas")

    # amostra sistemática do dataset original (1 a cada 380 linhas -> cobre todos os
    # gêneros, pois o arquivo é ordenado por gênero com 1000 linhas cada)
    with open(RAW, encoding="utf-8", newline="") as src, \
            open(SAMPLE / "spotify_tracks_sample.csv", "w", encoding="utf-8", newline="") as dst:
        reader, writer = csv.reader(src), csv.writer(dst)
        writer.writerow(next(reader))
        for n, row in enumerate(reader):
            if n % 380 == 0:
                writer.writerow(row)


if __name__ == "__main__":
    main()
