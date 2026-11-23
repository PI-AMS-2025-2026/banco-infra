# Contrato de parâmetros — implantação na AWS

Este documento é o **contrato** entre três formas de criar o ambiente:

1. **hoje:** console da AWS, à mão ([`docs/aws-learner-lab.md`](../docs/aws-learner-lab.md));
2. **hoje:** user data do launch template ([`user-data.sh`](user-data.sh)) →
   [`bootstrap-ec2.sh`](bootstrap-ec2.sh);
3. **futuro:** template CloudFormation ([`cloudformation/README.md`](cloudformation/README.md)).

Regra: **todo parâmetro do bootstrap está na tabela 1**, e cada linha diz de
onde o valor vem no console e no CloudFormation. Migrar para CloudFormation é
trocar a coluna "console" pela coluna "CloudFormation", sem decidir nada novo.

Todos os parâmetros são **variáveis de ambiente** (nunca argumentos
posicionais). O bootstrap valida **todos** antes de mudar qualquer coisa e
lista **todos** os erros de uma vez. Qualquer valor com `CHANGE_ME` é recusado.

---

## 1. Parâmetros do bootstrap

### 1.1 Aplicação e banco

| Variável | Obrig. | Padrão | Validação | Origem no console (manual) | CloudFormation (futuro) |
| --- | --- | --- | --- | --- | --- |
| `RDS_ENDPOINT` | **sim** | — | nome DNS em minúsculas (`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.…)+$`), **sem porta** (`:` é recusado). Convertido para minúsculas. | RDS → Bancos de dados → `gini-db` → *Conectividade e segurança* → **Endpoint** | `!GetAtt GiniDb.Endpoint.Address` |
| `DB_NAME` | não | `gini` | `^[A-Za-z][A-Za-z0-9_]{0,62}$` | RDS → criação → *Configuração adicional* → **Nome do banco de dados inicial** | `Parameter DbName` (padrão `gini`) → `GiniDb.DBName` |
| `DB_USER` | **sim** | — | `^[A-Za-z][A-Za-z0-9_]{0,62}$` | RDS → criação → **Nome do usuário principal** (sugestão: `gini_admin`) | `Parameter DbUser` → `GiniDb.MasterUsername` |
| `DB_PASSWORD` | **sim** | — | 8–128 caracteres ASCII imprimíveis, sem espaço, `/ ' " @` (regra do RDS) nem `` \ ` $ ``. Gere **uma vez**: `openssl rand -hex 32`. Nunca impressa (só o tamanho). | RDS → criação → **Senha principal** (autogerenciada) | `Parameter DbPassword` (`NoEcho: true`) → `GiniDb.MasterUserPassword` |
| `JWT_SECRET` | **sim** | — | 32–512 caracteres de `[A-Za-z0-9+/=_.-]`. Gere **uma vez**: `openssl rand -hex 32`. **Igual nas duas instâncias.** Nunca impresso. | não existe no console: só no user data | `Parameter JwtSecret` (`NoEcho: true`) |
| `APP_ENVIRONMENT` | não | `staging` | `dev` \| `staging` \| `production`. `production` + Mailpit é recusado (ADR-011). | — (homologação) | `Parameter AppEnvironment` (`AllowedValues`) |

### 1.2 Load balancer e URLs

| Variável | Obrig. | Padrão | Validação | Origem no console (manual) | CloudFormation (futuro) |
| --- | --- | --- | --- | --- | --- |
| `ALB_DNS` | não¹ | descoberto | nome DNS (sem `http://`, sem porta), convertido para minúsculas | EC2 → Load balancers → `gini-lb` → **Nome do DNS** | `!GetAtt GiniLb.DNSName` |
| `ALB_NAME` | não | `gini-lb` | `^[A-Za-z0-9-]{1,32}$` | nome dado ao ALB na criação | `GiniLb.Name` (não é preciso: o DNS vem por `GetAtt`) |
| `AWS_REGION` | não | metadados da instância (IMDSv2) | formato de região; aviso se não for `us-east-1`/`us-west-2` | região do canto superior direito do console | pseudo-parâmetro `AWS::Region` |

¹ Se `ALB_DNS` estiver vazio, o bootstrap chama
`aws elbv2 describe-load-balancers --names "$ALB_NAME"` (até 20 tentativas,
15 s entre elas) com a credencial do `LabInstanceProfile`, e falha com mensagem
clara se não conseguir. **Deixar vazio é o recomendado no console**: se o ALB
for recriado, basta reexecutar o bootstrap.

Derivadas (não são parâmetros; o bootstrap calcula e grava no `.env`):

| Derivada | Valor | Uso |
| --- | --- | --- |
| `FRONTEND_URL` | `http://<ALB_DNS>` (sem barra final) | CORS e link do e-mail de recuperação, no backend |
| `API_URL` | `http://<ALB_DNS>:8080` | URL da API usada pelo navegador, no frontend (imagem única) |

### 1.3 Imagens

| Variável | Obrig. | Padrão | Validação | Origem no console (manual) | CloudFormation (futuro) |
| --- | --- | --- | --- | --- | --- |
| `BACKEND_TAG` | **sim** | — | `^[A-Za-z0-9_.-]{1,128}$`; aviso para tags mutáveis (`dev`, `staging`, `main`, `latest`) | GitHub → `backend-java` → Packages → tag `sha-<7>` | `Parameter BackendTag` |
| `FRONTEND_TAG` | **sim** | — | idem; **recusa** o formato legado `sha-<7>-<ambiente>`. Depois do pull, exige o rótulo OCI `br.fatec.gini.runtime-api-url=true` | GitHub → `frontend-nextjs` → Packages → tag `sha-<7>` da imagem única | `Parameter FrontendTag` |
| `BACKEND_IMAGE` | não | `ghcr.io/pi-ams-2025-2026/backend-java` | minúsculas, sem tag nem digest (mesmo regex do `deploy.sh`) | — | `Parameter BackendImage` (padrão igual) |
| `FRONTEND_IMAGE` | não | `ghcr.io/pi-ams-2025-2026/frontend-nextjs` | idem | — | `Parameter FrontendImage` (padrão igual) |

As imagens são públicas: não há usuário nem token de registry.
As imagens publicadas hoje são **somente `linux/amd64`**: use instâncias
x86_64 (`t3.*`). O bootstrap confere a arquitetura de cada imagem baixada.

### 1.4 E-mail (SMTP)

| Variável | Obrig. | Padrão | Validação | Origem no console | CloudFormation (futuro) |
| --- | --- | --- | --- | --- | --- |
| `ENABLE_MAILPIT` | não | `true` | `true` \| `false`. Com `true`, `SMTP_HOST` precisa ser `mailpit`; com `false`, precisa ser outro host. | — | `Parameter EnableMailpit` (`AllowedValues: [true, false]`) |
| `SMTP_HOST` | não | `mailpit` | `mailpit` ou nome DNS | — | `Parameter SmtpHost` (só se houver SMTP real) |
| `SMTP_PORT` | não | `1025` | numérica | — | `Parameter SmtpPort` |
| `SMTP_USERNAME` | não² | vazio | sem aspas simples nem quebra de linha | — | `Parameter SmtpUsername` |
| `SMTP_PASSWORD` | não² | vazio | idem; nunca impressa | — | `Parameter SmtpPassword` (`NoEcho: true`) |
| `SMTP_AUTH` | não | `false` | `true` \| `false` | — | `Parameter SmtpAuth` |
| `SMTP_STARTTLS` | não | `false` | `true` \| `false` | — | `Parameter SmtpStarttls` |
| `SMTP_FROM` | não | `noreply@gini.local` | formato de e-mail | — | `Parameter SmtpFrom` |

² Obrigatórias quando `SMTP_AUTH=true`. Os padrões são exatamente os do Mailpit
(ADR-011); só mexa nessas variáveis para usar um SMTP real com
`ENABLE_MAILPIT=false`.

### 1.5 Operação do script

| Variável | Obrig. | Padrão | Validação | Origem no console | CloudFormation (futuro) |
| --- | --- | --- | --- | --- | --- |
| `INFRA_REF` | não | `main` | `^[A-Za-z0-9._/-]{1,100}$`, sem `..`; **aviso** se `main` | tag ou commit deste repositório | `Parameter InfraRef` (sem padrão `main`: obrigar uma tag) |
| `COMPOSE_VERSION` | não | `v5.7.2` | `^vX.Y.Z$` (nunca `latest`) | — | fixo no script (não vira parâmetro) |
| `COMPOSE_SHA256` | não³ | checksum oficial da versão padrão para a arquitetura | 64 hexadecimais minúsculos | — | fixo no script |
| `HEALTH_TIMEOUT` | não | `300` | inteiro ≥ 30 (segundos) | — | fixo (padrão) |
| `DRY_RUN` | não | `0` | `0` \| `1`. Com `1`: só valida e imprime o plano; não exige root nem Amazon Linux e não altera nada. | — | não usado |

³ Obrigatório se `COMPOSE_VERSION` for diferente da padrão. Pegue o valor no
`checksums.txt` da release em <https://github.com/docker/compose/releases> —
nunca estime.

---

## 2. Recursos do console → CloudFormation

Valores que **não** são parâmetros do bootstrap, mas que o template futuro
precisa reproduzir. Nomes iguais aos do runbook.

| Console (manual) | Valor | CloudFormation (futuro) |
| --- | --- | --- |
| VPC `gini-vpc` (assistente "VPC e mais") | `10.0.0.0/16`, 2 AZs, 2 sub-redes públicas, 2 privadas, **sem NAT**, DNS habilitado | `AWS::EC2::VPC`, 4× `AWS::EC2::Subnet`, `AWS::EC2::InternetGateway` + `VPCGatewayAttachment`, `RouteTable`/`Route`/`SubnetRouteTableAssociation` |
| IP público automático nas sub-redes públicas | habilitado | `Subnet.MapPublicIpOnLaunch: true` |
| SG `gini-sg-alb` | entrada TCP 80 e 8080 de `0.0.0.0/0` | `AWS::EC2::SecurityGroup` |
| SG `gini-sg-ec2` | entrada TCP 3000 e 8080 **só** de `gini-sg-alb`; sem SSH | `AWS::EC2::SecurityGroup` + `SourceSecurityGroupId: !Ref SgAlb` |
| SG `gini-sg-bd` | entrada TCP 5432 **só** de `gini-sg-ec2` | `AWS::EC2::SecurityGroup` + `SourceSecurityGroupId: !Ref SgEc2` |
| Grupo de sub-redes do RDS `gini-db-subnets` | 2 sub-redes privadas | `AWS::RDS::DBSubnetGroup` |
| RDS `gini-db` | PostgreSQL 17.x, `db.t4g.micro`, 20 GiB gp3, Single-AZ, sem acesso público, banco inicial `gini` | `AWS::RDS::DBInstance` (`Engine: postgres`, `EngineVersion` parâmetro, `PubliclyAccessible: false`, `MultiAZ: false`, `DeletionProtection: false`) |
| Target Group `gini-tg-frontend` | instâncias, HTTP 3000, health `/api/health`, matcher 200 | `AWS::ElasticLoadBalancingV2::TargetGroup` (`Targets` com as duas instâncias) |
| Target Group `gini-tg-backend` | instâncias, HTTP 8080, health `/actuator/health`, matcher 200 | idem |
| ALB `gini-lb` | internet-facing, 2 sub-redes públicas, SG `gini-sg-alb` | `AWS::ElasticLoadBalancingV2::LoadBalancer` |
| Listener 80 | → `gini-tg-frontend` | `AWS::ElasticLoadBalancingV2::Listener` |
| Listener 8080 | → `gini-tg-backend` | `AWS::ElasticLoadBalancingV2::Listener` |
| Launch template `gini-template` | AL2023 x86_64, `t3.small`, 20 GiB gp3, `LabInstanceProfile`, IMDSv2, user data | `AWS::EC2::LaunchTemplate` (`UserData: !Base64 !Sub …`) |
| AMI | Amazon Linux 2023 (x86_64) | `Parameter AmiId` do tipo `AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>` com padrão `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` (**conferir** se o `LabRole`/usuário do lab lê parâmetros públicos do SSM) |
| Tipo de instância | `t3.small` | `Parameter InstanceType` (`AllowedValues: [t3.micro, t3.small, t3.medium]`) |
| Instâncias `gini-app1`, `gini-app2` | uma em cada sub-rede pública (AZs diferentes), tag `Name` distinta | 2× `AWS::EC2::Instance` com `LaunchTemplate` + `SubnetId` + `Tags` |
| Perfil de instância | `LabInstanceProfile` (já existe; não criar IAM) | `IamInstanceProfile.Name: LabInstanceProfile` (literal ou parâmetro) |
| Par de chaves | nenhum (acesso por Session Manager) | omitido |

---

## 3. Segredos

`DB_PASSWORD`, `JWT_SECRET` e `SMTP_PASSWORD` são os únicos segredos.

- **Nunca** são gerados pelo bootstrap: o aluno gera **uma vez** e informa o
  mesmo valor nas duas instâncias (senão o login feito numa instância é
  rejeitado pela outra, e o backend não conecta ao RDS).
- O bootstrap os grava só em `/opt/gini/aws/.env` (modo `600`, dono root) e
  nunca os imprime (aparecem como `******** (N caracteres)`).
- **Risco aceito no laboratório:** o user data **não é sigiloso**. Ele aparece
  no console (Ações → Configurações da instância → Editar dados do usuário),
  nas versões do launch template e nos metadados da instância
  (`169.254.169.254`), acessíveis a qualquer processo dentro dela. Uma cópia
  fica em `/var/lib/cloud/instance/` (somente root).
- **Alternativa (não implementada):** SSM Parameter Store com `SecureString`
  (`/gini/db-password`, `/gini/jwt-secret`); o bootstrap leria com
  `aws ssm get-parameter --with-decryption`, e o user data passaria só os
  **nomes**. Exige que o `LabRole` permita `ssm:GetParameter` e `kms:Decrypt`
  na chave `aws/ssm` — **confira no seu Learner Lab** antes de adotar
  (teste no CloudShell e numa instância:
  `aws ssm get-parameter --name /gini/teste --with-decryption`). No
  CloudFormation, o equivalente é o tipo de parâmetro
  `AWS::SSM::Parameter::Value<String>` ou referências dinâmicas
  `{{resolve:ssm-secure:...}}` (estas só são aceitas em alguns recursos, como
  `MasterUserPassword` do RDS — não no `UserData`).
