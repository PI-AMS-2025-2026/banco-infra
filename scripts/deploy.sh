#!/usr/bin/env bash
#
# deploy.sh — Faz o deploy de um ambiente (dev | staging | production) no
# servidor local, com backup pré-deploy, verificação de saúde e rollback.
#
# É executado pelo self-hosted runner (.github/workflows/deploy-dev.yml e
# deploy.yml) e também serve para deploy manual via SSH.
#
# Uso:
#   BACKEND_TAG=sha-a1b2c3d ./scripts/deploy.sh dev
#   FRONTEND_TAG=sha-1111111-staging BACKEND_TAG=sha-2222222 ./scripts/deploy.sh staging
#
# ENTRADAS — todas por variável de ambiente; nenhum valor externo é interpolado
# em comando sem passar pelas validações de regex abaixo.
#
#   ENV_NAME          dev|staging|production. O 1º argumento, se informado,
#                     tem precedência.
#   FRONTEND_TAG      tag da imagem do frontend  (opcional)
#   BACKEND_TAG       tag da imagem do backend   (opcional)
#                     -> ao menos uma das duas é obrigatória; a que não vier
#                        mantém a tag que já está em images.env.
#   GHCR_USER         usuário do GitHub para `docker login ghcr.io` (opcional
#                     se os pacotes forem públicos)
#   GHCR_PULL_TOKEN   PAT com escopo read:packages (lido por stdin, nunca vai
#                     para a linha de comando)
#   HEALTH_TIMEOUT    segundos de espera pela saúde dos serviços (padrão 180)
#   GINI_ROOT         raiz dos ambientes no servidor (padrão /opt/gini)
#
# LIDO DO .env do ambiente (nunca do ambiente do shell):
#   API_URL           URL da API para a imagem ÚNICA do frontend (ADR-012).
#                     Depois do pull o script inspeciona o rótulo
#                     br.fatec.gini.runtime-api-url da imagem do frontend:
#                       - imagem única sem API_URL válida -> aborta ANTES do up;
#                       - imagem legado -> API_URL é ignorada (só log).
#
# EFEITOS no servidor, em /opt/gini/<env>/:
#   docker-compose.yml       sincronizado a partir deste repositório
#   images.env               reescrito com as tags do deploy
#   images.env.previous      tags do último deploy bem-sucedido (rollback)
#   .deploy-ok               marcador de que já houve um deploy bem-sucedido
#   releases.log             histórico (data/hora, tags, tipo da imagem do
#                            frontend — legado|unica —, resultado)
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuração
# --------------------------------------------------------------------------- #
GINI_ROOT="${GINI_ROOT:-/opt/gini}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
AMBIENTES_VALIDOS=(dev staging production)
SERVICOS=(db backend frontend)

# Tags padrão do primeiro deploy, quando ainda não existe images.env.
# Correspondem às branches de cada ambiente (premissa 9 / contrato de imagens).
TAG_PADRAO_DEV=dev
TAG_PADRAO_STAGING=staging
TAG_PADRAO_PRODUCTION=main

# Regex única para validar tags de imagem vindas de fora (payload / input).
REGEX_TAG='^[A-Za-z0-9_.-]{1,128}$'

RAIZ_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Imagem única x legado do frontend (rótulo OCI e validação de API_URL).
# shellcheck source=scripts/lib/frontend-api-url.sh
source "${RAIZ_REPO}/scripts/lib/frontend-api-url.sh"

log()   { printf '\033[0;34m[INFO ]\033[0m %s\n' "$*"; }
ok()    { printf '\033[0;32m[ OK  ]\033[0m %s\n' "$*"; }
aviso() { printf '\033[0;33m[AVISO]\033[0m %s\n' "$*"; }
erro()  { printf '\033[0;31m[ERRO ]\033[0m %s\n' "$*" >&2; }
morrer() { erro "$1"; exit 1; }

# Lê uma variável do arquivo KEY=VALUE sem executá-lo (o .env não é código).
ler_variavel_env() {
  local arquivo="$1" chave="$2" valor
  valor="$(grep -E "^[[:space:]]*${chave}=" "${arquivo}" | tail -n1 | cut -d= -f2-)" || true
  valor="${valor#"${valor%%[![:space:]]*}"}"
  valor="${valor%"${valor##*[![:space:]]}"}"
  valor="${valor%\"}"; valor="${valor#\"}"
  valor="${valor%\'}"; valor="${valor#\'}"
  printf '%s' "${valor}"
}

# --------------------------------------------------------------------------- #
# 1. Validação das entradas
# --------------------------------------------------------------------------- #
ENV_NAME="${1:-${ENV_NAME:-}}"

[[ -n "${ENV_NAME}" ]] || morrer "Informe o ambiente: $0 <dev|staging|production>"

if ! printf '%s\n' "${AMBIENTES_VALIDOS[@]}" | grep -qx -- "${ENV_NAME}"; then
  morrer "Ambiente inválido: '${ENV_NAME}'. Use um de: ${AMBIENTES_VALIDOS[*]}"
fi

FRONTEND_TAG="${FRONTEND_TAG:-}"
BACKEND_TAG="${BACKEND_TAG:-}"

if [[ -z "${FRONTEND_TAG}" && -z "${BACKEND_TAG}" ]]; then
  morrer "Informe FRONTEND_TAG e/ou BACKEND_TAG — ao menos uma é obrigatória."
fi

if [[ -n "${FRONTEND_TAG}" && ! "${FRONTEND_TAG}" =~ ${REGEX_TAG} ]]; then
  morrer "FRONTEND_TAG inválida. Esperado ${REGEX_TAG}."
fi
if [[ -n "${BACKEND_TAG}" && ! "${BACKEND_TAG}" =~ ${REGEX_TAG} ]]; then
  morrer "BACKEND_TAG inválida. Esperado ${REGEX_TAG}."
fi

if [[ ! "${HEALTH_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  morrer "HEALTH_TIMEOUT inválido: '${HEALTH_TIMEOUT}' (esperado inteiro de segundos)."
fi

command -v docker >/dev/null || morrer "docker não encontrado no PATH."
docker compose version >/dev/null 2>&1 || morrer "plugin 'docker compose' v2 indisponível."

DIRETORIO_AMBIENTE="${GINI_ROOT}/${ENV_NAME}"
ARQUIVO_ENV="${DIRETORIO_AMBIENTE}/.env"
ARQUIVO_IMAGES="${DIRETORIO_AMBIENTE}/images.env"
ARQUIVO_IMAGES_ANTERIOR="${DIRETORIO_AMBIENTE}/images.env.previous"
MARCADOR_OK="${DIRETORIO_AMBIENTE}/.deploy-ok"
ARQUIVO_RELEASES="${DIRETORIO_AMBIENTE}/releases.log"
PROJETO_COMPOSE="gini-${ENV_NAME}"

[[ -d "${DIRETORIO_AMBIENTE}" ]] \
  || morrer "${DIRETORIO_AMBIENTE} não existe. Rode scripts/bootstrap-server.sh."

[[ -f "${ARQUIVO_ENV}" ]] \
  || morrer "${ARQUIVO_ENV} não encontrado. Crie-o a partir de environments/${ENV_NAME}/.env.example (modo 600)."

MODO_ENV="$(stat -c '%a' "${ARQUIVO_ENV}")"
if [[ "${MODO_ENV}" != "600" ]]; then
  morrer "${ARQUIVO_ENV} está com modo ${MODO_ENV}; exigido 600 (chmod 600 '${ARQUIVO_ENV}')."
fi

if grep -q 'CHANGE_ME' "${ARQUIVO_ENV}"; then
  morrer "${ARQUIVO_ENV} ainda contém valores CHANGE_ME; preencha antes do deploy."
fi

# --------------------------------------------------------------------------- #
# 2. images.env — cria com as tags padrão no primeiro deploy
# --------------------------------------------------------------------------- #
tag_padrao_do_ambiente() {
  case "${ENV_NAME}" in
    dev)        printf '%s' "${TAG_PADRAO_DEV}" ;;
    staging)    printf '%s' "${TAG_PADRAO_STAGING}" ;;
    production) printf '%s' "${TAG_PADRAO_PRODUCTION}" ;;
  esac
}

if [[ ! -f "${ARQUIVO_IMAGES}" ]]; then
  PADRAO="$(tag_padrao_do_ambiente)"
  log "images.env ausente (primeiro deploy): criando com as tags padrão '${PADRAO}'."
  umask 077
  printf '# Gerado por scripts/deploy.sh — contém APENAS as tags das imagens.\nFRONTEND_TAG=%s\nBACKEND_TAG=%s\n' \
    "${PADRAO}" "${PADRAO}" > "${ARQUIVO_IMAGES}"
fi

TAG_FRONTEND_ATUAL="$(ler_variavel_env "${ARQUIVO_IMAGES}" FRONTEND_TAG)"
TAG_BACKEND_ATUAL="$(ler_variavel_env "${ARQUIVO_IMAGES}" BACKEND_TAG)"

# A tag não informada permanece como está.
TAG_FRONTEND_NOVA="${FRONTEND_TAG:-${TAG_FRONTEND_ATUAL}}"
TAG_BACKEND_NOVA="${BACKEND_TAG:-${TAG_BACKEND_ATUAL}}"

[[ -n "${TAG_FRONTEND_NOVA}" ]] || morrer "FRONTEND_TAG não informada e ausente em images.env."
[[ -n "${TAG_BACKEND_NOVA}"  ]] || morrer "BACKEND_TAG não informada e ausente em images.env."

# IMPORTANTE: FRONTEND_TAG/BACKEND_TAG chegam como variáveis de ambiente, e na
# interpolação do Compose o ambiente do shell tem precedência sobre --env-file.
# Se continuassem exportadas, o rollback leria a tag nova em vez da que está em
# images.env.previous. A partir daqui a fonte da verdade é só o images.env.
unset FRONTEND_TAG BACKEND_TAG

# Nomes das imagens: nos workflows vêm das Variables do repositório
# (FRONTEND_IMAGE / BACKEND_IMAGE) — NUNCA do payload do repository_dispatch.
# Em deploy manual por SSH, caem para o valor do .env do ambiente.
# Variável exportada tem precedência sobre --env-file na interpolação do Compose,
# então basta exportá-las aqui para o compose enxergar o mesmo valor.
IMAGEM_FRONTEND_NO_ENV="$(ler_variavel_env "${ARQUIVO_ENV}" FRONTEND_IMAGE)"
IMAGEM_BACKEND_NO_ENV="$(ler_variavel_env "${ARQUIVO_ENV}" BACKEND_IMAGE)"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-${IMAGEM_FRONTEND_NO_ENV}}"
BACKEND_IMAGE="${BACKEND_IMAGE:-${IMAGEM_BACKEND_NO_ENV}}"

# O mesmo nome de imagem existe em dois lugares (Variables do repositório e
# .env do servidor). Isso é proposital — o .env é o fallback do deploy manual
# por SSH —, mas divergência silenciosa entre os dois faria um deploy pela
# Actions e um deploy por SSH apontarem para imagens diferentes. Avisamos alto
# quando isso acontece, sem abortar: quem manda é sempre o valor recebido.
avisar_divergencia_de_imagem() {
  local rotulo="$1" efetivo="$2" no_env="$3"
  if [[ -n "${no_env}" && "${efetivo}" != "${no_env}" ]]; then
    aviso "${rotulo} divergente: usando '${efetivo}', mas ${ARQUIVO_ENV} diz '${no_env}'."
    aviso "Alinhe a Variable do repositório e o .env do servidor (veja docs/variaveis-e-secrets.md)."
  fi
}
avisar_divergencia_de_imagem FRONTEND_IMAGE "${FRONTEND_IMAGE}" "${IMAGEM_FRONTEND_NO_ENV}"
avisar_divergencia_de_imagem BACKEND_IMAGE  "${BACKEND_IMAGE}"  "${IMAGEM_BACKEND_NO_ENV}"

REGEX_IMAGEM='^[a-z0-9]+([._-][a-z0-9]+)*(\.[a-z0-9-]+)*(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)+$'
[[ "${FRONTEND_IMAGE}" =~ ${REGEX_IMAGEM} ]] \
  || morrer "FRONTEND_IMAGE inválida: '${FRONTEND_IMAGE}' (esperado ghcr.io/<owner>/<repo> em minúsculas, sem tag)."
[[ "${BACKEND_IMAGE}" =~ ${REGEX_IMAGEM} ]] \
  || morrer "BACKEND_IMAGE inválida: '${BACKEND_IMAGE}' (esperado ghcr.io/<owner>/<repo> em minúsculas, sem tag)."
export FRONTEND_IMAGE BACKEND_IMAGE

FRONTEND_PORT="$(ler_variavel_env "${ARQUIVO_ENV}" FRONTEND_PORT)"
BACKEND_PORT="$(ler_variavel_env "${ARQUIVO_ENV}" BACKEND_PORT)"

[[ "${FRONTEND_PORT}" =~ ^[0-9]{1,5}$ && "${BACKEND_PORT}" =~ ^[0-9]{1,5}$ ]] \
  || morrer "FRONTEND_PORT/BACKEND_PORT inválidos em ${ARQUIVO_ENV}."

# API_URL (imagem única do frontend). A fonte da verdade é o .env: se viesse
# exportada no shell, teria precedência sobre --env-file na interpolação do
# Compose e o container receberia um valor diferente do que validamos aqui.
# A validação propriamente dita acontece depois do pull, quando já se sabe se
# a imagem do frontend é única ou legado (seção 7.1).
API_URL_NO_ENV="$(ler_variavel_env "${ARQUIVO_ENV}" API_URL)"
unset API_URL

# Tipo da imagem do frontend (legado|unica), registrado no releases.log.
# Fica `?` enquanto a imagem não foi inspecionada (falhas antes do pull).
TIPO_FRONTEND='?'

# Mailpit (opcional): sobe quando COMPOSE_PROFILES do .env contém `mailpit`.
# Em production ele engoliria os e-mails reais dos usuários, então é recusado.
COMPOSE_PROFILES_ENV="$(ler_variavel_env "${ARQUIVO_ENV}" COMPOSE_PROFILES)"
USA_MAILPIT=0
if [[ ",${COMPOSE_PROFILES_ENV// /}," == *",mailpit,"* ]]; then
  USA_MAILPIT=1
  [[ "${ENV_NAME}" != "production" ]] \
    || morrer "COMPOSE_PROFILES=mailpit em ${ARQUIVO_ENV}: o Mailpit não pode rodar em production (os e-mails dos usuários não seriam entregues). Remova a linha e use um SMTP real."
  MAILPIT_WEB_PORT="$(ler_variavel_env "${ARQUIVO_ENV}" MAILPIT_WEB_PORT)"
  [[ -z "${MAILPIT_WEB_PORT}" || "${MAILPIT_WEB_PORT}" =~ ^[0-9]{1,5}$ ]] \
    || morrer "MAILPIT_WEB_PORT inválida em ${ARQUIVO_ENV}."
fi

# --------------------------------------------------------------------------- #
# Atalhos
# --------------------------------------------------------------------------- #
compose() {
  docker compose -p "${PROJETO_COMPOSE}" \
    --env-file "${ARQUIVO_ENV}" \
    --env-file "${ARQUIVO_IMAGES}" \
    -f "${DIRETORIO_AMBIENTE}/docker-compose.yml" "$@"
}

# Grava uma linha no histórico de releases do ambiente.
registrar_release() {
  local resultado="$1" detalhe="${2:-}"
  printf '%s | env=%s | frontend=%s | frontend_tipo=%s | backend=%s | resultado=%s%s\n' \
    "$(date --iso-8601=seconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S%z)" \
    "${ENV_NAME}" "${TAG_FRONTEND_NOVA}" "${TIPO_FRONTEND}" "${TAG_BACKEND_NOVA}" \
    "${resultado}" "${detalhe:+ | ${detalhe}}" \
    >> "${ARQUIVO_RELEASES}"
  chmod 640 "${ARQUIVO_RELEASES}" 2>/dev/null || true
}

printf '\n'
log "============================================================"
log " DEPLOY — ambiente '${ENV_NAME}' (projeto ${PROJETO_COMPOSE})"
log "============================================================"
log "frontend: ${FRONTEND_IMAGE}:${TAG_FRONTEND_ATUAL:-<nenhuma>} -> ${TAG_FRONTEND_NOVA}"
log "backend : ${BACKEND_IMAGE}:${TAG_BACKEND_ATUAL:-<nenhuma>} -> ${TAG_BACKEND_NOVA}"
printf '\n'

# --------------------------------------------------------------------------- #
# 3. Login no ghcr.io (imagens privadas)
# --------------------------------------------------------------------------- #
if [[ -n "${GHCR_PULL_TOKEN:-}" ]]; then
  [[ -n "${GHCR_USER:-}" ]] || morrer "GHCR_PULL_TOKEN informado sem GHCR_USER."
  log "Autenticando no ghcr.io como '${GHCR_USER}'..."
  # --password-stdin: o token não aparece em `ps` nem no histórico.
  printf '%s' "${GHCR_PULL_TOKEN}" | docker login ghcr.io -u "${GHCR_USER}" --password-stdin \
    || morrer "falha no login no ghcr.io; verifique GHCR_USER e o escopo read:packages do PAT."
  ok "autenticado no ghcr.io"
else
  log "GHCR_PULL_TOKEN não informado — assumindo pacotes públicos no ghcr.io."
fi

# --------------------------------------------------------------------------- #
# 4. Sincronizar o compose do checkout para o servidor
# Só o docker-compose.yml: .env e images.env pertencem ao servidor.
# --------------------------------------------------------------------------- #
log "Sincronizando docker-compose.yml para ${DIRETORIO_AMBIENTE}/..."
install -m 0640 "${RAIZ_REPO}/docker/docker-compose.yml" "${DIRETORIO_AMBIENTE}/docker-compose.yml"
ok "docker-compose.yml sincronizado"

# --------------------------------------------------------------------------- #
# 5. Backup pré-deploy
# Só faz sentido se já existe um container de banco. Falha no backup ABORTA o
# deploy: sem backup não há como voltar atrás de uma migration do Flyway.
# --------------------------------------------------------------------------- #
if [[ -n "$(compose ps --all --quiet db 2>/dev/null)" ]]; then
  log "Container 'db' existe — executando backup pré-deploy..."

  # O dump roda via `exec` dentro do container, então o banco precisa estar de
  # pé. Se o ambiente estava parado, sobe apenas o `db` (as aplicações seguem
  # paradas) e aguarda o healthcheck.
  if [[ -z "$(compose ps --quiet db 2>/dev/null)" ]]; then
    log "'db' estava parado — subindo apenas o banco para o backup."
    compose up -d --wait db || morrer "não foi possível subir o banco para o backup pré-deploy."
  fi

  if ! "${RAIZ_REPO}/scripts/backup-db.sh" "${ENV_NAME}"; then
    registrar_release "FALHA" "backup pre-deploy falhou"
    morrer "backup pré-deploy falhou; deploy abortado (nada foi alterado)."
  fi
  ok "backup pré-deploy concluído"
else
  log "Nenhum container 'db' ainda — primeiro deploy, sem backup pré-deploy."
fi

# --------------------------------------------------------------------------- #
# 6. Atualizar images.env (guardando a versão anterior)
# --------------------------------------------------------------------------- #
cp -p "${ARQUIVO_IMAGES}" "${ARQUIVO_IMAGES_ANTERIOR}"
umask 077
printf '# Gerado por scripts/deploy.sh em %s — contém APENAS as tags das imagens.\nFRONTEND_TAG=%s\nBACKEND_TAG=%s\n' \
  "$(date --iso-8601=seconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S%z)" \
  "${TAG_FRONTEND_NOVA}" "${TAG_BACKEND_NOVA}" > "${ARQUIVO_IMAGES}"
ok "images.env atualizado (anterior salvo em images.env.previous)"

# --------------------------------------------------------------------------- #
# Funções de saúde e rollback
# --------------------------------------------------------------------------- #
# Espera até HEALTH_TIMEOUT que todos os serviços reportem "healthy".
aguardar_saude() {
  local limite=$((SECONDS + HEALTH_TIMEOUT))
  local servico estado pendentes

  log "Aguardando os serviços ficarem saudáveis (timeout ${HEALTH_TIMEOUT}s)..."
  while [[ "${SECONDS}" -lt "${limite}" ]]; do
    pendentes=""
    for servico in "${SERVICOS[@]}"; do
      estado="$(compose ps --format '{{.Service}} {{.Health}}' 2>/dev/null \
                | awk -v s="${servico}" '$1==s{print $2}' | head -n1)"
      [[ "${estado}" == "healthy" ]] || pendentes+="${servico}(${estado:-ausente}) "
    done
    if [[ -z "${pendentes}" ]]; then
      ok "db, backend e frontend estão healthy"
      return 0
    fi
    log "ainda não saudáveis: ${pendentes}"
    sleep 5
  done

  erro "timeout de ${HEALTH_TIMEOUT}s esperando a saúde dos serviços."
  return 1
}

# Confirma pelas portas publicadas no host, não só pelo healthcheck interno.
verificar_endpoints() {
  local falhou=0

  if curl -fsS --max-time 15 "http://127.0.0.1:${BACKEND_PORT}/actuator/health" >/dev/null; then
    ok "backend: GET http://127.0.0.1:${BACKEND_PORT}/actuator/health"
  else
    erro "backend NÃO respondeu em /actuator/health (porta ${BACKEND_PORT})."
    falhou=1
  fi

  if curl -fsS --max-time 15 "http://127.0.0.1:${FRONTEND_PORT}/api/health" >/dev/null; then
    ok "frontend: GET http://127.0.0.1:${FRONTEND_PORT}/api/health"
  else
    erro "frontend NÃO respondeu em /api/health (porta ${FRONTEND_PORT})."
    falhou=1
  fi

  return "${falhou}"
}

# As migrations são do Flyway, executadas pelo backend no startup. Aqui só
# procuramos a confirmação nos logs — a ausência do padrão é AVISO, não falha:
# o formato da linha pertence ao backend e pode mudar.
verificar_flyway() {
  local logs
  logs="$(compose logs --no-color --tail=500 backend 2>/dev/null || true)"

  if printf '%s' "${logs}" | grep -qiE 'flyway.*(migrat|schema|up to date|validate)'; then
    ok "Flyway confirmado nos logs do backend"
    printf '%s' "${logs}" | grep -iE 'flyway' | tail -n 5 | sed 's/^/        /'
  else
    aviso "não encontrei confirmação do Flyway nos últimos 500 logs do backend."
    aviso "verifique manualmente: docker compose -p ${PROJETO_COMPOSE} logs backend | grep -i flyway"
  fi
}

# Volta para as tags de images.env.previous. Só é chamado quando existe um
# deploy anterior comprovadamente bem-sucedido (marcador .deploy-ok).
executar_rollback() {
  if [[ ! -f "${MARCADOR_OK}" || ! -f "${ARQUIVO_IMAGES_ANTERIOR}" ]]; then
    aviso "sem deploy anterior bem-sucedido registrado — nenhum rollback a fazer."
    aviso "o ambiente pode estar parcialmente no ar; investigue pelos logs acima."
    return 1
  fi

  aviso "Iniciando rollback para as tags do último deploy bem-sucedido..."
  cp -p "${ARQUIVO_IMAGES_ANTERIOR}" "${ARQUIVO_IMAGES}"
  log "tags restauradas: frontend=${TAG_FRONTEND_ATUAL} backend=${TAG_BACKEND_ATUAL}"

  # images.env.previous guarda só tags; API_URL continua vindo do .env. Voltar
  # de uma imagem única para uma legado é sempre seguro (a legado ignora
  # API_URL). O inverso só funciona se o .env ainda tiver API_URL válida —
  # caso contrário avisamos, mas tentamos mesmo assim (não há alternativa).
  local tipo_anterior
  if tipo_anterior="$(tipo_imagem_frontend "${FRONTEND_IMAGE}:${TAG_FRONTEND_ATUAL}")"; then
    log "frontend do rollback: imagem ${tipo_anterior}"
    if ! avaliar_api_url_frontend "${tipo_anterior}" "${API_URL_NO_ENV}" >/dev/null; then
      aviso "a imagem anterior do frontend é ÚNICA e API_URL em ${ARQUIVO_ENV} está ausente/inválida:"
      aviso "o frontend provavelmente não subirá no rollback. Corrija API_URL e rode o deploy de novo."
    fi
  else
    log "imagem anterior do frontend não está no host (o compose a baixará); tipo não verificado."
  fi

  if ! compose up -d --remove-orphans; then
    erro "o rollback falhou ao subir os containers."
    return 1
  fi

  if aguardar_saude; then
    ok "rollback concluído: ambiente de volta às tags anteriores."
    aviso "ATENÇÃO: o rollback de imagem NÃO reverte migrations já aplicadas pelo Flyway."
    aviso "Se a versão nova migrou o schema de forma incompatível, restaure o backup"
    aviso "pré-deploy com scripts/restore-db.sh."
    return 0
  fi

  erro "rollback executado, mas o ambiente não voltou a ficar saudável."
  return 1
}

# Fluxo de falha: logs -> rollback -> sempre encerra com código != 0.
tratar_falha() {
  local motivo="$1"

  erro "DEPLOY FALHOU: ${motivo}"
  printf '\n'
  erro "--- últimas 100 linhas de log de cada serviço ---"
  compose logs --no-color --tail=100 || true
  printf '\n'

  if executar_rollback; then
    registrar_release "FALHA_COM_ROLLBACK" "${motivo}"
  else
    registrar_release "FALHA_SEM_ROLLBACK" "${motivo}"
  fi

  # Mesmo com rollback bem-sucedido o job precisa terminar vermelho: a versão
  # pedida não entrou no ar.
  exit 1
}

# --------------------------------------------------------------------------- #
# 7. Pull — falha antecipada se a tag não existir, sem tocar no que está no ar
# --------------------------------------------------------------------------- #
log "Baixando as imagens (docker compose pull)..."
if ! compose pull; then
  erro "falha no pull — a tag provavelmente não existe no ghcr.io."
  log "Revertendo images.env; o ambiente em execução NÃO foi alterado."
  cp -p "${ARQUIVO_IMAGES_ANTERIOR}" "${ARQUIVO_IMAGES}"
  registrar_release "FALHA" "pull da imagem falhou (tag inexistente ou sem permissao)"
  exit 1
fi
ok "imagens disponíveis localmente"

# --------------------------------------------------------------------------- #
# 7.1 Imagem do frontend: única (API_URL em runtime) ou legado — ADR-012
# Roda ANTES do up: uma imagem única sem API_URL não sobe, e descobrir isso
# só pelo healthcheck custaria um rollback. Aqui o ambiente no ar não é tocado.
# --------------------------------------------------------------------------- #
abortar_antes_do_up() {
  local motivo_log="$1"
  log "Revertendo images.env; o ambiente em execução NÃO foi alterado."
  cp -p "${ARQUIVO_IMAGES_ANTERIOR}" "${ARQUIVO_IMAGES}"
  registrar_release "FALHA" "${motivo_log}"
  exit 1
}

REFERENCIA_FRONTEND="${FRONTEND_IMAGE}:${TAG_FRONTEND_NOVA}"
if ! TIPO_FRONTEND="$(tipo_imagem_frontend "${REFERENCIA_FRONTEND}")"; then
  TIPO_FRONTEND='?'
  erro "não foi possível inspecionar ${REFERENCIA_FRONTEND} (rótulo ${ROTULO_RUNTIME_API_URL})."
  abortar_antes_do_up "inspecao da imagem do frontend falhou"
fi

if RESULTADO_API_URL="$(avaliar_api_url_frontend "${TIPO_FRONTEND}" "${API_URL_NO_ENV}")"; then
  case "${RESULTADO_API_URL}" in
    OK_UNICA)
      ok "frontend: imagem única — API_URL=${API_URL_NO_ENV}" ;;
    OK_LEGADO)
      log "frontend: imagem legado (URL da API embutida no build)." ;;
    OK_LEGADO_IGNORADA)
      log "frontend: imagem antiga: API_URL ignorada (a URL da API vem embutida no build)." ;;
    AVISO_LEGADO_INVALIDA)
      log "frontend: imagem antiga: API_URL ignorada (a URL da API vem embutida no build)."
      aviso "API_URL em ${ARQUIVO_ENV} tem formato inválido; corrija antes de usar a imagem única."
      aviso "Formato esperado: ${REGEX_API_URL} (ex.: http://192.168.0.10:8081)." ;;
  esac
else
  case "${RESULTADO_API_URL}" in
    ERRO_AUSENTE)
      erro "a imagem ${REFERENCIA_FRONTEND} é ÚNICA (lê a URL da API em runtime), mas API_URL não está definida."
      erro "Defina API_URL em ${ARQUIVO_ENV} (ex.: API_URL=http://192.168.0.10:${BACKEND_PORT}) e rode o deploy de novo."
      ;;
    ERRO_INVALIDA)
      erro "a imagem ${REFERENCIA_FRONTEND} é ÚNICA, mas API_URL em ${ARQUIVO_ENV} é inválida: '${API_URL_NO_ENV}'."
      erro "Defina API_URL em ${ARQUIVO_ENV} no formato ${REGEX_API_URL} (sem barra final, sem caminho)."
      ;;
    *)
      erro "verificação de API_URL do frontend retornou '${RESULTADO_API_URL}'."
      ;;
  esac
  abortar_antes_do_up "frontend imagem unica sem API_URL valida no .env"
fi

# --------------------------------------------------------------------------- #
# 8. Subir
# --------------------------------------------------------------------------- #
log "Aplicando (docker compose up -d --remove-orphans)..."
if ! compose up -d --remove-orphans; then
  tratar_falha "docker compose up falhou"
fi

# --------------------------------------------------------------------------- #
# 9. Verificações
# --------------------------------------------------------------------------- #
if ! aguardar_saude; then
  tratar_falha "serviços não ficaram healthy dentro de ${HEALTH_TIMEOUT}s"
fi

if ! verificar_endpoints; then
  tratar_falha "endpoints de health não responderam nas portas publicadas"
fi

verificar_flyway

# O Mailpit é ferramenta de teste: se não estiver saudável, avisa, mas não
# derruba nem reverte o deploy (o backend não depende dele para subir).
if [[ "${USA_MAILPIT}" -eq 1 ]]; then
  estado_mailpit="$(compose ps --format '{{.Service}} {{.Health}}' 2>/dev/null \
                    | awk '$1=="mailpit"{print $2}' | head -n1)"
  if [[ "${estado_mailpit}" == "healthy" ]]; then
    ok "mailpit healthy (interface em 127.0.0.1:${MAILPIT_WEB_PORT:-8025}, acesso por túnel SSH)"
  else
    aviso "mailpit não está healthy (estado: ${estado_mailpit:-ausente}); e-mails de teste podem não ser capturados."
  fi
fi

# --------------------------------------------------------------------------- #
# 10. Sucesso — marcar, registrar e limpar
# --------------------------------------------------------------------------- #
touch "${MARCADOR_OK}"
registrar_release "SUCESSO"
ok "release registrada em ${ARQUIVO_RELEASES}"

log "Removendo imagens dangling..."
docker image prune -f >/dev/null || aviso "docker image prune falhou (ignorado)."

printf '\n'
compose ps
printf '\n'
ok "DEPLOY DE '${ENV_NAME}' CONCLUÍDO — frontend=${TAG_FRONTEND_NOVA} (${TIPO_FRONTEND}) backend=${TAG_BACKEND_NOVA}"
