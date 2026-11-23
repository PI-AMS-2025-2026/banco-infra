# Runbook — Implantação na AWS Academy Learner Lab

Procedimento completo para implantar a aplicação Gini na **sua** conta do AWS
Academy Learner Lab, como ambiente de **homologação** (`staging`, com
Mailpit). Cada aluno faz isso na própria conta, pelo console.

Decisão e alternativas: [ADR-013](decisoes-tecnicas.md#adr-013--implantação-na-aws-learner-lab-um-ambiente-de-homologação-por-conta-bootstrap-por-script).
Parâmetros: [`aws/PARAMETERS.md`](../aws/PARAMETERS.md).
Visão geral e arquitetura: [`aws/README.md`](../aws/README.md).

> Os rótulos do console estão em português, com o nome em inglês entre
> parênteses quando ajuda a achar o campo. O console muda com o tempo: se um
> campo não estiver exatamente onde descrito, procure pelo nome em inglês.

Marcações usadas:

- ⚠️ **CONFIRA NO PAINEL** — depende do seu Learner Lab (limites, orçamento,
  versões). Confira antes de seguir.
- 💰 — gera custo enquanto existir.

---

## Sumário

0. [O que muda em relação ao roteiro anterior](#0-o-que-muda-em-relação-ao-roteiro-anterior)
1. [Antes de começar](#1-antes-de-começar)
2. [VPC](#2-vpc)
3. [Security Groups](#3-security-groups)
4. [RDS](#4-rds-postgresql-17)
5. [Target Groups](#5-target-groups)
6. [Application Load Balancer](#6-application-load-balancer)
7. [Launch template com o user data](#7-launch-template-com-o-user-data)
8. [Instâncias](#8-instâncias)
9. [Registrar as instâncias nos Target Groups](#9-registrar-as-instâncias-nos-target-groups)
10. [Validação](#10-validação)
11. [Acesso às instâncias (Session Manager)](#11-acesso-às-instâncias-session-manager)
12. [Mailpit e recuperação de senha com duas instâncias](#12-mailpit-e-recuperação-de-senha-com-duas-instâncias)
13. [Atualizar a versão ou a configuração](#13-atualizar-a-versão-ou-a-configuração)
14. [Fim da sessão: o que acontece e custos](#14-fim-da-sessão-o-que-acontece-e-custos)
15. [Destruir tudo](#15-destruir-tudo)
16. [Troubleshooting](#16-troubleshooting)
17. [Lista de verificação final](#17-lista-de-verificação-final)

---

## 0. O que muda em relação ao roteiro anterior

O roteiro manual anterior (Notion) usava a mesma topologia (VPC com 2 AZs, RDS,
2 EC2, Target Group, ALB). Este runbook o substitui e corrige:

| Problema no roteiro anterior | Correção aqui |
| --- | --- |
| O compose do backend subia um Postgres próprio e **ignorava o RDS** | [`aws/docker-compose.aws.yml`](../aws/docker-compose.aws.yml) não tem banco; o backend usa `RDS_ENDPOINT` |
| O frontend **nunca era iniciado** | o compose sobe backend **e** frontend; o bootstrap espera os dois ficarem `healthy` |
| **Build na instância** (lento, consome memória, resultado diferente por instância) | imagens prontas e públicas do ghcr.io, por tag imutável `sha-<7>` |
| Sem regra de SG para o RDS | `gini-sg-bd` aceita 5432 **só** de `gini-sg-ec2` |
| Porta e health check do Target Group não definidos | dois Target Groups com porta e caminho de health exatos |
| URL da API e do frontend definidas antes de existir o ALB | **nova ordem**: o ALB é criado **antes** das instâncias, e o bootstrap descobre o DNS dele |

Ordem de criação: **VPC → SGs → RDS → Target Groups → ALB → launch template →
instâncias → registro nos Target Groups.**

---

## 1. Antes de começar

### 1.1 Confira o Learner Lab ⚠️ **CONFIRA NO PAINEL**

Inicie o lab (**Start Lab**), espere o indicador ficar verde e abra o console
(**AWS**). Leia o **Readme** do lab e confira:

- [ ] **Região:** use **`us-east-1` (Norte da Virgínia)** em tudo. O Learner
      Lab costuma permitir só `us-east-1` e `us-west-2`.
- [ ] **Orçamento** restante da conta (canto superior do painel do lab).
      Este ambiente custa cerca de **US$ 0,10 por hora ligado** (§14).
- [ ] **Tipos permitidos:** EC2 de *nano* a *large* (On-Demand); RDS de
      *micro* a *medium*, **sem Multi-AZ**.
- [ ] **IAM:** não é possível criar usuários nem roles; usaremos o
      `LabInstanceProfile` (role `LabRole`) que já existe.

### 1.2 Gere os dois segredos (uma vez só)

No seu computador ou no **CloudShell** (ícone `>_` no topo do console):

```bash
openssl rand -hex 32   # → DB_PASSWORD
openssl rand -hex 32   # → JWT_SECRET
```

Guarde os dois num gerenciador de senhas. Eles serão usados **iguais** nas
duas instâncias e não devem ir para o Git, para o Notion nem para prints.

### 1.3 Escolha as tags das imagens

As imagens são públicas no ghcr.io (sem login):

- backend: `ghcr.io/pi-ams-2025-2026/backend-java`, tag `sha-<7>`;
- frontend: `ghcr.io/pi-ams-2025-2026/frontend-nextjs`, tag `sha-<7>` da
  **imagem única** (a que recebe a URL da API em runtime —
  [ADR-012](decisoes-tecnicas.md#adr-012--imagem-única-do-frontend-com-url-da-api-em-runtime)).

Use as **mesmas tags** que estão (ou estarão) em homologação no servidor local
— peça ao grupo, ou veja em GitHub → organização → *Packages*. Para conferir
que a tag do frontend é a imagem única (em qualquer máquina com Docker):

```bash
docker buildx imagetools inspect ghcr.io/pi-ams-2025-2026/frontend-nextjs:sha-XXXXXXX \
  --format '{{ index .Image.Config.Labels "br.fatec.gini.runtime-api-url" }}'
# precisa imprimir: true
```

> Não use tags `sha-<7>-<ambiente>` (legado, URL da API embutida no build) nem
> `staging`/`dev` (mutáveis; antes da Fase B do frontend apontam para imagens
> legado). O bootstrap recusa as legado e confere o rótulo antes de subir.

### 1.4 Escolha o `INFRA_REF`

`INFRA_REF` é a tag ou commit **deste** repositório de onde a instância baixa
o bootstrap e o compose. Use uma tag ou o hash de um commit que já esteja no
GitHub e contenha a pasta `aws/`. `main` funciona, mas se alguém alterar a
`main` entre a criação das duas instâncias, elas ficam diferentes.

### 1.5 Anote

Vá preenchendo esta tabela (fica só com você):

| Item | Valor |
| --- | --- |
| Região | `us-east-1` |
| `DB_PASSWORD` | (gerenciador de senhas) |
| `JWT_SECRET` | (gerenciador de senhas) |
| `BACKEND_TAG` / `FRONTEND_TAG` | `sha-…` / `sha-…` |
| `INFRA_REF` | |
| Endpoint do RDS (§4) | |
| DNS do ALB (§6) | |

---

## 2. VPC

Console → **VPC** → **Criar VPC** (*Create VPC*):

| Campo | Valor |
| --- | --- |
| Recursos a serem criados | **VPC e muito mais** (*VPC and more*) |
| Geração automática de etiqueta de nome | marcado, `gini` (gera `gini-vpc`, `gini-subnet-public1-us-east-1a`, …) |
| Bloco CIDR IPv4 | `10.0.0.0/16` |
| Bloco CIDR IPv6 | nenhum |
| Número de zonas de disponibilidade | **2** (ex.: `us-east-1a` e `us-east-1b`) |
| Sub-redes públicas | **2** |
| Sub-redes privadas | **2** |
| Gateways NAT | **Nenhum** (NAT custa por hora 💰 e não é necessário) |
| Endpoints da VPC | **Nenhum** |
| Opções de DNS | **Habilitar nomes de host DNS** e **Habilitar resolução de DNS** marcados |

> Valores alinhados ao roteiro da colega (2 AZs, 2 públicas, 2 privadas, sem
> NAT). Se ela usou outro CIDR, tanto faz: nada depende do CIDR.

**Criar VPC** e aguarde.

### 2.1 IP público automático nas sub-redes públicas

Sem NAT, as instâncias só alcançam a internet (para baixar as imagens e falar
com o Session Manager) se tiverem **IP público**. Para cada uma das **duas
sub-redes públicas**:

VPC → **Sub-redes** → selecione `gini-subnet-public1-…` → **Ações** →
**Editar configurações da sub-rede** → marque **Habilitar endereço IPv4
público de atribuição automática** → **Salvar**. Repita na `public2`.

> O IP público **não abre** a instância para a internet: quem decide o que entra
> é o Security Group, e `gini-sg-ec2` só aceita tráfego vindo do ALB.

---

## 3. Security Groups

Console → **EC2** → **Security Groups** → **Criar grupo de segurança**. Em
todos: **VPC = `gini-vpc`**; regras de **saída** = padrão (todo o tráfego).
Crie **nesta ordem**, porque um referencia o anterior.

### 3.1 `gini-sg-alb` (load balancer)

| Tipo | Protocolo | Porta | Origem | Descrição |
| --- | --- | --- | --- | --- |
| HTTP | TCP | 80 | `0.0.0.0/0` | frontend |
| TCP personalizado | TCP | 8080 | `0.0.0.0/0` | API (chamada pelo navegador) |

### 3.2 `gini-sg-ec2` (instâncias)

| Tipo | Protocolo | Porta | Origem | Descrição |
| --- | --- | --- | --- | --- |
| TCP personalizado | TCP | 3000 | **`gini-sg-alb`** (escolha o SG, não um CIDR) | frontend via ALB |
| TCP personalizado | TCP | 8080 | **`gini-sg-alb`** | backend via ALB |

**Sem regra de SSH (22).** O acesso às instâncias é pelo Session Manager
(§11), que não precisa de porta de entrada.

### 3.3 `gini-sg-bd` (RDS)

| Tipo | Protocolo | Porta | Origem | Descrição |
| --- | --- | --- | --- | --- |
| PostgreSQL | TCP | 5432 | **`gini-sg-ec2`** | backend das instâncias |

---

## 4. RDS (PostgreSQL 17)

### 4.1 Grupo de sub-redes

Console → **RDS** → **Grupos de sub-redes** → **Criar grupo de sub-redes de
banco de dados**:

| Campo | Valor |
| --- | --- |
| Nome / Descrição | `gini-db-subnets` / `Sub-redes privadas do RDS Gini` |
| VPC | `gini-vpc` |
| Zonas de disponibilidade | as duas usadas na VPC |
| Sub-redes | as **duas privadas** (confira o CIDR em VPC → Sub-redes) |

### 4.2 Banco de dados

RDS → **Bancos de dados** → **Criar banco de dados**:

| Campo | Valor |
| --- | --- |
| Método de criação | **Criação padrão** (*Standard create*) |
| Tipo de mecanismo | **PostgreSQL** |
| Versão do mecanismo | a **17.x** mais recente da lista ⚠️ **CONFIRA NO PAINEL**: se não houver 17, use a mais próxima disponível e avise o grupo (a major tem de bater com o [ADR-008](decisoes-tecnicas.md#adr-008--postgresql-17-postgres17-alpine)) |
| Modelos | **Nível gratuito** (*Free tier*) ou **Sandbox/Desenvolvimento e teste** |
| Disponibilidade | **Instância de banco de dados single-AZ** (Multi-AZ não é permitido no lab) |
| Identificador da instância | `gini-db` |
| Nome do usuário principal | `gini_admin` (vira `DB_USER`) |
| Gerenciamento de credenciais | **Autogerenciado** (*Self managed*) — **não** use o AWS Secrets Manager |
| Senha principal / Confirmar | o `DB_PASSWORD` do §1.2 |
| Classe da instância | **Classes com capacidade de intermitência** → `db.t4g.micro` |
| Armazenamento | gp3, **20 GiB**; **desmarque** "Habilitar escalabilidade automática do armazenamento" |
| Recurso de computação | **Não se conectar a um recurso de computação do EC2** |
| VPC / Grupo de sub-redes | `gini-vpc` / `gini-db-subnets` |
| Acesso público | **Não** |
| Grupo de segurança da VPC | **Escolher existente** → só `gini-sg-bd` (remova o `default`) |
| Zona de disponibilidade | Sem preferência |
| Autenticação de banco de dados | Autenticação de senha |
| Monitoramento | **desmarque** Performance Insights e **Monitoramento avançado** (este exige uma role IAM que o lab não deixa criar) |
| **Configuração adicional → Nome do banco de dados inicial** | **`gini`** — ⚠️ **sem isso o RDS não cria o banco** e o backend falha com `database "gini" does not exist` |
| Backup automatizado | retenção de **1 dia** (ou desabilitado, para economizar) |
| Criptografia | padrão (habilitada) |
| Proteção contra exclusão | **desmarcada** (para conseguir destruir no fim) |

**Criar banco de dados.** Ignore a oferta de complementos. A criação leva
**10–20 minutos**; siga para os Target Groups enquanto isso.

Quando o status for **Disponível**, abra `gini-db` → **Conectividade e
segurança** → copie o **Endpoint** (algo como
`gini-db.abcdefghijkl.us-east-1.rds.amazonaws.com`, **sem** a porta). Esse é o
`RDS_ENDPOINT`.

> O RDS com PostgreSQL 15+ exige SSL; o compose já conecta com
> `sslmode=require`. Nada a configurar.

---

## 5. Target Groups

EC2 → **Grupos de destino** (*Target Groups*) → **Criar grupo de destino**.
Crie **dois**; **não registre destinos agora** (as instâncias ainda não
existem).

| Campo | `gini-tg-frontend` | `gini-tg-backend` |
| --- | --- | --- |
| Tipo de destino | **Instâncias** | **Instâncias** |
| Protocolo : Porta | HTTP : **3000** | HTTP : **8080** |
| Tipo de endereço IP | IPv4 | IPv4 |
| VPC | `gini-vpc` | `gini-vpc` |
| Versão do protocolo | HTTP1 | HTTP1 |
| Protocolo de verificação de integridade | HTTP | HTTP |
| Caminho da verificação de integridade | **`/api/health`** | **`/actuator/health`** |
| Avançado → Porta | Porta de tráfego | Porta de tráfego |
| Avançado → Limite íntegro / não íntegro | 2 / 3 | 2 / 3 |
| Avançado → Tempo limite / Intervalo | 5 s / 15 s | 5 s / 15 s |
| Avançado → Códigos de sucesso | **200** | **200** |

Na tela "Registrar destinos", apenas clique **Criar grupo de destino**.

---

## 6. Application Load Balancer

EC2 → **Load balancers** → **Criar load balancer** → **Application Load
Balancer**:

| Campo | Valor |
| --- | --- |
| Nome | **`gini-lb`** (o bootstrap procura por esse nome) |
| Esquema | **Voltado para a Internet** (*Internet-facing*) |
| Tipo de endereço IP | IPv4 |
| VPC | `gini-vpc` |
| Mapeamentos | as **duas AZs**, cada uma com a sua **sub-rede pública** |
| Grupos de segurança | só **`gini-sg-alb`** (remova o `default`) |
| Listener 1 | HTTP : **80** → ação padrão: encaminhar para **`gini-tg-frontend`** |
| Listener 2 (**Adicionar listener**) | HTTP : **8080** → encaminhar para **`gini-tg-backend`** |

**Criar load balancer.** Abra `gini-lb` e copie o **Nome do DNS** (ex.:
`gini-lb-1234567890.us-east-1.elb.amazonaws.com`). A aplicação ficará em:

- frontend: `http://<DNS_DO_ALB>`
- API: `http://<DNS_DO_ALB>:8080`

> O DNS do ALB **não muda** enquanto o ALB existir, mesmo com as instâncias
> paradas. Se você apagar e recriar o ALB, o DNS muda — veja §13.3.

---

## 7. Launch template com o user data

### 7.1 Prepare o user data

Abra [`aws/user-data.sh`](../aws/user-data.sh) (no GitHub, botão *Raw*) e
copie o conteúdo para um editor **no seu computador**. Preencha o bloco
`PREENCHA AQUI`:

| Variável | Valor |
| --- | --- |
| `RDS_ENDPOINT` | endpoint do §4.2 (sem `:5432`) |
| `DB_USER` | `gini_admin` |
| `DB_PASSWORD` | o do §1.2 |
| `JWT_SECRET` | o do §1.2 |
| `BACKEND_TAG` / `FRONTEND_TAG` | as do §1.3 |
| `INFRA_REF` | o do §1.4 |
| `ALB_DNS` | **deixe vazio**: o bootstrap descobre pelo nome `gini-lb` |

Não altere nada abaixo do bloco. Não salve esse arquivo preenchido dentro do
repositório.

> ⚠️ O user data **não é sigiloso**: quem acessa o console da conta consegue
> lê-lo, e ele fica disponível nos metadados da instância. Aceitável no
> laboratório (a conta é só sua); por isso os segredos daqui são exclusivos
> deste ambiente e nunca reaproveitados na produção. Alternativa em
> [`aws/PARAMETERS.md` §3](../aws/PARAMETERS.md#3-segredos).

### 7.2 Crie o launch template

EC2 → **Modelos de execução** → **Criar modelo de execução**:

| Campo | Valor |
| --- | --- |
| Nome | `gini-template` |
| Orientação do Auto Scaling | desmarcada |
| AMI | **Amazon Linux 2023 AMI**, arquitetura **64 bits (x86)** |
| Tipo de instância | **`t3.small`** (2 GiB). `t3.micro` (1 GiB) só se o grupo aceitar o risco de falta de memória (Java + Node na mesma máquina). **Não** use `t4g` (ARM): as imagens são só amd64 |
| Par de chaves | **Não incluir no modelo** (acesso por Session Manager; `vockey` é opcional e não é usado) |
| Configurações de rede → Sub-rede | **Não incluir no modelo** (escolhida ao criar cada instância) |
| Firewall | **Selecionar grupo de segurança existente** → `gini-sg-ec2` |
| Armazenamento | volume raiz **20 GiB**, gp3 (o padrão de 8 GiB fica apertado com as imagens) |
| Tags de recurso | **não** adicione `Name` aqui (as duas instâncias ficariam com o mesmo nome) |
| Detalhes avançados → Perfil de instância do IAM | **`LabInstanceProfile`** — necessário para o Session Manager e para descobrir o DNS do ALB |
| Detalhes avançados → Metadados acessíveis / Versão | Habilitado / **Somente V2 (token obrigatório)** |
| Detalhes avançados → **Dados do usuário** | cole o user data **preenchido** do §7.1 |

**Criar modelo de execução.**

---

## 8. Instâncias

Confira antes: RDS **Disponível** e ALB **Ativo**. O bootstrap testa os dois
e espera alguns minutos por eles, mas não indefinidamente.

### 8.1 `gini-app1`

EC2 → **Modelos de execução** → `gini-template` → **Ações** → **Executar
instância a partir do modelo**:

- **Número de instâncias:** 1.
- **Configurações de rede → Sub-rede:** a **pública da AZ A**
  (`gini-subnet-public1-us-east-1a`).
- **Tags de recurso → Adicionar tag:** chave `Name`, valor **`gini-app1`**,
  tipos de recurso: Instâncias (e Volumes, se quiser).
- **Executar instância.**

### 8.2 `gini-app2` (outra AZ)

Repita o §8.1 escolhendo a sub-rede **pública da AZ B**
(`gini-subnet-public2-us-east-1b`) e a tag `Name` = **`gini-app2`**.

> Atenção à tag `Name`: se você esquecer, a instância aparece sem nome; se
> copiar a da primeira, as duas ficam com `gini-app1`. Corrija em
> Instância → **Tags** → **Gerenciar tags**.

### 8.3 Acompanhe o bootstrap

O bootstrap leva **5–10 minutos** (instalar Docker, baixar imagens, primeira
migração do banco). Conecte por Session Manager (§11) e acompanhe:

```bash
sudo tail -f /var/log/gini-bootstrap.log
```

O fim esperado é `Bootstrap concluído.` com o resumo e `docker compose ps`
mostrando `backend` e `frontend` como `healthy`. Se aparecer `[ERRO ]`, veja
§16. Erros de parâmetro aparecem todos juntos, logo no início.

---

## 9. Registrar as instâncias nos Target Groups

EC2 → **Grupos de destino**:

1. `gini-tg-frontend` → aba **Destinos** → **Registrar destinos** → marque
   `gini-app1` e `gini-app2` → porta **3000** → **Incluir como pendente
   abaixo** → **Registrar destinos pendentes**.
2. `gini-tg-backend` → mesma coisa com a porta **8080**.

Em 1–2 minutos os quatro destinos devem ficar **Íntegro** (*healthy*). Se
algum ficar **Não íntegro**, veja §16.1.

---

## 10. Validação

1. **Destinos:** os dois Target Groups com 2/2 destinos **Íntegros**.
2. **API:** no navegador ou no CloudShell:
   ```bash
   curl -s http://<DNS_DO_ALB>:8080/actuator/health   # {"status":"UP"...}
   ```
3. **Frontend:** abra `http://<DNS_DO_ALB>` (HTTP, **sem** `https://`).
4. **Login:** crie uma conta ou entre com um usuário de teste. Abra as
   ferramentas do desenvolvedor (F12) → **Rede**: as chamadas devem ir para
   `http://<DNS_DO_ALB>:8080/...` e voltar sem erro de CORS.
5. **Balanceamento:** recarregue algumas vezes; com as duas instâncias
   saudáveis o ALB alterna entre elas. O login continua válido porque o
   `JWT_SECRET` é o mesmo nas duas.
6. **Recuperação de senha:** §12.

---

## 11. Acesso às instâncias (Session Manager)

EC2 → **Instâncias** → selecione `gini-app1` → **Conectar** → aba **Session
Manager** → **Conectar**. Abre um terminal no navegador, como `ssm-user`.

```bash
sudo -i                                   # os comandos de Docker exigem root
cd /opt/gini/aws
docker compose ps                         # status dos containers
docker compose logs --tail=100 backend    # logs
cat /var/log/gini-bootstrap.log           # log do bootstrap
```

> Se "Conectar" estiver desabilitado no Session Manager: confira se a
> instância usa o `LabInstanceProfile` e tem IP público (§2.1), e espere uns
> minutos depois do boot para o agente se registrar.

---

## 12. Mailpit e recuperação de senha com duas instâncias

Cada instância tem o **seu** Mailpit, preso a `127.0.0.1:8025` dela (sem
login; mostra os links de redefinição). O e-mail de recuperação vai para o
Mailpit da instância **cujo backend atendeu** o "esqueci minha senha" — e o
ALB escolhe uma das duas. Então **procure nas duas**.

O link do e-mail aponta para `http://<DNS_DO_ALB>/...` (de `FRONTEND_URL`) e
funciona por qualquer instância: o token fica no RDS, compartilhado.

### 12.1 Ler pelo terminal do Session Manager (sem instalar nada)

Em cada instância:

```bash
# lista as mensagens (mais recentes primeiro)
curl -s http://127.0.0.1:8025/api/v1/messages \
  | python3 -c 'import sys,json; [print(m["Created"], m["Subject"]) for m in json.load(sys.stdin)["messages"]]'

# corpo em texto da mais recente (contém o link de redefinição)
curl -s http://127.0.0.1:8025/api/v1/message/latest \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["Text"])'
```

Lista vazia → o e-mail caiu na outra instância.

### 12.2 Interface web por túnel do Session Manager

No **seu computador** (não no CloudShell, que não abre portas para o seu
navegador), com:

- AWS CLI v2 e o **Session Manager plugin** instalados
  (<https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html>);
- as credenciais **temporárias** do lab: painel do Learner Lab → **AWS
  Details** → **AWS CLI: Show** → copie para `~/.aws/credentials`. Elas
  expiram a cada sessão do lab.

```bash
# um terminal por instância; troque i-... pelo ID (EC2 → Instâncias)
aws ssm start-session --region us-east-1 --target i-0aaaaaaaaaaaaaaaa \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8025"],"localPortNumber":["8025"]}'   # gini-app1

aws ssm start-session --region us-east-1 --target i-0bbbbbbbbbbbbbbbb \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8025"],"localPortNumber":["8026"]}'   # gini-app2
```

Abra `http://localhost:8025` (app1) e `http://localhost:8026` (app2).

> As mensagens ficam em memória: somem quando o container do Mailpit é
> recriado ou a instância é parada.

---

## 13. Atualizar a versão ou a configuração

O bootstrap é **idempotente**: reexecutar não reinstala nada e só recria os
containers cuja imagem ou configuração mudou.

### 13.1 Reexecutar com os mesmos valores

```bash
sudo bash /var/lib/cloud/instance/scripts/part-001
```

(`part-001` é a cópia do user data guardada pelo cloud-init, somente root.)

### 13.2 Trocar tags (nova versão da aplicação)

Em **cada** instância:

```bash
sudo nano /var/lib/cloud/instance/scripts/part-001   # altere BACKEND_TAG / FRONTEND_TAG
sudo bash /var/lib/cloud/instance/scripts/part-001
```

E, para instâncias criadas depois, crie uma **nova versão** do launch template
com os mesmos valores (Modelos de execução → `gini-template` → **Ações** →
**Modificar modelo (criar nova versão)**) e defina-a como padrão.

> Faça uma instância por vez: enquanto uma reinicia o backend, a outra segue
> atendendo pelo ALB. Lembre que as migrations do Flyway rodam na primeira que
> subir a versão nova e **não são revertidas** por voltar a tag
> ([ADR-006](decisoes-tecnicas.md#adr-006--backup-pré-deploy-obrigatório-rollback-de-imagem-não-reverte-o-banco)).

### 13.3 O ALB foi recriado (DNS mudou)

Com `ALB_DNS` vazio no user data, basta reexecutar o bootstrap (§13.1) nas
duas instâncias: ele descobre o novo DNS, regrava `FRONTEND_URL`/`API_URL` e
recria backend e frontend. Depois registre as instâncias nos Target Groups do
ALB novo (§9).

---

## 14. Fim da sessão: o que acontece e custos

### 14.1 Ao encerrar a sessão do lab ⚠️ **CONFIRA NO PAINEL**

O Learner Lab **para** as instâncias EC2 ao fim da sessão (o comportamento
exato de cada serviço está no Readme do lab). Ao iniciar o lab de novo:

| Recurso | O que acontece |
| --- | --- |
| EC2 | voltam paradas ou são religadas pelo lab; se paradas, **inicie-as** (EC2 → Instâncias → Iniciar). Recebem **IP público novo** — irrelevante: ninguém acessa pelo IP |
| Containers | voltam **sozinhos**: Docker habilitado no boot + `restart: unless-stopped`. O user data **não** roda de novo (nem precisa) |
| Target Groups | as instâncias continuam registradas (pelo ID); ficam *Não íntegras* enquanto paradas e voltam a *Íntegras* em ~1–2 min após o boot |
| ALB | **continua existindo e cobrando** 💰; DNS inalterado |
| RDS | se você o parar, a AWS o **religa sozinha após 7 dias** parado |
| Mailpit | mensagens perdidas (ficam em memória) |

Se o RDS estiver parado quando as instâncias subirem, o backend entra em
reinício até o banco voltar; depois de iniciar o RDS, espere alguns minutos.

### 14.2 Custo aproximado ⚠️ **CONFIRA NO PAINEL**

Preços On-Demand aproximados de `us-east-1`; confira em
<https://aws.amazon.com/pricing/> — o orçamento do lab é finito.

| Recurso | Aprox. por hora | Cobra parado? |
| --- | --- | --- |
| 2× EC2 `t3.small` | 2 × US$ 0,021 | não (só o disco) |
| 2× EBS gp3 20 GiB | ~US$ 0,004 no total | **sim** |
| RDS `db.t4g.micro` + 20 GiB | ~US$ 0,018 | instância não; **disco sim** |
| ALB | ~US$ 0,023 + uso | **sim** (enquanto existir) |
| IPv4 públicos (2 instâncias + ALB) | US$ 0,005 cada | o do ALB sim |
| **Total ligado** | **≈ US$ 0,10/h (≈ US$ 2,40/dia)** | |

Para economizar entre aulas: pare as instâncias e o RDS (RDS → `gini-db` →
**Ações** → **Parar temporariamente**). O ALB não pode ser pausado: se for
ficar dias sem usar, apague-o (e os listeners) e recrie depois seguindo §6,
§9 e §13.3.

---

## 15. Destruir tudo

Ao terminar a disciplina (ou se o orçamento estiver acabando), apague **nesta
ordem** (dependências primeiro):

1. **Instâncias:** EC2 → Instâncias → `gini-app1` e `gini-app2` → **Estado da
   instância** → **Encerrar** (*Terminate*). Os volumes são apagados junto.
2. **ALB:** Load balancers → `gini-lb` → **Ações** → **Excluir**.
3. **Target Groups:** `gini-tg-frontend` e `gini-tg-backend` → **Excluir**.
4. **Launch template:** `gini-template` → **Ações** → **Excluir modelo**.
5. **RDS:** `gini-db` → **Ações** → **Excluir**; desmarque "Criar snapshot
   final" e "Reter backups automatizados", confirme. Aguarde sumir (~10 min).
6. **Grupo de sub-redes do RDS:** `gini-db-subnets` → **Excluir**.
7. **Security Groups:** `gini-sg-bd`, `gini-sg-ec2`, `gini-sg-alb` (nesta
   ordem).
8. **VPC:** VPC → `gini-vpc` → **Ações** → **Excluir VPC** (remove sub-redes,
   tabelas de rotas e o internet gateway).
9. **Conferência:** EC2 → **Volumes**, **IPs elásticos** e **Snapshots**; RDS →
   **Snapshots**. Nada com `gini` deve sobrar.

---

## 16. Troubleshooting

### 16.1 Destino *Não íntegro* no Target Group

Veja o motivo em Grupos de destino → Destinos → coluna **Detalhes**.

| Detalhe | Causa provável | O que fazer |
| --- | --- | --- |
| `Request timed out` | SG | `gini-sg-ec2` precisa aceitar **3000 e 8080 vindos de `gini-sg-alb`** (o SG, não um IP) |
| `Connection refused` / `Target.FailedHealthChecks` | container fora do ar | Session Manager → `cd /opt/gini/aws && sudo docker compose ps`; veja o log do bootstrap |
| `Health checks failed with these codes: [404]` | caminho errado | frontend: `/api/health` na porta 3000; backend: `/actuator/health` na 8080 |
| `Target is in an Availability Zone that is not enabled` | ALB sem a AZ da instância | ALB → **Rede** → **Editar sub-redes**: as duas públicas |

Teste de dentro da instância:

```bash
curl -i http://127.0.0.1:3000/api/health
curl -i http://127.0.0.1:8080/actuator/health
```

### 16.2 Erro de CORS no navegador

`FRONTEND_URL` precisa ser **exatamente** a origem que aparece na barra do
navegador: `http://<DNS_DO_ALB>`, minúsculas, sem barra final, sem porta.

- Você abriu com `https://` ou pelo IP da instância → use `http://<DNS_DO_ALB>`.
- O ALB foi recriado → §13.3.
- Conferir o valor em uso: `sudo grep -E '^(FRONTEND_URL|API_URL)=' /opt/gini/aws/.env`.

### 16.3 RDS inacessível

O bootstrap para em "Conectividade com o RDS" ou o backend loga
`Connection refused`/`timeout`:

- RDS com status **Disponível**?
- `gini-sg-bd` aceita **5432 de `gini-sg-ec2`**? A instância está com
  `gini-sg-ec2`?
- RDS e instâncias na **mesma VPC** (`gini-vpc`)?
- `RDS_ENDPOINT` sem porta e sem espaço?

Teste manual na instância:

```bash
sudo docker run --rm postgres:17-alpine pg_isready -h <RDS_ENDPOINT> -p 5432
```

Backend loga `database "gini" does not exist` → faltou o **nome do banco
inicial** (§4.2). Crie o banco sem recriar o RDS:

```bash
sudo docker run --rm -it postgres:17-alpine \
  psql "host=<RDS_ENDPOINT> user=gini_admin dbname=postgres sslmode=require" \
  -c 'CREATE DATABASE gini;'
# digite a senha quando pedir; depois:
sudo bash /var/lib/cloud/instance/scripts/part-001
```

`password authentication failed` → `DB_PASSWORD` do user data diferente da
senha do RDS. Corrija no `part-001` (§13.2) e reexecute, ou troque a senha no
RDS (Modificar → Senha principal).

### 16.4 Frontend abre, mas não carrega dados (URL da API errada)

- F12 → **Rede**: para onde vão as chamadas? Devem ir para
  `http://<DNS_DO_ALB>:8080`.
- Chamadas para `localhost`, IP do servidor local ou outro host → a imagem é
  **legado** (URL embutida no build). O bootstrap recusa imagens sem o rótulo;
  se aconteceu, confira a `FRONTEND_TAG` (§1.3).
- URL certa mas sem resposta → listener **8080** do ALB e regra 8080 de
  `gini-sg-alb`.
- Valor dentro do container:
  `cd /opt/gini/aws && sudo docker compose exec frontend printenv API_URL`.

### 16.5 `permission denied ... docker.sock`

O Session Manager entra como `ssm-user`, fora do grupo `docker`. Use
`sudo` (ou `sudo -i`). Não adicione o `ssm-user` ao grupo `docker`: isso
equivale a dar root a ele.

### 16.6 O bootstrap não rodou ou parou no meio

```bash
sudo tail -n 100 /var/log/cloud-init-output.log   # saída do user data
sudo tail -n 100 /var/log/gini-bootstrap.log      # log do bootstrap
```

- `Parâmetros inválidos` → corrija os valores no
  `/var/lib/cloud/instance/scripts/part-001` e reexecute (§13.2); corrija
  também o launch template (nova versão).
- `curl: (22) ... 404` ao baixar o bootstrap → `INFRA_REF` não existe no
  GitHub ou ainda não tem a pasta `aws/`.
- `Não foi possível descobrir o DNS do ALB` → o ALB não se chama `gini-lb`, não
  existe, ou a instância está sem o `LabInstanceProfile`. Informe `ALB_DNS`
  explicitamente.
- `Falha no 'docker compose pull'` → instância sem IP público (§2.1) ou tag
  inexistente.

### 16.7 Falta de memória (`t3.micro`)

Sintomas: backend reiniciando, `Exited (137)`, instância lenta.

```bash
free -m; sudo docker stats --no-stream; sudo dmesg | grep -i -E 'killed process|oom'
```

Solução recomendada: tipo `t3.small` (Instância → **Ações** → **Configurações
da instância** → **Alterar tipo de instância**, com ela parada).

---

## 17. Lista de verificação final

- [ ] Região `us-east-1`; orçamento conferido no painel do lab.
- [ ] `gini-vpc` com 2 sub-redes públicas (IP público automático) e 2 privadas, sem NAT.
- [ ] `gini-sg-alb`: 80 e 8080 de `0.0.0.0/0`.
- [ ] `gini-sg-ec2`: 3000 e 8080 **só** de `gini-sg-alb`; **sem 22**.
- [ ] `gini-sg-bd`: 5432 **só** de `gini-sg-ec2`.
- [ ] RDS `gini-db`: PostgreSQL 17.x, `db.t4g.micro`, Single-AZ, **sem acesso público**, banco inicial `gini`, SG `gini-sg-bd`.
- [ ] Target Groups: `gini-tg-frontend` (3000, `/api/health`) e `gini-tg-backend` (8080, `/actuator/health`), matcher 200.
- [ ] ALB `gini-lb` internet-facing: :80 → frontend, :8080 → backend.
- [ ] Launch template `gini-template`: AL2023 x86_64, `t3.small`, 20 GiB, `gini-sg-ec2`, `LabInstanceProfile`, IMDSv2, user data preenchido.
- [ ] `gini-app1` e `gini-app2` em AZs diferentes, com a tag `Name` correta.
- [ ] Bootstrap concluído nas duas (`/var/log/gini-bootstrap.log`).
- [ ] 4/4 destinos **Íntegros**.
- [ ] `http://<DNS_DO_ALB>` abre, login funciona, sem erro de CORS.
- [ ] E-mail de recuperação localizado no Mailpit de uma das instâncias; link funciona.
- [ ] Segredos guardados fora do repositório; nenhum print com o user data.
- [ ] Plano de parada (§14) e de destruição (§15) combinado com o grupo.
