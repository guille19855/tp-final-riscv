#!/usr/bin/env bash
# Convierte un diagrama SVG de una pagina de docs/*.html en PNG para el informe.
# Usa Edge en modo headless (sin ventana) para dibujar el SVG en tema claro.
#
# Uso:   scripts/svg_a_png.sh <pagina.html> <clase_del_svg> <salida.png>
# Ej:    scripts/svg_a_png.sh docs/pipeline_diagrama.html dp docs/informe/img/pipeline_datapath.png
#        scripts/svg_a_png.sh docs/etapa_if.html sch docs/informe/img/if_esquematico.png
#        scripts/svg_a_png.sh docs/etapa_if.html wave docs/informe/img/if_ondas.png

set -e
[ $# -ne 3 ] && { echo "uso: $0 <pagina.html> <clase_svg> <salida.png>"; exit 1; }
SRC="$1"; CLS="$2"; OUT="$3"
EDGE="${EDGE:-/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe}"
# Carpeta temporal propia (Edge necesita un perfil aparte si el navegador ya esta abierto)
TMP="$(mktemp -d -p "${TEMP:-/tmp}")"

# Extrae el <svg class="... CLS ..."> y el <style> de la pagina en un HTML minimo
read W H < <(python -I - "$SRC" "$CLS" "$TMP/svg.html" <<'EOF'
import re, sys
src, cls, out = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
style = re.search(r"<style>(.*?)</style>", s, re.S).group(1)
svg = re.search(r'(<svg class="[^"]*\b' + cls + r'\b[^"]*".*?</svg>)', s, re.S).group(1)
w, h = map(int, re.search(r'viewBox="0 0 (\d+) (\d+)"', svg).groups())
open(out, "w", encoding="utf-8").write(f"""<!doctype html><html data-theme="light"><head><meta charset="utf-8">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans+Condensed:wght@600;700&family=IBM+Plex+Sans:wght@400;600&display=swap">
<style>{style}
html,body{{margin:0;padding:0;background:#ffffff}}
svg{{min-width:0 !important;width:{w}px !important;height:{h}px !important;display:block}}
</style></head><body>{svg}</body></html>""")
print(w, h)
EOF
)

"$EDGE" --headless=new --user-data-dir="$(cygpath -w "$TMP/perfil")" --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --virtual-time-budget=4000 --window-size=$W,$H \
    --screenshot="$(cygpath -w "$TMP/out.png")" "file:///$(cygpath -m "$TMP/svg.html")" >/dev/null 2>&1
# Edge escribe la imagen en segundo plano: esperar hasta 30 s a que aparezca
for i in $(seq 60); do [ -s "$TMP/out.png" ] && break; timeout 0.5 tail -f /dev/null || true; done
[ -s "$TMP/out.png" ] || { echo "Edge no genero la imagen"; exit 1; }
timeout 1 tail -f /dev/null || true          # que termine de escribirla
cp "$TMP/out.png" "$OUT"
rm -rf "$TMP" 2>/dev/null || true           # el perfil puede seguir bloqueado un rato
echo "generado: $OUT (${W}x${H} a escala 2)"
