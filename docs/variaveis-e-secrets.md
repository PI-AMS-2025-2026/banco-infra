# Variáveis e secrets

Catálogo completo de tudo que precisa ser configurado para a infraestrutura
funcionar. **Nenhum valor real aparece aqui** — todos os exemplos são fictícios.

Onde cada coisa mora:

| Local | O que guarda | Versionado? |
| --- | --- | --- |
| **Secrets** deste repositório | credenciais usadas pelos workflows | não |
| **Variables** deste repositório | configuração não sensível dos workflows | não |
| `/opt/gini/<env>/.env` (servidor) | configuração e segredos de cada ambiente | **não** (só o `.example`) |
| `/opt/gini/<env>/images.env` (servidor) | apenas as tags das imagens | não (reescrito pelo deploy) |
| Secrets/Variables dos repos de aplicação | integração com este repositório | não |
| user data das EC2 da AWS / `/opt/gini/aws/.env` | parâmetros e segredos da homologação no Learner Lab ([§9](#9-bootstrap-da-aws-learner-lab)) | **não** (só modelos com `CHANGE_ME`) |

Caminho no GitHub para secrets e variables:
**Settings → Secrets and variables → Actions** (abas *Secrets* e *Variables*).

---

## 1. Secrets deste repositório (`banco-infra`)

| Nome | Onde configurar | Finalidade | Exemplo fictício |
| --- | --- | --- | --- |
| `GHCR_USER` | Settings → Secrets and variables → Actions → *Secrets* | Usuário do GitHub usado no `docker login ghcr.io` do servidor. Pode ser a conta de um integrante do grupo. | `gttolla` |
| `GHCR_PULL_TOKEN` | idem | PAT **somente leitura** (`read:packages`) para baixar as imagens privadas do ghcr.io. Entra no `docker login` via `--password-stdin`. Rotação a cada 90 dias — ver [`seguranca-runner.md`](seguranca-runner.md#28-rotação-do-pat-do-ghcrio). | `ghp_0000000000000000000000000000000000` |

> Se o grupo tornar os pacotes do ghcr.io **públicos**, os dois secrets passam a
> ser opcionais: sem `GHCR_PULL_TOKEN` o `deploy.sh` apenas não autentica.

Não existe secret de SSH: o deploy roda **dentro** do servidor, no self-hosted
runner. Também não existe secret de banco neste repositório — a senha do
PostgreSQL vive só no `.env` do servidor.

---

## 2. Variables deste repositório (`banco-infra`)

| Nome | Onde configurar | Finalidade | Exemplo fictício |
| --- | --- | --- | --- |
| `FRONTEND_IMAGE` | Settings → Secrets and variables → Actions → *Variables* | Nome da imagem do frontend no ghcr.io, **sem tag**, em minúsculas. Os workflows a repassam ao `deploy.sh`; o nome **nunca** vem do payload do dispatch. | `ghcr.io/pi-ams-2025-2026/frontend-nextjs` |
| `BACKEND_IMAGE` | idem | Idem, para o backend. | `ghcr.io/pi-ams-2025-2026/backend-java` |

Formato validado pelo `deploy.sh`: tudo em minúsculas, sem tag e sem `@sha256`.
### 2.1 Por que o nome da imagem aparece em dois lugares

O mesmo valor existe aqui (Variable) **e** no `.env` de cada ambiente no
servidor. A duplicidade é proposital:

| Caminho do deploy | De onde vem o nome da imagem |
| --- | --- |
| Workflows (`deploy-dev.yml`, `deploy.yml`) | **Variable do repositório** — repassada ao `deploy.sh` por `env:` |
| Deploy manual por SSH ([runbook §5.3](runbook.md#53-deploy-manual-direto-no-servidor-contorno)) | `.env` do ambiente, usado como fallback |

Sem o fallback, o deploy de contorno (quando o runner está fora do ar) exigiria
digitar as duas imagens na linha de comando. Sem a Variable, o nome da imagem
teria de vir do payload do dispatch — exatamente o que não queremos
([ADR-005](decisoes-tecnicas.md#adr-005--integração-entre-repos-por-repository_dispatch)).

O risco real da duplicidade é **divergência silenciosa**: um deploy pela Actions
e um por SSH apontando para imagens diferentes. Por isso o `deploy.sh` compara os
dois valores e emite `[AVISO] <VAR> divergente: usando 'X', mas .../.env diz 'Y'`
sem abortar — quem manda é sempre o valor recebido. Se esse aviso aparecer,
alinhe a Variable e o `.env`.

O formato é validado em ambos os casos: minúsculas, sem tag e sem `@sha256`.

---

## 3. GitHub Environments deste repositório

Não guardam variáveis nesta fase — servem para as regras de proteção.

| Environment | Proteção | Usado por |
| --- | --- | --- |
| `dev` | nenhuma | `deploy-dev.yml` |
| `staging` | revisor opcional | `deploy.yml` |
| `production` | **revisor obrigatório** (≥ 1 aprovador) | `deploy.yml` |

Criação passo a passo em [`estrategia-gatilhos.md`](estrategia-gatilhos.md#5-github-environments).

---

## 4. Variáveis do `.env` de cada ambiente (no servidor)

Arquivo: `/opt/gini/<env>/.env` — criado **à mão**, modo `600`, dono
`gha-runner`, **fora do Git**. Modelos versionados:
`environments/<env>/.env.example`.

O `deploy.sh` aborta se o modo não for `600` ou se ainda houver `CHANGE_ME`
(inclusive em linhas comentadas).

> **`CORS_ALLOWED_ORIGINS` foi removida.** O backend, no perfil `prod`, não a
> lê: a origem do CORS vem de `FRONTEND_URL`. Se o `.env` de um servidor ainda
> tiver a linha, ela é ignorada e pode ser apagada.

| Nome | Finalidade | Exemplo fictício (dev / staging / production) |
| --- | --- | --- |
| `ENV_NAME` | Nome do ambiente. Usado nos nomes dos containers (`gini-<env>-db`) e nas labels. Precisa casar com o diretório e com `-p gini-<env>`. | `dev` / `staging` / `production` |
| `FRONTEND_IMAGE` | Imagem do frontend, sem tag. Igual à Variable homônima. | `ghcr.io/pi-ams-2025-2026/frontend-nextjs` |
| `BACKEND_IMAGE` | Imagem do backend, sem tag. Igual à Variable homônima. | `ghcr.io/pi-ams-2025-2026/backend-java` |
| `FRONTEND_PORT` | Porta publicada no host para o frontend (interna é sempre 3000). Precisa estar liberada no UFW. | `3001` / `3002` / `3000` |
| `BACKEND_PORT` | Porta publicada no host para o backend (interna é sempre 8080). | `8081` / `8082` / `8080` |
| `POSTGRES_DB` | Nome do banco criado no container `db`. | `gini_dev` / `gini_staging` / `gini_production` |
| `POSTGRES_USER` | Usuário do PostgreSQL. | `gini_dev` / `gini_staging` / `gini_production` |
| `POSTGRES_PASSWORD` | Senha do PostgreSQL. **Diferente em cada ambiente.** Gere com `openssl rand -base64 32`. | `cGFzc3dvcmQtZmljdGljaWEtbmFvLXVzZQ==` |
| `JWT_SECRET` | Segredo de assinatura dos JWT do backend. **Diferente em cada ambiente.** Gere com `openssl rand -base64 48`. | `and0LXNlY3JldC1maWN0aWNpby1uYW8tdXNlLWVtLXByb2Q=` |
| `FRONTEND_URL` | URL pública do frontend do ambiente: esquema + host + porta, **sem barra final e sem caminho**. O backend a usa como origem do CORS **e** como base do link do e-mail de recuperação de senha. Aceita **uma única** origem. **Obrigatória.** | `http://192.168.0.10:3001` / `http://192.168.0.10:3002` / `http://192.168.0.10:3000` |
| `API_URL` | URL pela qual o **navegador** alcança o backend do ambiente: `http(s)://host[:porta]`, **sem barra final e sem caminho** — a mesma origem do backend do ambiente (porta `BACKEND_PORT`), acessível da máquina do usuário (nada de `localhost` nem do nome do serviço Docker). Lida em runtime pela **imagem única** do frontend (`sha-<7>`), que não sobe sem ela; ignorada pela imagem legado (`sha-<7>-<env>`). O `deploy.sh` a valida com `^https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?$` e **recusa** subir uma imagem única sem ela. Não é segredo (vai parar no JavaScript do navegador). Trocar o valor exige **recriar** o container do frontend (rodar o deploy do frontend de novo). Fase A: opcional; Fase B: obrigatória ([ADR-012](decisoes-tecnicas.md#adr-012--imagem-única-do-frontend-com-url-da-api-em-runtime)). | `http://192.168.0.10:8081` / `http://192.168.0.10:8082` / `http://192.168.0.10:8080` |
| `SMTP_HOST` | Servidor SMTP do e-mail de recuperação de senha. **Obrigatória** (o backend não sobe sem ela). Em dev/staging com Mailpit: `mailpit` (porta `1025`, `SMTP_AUTH=false`, `SMTP_STARTTLS=false`, usuário e senha vazios). | `smtp.exemplo.com.br` |
| `SMTP_PORT` | Porta do SMTP. Opcional; padrão `587`. | `587` |
| `SMTP_AUTH` | Se o SMTP exige autenticação. Opcional; padrão `true`. | `true` |
| `SMTP_STARTTLS` | Se usa STARTTLS. Opcional; padrão `true`. | `true` |
| `SMTP_USERNAME` | Usuário do SMTP. **Obrigatória** (pode ser vazia se `SMTP_AUTH=false`). | `usuario-ficticio` |
| `SMTP_PASSWORD` | Senha do SMTP. **Obrigatória** (pode ser vazia se `SMTP_AUTH=false`). Segredo: diferente em cada ambiente quando possível. | `senha-ficticia-nao-use` |
| `SMTP_FROM` | Remetente dos e-mails. **Obrigatória**; precisa ser aceito pelo provedor. | `noreply@exemplo.com.br` |
| `PASSWORD_RESET_EXPIRATION_MINUTES` | Validade do link de recuperação de senha. Opcional; padrão `15`. | `15` |
| `COMPOSE_PROFILES` | Perfis do Compose a ativar. `mailpit` sobe a caixa de entrada de teste (ADR-011). Presente nos `.env.example` de dev e staging; **proibida em production** (o `deploy.sh` aborta). Opcional. | `mailpit` |
| `MAILPIT_WEB_PORT` | Porta da interface web do Mailpit, publicada **somente em `127.0.0.1`** do servidor. Diferente por ambiente. Opcional; padrão `8025`. Só tem efeito com `COMPOSE_PROFILES=mailpit`. | `8025` / `8026` |
| `SWAGGER_ENABLED` | Publica o Swagger UI e `/v3/api-docs`. Opcional; padrão `false`. Ligar **apenas em dev**: as rotas ficam sem autenticação e não há proxy reverso nesta fase (ADR-007). Com `ENV_NAME=production` o backend recusa `true`. | `false` |
| `BACKUP_RETENTION_DAYS` | Dias de retenção dos dumps em `/opt/gini/backups/<env>`. Opcional; padrão `7`. | `7` / `7` / `14` |

### 4.1 Variáveis derivadas (não se escreve no `.env`)

Montadas pelo `docker/docker-compose.yml` a partir das acima:

| Variável entregue ao container | Como é montada |
| --- | --- |
| `SPRING_PROFILES_ACTIVE` | fixo em `prod` |
| `SPRING_DATASOURCE_URL` | `jdbc:postgresql://db:5432/${POSTGRES_DB}` |
| `SPRING_DATASOURCE_USERNAME` | `${POSTGRES_USER}` |
| `SPRING_DATASOURCE_PASSWORD` | `${POSTGRES_PASSWORD}` |
| `JWT_SECRET` | `${JWT_SECRET}` |
| `APP_ENVIRONMENT` | `${ENV_NAME}` — compõe o emissor (`iss`) dos JWT e isola os ambientes; mudar o valor invalida os tokens já emitidos |
| `FRONTEND_URL`, `SMTP_*`, `PASSWORD_RESET_EXPIRATION_MINUTES`, `SWAGGER_ENABLED` | repassadas como estão, com os padrões da tabela acima |
| `NODE_ENV` / `PORT` (frontend) | fixos em `production` / `3000` |
| `API_URL` (frontend) | `${API_URL}` do `.env`, repassada como está; vazia se ausente (Fase A) |
| `POSTGRES_INITDB_ARGS` (db) | fixo em `--encoding=UTF8 --locale=C` |

---

## 5. `images.env` de cada ambiente (no servidor)

Arquivo: `/opt/gini/<env>/images.env`. Contém **apenas** as duas variáveis
abaixo e é **reescrito pelo `deploy.sh`** a cada deploy. O conteúdo anterior vai
para `images.env.previous`, que é a base do rollback automático.

| Nome | Finalidade | Exemplo fictício |
| --- | --- | --- |
| `FRONTEND_TAG` | Tag da imagem do frontend em uso. Imagem única: `sha-<7>`, igual nos três ambientes (exige `API_URL` no `.env`). Legado, aceito durante a transição: `sha-<7>-<ambiente>`. | `sha-a1b2c3d` (legado: `sha-a1b2c3d-dev`) |
| `BACKEND_TAG` | Tag da imagem do backend em uso. | `sha-9f8e7d6` |

Tags padrão do **primeiro** deploy (quando o arquivo ainda não existe):

| Ambiente | Tag padrão |
| --- | --- |
| `dev` | `dev` |
| `staging` | `staging` |
| `production` | `main` |

Formato aceito (validado nos workflows e no `deploy.sh`):
`^[A-Za-z0-9_.-]{1,128}$`.

---

## 6. Variáveis de ambiente dos scripts

Entradas opcionais, úteis em execução manual. Nenhuma precisa ser configurada no
GitHub.

| Script | Variável | Padrão | Finalidade |
| --- | --- | --- | --- |
| `bootstrap-server.sh` | `RUNNER_USER` | `gha-runner` | Usuário de serviço do runner. |
| | `GINI_ROOT` | `/opt/gini` | Raiz dos ambientes. |
| | `SSH_PORT` | `22` | Porta de SSH liberada no UFW. |
| | `DEV_FRONTEND_PORT` / `DEV_BACKEND_PORT` | `3001` / `8081` | Portas liberadas no UFW para dev. |
| | `STAGING_FRONTEND_PORT` / `STAGING_BACKEND_PORT` | `3002` / `8082` | Idem, staging. |
| | `PRODUCTION_FRONTEND_PORT` / `PRODUCTION_BACKEND_PORT` | `3000` / `8080` | Idem, produção. |
| `install-runner.sh` | `REPO_URL` | — (obrigatória) | URL deste repositório. |
| | `RUNNER_TOKEN` | — (obrigatória no 1º registro) | Token de registro de curta duração. **Nunca gravado em disco.** |
| | `RUNNER_VERSION` | `2.338.0` | Versão do `actions/runner` fixada no script. |
| | `RUNNER_SHA256` | checksum da versão acima | Validação do tarball baixado. |
| | `RUNNER_LABELS` | `gini-local` | Rótulo extra do runner. |
| | `RUNNER_DIR` | `/opt/gini/runner` | Destino da instalação. |
| `deploy.sh` | `ENV_NAME` | — (ou 1º argumento) | Ambiente de destino. |
| | `FRONTEND_TAG` / `BACKEND_TAG` | — (ao menos uma) | Tags a aplicar; a ausente é preservada. |
| | `FRONTEND_IMAGE` / `BACKEND_IMAGE` | valor do `.env` | Nomes das imagens (vêm das Variables nos workflows). |
| | `GHCR_USER` / `GHCR_PULL_TOKEN` | — (opcionais) | Login no ghcr.io. |
| | `HEALTH_TIMEOUT` | `180` | Segundos de espera pela saúde dos serviços. |
| | `GINI_ROOT` | `/opt/gini` | Raiz dos ambientes. |
| | `API_URL` | — | **Não** é entrada do script: é lida só do `.env` do ambiente. Se vier exportada no shell, o `deploy.sh` a descarta, para o container receber exatamente o valor validado. |
| `backup-db.sh` | `BACKUP_RETENTION_DAYS` | `.env` do ambiente, senão `7` | Retenção dos dumps. |
| | `GINI_ROOT` | `/opt/gini` | Raiz dos ambientes. |
| `restore-db.sh` | `HEALTH_TIMEOUT` | `180` | Espera pelo backend após o restore. |
| | `GINI_ROOT` | `/opt/gini` | Raiz dos ambientes. |

---

## 7. Referência cruzada — repositórios de aplicação

Configurado **nos outros repositórios** (`frontend-nextjs`, `backend-java`),
não aqui. Listado para o contrato entre repos ficar completo.

### 7.1 Secrets

| Nome | Repositório | Finalidade | Exemplo fictício |
| --- | --- | --- | --- |
| `INFRA_DISPATCH_TOKEN` | frontend-nextjs, backend-java | PAT com permissão de **escrita** neste repositório, usado para enviar o `repository_dispatch` (`event_type: image-published`) após publicar a imagem. Só é usado na branch `dev`. | `ghp_1111111111111111111111111111111111` |

`GITHUB_TOKEN` não serve para disparar o dispatch: ele é escopado ao próprio
repositório que roda o workflow.

A publicação no ghcr.io usa o `GITHUB_TOKEN` do próprio repo de aplicação com
`permissions: packages: write` — não precisa de secret adicional.

### 7.2 Variables

| Nome | Repositório | Finalidade | Exemplo fictício |
| --- | --- | --- | --- |
| `INFRA_REPOSITORY` | frontend-nextjs, backend-java | Destino do dispatch, no formato `owner/repo`. | `PI-AMS-2025-2026/banco-infra` |
| `NEXT_PUBLIC_API_URL_DEV` | frontend-nextjs | URL da API embutida no build **legado** da branch `dev`. **Obsoleta após a Fase B** (a URL passa a vir de `API_URL` no `.env` do servidor). Durante a transição, `API_URL` de cada `.env` deve ter o **mesmo valor** da variable do ambiente. | `http://192.168.0.10:8081` |
| `NEXT_PUBLIC_API_URL_STAGING` | frontend-nextjs | Idem, branch `staging`. **Obsoleta após a Fase B.** | `http://192.168.0.10:8082` |
| `NEXT_PUBLIC_API_URL_PRODUCTION` | frontend-nextjs | Idem, branch `main`. **Obsoleta após a Fase B.** | `http://192.168.0.10:8080` |
| `FRONTEND_DISPATCH_UNIFIED` | frontend-nextjs | **Chave de cutover** da imagem única. Com `true`, o dispatch da branch `dev` passa a enviar a tag única `sha-<7>` em vez de `sha-<7>-dev`, e o deploy automático de dev passa a usar a imagem única. Ausente ou diferente de `true`: comportamento legado. Só ligue depois do passo 4 do [runbook §13](runbook.md#13-migração-para-a-imagem-única-do-frontend). | `true` |

> **Transição ([ADR-012](decisoes-tecnicas.md#adr-012--imagem-única-do-frontend-com-url-da-api-em-runtime)).**
> No formato **legado**, o frontend é buildado por ambiente porque `NEXT_PUBLIC_*`
> é embutido no bundle, e a tag carrega o ambiente (`sha-<7>-dev`,
> `sha-<7>-staging`, `sha-<7>-production`) — nunca reaproveite a tag legado de
> um ambiente em outro. A **imagem única** (`sha-<7>`, rótulo OCI
> `br.fatec.gini.runtime-api-url=true`) é a mesma nos três ambientes e recebe a
> URL da API por `API_URL` em runtime; ela é promovida de `dev` para `staging`
> e `production` sem rebuild.

---

## 8. Checklist de configuração inicial

- [ ] Secrets `GHCR_USER` e `GHCR_PULL_TOKEN` criados neste repositório.
- [ ] Variables `FRONTEND_IMAGE` e `BACKEND_IMAGE` criadas neste repositório.
- [ ] Environments `dev`, `staging` e `production` criados, `production` com
      revisor obrigatório.
- [ ] `/opt/gini/dev/.env`, `/opt/gini/staging/.env` e
      `/opt/gini/production/.env` criados, modo `600`, dono `gha-runner`, sem
      nenhum `CHANGE_ME` e com senhas/segredos **distintos por ambiente**.
- [ ] Secret `INFRA_DISPATCH_TOKEN` e variable `INFRA_REPOSITORY` configurados
      nos dois repos de aplicação.
- [ ] `API_URL` definida no `.env` de cada ambiente (obrigatória para a imagem
      única do frontend; igual à `NEXT_PUBLIC_API_URL_<ENV>` correspondente).
- [ ] Variables `NEXT_PUBLIC_API_URL_*` configuradas no repo do frontend
      (enquanto houver imagens legado; obsoletas após a Fase B).
- [ ] `git ls-files | grep -E '(^|/)\.env$'` sem resultado.

---

## 9. Bootstrap da AWS (Learner Lab)

Parâmetros do [`aws/bootstrap-ec2.sh`](../aws/bootstrap-ec2.sh), passados como
**variáveis de ambiente** pelo [`aws/user-data.sh`](../aws/user-data.sh) do
launch template. Não têm relação com os workflows nem com o `deploy.sh`: o
ambiente da AWS é manual ([ADR-013](decisoes-tecnicas.md#adr-013--implantação-na-aws-learner-lab-um-ambiente-de-homologação-por-conta-bootstrap-por-script)).
Validação detalhada e mapeamento para CloudFormation:
[`aws/PARAMETERS.md`](../aws/PARAMETERS.md) (fonte da verdade).

| Variável | Obrig. | Padrão | Finalidade | Exemplo fictício |
| --- | --- | --- | --- | --- |
| `RDS_ENDPOINT` | **sim** | — | Endpoint do RDS, sem porta. | `gini-db.abcdefghijkl.us-east-1.rds.amazonaws.com` |
| `DB_NAME` | não | `gini` | Banco inicial criado no RDS. | `gini` |
| `DB_USER` | **sim** | — | Usuário principal do RDS. | `gini_admin` |
| `DB_PASSWORD` | **sim** | — | Senha principal do RDS. Segredo; gerada **uma vez** (`openssl rand -hex 32`), igual nas duas instâncias. | `0123456789abcdef0123456789abcdef` |
| `JWT_SECRET` | **sim** | — | Segredo dos JWT; 32+ caracteres, **igual nas duas instâncias**. Exclusivo deste ambiente. | `fedcba9876543210fedcba9876543210` |
| `ALB_DNS` | não | descoberto pelo `ALB_NAME` | DNS do ALB; origem de `FRONTEND_URL=http://<dns>` e `API_URL=http://<dns>:8080`. | `gini-lb-1234567890.us-east-1.elb.amazonaws.com` |
| `ALB_NAME` | não | `gini-lb` | Nome do ALB para a descoberta. | `gini-lb` |
| `BACKEND_TAG` / `FRONTEND_TAG` | **sim** | — | Tags `sha-<7>`; o frontend precisa ser a imagem única (rótulo `br.fatec.gini.runtime-api-url=true`). | `sha-a1b2c3d` |
| `BACKEND_IMAGE` / `FRONTEND_IMAGE` | não | imagens do ghcr.io da organização | Imagens públicas, sem tag. | `ghcr.io/pi-ams-2025-2026/backend-java` |
| `APP_ENVIRONMENT` | não | `staging` | Ambiente lógico do backend. | `staging` |
| `ENABLE_MAILPIT` | não | `true` | Sobe o Mailpit (perfil `mailpit`). | `true` |
| `SMTP_*` | não | valores do Mailpit | Só para SMTP real com `ENABLE_MAILPIT=false`. | — |
| `INFRA_REF` | não | `main` (aviso) | Tag/commit deste repositório de onde vêm o bootstrap e o compose. | `v1.4.0` |
| `COMPOSE_VERSION` / `COMPOSE_SHA256` | não | `v5.7.2` / checksum oficial | Versão fixada do compose plugin. | — |
| `AWS_REGION` | não | metadados da instância | Região usada na descoberta do ALB. | `us-east-1` |
| `HEALTH_TIMEOUT` | não | `300` | Espera pela saúde dos containers (s). | `300` |
| `DRY_RUN` | não | `0` | `1` = só valida e mostra o plano. | `1` |

> O user data **não é sigiloso** (visível no console e nos metadados da
> instância). Por isso os segredos da AWS são **exclusivos** desse ambiente —
> nunca reaproveite os do servidor local. Na instância, o bootstrap os grava
> em `/opt/gini/aws/.env` (modo `600`, root) e nunca os imprime.
