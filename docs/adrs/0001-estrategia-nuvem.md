# ADR 0001 — Estratégia de Nuvem e Escalabilidade

**Status:** Aceito  
**Data:** 2026-06-01  
**Contexto do Projeto:** EduVerse — Plataforma de Aprendizado Adaptativo com IA  
**Fase:** Ciclo 3 — Cloud e Microsserviços

---

## 1. Contexto

O EduVerse saiu da Fase 2 com uma arquitetura hexagonal monolítica rodando em um único servidor VPS. Com a decisão de migrar para microsserviços, surge a necessidade de definir **onde e como esses serviços serão implantados e escalonados**.

As restrições do projeto são:
- Equipe pequena (4 pessoas) sem dedicação exclusiva para operações de infraestrutura;
- Budget limitado de startup: custos operacionais devem crescer proporcionalmente ao uso, não de forma fixa;
- Picos de demanda previsíveis: o uso se concentra em horários comerciais e durante períodos de provas/avaliações, podendo aumentar 5x em janelas curtas;
- O **Learning Engine** (motor de IA) executa inferências com scikit-learn — cargas CPU-intensivas que precisam de escalonamento independente dos demais serviços;
- Disponibilidade exigida pelo SAD: **99,5% de uptime** (menos de 44h de downtime/ano).

A decisão central é: **qual modelo de nuvem adotar — IaaS, PaaS, SaaS ou Serverless?** E como abordar a escalabilidade: **horizontal (scale-out) ou vertical (scale-up)?**

---

## 2. Decisão

**Adotamos PaaS (Platform as a Service) na AWS como estratégia principal de nuvem, com escalabilidade horizontal via containers.**

Os serviços-chave escolhidos:

| Componente | Serviço AWS (PaaS) | Justificativa |
|---|---|---|
| Contêineres dos microsserviços | **ECS Fargate** | Orquestração sem gerenciar EC2 — a AWS provisiona e mantém o cluster |
| Banco de dados relacional | **RDS Aurora PostgreSQL** | Multi-AZ nativo, backups automatizados, failover em < 30s |
| Cache em memória | **ElastiCache (Redis)** | Gerenciado, replicação configurável, sem overhead de administração |
| Fila de mensagens | **Amazon SQS** | Serverless, escala automaticamente, sem broker a manter |
| Armazenamento de objetos | **Amazon S3 + CloudFront** | Durabilidade 99,999999999%, CDN global para arquivos de conteúdo |
| Build e deploy | **AWS CodePipeline + ECR** | CI/CD integrado, imagens Docker no repositório gerenciado |

**Escalabilidade:** Horizontal (scale-out). Cada microsserviço é um container stateless que escala adicionando réplicas via **ECS Auto Scaling** baseado em métricas de CPU e memória. O Learning Engine recebe uma política de scaling dedicada (CPU > 70% → adiciona réplicas).

---

## 3. Justificativa Teórica

### 3.1 Por que PaaS e não IaaS?

O modelo IaaS (ex.: EC2 puro) transfere para a equipe a responsabilidade de configurar e manter o sistema operacional, patches de segurança, bibliotecas de runtime e alta disponibilidade. Segundo Pressman e Maxim (2021), o custo total de propriedade (TCO) de IaaS inclui overhead operacional que tipicamente representa 30–40% do esforço de equipes pequenas.

O PaaS abstrai essa camada. O **ECS Fargate** elimina o gerenciamento de nós EC2: a equipe define o container e a AWS cuida do cluster. O **RDS Aurora** oferece Multi-AZ nativo sem que o time precise configurar replicação, failover ou backups — redução direta de risco operacional.

**Rejeição do SaaS:** Soluções como Bubble ou Teachable oferecem a plataforma pronta (SaaS), mas eliminam a possibilidade de customizar o motor de IA, que é o diferencial competitivo do EduVerse.

### 3.2 Por que não Serverless puro?

O modelo Serverless (AWS Lambda) seria adequado para funções de curta duração e acionadas por eventos. Porém, o Learning Engine executa inferências que podem durar entre 2–8 segundos — fora da janela ideal de Lambda (máximo eficiente < 300ms para UX). Além disso, o **cold start** do Lambda com bibliotecas scikit-learn pode atingir 3–5 segundos, degradando a experiência do aluno. O Serverless foi rejeitado para os serviços principais, mas permanece como candidato para funções auxiliares futuras (ex.: processamento de thumbnails de vídeo).

### 3.3 Por que escalabilidade horizontal?

A escalabilidade **vertical** (scale-up) — aumentar CPU/RAM de uma instância — tem limite físico e implica downtime durante a troca de instância. A escala **horizontal** (scale-out) — adicionar réplicas do container — é alinhada ao modelo de microsserviços stateless e permite escalonamento granular: se apenas o Learning Engine está sobrecarregado durante um período de provas, só ele escala, sem aumentar o custo dos demais serviços.

Conforme Newman (2019, *Building Microservices*), microsserviços projetados como stateless são escalonados horizontalmente de forma trivial — o estado é externalizado (Redis para sessões, RDS para persistência), e novas réplicas entram em operação em segundos.

---

## 4. Alternativas Rejeitadas

| Alternativa | Por que rejeitada |
|---|---|
| **IaaS puro (EC2 + gerenciamento manual)** | Alto overhead operacional para equipe pequena; patches, segurança e HA manuais aumentam risco e custo indireto |
| **SaaS (Teachable, Moodle Cloud)** | Inviabiliza o Learning Engine personalizado — o diferencial competitivo do produto |
| **Serverless puro (Lambda)** | Cold start inaceitável para inferência de ML (3–5s); limite de timeout do Lambda incompatível com cargas CPU-intensivas |
| **Google Cloud / Azure** | AWS tem ecossistema mais maduro no Brasil (região sa-east-1 em São Paulo), menor latência para usuários brasileiros, e maior familiaridade da equipe |
| **Escalabilidade vertical** | Limite físico, downtime na troca, custo cresce de forma não-linear |

---

## 5. Consequências

**Positivas (+):**
- Redução de overhead operacional: a equipe foca em produto, não em infraestrutura;
- Escalonamento granular e automático por serviço;
- Failover automático do RDS Aurora em < 30 segundos;
- Custo variável: o ECS Fargate cobra por vCPU/memória usados, sem custos fixos de servidores ociosos;
- Multi-AZ out-of-the-box para banco e cache.

**Negativas (-):**
- **Vendor lock-in:** serviços gerenciados (SQS, ECS Fargate, Aurora) são específicos da AWS. Migrar para outro provedor requer refatoração de infraestrutura;
- **Curva de aprendizado:** a equipe precisa dominar conceitos de IAM, VPC, ECS task definitions e CloudWatch;
- **Custo pode surpreender:** sem controle de Auto Scaling adequado, picos podem gerar bills inesperados. Mitigação: alertas de billing + limites de scaling máximo definidos.

---

## 6. Referências

- Newman, S. (2019). *Building Microservices* (2ª ed.). O'Reilly Media.
- Pressman, R. S.; Maxim, B. R. (2021). *Engenharia de Software: Uma Abordagem Profissional* (8ª ed.). McGraw-Hill.
- AWS Documentation. *Amazon ECS — Fargate Launch Type*. Disponível em: https://docs.aws.amazon.com/ecs/
- AWS Documentation. *Amazon RDS Aurora — High Availability*. Disponível em: https://docs.aws.amazon.com/rds/
