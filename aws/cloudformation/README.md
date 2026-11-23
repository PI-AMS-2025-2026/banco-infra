# CloudFormation — desenho do template (fase futura)

> **Status:** só desenho. Nenhum template é versionado nesta fase: um template
> parcial ou não validado daria a falsa impressão de que a implantação por
> CloudFormation funciona. O procedimento vigente é o manual
> ([`docs/aws-learner-lab.md`](../../docs/aws-learner-lab.md)).

O template futuro (`aws/cloudformation/gini.yaml`) reproduz **exatamente** o
runbook, recurso por recurso. O contrato de valores está em
[`../PARAMETERS.md`](../PARAMETERS.md): cada linha de lá vira um `Parameter`,
um atributo de recurso ou um `Fn::GetAtt` aqui.

---

## 1. Parameters

Derivados de [`PARAMETERS.md` §1](../PARAMETERS.md#1-parâmetros-do-bootstrap):

| Parameter | Tipo | Padrão | Observação |
| --- | --- | --- | --- |
| `DbName` | String | `gini` | `AllowedPattern: ^[A-Za-z][A-Za-z0-9_]{0,62}$` |
| `DbUser` | String | `gini_admin` | idem |
| `DbPassword` | String | — | **`NoEcho: true`**, `MinLength: 8`, `MaxLength: 128`, `AllowedPattern` sem espaço, `/ ' " @ \ $` e crase |
| `JwtSecret` | String | — | **`NoEcho: true`**, `MinLength: 32`, `AllowedPattern: ^[A-Za-z0-9+/=_.-]+$` |
| `BackendTag` / `FrontendTag` | String | — | `AllowedPattern: ^sha-[0-9a-f]{7}$` (mais estrito que o bootstrap: só tags imutáveis) |
| `BackendImage` / `FrontendImage` | String | imagens do ghcr.io | minúsculas, sem tag |
| `AppEnvironment` | String | `staging` | `AllowedValues: [dev, staging, production]` |
| `EnableMailpit` | String | `true` | `AllowedValues: ["true", "false"]` |
| `InfraRef` | String | — | **sem padrão** `main`: obrigar tag ou commit |
| `InstanceType` | String | `t3.small` | `AllowedValues: [t3.micro, t3.small, t3.medium]` (x86_64; imagens só amd64) |
| `DbEngineVersion` | String | `17` (major) | conferir as versões disponíveis na região |
| `AmiId` | `AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>` | `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` | ⚠️ conferir se o Learner Lab lê parâmetros públicos do SSM; senão, `AWS::EC2::Image::Id` informado à mão |

Os `SMTP_*` só entram se um dia houver SMTP real (`EnableMailpit=false`).
`COMPOSE_VERSION`/`COMPOSE_SHA256`, `HEALTH_TIMEOUT` e `DRY_RUN` **não** viram
parâmetros: ficam com o padrão do script. `AWS_REGION` vem de `AWS::Region`.

`Metadata: AWS::CloudFormation::Interface` agrupa os parâmetros (Banco,
Segredos, Imagens, Instâncias) para o formulário do console.

## 2. Recursos e dependências

Mesma ordem do runbook. As dependências saem naturalmente das referências
(`!Ref`/`!GetAtt`); `DependsOn` explícito só onde indicado.

```
VPC ─┬─ InternetGateway + VPCGatewayAttachment
     ├─ SubnetPublicA/B (MapPublicIpOnLaunch: true) ─ RouteTablePublic ─ Route 0.0.0.0/0 → IGW
     └─ SubnetPrivateA/B ─ RouteTablePrivate (sem rota para a internet; sem NAT)
SgAlb ← SgEc2 (SourceSecurityGroupId: SgAlb) ← SgDb (SourceSecurityGroupId: SgEc2)
DbSubnetGroup (privadas) → GiniDb (SgDb)
TgFrontend (3000, /api/health)   TgBackend (8080, /actuator/health)
GiniLb (públicas, SgAlb) → ListenerHttp80 → TgFrontend
                         → ListenerHttp8080 → TgBackend
LaunchTemplate (AmiId, InstanceType, SgEc2, LabInstanceProfile, IMDSv2, UserData)
     └─ UserData usa GiniDb.Endpoint.Address e GiniLb.DNSName
App1 (SubnetPublicA)  App2 (SubnetPublicB)   [DependsOn: RoutePublicDefault]
     └─ registradas em TgFrontend e TgBackend via Targets do TargetGroup
```

| Recurso | Tipo | Pontos de atenção |
| --- | --- | --- |
| `Vpc`, sub-redes, IGW, rotas | `AWS::EC2::*` | CIDR `10.0.0.0/16`; AZs com `!Select [0, !GetAZs ""]` e `[1, …]` |
| `SgAlb`, `SgEc2`, `SgDb` | `AWS::EC2::SecurityGroup` | regras de entrada exatamente como no runbook §3; nenhuma porta 22 |
| `DbSubnetGroup` | `AWS::RDS::DBSubnetGroup` | duas sub-redes privadas |
| `GiniDb` | `AWS::RDS::DBInstance` | `db.t4g.micro`, `AllocatedStorage: 20`, `StorageType: gp3`, `MultiAZ: false`, `PubliclyAccessible: false`, `DBName: !Ref DbName`, `DeletionProtection: false`, `DeletionPolicy: Delete` + `UpdateReplacePolicy: Delete` (laboratório), sem `MonitoringRoleArn` |
| `TgFrontend`, `TgBackend` | `AWS::ElasticLoadBalancingV2::TargetGroup` | `HealthCheckPath`, `Matcher: {HttpCode: "200"}`, `Targets` com `App1`/`App2` |
| `GiniLb` | `AWS::ElasticLoadBalancingV2::LoadBalancer` | `Name: gini-lb`, `Scheme: internet-facing` |
| `ListenerHttp80`, `ListenerHttp8080` | `AWS::ElasticLoadBalancingV2::Listener` | ação `forward` |
| `LaunchTemplate` | `AWS::EC2::LaunchTemplate` | `IamInstanceProfile: {Name: LabInstanceProfile}`, `MetadataOptions.HttpTokens: required`, volume 20 GiB gp3 |
| `App1`, `App2` | `AWS::EC2::Instance` | `LaunchTemplate` + `SubnetId` + `Tags: Name=gini-app1/2` |

## 3. UserData e o DNS do ALB

O `UserData` do `LaunchTemplate` é o **mesmo texto** de
[`../user-data.sh`](../user-data.sh), com cada valor do bloco `PREENCHA AQUI`
trocado por uma referência do `Fn::Sub`:

```yaml
UserData: !Base64
  Fn::Sub:
    - |
      #!/bin/bash
      set -euo pipefail
      export RDS_ENDPOINT='${DbHost}'
      export ALB_DNS='${AlbDns}'
      export DB_PASSWORD='${DbPassword}'
      # ... demais variáveis do user-data.sh ...
      curl -fsSL --retry 5 --retry-delay 5 -o /root/gini-bootstrap-ec2.sh \
        "https://raw.githubusercontent.com/PI-AMS-2025-2026/banco-infra/$INFRA_REF/aws/bootstrap-ec2.sh"
      bash /root/gini-bootstrap-ec2.sh
    - DbHost: !GetAtt GiniDb.Endpoint.Address
      AlbDns: !GetAtt GiniLb.DNSName
```

- `ALB_DNS` vem de `!GetAtt GiniLb.DNSName` — não é preciso descobrir pela
  API. Isso cria a dependência LaunchTemplate → ALB, que garante a ordem
  "ALB antes das instâncias" do runbook.
- O `user-data.sh` não usa a forma "cifrão + chave" do bash (nem em
  comentários), justamente para não conflitar com o `Fn::Sub`. Manter essa
  regra ao editar o arquivo.
- Os valores `NoEcho` **continuam visíveis** no user data da instância
  (`NoEcho` só esconde no console do CloudFormation). Mesmo risco aceito do
  processo manual; alternativa em [`PARAMETERS.md` §3](../PARAMETERS.md#3-segredos).
- Opcional: `cfn-signal`/`CreationPolicy` nas instâncias para a stack só ficar
  `CREATE_COMPLETE` com o bootstrap concluído. Exige o pacote
  `aws-cfn-bootstrap` na AMI e mais lógica no wrapper — avaliar na implementação.

## 4. IAM

Nenhum recurso IAM é criado (o Learner Lab não permite). O template usa o
`LabInstanceProfile` existente por nome. A stack é criada pelo usuário do lab
(que assume o `voclabs`/`LabRole`); se o console pedir uma *role de serviço*
para o CloudFormation, escolha `LabRole` ou deixe em branco.
⚠️ Confirmar no Learner Lab se a criação de stacks exige `CAPABILITY_IAM`
(não deveria, já que não há recurso IAM).

## 5. Outputs

| Output | Valor |
| --- | --- |
| `AppUrl` | `!Sub "http://${GiniLb.DNSName}"` |
| `ApiUrl` | `!Sub "http://${GiniLb.DNSName}:8080"` |
| `RdsEndpoint` | `!GetAtt GiniDb.Endpoint.Address` |
| `App1Id` / `App2Id` | `!Ref App1` / `!Ref App2` (para o túnel do Session Manager) |

## 6. Destruição

**Excluir a stack** substitui o runbook §15 inteiro: o CloudFormation apaga na
ordem inversa das dependências. Para isso funcionar sem sobras:
`DeletionProtection: false` e `DeletionPolicy: Delete` no RDS (sem snapshot
final — é laboratório), nenhum recurso criado à mão dentro da VPC da stack.

## 7. Validação

Antes de versionar o template:

```bash
pip install cfn-lint
cfn-lint aws/cloudformation/gini.yaml
aws cloudformation validate-template --template-body file://aws/cloudformation/gini.yaml   # no CloudShell
```

E um ciclo completo no Learner Lab: criar a stack → 4/4 destinos íntegros →
login → recuperação de senha → excluir a stack → conferir que nada sobrou.
Só então o template entra no repositório (com um ADR atualizando o ADR-013).

## 8. Riscos específicos do Learner Lab

| Risco | Mitigação |
| --- | --- |
| IAM restrito: sem roles novas, sem `MonitoringRoleArn` no RDS, sem Secrets Manager gerenciado | usar `LabInstanceProfile`; senha `NoEcho` autogerenciada; monitoramento avançado desligado |
| Sem NAT: instâncias precisam de IP público para baixar imagens e falar com o SSM | instâncias nas sub-redes públicas com `MapPublicIpOnLaunch`; SG sem entrada direta |
| Limites de tipo (EC2 nano–large, RDS micro–medium, sem Multi-AZ) | `AllowedValues` nos parâmetros; `MultiAZ: false` fixo |
| Regiões (`us-east-1`/`us-west-2`) | `Rules`/`Conditions` recusando outras regiões |
| Leitura de parâmetros públicos do SSM pode ser negada | fallback para `AmiId` informado à mão |
| Instâncias paradas ao fim da sessão | sem impacto na stack; containers voltam sozinhos |
| Orçamento | `Outputs` lembrando de excluir a stack; ALB cobra enquanto existir |
| Credenciais do lab expiram a cada sessão | criar/excluir a stack pelo console ou CloudShell, não por pipeline |
