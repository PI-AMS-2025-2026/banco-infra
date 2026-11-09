#!/usr/bin/env bash
#
# restore-db.sh — Restaura um dump do PostgreSQL em um ambiente.
#
# OPERAÇÃO DESTRUTIVA: `pg_restore --clean --if-exists` APAGA os objetos atuais
# do banco antes de recriá-los. Exige a flag --yes para executar.
#
# Uso:
#   ./scripts/restore-db.sh <dev|staging|production> <arquivo.dump> --yes
#
# Exemplo:
#   ./scripts/restore-db.sh dev /opt/gini/backups/dev/dev-20261008-030000.dump --yes
#
# Sequência: valida o dump -> para o frontend e o backend -> pg_restore ->
# sobe o backend e o frontend -> confere o healthcheck.
#
# ANTES DE RESTAURAR EM PRODUÇÃO, valide o dump em um banco temporário
# descartável (procedimento completo em docs/runbook.md, seção
# "Validar um dump sem tocar no ambiente"):
#
#   docker run -d --name gini-teste-restore \
#     -e POSTGRES_PASSWORD=teste -e POSTGRES_USER=gini -e POSTGRES_DB=gini \
#     postgres:17-alpine
#   docker exec -i gini-teste-restore pg_restore --clean --if-exists \
#     -U gini -d gini < meu.dump
#   docker rm -f gini-teste-restore
#
# Variáveis de ambiente opcionais:
#   GINI_ROOT       padrão /opt/gini
#   HEALTH_TIMEOUT  segundos de espera pelo backend após o restore (padrão 180)
#
set -euo pipefail

GINI_ROOT="${GINI_ROOT:-/opt/gini}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
AMBIENTES_VALIDOS=(dev staging production)

log()   { printf '\033[0;34m[INFO ]\033[0m %s\n' "$*"; }
ok()    { printf '\033[0;32m[ OK  ]\033[0m %s\n' "$*"; }
aviso() { printf '\033[0;33m[AVISO]\033[0m %s\n' "$*"; }
erro()  { printf '\033[0;31m[ERRO ]\033[0m %s\n' "$*" >&2; }
morrer() { erro "$1"; exit 1; }

uso() {
  erro "Uso: $0 <dev|staging|production> <arquivo.dump> --yes"
  exit 2
}

# Lê uma variável do arquivo KEY=VALUE sem executá-lo.
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
# Argumentos
# --------------------------------------------------------------------------- #
ENV_NAME=""
ARQUIVO_DUMP=""
CONFIRMADO=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) CONFIRMADO=1; shift ;;
    -h|--help) uso ;;
    -*) morrer "Opção desconhecida: '$1'." ;;
    *)
      if   [[ -z "${ENV_NAME}" ]];      then ENV_NAME="$1"
      elif [[ -z "${ARQUIVO_DUMP}" ]];  then ARQUIVO_DUMP="$1"
      else morrer "Argumento extra inesperado: '$1'."
      fi
      shift
      ;;
  esac
done

[[ -n "${ENV_NAME}" && -n "${ARQUIVO_DUMP}" ]] || uso

if ! printf '%s\n' "${AMBIENTES_VALIDOS[@]}" | grep -qx -- "${ENV_NAME}"; then
  morrer "Ambiente inválido: '${ENV_NAME}'. Use um de: ${AMBIENTES_VALIDOS[*]}"
fi

if [[ "${CONFIRMADO}" -ne 1 ]]; then
  erro "Operação DESTRUTIVA: o banco de '${ENV_NAME}' será sobrescrito."
  erro "Nada foi alterado. Repita o comando com --yes para confirmar:"
  erro "  $0 ${ENV_NAME} ${ARQUIVO_DUMP} --yes"
  exit 3
fi

[[ -f "${ARQUIVO_DUMP}" ]] || morrer "Arquivo de dump não encontrado: ${ARQUIVO_DUMP}"
[[ -s "${ARQUIVO_DUMP}" ]] || morrer "Arquivo de dump está vazio: ${ARQUIVO_DUMP}"

DIRETORIO_AMBIENTE="${GINI_ROOT}/${ENV_NAME}"
ARQUIVO_ENV="${DIRETORIO_AMBIENTE}/.env"
PROJETO_COMPOSE="gini-${ENV_NAME}"

[[ -f "${ARQUIVO_ENV}" ]] || morrer "${ARQUIVO_ENV} não encontrado."
[[ -f "${DIRETORIO_AMBIENTE}/images.env" ]] || morrer "${DIRETORIO_AMBIENTE}/images.env não encontrado."
[[ -f "${DIRETORIO_AMBIENTE}/docker-compose.yml" ]] || morrer "${DIRETORIO_AMBIENTE}/docker-compose.yml não encontrado."

if [[ ! "${HEALTH_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  morrer "HEALTH_TIMEOUT inválido: '${HEALTH_TIMEOUT}'."
fi

POSTGRES_USER="$(ler_variavel_env "${ARQUIVO_ENV}" POSTGRES_USER)"
POSTGRES_DB="$(ler_variavel_env "${ARQUIVO_ENV}" POSTGRES_DB)"
BACKEND_PORT="$(ler_variavel_env "${ARQUIVO_ENV}" BACKEND_PORT)"

[[ -n "${POSTGRES_USER}" && -n "${POSTGRES_DB}" ]] \
  || morrer "POSTGRES_USER/POSTGRES_DB ausentes em ${ARQUIVO_ENV}."

compose() {
  docker compose -p "${PROJETO_COMPOSE}" \
    --env-file "${ARQUIVO_ENV}" \
    --env-file "${DIRETORIO_AMBIENTE}/images.env" \
    -f "${DIRETORIO_AMBIENTE}/docker-compose.yml" "$@"
}

# --------------------------------------------------------------------------- #
# 1. Validar o dump antes de derrubar qualquer coisa
# --------------------------------------------------------------------------- #
log "Ambiente ...: ${ENV_NAME} (${PROJETO_COMPOSE})"
log "Dump .......: ${ARQUIVO_DUMP}"
log "Banco ......: ${POSTGRES_DB} (usuário ${POSTGRES_USER})"
printf '\n'

[[ -n "$(compose ps --quiet db 2>/dev/null)" ]] \
  || morrer "container 'db' não está em execução; suba o ambiente antes de restaurar."

log "Validando o dump com pg_restore --list..."
if ! compose exec -T db sh -c '
      set -e
      cat > /tmp/gini-restore-verificacao.dump
      pg_restore --list /tmp/gini-restore-verificacao.dump > /dev/null
      rm -f /tmp/gini-restore-verificacao.dump
    ' < "${ARQUIVO_DUMP}"; then
  morrer "o arquivo informado não é um dump válido; nada foi alterado."
fi
ok "dump válido"

# --------------------------------------------------------------------------- #
# 2. Parar o que escreve no banco
# Frontend sai junto para não servir páginas durante a janela de restore.
# --------------------------------------------------------------------------- #
log "Parando frontend e backend..."
compose stop frontend backend
ok "aplicações paradas (o banco segue de pé)"

# --------------------------------------------------------------------------- #
# 3. Restaurar
# --------------------------------------------------------------------------- #
log "Restaurando (pg_restore --clean --if-exists)..."
# --clean --if-exists: remove os objetos existentes sem reclamar dos ausentes.
# --no-owner/--no-privileges: o dono é sempre o usuário do ambiente.
# pg_restore pode sair != 0 por avisos não fatais; tratamos abaixo.
CODIGO_RESTORE=0
compose exec -T db \
  pg_restore --clean --if-exists --no-owner --no-privileges \
             --exit-on-error \
             -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  < "${ARQUIVO_DUMP}" || CODIGO_RESTORE=$?

if [[ "${CODIGO_RESTORE}" -ne 0 ]]; then
  erro "pg_restore terminou com código ${CODIGO_RESTORE}."
  aviso "O banco pode estar em estado inconsistente. Subindo as aplicações para diagnóstico;"
  aviso "considere restaurar um dump anterior ou recriar o volume."
  compose up -d backend frontend || true
  exit 1
fi
ok "restore concluído"

# --------------------------------------------------------------------------- #
# 4. Subir as aplicações
# --------------------------------------------------------------------------- #
log "Subindo backend e frontend..."
compose up -d backend frontend

# --------------------------------------------------------------------------- #
# 5. Checagem de saúde
# --------------------------------------------------------------------------- #
log "Aguardando saúde do backend (timeout ${HEALTH_TIMEOUT}s)..."
LIMITE=$((SECONDS + HEALTH_TIMEOUT))
SAUDAVEL=0
while [[ "${SECONDS}" -lt "${LIMITE}" ]]; do
  ESTADO="$(compose ps --format '{{.Service}} {{.Health}}' 2>/dev/null \
            | awk '$1=="backend"{print $2}')"
  if [[ "${ESTADO}" == "healthy" ]]; then
    SAUDAVEL=1
    break
  fi
  sleep 5
done

if [[ "${SAUDAVEL}" -ne 1 ]]; then
  erro "backend não ficou saudável após o restore."
  compose logs --tail=100 backend || true
  exit 1
fi
ok "backend saudável"

if [[ -n "${BACKEND_PORT}" ]] && command -v curl >/dev/null; then
  if curl -fsS --max-time 10 "http://127.0.0.1:${BACKEND_PORT}/actuator/health" >/dev/null; then
    ok "GET /actuator/health respondeu na porta ${BACKEND_PORT}"
  else
    aviso "não foi possível validar /actuator/health na porta ${BACKEND_PORT}."
  fi
fi

printf '\n'
ok "Restore de '${ENV_NAME}' concluído a partir de $(basename "${ARQUIVO_DUMP}")."
aviso "Confira a versão do schema: se o dump é anterior a migrations recentes, o"
aviso "Flyway reaplicará o que faltar no próximo start do backend."
