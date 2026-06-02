# SAD — Software Architecture Document
## EduVerse: Plataforma de Aprendizado Adaptativo com IA
### Fase 3 — Cloud e Microsserviços

**Versão:** 3.0  
**Data:** 2026-06-01  
**Responsável:** Vitor Martins Melo — 2320023  
**Disciplina:** Arquitetura de Software | Prof. Carlos Gomes | UniEvangélica 2026.1  
**Referência normativa:** IEEE 1471 / ISO/IEC/IEEE 42010:2011

---

## 1. Introdução

### 1.1 Propósito

Este documento descreve a arquitetura de software do EduVerse na Fase 3 (Cloud e Microsserviços). Ele serve como referência oficial para desenvolvedores, avaliadores e futuros membros da equipe, comunicando as decisões estruturais e as justificativas arquiteturais que guiaram a evolução do sistema.

### 1.2 Escopo

O EduVerse é uma plataforma de aprendizado adaptativo que utiliza IA para personalizar trilhas de conteúdo educacional conforme o perfil e ritmo de cada aluno. O sistema atende dois tipos de usuário: **estudantes** (acesso a trilhas personalizadas) e **administradores** (gestão de conteúdo e monitoramento de métricas).

### 1.3 Evolução Arquitetural por Fase

| Fase | Arquitetura | Decisão Principal |
|---|---|---|
| **Fase 1** | Monólito Django | Velocidade de MVP, equipe pequena |
| **Fase 2** | Hexagonal (Ports & Adapters) | Separação de domínio de negócio da infraestrutura |
| **Fase 3** *(este documento)* | Microsserviços em Cloud (AWS PaaS) | Escalabilidade independente, resiliência a falhas |

---

## 2. Requisitos Arquiteturais

### 2.1 Requisitos Funcionais Críticos

| RF | Descrição | Critério de Aceite |
|---|---|---|
| RF-01 | O sistema deve recomendar trilhas de conteúdo personalizadas para cada aluno | 95% das recomendações entregues em < 2s (P95) |
| RF-02 | O aluno deve conseguir acompanhar seu progresso em tempo real | Dashboard de progresso atualizado em < 5s após conclusão de exercício |
| RF-03 | O administrador deve conseguir publicar e gerenciar conteúdo | Publicação de novo módulo disponível para alunos em < 10s |

### 2.2 Requisitos Não Funcionais (FURPS+)

| Atributo | Requisito | Métrica |
|---|---|---|
| **Disponibilidade** | O sistema deve estar disponível 99,5% do tempo | < 44 horas de downtime/ano; Multi-AZ obrigatório |
| **Escalabilidade** | Suportar de 500 a 5.000 usuários simultâneos sem degradação | ECS Auto Scaling responde a picos em < 60 segundos |
| **Performance** | Latência de carregamento de conteúdo | P95 < 500ms para Content Service; P95 < 2s para Learning Engine |
| **Segurança** | Autenticação e autorização | JWT com expiração de 60 min; refresh token de 7 dias; HTTPS obrigatório |
| **Manutenibilidade** | Deploys sem downtime | Blue/green deployment via ECS; rollback automatizado |

---

## 3. Visão Lógica — Arquitetura de Microsserviços

### 3.1 Microsserviços Identificados

O sistema é decomposto seguindo o princípio de **Single Responsibility** por domínio de negócio (Bounded Context — Evans, 2003):

| Serviço | Domínio | Tecnologia | Responsabilidade |
|---|---|---|---|
| **Auth Service** | Identidade | Django 5 + SimpleJWT | Registro, login, tokens, RBAC |
| **Content Service** | Conteúdo | Django 5 + DRF | CRUD de módulos, vídeos, exercícios |
| **Learning Engine** | IA/Recomendação | FastAPI + scikit-learn | Análise de histórico, recomendação de trilhas |
| **Notification Service** | Comunicação | Node.js 20 | Push (FCM) e e-mail (SES) |
| **Analytics Service** | Métricas | FastAPI + Pandas | Consolidação de eventos, dashboard admin |
| **API Gateway** | Infraestrutura | Kong Gateway | Routing, Auth offload, Rate Limiting, Timeout |

### 3.2 Regras de Dependência

- Cada microsserviço possui seu próprio banco de dados (Database per Service) — sem acesso direto ao banco de outro serviço;
- Serviços se comunicam exclusivamente via API Gateway (fluxos síncronos) ou via SQS (fluxos assíncronos);
- O Learning Engine é o único serviço que lê dados de múltiplas origens: progresso do aluno (via réplica de leitura do RDS) e configurações de trilha (via API REST do Content Service).

---

## 4. Visão de Implantação — Infraestrutura Cloud (AWS)

### 4.1 Diagrama de Implantação

```
                        ┌─────────────────────────────────────────┐
                        │         AWS Cloud (sa-east-1)            │
                        │                                          │
   Aluno / Admin        │  ┌─────────┐     ┌──────────────────┐   │
   ─────────────→ CF ──→│  │   ALB   │────→│   API Gateway    │   │
   (HTTPS)       CDN    │  │ (HTTPS) │     │   (Kong/ECS)     │   │
                        │  └─────────┘     └────────┬─────────┘   │
                        │                           │              │
                        │         ┌─────────────────┼──────────┐  │
                        │         ↓                 ↓          ↓  │
                        │  ┌──────────┐  ┌──────────────┐  ┌──────────┐  │
                        │  │   Auth   │  │   Content    │  │ Learning │  │
                        │  │ Service  │  │   Service    │  │  Engine  │  │
                        │  │ (ECS FG) │  │  (ECS FG)   │  │ (ECS FG) │  │
                        │  └────┬─────┘  └──────┬───────┘  └────┬─────┘  │
                        │       │               │               │         │
                        │       └───────────────┴───────────────┘         │
                        │                       ↓                          │
                        │              ┌─────────────────┐                 │
                        │              │  RDS Aurora PG  │                 │
                        │              │    (Multi-AZ)   │                 │
                        │              └─────────────────┘                 │
                        │                                                  │
                        │  ┌────────────────────────────────────────────┐  │
                        │  │              Amazon SQS (FIFO)             │  │
                        │  │  progress-events | notification | analytics │  │
                        │  └───────────────────┬────────────────────────┘  │
                        │                      ↓                           │
                        │         ┌────────────────────────┐               │
                        │         │  Notification Service  │               │
                        │         │  Analytics Service     │               │
                        │         │      (ECS Fargate)     │               │
                        │         └────────────────────────┘               │
                        └──────────────────────────────────────────────────┘
```

### 4.2 Configurações de Infraestrutura

| Componente | Configuração | Motivo |
|---|---|---|
| ECS Fargate (cada serviço) | Min: 1 task / Max: 10 tasks | Auto Scaling baseado em CPU > 70% |
| RDS Aurora PostgreSQL | db.t3.medium, Multi-AZ, 1 réplica de leitura | Alta disponibilidade e isolamento de carga de leitura |
| ElastiCache Redis | cache.t3.micro, 2 nós (1 primário + 1 réplica) | Cache de sessões e predições do Learning Engine |
| SQS FIFO | MessageRetentionPeriod: 4 dias, VisibilityTimeout: 30s | Garantia de processamento at-least-once |
| CloudFront | TTL 1 hora para arquivos estáticos, 0 para APIs | CDN para assets, bypass para dados dinâmicos |

---

## 5. Visão de Processos — Fluxos Principais

### 5.1 Fluxo Síncrono: Aluno solicita recomendações

```
Aluno → [HTTPS] → CloudFront → ALB → API Gateway (Kong)
  Kong: valida JWT, verifica rate limit, aplica timeout global (10s)
  Kong → [REST interno] → Learning Engine
    Learning Engine: consulta Redis (cache de predições)
      Cache HIT → retorna predição em < 50ms
      Cache MISS → consulta réplica de leitura RDS → executa inferência → salva no Redis
  API Gateway ← [JSON] ← Learning Engine
Aluno ← [HTTP 200, JSON] ← API Gateway
```

**Circuit Breaker:** Se Learning Engine não responde em 10s ou atinge 50% de falhas → Kong retorna HTTP 200 com conteúdo popular do Redis (fallback gracioso).

### 5.2 Fluxo Assíncrono: Aluno conclui exercício

```
Aluno → [POST /api/progress] → API Gateway
  API Gateway: autentica JWT, publica evento em SQS progress-events.fifo
  API Gateway ← [HTTP 202 Accepted] imediatamente
Aluno ← [HTTP 202] ← API Gateway (< 100ms)

--- em background ---
Analytics Service: Long Polling em SQS progress-events.fifo
  Consome evento → agrega métricas → salva em RDS
  (até 5 segundos de atraso consistência eventual)

Learning Engine: consumidor de SQS notification-events.fifo
  Detecta conclusão → gera nova recomendação → publica em notification-events
Notification Service: consome notification-events → envia push/email
```

---

## 6. Visão de Dados

### 6.1 Estratégia de Persistência

O EduVerse adota o padrão **Database per Service**: cada microsserviço é dono de seus dados e outros serviços nunca acessam diretamente seu banco.

| Serviço | Banco | Justificativa |
|---|---|---|
| Auth Service | RDS PostgreSQL (schema `auth`) | ACID para transações de credenciais |
| Content Service | RDS PostgreSQL (schema `content`) | Dados relacionais estruturados |
| Learning Engine | RDS PostgreSQL (schema `learning`, read replica) + Redis | Read replica para não onerar o banco principal com queries de ML |
| Analytics Service | RDS PostgreSQL (schema `analytics`) | Dados históricos, queries analíticas com índices específicos |

### 6.2 Dados em Cache (Redis)

| Chave | Conteúdo | TTL |
|---|---|---|
| `session:{userId}` | Dados de sessão ativa | 60 min (renovado no refresh) |
| `recommendations:{userId}` | Última lista de recomendações do Learning Engine | 60 min |
| `popular_content` | Top 20 conteúdos mais acessados (fallback do Circuit Breaker) | 1 hora |
| `rate_limit:{userId}` | Contador de requisições por minuto | 60 segundos |

---

## 7. Decisões Arquiteturais — Resumo

| ADR | Decisão | Alternativa Rejeitada Principal |
|---|---|---|
| [ADR 0001](../adrs/0001-estrategia-nuvem.md) | PaaS (AWS ECS Fargate + RDS + SQS) + Escala horizontal | IaaS puro (EC2 gerenciado manualmente) |
| [ADR 0002](../adrs/0002-padrao-resiliencia.md) | API Gateway + Circuit Breaker + Bulkhead | Timeout simples sem Fail Fast |
| [ADR 0003](../adrs/0003-modelo-comunicacao.md) | REST síncrono (leituras) + SQS assíncrono (escritas) | 100% REST síncrono (acoplamento temporal) |

---

## 8. Riscos e Mitigações

| Risco | Probabilidade | Impacto | Mitigação |
|---|---|---|---|
| Vendor lock-in AWS | Média | Alto | Abstrair serviços AWS via interfaces (ex: interface de fila que pode ser implementada por SQS ou RabbitMQ) |
| Cold start do Learning Engine | Alta (em scaling) | Médio | ECS Fargate mantém mínimo de 1 task ativa; cache de predições no Redis reduz demanda de inferência |
| Consistência eventual problemática | Baixa | Médio | Comunicar na UI quando dados são eventuais; monitorar tamanho da fila SQS |
| Custo AWS excedendo budget | Média | Alto | Billing alerts no CloudWatch; limites de Auto Scaling definidos; Reserved Instances para RDS |

---

## 9. Referências

- Evans, E. (2003). *Domain-Driven Design: Tackling Complexity in the Heart of Software*. Addison-Wesley.
- Newman, S. (2019). *Building Microservices* (2ª ed.). O'Reilly Media.
- Richardson, C. (2018). *Microservices Patterns*. Manning Publications.
- Nygard, M. T. (2018). *Release It!* (2ª ed.). Pragmatic Bookshelf.
- Pressman, R. S.; Maxim, B. R. (2021). *Engenharia de Software: Uma Abordagem Profissional* (8ª ed.). McGraw-Hill.
- IEEE Std 1471-2000. *Recommended Practice for Architectural Description of Software-Intensive Systems*.
- ISO/IEC/IEEE 42010:2011. *Systems and software engineering — Architecture description*.
