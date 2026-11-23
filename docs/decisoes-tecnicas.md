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

**Atualização (2026-11-13) — sufixo de ambiente no frontend.**

> **Substituída por [ADR-012](#adr-012--imagem-única-do-frontend-com-url-da-api-em-runtime)
> (após a Fase B).** Durante a transição (Fase A) os dois formatos de tag do
> frontend convivem: `sha-<7>` (imagem única) e `sha-<7>-<ambiente>` (legado,
> descrito abaixo). O restante deste ADR — deploy sempre por tag imutável —
> continua valendo.

A imagem do
frontend embute `NEXT_PUBLIC_API_URL` no build, então cada ambiente tem uma
imagem diferente. Um mesmo commit pode ser buildado em mais de uma branch
(fast-forward ou rebase-merge de `dev` para `staging`/`main`); com só
`sha-<7>`, o segundo build **sobrescreveria** a tag com outra URL embutida, e
a tag deixaria de ser imutável na prática. Por isso o frontend publica
`sha-<7>-<ambiente>` (ex.: `sha-a1b2c3d-dev`, `sha-a1b2c3d-staging`,
`sha-a1b2c3d-production`). O backend continua em `sha-<7>`: sua imagem é a
mesma em todos os ambientes. Nenhuma mudança de código foi necessária aqui —
a regex `^[A-Za-z0-9_.-]{1,128}$` já aceita o novo formato.

- Ao fazer deploy manual de uma imagem **legado** do frontend, use **sempre** a
  tag do ambiente de destino (`-staging` para staging, `-production` para
  production). A imagem única (`sha-<7>`, ADR-012) é a mesma nos três.

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

**Status:** Aceita — **parcialmente substituída** pelo
[ADR-013](#adr-013--implantação-na-aws-learner-lab-um-ambiente-de-homologação-por-conta-bootstrap-por-script)
no item "AWS" (2026-11-23) · **Data:** 2026-10-08 · **Revisar quando:** a
aplicação for exposta fora da rede da Fatec, ou houver usuários reais

**Contexto.** Há tempo limitado e um servidor local disponível. A tentação é
resolver tudo (nuvem, HTTPS, observabilidade) de uma vez.

**Decisão.** Esta fase entrega **apenas** o deploy das aplicações no servidor
Ubuntu local. Ficam explicitamente **fora do escopo**:

| Fora do escopo | Consequência atual | Quando virará necessário |
| --- | --- | --- |
| **AWS** (ou qualquer nuvem) | ponto único de falha; sem disponibilidade fora da rede local | exposição pública ou requisito de uptime — **atualizado pelo ADR-013:** a AWS passa a hospedar um ambiente de **homologação** por aluno (Learner Lab); a **produção** continua local e este item segue valendo para ela |
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

## ADR-008 — PostgreSQL 17 (`postgres:17-alpine`)

**Status:** Aceita (revisada em 2026-11-09: 16 → 17) · **Data:** 2026-10-08 ·
**Revisar quando:** o backend declarar dependência de recurso de outra major

**Contexto.** O projeto não fixou a versão do PostgreSQL em nenhum documento e
a primeira escolha foi a 16. Depois, o compose de desenvolvimento e o CI do
backend (`backend-java`) passaram a usar a 17, e as migrations do Flyway eram
validadas numa major diferente da que roda nos ambientes hospedados.

**Decisão.** `postgres:17-alpine`, com a major **fixada** (nunca
`postgres:latest`) e **igual à do backend** (compose local e job
`migrations-postgres` do CI). Ao mudar a major, altere os três lugares juntos.

**Consequências.**

- Versão estável, amplamente suportada pelo driver JDBC e pelo Flyway.
- `-alpine` reduz o tamanho da imagem.
- Trocar de major (16 → 17, por exemplo) **não** é transparente: o diretório de dados não é
  compatível. A troca exige `pg_dump` na major antiga, recriar o volume e
  restaurar — procedimento que precisa de janela planejada.
- `POSTGRES_INITDB_ARGS=--encoding=UTF8 --locale=C` mantém o locale previsível
  entre ambientes e recriações de volume.
- **Ambientes já criados com a 16:** o container `db` 17 não sobe sobre o
  volume da 16 (`database files are incompatible with server`). Migração por
  ambiente, com janela planejada: `scripts/backup-db.sh <env>` → parar o
  ambiente → remover o volume `gini-<env>_db-data` → subir a 17 → restaurar
  com `scripts/restore-db.sh`. O dump em formato custom (`-Fc`) feito na 16
  restaura na 17. Ambientes ainda sem volume não precisam de nada.

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

---

## ADR-011 — Mailpit opcional (perfil `mailpit`) em dev e staging

**Status:** Aceita · **Data:** 2026-11-09

**Contexto.** O backend, no perfil `prod`, exige um SMTP para o e-mail de
recuperação de senha e não sobe sem ele. Nesta fase não há servidor SMTP nem
provedor contratado (ADR-007), e dev/staging não devem enviar e-mail de verdade.

**Decisão.** O serviço `mailpit` (`axllent/mailpit`, mesma versão do compose do
backend) existe no compose único, atrás do perfil Compose `mailpit`. Cada
ambiente liga com `COMPOSE_PROFILES=mailpit` no seu `.env`: os `.env.example` de
`dev` e `staging` já vêm assim; o de `production` não.

**Consequências.**

- O SMTP (`1025`) não é publicado: só o backend o alcança, por `backend-net`.
- A interface web é publicada **apenas em `127.0.0.1`** do servidor. Ela exibe
  todos os e-mails (inclusive links de redefinição de senha), não tem login, e
  portas publicadas pelo Docker contornam o UFW. O acesso é por túnel SSH.
- As mensagens ficam em memória e somem quando o container é recriado.
- Em `production` o Mailpit é proibido: capturaria e-mails de usuários reais sem
  entregá-los. O `deploy.sh` aborta se encontrar o perfil nesse ambiente.
- Mailpit com problema gera apenas aviso no deploy; não causa rollback, porque o
  backend não depende dele para subir.
- Para usar SMTP real em dev/staging, basta apagar `COMPOSE_PROFILES` e trocar os
  `SMTP_*`. `production` exige SMTP real, ainda não definido pelo grupo.

---

## ADR-012 — Imagem única do frontend com URL da API em runtime

**Status:** Aceita — Fase A (transição) · **Data:** 2026-11-23 · **Substitui:**
a atualização de 2026-11-13 do [ADR-003](#adr-003--deploy-sempre-por-tag-imutável-sha-7)
(tags por ambiente), após a Fase B

**Contexto.** O Next.js embute as variáveis `NEXT_PUBLIC_*` no bundle durante o
build. Por isso o frontend era buildado **uma vez por ambiente**, com a URL da
API de cada um (`NEXT_PUBLIC_API_URL_<ENV>` no repo do frontend), e publicado
como `sha-<7>-<ambiente>` (ADR-003). Efeitos colaterais:

- três builds por commit, e nenhuma garantia de que o que foi testado em `dev` é
  o mesmo artefato que vai para `staging`/`production` — não existe promoção;
- uma imagem de um ambiente implantada em outro sobe `healthy`, mas chama a API
  errada (o erro só aparece no navegador);
- a mesma imagem não serve para outro destino (ex.: AWS, quando sair do escopo
  do ADR-007) sem um quarto build.

**Decisão.**

1. O repositório do frontend publica **uma imagem por commit**, `sha-<7>`, com
   um *placeholder* no lugar da URL da API. No startup do container, a imagem
   substitui o placeholder pelo valor da variável **`API_URL`** e, se ela
   estiver ausente, **não sobe** (falha rápida). A imagem carrega o rótulo OCI
   `br.fatec.gini.runtime-api-url=true`.
2. `API_URL` mora no `.env` de cada ambiente no servidor e é repassada ao
   container pelo `docker-compose.yml`. É a URL pela qual o **navegador**
   alcança o backend do ambiente (`http(s)://host[:porta]`, sem barra final).
3. O `deploy.sh`, depois do `pull` e **antes** do `up`, lê o rótulo da imagem do
   frontend:
   - rótulo `true` e `API_URL` ausente ou fora do formato
     `^https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?$` → aborta sem tocar no ambiente
     no ar;
   - sem o rótulo (imagem legado) → segue como antes; `API_URL`, se houver, é
     ignorada e isso só é registrado no log.
   O tipo implantado (`legado`/`unica`) vai para o `releases.log`.
4. Migração em duas fases:
   - **Fase A (atual):** `API_URL` opcional no compose (`${API_URL:-}`); os dois
     formatos de tag convivem e `.env` antigos continuam válidos.
   - **Fase B (pendente de confirmação do grupo):** `API_URL` obrigatória no
     compose (`${API_URL:?...}`) e documentação só com `sha-<7>`.

Procedimento passo a passo, com reversão por etapa:
[runbook §13](runbook.md#13-migração-para-a-imagem-única-do-frontend).

**Consequências.**

- **Um build por commit**, e a mesma imagem testada em `dev` é promovida para
  `staging` e `production` — e pode ser usada, sem rebuild, em qualquer outro
  destino (servidor local ou AWS).
- **Rollback entre formatos funciona:** `images.env.previous` guarda só tags, e
  `API_URL` continua no `.env`. Voltar de uma imagem única para uma legado é
  sempre seguro (a legado ignora `API_URL`); voltar para uma única exige
  `API_URL` válida no `.env` — o `deploy.sh` avisa no rollback se faltar.
- **Trocar `API_URL` exige recriar o container do frontend.** O valor só é lido
  na criação do container; `docker restart` não basta. Rodar o deploy do
  frontend de novo (mesmo com a mesma tag) recria, porque o Compose detecta a
  mudança de configuração.
- Na Fase A, o primeiro deploy de cada ambiente recria o container do frontend
  uma vez, mesmo com imagem legado, porque a configuração dele ganhou a
  variável `API_URL` (vazia). É inofensivo.
- `API_URL` **não é segredo**: ela acaba no JavaScript entregue ao navegador.
  Pode ficar no `.env` junto com os segredos, mas não precisa de rotação.
- O CORS continua sendo controlado por `FRONTEND_URL` no backend; `API_URL` não
  muda o que o backend aceita.
- A verificação depende do rótulo OCI: uma imagem única publicada **sem** o
  rótulo seria tratada como legado e, sem `API_URL`, falharia só no
  healthcheck (com rollback automático). O rótulo faz parte do contrato entre
  os repositórios.
- As variables `NEXT_PUBLIC_API_URL_<ENV>` do repo do frontend ficam obsoletas
  após a Fase B.

**Alternativas descartadas.**

| Alternativa | Por que não |
| --- | --- |
| Manter o build por ambiente (`sha-<7>-<env>`) | Três builds por commit, sem promoção do artefato testado e com o risco de imagem trocada entre ambientes. |
| URL relativa (`/api`) atrás de um proxy reverso no mesmo domínio | Exige proxy reverso, fora do escopo desta fase ([ADR-007](#adr-007--escopo-desta-fase-servidor-local-sem-aws-tls-ou-monitoramento)). Pode voltar à mesa quando houver TLS. |
| *Rewrites* do Next.js encaminhando `/api` ao backend | O servidor Next.js passaria a intermediar todo o tráfego da API (mais um salto, timeouts e cabeçalhos a tratar) e o frontend precisaria alcançar o backend pela rede interna — muda o modelo de CORS e de rede do compose. |
| Frontend busca a configuração em runtime (`/config.json`) antes de chamar a API | Mudança maior no código da aplicação (toda chamada passa a depender de uma requisição prévia) para o mesmo resultado do placeholder. |
| Passar `API_URL` como *build arg* | Continua sendo build por ambiente — é o problema que se quer resolver. |

---

## ADR-013 — Implantação na AWS Learner Lab: um ambiente de homologação por conta, bootstrap por script

**Status:** Aceita · **Data:** 2026-11-23 · **Substitui parcialmente:** o item
"AWS" do [ADR-007](#adr-007--escopo-desta-fase-servidor-local-sem-aws-tls-ou-monitoramento)
· **Revisar quando:** o template CloudFormation for validado, ou se a
produção sair do servidor local

**Contexto.** A disciplina de cloud exige que **cada aluno** implante a
aplicação na **própria** conta AWS Academy Learner Lab, manualmente. O roteiro
que circulava (Notion) tinha falhas: o compose do backend subia um Postgres
próprio e ignorava o RDS, o frontend nunca era iniciado, o build era feito na
instância, faltava a regra de SG para o RDS e os health checks do Target Group
não estavam definidos. O Learner Lab impõe restrições: só `us-east-1`/`us-west-2`,
IAM fechado (só `LabRole`/`LabInstanceProfile`), tipos de instância limitados,
RDS sem Multi-AZ, instâncias paradas ao fim da sessão e orçamento finito.

**Alternativas.**

| | Alternativa | Por que sim / por que não |
| --- | --- | --- |
| A | Seguir o roteiro manual do Notion, com o compose principal (`docker/docker-compose.yml`) copiado para a instância | Reaproveita arquivos, mas o compose principal sobe o próprio banco (o RDS fica sem uso) e depende do `deploy.sh`/runner, que não existem na AWS. Cada aluno repetiria os erros à mão. |
| B | **Console para a infraestrutura + script de bootstrap idempotente no user data**, com compose próprio da AWS e contrato de parâmetros | Atende à exigência de implantação manual, elimina os passos frágeis dentro da instância e deixa cada valor mapeado para um futuro template. **Escolhida.** |
| C | CloudFormation completo desde já | Mais reprodutível, mas o objetivo da disciplina é o processo manual, e um template exige um ciclo de validação no Learner Lab (IAM, limites) que ainda não foi feito. Fica como evolução, com o desenho pronto. |

**Decisão.**

- A AWS hospeda **homologação** (`APP_ENVIRONMENT=staging`, com Mailpit); a
  **produção continua no servidor local** (ADR-007 segue valendo para ela). Um
  ambiente por conta de aluno; sem deploy automático e sem workflow.
- Topologia: VPC com 2 AZs sem NAT, ALB `gini-lb` com listeners 80
  (frontend) e 8080 (API), 2 EC2 (`t3.small`, AL2023) em sub-redes públicas,
  RDS PostgreSQL 17 em sub-redes privadas. SGs em cadeia: internet → ALB →
  EC2 → RDS; sem SSH (Session Manager).
- **Ordem nova:** o ALB é criado **antes** das instâncias, porque
  `FRONTEND_URL` e `API_URL` derivam do DNS dele.
- Cada EC2 roda `aws/docker-compose.aws.yml` (backend + frontend + Mailpit
  opcional, **sem banco**), configurado por `aws/bootstrap-ec2.sh`, chamado
  pelo `aws/user-data.sh`. O bootstrap é idempotente, valida todos os
  parâmetros antes de agir, fixa a versão e o SHA-256 do compose plugin,
  confere o RDS e o rótulo da imagem única do frontend (ADR-012) antes de subir.
- O frontend na AWS usa **somente** a imagem única (`sha-<7>`): é o que permite
  usar o mesmo artefato do servidor local sem rebuild.
- `aws/PARAMETERS.md` é o contrato entre console, bootstrap e o futuro
  CloudFormation (`aws/cloudformation/README.md`).

**Consequências.**

- Cada aluno reproduz o ambiente seguindo `docs/aws-learner-lab.md`; o que
  roda dentro da instância é igual para todos.
- `docker/`, `scripts/deploy.sh` e os workflows **não** mudam: a AWS é um
  caminho paralelo, sem runner, sem `images.env` e sem backup automático
  (o RDS tem backup próprio, opcional).
- **Segredos no user data** (`DB_PASSWORD`, `JWT_SECRET`): visíveis no console
  e nos metadados da instância. Aceito no laboratório (conta individual,
  segredos exclusivos deste ambiente); alternativa documentada: SSM Parameter
  Store, se o `LabRole` permitir. Diverge do ADR-009 (que proíbe segredo fora do
  `.env` do servidor) só neste ambiente.
- Duas instâncias = dois Mailpit: o e-mail de recuperação cai na instância que
  atendeu a requisição; o runbook ensina a procurar nas duas.
- HTTP puro também na AWS (sem TLS): coerente com o ADR-007; o ALB permite
  adicionar HTTPS depois sem mudar as imagens (exigiria certificado e domínio).
- Custos: ~US$ 0,10/h com tudo ligado; o ALB cobra mesmo com as instâncias
  paradas. Destruição documentada.
- As imagens publicadas são só `linux/amd64`: instâncias ARM (`t4g`) não servem
  enquanto os repos de aplicação não publicarem multi-arquitetura.
- Mudanças de versão (tags) são feitas reexecutando o bootstrap em cada
  instância — manual, como a disciplina exige.
