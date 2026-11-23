#!/bin/bash
#
# user-data.sh — User data do launch template `gini-template` (AWS Learner Lab).
#
# ONDE COLAR: EC2 → Modelos de execução → Criar modelo de execução →
# "Detalhes avançados" → campo "Dados do usuário" (User data). Cole o arquivo
# INTEIRO, já com os valores preenchidos. Passo a passo: docs/aws-learner-lab.md
#
# ATENÇÃO — ESTE TEXTO NÃO É SIGILOSO. O user data fica visível para quem tem
# acesso ao console (Ações → Configurações da instância → Editar dados do
# usuário) e a qualquer processo dentro da instância (metadados em
# 169.254.169.254). Aceitável no laboratório; alternativa em
# aws/PARAMETERS.md ("Segredos").
#
# O que faz: exporta os parâmetros abaixo, baixa o aws/bootstrap-ec2.sh da
# referência INFRA_REF deste repositório público e o executa como root. Toda
# a lógica está no bootstrap. Roda só no PRIMEIRO boot; depois de parar e
# iniciar a instância, o Docker e os containers voltam sozinhos.
# Reexecutar à mão (Session Manager):
#   sudo bash /var/lib/cloud/instance/scripts/part-001
#
# Saída: /var/log/cloud-init-output.log e /var/log/gini-bootstrap.log
#
# Reaproveitamento no CloudFormation (aws/cloudformation/README.md): o mesmo
# texto vira o UserData do LaunchTemplate com Fn::Sub. Por isso este arquivo
# NUNCA usa a forma "cifrão + chave" do bash (nem em comentários): o Fn::Sub
# trataria cada ocorrência como referência a um parâmetro do template. Cada
# valor entre aspas abaixo é trocado por uma referência do template.
#
set -euo pipefail

# ============================ PREENCHA AQUI =================================
# Obrigatórios. Os DOIS segredos são gerados UMA vez, no seu computador ou no
# CloudShell (openssl rand -hex 32), e são IGUAIS nas duas instâncias.
export RDS_ENDPOINT='CHANGE_ME.us-east-1.rds.amazonaws.com'  # endpoint do RDS, sem porta
export DB_USER='gini_admin'                                   # usuário principal do RDS
export DB_PASSWORD='CHANGE_ME'                                # senha principal do RDS
export JWT_SECRET='CHANGE_ME'                                 # 32+ caracteres
export BACKEND_TAG='sha-CHANGE_ME'                            # ex.: sha-a1b2c3d
export FRONTEND_TAG='sha-CHANGE_ME'                           # imagem ÚNICA: sha-<7>
export INFRA_REF='main'                                       # tag/commit deste repo; main só em laboratório

# Opcionais (padrões do bootstrap; veja aws/PARAMETERS.md).
export DB_NAME='gini'
export ALB_NAME='gini-lb'       # usado para descobrir o DNS do ALB
export ALB_DNS=''               # vazio = descobrir pelo ALB_NAME
export APP_ENVIRONMENT='staging'
export ENABLE_MAILPIT='true'
# ============================================================================

curl -fsSL --retry 5 --retry-delay 5 -o /root/gini-bootstrap-ec2.sh \
  "https://raw.githubusercontent.com/PI-AMS-2025-2026/banco-infra/$INFRA_REF/aws/bootstrap-ec2.sh"
bash /root/gini-bootstrap-ec2.sh
