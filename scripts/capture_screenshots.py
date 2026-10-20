"""Gera as evidências visuais (docs/img) executando consultas no Neo4j Browser.

Automatiza o Neo4j Browser servido pelo próprio servidor (http://localhost:7474/browser/)
com Playwright/Chromium headless: conecta, executa cada consulta e captura o frame
de resultado (visualização de grafo ou tabela).

As consultas tabulares são lidas de cypher/05_business_queries.cypher; os
parâmetros declarados com `:param` são substituídos por literais antes da execução.

Uso:
    python -m pip install playwright && python -m playwright install chromium
    python scripts/capture_screenshots.py [--only nome]
"""
import argparse
import os
import re
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
IMG = ROOT / "docs" / "img"
QUERIES = ROOT / "cypher" / "05_business_queries.cypher"
URL = os.getenv("NEO4J_BROWSER_URL", "http://localhost:7474/browser/")
PASSWORD = os.getenv("NEO4J_PASSWORD", "musicgraph123")

# Visualizações de grafo: (arquivo, consulta)
GRAPHS = [
    ("schema", "CALL db.schema.visualization()"),
    ("g1_perfil_usuario", """
MATCH (u:User {id: 'u00029'})-[l:LISTENED]->(t:Track)
WITH u, l, t ORDER BY l.playCount DESC LIMIT 15
MATCH (t)-[h:HAS_GENRE]->(g:Genre)
RETURN u, l, t, h, g"""),
    ("g2_colaborativa_explicacao", """
MATCH (u:User {id: 'u00029'})-[s:SIMILAR_TASTE]->(o:User)-[l:LISTENED]->(rec:Track {name: 'Ainda Existe Amor Em Nós'})
WITH u, s, o, l, rec ORDER BY s.score DESC LIMIT 4
MATCH (u)-[l1:LISTENED]->(shared:Track)<-[l2:LISTENED]-(o)
RETURN u, s, o, l, rec, l1, shared, l2"""),
    ("g3_conteudo_similar_to", """
MATCH (fav:Track {name: 'Reprise - Ao Vivo'})-[s:SIMILAR_TO]->(rec:Track)
MATCH (rec)-[h:HAS_GENRE]->(g:Genre)
MATCH (fav)-[h0:HAS_GENRE]->(g0:Genre)
RETURN fav, s, rec, h, g, h0, g0"""),
    ("g4_social", """
MATCH (u:User {id: 'u00029'})-[f:FOLLOWS]->(friend:User)-[lk:LIKED]->(rec:Track)
WHERE rec.name IN ['Quando o Sol Nascer', 'Papel de pão - Ao vivo', 'Two Weeks']
RETURN u, f, friend, lk, rec"""),
    ("g5_cold_start", """
MATCH (u:User {id: 'u02002'})-[p:PREFERS]->(g:Genre)<-[h:HAS_GENRE]-(t:Track)
WITH u, p, g, h, t, COUNT { (t)<-[:LIKED]-() } AS likes
ORDER BY likes DESC
WITH u, p, g, collect([h, t])[..4] AS top
UNWIND top AS x
RETURN u, p, g, x[0] AS h, x[1] AS t"""),
    ("g6_coocorrencia_generos", """
MATCH (g1:Genre)-[c:CO_OCCURS_WITH]->(g2:Genre)
WHERE c.tracks >= 300
RETURN g1, c, g2"""),
    ("g7_artista_ponte", """
MATCH (a:Artist {name: 'David Guetta'})<-[p:PERFORMED_BY]-(t:Track)-[h:HAS_GENRE]->(g:Genre)
WITH a, g, collect([p, t, h])[0] AS x
RETURN a, g, x[0] AS p, x[1] AS t, x[2] AS h"""),
]


def table_queries():
    """Extrai (nome, consulta) de 05_business_queries.cypher, com parâmetros embutidos."""
    text = QUERIES.read_text(encoding="utf-8")
    params = dict(re.findall(r":param (\w+) => ('[^']*');", text))
    out = []
    parts = re.split(r"// =+\n// (Q\d+)\.", text)
    for qid, body in zip(parts[1::2], parts[2::2]):
        body = body.split("\n", 1)[1]  # descarta o restante da linha de título "// Qn. ..."
        lines = [ln for ln in body.splitlines() if not ln.lstrip().startswith("//")]
        stmt = "\n".join(lines).strip().rstrip(";").strip()
        for k, v in params.items():
            stmt = re.sub(rf"\${k}\b", v, stmt)
        out.append((f"t{int(qid[1:]):02d}_{qid.lower()}", stmt))
    return out


def run(page, query: str):
    editor = page.locator("[data-testid=main-editor] .cm-content")
    editor.click()
    page.keyboard.press("Control+A")
    page.keyboard.press("Delete")
    page.keyboard.insert_text(query.strip())
    page.locator("[data-testid=run-button]").first.click()
    page.wait_for_timeout(1500)
    frame = page.locator("[data-testid=frame]").first
    try:
        frame.locator("text=/completed after|returned in/").first.wait_for(timeout=60_000)
    except Exception:
        page.screenshot(path=str(IMG / "_debug.png"))
        raise
    return frame


ENLARGE_JS = """(frame) => {
  // O Browser fixa a altura da área de grafo (~500 px). Para a captura, aumenta a
  // altura dos contêineres entre o frame e o canvas/SVG da visualização.
  const viz = frame.querySelector('canvas, svg.neod3viz, [class*=graph] svg');
  if (!viz) return 0;
  let n = 0;
  for (let el = viz.parentElement; el && el !== frame; el = el.parentElement) {
    const h = el.getBoundingClientRect().height;
    if (h >= 350 && h <= 650) { el.style.height = GRAPH_HEIGHT + 'px'; el.style.maxHeight = 'none'; n++; }
  }
  return n;
}"""
GRAPH_HEIGHT = 820


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", help="captura apenas arquivos que contenham este texto")
    args = parser.parse_args()
    IMG.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 1500, "height": 1300}, device_scale_factor=2)
        page.goto(URL, wait_until="networkidle")
        page.fill("input[name=password]", PASSWORD)
        page.click("[data-testid=connection-form-submit]")
        page.wait_for_selector("[data-testid=connection-status-indicator-success]")
        page.wait_for_timeout(2000)
        # Dispensa o tour de novidades exibido no primeiro acesso
        dismiss = page.get_by_role("button", name="Dismiss")
        if dismiss.count():
            dismiss.first.click()
        # Recolhe o painel lateral de consultas salvas para ampliar a área do frame
        page.get_by_title("Collapse Sidebar").first.click()

        for name, query in GRAPHS:
            if args.only and args.only not in name:
                continue
            frame = run(page, query)
            page.wait_for_timeout(1000)
            frame.evaluate(ENLARGE_JS.replace("GRAPH_HEIGHT", str(GRAPH_HEIGHT)))
            page.wait_for_timeout(6000)  # estabilização do layout de forças
            frame.get_by_role("button", name="Zoom to fit").first.click()
            page.mouse.move(5, 5)  # remove o tooltip do botão da captura
            page.wait_for_timeout(1500)
            frame.screenshot(path=str(IMG / f"{name}.png"))
            print("ok", name)

        for name, query in table_queries():
            if args.only and args.only not in name:
                continue
            frame = run(page, query)
            tab = frame.get_by_role("tab", name="Table")
            if tab.count():
                tab.first.click()
            else:
                frame.get_by_text("Table", exact=True).first.click()
            page.wait_for_timeout(800)
            frame.screenshot(path=str(IMG / f"{name}.png"))
            print("ok", name)

        browser.close()


if __name__ == "__main__":
    main()
