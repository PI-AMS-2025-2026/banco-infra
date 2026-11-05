#!/usr/bin/env bash
#
# backup-db.sh — Gera um dump do PostgreSQL de um ambiente, valida o arquivo e
# aplica a política de retenção.
#
# Uso:
#   ./scripts/backup-db.sh <dev|staging|production>
#
# É chamado:
#   - automaticamente antes de cada deploy (scripts/deploy.sh);
#   - diariamente às 03:00 pelo timer systemd gini-backup@<env>.timer.
#
# Saída: /opt/gini/backups/<env>/<env>-AAAAMMDD-HHMMSS.dump  (formato custom
# do pg_dump, modo 600). Restauração: scripts/restore-db.sh
#
# Variáveis de ambiente opcionais:
#   BACKUP_RETENTION_DAYS  dias de retenção (padrão 7; o .env do ambiente tem
#                          precedência sobre o padrão, e um valor exportado no
#                          ambiente do processo tem precedência sobre o .env).
#   GINI_ROOT              padrão /opt/gini
#
set -euo pipefail

GINI_ROOT="${GINI_ROOT:-/opt/gini}"
AMBIENTES_VALIDOS=(dev staging production)

log()   { printf '\033[0;34m[INFO ]\033[0m %s\n' "$*"; }
ok()    { printf '\033[0;32m[ OK  ]\033[0m %s\n' "$*"; }
aviso() { printf '\033[0;33m[AVISO]\033[0m %s\n' "$*"; }
erro()  { printf '\033[0;31m[ERRO ]\033[0m %s\n' "$*" >&2; }
morrer() { erro "$1"; exit 1; }

# --------------------------------------------------------------------------- #
# Lê uma única variável de um arquivo no formato KEY=VALUE.
# Preferimos isso a `source`: o .env não é código e não deve ser executado.
# Uso: ler_variavel_env <arquivo> <CHAVE>
# --------------------------------------------------------------------------- #
ler_variavel_env() {
  local arquivo="$1" chave="$2" valor
  valor="$(grep -E "^[[:space:]]*${chave}=" "${arquivo}" | tail -n1 | cut -d= -f2-)" || true
  # Remove espaços nas pontas e aspas simples/duplas envolventes.
  valor="${valor#"${valor%%[![:space:]]*}"}"
  valor="${valor%"${valor##*[![:space:]]}"}"
  valor="${valor%\"}"; valor="${valor#\"}"
  valor="${valor%\'}"; valor="${valor#\'}"
  printf '%s' "${valor}"
}

# --------------------------------------------------------------------------- #
# Validações
# --------------------------------------------------------------------------- #
ENV_NAME="${1:-}"

[[ -n "${ENV_NAME}" ]] || morrer "Informe o ambiente: $0 <dev|staging|production>"

if ! printf '%s\n' "${AMBIENTES_VALIDOS[@]}" | grep -qx -- "${ENV_NAME}"; then
  morrer "Ambiente inválido: '${ENV_NAME}'. Use um de: ${AMBIENTES_VALIDOS[*]}"
fi

DIRETORIO_AMBIENTE="${GINI_ROOT}/${ENV_NAME}"
DIRETORIO_BACKUPS="${GINI_ROOT}/backups/${ENV_NAME}"
ARQUIVO_ENV="${DIRETORIO_AMBIENTE}/.env"
PROJETO_COMPOSE="gini-${ENV_NAME}"

[[ -f "${ARQUIVO_ENV}" ]] || morrer "${ARQUIVO_ENV} não encontrado. Veja docs/runbook.md."
[[ -d "${DIRETORIO_BACKUPS}" ]] \
  || morrer "${DIRETORIO_BACKUPS} não existe. Rode scripts/bootstrap-server.sh."

command -v docker >/dev/null || morrer "docker não encontrado no PATH."

POSTGRES_USER="$(ler_variavel_env "${ARQUIVO_ENV}" POSTGRES_USER)"
POSTGRES_DB="$(ler_variavel_env "${ARQUIVO_ENV}" POSTGRES_DB)"

[[ -n "${POSTGRES_USER}" ]] || morrer "POSTGRES_USER ausente em ${ARQUIVO_ENV}."
[[ -n "${POSTGRES_DB}"   ]] || morrer "POSTGRES_DB ausente em ${ARQUIVO_ENV}."

# Precedência: variável exportada > .env do ambiente > padrão 7.
if [[ -z "${BACKUP_RETENTION_DAYS:-}" ]]; then
  BACKUP_RETENTION_DAYS="$(ler_variavel_env "${ARQUIVO_ENV}" BACKUP_RETENTION_DAYS)"
fi
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"

if [[ ! "${BACKUP_RETENTION_DAYS}" =~ ^[0-9]+$ ]]; then
  morrer "BACKUP_RETENTION_DAYS inválido: '${BACKUP_RETENTION_DAYS}' (esperado inteiro)."
fi

# --------------------------------------------------------------------------- #
# Atalho para o compose do ambiente
# --------------------------------------------------------------------------- #
compose() {
  docker compose -p "${PROJETO_COMPOSE}" \
    --env-file "${ARQUIVO_ENV}" \
    --env-file "${DIRETORIO_AMBIENTE}/images.env" \
    -f "${DIRETORIO_AMBIENTE}/docker-compose.yml" "$@"
}

# O `db` é o único serviço necessário para o backup; se images.env não existir,
# o compose falharia por causa de FRONTEND_TAG/BACKEND_TAG obrigatórios. Como o
# deploy.sh garante o arquivo antes de chamar este script, apenas validamos.
[[ -f "${DIRETORIO_AMBIENTE}/images.env" ]] \
  || morrer "${DIRETORIO_AMBIENTE}/images.env não encontrado — o ambiente nunca foi implantado."
[[ -f "${DIRETORIO_AMBIENTE}/docker-compose.yml" ]] \
  || morrer "${DIRETORIO_AMBIENTE}/docker-compose.yml não encontrado — rode um deploy primeiro."

# --------------------------------------------------------------------------- #
# 1. O container do banco precisa estar rodando
# --------------------------------------------------------------------------- #
log "Verificando o container 'db' do ambiente '${ENV_NAME}'..."
if [[ -z "$(compose ps --quiet db 2>/dev/null)" ]]; then
  morrer "container 'db' de ${PROJETO_COMPOSE} não está em execução; backup abortado."
fi
ok "container 'db' em execução"

# --------------------------------------------------------------------------- #
# 2. Dump
# --------------------------------------------------------------------------- #
ESTAMPA="$(date +%Y%m%d-%H%M%S)"
ARQUIVO_DUMP="${DIRETORIO_BACKUPS}/${ENV_NAME}-${ESTAMPA}.dump"
ARQUIVO_PARCIAL="${ARQUIVO_DUMP}.parcial"

# Remove o arquivo parcial se o script morrer no meio: um dump truncado é pior
# do que nenhum dump, porque passa a impressão de que existe backup.
limpar_parcial() { rm -f "${ARQUIVO_PARCIAL}"; }
trap limpar_parcial EXIT

log "Gerando dump de '${POSTGRES_DB}' em ${ARQUIVO_DUMP}..."
# -Fc: formato custom (comprimido, restaurável seletivamente com pg_restore).
# exec -T: sem TTY, obrigatório para não corromper a saída binária.
umask 077
if ! compose exec -T db \
      pg_dump -Fc --no-owner --no-privileges \
              -U "${POSTGRES_USER}" "${POSTGRES_DB}" > "${ARQUIVO_PARCIAL}"; then
  morrer "pg_dump falhou; nenhum backup foi gravado."
fi

if [[ ! -s "${ARQUIVO_PARCIAL}" ]]; then
  morrer "pg_dump produziu um arquivo vazio; backup inválido."
fi

# --------------------------------------------------------------------------- #
# 3. Validação do dump
# Rodamos o pg_restore --list DENTRO do container: o host não precisa ter o
# cliente do PostgreSQL instalado, e a versão confere com a do servidor.
# --------------------------------------------------------------------------- #
log "Validando o dump com pg_restore --list..."
if ! compose exec -T db sh -c '
      set -e
      cat > /tmp/gini-verificacao.dump
      pg_restore --list /tmp/gini-verificacao.dump > /dev/null
      rm -f /tmp/gini-verificacao.dump
    ' < "${ARQUIVO_PARCIAL}"; then
  rm -f "${ARQUIVO_PARCIAL}"
  morrer "o dump gerado NÃO é um arquivo válido para pg_restore; backup descartado."
fi
ok "dump válido"

mv "${ARQUIVO_PARCIAL}" "${ARQUIVO_DUMP}"
chmod 600 "${ARQUIVO_DUMP}"
trap - EXIT

TAMANHO="$(du -h "${ARQUIVO_DUMP}" | cut -f1)"
ok "backup criado: ${ARQUIVO_DUMP} (${TAMANHO})"

# --------------------------------------------------------------------------- #
# 4. Retenção
# --------------------------------------------------------------------------- #
log "Aplicando retenção de ${BACKUP_RETENTION_DAYS} dia(s)..."
REMOVIDOS=0
while IFS= read -r -d '' antigo; do
  rm -f -- "${antigo}"
  log "removido por retenção: $(basename "${antigo}")"
  REMOVIDOS=$((REMOVIDOS + 1))
done < <(find "${DIRETORIO_BACKUPS}" -maxdepth 1 -type f \
              -name "${ENV_NAME}-*.dump" \
              -mtime "+${BACKUP_RETENTION_DAYS}" -print0)

if [[ "${REMOVIDOS}" -eq 0 ]]; then
  log "nenhum backup acima da retenção"
else
  ok "${REMOVIDOS} backup(s) antigo(s) removido(s)"
fi

# Rede de segurança: nunca deixar o diretório sem nenhum backup.
TOTAL="$(find "${DIRETORIO_BACKUPS}" -maxdepth 1 -type f -name "${ENV_NAME}-*.dump" | wc -l | tr -d ' ')"
if [[ "${TOTAL}" -eq 0 ]]; then
  aviso "o diretório de backups ficou vazio — verifique a retenção configurada."
fi

printf '\n'
ok "Backup de '${ENV_NAME}' concluído. Total de dumps retidos: ${TOTAL}."
log "Fora do escopo desta fase: cópia dos dumps para fora do host (ver README.md)."
