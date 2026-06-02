# ADR 0002 — Padrões de Resiliência

**Status:** Aceito  
**Data:** 2026-06-01  
**Contexto do Projeto:** EduVerse — Plataforma de Aprendizado Adaptativo com IA  
**Fase:** Ciclo 3 — Cloud e Microsserviços

---

## 1. Contexto

Com a migração para microsserviços na AWS (→ ADR 0001), o EduVerse passou a ter sete serviços independentes se comunicando pela rede. Esse cenário introduz um risco crítico que não existia no monólito: **falha em cascata**.

O caso mais provável de falha no EduVerse é o **Learning Engine**: por executar inferências com scikit-learn, ele é CPU-intensivo e responde mais lentamente sob carga — especialmente em picos de avaliações, quando dezenas de alunos solicitam recomendações simultaneamente.

Se o Learning Engine ficar lento ou cair e o API Gateway continuar enviando requisições sem controle:
1. As threads do Gateway ficam presas aguardando resposta do Engine;
2. Novas requisições de *outros* serviços (Content Service, Auth) também ficam bloqueadas porque o pool de conexões está esgotado;
3. O sistema todo degradou por causa de um único serviço sobrecarregado — **falha em cascata**.

A decisão central é: **quais padrões de resiliência adotar para garantir que a falha de um microsserviço não derrube os demais?**

---

## 2. Decisão

**Adotamos uma estratégia em três camadas: API Gateway (Kong) + Circuit Breaker (Resilience4j/pybreaker) + Bulkhead via pools de threads isolados.**

### Camada 1 — API Gateway (Kong)

O Kong atua como ponto de entrada único e primeira linha de defesa:

| Funcionalidade | Configuração no EduVerse |
|---|---|
| **Routing** | Roteia `/api/recommendations/*` → Learning Engine, `/api/content/*` → Content Service, etc. O cliente nunca conhece os IPs dos serviços internos |
| **Rate Limiting** | 60 req/min por aluno autenticado; 300 req/min para admins |
| **Timeout global** | 10 segundos máximo por upstream. Se o Learning Engine não responder em 10s, o Gateway retorna HTTP 503 imediatamente em vez de bloquear indefinidamente |
| **Auth offloading** | Validação do JWT no Gateway — os microsserviços internos recebem o token já validado, sem necessidade de cada um reimplementar autenticação |

### Camada 2 — Circuit Breaker

Implementado diretamente nos serviços que chamam o Learning Engine (principalmente o API Gateway via plugin Kong):

```
Estado FECHADO:
  - Chamadas ao Learning Engine fluem normalmente
  - O CB monitora a taxa de falha na janela dos últimos 10s

Estado ABERTO (ativado quando falhas > 50% em 10 requisições):
  - Bloqueia chamadas imediatamente (Fail Fast)
  - Retorna FALLBACK: lista de conteúdos populares em cache (Redis)
  - Aguarda 30 segundos antes de tentar novamente

Estado MEIO-ABERTO:
  - Deixa passar 1 requisição de teste
  - Se sucesso → FECHADO
  - Se falha → ABERTO por mais 30s
```

**Fallback:** quando o Circuit Breaker está ABERTO, o aluno recebe recomendações baseadas no conteúdo mais popular geral (armazenado em Redis com TTL de 1 hora), em vez de uma tela de erro. A degradação é *graceful* — o sistema funciona com qualidade reduzida, não falha completamente.

### Camada 3 — Bulkhead

O ECS Fargate já isola containers fisicamente (CPU/memória), mas o Bulkhead é implementado no nível de pools de threads do API Gateway:

| Pool | Responsabilidade | Tamanho do Pool |
|---|---|---|
| `pool-learning` | Chamadas ao Learning Engine (lento, CPU-intensivo) | 20 threads |
| `pool-content` | Chamadas ao Content Service (rápido, I/O bound) | 50 threads |
| `pool-auth` | Chamadas ao Auth Service (crítico, deve sempre responder) | 30 threads |

Se o Learning Engine travar e esgotar `pool-learning`, os pools de Content e Auth continuam disponíveis. O aluno não consegue ver recomendações personalizadas, mas ainda faz login e acessa o conteúdo.

---

## 3. Justificativa Teórica

### 3.1 Por que API Gateway é o primeiro padrão?

Segundo Fowler e Lewis (2014, *Microservices*), o API Gateway resolve o problema de "chatty clients" — sem ele, o frontend precisaria conhecer os endereços de todos os microsserviços e fazer múltiplas chamadas. O Gateway centraliza roteamento, autenticação e políticas de timeout, criando um ponto de controle sem necessidade de replicar lógica de infraestrutura em cada serviço.

O anti-padrão que evitamos: **não colocar lógica de negócio no Gateway**. O Gateway do EduVerse apenas roteia, autentica e limita — não orquestra regras de domínio. Isso evita que ele se torne um ESB (Enterprise Service Bus) ou um "monólito distribuído".

### 3.2 Por que Circuit Breaker é essencial para o Learning Engine?

O Learning Engine é o componente mais lento e imprevisível do EduVerse — a inferência de ML depende do tamanho do histórico do aluno e da carga de CPU. Sem Circuit Breaker, uma sobrecarga momentânea no Engine bloqueia threads do Gateway até o timeout global de 10s, esgotando os pools disponíveis para outros serviços.

O Circuit Breaker implementa o princípio **Fail Fast**: em vez de esperar 10s para descobrir que o serviço está indisponível, o estado ABERTO retorna o erro/fallback imediatamente (< 1ms). Isso libera threads e permite que o sistema continue servindo outras requisições.

Conforme o Azure Architecture Center (Microsoft, 2024), o Circuit Breaker é recomendado especificamente para chamadas a serviços com latência variável — exatamente o perfil do Learning Engine.

### 3.3 Por que Bulkhead ao invés de um único pool compartilhado?

Sem Bulkhead, um pool único de 100 threads serve todos os microsserviços. Se o Learning Engine consumir 90 threads (cenário de pico de avaliações), apenas 10 restam para Auth e Content — que são muito mais rápidos e críticos. Um serviço lento "starva" os serviços rápidos.

O Bulkhead, inspirado nos compartimentos estanques de navios (Nygard, 2018), garante que cada serviço tem sua cota de recursos. A falha fica *contida* dentro do compartimento do serviço problemático. Segundo Nygard, em sistemas de alto volume essa isolação é a diferença entre "degradação de uma funcionalidade" e "indisponibilidade total".

---

## 4. Alternativas Rejeitadas

| Alternativa | Por que rejeitada |
|---|---|
| **Apenas Timeout global** | Insuficiente: aguarda o tempo completo antes de falhar. Com 10s × 100 usuários simultâneos, o pool de threads esgota em segundos de sobrecarga |
| **Retry em todas as chamadas** | O Retry é seguro apenas em operações idempotentes (GET). Recomendações do Learning Engine podem ter side-effects de atualização de estado — Retry cego geraria inconsistências |
| **Sem Fallback (Circuit Breaker que apenas rejeita)** | Degradação abrupta: o aluno vê uma tela de erro em vez de uma experiência degradada mas funcional. UX inaceitável para uma plataforma de educação |
| **Istio Service Mesh** | Mais poderoso, mas adiciona complexidade operacional desproporcional para uma equipe de 4 pessoas na fase atual. O Kong com plugins nativos resolve os requisitos sem overhead de mesh |

---

## 5. Consequências

**Positivas (+):**
- Sistema degrada graciosamente: a falha do Learning Engine não derruba Login ou visualização de conteúdo;
- Alunos recebem conteúdo popular em vez de erro — experiência mantida com qualidade reduzida;
- Timeout global no Gateway elimina chamadas de rede infinitas;
- Rate limiting protege o backend de clientes mal-comportados ou ataques volumétricos.

**Negativas (-):**
- **Complexidade adicional:** o time precisa monitorar os estados do Circuit Breaker (CloudWatch + alertas para quando entra em ABERTO);
- **Fallback pode estar desatualizado:** o cache de "conteúdo popular" no Redis é atualizado a cada hora — em um pico prolonged, o aluno pode ver recomendações genéricas por horas;
- **Tuning dos thresholds:** os parâmetros do Circuit Breaker (50% de falha, janela de 10 requisições, timeout de 30s) precisam ser calibrados com dados reais de produção — valores iniciais são estimativas.

---

## 6. Referências

- Nygard, M. T. (2018). *Release It! Design and Deploy Production-Ready Software* (2ª ed.). Pragmatic Bookshelf.
- Fowler, M.; Lewis, J. (2014). *Microservices*. martinfowler.com. Disponível em: https://martinfowler.com/articles/microservices.html
- Microsoft Azure Architecture Center. (2024). *Circuit Breaker pattern*. Disponível em: https://learn.microsoft.com/azure/architecture/patterns/circuit-breaker
- Microsoft Azure Architecture Center. (2024). *Bulkhead pattern*. Disponível em: https://learn.microsoft.com/azure/architecture/patterns/bulkhead
- Pressman, R. S.; Maxim, B. R. (2021). *Engenharia de Software: Uma Abordagem Profissional* (8ª ed.). McGraw-Hill.
