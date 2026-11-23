#!/usr/bin/env bash
#
# test-frontend-api-url.sh — Testa, em modo simulado, a decisão do deploy.sh
# sobre a imagem do frontend (única x legado) e a validação de API_URL.
# Não toca no servidor, não sobe container e não precisa de rede.
#
# Uso (na raiz do repositório):
#   bash scripts/tests/test-frontend-api-url.sh
#   bash scripts/tests/test-frontend-api-url.sh --com-docker
#
#   --com-docker  além do `docker` simulado, constrói duas imagens mínimas
#                 (FROM scratch, só rótulos) no daemon local e confere o
#                 template real do `docker image inspect`. Remove as imagens
#                 ao final.
#
# Sai com 0 se todos os casos passarem.
set -euo pipefail

RAIZ_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/frontend-api-url.sh
source "${RAIZ_REPO}/scripts/lib/frontend-api-url.sh"

COM_DOCKER=0
[[ "${1:-}" == "--com-docker" ]] && COM_DOCKER=1

FALHAS=0
TOTAL=0

conferir() {
  local descricao="$1" esperado="$2" obtido="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "${obtido}" == "${esperado}" ]]; then
    printf '  ok    %s\n' "${descricao}"
  else
    printf '  FALHA %s\n        esperado: %s\n        obtido:   %s\n' \
      "${descricao}" "${esperado}" "${obtido}"
    FALHAS=$((FALHAS + 1))
  fi
}

# Executa avaliar_api_url_frontend e devolve "<codigo>/<status>".
avaliar() {
  local codigo status=0
  codigo="$(avaliar_api_url_frontend "$1" "$2")" || status=$?
  printf '%s/%s' "${codigo}" "${status}"
}

# --------------------------------------------------------------------------- #
printf '\n== Cenários do deploy (tipo da imagem x API_URL no .env)\n'
# --------------------------------------------------------------------------- #
conferir "única sem API_URL -> erro, bloqueia o up" \
  "ERRO_AUSENTE/1" "$(avaliar unica '')"
conferir "única com API_URL inválida -> erro, bloqueia o up" \
  "ERRO_INVALIDA/1" "$(avaliar unica 'http://192.168.0.10:8081/')"
conferir "única com API_URL válida -> segue" \
  "OK_UNICA/0" "$(avaliar unica 'http://192.168.0.10:8081')"
conferir "legado sem API_URL -> segue (comportamento atual)" \
  "OK_LEGADO/0" "$(avaliar legado '')"
conferir "legado com API_URL -> segue, só log 'ignorada'" \
  "OK_LEGADO_IGNORADA/0" "$(avaliar legado 'http://192.168.0.10:8081')"
conferir "legado com API_URL inválida -> segue, com aviso" \
  "AVISO_LEGADO_INVALIDA/0" "$(avaliar legado 'localhost:8081')"
conferir "tipo desconhecido -> bloqueia" \
  "ERRO_TIPO/1" "$(avaliar '?' 'http://192.168.0.10:8081')"

# --------------------------------------------------------------------------- #
printf '\n== Formato de API_URL (%s)\n' "${REGEX_API_URL}"
# --------------------------------------------------------------------------- #
validade() { if api_url_valida "$1"; then printf 'valida'; else printf 'invalida'; fi; }

for url in \
  'http://192.168.0.10:8081' \
  'https://api.gini.exemplo.com.br' \
  'http://gini-servidor:8080' \
  'http://localhost:8081'; do
  conferir "aceita   ${url}" "valida" "$(validade "${url}")"
done

# shellcheck disable=SC2016  # '$(id)' é literal de propósito (tentativa de injeção)
for url in \
  'http://192.168.0.10:8081/' \
  'http://192.168.0.10:8081/api' \
  '192.168.0.10:8081' \
  'ftp://192.168.0.10' \
  'http://usuario:senha@192.168.0.10' \
  'http://192.168.0.10:123456' \
  'http://host:8081;rm -rf /' \
  'http://$(id):8081' \
  ' http://192.168.0.10:8081' \
  $'http://192.168.0.10:8081\nhttp://outro' \
  'CHANGE_ME' \
  ''; do
  conferir "recusa   $(printf '%q' "${url}")" "invalida" "$(validade "${url}")"
done

# --------------------------------------------------------------------------- #
printf '\n== Leitura do rótulo OCI (docker simulado)\n'
# --------------------------------------------------------------------------- #
DIR_TMP="$(mktemp -d)"
trap 'rm -rf "${DIR_TMP}"' EXIT

# `docker` falso: responde a `docker image inspect --format ... -- <ref>`
# conforme o nome da referência, imprimindo os rótulos no formato k=v.
cat > "${DIR_TMP}/docker" <<'SIMULADO'
#!/usr/bin/env bash
ref="${*: -1}"
case "${ref}" in
  *:unica)       printf 'org.opencontainers.image.source=x\nbr.fatec.gini.runtime-api-url=true\n' ;;
  *:legado)      printf 'org.opencontainers.image.source=x\n' ;;
  *:sem-rotulos) printf '' ;;
  *:falso)       printf 'br.fatec.gini.runtime-api-url=false\n' ;;
  *:parecido)    printf 'br.fatec.gini.runtime-api-url=true-ish\nxbr.fatec.gini.runtime-api-url=true\n' ;;
  *)             echo "Error: No such image: ${ref}" >&2; exit 1 ;;
esac
SIMULADO
chmod +x "${DIR_TMP}/docker"

tipo_simulado() {
  local tipo status=0
  tipo="$(PATH="${DIR_TMP}:${PATH}" tipo_imagem_frontend "$1")" || status=$?
  printf '%s/%s' "${tipo}" "${status}"
}

conferir "rótulo =true            -> unica"  "unica/0"  "$(tipo_simulado ghcr.io/o/frontend:unica)"
conferir "sem o rótulo            -> legado" "legado/0" "$(tipo_simulado ghcr.io/o/frontend:legado)"
conferir "imagem sem rótulo algum -> legado" "legado/0" "$(tipo_simulado ghcr.io/o/frontend:sem-rotulos)"
conferir "rótulo =false           -> legado" "legado/0" "$(tipo_simulado ghcr.io/o/frontend:falso)"
conferir "rótulo só parecido      -> legado" "legado/0" "$(tipo_simulado ghcr.io/o/frontend:parecido)"
conferir "inspect falha           -> status 1" "/1"     "$(tipo_simulado ghcr.io/o/frontend:inexistente)"

# --------------------------------------------------------------------------- #
if [[ "${COM_DOCKER}" -eq 1 ]]; then
  printf '\n== Leitura do rótulo OCI (docker real, imagens FROM scratch)\n'
  # Nomes fixos e locais (sem registry): nada é enviado para fora.
  IMG_UNICA='gini-teste/frontend-rotulo:unica'
  IMG_LEGADO='gini-teste/frontend-rotulo:legado'
  trap 'docker image rm -f "${IMG_UNICA}" "${IMG_LEGADO}" >/dev/null 2>&1 || true; rm -rf "${DIR_TMP}"' EXIT

  printf 'FROM scratch\nLABEL br.fatec.gini.runtime-api-url=true\n' \
    | docker build -q -t "${IMG_UNICA}" - >/dev/null
  printf 'FROM scratch\n' > "${DIR_TMP}/Dockerfile.legado"
  docker build -q -t "${IMG_LEGADO}" -f "${DIR_TMP}/Dockerfile.legado" "${DIR_TMP}" >/dev/null

  tipo_real() {
    local tipo status=0
    tipo="$(tipo_imagem_frontend "$1")" || status=$?
    printf '%s/%s' "${tipo}" "${status}"
  }
  conferir "imagem real com rótulo  -> unica"    "unica/0"  "$(tipo_real "${IMG_UNICA}")"
  conferir "imagem real sem rótulos -> legado"   "legado/0" "$(tipo_real "${IMG_LEGADO}")"
  conferir "imagem real inexistente -> status 1" "/1"       "$(tipo_real gini-teste/frontend-rotulo:nao-existe)"
fi

printf '\n%d caso(s), %d falha(s).\n' "${TOTAL}" "${FALHAS}"
[[ "${FALHAS}" -eq 0 ]]
