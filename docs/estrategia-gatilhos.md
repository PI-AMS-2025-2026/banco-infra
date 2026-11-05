# Estratégia de gatilhos e deploy

Como uma mudança de código nos repositórios de aplicação chega ao servidor.

---

## 1. Visão geral

```
┌──────────────────────────────┐        ┌──────────────────────────────┐
│  frontend-nextjs             │        │  backend-java                │
│  push em dev/staging/main    │        │  push em dev/staging/main    │
└──────────────┬───────────────┘        └──────────────┬───────────────┘
               │                                       │
               ▼                                       ▼
        job: ci-tests                           job: ci-tests
               │                                       │
               ▼                                       ▼
   job: build-release-images  ──── publica ───▶  ghcr.io/<owner>/<repo>
               │                                  tags: sha-<7>, <branch>,
               │                                        X.Y.Z, X.Y, latest
               │
               │  SOMENTE na branch `dev`
               ▼
   repository_dispatch  ──▶  banco-infra
     event_type: image-published
     client_payload: { service, tag, sha, branch }
               │
               ▼
   .github/workflows/deploy-dev.yml
     (self-hosted runner `gini-local`)
               │
               ▼
   scripts/deploy.sh dev  ──▶  /opt/gini/dev  (docker compose -p gini-dev)


   staging / production:  NÃO há gatilho automático
               │
               ▼
   Actions ▸ "Deploy manual (staging/production)" ▸ Run workflow
     (workflow_dispatch, informando a tag da imagem)
               │
               ▼
   .github/workflows/deploy.yml  ──▶  scripts/deploy.sh staging|production
```

---

## 2. Contrato do payload

Enviado pelos repos de aplicação para este repositório, **apenas** a partir da
branch `dev`:

```jsonc
// POST /repos/PI-AMS-2025-2026/banco-infra/dispatches
{
  "event_type": "image-published",
  "client_payload": {
    "service": "backend",      // "frontend" | "backend"
    "tag": "sha-a1b2c3d",      // tag imutável publicada no ghcr.io
    "sha": "a1b2c3d4e5f6...",  // commit completo (informativo)
    "branch": "dev"            // precisa ser "dev"
  }
}
```

Validação feita no **primeiro step** de `deploy-dev.yml`, antes de qualquer
comando que toque no servidor:

| Campo | Regra | Se falhar |
| --- | --- | --- |
| `service` | exatamente `frontend` ou `backend` | job falha com `::error::` |
| `branch` | exatamente `dev` | job falha com `::error::` |
| `tag` | `^[A-Za-z0-9_.-]{1,128}$` | job falha com `::error::` |
| `sha` | não validado (apenas registrado no log) | — |

Os valores entram no step por `env:` e são consumidos como variáveis de shell —
nunca interpolados como `${{ ... }}` dentro do corpo do script, o que permitiria
injeção de comando.

**Os nomes das imagens NUNCA vêm do payload.** Eles vêm das Variables
`FRONTEND_IMAGE` / `BACKEND_IMAGE` deste repositório. Se viessem do payload,
quem conseguisse disparar o dispatch poderia apontar o deploy para uma imagem
arbitrária.

### 2.1 Como o repo de aplicação dispara (referência)

Trecho equivalente ao que roda nos repos de aplicação — mantido aqui só como
documentação do contrato:

```yaml
- name: Notificar o repositório de infraestrutura
  if: github.ref_name == 'dev'
  env:
    GH_TOKEN: ${{ secrets.INFRA_DISPATCH_TOKEN }}
    INFRA_REPOSITORY: ${{ vars.INFRA_REPOSITORY }}
    TAG: sha-${{ github.sha }}   # já truncado para 7 caracteres no job de build
  run: |
    gh api "repos/${INFRA_REPOSITORY}/dispatches" \
      -f event_type=image-published \
      -f 'client_payload[service]=backend' \
      -f "client_payload[tag]=${TAG}" \
      -f "client_payload[sha]=${GITHUB_SHA}" \
      -f 'client_payload[branch]=dev'
```

---

## 3. Por que `repository_dispatch` e não `workflow_run`

`workflow_run` só observa workflows **do mesmo repositório**. Nossa CI/CD é
dividida em três repos independentes (não é monorepo), então um workflow em
`banco-infra` não tem como "ouvir" o término de um workflow em `backend-java`.

Alternativas avaliadas:

| Opção | Por que não |
| --- | --- |
| `workflow_run` | Não atravessa repositórios. |
| `schedule` (pooling do registry) | Deploy com atraso de minutos e desperdício de execuções; não dá rastreabilidade de "qual commit entrou". |
| Workflow reutilizável (`workflow_call`) chamado pelo repo da app | O job rodaria no contexto do repo de aplicação; os secrets de infraestrutura precisariam ser replicados lá. |
| Deploy direto do repo da app por SSH | Espalharia credenciais de servidor pelos três repos e tiraria o controle do repositório de infraestrutura. |
| **`repository_dispatch`** ✅ | Chamada explícita entre repos, com payload tipado, exigindo token com escrita neste repositório. |

### 3.1 Detalhe importante: `repository_dispatch` usa a branch padrão

Um `repository_dispatch` **sempre executa a versão do workflow que está na
branch padrão** (`main`) deste repositório. Consequências práticas:

- Alterações em `deploy-dev.yml` ou em `scripts/deploy.sh` só passam a valer
  depois do merge em `main`.
- Não é possível testar uma mudança de workflow de dispatch a partir de uma
  branch. Para testar, use `workflow_dispatch` (que aceita escolher a branch) ou
  rode `scripts/deploy.sh` manualmente por SSH.
- O `event_type` é lido da branch padrão: renomeá-lo exige merge antes de os
  repos de aplicação começarem a usar o nome novo.

---

## 4. Deploy manual de staging e production

`deploy.yml` tem **só** `workflow_dispatch`. Os motivos:

1. **Build por ambiente.** O frontend embute `NEXT_PUBLIC_API_URL` no bundle, de
   modo que a imagem de staging precisa vir de um build da branch `staging` e a
   de produção, de um build da `main`. Não existe "promover" a mesma imagem
   entre ambientes.
2. **Migrations.** O Flyway aplica as migrations no startup do backend, e
   rollback de imagem não desfaz migration. Produção precisa de decisão humana.
3. **Aprovação.** `environment: production` com revisor obrigatório só funciona
   com um gatilho que crie um job pendente — é o caso aqui.

### 4.1 Pela interface

1. **Actions → "Deploy manual (staging/production)" → Run workflow**.
2. Preencha:
   - `environment`: `staging` ou `production`;
   - `service`: `frontend`, `backend` ou `both`;
   - `frontend_tag` e/ou `backend_tag`: a tag publicada no ghcr.io
     (ex.: `sha-a1b2c3d`).
3. **Run workflow**.
4. Com `environment=production`, o job entra em **Waiting** com o aviso
   *"Review pending deployments"*. Um revisor precisa clicar em **Approve and
   deploy**. Só então o runner executa qualquer comando no servidor.

Há dois inputs de tag (em vez de um) justamente para permitir `service=both` com
versões diferentes para frontend e backend. A tag que não for informada é
**preservada** a partir do `images.env` do servidor.

### 4.2 Pela linha de comando

```bash
# staging, só o backend
gh workflow run deploy.yml \
  -f environment=staging -f service=backend -f backend_tag=sha-9f8e7d6

# produção, os dois serviços com tags distintas
gh workflow run deploy.yml \
  -f environment=production -f service=both \
  -f frontend_tag=sha-a1b2c3d -f backend_tag=sha-9f8e7d6

# acompanhar
gh run watch
```

---

## 5. GitHub Environments

Os jobs declaram `environment:`, que é o que habilita as regras de proteção.

### 5.1 Criar os três environments

**Settings → Environments → New environment**

| Nome | Required reviewers | Wait timer | Deployment branches |
| --- | --- | --- | --- |
| `dev` | desmarcado | 0 | *No restriction* |
| `staging` | opcional (marque se o grupo quiser) | 0 | *No restriction* |
| `production` | **marcado**, ≥ 1 revisor | 0 | *Selected branches* → `main` |

Passo a passo para `production`:

1. **Settings → Environments → New environment** → nome `production` →
   **Configure environment**.
2. Marque **Required reviewers** e adicione pelo menos um integrante do grupo
   (de preferência dois, para não travar se alguém faltar).
3. Em **Deployment branches and tags**, escolha **Selected branches and tags** e
   adicione a regra `main`.
4. **Save protection rules**.
5. Repita para `staging` (sem required reviewers, ou com, se o grupo preferir) e
   para `dev` (sem nenhuma proteção).

> Quem é *Required reviewer* **não pode** aprovar o próprio deploy em repositório
> privado de plano gratuito; na dúvida, cadastre dois revisores.

### 5.2 Validar

```bash
gh api repos/PI-AMS-2025-2026/banco-infra/environments \
  --jq '.environments[] | {name, protection_rules: [.protection_rules[].type]}'
```

Esperado: `production` com `required_reviewers`.

---

## 6. Como testar o dispatch

```bash
# 1. Dispara como se o backend-java tivesse acabado de publicar uma imagem
gh api repos/PI-AMS-2025-2026/banco-infra/dispatches \
  -f event_type=image-published \
  -f 'client_payload[service]=backend' \
  -f 'client_payload[tag]=sha-a1b2c3d' \
  -f 'client_payload[sha]=a1b2c3d4e5f67890abcdef1234567890abcdef12' \
  -f 'client_payload[branch]=dev'

# 2. Acompanhar (o dispatch não devolve a URL do run)
gh run list --workflow=deploy-dev.yml --limit 5
gh run watch
```

Use uma `tag` que **exista** no ghcr.io. Com uma tag inexistente, o deploy falha
no `docker compose pull` — de propósito, e sem derrubar o ambiente que está no
ar (o `images.env` é revertido antes de qualquer `up`).

### 6.1 Casos de rejeição que valem testar

```bash
# branch != dev -> rejeitado na validação, antes de tocar no servidor
gh api repos/PI-AMS-2025-2026/banco-infra/dispatches \
  -f event_type=image-published \
  -f 'client_payload[service]=backend' \
  -f 'client_payload[tag]=sha-a1b2c3d' \
  -f 'client_payload[branch]=main'

# service inválido -> rejeitado
gh api repos/PI-AMS-2025-2026/banco-infra/dispatches \
  -f event_type=image-published \
  -f 'client_payload[service]=banco' \
  -f 'client_payload[tag]=sha-a1b2c3d' \
  -f 'client_payload[branch]=dev'

# tag com caractere proibido -> rejeitado
gh api repos/PI-AMS-2025-2026/banco-infra/dispatches \
  -f event_type=image-published \
  -f 'client_payload[service]=backend' \
  -f 'client_payload[tag]=sha-a1b2c3d; rm -rf /' \
  -f 'client_payload[branch]=dev'
```

Nos três casos o job precisa falhar no step **"Validar payload do dispatch"**,
sem nenhum `docker` executado.

---

## 7. Rollback

### 7.1 Automático (só em falha de deploy)

Se as imagens novas não ficarem saudáveis, o `deploy.sh` restaura
`images.env.previous`, sobe novamente e **termina com código diferente de zero
mesmo que o rollback funcione** — a versão pedida não entrou no ar, então o job
fica vermelho. O ocorrido é registrado em `/opt/gini/<env>/releases.log` como
`FALHA_COM_ROLLBACK` ou `FALHA_SEM_ROLLBACK`.

No primeiro deploy de um ambiente não existe versão anterior validada: o script
apenas reporta a falha.

### 7.2 Manual (voltar uma versão já implantada)

1. Descubra a tag anterior:

   ```bash
   ssh <servidor> 'tail -20 /opt/gini/production/releases.log'
   ```

2. Rode o `deploy.yml` com essa tag:

   ```bash
   gh workflow run deploy.yml \
     -f environment=production -f service=both \
     -f frontend_tag=sha-ANTERIOR -f backend_tag=sha-ANTERIOR
   ```

3. Aprove o deployment, se `production` exigir revisor.

### 7.3 O limite do rollback: Flyway

**Rollback de imagem não reverte o banco de dados.** Se a versão nova aplicou
migrations, voltar a imagem antiga deixa o código antigo rodando sobre um schema
novo.

Consequências práticas para o grupo:

- Escreva migrations **compatíveis com a versão anterior** do código
  (*expand/contract*): adicione colunas nullable ou com default, não renomeie
  nem remova coluna/tabela na mesma release que passa a usar o novo nome. Deixe
  a remoção para uma release seguinte, depois de confirmar que ninguém mais usa.
- O `deploy.sh` faz **backup pré-deploy** antes de qualquer `up`; se a migration
  for incompatível, a saída é restaurar o dump com
  `scripts/restore-db.sh <env> <dump> --yes`.
- Quando uma migration destrutiva for inevitável, trate como janela planejada:
  avise o grupo, confirme o backup e tenha o `restore` à mão.

---

## 8. Resumo dos gatilhos

| Workflow | Gatilho | Ambiente | Aprovação | Quando roda |
| --- | --- | --- | --- | --- |
| `deploy-dev.yml` | `repository_dispatch` (`image-published`) | `dev` | não | automático, a cada imagem publicada da branch `dev` |
| `deploy.yml` | `workflow_dispatch` | `staging` | opcional | quando o grupo decide |
| `deploy.yml` | `workflow_dispatch` | `production` | **obrigatória** | quando o grupo decide, após aprovação |

Nenhum workflow deste repositório usa `pull_request` ou `pull_request_target` —
o runner é self-hosted e tem acesso ao host. Ver
[`seguranca-runner.md`](seguranca-runner.md).
