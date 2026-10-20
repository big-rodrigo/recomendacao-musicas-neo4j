"""Baixa o Spotify Tracks Dataset (Kaggle: maharshipandya/-spotify-tracks-dataset).

O Kaggle exige autenticação (kaggle.json) para download via API. Para tornar a
execução reprodutível sem credenciais, o script usa o espelho público do mesmo
arquivo publicado pelo autor no Hugging Face. Se o espelho falhar e houver
credenciais do Kaggle configuradas, usa o Kaggle CLI como alternativa.

Uso:
    python scripts/download_dataset.py
"""
import hashlib
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / "data" / "raw" / "dataset.csv"
HF_URL = "https://huggingface.co/datasets/maharshipandya/spotify-tracks-dataset/resolve/main/dataset.csv"
KAGGLE_SLUG = "maharshipandya/-spotify-tracks-dataset"
EXPECTED_ROWS = 114_000


def download_hf() -> None:
    print(f"Baixando {HF_URL}")
    with urllib.request.urlopen(HF_URL, timeout=120) as resp, open(DEST, "wb") as out:
        shutil.copyfileobj(resp, out)


def download_kaggle() -> None:
    print(f"Baixando via Kaggle CLI: {KAGGLE_SLUG}")
    subprocess.run(
        ["kaggle", "datasets", "download", "-d", KAGGLE_SLUG, "-p", str(DEST.parent), "--unzip"],
        check=True,
    )


def main() -> None:
    DEST.parent.mkdir(parents=True, exist_ok=True)
    if DEST.exists():
        print(f"{DEST} já existe; nada a fazer.")
    else:
        try:
            download_hf()
        except Exception as exc:  # noqa: BLE001
            print(f"Falha no espelho Hugging Face ({exc}); tentando Kaggle CLI.")
            download_kaggle()

    with open(DEST, encoding="utf-8") as fh:
        rows = sum(1 for _ in fh) - 1
    sha = hashlib.sha256(DEST.read_bytes()).hexdigest()
    print(f"Linhas: {rows} | sha256: {sha}")
    if rows != EXPECTED_ROWS:
        sys.exit(f"Número de linhas inesperado ({rows} != {EXPECTED_ROWS}).")


if __name__ == "__main__":
    main()
