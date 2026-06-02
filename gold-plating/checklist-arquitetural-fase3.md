# Gold Plating — Checklist Arquitetural: 7 Princípios de Hooker aplicados ao EduVerse

> Verificação da conformidade da arquitetura da Fase 3 com os 7 Princípios de Hooker (Pressman, 2021).

---

## Os 7 Princípios e sua Aplicação

| # | Princípio | Aplicação no EduVerse Fase 3 | Status |
|---|---|---|---|
| **1** | **Razão** — toda decisão arquitetural deve ter justificativa | ADR 0001, 0002 e 0003 documentam contexto, decisão, alternativas e trade-offs | ✅ |
| **2** | **Valor** — a arquitetura deve agregar valor ao negócio | PaaS reduz custo operacional; escalabilidade horizontal suporta crescimento sem reescritas | ✅ |
| **3** | **Simplicidade** — o mais simples que satisfaça os requisitos | SQS ao invés de Kafka; Kong ao invés de Istio; REST ao invés de gRPC — cada escolha foi a mais simples viável | ✅ |
| **4** | **Separação de Preocupações** | Cada microsserviço tem responsabilidade única; API Gateway não contém lógica de negócio | ✅ |
| **5** | **Consistência** | Padrão de comunicação uniforme: REST via Gateway (síncrono) e SQS (assíncrono). Mesmo framework (Django DRF) para Auth e Content | ✅ |
| **6** | **Abertura** — documentar arquitetura para evolução futura | Este SAD + ADRs permitem novos membros entenderem o sistema sem depender de conhecimento tácito | ✅ |
| **7** | **Corretude** — a arquitetura deve satisfazer os requisitos | RNFs de disponibilidade (Multi-AZ), performance (cache + read replica) e segurança (JWT + HTTPS + Rate Limiting) mapeados na infraestrutura | ✅ |

---

## Itens de Dívida Técnica Identificados (para Fase 4)

| Item | Impacto | Prioridade |
|---|---|---|
| Sem observabilidade distribuída (tracing) | Dificulta debug de fluxos assíncronos | Alta |
| Dead Letter Queues não configuradas no SQS | Mensagens com falha são perdidas silenciosamente | Alta |
| Learning Engine sem versionamento de modelos | Rollback de um modelo de ML ruim é manual | Média |
| Autenticação entre serviços internos (mTLS) | Serviços internos confiam em qualquer caller na VPC | Média |
| Testes de contrato entre microsserviços ausentes | Mudança de interface de um serviço pode quebrar outro sem detecção | Média |

---

## Lei de Conway — Análise

> "Qualquer organização que projeta um sistema produzirá um design cuja estrutura é uma cópia da estrutura de comunicação da organização." — Melvin Conway, 1968

**Análise para o EduVerse:**

A equipe de 4 pessoas está estruturada em:
- 1 desenvolvedor full-stack (Frontend + API Gateway)
- 1 desenvolvedor Python (Auth Service + Content Service)
- 1 desenvolvedor IA/ML (Learning Engine)
- 1 desenvolvedor backend (Analytics + Notification)

Os microsserviços do EduVerse espelham essa estrutura de equipe. Isso é intencional — segundo a Lei de Conway, tentar criar fronteiras de serviço que contradizem a estrutura da equipe cria overhead de comunicação. A decomposição atual minimiza dependências cruzadas entre as responsabilidades de cada desenvolvedor.
