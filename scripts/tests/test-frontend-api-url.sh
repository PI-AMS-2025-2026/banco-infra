#!/usr/bin/env bash
#
# test-frontend-api-url.sh — Testa, em modo simulado, as verificações de
# sanidade do deploy.sh sobre o frontend: formato de API_URL e rótulo OCI
# br.fatec.gini.runtime-api-url=true da imagem (ADR-012).
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
printf '\n== Rótulo OCI da imagem do frontend (docker simulado)\n'
# --------------------------------------------------------------------------- #
DIR_TMP="$(mktemp -d)"
trap 'rm -rf "${DIR_TMP}"' EXIT

# `docker` falso: responde a `docker image inspect --format ... -- <ref>`
# conforme o nome da referência, imprimindo os rótulos no formato k=v.
cat > "${DIR_TMP}/docker" <<'SIMULADO'
#!/usr/bin/env bash
ref="${*: -1}"
case "${ref}" in
  *:com-rotulo)  printf 'org.opencontainers.image.source=x\nbr.fatec.gini.runtime-api-url=true\n' ;;
  *:antiga)      printf 'org.opencontainers.image.source=x\n' ;;
  *:sem-rotulos) printf '' ;;
  *:falso)       printf 'br.fatec.gini.runtime-api-url=false\n' ;;
  *:parecido)    printf 'br.fatec.gini.runtime-api-url=true-ish\nxbr.fatec.gini.runtime-api-url=true\n' ;;
  *)             echo "Error: No such image: ${ref}" >&2; exit 1 ;;
esac
SIMULADO
chmod +x "${DIR_TMP}/docker"

# Executa frontend_le_api_url e devolve o código de saída.
status_simulado() {
  local status=0
  PATH="${DIR_TMP}:${PATH}" frontend_le_api_url "$1" || status=$?
  printf '%s' "${status}"
}

conferir "rótulo =true            -> 0 (segue)"     "0" "$(status_simulado ghcr.io/o/frontend:com-rotulo)"
conferir "sem o rótulo            -> 1 (bloqueia)"  "1" "$(status_simulado ghcr.io/o/frontend:antiga)"
conferir "imagem sem rótulo algum -> 1 (bloqueia)"  "1" "$(status_simulado ghcr.io/o/frontend:sem-rotulos)"
conferir "rótulo =false           -> 1 (bloqueia)"  "1" "$(status_simulado ghcr.io/o/frontend:falso)"
conferir "rótulo só parecido      -> 1 (bloqueia)"  "1" "$(status_simulado ghcr.io/o/frontend:parecido)"
conferir "inspect falha           -> 2 (bloqueia)"  "2" "$(status_simulado ghcr.io/o/frontend:inexistente)"

# --------------------------------------------------------------------------- #
if [[ "${COM_DOCKER}" -eq 1 ]]; then
  printf '\n== Rótulo OCI da imagem do frontend (docker real, imagens FROM scratch)\n'
  # Nomes fixos e locais (sem registry): nada é enviado para fora.
  IMG_COM='gini-teste/frontend-rotulo:com-rotulo'
  IMG_SEM='gini-teste/frontend-rotulo:sem-rotulos'
  trap 'docker image rm -f "${IMG_COM}" "${IMG_SEM}" >/dev/null 2>&1 || true; rm -rf "${DIR_TMP}"' EXIT

  printf 'FROM scratch\nLABEL br.fatec.gini.runtime-api-url=true\n' \
    | docker build -q -t "${IMG_COM}" - >/dev/null
  printf 'FROM scratch\n' > "${DIR_TMP}/Dockerfile.sem"
  docker build -q -t "${IMG_SEM}" -f "${DIR_TMP}/Dockerfile.sem" "${DIR_TMP}" >/dev/null

  status_real() {
    local status=0
    frontend_le_api_url "$1" || status=$?
    printf '%s' "${status}"
  }
  conferir "imagem real com rótulo  -> 0" "0" "$(status_real "${IMG_COM}")"
  conferir "imagem real sem rótulos -> 1" "1" "$(status_real "${IMG_SEM}")"
  conferir "imagem real inexistente -> 2" "2" "$(status_real gini-teste/frontend-rotulo:nao-existe)"
fi

printf '\n%d caso(s), %d falha(s).\n' "${TOTAL}" "${FALHAS}"
[[ "${FALHAS}" -eq 0 ]]
