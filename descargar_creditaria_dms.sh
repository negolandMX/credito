#!/usr/bin/env bash
# ============================================================================
#  descargar_creditaria_dms.sh
#  Descarga masiva del portal Creditaria DMS (Odoo) — partners-creditaria.com
#
#  Lee creditaria_inventario.json con forma:
#      { "ruta/de/carpeta": ["id1","id2", ...], ... }
#  y descarga cada archivo a:
#      Creditaria_DMS/<ruta/de/carpeta>/<nombre real>
#  El nombre real se toma de la cabecera Content-Disposition que envia el
#  servidor (incluye el formato UTF-8 filename*=, que curl -J NO sabe leer;
#  por eso lo parseamos aqui en vez de usar -J -O).
#
#  USO:
#    A) Pega tu cookie en COOKIE (abajo), o
#    B) pasala por entorno (no queda escrita en el archivo):
#         COOKIE='session_id=xxxxxxxx' ./descargar_creditaria_dms.sh
#    El nombre de la cookie de sesion del portal es  session_id.
#
#  No descarga nada si COOKIE esta vacia.
# ============================================================================

# --------------------------- PEGA TU COOKIE AQUI ----------------------------
# Formato:  session_id=<valor>     (el <valor> es el de DevTools > Cookies)
# Ejemplo:  COOKIE="session_id=7145c4d698f371943306cc6a538648fb519942a8"
COOKIE="${COOKIE:-}"
# ----------------------------------------------------------------------------

set -uo pipefail

# --------------------------------- Config -----------------------------------
# Sobreescribibles por entorno al lanzar.
INVENTARIO="${INVENTARIO:-$HOME/Downloads/creditaria_inventario.json}"
BASE_DIR="${BASE_DIR:-$HOME/Downloads/Creditaria_DMS}"
FALLIDOS="${FALLIDOS:-$BASE_DIR/_fallidos.txt}"
COMPLETADOS="${COMPLETADOS:-$BASE_DIR/_completados.txt}"
BASE_URL="https://partners-creditaria.com/my/dms/file"
PAUSA="${PAUSA:-0.3}"             # segundos de pausa entre descargas
MODO_RESUME="${MODO_RESUME:-1}"  # 1 = salta IDs ya descargados (segun _completados.txt)
DRY_RUN="${DRY_RUN:-0}"          # 1 = no descarga, solo recorre el inventario
# ----------------------------------------------------------------------------

# ------------------------------ Validaciones --------------------------------
if [[ -z "$COOKIE" && "$DRY_RUN" != "1" ]]; then
  echo "ERROR: la variable COOKIE esta vacia." >&2
  echo "       Pega tu cookie en el script o lanza:  COOKIE='session_id=...' $0" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: se necesita python3 y no esta disponible." >&2
  exit 1
fi
if [[ ! -f "$INVENTARIO" ]]; then
  echo "ERROR: no encuentro el inventario: $INVENTARIO" >&2
  exit 1
fi
if ! python3 -c 'import json,sys; json.load(open(sys.argv[1],encoding="utf-8"))' "$INVENTARIO" 2>/dev/null; then
  echo "ERROR: $INVENTARIO no es un JSON valido." >&2
  exit 1
fi

mkdir -p "$BASE_DIR"
: > "$FALLIDOS"            # el registro de fallidos se reinicia en cada corrida
touch "$COMPLETADOS"      # el registro de completados PERSISTE entre corridas (reanudable)

TOTAL_ESPERADO="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); print(sum(len(v) for v in d.values()))' "$INVENTARIO")"

# Parsea el nombre real del archivo desde un volcado de cabeceras HTTP.
# Soporta  filename*=UTF-8''<pct-encoded>  (RFC 5987)  y  filename="..."
parse_cd() {
  python3 - "$1" <<'PY'
import sys, re, urllib.parse
data = open(sys.argv[1], encoding="latin-1", errors="replace").read()
m = re.findall(r'(?im)^content-disposition:[ \t]*([^\r\n]*)', data)
val = m[-1].strip() if m else ""
name = ""
mm = re.search(r"filename\*\s*=\s*([^;]+)", val, re.I)        # RFC 5987: filename*=
if mm:
    raw = mm.group(1).strip().strip('"')
    parts = raw.split("'", 2)
    if len(parts) == 3:                                       # charset'lang'pct-encoded
        charset, _lang, enc = parts
        name = urllib.parse.unquote(enc, encoding=(charset or "utf-8"), errors="replace")
    else:
        name = urllib.parse.unquote(raw)
if not name:                                                  # fallback: filename=
    mm2 = re.search(r'filename\s*=\s*"([^"]*)"', val, re.I) or re.search(r'filename\s*=\s*([^;]+)', val, re.I)
    if mm2:
        name = mm2.group(1).strip().strip('"')
name = name.replace("\\", "/").split("/")[-1]                 # basename (anti path-traversal)
name = "".join(c for c in name if ord(c) >= 32 and ord(c) != 127)
name = name.strip().strip(".").strip()
print(name)
PY
}

# Contadores (el while corre en el shell actual via proceso-sustitucion: persisten).
nuevos=0; saltados=0; fallidos=0; total=0

imprimir_resumen() {
  printf '\n'
  echo   "==================== RESUMEN ===================="
  printf ' Total en inventario  : %s\n' "$TOTAL_ESPERADO"
  printf ' Intentados           : %s\n' "$total"
  printf ' Descargados (nuevos) : %s\n' "$nuevos"
  printf ' Ya estaban (saltados): %s\n' "$saltados"
  printf ' Fallidos             : %s\n' "$fallidos"
  printf ' Carpeta destino      : %s\n' "$BASE_DIR"
  if [[ "$fallidos" -gt 0 ]]; then
    printf ' Registro de fallidos : %s\n' "$FALLIDOS"
  fi
  echo   "================================================="
}

tmpf="$BASE_DIR/.descarga_parcial.$$"
hdrf="$BASE_DIR/.headers.$$"
limpiar() { rm -f "$tmpf" "$hdrf"; }
# Ctrl-C / kill: limpia temporales y muestra el resumen parcial.
trap 'limpiar; imprimir_resumen; exit 130' INT TERM

echo "Inventario : $INVENTARIO  ($TOTAL_ESPERADO archivos)"
echo "Destino    : $BASE_DIR"
[[ "$MODO_RESUME" == "1" ]] && echo "Modo       : reanudable (salta lo ya registrado en _completados.txt)"
[[ "$DRY_RUN" == "1" ]] && echo "Modo       : DRY-RUN (no descarga, solo recorre)"
echo

# python3 emite pares  id\0 ruta\0  (NUL: a prueba de espacios, acentos y barras).
while IFS= read -r -d '' id && IFS= read -r -d '' carpeta; do
  total=$((total+1))
  destino="$BASE_DIR/$carpeta"
  url="$BASE_URL/$id/download"
  mkdir -p "$destino"

  # --- Reanudacion: si el ID ya esta completado, saltar sin red ---
  if [[ "$MODO_RESUME" == "1" ]] && grep -qxF "$id" "$COMPLETADOS"; then
    saltados=$((saltados+1))
    printf '\r\033[K[%d/%s] yaesta %s' "$total" "$TOTAL_ESPERADO" "$id"
    continue
  fi

  # --- Dry-run: no toca la red ---
  if [[ "$DRY_RUN" == "1" ]]; then
    nuevos=$((nuevos+1))
    printf '\r\033[K[%d/%s] (dry) %s -> %s' "$total" "$TOTAL_ESPERADO" "$id" "$carpeta"
    continue
  fi

  # --- Descarga a temporal, leyendo cabeceras y codigo HTTP ---
  http="$(curl -fsSL --remove-on-error -D "$hdrf" -o "$tmpf" -w '%{http_code}' \
               -H "Cookie: $COOKIE" "$url" 2>/dev/null)"
  rc=$?

  nombre=""
  if [[ $rc -eq 0 && "$http" == "200" ]]; then
    nombre="$(parse_cd "$hdrf")"
  fi

  if [[ $rc -eq 0 && "$http" == "200" && -n "$nombre" ]]; then
    destfile="$destino/$nombre"
    if [[ -e "$destfile" ]]; then                 # colision de nombre entre 2 IDs: desambigua
      base="${nombre%.*}"; ext="${nombre##*.}"
      if [[ "$base" == "$nombre" ]]; then destfile="$destino/${nombre} ($id)"
      else destfile="$destino/${base} ($id).${ext}"; fi
    fi
    mv -f "$tmpf" "$destfile"
    printf '%s\n' "$id" >> "$COMPLETADOS"
    nuevos=$((nuevos+1))
    printf '\r\033[K[%d/%s] OK     %s  (%s)' "$total" "$TOTAL_ESPERADO" "$id" "$nombre"
  else
    rm -f "$tmpf"
    fallidos=$((fallidos+1))
    printf '%s\t%s\t%s\tHTTP=%s rc=%s\n' "$id" "$carpeta" "$url" "${http:-?}" "$rc" >> "$FALLIDOS"
    printf '\r\033[K[%d/%s] FALLO  %s -> %s (HTTP=%s rc=%s)\n' \
           "$total" "$TOTAL_ESPERADO" "$id" "$carpeta" "${http:-?}" "$rc"
  fi

  sleep "$PAUSA"
done < <(python3 - "$INVENTARIO" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
out = sys.stdout.buffer
for carpeta, ids in d.items():
    for i in ids:
        out.write(str(i).encode("utf-8") + b"\0")
        out.write(str(carpeta).encode("utf-8") + b"\0")
PY
)

limpiar
imprimir_resumen
# Salida 0 si no hubo fallos; 1 si hubo al menos uno.
[[ "$fallidos" -eq 0 ]]
