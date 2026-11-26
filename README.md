# banco-infra — Infraestrutura e banco de dados

Repositório de **infraestrutura** do Projeto Integrador (Fatec Itu). Aqui ficam a
orquestração em Docker Compose, o deploy no servidor Ubuntu local e os
procedimentos de operação (backup, restauração, rollback).

> Este repositório **não** hospeda código de aplicação, Dockerfiles nem
> migrations SQL. Cada repositório de aplicação é dono do seu build; este é dono
> do deploy e da operação. Ver [ADR-001](docs/decisoes-tecnicas.md#adr-001--ci-testesbuild-nos-repos-de-aplicação-cd-deploy-neste-repositório).

---

## Repositórios do projeto

| Repositório | Conteúdo |
| --- | --- |
| [frontend-nextjs](https://github.com/PI-AMS-2025-2026/frontend-nextjs) | Frontend em Next.js 16 (porta 3000, health em `/api/health`) |
| [backend-java](https://github.com/PI-AMS-2025-2026/backend-java) | Backend em Java 21 + Spring Boot (porta 8080, health em `/actuator/health`, migrations Flyway) |
| **banco-infra** (este) | Docker Compose, scripts de servidor, workflows de deploy, backup |
| [documentacao](https://github.com/PI-AMS-2025-2026/documentacao) | Documentação acadêmica do TCC |

---

## Stack

- **Docker Engine** + **Docker Compose v2** no Ubuntu Server LTS (22.04 / 24.04, amd64)
- **PostgreSQL 17** (`postgres:17-alpine`), um container por ambiente, **sem porta publicada no host**
- **Mailpit** (`axllent/mailpit`), opcional e só em `dev`/`staging`: caixa de entrada de teste para o e-mail de recuperação de senha, com a interface web presa a `127.0.0.1` ([ADR-011](docs/decisoes-tecnicas.md#adr-011--mailpit-opcional-perfil-mailpit-em-dev-e-staging))
- Imagens de frontend e backend publicadas no **ghcr.io** pelas pipelines dos repos de aplicação
- **GitHub Actions** com **self-hosted runner** instalado no próprio servidor

---

## Ambientes

Os três ambientes rodam no **mesmo servidor**, isolados por projeto Compose e
por diretório ([ADR-004](docs/decisoes-tecnicas.md#adr-004--três-ambientes-no-mesmo-host-isolados-por-projeto-compose)).

| Ambiente | Branch da app | Projeto Compose | Diretório | Frontend | Backend | Deploy |
| --- | --- | --- | --- | --- | --- | --- |
| `dev` | `dev` | `gini-dev` | `/opt/gini/dev` | `3001` | `8081` | automático (`repository_dispatch`) |
| `staging` | `staging` | `gini-staging` | `/opt/gini/staging` | `3002` | `8082` | manual |
| `production` | `main` | `gini-production` | `/opt/gini/production` | `3000` | `8080` | manual, com aprovação |

As portas são configuráveis pelo `.env` de cada ambiente.

---

## Estrutura do repositório

```
.
├── README.md
├── docker/
│   └── docker-compose.yml          # compose único, parametrizado por variáveis
├── aws/                            # implantação no AWS Learner Lab (homologação, manual)
│   ├── README.md                   # arquitetura e arquivos
│   ├── PARAMETERS.md               # contrato: console ↔ bootstrap ↔ CloudFormation
│   ├── docker-compose.aws.yml      # backend + frontend (+ mailpit), sem banco (RDS)
│   ├── .env.aws.example            # modelo do .env gerado na instância
│   ├── bootstrap-ec2.sh            # prepara a EC2 e sobe a aplicação (idempotente)
│   ├── user-data.sh                # wrapper do user data do launch template
│   └── cloudformation/README.md    # desenho do template futuro (sem template)
├── environments/
│   ├── dev/        (.env.example, images.env.example)
│   ├── staging/    (.env.example, images.env.example)
│   └── production/ (.env.example, images.env.example)
├── scripts/
│   ├── bootstrap-server.sh         # prepara o Ubuntu (Docker, usuário, UFW, diretórios)
│   ├── install-runner.sh           # registra o self-hosted runner como serviço
│   ├── deploy.sh                   # deploy com backup, health check e rollback
│   ├── backup-db.sh                # pg_dump validado + retenção
│   ├── restore-db.sh               # pg_restore (destrutivo, exige --yes)
│   ├── lib/frontend-api-url.sh     # sanidade do frontend: API_URL e rótulo OCI (usado pelo deploy.sh)
│   ├── tests/                      # testes simulados (sem servidor): bash scripts/tests/<teste>.sh
│   └── systemd/                    # gini-backup@.service / gini-backup@.timer
├── .github/workflows/
│   ├── deploy-dev.yml              # automático: repository_dispatch (dev)
│   └── deploy.yml                  # manual: workflow_dispatch (staging/production)
└── docs/
    ├── runbook.md                  # procedimentos de operação
    ├── aws-learner-lab.md          # implantação passo a passo no AWS Learner Lab
    ├── variaveis-e-secrets.md      # catálogo de variáveis e secrets
    ├── estrategia-gatilhos.md      # integração entre repos e deploy manual
    ├── seguranca-runner.md         # riscos e mitigações do runner self-hosted
    └── decisoes-tecnicas.md        # ADRs
```

---

## Começando

Leia o [**runbook**](docs/runbook.md) — é o guia operacional completo. Resumo:

```bash
# 1. No servidor: clonar e preparar o host
sudo git clone https://github.com/PI-AMS-2025-2026/banco-infra.git /opt/gini/infra
cd /opt/gini/infra
sudo ./scripts/bootstrap-server.sh

# 2. Registrar o self-hosted runner (token de curta duração, lido sem eco)
read -rs RUNNER_TOKEN && export RUNNER_TOKEN
sudo -E REPO_URL=https://github.com/PI-AMS-2025-2026/banco-infra \
     ./scripts/install-runner.sh
unset RUNNER_TOKEN

# 3. Criar o .env de cada ambiente (modo 600, fora do Git)
sudo install -o gha-runner -g gha-runner -m 600 \
  environments/dev/.env.example /opt/gini/dev/.env
sudo -u gha-runner nano /opt/gini/dev/.env     # substituir todos os CHANGE_ME

# 4. Instalar os timers de backup diário
sudo install -m 0644 scripts/systemd/gini-backup@.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gini-backup@dev.timer
```

Configure também, no GitHub (**Settings → Secrets and variables → Actions**):

- secrets `GHCR_USER` e `GHCR_PULL_TOKEN`
- variables `FRONTEND_IMAGE` e `BACKEND_IMAGE`
- environments `dev`, `staging` e `production` (este último com revisor obrigatório)

Catálogo completo: [`docs/variaveis-e-secrets.md`](docs/variaveis-e-secrets.md).

---

## Como o deploy funciona

```
push em dev (repo da app) → ci-tests → build-release-images → ghcr.io
                                              │
                                              ▼  repository_dispatch
                                   deploy-dev.yml (self-hosted runner)
                                              │
                                              ▼
                                      scripts/deploy.sh dev
```

`staging` e `production` são **sempre manuais** (Actions → *Deploy manual
(staging/production)*), informando a tag da imagem. Detalhes em
[`docs/estrategia-gatilhos.md`](docs/estrategia-gatilhos.md).

Cada deploy faz **backup do banco antes de subir**, espera os três serviços
ficarem `healthy`, confere os endpoints de health e, em caso de falha, faz
**rollback das tags** e termina vermelho.

⚠️ **Rollback de imagem não reverte o banco.** As migrations rodam no startup do
backend (Flyway) e não são desfeitas ao voltar a imagem. Escreva migrations
compatíveis com a versão anterior do código —
[ADR-006](docs/decisoes-tecnicas.md#adr-006--backup-pré-deploy-obrigatório-rollback-de-imagem-não-reverte-o-banco).

---

## Contrato entre repositórios

- **Registry:** `ghcr.io/<owner>/<nome-do-repo>`, em minúsculas.
- **Tags publicadas:** tag imutável usada nos deploys — `sha-<7 chars>` no
  backend e no frontend —, nome da branch (`dev`/`staging`/`main`, mutável),
  `X.Y.Z` e `X.Y` quando houver tag git `vX.Y.Z`, e `latest` somente a partir
  de `main`.
  A imagem do frontend é a mesma nos três ambientes e recebe a URL da API pela
  variável `API_URL` (do `.env` de cada ambiente) em runtime
  ([ADR-012](docs/decisoes-tecnicas.md#adr-012--imagem-única-do-frontend-com-url-da-api-em-runtime)).
- **Requisito da imagem do frontend:** rótulo OCI
  `br.fatec.gini.runtime-api-url=true`, e não subir sem `API_URL`. O
  `deploy.sh` recusa, antes do `up`, imagens sem o rótulo.
- **Variáveis do frontend:** `NODE_ENV=production`, `PORT=3000` e `API_URL`
  (obrigatória; URL do backend pela qual o navegador o alcança).
- **Dispatch:** só a branch `dev` envia `repository_dispatch` para este
  repositório — `event_type: image-published`, `client_payload: { service, tag,
  sha, branch }`.
- **Portas e health:** frontend `3000` + `GET /api/health`; backend `8080` +
  `GET /actuator/health`.
- **Requisito da imagem do backend:** o estágio final precisa ter `curl` **ou**
  `wget`, senão o healthcheck do Compose nunca passa e todo deploy falha e rola
  para trás. `eclipse-temurin:21-jre` e `:21-jre-alpine` já atendem; variantes
  `-slim` e distroless **não**. O frontend não tem esse requisito (usa `node -e`).
- **Variáveis do backend:** `SPRING_PROFILES_ACTIVE=prod`,
  `SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME`,
  `SPRING_DATASOURCE_PASSWORD`, `JWT_SECRET`, `APP_ENVIRONMENT` (derivada de
  `ENV_NAME`), `FRONTEND_URL` (origem do CORS **e** base do link de
  recuperação de senha), `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`,
  `SMTP_PASSWORD`, `SMTP_AUTH`, `SMTP_STARTTLS`, `SMTP_FROM`,
  `PASSWORD_RESET_EXPIRATION_MINUTES` e `SWAGGER_ENABLED` (padrão `false`).
  Em dev e staging o SMTP aponta para o Mailpit (`SMTP_HOST=mailpit`); em
  production é obrigatório um SMTP real.
  No perfil `prod` o backend **não sobe** sem `SMTP_HOST`, `SMTP_USERNAME`,
  `SMTP_PASSWORD`, `SMTP_FROM` e `FRONTEND_URL`. O backend não lê mais
  `CORS_ALLOWED_ORIGINS`.
- **Versão do PostgreSQL:** a major é a **17**, a mesma do compose de
  desenvolvimento e do CI do backend. Ao mudar, altere os três lugares.
- **Nos repos de aplicação:** secret `INFRA_DISPATCH_TOKEN`, variable
  `INFRA_REPOSITORY` (`owner/repo`).

---

## Segurança — leia antes de operar

O runner self-hosted executa código **no nosso servidor**, e o usuário
`gha-runner` pertence ao grupo `docker`, que é **equivalente a root no host**.
As mitigações obrigatórias estão em
[`docs/seguranca-runner.md`](docs/seguranca-runner.md):

- runner registrado no **repositório**, nunca na organização;
- workflows de deploy só com `repository_dispatch` / `workflow_dispatch` —
  **nunca** `pull_request` ou `pull_request_target`;
- aprovação obrigatória para workflows de colaboradores externos (se público);
- Environments com revisor obrigatório em `production`;
- `gha-runner` sem `sudo`;
- toda entrada externa validada por regex, nenhum valor interpolado direto em
  comando;
- PAT do ghcr.io apenas com `read:packages`, rotação a cada 90 dias;
- nenhum `.env` real e nenhum segredo versionado.

---

## Fora do escopo desta fase

Decisão consciente, registrada em
[ADR-007](docs/decisoes-tecnicas.md#adr-007--escopo-desta-fase-servidor-local-sem-aws-tls-ou-monitoramento)
(item AWS atualizado pelo [ADR-013](docs/decisoes-tecnicas.md#adr-013--implantação-na-aws-learner-lab-um-ambiente-de-homologação-por-conta-bootstrap-por-script)):

| Item | Risco aceito agora |
| --- | --- |
| **AWS / nuvem para a produção** | ponto único de falha; sem acesso fora da rede local. A AWS hospeda só a **homologação** de cada aluno, implantada à mão no Learner Lab ([ADR-013](docs/decisoes-tecnicas.md#adr-013--implantação-na-aws-learner-lab-um-ambiente-de-homologação-por-conta-bootstrap-por-script), [runbook da AWS](docs/aws-learner-lab.md)) |
| **Proxy reverso e TLS/HTTPS** | tráfego em HTTP puro, acesso por `host:porta` |
| **Monitoramento e alertas** | falha só é percebida por quem olhar |
| **Cópia de backups para fora do host** | dump e banco na mesma máquina |

Mitigações já aplicadas: UFW com `deny incoming`, banco sem porta publicada,
backup diário validado com retenção, segredos fora do Git.

---

## Documentação

| Documento | Para quê |
| --- | --- |
| [`docs/runbook.md`](docs/runbook.md) | preparar o servidor, deployar, rollback, backup/restore, logs, troubleshooting |
| [`docs/aws-learner-lab.md`](docs/aws-learner-lab.md) | implantar a homologação no AWS Learner Lab (VPC, SGs, RDS, ALB, EC2), custos e destruição |
| [`aws/PARAMETERS.md`](aws/PARAMETERS.md) | parâmetros do bootstrap da AWS e mapeamento para CloudFormation |
| [`docs/variaveis-e-secrets.md`](docs/variaveis-e-secrets.md) | toda variável e secret, onde configurar e exemplos fictícios |
| [`docs/estrategia-gatilhos.md`](docs/estrategia-gatilhos.md) | integração entre repos, payload, Environments, rollback |
| [`docs/seguranca-runner.md`](docs/seguranca-runner.md) | riscos do runner self-hosted e mitigações obrigatórias |
| [`docs/decisoes-tecnicas.md`](docs/decisoes-tecnicas.md) | ADRs — por que cada escolha foi feita |
