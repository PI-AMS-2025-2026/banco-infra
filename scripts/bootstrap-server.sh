#!/usr/bin/env bash
#
# bootstrap-server.sh — Prepara um Ubuntu Server limpo para hospedar os
# ambientes dev/staging/production do Projeto Integrador (Gini).
#
# O que faz (todas as etapas são idempotentes):
#   1. Valida que está rodando como root, em Ubuntu amd64.
#   2. Instala pacotes-base e o Docker Engine + plugin Compose v2 (repo oficial).
#   3. Configura rotação de logs do Docker em /etc/docker/daemon.json.
#   4. Cria o usuário de serviço `gha-runner` no grupo `docker`.
#   5. Cria a árvore de diretórios em /opt/gini.
#   6. Configura o firewall UFW.
#   7. Imprime um resumo do que foi feito e do que já estava configurado.
#
# Uso:
#   sudo ./scripts/bootstrap-server.sh
#
# Variáveis de ambiente opcionais (portas liberadas no firewall):
#   SSH_PORT=22
#   DEV_FRONTEND_PORT=3001         DEV_BACKEND_PORT=8081
#   STAGING_FRONTEND_PORT=3002     STAGING_BACKEND_PORT=8082
#   PRODUCTION_FRONTEND_PORT=3000  PRODUCTION_BACKEND_PORT=8080
#   RUNNER_USER=gha-runner
#   GINI_ROOT=/opt/gini
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuração
# --------------------------------------------------------------------------- #
RUNNER_USER="${RUNNER_USER:-gha-runner}"
GINI_ROOT="${GINI_ROOT:-/opt/gini}"
ENVIRONMENTS=(dev staging production)

SSH_PORT="${SSH_PORT:-22}"
DEV_FRONTEND_PORT="${DEV_FRONTEND_PORT:-3001}"
DEV_BACKEND_PORT="${DEV_BACKEND_PORT:-8081}"
STAGING_FRONTEND_PORT="${STAGING_FRONTEND_PORT:-3002}"
STAGING_BACKEND_PORT="${STAGING_BACKEND_PORT:-8082}"
PRODUCTION_FRONTEND_PORT="${PRODUCTION_FRONTEND_PORT:-3000}"
PRODUCTION_BACKEND_PORT="${PRODUCTION_BACKEND_PORT:-8080}"

BASE_PACKAGES=(ca-certificates curl gnupg ufw jq rsync)
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
DOCKER_APT_LIST="/etc/apt/sources.list.d/docker.list"
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"

# Acumuladores para o resumo final.
ACOES_REALIZADAS=()
ACOES_IGNORADAS=()

# --------------------------------------------------------------------------- #
# Utilitários de log
# --------------------------------------------------------------------------- #
log()    { printf '\033[0;34m[INFO ]\033[0m %s\n' "$*"; }
ok()     { printf '\033[0;32m[ OK  ]\033[0m %s\n' "$*"; }
aviso()  { printf '\033[0;33m[AVISO]\033[0m %s\n' "$*"; }
erro()   { printf '\033[0;31m[ERRO ]\033[0m %s\n' "$*" >&2; }

# Registra uma mudança efetivamente aplicada.
mudou() { ACOES_REALIZADAS+=("$1"); ok "$1"; }

# Registra um estado que já estava correto (nada a fazer).
inalterado() { ACOES_IGNORADAS+=("$1"); log "já configurado: $1"; }

morrer() { erro "$1"; exit 1; }

# --------------------------------------------------------------------------- #
# Etapa 1 — Pré-requisitos
# --------------------------------------------------------------------------- #
verificar_prerequisitos() {
  log "Verificando pré-requisitos..."

  if [[ "${EUID}" -ne 0 ]]; then
    morrer "Este script precisa ser executado como root (use: sudo $0)."
  fi

  [[ -r /etc/os-release ]] || morrer "/etc/os-release não encontrado; sistema não suportado."

  # shellcheck disable=SC1091  # arquivo gerado pelo sistema, não existe neste repo
  . /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    morrer "Distribuição '${ID:-desconhecida}' não suportada. Esperado: Ubuntu Server LTS."
  fi

  case "${VERSION_ID:-}" in
    22.04|24.04)
      ok "Ubuntu ${VERSION_ID} (${VERSION_CODENAME:-?}) — versão homologada."
      ;;
    *)
      aviso "Ubuntu ${VERSION_ID:-?} não está na lista homologada (22.04 / 24.04). Prosseguindo."
      ;;
  esac

  [[ -n "${VERSION_CODENAME:-}" ]] || morrer "VERSION_CODENAME ausente em /etc/os-release."

  local arquitetura
  arquitetura="$(dpkg --print-architecture)"
  if [[ "${arquitetura}" != "amd64" ]]; then
    morrer "Arquitetura '${arquitetura}' não suportada. Esperado: amd64."
  fi
  ok "Arquitetura amd64 confirmada."
}

# --------------------------------------------------------------------------- #
# Etapa 2 — Pacotes-base e Docker
# --------------------------------------------------------------------------- #
# Retorna 0 se TODOS os pacotes informados já estiverem instalados.
pacotes_instalados() {
  local pacote
  for pacote in "$@"; do
    dpkg-query -W -f='${Status}' "${pacote}" 2>/dev/null | grep -q '^install ok installed$' || return 1
  done
  return 0
}

instalar_pacotes_base() {
  log "Verificando pacotes-base..."

  if pacotes_instalados "${BASE_PACKAGES[@]}"; then
    inalterado "pacotes-base (${BASE_PACKAGES[*]})"
    return
  fi

  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${BASE_PACKAGES[@]}"
  mudou "pacotes-base instalados (${BASE_PACKAGES[*]})"
}

configurar_repositorio_docker() {
  log "Verificando repositório apt da Docker..."

  # shellcheck disable=SC1091
  . /etc/os-release
  local codename="${VERSION_CODENAME}"
  local linha_esperada="deb [arch=amd64 signed-by=${DOCKER_KEYRING}] https://download.docker.com/linux/ubuntu ${codename} stable"
  local alterou=0

  if [[ ! -s "${DOCKER_KEYRING}" ]]; then
    install -m 0755 -d "$(dirname "${DOCKER_KEYRING}")"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "${DOCKER_KEYRING}"
    chmod a+r "${DOCKER_KEYRING}"
    mudou "chave GPG da Docker instalada em ${DOCKER_KEYRING}"
    alterou=1
  else
    inalterado "chave GPG da Docker (${DOCKER_KEYRING})"
  fi

  if [[ ! -f "${DOCKER_APT_LIST}" ]] || ! grep -qxF "${linha_esperada}" "${DOCKER_APT_LIST}"; then
    printf '%s\n' "${linha_esperada}" > "${DOCKER_APT_LIST}"
    mudou "repositório apt da Docker configurado para '${codename}'"
    alterou=1
  else
    inalterado "repositório apt da Docker (${codename})"
  fi

  # Só gasta tempo com `apt-get update` se a lista de fontes mudou.
  if [[ "${alterou}" -eq 1 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
  fi
}

instalar_docker() {
  log "Verificando Docker Engine e plugin Compose v2..."

  if pacotes_instalados "${DOCKER_PACKAGES[@]}"; then
    inalterado "Docker Engine + plugin Compose (${DOCKER_PACKAGES[*]})"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${DOCKER_PACKAGES[@]}"
    mudou "Docker Engine + plugin Compose instalados"
  fi

  if systemctl is-enabled --quiet docker 2>/dev/null; then
    inalterado "serviço docker habilitado no boot"
  else
    systemctl enable docker
    mudou "serviço docker habilitado no boot"
  fi

  if systemctl is-active --quiet docker 2>/dev/null; then
    inalterado "serviço docker em execução"
  else
    systemctl start docker
    mudou "serviço docker iniciado"
  fi

  # Confirma que o plugin Compose v2 responde (não é o docker-compose v1).
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose: $(docker compose version --short 2>/dev/null || echo 'v2')"
  else
    morrer "plugin 'docker compose' v2 não respondeu após a instalação."
  fi
}

# --------------------------------------------------------------------------- #
# Etapa 3 — Rotação de logs do Docker
# --------------------------------------------------------------------------- #
# Mescla as chaves de log-driver no daemon.json existente em vez de sobrescrever
# o arquivo, para não apagar configuração que o grupo tenha adicionado à mão.
configurar_rotacao_de_logs() {
  log "Verificando rotação de logs do Docker (${DOCKER_DAEMON_JSON})..."

  install -m 0755 -d /etc/docker

  local atual='{}'
  if [[ -s "${DOCKER_DAEMON_JSON}" ]]; then
    if ! jq -e . "${DOCKER_DAEMON_JSON}" >/dev/null 2>&1; then
      morrer "${DOCKER_DAEMON_JSON} existe mas não é um JSON válido; corrija manualmente."
    fi
    atual="$(cat "${DOCKER_DAEMON_JSON}")"
  fi

  local desejado
  desejado="$(printf '%s' "${atual}" | jq -S '
    .["log-driver"] = "json-file"
    | .["log-opts"] = ((.["log-opts"] // {}) + {"max-size": "10m", "max-file": "3"})
  ')"

  if [[ "$(printf '%s' "${atual}" | jq -S .)" == "${desejado}" ]]; then
    inalterado "rotação de logs do Docker (json-file, max-size 10m, max-file 3)"
    return
  fi

  printf '%s\n' "${desejado}" > "${DOCKER_DAEMON_JSON}"
  chmod 0644 "${DOCKER_DAEMON_JSON}"
  systemctl restart docker
  mudou "rotação de logs do Docker aplicada e serviço reiniciado"
}

# --------------------------------------------------------------------------- #
# Etapa 4 — Usuário de serviço do runner
# --------------------------------------------------------------------------- #
# ATENÇÃO: pertencer ao grupo `docker` é equivalente a root no host — qualquer
# membro pode montar / dentro de um container e escrever em qualquer arquivo.
# As mitigações (runner no nível do repositório, gatilhos restritos, Environments
# com aprovação, usuário sem sudo) estão em docs/seguranca-runner.md.
criar_usuario_runner() {
  log "Verificando usuário de serviço '${RUNNER_USER}'..."

  if id -u "${RUNNER_USER}" >/dev/null 2>&1; then
    inalterado "usuário ${RUNNER_USER}"
  else
    # -r: usuário de sistema; -m: cria o home (o runner grava .credentials lá
    # perto); -s /bin/bash: shell válido, exigido pelo svc.sh do runner.
    useradd --system --create-home \
            --home-dir "/home/${RUNNER_USER}" \
            --shell /bin/bash \
            --user-group \
            --comment "GitHub Actions self-hosted runner (Gini)" \
            "${RUNNER_USER}"
    # Sem senha: o acesso é só via `sudo -u` / systemd, nunca por login direto.
    passwd --lock "${RUNNER_USER}" >/dev/null
    mudou "usuário ${RUNNER_USER} criado (senha travada, shell /bin/bash)"
  fi

  if id -nG "${RUNNER_USER}" | tr ' ' '\n' | grep -qx docker; then
    inalterado "${RUNNER_USER} já pertence ao grupo docker"
  else
    usermod -aG docker "${RUNNER_USER}"
    mudou "${RUNNER_USER} adicionado ao grupo docker"
    aviso "Grupo 'docker' ≡ privilégio de root no host. Veja docs/seguranca-runner.md."
  fi

  # O runner não deve ter sudo: valida e avisa se alguém concedeu.
  if [[ -f "/etc/sudoers.d/${RUNNER_USER}" ]] || id -nG "${RUNNER_USER}" | tr ' ' '\n' | grep -qxE 'sudo|admin'; then
    aviso "${RUNNER_USER} aparenta ter privilégio sudo. Remova — o runner deve rodar sem sudo."
  fi
}

# --------------------------------------------------------------------------- #
# Etapa 5 — Árvore de diretórios
# --------------------------------------------------------------------------- #
# Garante dono/modo de um diretório sem reescrever quando já está correto.
garantir_diretorio() {
  local caminho="$1" modo="$2" dono="$3"

  if [[ ! -d "${caminho}" ]]; then
    install -d -m "${modo}" -o "${dono%:*}" -g "${dono#*:}" "${caminho}"
    mudou "diretório ${caminho} criado (modo ${modo}, dono ${dono})"
    return
  fi

  local modo_atual dono_atual
  modo_atual="$(stat -c '%a' "${caminho}")"
  dono_atual="$(stat -c '%U:%G' "${caminho}")"

  if [[ "${modo_atual}" == "${modo#0}" && "${dono_atual}" == "${dono}" ]]; then
    inalterado "diretório ${caminho} (modo ${modo}, dono ${dono})"
  else
    chmod "${modo}" "${caminho}"
    chown "${dono}" "${caminho}"
    mudou "diretório ${caminho} ajustado (modo ${modo}, dono ${dono})"
  fi
}

criar_arvore_de_diretorios() {
  log "Verificando árvore de diretórios em ${GINI_ROOT}..."

  local dono="${RUNNER_USER}:${RUNNER_USER}"
  local ambiente

  garantir_diretorio "${GINI_ROOT}" 0750 "${dono}"

  # Um diretório de trabalho por ambiente: guarda .env, images.env,
  # docker-compose.yml e releases.log.
  for ambiente in "${ENVIRONMENTS[@]}"; do
    garantir_diretorio "${GINI_ROOT}/${ambiente}" 0750 "${dono}"
  done

  # Backups ficam 700: contêm dados do banco em claro.
  garantir_diretorio "${GINI_ROOT}/backups" 0700 "${dono}"
  for ambiente in "${ENVIRONMENTS[@]}"; do
    garantir_diretorio "${GINI_ROOT}/backups/${ambiente}" 0700 "${dono}"
  done

  # Destino da instalação do self-hosted runner (TASK 2).
  garantir_diretorio "${GINI_ROOT}/runner" 0750 "${dono}"
}

# --------------------------------------------------------------------------- #
# Etapa 6 — Firewall UFW
# --------------------------------------------------------------------------- #
# IMPORTANTE: o Docker escreve direto na cadeia DOCKER-USER do iptables, então
# portas publicadas com `ports:` no compose IGNORAM as regras do UFW. Por isso o
# container do banco nunca publica porta no host (ver docker/docker-compose.yml).
# O UFW aqui protege os serviços do próprio host (SSH, etc.).
configurar_firewall() {
  log "Verificando firewall UFW..."

  local porta
  local portas_dos_ambientes=(
    "${DEV_FRONTEND_PORT}"        "${DEV_BACKEND_PORT}"
    "${STAGING_FRONTEND_PORT}"    "${STAGING_BACKEND_PORT}"
    "${PRODUCTION_FRONTEND_PORT}" "${PRODUCTION_BACKEND_PORT}"
  )

  # Políticas padrão. `ufw default` é idempotente, mas só reportamos mudança se
  # o status atual divergir.
  local status_verbose
  status_verbose="$(ufw status verbose 2>/dev/null || true)"

  if printf '%s' "${status_verbose}" | grep -q 'deny (incoming), allow (outgoing)'; then
    inalterado "políticas padrão do UFW (deny incoming / allow outgoing)"
  else
    ufw --force default deny incoming >/dev/null
    ufw --force default allow outgoing >/dev/null
    mudou "políticas padrão do UFW definidas (deny incoming / allow outgoing)"
  fi

  # SSH PRIMEIRO: liberar antes de habilitar o firewall evita perder a sessão.
  if ufw status | grep -qE "^${SSH_PORT}/tcp\b"; then
    inalterado "regra UFW para SSH (${SSH_PORT}/tcp)"
  else
    ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
    mudou "regra UFW criada para SSH (${SSH_PORT}/tcp)"
  fi

  for porta in "${portas_dos_ambientes[@]}"; do
    if [[ ! "${porta}" =~ ^[0-9]{1,5}$ ]]; then
      morrer "porta inválida informada: '${porta}'"
    fi
    if ufw status | grep -qE "^${porta}/tcp\b"; then
      inalterado "regra UFW para ${porta}/tcp"
    else
      ufw allow "${porta}/tcp" comment 'Gini app' >/dev/null
      mudou "regra UFW criada para ${porta}/tcp"
    fi
  done

  # Habilita só no final, com o SSH já liberado.
  if ufw status | grep -q '^Status: active'; then
    inalterado "UFW já ativo"
  else
    ufw --force enable >/dev/null
    mudou "UFW habilitado"
  fi

  aviso "Portas publicadas pelo Docker contornam o UFW — o banco nunca deve publicar porta."
}

# --------------------------------------------------------------------------- #
# Etapa 7 — Resumo
# --------------------------------------------------------------------------- #
imprimir_resumo() {
  local item
  printf '\n'
  printf '==========================================================\n'
  printf ' RESUMO DO BOOTSTRAP — %s\n' "$(hostname)"
  printf '==========================================================\n'

  printf '\nAlterações aplicadas (%d):\n' "${#ACOES_REALIZADAS[@]}"
  if [[ "${#ACOES_REALIZADAS[@]}" -eq 0 ]]; then
    printf '  (nenhuma — o servidor já estava configurado)\n'
  else
    for item in "${ACOES_REALIZADAS[@]}"; do
      printf '  + %s\n' "${item}"
    done
  fi

  printf '\nJá configurado, nada a fazer (%d):\n' "${#ACOES_IGNORADAS[@]}"
  for item in "${ACOES_IGNORADAS[@]}"; do
    printf '  = %s\n' "${item}"
  done

  printf '\nPróximos passos:\n'
  printf '  1. Validar o Docker para o runner:\n'
  printf '       sudo -u %s docker run --rm hello-world\n' "${RUNNER_USER}"
  printf '  2. Registrar o self-hosted runner:  scripts/install-runner.sh\n'
  printf '  3. Criar o .env de cada ambiente em %s/<env>/.env (modo 600).\n' "${GINI_ROOT}"
  printf '     Veja docs/runbook.md e docs/variaveis-e-secrets.md.\n'
  printf '\n'
}

# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
main() {
  verificar_prerequisitos
  instalar_pacotes_base
  configurar_repositorio_docker
  instalar_docker
  configurar_rotacao_de_logs
  criar_usuario_runner
  criar_arvore_de_diretorios
  configurar_firewall
  imprimir_resumo
}

main "$@"
