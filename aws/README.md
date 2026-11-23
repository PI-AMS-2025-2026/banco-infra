# aws/ — Implantação na AWS (Learner Lab)

Arquivos para implantar a aplicação Gini na conta **AWS Academy Learner Lab**
de cada aluno, como ambiente de **homologação** (`APP_ENVIRONMENT=staging`,
com Mailpit). A produção continua no servidor local
([ADR-013](../docs/decisoes-tecnicas.md#adr-013--implantação-na-aws-learner-lab-um-ambiente-de-homologação-por-conta-bootstrap-por-script)).

A implantação é **manual** (exigência da disciplina de cloud): não há workflow
nem deploy automático para a AWS.

## Arquitetura

```
                     Internet
                        │
            ┌───────────┴────────────┐
            │  ALB gini-lb           │  SG gini-sg-alb: 80, 8080 ← 0.0.0.0/0
            │  :80   → gini-tg-frontend (3000, /api/health)
            │  :8080 → gini-tg-backend  (8080, /actuator/health)
            └──────┬──────────┬──────┘
     sub-rede pública A       sub-rede pública B       (sem NAT; IP público
   ┌─────────────────────┐ ┌─────────────────────┐      só para saída)
   │ EC2 gini-app1       │ │ EC2 gini-app2       │   SG gini-sg-ec2:
   │ backend  :8080      │ │ backend  :8080      │   3000, 8080 ← gini-sg-alb
   │ frontend :3000      │ │ frontend :3000      │   sem SSH (Session Manager)
   │ mailpit  127.0.0.1  │ │ mailpit  127.0.0.1  │
   └──────────┬──────────┘ └──────────┬──────────┘
              └──────────┬────────────┘
     sub-redes privadas  │
            ┌────────────┴───────────┐
            │ RDS gini-db (PG 17)    │  SG gini-sg-bd: 5432 ← gini-sg-ec2
            └────────────────────────┘
```

- Frontend no navegador: `http://<DNS_DO_ALB>` → `FRONTEND_URL`.
- API no navegador: `http://<DNS_DO_ALB>:8080` → `API_URL` da imagem única.

## Arquivos

| Arquivo | Para quê |
| --- | --- |
| [`PARAMETERS.md`](PARAMETERS.md) | **Contrato** de parâmetros: console ↔ bootstrap ↔ CloudFormation |
| [`docker-compose.aws.yml`](docker-compose.aws.yml) | Compose de cada EC2: `backend`, `frontend`, `mailpit` (perfil), **sem banco** |
| [`.env.aws.example`](.env.aws.example) | Modelo do `/opt/gini/aws/.env` (o real é gerado pelo bootstrap) |
| [`bootstrap-ec2.sh`](bootstrap-ec2.sh) | Prepara a instância e sobe a aplicação. Idempotente, com `DRY_RUN=1` e `--help` |
| [`user-data.sh`](user-data.sh) | Wrapper mínimo para o user data do launch template (e, no futuro, do CloudFormation) |
| [`cloudformation/README.md`](cloudformation/README.md) | Desenho do template CloudFormation futuro (sem template nesta fase) |

Procedimento completo no console: [`docs/aws-learner-lab.md`](../docs/aws-learner-lab.md).

## Fluxo

```
user data (launch template)
  └─ exporta os parâmetros e baixa aws/bootstrap-ec2.sh de INFRA_REF
       └─ bootstrap-ec2.sh
            1. confere root, Amazon Linux 2023, arquitetura
            2. valida os parâmetros; descobre o DNS do ALB (se vazio)
            3. instala Docker (dnf) e o compose plugin (versão + SHA-256 fixados)
            4. grava /opt/gini/aws/docker-compose.yml e .env (600)
            5. pull; testa o RDS (pg_isready); confere o rótulo do frontend
            6. up -d; espera healthy; testa 127.0.0.1:8080 e :3000
            7. imprime o resumo
```

## Validação local (sem AWS)

```bash
# Compose, com e sem Mailpit
docker compose --env-file aws/.env.aws.example -f aws/docker-compose.aws.yml config
docker compose --env-file aws/.env.aws.example -f aws/docker-compose.aws.yml --profile mailpit config

# Scripts
for f in aws/bootstrap-ec2.sh aws/user-data.sh; do bash -n "$f"; done
shellcheck aws/bootstrap-ec2.sh aws/user-data.sh

# Plano do bootstrap com valores fictícios (não altera nada; termina com 0)
DRY_RUN=1 RDS_ENDPOINT=gini-db.exemplo.us-east-1.rds.amazonaws.com \
  DB_USER=gini_admin DB_PASSWORD=0123456789abcdef0123456789abcdef \
  JWT_SECRET=fedcba9876543210fedcba9876543210fedcba98 \
  BACKEND_TAG=sha-0000000 FRONTEND_TAG=sha-0000000 \
  bash aws/bootstrap-ec2.sh
```

## Regras

- Nenhum segredo neste diretório: só `CHANGE_ME` e valores fictícios.
- O `.env` real vive apenas em `/opt/gini/aws/.env` de cada instância.
- `docker/`, `scripts/deploy.sh` e os workflows **não** são usados na AWS:
  este diretório é independente do deploy local.
- Ao mudar a major do PostgreSQL, altere também a versão do RDS
  ([ADR-008](../docs/decisoes-tecnicas.md#adr-008--postgresql-17-postgres17-alpine)).
