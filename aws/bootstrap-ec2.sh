#!/usr/bin/env bash
#
# bootstrap-ec2.sh — Prepara uma instância EC2 (Amazon Linux 2023) do AWS
# Academy Learner Lab e sobe a aplicação Gini (backend + frontend + Mailpit
# opcional) com Docker Compose, usando o Amazon RDS como banco.
#
# Normalmente é chamado pelo aws/user-data.sh (user data do launch template),
# que exporta as variáveis abaixo e roda este script como root no 1º boot.
# Pode ser reexecutado à mão a qualquer momento (é idempotente):
#
#   sudo -E bash aws/bootstrap-ec2.sh            # usa as variáveis exportadas
#   DRY_RUN=1 bash aws/bootstrap-ec2.sh          # só valida e mostra o plano
#   bash aws/bootstrap-ec2.sh --help
#
# Todos os parâmetros são VARIÁVEIS DE AMBIENTE (nunca argumentos). Contrato
# completo, com validação e o mapeamento para CloudFormation: aws/PARAMETERS.md
#
#   Obrigatórias: RDS_ENDPOINT, DB_USER, DB_PASSWORD, JWT_SECRET,
#                 BACKEND_TAG, FRONTEND_TAG
#   Opcionais:    DB_NAME (gini), ALB_DNS (descoberto pelo ALB_NAME),
#                 ALB_NAME (gini-lb), BACKEND_IMAGE, FRONTEND_IMAGE,
#                 APP_ENVIRONMENT (staging), ENABLE_MAILPIT (true),
#                 INFRA_REF (main), COMPOSE_VERSION, COMPOSE_SHA256,
#                 SMTP_HOST/PORT/USERNAME/PASSWORD/AUTH/STARTTLS/FROM
#                 (só com ENABLE_MAILPIT=false), AWS_REGION (dos metadados),
#                 HEALTH_TIMEOUT (300), DRY_RUN (0)
#
# O que faz (cada etapa confere o estado antes e registra "já configurado"):
#   1. confere root, Amazon Linux 2023 e arquitetura;
#   2. valida os parâmetros e descobre o DNS do ALB, se preciso;
#   3. instala e habilita o Docker; instala o compose plugin (versão e
#      SHA-256 fixados);
#   4. grava /opt/gini/aws/docker-compose.yml e /opt/gini/aws/.env (modo 600);
#   5. baixa as imagens, testa o RDS e confere o rótulo da imagem do frontend;
#   6. sobe os containers, espera ficarem saudáveis e testa os endpoints;
#   7. imprime o resumo (URLs, tags, status).
#
# Log: /var/log/gini-bootstrap.log (e saída padrão). Segredos nunca são
# impressos: aparecem mascarados.
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Constantes
# --------------------------------------------------------------------------- #
readonly LOG_FILE='/var/log/gini-bootstrap.log'
readonly GINI_DIR='/opt/gini/aws'
readonly REPO_RAW_BASE='https://raw.githubusercontent.com/PI-AMS-2025-2026/banco-infra'
readonly COMPOSE_PLUGIN_DIR='/usr/local/lib/docker/cli-plugins'
readonly ROTULO_RUNTIME_API_URL='br.fatec.gini.runtime-api-url'
readonly IMAGEM_PG_ISREADY='postgres:17-alpine'

# Docker Compose fixado. Versão e checksums conferidos em
# https://github.com/docker/compose/releases/tag/v5.7.2 (publicada em
# 17/11/2026; arquivo checksums.txt da release, conferido também contra os
# binários baixados). Para atualizar: troque as TRÊS linhas juntas, sempre
# consultando a página oficial — nunca estime o checksum.
readonly COMPOSE_VERSION_PADRAO='v5.7.2'
readonly COMPOSE_SHA256_PADRAO_X86_64='e14235d9c622c5bd57eb8adeed4a0f7308c7f3862e6812dd843f6fe27f1307cc'
readonly COMPOSE_SHA256_PADRAO_AARCH64='e3afd91588e494ff309fced4ad40c5fa93ababe54c1c2eeffe90865719d8d0db'

# Formatos aceitos.
readonly REGEX_TAG='^[A-Za-z0-9_.-]{1,128}$'
readonly REGEX_TAG_LEGADO='^sha-[0-9a-f]{7}-(dev|staging|production)$'
readonly REGEX_IMAGEM='^[a-z0-9]+([._-][a-z0-9]+)*(\.[a-z0-9-]+)*(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)+$'
readonly REGEX_HOST='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
readonly REGEX_API_URL='^https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?$'
readonly REGEX_IDENT_PG='^[A-Za-z][A-Za-z0-9_]{0,62}$'
readonly REGEX_JWT='^[A-Za-z0-9+/=_.-]+$'
readonly REGEX_REF='^[A-Za-z0-9._/-]{1,100}$'
readonly REGEX_REGIAO='^[a-z]{2}(-[a-z]+)+-[0-9]$'

# Variáveis que o compose interpola. São removidas do ambiente ao chamar o
# `docker compose`, para os containers receberem exatamente o que foi
# validado e gravado no .env (o ambiente do shell teria precedência).
readonly VARS_COMPOSE=(
  RDS_ENDPOINT DB_NAME DB_USER DB_PASSWORD JWT_SECRET APP_ENVIRONMENT
  BACKEND_IMAGE BACKEND_TAG FRONTEND_IMAGE FRONTEND_TAG FRONTEND_URL API_URL
  SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_AUTH SMTP_STARTTLS
  SMTP_FROM PASSWORD_RESET_EXPIRATION_MINUTES COMPOSE_PROFILES
  COMPOSE_PROJECT_NAME COMPOSE_FILE
)

# --------------------------------------------------------------------------- #
# Parâmetros (variáveis de ambiente) e padrões — ver aws/PARAMETERS.md
# --------------------------------------------------------------------------- #
RDS_ENDPOINT="${RDS_ENDPOINT:-}"
DB_NAME="${DB_NAME:-gini}"
DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
JWT_SECRET="${JWT_SECRET:-}"
ALB_DNS="${ALB_DNS:-}"
ALB_NAME="${ALB_NAME:-gini-lb}"
BACKEND_TAG="${BACKEND_TAG:-}"
FRONTEND_TAG="${FRONTEND_TAG:-}"
BACKEND_IMAGE="${BACKEND_IMAGE:-ghcr.io/pi-ams-2025-2026/backend-java}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-ghcr.io/pi-ams-2025-2026/frontend-nextjs}"
APP_ENVIRONMENT="${APP_ENVIRONMENT:-staging}"
ENABLE_MAILPIT="${ENABLE_MAILPIT:-true}"
INFRA_REF="${INFRA_REF:-main}"
COMPOSE_VERSION="${COMPOSE_VERSION:-${COMPOSE_VERSION_PADRAO}}"
COMPOSE_SHA256="${COMPOSE_SHA256:-}"
SMTP_HOST="${SMTP_HOST:-mailpit}"
SMTP_PORT="${SMTP_PORT:-1025}"
SMTP_USERNAME="${SMTP_USERNAME:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_AUTH="${SMTP_AUTH:-false}"
SMTP_STARTTLS="${SMTP_STARTTLS:-false}"
SMTP_FROM="${SMTP_FROM:-noreply@gini.local}"
AWS_REGION="${AWS_REGION:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
DRY_RUN="${DRY_RUN:-0}"

# Derivados (preenchidos durante a validação).
ARQUITETURA=''
ARQ_DOCKER=''
FRONTEND_URL=''
API_URL=''
PERFIS=()
TMP_DIR=''

# --------------------------------------------------------------------------- #
# Utilitários
# --------------------------------------------------------------------------- #
log()    { printf '[%s] [INFO ] %s\n'  "$(date '+%F %T')" "$*"; }
ok()     { printf '[%s] [ OK  ] %s\n'  "$(date '+%F %T')" "$*"; }
ja()     { printf '[%s] [ OK  ] %s (já configurado)\n' "$(date '+%F %T')" "$*"; }
aviso()  { printf '[%s] [AVISO] %s\n'  "$(date '+%F %T')" "$*"; }
erro()   { printf '[%s] [ERRO ] %s\n'  "$(date '+%F %T')" "$*" >&2; }
morrer() { erro "$1"; exit 1; }
etapa()  { printf '\n[%s] ===== %s =====\n' "$(date '+%F %T')" "$*"; }

# Nunca imprime o valor: só o tamanho.
mascarar() { if [[ -n "$1" ]]; then printf '******** (%d caracteres)' "${#1}"; else printf '(vazio)'; fi; }

minusculas() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

limpar() { [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"; return 0; }
trap limpar EXIT

mostrar_ajuda() {
  sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# docker compose do projeto gini-aws, com o ambiente limpo (ver VARS_COMPOSE).
dc() {
  local desfazer=() v
  for v in "${VARS_COMPOSE[@]}"; do desfazer+=(-u "$v"); done
  env "${desfazer[@]}" docker compose \
    --project-directory "${GINI_DIR}" \
    -f "${GINI_DIR}/docker-compose.yml" \
    --env-file "${GINI_DIR}/.env" \
    ${PERFIS[@]+"${PERFIS[@]}"} "$@"
}

# Igual a dc(), mas sempre com o perfil mailpit (para removê-lo quando
# ENABLE_MAILPIT=false).
dc_com_mailpit() {
  local desfazer=() v
  for v in "${VARS_COMPOSE[@]}"; do desfazer+=(-u "$v"); done
  env "${desfazer[@]}" docker compose \
    --project-directory "${GINI_DIR}" \
    -f "${GINI_DIR}/docker-compose.yml" \
    --env-file "${GINI_DIR}/.env" \
    --profile mailpit "$@"
}

# --------------------------------------------------------------------------- #
# 1. Sistema
# --------------------------------------------------------------------------- #
verificar_sistema() {
  ARQUITETURA="$(uname -m)"
  case "${ARQUITETURA}" in
    x86_64)  ARQ_DOCKER='amd64' ;;
    aarch64) ARQ_DOCKER='arm64' ;;
    *)
      if [[ "${DRY_RUN}" == "1" ]]; then
        ARQ_DOCKER='desconhecida'
      else
        morrer "Arquitetura '${ARQUITETURA}' não suportada (use x86_64 ou aarch64)."
      fi ;;
  esac

  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0   # no modo de simulação não exigimos root nem Amazon Linux
  fi

  [[ "${EUID}" -eq 0 ]] || morrer "Execute como root (o user data já roda como root; à mão: sudo -E bash $0)."

  local id='' versao=''
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    # shellcheck disable=SC1091
    versao="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
  fi
  [[ "${id}" == "amzn" && "${versao}" == "2023" ]] \
    || morrer "Sistema '${id} ${versao}' não suportado: use uma AMI Amazon Linux 2023."

  if [[ "${ARQUITETURA}" == "aarch64" ]]; then
    aviso "Instância ARM (aarch64). As imagens do projeto podem ser publicadas só para amd64; nesse caso o pull falha. Prefira t3.small (x86_64)."
  fi
}

configurar_log() {
  [[ "${DRY_RUN}" == "1" ]] && return 0
  touch "${LOG_FILE}"
  chmod 640 "${LOG_FILE}"
  exec > >(tee -a "${LOG_FILE}") 2>&1
  log "Log desta execução também em ${LOG_FILE}."
}

# --------------------------------------------------------------------------- #
# 2. Parâmetros
# --------------------------------------------------------------------------- #
ERROS=()
falha() { ERROS+=("$1"); }

contem_change_me() { [[ "$1" == *CHANGE_ME* ]]; }

validar_senha_db() {
  local p="$1"
  if [[ -z "${p}" ]]; then falha "DB_PASSWORD é obrigatória (gere UMA vez: openssl rand -hex 32)."; return; fi
  contem_change_me "${p}" && { falha "DB_PASSWORD ainda contém CHANGE_ME."; return; }
  (( ${#p} >= 8 && ${#p} <= 128 )) || falha "DB_PASSWORD deve ter de 8 a 128 caracteres (regra do RDS)."
  [[ "${p}" =~ ^[[:print:]]+$ ]] || falha "DB_PASSWORD só pode ter caracteres ASCII imprimíveis."
  case "${p}" in
    *[[:space:]/\'\"@\\\`\$]*)
      falha "DB_PASSWORD não pode conter espaço, / ' \" @ (proibidos pelo RDS) nem \\ \` \$. Use: openssl rand -hex 32" ;;
  esac
}

validar_parametros() {
  # Normalização: hosts em minúsculas (o navegador envia o Origin em
  # minúsculas; o CORS do backend compara a string exata).
  RDS_ENDPOINT="$(minusculas "${RDS_ENDPOINT}")"
  ALB_DNS="$(minusculas "${ALB_DNS}")"
  ALB_DNS="${ALB_DNS%.}"

  # Obrigatórios ---------------------------------------------------------
  if [[ -z "${RDS_ENDPOINT}" ]]; then
    falha "RDS_ENDPOINT é obrigatória (RDS → Bancos de dados → gini-db → Endpoint, sem a porta)."
  elif [[ "${RDS_ENDPOINT}" == *:* ]]; then
    falha "RDS_ENDPOINT não deve ter porta (':5432'); informe só o nome."
  elif [[ ! "${RDS_ENDPOINT}" =~ ${REGEX_HOST} ]] || [[ "${RDS_ENDPOINT}" == *change_me* ]]; then
    falha "RDS_ENDPOINT inválida: '${RDS_ENDPOINT}'."
  fi

  [[ "${DB_NAME}" =~ ${REGEX_IDENT_PG} ]] || falha "DB_NAME inválido: '${DB_NAME}' (letra inicial, letras/dígitos/_ até 63)."
  if [[ -z "${DB_USER}" ]]; then
    falha "DB_USER é obrigatória (usuário principal do RDS)."
  elif [[ ! "${DB_USER}" =~ ${REGEX_IDENT_PG} ]]; then
    falha "DB_USER inválido: '${DB_USER}' (letra inicial, letras/dígitos/_ até 63)."
  fi
  validar_senha_db "${DB_PASSWORD}"

  if [[ -z "${JWT_SECRET}" ]]; then
    falha "JWT_SECRET é obrigatória (gere UMA vez: openssl rand -hex 32; igual nas duas instâncias)."
  elif contem_change_me "${JWT_SECRET}"; then
    falha "JWT_SECRET ainda contém CHANGE_ME."
  elif [[ ! "${JWT_SECRET}" =~ ${REGEX_JWT} ]] || (( ${#JWT_SECRET} < 32 || ${#JWT_SECRET} > 512 )); then
    falha "JWT_SECRET deve ter de 32 a 512 caracteres de [A-Za-z0-9+/=_.-] (ex.: openssl rand -hex 32)."
  fi

  # Imagens e tags --------------------------------------------------------
  [[ "${BACKEND_IMAGE}" =~ ${REGEX_IMAGEM} ]]  || falha "BACKEND_IMAGE inválida (minúsculas, sem tag): '${BACKEND_IMAGE}'."
  [[ "${FRONTEND_IMAGE}" =~ ${REGEX_IMAGEM} ]] || falha "FRONTEND_IMAGE inválida (minúsculas, sem tag): '${FRONTEND_IMAGE}'."
  if [[ -z "${BACKEND_TAG}" ]]; then
    falha "BACKEND_TAG é obrigatória (ex.: sha-a1b2c3d)."
  elif [[ ! "${BACKEND_TAG}" =~ ${REGEX_TAG} ]]; then
    falha "BACKEND_TAG inválida: '${BACKEND_TAG}'."
  fi
  if [[ -z "${FRONTEND_TAG}" ]]; then
    falha "FRONTEND_TAG é obrigatória (imagem única: sha-<7>)."
  elif [[ ! "${FRONTEND_TAG}" =~ ${REGEX_TAG} ]]; then
    falha "FRONTEND_TAG inválida: '${FRONTEND_TAG}'."
  elif [[ "${FRONTEND_TAG}" =~ ${REGEX_TAG_LEGADO} ]]; then
    falha "FRONTEND_TAG '${FRONTEND_TAG}' é do formato LEGADO (URL da API embutida no build de outro ambiente). Use a imagem única: sha-<7>."
  fi
  local tag
  for tag in "${BACKEND_TAG}" "${FRONTEND_TAG}"; do
    case "${tag}" in
      dev|staging|main|latest)
        aviso "Tag mutável '${tag}': pode apontar para imagens diferentes nas duas instâncias (e, no frontend, para uma imagem legado). Prefira sha-<7>." ;;
    esac
  done

  # Ambiente e e-mail ------------------------------------------------------
  case "${APP_ENVIRONMENT}" in
    dev|staging|production) ;;
    *) falha "APP_ENVIRONMENT deve ser dev, staging ou production (padrão: staging)." ;;
  esac
  case "${ENABLE_MAILPIT}" in
    true|false) ;;
    *) falha "ENABLE_MAILPIT deve ser true ou false." ;;
  esac
  if [[ "${ENABLE_MAILPIT}" == "true" ]]; then
    [[ "${APP_ENVIRONMENT}" == "production" ]] \
      && falha "Mailpit é proibido com APP_ENVIRONMENT=production (engoliria e-mails reais — ADR-011)."
    [[ "${SMTP_HOST}" == "mailpit" ]] \
      || falha "Com ENABLE_MAILPIT=true, SMTP_HOST deve ser 'mailpit' (ou desligue o Mailpit)."
  else
    [[ "${SMTP_HOST}" != "mailpit" ]] \
      || falha "Com ENABLE_MAILPIT=false, informe um SMTP real em SMTP_HOST (e SMTP_PORT/AUTH/STARTTLS/USERNAME/PASSWORD/FROM)."
  fi
  if [[ "${SMTP_HOST}" != "mailpit" && ! "$(minusculas "${SMTP_HOST}")" =~ ${REGEX_HOST} ]]; then
    falha "SMTP_HOST inválido: '${SMTP_HOST}'."
  fi
  [[ "${SMTP_PORT}" =~ ^[0-9]{1,5}$ ]] || falha "SMTP_PORT deve ser numérica."
  [[ "${SMTP_AUTH}" == "true" || "${SMTP_AUTH}" == "false" ]] || falha "SMTP_AUTH deve ser true ou false."
  [[ "${SMTP_STARTTLS}" == "true" || "${SMTP_STARTTLS}" == "false" ]] || falha "SMTP_STARTTLS deve ser true ou false."
  [[ "${SMTP_FROM}" =~ ^[^[:space:]\'\"@]+@[^[:space:]\'\"@]+$ ]] || falha "SMTP_FROM deve ser um e-mail (ex.: noreply@gini.local)."
  local campo
  for campo in "${SMTP_USERNAME}" "${SMTP_PASSWORD}"; do
    case "${campo}" in *\'*|*$'\n'*) falha "SMTP_USERNAME/SMTP_PASSWORD não podem conter aspas simples nem quebra de linha." ;; esac
  done
  if [[ "${SMTP_AUTH}" == "true" && ( -z "${SMTP_USERNAME}" || -z "${SMTP_PASSWORD}" ) ]]; then
    falha "Com SMTP_AUTH=true, SMTP_USERNAME e SMTP_PASSWORD são obrigatórias."
  fi

  # Infra do script --------------------------------------------------------
  if [[ ! "${INFRA_REF}" =~ ${REGEX_REF} || "${INFRA_REF}" == *..* ]]; then
    falha "INFRA_REF inválida: '${INFRA_REF}' (tag, branch ou commit)."
  elif [[ "${INFRA_REF}" == "main" ]]; then
    aviso "INFRA_REF=main: aceitável só em laboratório. Fixe uma tag ou commit para que as duas instâncias usem o MESMO compose."
  fi
  [[ "${COMPOSE_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || falha "COMPOSE_VERSION inválida: '${COMPOSE_VERSION}' (formato vX.Y.Z; nunca 'latest')."
  if [[ -n "${COMPOSE_SHA256}" && ! "${COMPOSE_SHA256}" =~ ^[0-9a-f]{64}$ ]]; then
    falha "COMPOSE_SHA256 deve ter 64 caracteres hexadecimais minúsculos."
  fi
  if [[ "${COMPOSE_VERSION}" != "${COMPOSE_VERSION_PADRAO}" && -z "${COMPOSE_SHA256}" ]]; then
    falha "COMPOSE_VERSION diferente da padrão (${COMPOSE_VERSION_PADRAO}) exige COMPOSE_SHA256 da página oficial de releases."
  fi
  if [[ -z "${COMPOSE_SHA256}" && "${COMPOSE_VERSION}" == "${COMPOSE_VERSION_PADRAO}" ]]; then
    case "${ARQUITETURA}" in
      x86_64)  COMPOSE_SHA256="${COMPOSE_SHA256_PADRAO_X86_64}" ;;
      aarch64) COMPOSE_SHA256="${COMPOSE_SHA256_PADRAO_AARCH64}" ;;
    esac
  fi
  if [[ ! "${HEALTH_TIMEOUT}" =~ ^[0-9]+$ ]] || (( HEALTH_TIMEOUT < 30 )); then
    falha "HEALTH_TIMEOUT deve ser um número de segundos >= 30."
  fi
  [[ -z "${AWS_REGION}" || "${AWS_REGION}" =~ ${REGEX_REGIAO} ]] \
    || falha "AWS_REGION inválida: '${AWS_REGION}'."
  if [[ -n "${AWS_REGION}" && "${AWS_REGION}" != "us-east-1" && "${AWS_REGION}" != "us-west-2" ]]; then
    aviso "AWS_REGION=${AWS_REGION}: o Learner Lab costuma permitir só us-east-1 e us-west-2."
  fi
  [[ "${ALB_NAME}" =~ ^[A-Za-z0-9-]{1,32}$ ]] || falha "ALB_NAME inválido: '${ALB_NAME}'."
  if [[ -n "${ALB_DNS}" ]] && { [[ ! "${ALB_DNS}" =~ ${REGEX_HOST} ]] || [[ "${ALB_DNS}" == *change_me* ]]; }; then
    falha "ALB_DNS inválido: '${ALB_DNS}' (só o nome DNS, sem http:// e sem porta)."
  fi

  # Placeholder esquecido em qualquer parâmetro (os segredos já foram
  # tratados acima, com mensagem própria).
  local nome valor
  for nome in DB_NAME DB_USER BACKEND_TAG FRONTEND_TAG BACKEND_IMAGE FRONTEND_IMAGE \
              INFRA_REF ALB_NAME SMTP_HOST SMTP_FROM SMTP_USERNAME AWS_REGION; do
    valor="${!nome}"
    if [[ "$(minusculas "${valor}")" == *change_me* ]]; then
      falha "${nome} ainda contém CHANGE_ME."
    fi
  done

  if (( ${#ERROS[@]} > 0 )); then
    erro "Parâmetros inválidos (${#ERROS[@]}):"
    local e
    for e in "${ERROS[@]}"; do erro "  - ${e}"; done
    erro "Contrato completo: aws/PARAMETERS.md. Ajuda: bash $0 --help"
    exit 1
  fi
  ok "Parâmetros válidos."
}

# Região: parâmetro ou metadados da instância (IMDSv2).
descobrir_regiao() {
  [[ -n "${AWS_REGION}" ]] && return 0
  local token
  token="$(curl -fsS --max-time 5 -X PUT 'http://169.254.169.254/latest/api/token' \
             -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')" \
    || morrer "Não foi possível ler os metadados da instância; defina AWS_REGION."
  AWS_REGION="$(curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: ${token}" \
                 'http://169.254.169.254/latest/meta-data/placement/region')" \
    || morrer "Não foi possível descobrir a região; defina AWS_REGION."
  [[ "${AWS_REGION}" =~ ${REGEX_REGIAO} ]] || morrer "Região inesperada nos metadados: '${AWS_REGION}'."
  log "Região (metadados da instância): ${AWS_REGION}."
}

# DNS do ALB: parâmetro ou API do ELB (usa a credencial do LabInstanceProfile).
descobrir_alb_dns() {
  if [[ -n "${ALB_DNS}" ]]; then
    log "ALB_DNS informado: ${ALB_DNS}."
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "ALB_DNS ausente: seria descoberto com 'aws elbv2 describe-load-balancers --names ${ALB_NAME}'."
    return 0
  fi
  command -v aws >/dev/null 2>&1 || morrer "ALB_DNS ausente e AWS CLI indisponível. Informe ALB_DNS."
  descobrir_regiao

  local tentativa dns='' max=20
  for (( tentativa = 1; tentativa <= max; tentativa++ )); do
    if dns="$(aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
                --names "${ALB_NAME}" --query 'LoadBalancers[0].DNSName' \
                --output text 2>/dev/null)" \
       && [[ -n "${dns}" && "${dns}" != "None" ]]; then
      break
    fi
    dns=''
    log "ALB '${ALB_NAME}' ainda não encontrado (tentativa ${tentativa}/${max}); nova tentativa em 15 s."
    sleep 15
  done
  [[ -n "${dns}" ]] || morrer "Não foi possível descobrir o DNS do ALB '${ALB_NAME}' em ${AWS_REGION}. Confira se o ALB existe (crie-o ANTES das instâncias), se a instância usa o LabInstanceProfile, ou informe ALB_DNS."
  ALB_DNS="$(minusculas "${dns}")"
  [[ "${ALB_DNS}" =~ ${REGEX_HOST} ]] || morrer "DNS do ALB inesperado: '${ALB_DNS}'."
  ok "DNS do ALB descoberto: ${ALB_DNS}."
}

derivar_urls() {
  local host="${ALB_DNS:-<DNS-do-ALB-${ALB_NAME}>}"
  FRONTEND_URL="http://${host}"
  API_URL="http://${host}:8080"
  if [[ -n "${ALB_DNS}" ]]; then
    [[ "${API_URL}" =~ ${REGEX_API_URL} && "${FRONTEND_URL}" =~ ${REGEX_API_URL} ]] \
      || morrer "URLs derivadas do ALB fora do formato esperado: ${FRONTEND_URL} / ${API_URL}."
  fi
  if [[ "${ENABLE_MAILPIT}" == "true" ]]; then PERFIS=(--profile mailpit); else PERFIS=(); fi
}

imprimir_plano() {
  etapa "Plano"
  cat <<EOF
  Instância
    arquitetura ............ ${ARQUITETURA} (imagens ${ARQ_DOCKER})
    diretório .............. ${GINI_DIR} (750) com docker-compose.yml e .env (600)
    compose plugin ......... ${COMPOSE_VERSION} em ${COMPOSE_PLUGIN_DIR} (SHA-256 ${COMPOSE_SHA256:-<ver arquitetura>})
    compose da AWS ......... ${REPO_RAW_BASE}/${INFRA_REF}/aws/docker-compose.aws.yml (ou cópia local)
  Aplicação
    backend ................ ${BACKEND_IMAGE}:${BACKEND_TAG}
    frontend ............... ${FRONTEND_IMAGE}:${FRONTEND_TAG} (exige rótulo ${ROTULO_RUNTIME_API_URL}=true)
    APP_ENVIRONMENT ........ ${APP_ENVIRONMENT}
    FRONTEND_URL ........... ${FRONTEND_URL}
    API_URL ................ ${API_URL}
    Mailpit ................ ${ENABLE_MAILPIT}
  Banco (RDS)
    endpoint ............... ${RDS_ENDPOINT}:5432 / banco ${DB_NAME} / usuário ${DB_USER}
    senha .................. $(mascarar "${DB_PASSWORD}")
  Segredos
    JWT_SECRET ............. $(mascarar "${JWT_SECRET}")
    SMTP_PASSWORD .......... $(mascarar "${SMTP_PASSWORD}")
  Etapas
    1. instalar/habilitar Docker (dnf) e o compose plugin fixado
    2. gravar compose e .env em ${GINI_DIR} (só se mudaram)
    3. docker compose pull; testar RDS (pg_isready); conferir rótulo do frontend
    4. docker compose up -d (recria só o que mudou); esperar healthy (${HEALTH_TIMEOUT} s)
    5. testar http://127.0.0.1:8080/actuator/health e http://127.0.0.1:3000/api/health
EOF
}

# --------------------------------------------------------------------------- #
# 3. Docker e compose plugin
# --------------------------------------------------------------------------- #
instalar_docker() {
  etapa "Docker"
  if rpm -q docker >/dev/null 2>&1; then
    ja "Pacote docker instalado"
  else
    log "Instalando o pacote docker (dnf)..."
    dnf install -y docker
    ok "Pacote docker instalado."
  fi
  command -v curl >/dev/null 2>&1 || dnf install -y curl-minimal

  if systemctl is-enabled --quiet docker && systemctl is-active --quiet docker; then
    ja "Serviço docker habilitado no boot e ativo"
  else
    systemctl enable --now docker
    ok "Serviço docker habilitado no boot e iniciado."
  fi
}

instalar_compose_plugin() {
  etapa "Docker Compose plugin"
  local desejada="${COMPOSE_VERSION#v}" atual=''
  atual="$(docker compose version --short 2>/dev/null || true)"
  atual="${atual#v}"
  if [[ "${atual}" == "${desejada}" ]]; then
    ja "docker compose ${COMPOSE_VERSION}"
    return 0
  fi
  [[ -n "${atual}" ]] && log "docker compose atual: v${atual}; instalando ${COMPOSE_VERSION}."

  local url="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARQUITETURA}"
  curl -fsSL --retry 5 --retry-delay 3 -o "${TMP_DIR}/docker-compose" "${url}" \
    || morrer "Falha ao baixar ${url}."
  printf '%s  %s\n' "${COMPOSE_SHA256}" "${TMP_DIR}/docker-compose" | sha256sum -c --quiet - \
    || morrer "SHA-256 do compose plugin NÃO confere. Download descartado."
  install -d -m 755 "${COMPOSE_PLUGIN_DIR}"
  install -m 755 "${TMP_DIR}/docker-compose" "${COMPOSE_PLUGIN_DIR}/docker-compose"
  ok "docker compose $(docker compose version --short) instalado (checksum conferido)."
}

# --------------------------------------------------------------------------- #
# 4. Arquivos em /opt/gini/aws
# --------------------------------------------------------------------------- #
# instalar_se_mudou <origem> <destino> <modo> <descrição>
instalar_se_mudou() {
  local origem="$1" destino="$2" modo="$3" descricao="$4"
  if [[ -f "${destino}" ]] && cmp -s "${origem}" "${destino}"; then
    chmod "${modo}" "${destino}"
    ja "${descricao} sem mudanças"
  else
    install -m "${modo}" -o root -g root "${origem}" "${destino}"
    ok "${descricao} gravado em ${destino}."
  fi
}

preparar_diretorio() {
  etapa "Arquivos da aplicação"
  install -d -m 755 /opt/gini
  if [[ -d "${GINI_DIR}" ]]; then
    chmod 750 "${GINI_DIR}"
    ja "Diretório ${GINI_DIR}"
  else
    install -d -m 750 "${GINI_DIR}"
    ok "Diretório ${GINI_DIR} criado."
  fi
}

obter_compose() {
  local dir_script local_compose novo="${TMP_DIR}/docker-compose.yml"
  dir_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local_compose="${dir_script}/docker-compose.aws.yml"

  if [[ -f "${local_compose}" ]]; then
    log "Usando a cópia local: ${local_compose}."
    cp "${local_compose}" "${novo}"
  else
    local url="${REPO_RAW_BASE}/${INFRA_REF}/aws/docker-compose.aws.yml"
    log "Baixando ${url}"
    curl -fsSL --retry 5 --retry-delay 3 -o "${novo}" "${url}" \
      || morrer "Falha ao baixar o compose de ${url}. Confira INFRA_REF (o arquivo precisa existir nessa referência do GitHub)."
  fi
  grep -q '^name: gini-aws$' "${novo}" \
    || morrer "O arquivo obtido não parece ser o aws/docker-compose.aws.yml (sem 'name: gini-aws')."
  instalar_se_mudou "${novo}" "${GINI_DIR}/docker-compose.yml" 640 "docker-compose.yml"
}

gerar_env() {
  local novo="${TMP_DIR}/env"
  # Valores entre aspas simples: o Compose os lê de forma literal (sem
  # interpolar $). A validação garante que nenhum contém aspas simples.
  (
    umask 077
    {
      printf '# Gerado por aws/bootstrap-ec2.sh — NÃO versionar. Reexecute o bootstrap para alterar.\n'
      printf "BACKEND_IMAGE='%s'\n"   "${BACKEND_IMAGE}"
      printf "BACKEND_TAG='%s'\n"     "${BACKEND_TAG}"
      printf "FRONTEND_IMAGE='%s'\n"  "${FRONTEND_IMAGE}"
      printf "FRONTEND_TAG='%s'\n"    "${FRONTEND_TAG}"
      printf "APP_ENVIRONMENT='%s'\n" "${APP_ENVIRONMENT}"
      printf "RDS_ENDPOINT='%s'\n"    "${RDS_ENDPOINT}"
      printf "DB_NAME='%s'\n"         "${DB_NAME}"
      printf "DB_USER='%s'\n"         "${DB_USER}"
      printf "DB_PASSWORD='%s'\n"     "${DB_PASSWORD}"
      printf "JWT_SECRET='%s'\n"      "${JWT_SECRET}"
      printf "FRONTEND_URL='%s'\n"    "${FRONTEND_URL}"
      printf "API_URL='%s'\n"         "${API_URL}"
      if [[ "${ENABLE_MAILPIT}" == "true" ]]; then
        printf "COMPOSE_PROFILES='mailpit'\n"
      fi
      printf "SMTP_HOST='%s'\n"       "${SMTP_HOST}"
      printf "SMTP_PORT='%s'\n"       "${SMTP_PORT}"
      printf "SMTP_AUTH='%s'\n"       "${SMTP_AUTH}"
      printf "SMTP_STARTTLS='%s'\n"   "${SMTP_STARTTLS}"
      printf "SMTP_USERNAME='%s'\n"   "${SMTP_USERNAME}"
      printf "SMTP_PASSWORD='%s'\n"   "${SMTP_PASSWORD}"
      printf "SMTP_FROM='%s'\n"       "${SMTP_FROM}"
    } > "${novo}"
  )
  instalar_se_mudou "${novo}" "${GINI_DIR}/.env" 600 ".env (segredos não exibidos)"
}

# --------------------------------------------------------------------------- #
# 5. Imagens e pré-checagens
# --------------------------------------------------------------------------- #
baixar_imagens() {
  etapa "Imagens"
  if ! dc pull --quiet; then
    erro "Falha no 'docker compose pull'. Causas comuns: tag inexistente no ghcr.io, sem saída para a internet (a instância precisa de IP público na sub-rede pública: não há NAT), ou imagem sem variante ${ARQ_DOCKER}."
    exit 1
  fi
  ok "Imagens baixadas (as já presentes não são baixadas de novo)."

  local img arq
  for img in "${BACKEND_IMAGE}:${BACKEND_TAG}" "${FRONTEND_IMAGE}:${FRONTEND_TAG}"; do
    arq="$(docker image inspect --format '{{.Architecture}}' -- "${img}")"
    [[ "${arq}" == "${ARQ_DOCKER}" ]] \
      || morrer "Imagem ${img} é ${arq}, mas a instância é ${ARQ_DOCKER}. Use uma instância x86_64 (ex.: t3.small)."
  done
}

verificar_rotulo_frontend() {
  local img="${FRONTEND_IMAGE}:${FRONTEND_TAG}" rotulos
  rotulos="$(docker image inspect \
               --format '{{ range $k, $v := .Config.Labels }}{{ $k }}={{ $v }}{{ "\n" }}{{ end }}' \
               -- "${img}")" || morrer "Não foi possível inspecionar ${img}."
  if printf '%s\n' "${rotulos}" | grep -qxF -- "${ROTULO_RUNTIME_API_URL}=true"; then
    ok "Frontend ${FRONTEND_TAG} é a imagem única (rótulo ${ROTULO_RUNTIME_API_URL}=true): API_URL será aplicada."
  else
    erro "A imagem ${img} NÃO tem o rótulo ${ROTULO_RUNTIME_API_URL}=true."
    erro "Ela é uma imagem antiga (legado), com a URL da API embutida no build: API_URL=${API_URL} seria IGNORADA e o navegador chamaria a API errada."
    erro "Use a tag sha-<7> de um commit publicado depois da Fase A do frontend (ADR-012)."
    exit 1
  fi
}

testar_rds() {
  etapa "Conectividade com o RDS"
  local tentativa max=20 rc
  for (( tentativa = 1; tentativa <= max; tentativa++ )); do
    rc=0
    docker run --rm "${IMAGEM_PG_ISREADY}" \
      pg_isready -h "${RDS_ENDPOINT}" -p 5432 -t 5 >/dev/null 2>&1 || rc=$?
    if (( rc == 0 )); then
      ok "RDS ${RDS_ENDPOINT}:5432 aceitando conexões."
      return 0
    fi
    log "RDS ainda não responde (pg_isready=${rc}, tentativa ${tentativa}/${max}); nova tentativa em 15 s."
    sleep 15
  done
  erro "O RDS ${RDS_ENDPOINT}:5432 não respondeu."
  erro "Confira: RDS com status 'Disponível'; gini-sg-bd com entrada 5432 vinda de gini-sg-ec2; instância e RDS na mesma VPC (gini-vpc)."
  exit 1
}

# --------------------------------------------------------------------------- #
# 6. Subida e saúde
# --------------------------------------------------------------------------- #
status_servico() {
  local id
  id="$(dc ps -q "$1" 2>/dev/null || true)"
  [[ -n "${id}" ]] || { printf 'ausente'; return 0; }
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${id}" 2>/dev/null \
    || printf 'ausente'
}

falhar_com_logs() {
  erro "$1"
  erro "Últimas 100 linhas de log dos containers:"
  dc logs --no-color --tail=100 >&2 || true
  dc ps >&2 || true
  exit 1
}

subir_aplicacao() {
  etapa "Containers"
  if [[ "${ENABLE_MAILPIT}" != "true" ]]; then
    # Desligar o Mailpit numa reexecução: remove o container, se existir.
    dc_com_mailpit rm --stop --force mailpit >/dev/null 2>&1 || true
  fi
  # `up -d` só recria o que mudou (imagem, variáveis ou definição);
  # o resto fica como está.
  dc up -d --remove-orphans
}

aguardar_saude() {
  etapa "Saúde (até ${HEALTH_TIMEOUT} s)"
  local inicio=${SECONDS} be fe
  while :; do
    be="$(status_servico backend)"
    fe="$(status_servico frontend)"
    if [[ "${be}" == "healthy" && "${fe}" == "healthy" ]]; then
      ok "backend e frontend healthy."
      break
    fi
    if (( SECONDS - inicio >= HEALTH_TIMEOUT )); then
      falhar_com_logs "Tempo esgotado: backend=${be}, frontend=${fe}."
    fi
    log "Aguardando: backend=${be}, frontend=${fe}."
    sleep 10
  done

  curl -fsS --max-time 10 -o /dev/null http://127.0.0.1:8080/actuator/health \
    || falhar_com_logs "http://127.0.0.1:8080/actuator/health não respondeu 2xx."
  ok "Backend responde em http://127.0.0.1:8080/actuator/health."
  curl -fsS --max-time 10 -o /dev/null http://127.0.0.1:3000/api/health \
    || falhar_com_logs "http://127.0.0.1:3000/api/health não respondeu 2xx."
  ok "Frontend responde em http://127.0.0.1:3000/api/health."

  if [[ "${ENABLE_MAILPIT}" == "true" ]]; then
    local mp
    mp="$(status_servico mailpit)"
    if [[ "${mp}" == "healthy" || "${mp}" == "starting" ]]; then
      ok "Mailpit: ${mp}."
    else
      aviso "Mailpit: ${mp}. O e-mail de recuperação não será capturado (a aplicação segue no ar)."
    fi
  fi
}

# --------------------------------------------------------------------------- #
# 7. Resumo
# --------------------------------------------------------------------------- #
resumo() {
  etapa "Resumo"
  cat <<EOF
  Frontend (navegador) ... ${FRONTEND_URL}
  API (navegador) ........ ${API_URL}
  Backend ................ ${BACKEND_IMAGE}:${BACKEND_TAG}
  Frontend ............... ${FRONTEND_IMAGE}:${FRONTEND_TAG}
  Ambiente ............... ${APP_ENVIRONMENT} (Mailpit: ${ENABLE_MAILPIT})
  Arquivos ............... ${GINI_DIR}/docker-compose.yml e ${GINI_DIR}/.env
  Log .................... ${LOG_FILE}

  As URLs só respondem depois que ESTA instância estiver registrada e
  'healthy' nos Target Groups gini-tg-frontend e gini-tg-backend.
EOF
  dc ps
}

# --------------------------------------------------------------------------- #
# Principal
# --------------------------------------------------------------------------- #
main() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      -h|--help) mostrar_ajuda; exit 0 ;;
      *) morrer "Argumento desconhecido: '$1'. Os parâmetros são variáveis de ambiente (veja --help)." ;;
    esac
  fi
  [[ "${DRY_RUN}" == "0" || "${DRY_RUN}" == "1" ]] || morrer "DRY_RUN deve ser 0 ou 1."

  verificar_sistema
  configurar_log
  etapa "Bootstrap Gini na AWS$([[ "${DRY_RUN}" == "1" ]] && printf ' (DRY_RUN: nada será alterado)')"
  validar_parametros
  descobrir_alb_dns
  derivar_urls

  if [[ "${DRY_RUN}" == "1" ]]; then
    imprimir_plano
    ok "DRY_RUN concluído: parâmetros válidos, nenhuma alteração feita."
    exit 0
  fi

  TMP_DIR="$(mktemp -d)"
  imprimir_plano
  instalar_docker
  instalar_compose_plugin
  preparar_diretorio
  obter_compose
  gerar_env
  baixar_imagens
  verificar_rotulo_frontend
  testar_rds
  subir_aplicacao
  aguardar_saude
  resumo
  ok "Bootstrap concluído."
}

main "$@"
