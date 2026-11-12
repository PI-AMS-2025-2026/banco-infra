# Runbook de operação

Procedimentos operacionais da infraestrutura do Projeto Integrador. Tudo aqui
pressupõe acesso SSH ao servidor Ubuntu local.

**Índice**

1. [Mapa do servidor](#1-mapa-do-servidor)
2. [Preparar o servidor (primeira vez)](#2-preparar-o-servidor-primeira-vez)
3. [Registrar o self-hosted runner](#3-registrar-o-self-hosted-runner)
4. [Criar o `.env` de cada ambiente](#4-criar-o-env-de-cada-ambiente)
5. [Primeiro deploy](#5-primeiro-deploy)
6. [Deploy do dia a dia](#6-deploy-do-dia-a-dia)
7. [Rollback](#7-rollback)
8. [Backup](#8-backup)
9. [Restauração](#9-restauração)
10. [Logs e inspeção](#10-logs-e-inspeção)
11. [Troubleshooting](#11-troubleshooting)
12. [Manutenção periódica](#12-manutenção-periódica)

---

## 1. Mapa do servidor

```
/opt/gini/
├── infra/                     # clone deste repositório (usado pelo timer de backup)
├── runner/                    # self-hosted runner do GitHub Actions
├── dev/                       # ambiente dev
│   ├── .env                   # configuração + segredos (modo 600, fora do Git)
│   ├── images.env             # APENAS FRONTEND_TAG e BACKEND_TAG
│   ├── images.env.previous    # tags do último deploy OK (base do rollback)
│   ├── .deploy-ok             # marcador: já houve deploy bem-sucedido
│   ├── docker-compose.yml     # sincronizado pelo deploy.sh
│   └── releases.log           # histórico de deploys
├── staging/                   # idem
├── production/                # idem
└── backups/
    ├── dev/        dev-AAAAMMDD-HHMMSS.dump
    ├── staging/
    └── production/
```

| Ambiente | Projeto Compose | Frontend | Backend | Banco |
| --- | --- | --- | --- | --- |
| dev | `gini-dev` | `3001` | `8081` | sem porta publicada |
| staging | `gini-staging` | `3002` | `8082` | sem porta publicada |
| production | `gini-production` | `3000` | `8080` | sem porta publicada |

Em **dev** e **staging**, o `.env` também liga o Mailpit (perfil `mailpit`),
uma caixa de entrada de teste para o e-mail de recuperação de senha. Ele não
publica SMTP e expõe a interface web só em `127.0.0.1`
(`8025` em dev, `8026` em staging) — ver [§10.1](#101-ler-os-e-mails-de-teste-mailpit).
Em production não existe.

Comando canônico (sempre de dentro de `/opt/gini/<env>/`):

```bash
docker compose -p gini-<env> --env-file .env --env-file images.env \
  -f docker-compose.yml <subcomando>
```

---

## 2. Preparar o servidor (primeira vez)

Corresponde a `scripts/bootstrap-server.sh`. O script é **idempotente**: rodar
duas vezes não altera nada na segunda.

```bash
# 1. Clonar o repositório de infraestrutura no servidor
sudo install -d -m 0755 /opt/gini
sudo git clone https://github.com/PI-AMS-2025-2026/banco-infra.git /opt/gini/infra
cd /opt/gini/infra

# 2. Rodar o bootstrap como root
sudo ./scripts/bootstrap-server.sh
```

O que ele faz:

1. valida root, Ubuntu (22.04 ou 24.04) e arquitetura `amd64`;
2. instala `ca-certificates curl gnupg ufw jq rsync`;
3. instala Docker Engine + plugin Compose v2 pelo repositório apt oficial da
   Docker e habilita o serviço;
4. configura rotação de logs em `/etc/docker/daemon.json` (`json-file`,
   `max-size: 10m`, `max-file: 3`), **mesclando** com a configuração existente e
   reiniciando o Docker só se algo mudou;
5. cria o usuário `gha-runner` (senha travada, shell `/bin/bash`, grupo
   `docker`);
6. cria `/opt/gini/{dev,staging,production}` e `/opt/gini/runner` com modo `750`
   e `/opt/gini/backups/{dev,staging,production}` com modo `700`, todos com dono
   `gha-runner`;
7. configura o UFW: `deny incoming` / `allow outgoing`, libera SSH **antes** de
   habilitar, libera `3000-3002` e `8080-8082`, e só então `ufw --force enable`;
8. imprime um resumo do que foi feito e do que já estava configurado.

### 2.1 Validar

```bash
# idempotência: a segunda execução não deve alterar nada e sai com código 0
sudo ./scripts/bootstrap-server.sh; echo "código de saída: $?"

# o runner consegue usar o Docker
sudo -u gha-runner docker run --rm hello-world

# firewall
sudo ufw status verbose     # deny incoming; 22, 3000-3002, 8080-8082 liberadas

# estrutura e permissões
ls -ld /opt/gini /opt/gini/dev /opt/gini/backups /opt/gini/backups/dev
#   drwxr-x--- gha-runner gha-runner  /opt/gini          (750)
#   drwx------ gha-runner gha-runner  /opt/gini/backups  (700)

# rotação de logs
sudo jq . /etc/docker/daemon.json
```

### 2.2 Limitação conhecida do UFW

Portas publicadas pelo Docker (`ports:` no compose) escrevem direto na cadeia
`DOCKER-USER` do iptables e **contornam as regras do UFW**. É por isso que o
serviço `db` **nunca** publica porta: se publicasse, o PostgreSQL ficaria
acessível na rede apesar do `deny incoming`. Ao adicionar um serviço novo,
pergunte sempre se ele realmente precisa de `ports:`.

### 2.3 Fuso horário

O timer de backup usa o fuso do host. Confirme:

```bash
timedatectl status
sudo timedatectl set-timezone America/Sao_Paulo   # se necessário
```

---

## 3. Registrar o self-hosted runner

Leia [`seguranca-runner.md`](seguranca-runner.md) antes.

```bash
# 1. Gerar o token de registro (vale ~1 hora):
#    GitHub -> banco-infra -> Settings -> Actions -> Runners
#    -> New self-hosted runner -> Linux -> copiar o token do passo "Configure"

# 2. No servidor, ler o token sem eco (não fica no histórico do shell)
cd /opt/gini/infra
read -rs RUNNER_TOKEN && export RUNNER_TOKEN

# 3. Instalar (as variáveis são passadas explicitamente: em alguns servidores
#    o sudo ignora o -E e o script falharia com "RUNNER_TOKEN não informado")
sudo REPO_URL=https://github.com/PI-AMS-2025-2026/banco-infra \
     RUNNER_TOKEN="$RUNNER_TOKEN" \
     ./scripts/install-runner.sh

# 4. Limpar o token da sessão
unset RUNNER_TOKEN
```

> O `read -rs` não mostra nada enquanto você digita: ele está esperando o token.
> Cole o token (nada aparece na tela) e aperte Enter. Para conferir sem expor o
> valor: `[ -n "$RUNNER_TOKEN" ] && echo "definido (${#RUNNER_TOKEN} caracteres)"`.

### 3.1 Validar

```bash
systemctl status "actions.runner.*" --no-pager   # active (running)
systemctl is-enabled "actions.runner.*"          # enabled  (sobrevive a reboot)
```

Em **Settings → Actions → Runners** o runner deve aparecer como **Idle** com os
rótulos `self-hosted`, `linux`, `x64`, `gini-local`.

### 3.2 Re-registrar ou atualizar a versão

```bash
read -rs RUNNER_TOKEN && export RUNNER_TOKEN
sudo REPO_URL=https://github.com/PI-AMS-2025-2026/banco-infra \
     RUNNER_TOKEN="$RUNNER_TOKEN" \
     RUNNER_VERSION=2.338.0 \
     RUNNER_SHA256=af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32 \
     ./scripts/install-runner.sh --reconfigure
unset RUNNER_TOKEN
```

Ao trocar a versão, pegue **versão e checksum juntos** em
<https://github.com/actions/runner/releases> — nunca estime o hash.

Remoção do runner: seção 3 de [`seguranca-runner.md`](seguranca-runner.md#3-remoção-do-runner).

### 3.3 Problemas comuns na instalação do runner

**`sudo: preserving the entire environment is not supported, '-E' is ignored`
seguido de `RUNNER_TOKEN não informado`**
O sudo do servidor descarta o ambiente. Passe `RUNNER_TOKEN="$RUNNER_TOKEN"` na
própria linha do `sudo`, como na seção 3.

**`Failed: Must run from runner root or install is corrupt`**
O registro já deu certo (`Runner successfully added`); só a instalação do
serviço falhou, porque o `svc.sh` precisa rodar de dentro de `/opt/gini/runner`.
Não gere outro token. Instale o serviço à mão:

```bash
cd /opt/gini/runner
sudo ./svc.sh install gha-runner
sudo ./svc.sh start
sudo ./svc.sh status
```

Depois valide como na seção 3.1.

**`E: Unable to locate package libicu80` / `libicu79`**
O script tenta algumas versões do `libicu` e só uma existe em cada release do
Ubuntu; o aviso é inofensivo se o runner iniciar. Se o runner reclamar de ICU
(`Couldn't find a valid ICU package`), instale a versão disponível:

```bash
apt-cache search libicu | grep -E '^libicu[0-9]+ '
sudo apt-get install -y libicu<versão>   # ex.: libicu74 no Ubuntu 24.04
```

---

## 4. Criar o `.env` de cada ambiente

O `.env` **nunca** é versionado. Os modelos ficam em
`environments/<env>/.env.example`. Descrição campo a campo em
[`variaveis-e-secrets.md`](variaveis-e-secrets.md).

```bash
ENV=dev   # repita para staging e production

# 1. Criar o arquivo já com o modo e o dono corretos
sudo install -o gha-runner -g gha-runner -m 600 \
  /opt/gini/infra/environments/$ENV/.env.example \
  /opt/gini/$ENV/.env

# 2. Gerar os segredos (valores distintos por ambiente!)
openssl rand -base64 32   # -> POSTGRES_PASSWORD
openssl rand -base64 48   # -> JWT_SECRET

# 3. Editar e substituir TODOS os CHANGE_ME
sudo -u gha-runner nano /opt/gini/$ENV/.env

# 4. Conferir
sudo stat -c '%a %U:%G %n' /opt/gini/$ENV/.env      # 600 gha-runner:gha-runner
sudo grep -c CHANGE_ME /opt/gini/$ENV/.env          # precisa ser 0
```

O `deploy.sh` aborta se o modo não for `600` ou se sobrar algum `CHANGE_ME`.

---

## 5. Primeiro deploy

Pré-requisitos:

- seções 2, 3 e 4 concluídas;
- secrets `GHCR_USER` / `GHCR_PULL_TOKEN` e variables `FRONTEND_IMAGE` /
  `BACKEND_IMAGE` configurados no repositório;
- environments `dev`/`staging`/`production` criados
  ([`estrategia-gatilhos.md`](estrategia-gatilhos.md#5-github-environments));
- imagens já publicadas no ghcr.io pelas pipelines dos repos de aplicação.

No primeiro deploy não existe `images.env`; o `deploy.sh` o cria com as tags
padrão da branch do ambiente (`dev` → `dev`, `staging` → `staging`,
`production` → `main`).

### 5.1 Dev (automático)

Faça um push na branch `dev` de um dos repos de aplicação e aguarde o
`repository_dispatch`. Ou dispare à mão:

```bash
gh api repos/PI-AMS-2025-2026/banco-infra/dispatches \
  -f event_type=image-published \
  -f 'client_payload[service]=backend' \
  -f 'client_payload[tag]=dev' \
  -f 'client_payload[branch]=dev'

gh run list --workflow=deploy-dev.yml --limit 3
```

### 5.2 Staging e production (manual)

```bash
gh workflow run deploy.yml \
  -f environment=staging -f service=both \
  -f frontend_tag=staging -f backend_tag=staging
```

Para `production`, use tags vindas de builds da branch `main` e aprove o
deployment pendente.

### 5.3 Deploy manual direto no servidor (contorno)

Útil se o runner estiver fora do ar:

```bash
cd /opt/gini/infra
sudo -u gha-runner env \
  GHCR_USER=<usuario> GHCR_PULL_TOKEN=<pat> \
  BACKEND_TAG=sha-a1b2c3d \
  ./scripts/deploy.sh dev
```

### 5.4 Instalar os timers de backup

```bash
cd /opt/gini/infra
sudo install -m 0644 scripts/systemd/gini-backup@.service /etc/systemd/system/
sudo install -m 0644 scripts/systemd/gini-backup@.timer   /etc/systemd/system/
sudo systemctl daemon-reload

sudo systemctl enable --now gini-backup@dev.timer
sudo systemctl enable --now gini-backup@staging.timer
sudo systemctl enable --now gini-backup@production.timer

systemctl list-timers 'gini-backup@*'
```

### 5.5 Validar o ambiente

```bash
cd /opt/gini/dev
sudo -u gha-runner docker compose -p gini-dev \
  --env-file .env --env-file images.env -f docker-compose.yml ps
# db, backend e frontend como "healthy"; a linha do db SEM porta publicada

curl -fsS http://127.0.0.1:8081/actuator/health   # backend dev
curl -fsS http://127.0.0.1:3001/api/health        # frontend dev
```

### 5.6 Validar a persistência após reboot

```bash
sudo reboot
# ... reconectar ...
sudo -u gha-runner docker compose -p gini-dev \
  --env-file /opt/gini/dev/.env --env-file /opt/gini/dev/images.env \
  -f /opt/gini/dev/docker-compose.yml ps
```

Os três serviços voltam sozinhos (`restart: unless-stopped`) e os dados
permanecem (volume nomeado `gini-dev_db-data`).

---

## 6. Deploy do dia a dia

| Ambiente | Como |
| --- | --- |
| `dev` | automático: push na branch `dev` do repo de aplicação |
| `staging` | **Actions → "Deploy manual (staging/production)"** com `environment=staging` |
| `production` | idem, com `environment=production` + aprovação de um revisor |

O que o `deploy.sh` faz, em ordem:

1. valida ambiente, tags (`^[A-Za-z0-9_.-]{1,128}$`), `.env` (existência e modo
   `600`) e nomes de imagem;
2. cria `images.env` com as tags padrão, se for o primeiro deploy;
3. autentica no ghcr.io (`--password-stdin`), se houver token;
4. sincroniza o `docker-compose.yml` do checkout para `/opt/gini/<env>/`;
5. **backup pré-deploy** (se já existe container `db`) — falha aqui **aborta** o
   deploy;
6. salva `images.env` em `images.env.previous` e grava as tags novas (a tag não
   informada é preservada);
7. `docker compose pull` — falha antecipada se a tag não existir, **sem** mexer
   no que está no ar;
8. `docker compose up -d --remove-orphans`;
9. espera `db`, `backend` e `frontend` ficarem `healthy` (até `HEALTH_TIMEOUT`),
   confere `/actuator/health` e `/api/health` nas portas publicadas e procura a
   confirmação do Flyway nos logs (ausência = **aviso**, não falha). Se o
   Mailpit estiver ligado, confere a saúde dele, também só com **aviso**;
10. em falha: imprime `logs --tail=100`, faz rollback e sai com código ≠ 0;
11. em sucesso: grava `releases.log`, marca `.deploy-ok` e roda
    `docker image prune -f`.

---

## 7. Rollback

### 7.1 Automático

Já está no fluxo de falha do `deploy.sh` (passo 10). O job fica **vermelho mesmo
quando o rollback funciona** — a versão pedida não entrou no ar.

### 7.2 Manual

```bash
# 1. Descobrir a tag anterior
tail -20 /opt/gini/production/releases.log
cat /opt/gini/production/images.env.previous

# 2. Rodar o deploy com a tag anterior
gh workflow run deploy.yml \
  -f environment=production -f service=both \
  -f frontend_tag=sha-ANTERIOR -f backend_tag=sha-ANTERIOR
```

### 7.3 Atenção: rollback não reverte o banco

As migrations do Flyway rodam no startup do backend. Voltar a imagem **não**
desfaz migration aplicada. Se a release nova mudou o schema de forma
incompatível, o caminho é restaurar o backup pré-deploy (seção 9).

Por isso as migrations devem ser **compatíveis com a versão anterior** do código
(*expand/contract*) — detalhes em
[`estrategia-gatilhos.md`](estrategia-gatilhos.md#73-o-limite-do-rollback-flyway).

---

## 8. Backup

### 8.1 Automático

Timer systemd `gini-backup@<env>.timer`, diário às **03:00**, com
`Persistent=true` (se o servidor estava desligado, roda ao ligar) e atraso
aleatório de até 5 minutos para os três ambientes não concorrerem pelo disco.

```bash
systemctl list-timers 'gini-backup@*'
journalctl -u gini-backup@production.service -n 50 --no-pager
```

### 8.2 Manual

```bash
cd /opt/gini/infra
sudo -u gha-runner ./scripts/backup-db.sh production
# ou, pela unidade systemd:
sudo systemctl start gini-backup@production.service
```

### 8.3 O que o backup faz

1. `pg_dump -Fc --no-owner --no-privileges` via `docker compose exec -T db`;
2. grava em `/opt/gini/backups/<env>/<env>-AAAAMMDD-HHMMSS.dump`, modo `600`
   (escreve primeiro um `.parcial` e só renomeia depois de validar — nunca fica
   um dump truncado no diretório);
3. **valida** o arquivo rodando `pg_restore --list` dentro do container;
4. aplica a retenção de `BACKUP_RETENTION_DAYS` (padrão 7) com `find -mtime`;
5. sai com erro se qualquer etapa falhar.

```bash
ls -lh /opt/gini/backups/production/
tail -5 /opt/gini/production/releases.log
```

### 8.4 Fora do escopo

Cópia dos dumps para **fora do host** (outro disco, NAS, nuvem) não está nesta
fase. Hoje um backup e o banco vivem na mesma máquina — perda do servidor é
perda dos dois. Mitigação manual recomendada antes de qualquer janela de risco:

```bash
scp <servidor>:/opt/gini/backups/production/production-*.dump ./
```

---

## 9. Restauração

### 9.1 Validar um dump sem tocar no ambiente

**Faça isso antes de restaurar em produção.** Sobe um PostgreSQL descartável:

```bash
DUMP=/opt/gini/backups/production/production-20261008-030000.dump

docker run -d --name gini-teste-restore \
  -e POSTGRES_PASSWORD=teste -e POSTGRES_USER=gini -e POSTGRES_DB=gini \
  postgres:17-alpine

# esperar ficar pronto
until docker exec gini-teste-restore pg_isready -U gini -q; do sleep 2; done

# restaurar
docker exec -i gini-teste-restore \
  pg_restore --clean --if-exists --no-owner --no-privileges \
  -U gini -d gini < "$DUMP"

# conferir que as tabelas vieram
docker exec gini-teste-restore psql -U gini -d gini -c '\dt'

# limpar
docker rm -f gini-teste-restore
```

### 9.2 Restaurar no ambiente

Operação **destrutiva** (`pg_restore --clean --if-exists` apaga os objetos
atuais). Exige `--yes`:

```bash
cd /opt/gini/infra

# sem --yes, o script recusa e não altera nada (código de saída 3)
sudo -u gha-runner ./scripts/restore-db.sh production \
  /opt/gini/backups/production/production-20261008-030000.dump

# com confirmação explícita
sudo -u gha-runner ./scripts/restore-db.sh production \
  /opt/gini/backups/production/production-20261008-030000.dump --yes
```

Sequência executada: valida o dump → para `frontend` e `backend` (o `db`
continua de pé) → `pg_restore --clean --if-exists --exit-on-error` → sobe
`backend` e `frontend` → espera o backend ficar `healthy` → confere
`/actuator/health`.

Depois do restore, o Flyway reaplica no próximo start do backend o que faltar
entre a versão do dump e a versão do código.

---

## 10. Logs e inspeção

```bash
ENV=production
cd /opt/gini/$ENV
alias dc="sudo -u gha-runner docker compose -p gini-$ENV --env-file .env --env-file images.env -f docker-compose.yml"

dc ps                            # estado e saúde dos serviços
dc logs -f backend               # acompanhar o backend
dc logs --tail=200 frontend
dc logs --tail=200 backend | grep -i flyway    # migrations
dc exec -T db psql -U "$(grep '^POSTGRES_USER=' .env | cut -d= -f2)" \
     -d "$(grep '^POSTGRES_DB=' .env | cut -d= -f2)" -c '\dt'

# histórico de deploys do ambiente
tail -30 /opt/gini/$ENV/releases.log

# runner
journalctl -u "actions.runner.*" -n 100 --no-pager

# backup
journalctl -u "gini-backup@$ENV.service" -n 50 --no-pager

# host
docker system df                 # espaço usado por imagens/volumes
df -h /                          # espaço em disco
docker stats --no-stream
```

Os logs de container já têm rotação (`json-file`, `max-size 10m`,
`max-file 3`), definida no `daemon.json` e reforçada no compose.

---

### 10.1 Ler os e-mails de teste (Mailpit)

Em dev e staging o backend envia o e-mail de recuperação de senha ao Mailpit, que
o captura sem entregar a ninguém. A interface web só escuta em `127.0.0.1` do
servidor; acesse pelo seu computador com um túnel SSH:

```bash
# dev (8025) — para staging troque por 8026
ssh -L 8025:127.0.0.1:8025 <usuario>@<servidor>
# depois abra http://localhost:8025
```

Ou direto no servidor:

```bash
docker compose -p gini-dev --env-file .env --env-file images.env \
  -f docker-compose.yml logs --tail=50 mailpit
```

As mensagens ficam em memória e somem quando o container é recriado. Para trocar
por SMTP real num ambiente, apague `COMPOSE_PROFILES` do `.env`, ajuste os
`SMTP_*` e rode o deploy do backend; o container antigo do Mailpit é removido
pelo `--remove-orphans`.

## 11. Troubleshooting

### O job fica em "Waiting for a runner"

```bash
systemctl status "actions.runner.*" --no-pager
sudo systemctl restart "actions.runner.*"
```

Confira em **Settings → Actions → Runners** se o runner está `Idle` e se os
rótulos batem com `runs-on: [self-hosted, linux, x64, gini-local]`.

### Deploy falha no `docker compose pull`

Causas, em ordem de probabilidade:

1. **tag não existe** no ghcr.io — confira em *Packages* no GitHub, ou:
   `docker manifest inspect ghcr.io/<owner>/<repo>:<tag>`;
2. **PAT sem `read:packages`** ou expirado → rotacione `GHCR_PULL_TOKEN`
   ([`seguranca-runner.md`](seguranca-runner.md#28-rotação-do-pat-do-ghcrio));
3. **pacote privado** e secrets ausentes.

O ambiente em execução **não** é afetado: o `images.env` é revertido antes de
qualquer `up`.

### Backend não fica `healthy`

```bash
dc logs --tail=200 backend
```

Suspeitos mais comuns:

- **migration do Flyway falhou** → procure `FlywayException` nos logs;
- `.env` com `SPRING_DATASOURCE_*` incoerente (usuário/senha/banco);
- **faltou variável obrigatória do perfil `prod`** (`SMTP_HOST`, `SMTP_USERNAME`,
  `SMTP_PASSWORD`, `SMTP_FROM`, `FRONTEND_URL`) → o contexto Spring falha logo
  no início, com `Could not resolve placeholder` nos logs. O `docker compose`
  já recusa subir se alguma estiver ausente no `.env`;
- banco ainda subindo — o `start_period` do backend é 90 s; se o host for lento,
  aumente `HEALTH_TIMEOUT` no deploy;
- **a imagem do backend não tem `curl` nem `wget`** — o healthcheck do compose
  tenta os dois e, sem nenhum deles, o container nunca sai de `starting`, mesmo
  com a aplicação funcionando. Confirme:

  ```bash
  docker run --rm --entrypoint sh ghcr.io/pi-ams-2025-2026/backend-java:<tag> \
    -c 'command -v curl || command -v wget || echo "FALTAM OS DOIS"'
  ```

  Se faltarem, o **repositório do backend** precisa adicionar uma linha ao
  Dockerfile (ex.: `RUN apt-get update && apt-get install -y --no-install-recommends curl`
  em base Debian/Ubuntu, ou `RUN apk add --no-cache curl` em Alpine). Bases
  comuns de Spring Boot já atendem: `eclipse-temurin:21-jre` tem curl e wget,
  `eclipse-temurin:21-jre-alpine` tem wget; variantes `-slim` e distroless não
  têm nenhum dos dois.

  O **frontend** não tem esse problema: o healthcheck dele usa o próprio
  `node -e` com `fetch`, que existe em qualquer imagem Next.js.

### Recuperação de senha não envia e-mail (dev/staging)

1. O `.env` precisa ter `COMPOSE_PROFILES=mailpit`, `SMTP_HOST=mailpit` e
   `SMTP_PORT=1025`. Confirme que o container existe:
   `docker ps --filter name=gini-<env>-mailpit`.
2. Se `SMTP_HOST` apontar para um servidor real, o e-mail não aparece no
   Mailpit — vai para esse servidor.
3. Com `SMTP_AUTH=true` o Mailpit recusa a conexão; use `false` (e
   `SMTP_STARTTLS=false`).
4. `deploy.sh` abortou citando `COMPOSE_PROFILES=mailpit` → o ambiente é
   `production`; remova a linha e configure um SMTP real.

### Frontend `healthy` mas a tela não carrega dados

A URL da API é **embutida no build** do Next.js. Se a imagem de staging foi
buildada com a URL de dev, o frontend chama a API errada. Confirme que a tag veio
de um build da branch correta (`staging` → staging, `main` → produção) e que
`NEXT_PUBLIC_API_URL_*` está certa no repo do frontend.

Verifique também `FRONTEND_URL` no `.env` do ambiente: é a origem usada no CORS
do backend e precisa ser exatamente a do frontend (esquema + host + porta, sem
barra final). Aceita uma única origem. Depois de alterar, rode o deploy do
backend de novo para o container receber o valor.

### Conflito de porta ao subir

```bash
sudo ss -ltnp | grep -E ':(3000|3001|3002|8080|8081|8082)'
```

Ajuste `FRONTEND_PORT`/`BACKEND_PORT` no `.env` do ambiente e libere a porta nova
no UFW (`sudo ufw allow <porta>/tcp`).

### `deploy.sh` aborta dizendo que o `.env` está com modo errado

```bash
sudo chown gha-runner:gha-runner /opt/gini/<env>/.env
sudo chmod 600 /opt/gini/<env>/.env
```

### Disco cheio

```bash
docker system df
docker image prune -f           # já roda no fim de cada deploy bem-sucedido
docker image prune -a -f        # agressivo: remove imagens não usadas por nenhum container
ls -lhS /opt/gini/backups/*/    # dumps grandes? reduza BACKUP_RETENTION_DAYS
```

**Nunca** use `docker system prune --volumes`: apagaria os volumes dos bancos.

### Banco não sobe depois de um reboot

```bash
systemctl status docker
docker volume ls | grep db-data     # gini-dev_db-data, gini-staging_db-data, ...
dc logs db
```

Se o volume foi removido por engano, restaure o backup mais recente (seção 9).

---

## 12. Manutenção periódica

| Frequência | Tarefa |
| --- | --- |
| Semanal | conferir `systemctl list-timers 'gini-backup@*'` e se há dumps recentes nos três ambientes |
| Semanal | `df -h /` e `docker system df` |
| Mensal | `sudo apt-get update && sudo apt-get upgrade` e reboot em janela acordada |
| Mensal | testar um restore de dump em banco temporário (seção 9.1) |
| Trimestral | rotacionar `GHCR_PULL_TOKEN` ([`seguranca-runner.md`](seguranca-runner.md#28-rotação-do-pat-do-ghcrio)) |
| Trimestral | atualizar o self-hosted runner (seção 3.2) |
| Trimestral | rever o checklist de [`seguranca-runner.md`](seguranca-runner.md#4-checklist-de-revisão) |

---

## Fora do escopo desta fase

Mencionado aqui só para registrar a decisão: **AWS**, **proxy reverso com
TLS/HTTPS**, **monitoramento/alertas** e **cópia de backups para fora do host**
não fazem parte desta entrega. Ver [`../README.md`](../README.md) e
[`decisoes-tecnicas.md`](decisoes-tecnicas.md).
