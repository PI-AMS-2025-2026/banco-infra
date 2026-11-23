#!/usr/bin/env bash
#
# frontend-api-url.sh — Funções de suporte à imagem ÚNICA do frontend (URL da
# API recebida em runtime pela variável API_URL). Ver ADR-012.
#
# Biblioteca: é carregada com `source` pelo scripts/deploy.sh e pelo teste
# scripts/tests/test-frontend-api-url.sh. Não executa nada sozinha e não
# altera opções do shell de quem a carrega.
#
# Os dois tipos de imagem do frontend:
#   unica   rótulo OCI br.fatec.gini.runtime-api-url=true; lê API_URL no
#           startup e não sobe sem ela.
#   legado  sem o rótulo; a URL da API vem embutida no build e API_URL é
#           ignorada.

# Rótulo OCI publicado pelo repositório do frontend na imagem única.
ROTULO_RUNTIME_API_URL='br.fatec.gini.runtime-api-url'

# Formato aceito para API_URL: esquema + host + porta opcional, sem barra
# final, sem caminho, sem credenciais. Nada além disso chega ao container.
REGEX_API_URL='^https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?$'

# api_url_valida <valor>
#   Retorna 0 se o valor casa com REGEX_API_URL.
api_url_valida() {
  [[ "$1" =~ ${REGEX_API_URL} ]]
}

# tipo_imagem_frontend <imagem:tag>
#   Imprime `unica` ou `legado` a partir dos rótulos da imagem LOCAL (rodar
#   depois do pull). Retorna 1 se a imagem não puder ser inspecionada.
#
#   O template percorre os rótulos com `range` em vez de `index`: `range` sobre
#   um mapa nulo (imagem sem rótulo nenhum) simplesmente não itera, enquanto
#   `index` pode falhar. A referência vai como argumento, nunca interpolada.
tipo_imagem_frontend() {
  local referencia="$1" rotulos
  rotulos="$(docker image inspect \
               --format '{{ range $k, $v := .Config.Labels }}{{ $k }}={{ $v }}{{ "\n" }}{{ end }}' \
               -- "${referencia}" 2>/dev/null)" || return 1

  if printf '%s\n' "${rotulos}" | grep -qxF -- "${ROTULO_RUNTIME_API_URL}=true"; then
    printf 'unica'
  else
    printf 'legado'
  fi
}

# avaliar_api_url_frontend <tipo> <api_url>
#   Decide se o deploy pode seguir. Imprime um código e retorna 0 (segue) ou
#   1 (bloqueia). Quem chama traduz o código em mensagem.
#
#   tipo=unica,  API_URL vazia        -> ERRO_AUSENTE          (1)
#   tipo=unica,  API_URL inválida     -> ERRO_INVALIDA         (1)
#   tipo=unica,  API_URL válida       -> OK_UNICA              (0)
#   tipo=legado, API_URL vazia        -> OK_LEGADO             (0)
#   tipo=legado, API_URL válida       -> OK_LEGADO_IGNORADA    (0)
#   tipo=legado, API_URL inválida     -> AVISO_LEGADO_INVALIDA (0)
#   outro tipo                        -> ERRO_TIPO             (1)
avaliar_api_url_frontend() {
  local tipo="$1" api_url="$2"

  case "${tipo}" in
    unica)
      if [[ -z "${api_url}" ]]; then
        printf 'ERRO_AUSENTE'; return 1
      elif ! api_url_valida "${api_url}"; then
        printf 'ERRO_INVALIDA'; return 1
      fi
      printf 'OK_UNICA'; return 0
      ;;
    legado)
      if [[ -z "${api_url}" ]]; then
        printf 'OK_LEGADO'
      elif api_url_valida "${api_url}"; then
        printf 'OK_LEGADO_IGNORADA'
      else
        printf 'AVISO_LEGADO_INVALIDA'
      fi
      return 0
      ;;
    *)
      printf 'ERRO_TIPO'; return 1
      ;;
  esac
}
