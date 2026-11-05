# Decisões técnicas (ADRs)

Registros curtos das decisões de arquitetura da infraestrutura. Formato:
**contexto → decisão → consequências**.

Status possíveis: `Aceita`, `Substituída`, `Revisar`.

---

## ADR-001 — CI (testes/build) nos repos de aplicação, CD (deploy) neste repositório

**Status:** Aceita · **Data:** 2026-10-08

**Contexto.** O projeto tem quatro repositórios independentes
(`frontend-nextjs`, `backend-java`, `banco-infra`, `documentacao`), não é
monorepo. Era preciso decidir onde ficam os Dockerfiles, os testes e o deploy.

**Decisão.**

- Cada repositório de aplicação é dono do **seu** Dockerfile, dos seus testes e
  do job que publica a imagem no ghcr.io (`ci-tests` → `build-release-images`).
- Este repositório é dono da **orquestração, do deploy e da operação**:
  `docker-compose.yml`, scripts de servidor, workflows de deploy, backup e
  documentação operacional.

**Consequências.**

- Quem altera o build da aplicação não precisa tocar na infraestrutura, e
  vice-versa.
- O contrato entre os repos (nomes de imagem, tags, portas, rotas de health,
  variáveis do backend) tem de ser explícito e estável — está em
  [`estrategia-gatilhos.md`](estrategia-gatilhos.md) e no README.
- Uma mudança que atravessa os dois lados (ex.: variável nova no backend) exige
  dois PRs coordenados.
- Alterar o compose não requer rebuild de imagem: o `deploy.sh` sincroniza o
  arquivo a cada deploy.

---

## ADR-002 — Registry: GitHub Container Registry (ghcr.io)

**Status:** Aceita · **Data:** 2026-10-08

**Contexto.** As imagens precisam de um registry acessível pelo servidor local.
Alternativas: Docker Hub, ghcr.io, Amazon ECR, registry auto-hospedado.

**Decisão.** `ghcr.io`, com imagens nomeadas
`ghcr.io/<owner>/<nome-do-repo>` em minúsculas.

**Consequências.**

- Autenticação no push sai de graça: o `GITHUB_TOKEN` do próprio repo de
  aplicação, com `permissions: packages: write`.
- Sem os limites de pull do Docker Hub para contas gratuitas.
- Para baixar imagens **privadas**, o servidor precisa de um PAT com
  `read:packages` (secret `GHCR_PULL_TOKEN`), que exige rotação. Se o grupo
  tornar os pacotes públicos, o login vira opcional.
- ECR foi descartado porque AWS está fora do escopo desta fase (ADR-007).
- Registry auto-hospedado foi descartado: mais um serviço para operar, sem
  benefício para o tamanho do projeto.

---

## ADR-003 — Deploy sempre por tag imutável `sha-<7>`

**Status:** Aceita · **Data:** 2026-10-08

**Contexto.** A pipeline publica várias tags: `sha-<7 chars>`, nome da branch
(`dev`/`staging`/`main`), `X.Y.Z` e `X.Y` em tag git, e `latest` a partir de
`main`. Tags de branch e `latest` são **mutáveis**: o mesmo nome aponta para
conteúdos diferentes ao longo do tempo.

**Decisão.** Os deploys usam a tag **imutável** `sha-<7>`. As tags mutáveis
servem apenas de conveniência para desenvolvimento local e como **tag padrão do
primeiro deploy** de um ambiente, quando ainda não existe `images.env`
(`dev` → `dev`, `staging` → `staging`, `production` → `main`).

**Consequências.**

- `/opt/gini/<env>/images.env` sempre diz exatamente qual commit está no ar, e
  `releases.log` guarda o histórico.
- Rollback é determinístico: reaplicar a tag anterior traz o mesmo binário.
- O `docker compose pull` não pode ser substituído por `latest` + restart: cada
  deploy informa a tag explicitamente.
- Custo: quem dispara um deploy manual precisa copiar a tag de algum lugar
  (Actions do repo de aplicação, ou a aba *Packages*).

---

## ADR-004 — Três ambientes no mesmo host, isolados por projeto Compose

**Status:** Aceita · **Data:** 2026-10-08 · **Revisar quando:** houver mais de
um servidor, ou produção ganhar usuários reais

**Contexto.** Existe **um** servidor Ubuntu local. São necessários três
ambientes: `dev`, `staging`, `production`.

**Decisão.** Os três convivem no mesmo host, isolados por:

| Eixo | Como |
| --- | --- |
| Projeto Compose | `-p gini-dev`, `-p gini-staging`, `-p gini-production` |
| Diretório | `/opt/gini/dev`, `/opt/gini/staging`, `/opt/gini/production` |
| Portas publicadas | dev `3001`/`8081`, staging `3002`/`8082`, production `3000`/`8080` |
| Volumes | `gini-<env>_db-data` (prefixo do projeto) |
| Redes | `gini-<env>_backend-net` e `gini-<env>_frontend-net` |
| Banco | um container `db` por ambiente, sem porta publicada |

Um **único** `docker-compose.yml` parametrizado por variáveis atende os três,
evitando três arquivos que divergem com o tempo.

**Consequências.**

- Custo zero de infraestrutura extra; simples de operar para um TCC.
- **Sem isolamento de falha**: perda do host derruba os três ambientes, e um
  ambiente pode consumir CPU/RAM/disco dos outros.
- Um `docker system prune --volumes` descuidado apagaria os três bancos — por
  isso o runbook proíbe o comando.
- O rótulo `ENV_NAME` aparece nos nomes de container e nas labels, para não
  confundir ambientes ao inspecionar o host.
- Se o projeto crescer, a migração natural é separar produção em outro host (ou
  na AWS, ADR-007) reaproveitando o mesmo compose.

---

## ADR-005 — Integração entre repos por `repository_dispatch`

**Status:** Aceita · **Data:** 2026-10-08

**Contexto.** O deploy de `dev` deve acontecer automaticamente quando um repo de
aplicação publica uma imagem nova. `workflow_run` não atravessa repositórios.

**Decisão.** O repo de aplicação chama
`POST /repos/<owner>/banco-infra/dispatches` com
`event_type: image-published` e `client_payload: { service, tag, sha, branch }`,
usando o secret `INFRA_DISPATCH_TOKEN`. **Somente a branch `dev`** dispara.
Staging e produção são `workflow_dispatch` manual.

**Consequências.**

- Contrato explícito e tipado entre os repos; o payload é validado por regex
  antes de qualquer comando no servidor.
- Os **nomes das imagens vêm das Variables deste repositório**, nunca do
  payload — senão quem conseguisse disparar o dispatch poderia apontar o deploy
  para uma imagem arbitrária.
- `repository_dispatch` executa sempre o workflow da **branch padrão** deste
  repositório: mudanças em `deploy-dev.yml` só valem depois do merge em `main`,
  e não há como testá-las a partir de uma branch.
- Exige um PAT com escrita neste repositório nos repos de aplicação, com sua
  própria rotação. O `GITHUB_TOKEN` não serve (é escopado ao repo de origem).

---

## ADR-006 — Backup pré-deploy obrigatório; rollback de imagem não reverte o banco

**Status:** Aceita · **Data:** 2026-10-08

**Contexto.** As migrations são aplicadas pelo **Flyway no startup do backend**,
e vivem no repositório do backend. Voltar a imagem não desfaz uma migration já
aplicada: o código antigo passaria a rodar sobre um schema novo.

**Decisão.**

1. O `deploy.sh` executa `backup-db.sh <env>` **antes** de qualquer `up`, sempre
   que já existir um container `db`. **Falha no backup aborta o deploy.**
2. O rollback automático restaura apenas as **tags das imagens**
   (`images.env.previous`) e deixa explícito, na saída, que o banco não foi
   revertido.
3. O job termina **vermelho mesmo quando o rollback dá certo**: a versão pedida
   não entrou no ar.
4. A recomendação para o grupo é escrever migrations **compatíveis com a versão
   anterior** do código (*expand/contract*): adicionar coluna nullable ou com
   default; nunca renomear/remover coluna na mesma release que passa a usar o
   nome novo — deixar a remoção para a release seguinte.
5. Backups diários automáticos às 03:00 por timer systemd, com dump validado
   via `pg_restore --list` e retenção de 7 dias (padrão).

**Consequências.**

- Existe sempre um ponto de retorno imediatamente anterior a cada deploy.
- Reverter de verdade uma migration destrutiva exige `restore-db.sh`, que é
  **destrutivo e manual** (exige `--yes`) e implica perda dos dados gravados
  após o dump.
- O deploy fica alguns segundos mais lento (o dump) — aceitável.
- A disciplina de *expand/contract* é uma convenção humana: nada na pipeline a
  impede de ser violada.

---

## ADR-007 — Escopo desta fase: servidor local, sem AWS, TLS ou monitoramento

**Status:** Aceita · **Data:** 2026-10-08 · **Revisar quando:** a aplicação for
exposta fora da rede da Fatec, ou houver usuários reais

**Contexto.** Há tempo limitado e um servidor local disponível. A tentação é
resolver tudo (nuvem, HTTPS, observabilidade) de uma vez.

**Decisão.** Esta fase entrega **apenas** o deploy das aplicações no servidor
Ubuntu local. Ficam explicitamente **fora do escopo**:

| Fora do escopo | Consequência atual | Quando virará necessário |
| --- | --- | --- |
| **AWS** (ou qualquer nuvem) | ponto único de falha; sem disponibilidade fora da rede local | exposição pública ou requisito de uptime |
| **Proxy reverso + TLS/HTTPS** | tráfego em HTTP puro, acesso por `host:porta`; cookies/JWT trafegam sem cifra | qualquer acesso fora da rede confiável |
| **Monitoramento e alertas** | falha só é percebida por quem olhar; sem métricas históricas | antes de ter usuários reais |
| **Cópia de backups para fora do host** | dump e banco na mesma máquina: perda do host = perda dos dois | assim que houver dado que não se possa perder |

**Consequências.**

- A entrega fica pequena, auditável e termina no prazo.
- Os riscos acima estão **documentados**, não ignorados: a documentação não
  sugere que o ambiente é seguro para exposição pública.
- As escolhas feitas não impedem a evolução: o mesmo compose roda em uma EC2, e
  um Caddy/Traefik na frente não exige mudança nas imagens, só o remapeamento
  das portas publicadas.
- Mitigação parcial já aplicada: UFW com `deny incoming`, banco sem porta
  publicada, backup diário validado, segredos fora do Git.

---

## ADR-008 — PostgreSQL 16 (`postgres:16-alpine`)

**Status:** Aceita · **Data:** 2026-10-08 · **Revisar quando:** o backend
declarar dependência de recurso de outra major

**Contexto.** O projeto não fixou a versão do PostgreSQL em nenhum documento.
Era preciso escolher uma para o compose.

**Decisão.** `postgres:16-alpine`, com a major **fixada** (nunca `postgres:latest`).

**Consequências.**

- Versão estável, amplamente suportada pelo driver JDBC e pelo Flyway.
- `-alpine` reduz o tamanho da imagem.
- Trocar de major (16 → 17) **não** é transparente: o diretório de dados não é
  compatível. A troca exige `pg_dump` na major antiga, recriar o volume e
  restaurar — procedimento que precisa de janela planejada.
- `POSTGRES_INITDB_ARGS=--encoding=UTF8 --locale=C` mantém o locale previsível
  entre ambientes e recriações de volume.
- **Confirme com o grupo** se alguma dependência do backend exige outra major.

---

## ADR-009 — Um `.env` por ambiente no servidor, fora do Git

**Status:** Aceita · **Data:** 2026-10-08

**Contexto.** Os ambientes precisam de senhas de banco, `JWT_SECRET` e origens
de CORS distintas. O repositório deve ser tratado como potencialmente público.

**Decisão.**

- Segredos e configuração ficam em `/opt/gini/<env>/.env`, criado **à mão** no
  servidor, modo `600`, dono `gha-runner`, **fora do Git**.
- O repositório versiona apenas `environments/<env>/.env.example`, com
  `CHANGE_ME` nos campos sensíveis.
- As **tags das imagens** ficam em um arquivo separado, `images.env`, porque são
  a única parte reescrita automaticamente a cada deploy.
- O `deploy.sh` aborta se o `.env` não estiver em modo `600` ou se ainda contiver
  `CHANGE_ME`.

**Consequências.**

- Nenhum segredo trafega pelo GitHub Actions nem aparece em log de workflow.
- Separar `.env` de `images.env` deixa o rollback trivial: basta restaurar
  `images.env.previous`, sem risco de mexer em segredo.
- Custo: provisionar um servidor novo exige recriar os `.env` à mão (documentado
  no [runbook](runbook.md#4-criar-o-env-de-cada-ambiente)).
- Não há gestor de segredos (Vault, SSM) — coerente com ADR-007.

---

## ADR-010 — Runner self-hosted no nível do repositório, com gatilhos restritos

**Status:** Aceita · **Data:** 2026-10-08

**Contexto.** O servidor é local, sem IP público e sem acesso de entrada
liberado. Um runner hospedado pelo GitHub não alcançaria o host, o que exigiria
abrir SSH para a internet.

**Decisão.** Um self-hosted runner instalado no próprio servidor, rodando como
serviço systemd com o usuário `gha-runner`, registrado **no repositório** (não
na organização), com o rótulo `gini-local`.

**Consequências.**

- Não é preciso expor SSH nem distribuir chave privada de servidor como secret.
- O runner tem acesso ao host, e `gha-runner` está no grupo `docker` —
  equivalente a root. Mitigações obrigatórias (gatilhos só
  `repository_dispatch`/`workflow_dispatch`, nunca `pull_request`; aprovação de
  workflows de colaboradores externos; Environments com revisor; usuário sem
  sudo; validação por regex de toda entrada externa) estão em
  [`seguranca-runner.md`](seguranca-runner.md).
- Manutenção recai sobre o grupo: atualizar o runner, o SO e o Docker.
- Se o servidor estiver fora do ar, não há deploy — o contorno é rodar
  `scripts/deploy.sh` por SSH
  ([runbook](runbook.md#53-deploy-manual-direto-no-servidor-contorno)).
