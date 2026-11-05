# Segurança do self-hosted runner

Este repositório usa um **runner self-hosted** do GitHub Actions instalado no
servidor Ubuntu local (`scripts/install-runner.sh`). Um runner self-hosted
executa código no nosso host — diferente dos runners hospedados pelo GitHub,
que são descartados a cada job. Este documento lista o risco real e as
mitigações que **precisam** estar aplicadas.

> Trate este repositório como **potencialmente público**. Todas as restrições
> abaixo valem independentemente da visibilidade atual.

---

## 1. Por que isso exige cuidado

O runner roda como o usuário `gha-runner`, que pertence ao grupo `docker`.

**O grupo `docker` é equivalente a privilégio de root no host.** Qualquer membro
pode subir um container montando `/` e escrever em qualquer arquivo do sistema:

```bash
# Demonstração (NÃO execute em produção): acesso total ao disco do host
docker run --rm -it -v /:/host alpine chroot /host sh
```

Não existe forma de usar o Docker Engine padrão sem esse privilégio. Portanto a
defesa não é "tirar o poder do runner", e sim **controlar quem consegue fazer o
runner executar código**.

O cenário que precisamos impedir: alguém de fora abre um Pull Request com um
workflow (ou um script chamado por um workflow) alterado, o workflow roda no
nosso runner e executa comandos arbitrários no servidor.

---

## 2. Mitigações obrigatórias

### 2.1 Runner registrado no nível do REPOSITÓRIO, nunca da organização

`scripts/install-runner.sh` registra com `--url https://github.com/<owner>/<repo>`.

Um runner de **organização** fica disponível para *todos* os repositórios da
org — qualquer repositório novo (ou comprometido) poderia agendar jobs no nosso
servidor. Mantenha o registro no repositório.

Conferir: **Settings → Actions → Runners** do repositório `banco-infra` (e
confirmar que ele **não** aparece em Settings da organização).

### 2.2 Gatilhos restritos: só `repository_dispatch` e `workflow_dispatch`

| Workflow | Gatilho | Por quê |
| --- | --- | --- |
| `.github/workflows/deploy-dev.yml` | `repository_dispatch` | exige um token com permissão de escrita no repositório para disparar |
| `.github/workflows/deploy.yml` | `workflow_dispatch` | exige permissão de escrita e passa pelos Environments |

**Proibido** nos workflows que usam `runs-on: self-hosted`:

- `pull_request` — roda código de branch de contribuidor;
- `pull_request_target` — roda com acesso a secrets, pior ainda;
- `push` em branches que qualquer colaborador possa criar;
- `issue_comment`, `workflow_run` e similares disparados por terceiros.

Quem dispara `repository_dispatch` precisa de um token com escopo de escrita no
repositório (`INFRA_DISPATCH_TOKEN`, guardado como secret nos repos de
aplicação). Não é um gatilho anônimo.

### 2.3 Se o repositório for público: exigir aprovação de workflows externos

**Settings → Actions → General → Fork pull request workflows from outside
collaborators** → selecione:

> **Require approval for all outside collaborators**

E em **Settings → Actions → General → Fork pull request workflows**, deixe
desmarcadas as opções que permitem a forks ler secrets ou criar/aprovar PRs.

Isso garante que nenhum workflow vindo de fork rode sem um mantenedor clicar em
"Approve". Combinado com 2.2 (não há gatilho de PR nos workflows de deploy), são
duas camadas independentes.

### 2.4 Rótulo dedicado nos jobs

Todos os jobs de deploy usam:

```yaml
runs-on: [self-hosted, linux, x64, gini-local]
```

O rótulo `gini-local` é definido no registro (`--labels gini-local`). Usar o
rótulo completo evita que um job pegue um runner self-hosted errado, se o grupo
vier a registrar outros.

### 2.5 GitHub Environments com regras de proteção

Os jobs declaram `environment:`, o que permite ao GitHub pausar o job antes da
execução:

| Environment | Proteção |
| --- | --- |
| `dev` | sem proteção (deploy automático) |
| `staging` | revisor **opcional** |
| `production` | revisor **obrigatório** (pelo menos 1 aprovador) |

Configuração passo a passo em [`estrategia-gatilhos.md`](estrategia-gatilhos.md).

Guarde os secrets `GHCR_USER` / `GHCR_PULL_TOKEN` no nível do **repositório**
(são os mesmos para os três ambientes). Se algum dia houver credencial
específica de produção, mova-a para o Environment `production`, que só é
acessível após a aprovação.

### 2.6 Usuário sem `sudo`

`gha-runner` é criado por `scripts/bootstrap-server.sh` com senha travada
(`passwd --lock`) e **não** entra nos grupos `sudo`/`admin`. O bootstrap emite
aviso se detectar o contrário.

Confira:

```bash
id -nG gha-runner            # esperado: gha-runner docker
sudo -l -U gha-runner        # esperado: "não é permitido executar sudo"
ls /etc/sudoers.d/           # não deve existir arquivo para gha-runner
```

O serviço systemd do backup (`gini-backup@.service`) também roda como
`gha-runner`, com `NoNewPrivileges=true` e `ProtectSystem=full`.

### 2.7 Nada de segredo em disco ou no histórico

- O **token de registro** do runner é passado por variável de ambiente para
  `install-runner.sh` e nunca é gravado em arquivo. Ele expira em cerca de 1
  hora.
  Limitação conhecida: `config.sh` recebe o token como argumento, portanto ele
  fica visível em `ps` durante os poucos segundos do registro. Rode o script em
  um momento em que não haja terceiros com shell no servidor.
  Para não deixá-lo no histórico do shell, leia-o sem eco:

  ```bash
  read -rs RUNNER_TOKEN && export RUNNER_TOKEN
  sudo -E REPO_URL=https://github.com/PI-AMS-2025-2026/banco-infra \
       ./scripts/install-runner.sh
  unset RUNNER_TOKEN
  ```

- O **PAT do ghcr.io** chega por secret e entra no `docker login` via
  `--password-stdin` (nunca na linha de comando). Os workflows fazem
  `docker logout ghcr.io` no final, inclusive em falha.
- Os `.env` dos ambientes ficam **fora do Git**, em `/opt/gini/<env>/.env`, modo
  `600`, dono `gha-runner`. O `deploy.sh` aborta se o modo não for `600`.
- Nenhuma entrada externa (payload do dispatch, input do workflow) é interpolada
  diretamente em comando: tudo passa por `env:` e por validação de regex
  (`^[A-Za-z0-9_.-]{1,128}$` para tags).

### 2.8 Rotação do PAT do ghcr.io

O PAT usado pelo servidor é **somente leitura de pacotes**:

- tipo: classic PAT com escopo `read:packages` (ou fine-grained com
  *Packages: read*);
- **sem** `write:packages`, **sem** `repo`, **sem** `delete:packages`;
- validade máxima de 90 dias.

Rotação (a cada 90 dias ou imediatamente após saída de alguém do grupo / suspeita
de vazamento):

1. Gerar um novo PAT em **Settings → Developer settings → Personal access
   tokens**, apenas com `read:packages`.
2. Atualizar o secret `GHCR_PULL_TOKEN` em **Settings → Secrets and variables →
   Actions** deste repositório.
3. Disparar um deploy em `dev` para confirmar que o login funciona.
4. **Revogar o PAT antigo** no GitHub.
5. No servidor, limpar credenciais residuais:
   `sudo -u gha-runner docker logout ghcr.io`.

Se o grupo tornar os pacotes do ghcr **públicos**, o login passa a ser opcional:
basta não definir `GHCR_PULL_TOKEN` e o `deploy.sh` segue sem autenticar.

### 2.9 Higiene adicional

- Atualizar o runner com regularidade (`install-runner.sh --reconfigure` com
  `RUNNER_VERSION` nova); o GitHub descontinua versões antigas.
- Manter o sistema atualizado: `sudo apt-get update && sudo apt-get upgrade`.
- O firewall UFW nega entrada por padrão. **Portas publicadas pelo Docker
  contornam o UFW** — por isso o container do banco nunca publica porta.
- Revisar `/opt/gini/<env>/releases.log` e `journalctl -u actions.runner.*`
  periodicamente.

---

## 3. Remoção do runner

### 3.1 Jeito certo (remove do GitHub e do host)

```bash
# 1. Gerar um token de remoção:
#    Settings -> Actions -> Runners -> (o runner) -> Remove -> copiar o token
cd /opt/gini/runner

# 2. Parar e desinstalar o serviço systemd (como root)
sudo ./svc.sh stop
sudo ./svc.sh uninstall

# 3. Desregistrar do GitHub (como gha-runner)
sudo -u gha-runner ./config.sh remove --token <TOKEN_DE_REMOCAO>

# 4. Opcional: apagar os binários
sudo rm -rf /opt/gini/runner/*
```

### 3.2 Se o servidor já foi perdido

Remova pela interface: **Settings → Actions → Runners → ⋯ → Remove →
"Force remove this runner"**. Depois **revogue o PAT do ghcr.io** (seção 2.8),
porque ele pode ter ficado no `~/.docker/config.json` daquele host.

### 3.3 Re-registro

```bash
sudo -E REPO_URL=https://github.com/PI-AMS-2025-2026/banco-infra \
     RUNNER_TOKEN=<novo-token> \
     ./scripts/install-runner.sh --reconfigure
```

---

## 4. Checklist de revisão

Antes de considerar o runner "em produção":

- [ ] Runner aparece em **Settings → Actions → Runners** do repositório como
      `Idle`, com os rótulos `self-hosted, linux, x64, gini-local`.
- [ ] Runner **não** aparece nos runners da organização.
- [ ] `systemctl is-enabled "actions.runner.*"` retorna `enabled`
      (sobrevive a reboot) e `systemctl status` mostra `active (running)`.
- [ ] Nenhum workflow deste repositório usa `pull_request` ou
      `pull_request_target`:
      `grep -rn "pull_request" .github/workflows/` → sem resultado.
- [ ] Approval de workflows de colaboradores externos exigido (se público).
- [ ] Environments `dev`/`staging`/`production` criados, com revisor obrigatório
      em `production`.
- [ ] `id -nG gha-runner` → `gha-runner docker` (sem `sudo`).
- [ ] `git ls-files | grep -E '(^|/)\.env$'` → sem resultado (nenhum `.env` real
      versionado).
- [ ] PAT do ghcr.io apenas com `read:packages` e data de rotação anotada.
