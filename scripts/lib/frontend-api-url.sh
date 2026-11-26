#!/usr/bin/env bash
#
# frontend-api-url.sh — Funções de sanidade para a imagem do frontend, que
# recebe a URL da API em runtime pela variável API_URL (ADR-012).
#
# Biblioteca: é carregada com `source` pelo scripts/deploy.sh e pelo teste
# scripts/tests/test-frontend-api-url.sh. Não executa nada sozinha e não
# altera opções do shell de quem a carrega.

# Rótulo OCI publicado pelo repositório do frontend na imagem que lê API_URL.
ROTULO_RUNTIME_API_URL='br.fatec.gini.runtime-api-url'

# Formato aceito para API_URL: esquema + host + porta opcional, sem barra
# final, sem caminho, sem credenciais. Nada além disso chega ao container.
REGEX_API_URL='^https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?$'

# api_url_valida <valor>
#   Retorna 0 se o valor casa com REGEX_API_URL.
api_url_valida() {
  [[ "$1" =~ ${REGEX_API_URL} ]]
}

# frontend_le_api_url <imagem:tag>
#   Confere, na imagem LOCAL (rodar depois do pull), o rótulo
#   br.fatec.gini.runtime-api-url=true. Retorna:
#     0  rótulo presente: a imagem lê API_URL no startup;
#     1  rótulo ausente: imagem antiga, com a URL da API embutida no build —
#        API_URL seria ignorada e o navegador chamaria a API errada;
#     2  a imagem não pôde ser inspecionada.
#
#   O template percorre os rótulos com `range` em vez de `index`: `range` sobre
#   um mapa nulo (imagem sem rótulo nenhum) simplesmente não itera, enquanto
#   `index` pode falhar. A referência vai como argumento, nunca interpolada.
frontend_le_api_url() {
  local referencia="$1" rotulos
  rotulos="$(docker image inspect \
               --format '{{ range $k, $v := .Config.Labels }}{{ $k }}={{ $v }}{{ "\n" }}{{ end }}' \
               -- "${referencia}" 2>/dev/null)" || return 2

  printf '%s\n' "${rotulos}" | grep -qxF -- "${ROTULO_RUNTIME_API_URL}=true"
}
