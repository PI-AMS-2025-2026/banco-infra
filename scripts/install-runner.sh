#!/usr/bin/env bash
#
# install-runner.sh — Instala e registra o self-hosted runner do GitHub Actions
# como serviço systemd, rodando com o usuário `gha-runner`.
#
# Pré-requisito: scripts/bootstrap-server.sh já executado (cria o usuário
# gha-runner, o grupo docker e /opt/gini/runner).
#
# Uso (executar como root):
#
#   # O token de registro é de CURTA DURAÇÃO (~1h) e é obtido em
#   # Settings -> Actions -> Runners -> New self-hosted runner.
#   # Passe por variável de ambiente para não gravá-lo no histórico do shell:
#   sudo REPO_URL=https://github.com/PI-AMS-2025-2026/banco-infra \
#        RUNNER_TOKEN=XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX \
#        ./scripts/install-runner.sh
#
#   # Para re-registrar um runner já configurado:
#   sudo REPO_URL=... RUNNER_TOKEN=... ./scripts/install-runner.sh --reconfigure
#
# Alternativa que evita o token no ambiente do processo (lê de stdin):
#   read -rs RUNNER_TOKEN && export RUNNER_TOKEN && sudo -E ./scripts/install-runner.sh
#
# Variáveis de entrada:
#   REPO_URL        (obrigatória) URL deste repositório no GitHub.
#   RUNNER_TOKEN    (obrigatória, salvo com --reconfigure sobre runner já ativo)
#                   Token de registro de curta duração. NUNCA é gravado em disco.
#   RUNNER_VERSION  (opcional) padrão abaixo — release estável fixada.
#   RUNNER_SHA256   (opcional) checksum do tarball linux-x64 da versão acima.
#   RUNNER_USER     (opcional) padrão gha-runner.
#   RUNNER_DIR      (opcional) padrão /opt/gini/runner.
#   RUNNER_LABELS   (opcional) padrão gini-local.
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuração
# --------------------------------------------------------------------------- #
# Versão e checksum conferidos em https://github.com/actions/runner/releases
# (release v2.338.0, publicada em 06/10/2026; hash do bloco
# "<!-- BEGIN SHA linux-x64 -->" das notas de release).
# Para atualizar: troque as duas linhas abaixo juntas, sempre consultando a
# página oficial de releases — nunca estime o checksum.
RUNNER_VERSION="${RUNNER_VERSION:-2.338.0}"
RUNNER_SHA256="${RUNNER_SHA256:-af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32}"

RUNNER_USER="${RUNNER_USER:-gha-runner}"
RUNNER_DIR="${RUNNER_DIR:-/opt/gini/runner}"
RUNNER_LABELS="${RUNNER_LABELS:-gini-local}"
RUNNER_NAME="$(hostname)-gini"

RECONFIGURE=0

log()   { printf '\033[0;34m[INFO ]\033[0m %s\n' "$*"; }
ok()    { printf '\033[0;32m[ OK  ]\033[0m %s\n' "$*"; }
aviso() { printf '\033[0;33m[AVISO]\033[0m %s\n' "$*"; }
erro()  { printf '\033[0;31m[ERRO ]\033[0m %s\n' "$*" >&2; }
morrer() { erro "$1"; exit 1; }

# Executa um comando como o usuário do runner, dentro de RUNNER_DIR.
como_runner() {
  sudo -u "${RUNNER_USER}" --preserve-env=RUNNER_ALLOW_RUNASROOT \
    bash -c "cd '${RUNNER_DIR}' && $(printf '%q ' "$@")"
}

# --------------------------------------------------------------------------- #
# Argumentos
# --------------------------------------------------------------------------- #
analisar_argumentos() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reconfigure) RECONFIGURE=1; shift ;;
      -h|--help)
        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      *) morrer "Argumento desconhecido: '$1' (use --reconfigure ou --help)." ;;
    esac
  done
}

# --------------------------------------------------------------------------- #
# Validações
# --------------------------------------------------------------------------- #
validar_ambiente() {
  [[ "${EUID}" -eq 0 ]] || morrer "Execute como root (sudo -E $0)."

  [[ -n "${REPO_URL:-}" ]] || morrer "REPO_URL não informada (ex.: https://github.com/<owner>/<repo>)."

  if [[ ! "${REPO_URL}" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/?$ ]]; then
    morrer "REPO_URL inválida: '${REPO_URL}'. Esperado https://github.com/<owner>/<repo>."
  fi

  id -u "${RUNNER_USER}" >/dev/null 2>&1 \
    || morrer "Usuário '${RUNNER_USER}' não existe. Rode scripts/bootstrap-server.sh primeiro."

  [[ -d "${RUNNER_DIR}" ]] \
    || morrer "Diretório '${RUNNER_DIR}' não existe. Rode scripts/bootstrap-server.sh primeiro."

  command -v curl  >/dev/null || morrer "curl não encontrado."
  command -v tar   >/dev/null || morrer "tar não encontrado."
  command -v sha256sum >/dev/null || morrer "sha256sum não encontrado."

  if [[ ! "${RUNNER_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    morrer "RUNNER_VERSION inválida: '${RUNNER_VERSION}'."
  fi
  if [[ ! "${RUNNER_SHA256}" =~ ^[0-9a-f]{64}$ ]]; then
    morrer "RUNNER_SHA256 inválido: esperado 64 caracteres hexadecimais."
  fi
}

# --------------------------------------------------------------------------- #
# Download e extração
# --------------------------------------------------------------------------- #
baixar_e_extrair() {
  # Se o binário já está lá na versão certa, não baixa de novo.
  if [[ -x "${RUNNER_DIR}/config.sh" && -f "${RUNNER_DIR}/.gini-runner-version" ]] \
     && [[ "$(cat "${RUNNER_DIR}/.gini-runner-version")" == "${RUNNER_VERSION}" ]]; then
    log "já configurado: binários do runner ${RUNNER_VERSION} presentes em ${RUNNER_DIR}"
    return
  fi

  local arquivo="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  local url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${arquivo}"
  local temporario
  temporario="$(mktemp -d)"
  # shellcheck disable=SC2064  # queremos expandir ${temporario} agora, não no exit
  trap "rm -rf '${temporario}'" EXIT

  log "Baixando ${arquivo}..."
  curl -fsSL -o "${temporario}/${arquivo}" "${url}" \
    || morrer "falha ao baixar ${url}"

  log "Validando SHA-256..."
  printf '%s  %s\n' "${RUNNER_SHA256}" "${temporario}/${arquivo}" > "${temporario}/SHA256SUMS"
  if ! sha256sum --check --quiet "${temporario}/SHA256SUMS"; then
    morrer "checksum do tarball NÃO corresponde. Download abortado — não extraia."
  fi
  ok "checksum conferido"

  log "Extraindo em ${RUNNER_DIR}..."
  tar -xzf "${temporario}/${arquivo}" -C "${RUNNER_DIR}"
  printf '%s\n' "${RUNNER_VERSION}" > "${RUNNER_DIR}/.gini-runner-version"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_DIR}"
  ok "runner ${RUNNER_VERSION} extraído"

  rm -rf "${temporario}"
  trap - EXIT
}

# --------------------------------------------------------------------------- #
# Dependências nativas do runner (libicu etc.)
# --------------------------------------------------------------------------- #
instalar_dependencias_do_runner() {
  if [[ -x "${RUNNER_DIR}/bin/installdependencies.sh" ]]; then
    log "Garantindo dependências nativas do runner..."
    DEBIAN_FRONTEND=noninteractive "${RUNNER_DIR}/bin/installdependencies.sh" >/dev/null
    ok "dependências nativas presentes"
  fi
}

# --------------------------------------------------------------------------- #
# Remoção do registro atual (--reconfigure)
# --------------------------------------------------------------------------- #
remover_registro_existente() {
  log "Removendo registro e serviço existentes (--reconfigure)..."

  # svc.sh roda como root; recebe o usuário de serviço como argumento.
  if systemctl list-units --all --type=service --no-legend 'actions.runner.*' | grep -q .; then
    "${RUNNER_DIR}/svc.sh" stop     || aviso "svc.sh stop falhou (serviço talvez já parado)."
    "${RUNNER_DIR}/svc.sh" uninstall || aviso "svc.sh uninstall falhou (serviço talvez já removido)."
  fi

  if [[ -f "${RUNNER_DIR}/.runner" ]]; then
    # `config.sh remove` precisa de um token de remoção; reaproveitamos o token
    # de registro informado, que serve para ambos.
    como_runner ./config.sh remove --token "${RUNNER_TOKEN}" \
      || aviso "config.sh remove falhou; o runner pode ter de ser apagado na interface do GitHub."
  fi

  ok "registro anterior removido"
}

# --------------------------------------------------------------------------- #
# Registro
# --------------------------------------------------------------------------- #
registrar_runner() {
  if [[ -f "${RUNNER_DIR}/.runner" && "${RECONFIGURE}" -eq 0 ]]; then
    log "já configurado: runner registrado (.runner existe). Use --reconfigure para re-registrar."
    return
  fi

  [[ -n "${RUNNER_TOKEN:-}" ]] \
    || morrer "RUNNER_TOKEN não informado. Gere em Settings -> Actions -> Runners -> New self-hosted runner."

  if [[ -f "${RUNNER_DIR}/.runner" ]]; then
    remover_registro_existente
  fi

  log "Registrando runner '${RUNNER_NAME}' em ${REPO_URL} com rótulos '${RUNNER_LABELS}'..."
  # --replace: se já existir um runner com este nome no repositório, substitui.
  # --unattended: sem perguntas interativas.
  como_runner ./config.sh \
    --unattended \
    --url "${REPO_URL}" \
    --token "${RUNNER_TOKEN}" \
    --labels "${RUNNER_LABELS}" \
    --name "${RUNNER_NAME}" \
    --work "_work" \
    --replace
  ok "runner registrado"
}

# --------------------------------------------------------------------------- #
# Serviço systemd
# --------------------------------------------------------------------------- #
instalar_servico() {
  local unidade
  unidade="$(systemctl list-units --all --type=service --no-legend 'actions.runner.*' \
              | awk '{print $1}' | head -n1)"

  if [[ -z "${unidade}" ]]; then
    log "Instalando o serviço systemd (executando como ${RUNNER_USER})..."
    "${RUNNER_DIR}/svc.sh" install "${RUNNER_USER}"
    ok "serviço systemd instalado"
  else
    log "já configurado: serviço systemd ${unidade}"
  fi

  unidade="$(systemctl list-units --all --type=service --no-legend 'actions.runner.*' \
              | awk '{print $1}' | head -n1)"
  [[ -n "${unidade}" ]] || morrer "não foi possível localizar a unidade actions.runner.*"

  if systemctl is-active --quiet "${unidade}"; then
    log "já configurado: ${unidade} em execução"
  else
    "${RUNNER_DIR}/svc.sh" start
    ok "serviço iniciado"
  fi

  # `svc.sh install` já habilita no boot; confirmamos para o critério de aceite.
  if systemctl is-enabled --quiet "${unidade}" 2>/dev/null; then
    log "já configurado: ${unidade} habilitado no boot"
  else
    systemctl enable "${unidade}"
    ok "${unidade} habilitado no boot"
  fi

  printf '\n'
  systemctl status "${unidade}" --no-pager --lines=0 || true
}

# --------------------------------------------------------------------------- #
# Resumo
# --------------------------------------------------------------------------- #
imprimir_resumo() {
  cat <<RESUMO

==========================================================
 RUNNER SELF-HOSTED — ${RUNNER_NAME}
==========================================================
  Repositório : ${REPO_URL}
  Versão      : ${RUNNER_VERSION}
  Diretório   : ${RUNNER_DIR}
  Usuário     : ${RUNNER_USER} (sem sudo, membro do grupo docker)
  Rótulos     : self-hosted, linux, x64, ${RUNNER_LABELS}

  Nos workflows use:
      runs-on: [self-hosted, linux, x64, ${RUNNER_LABELS}]

  Confira em Settings -> Actions -> Runners: deve aparecer como "Idle".
  Riscos e mitigações: docs/seguranca-runner.md
  Para remover o runner: docs/seguranca-runner.md (seção "Remoção")

RESUMO
}

# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
main() {
  analisar_argumentos "$@"
  validar_ambiente
  baixar_e_extrair
  instalar_dependencias_do_runner
  registrar_runner
  instalar_servico
  imprimir_resumo

  # Não há nada a limpar em disco: o token só existiu como variável de ambiente.
  unset RUNNER_TOKEN
}

main "$@"
