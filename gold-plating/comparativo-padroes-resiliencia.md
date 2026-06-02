# Gold Plating — Comparativo Aprofundado: Padrões de Resiliência em Contexto Real

> Este documento complementa a ADR 0002, explorando como os padrões de resiliência se comportam em cenários de falha reais documentados pela indústria.

---

## Análise de Incidentes Reais

### Netflix — Cascata de Falhas sem Circuit Breaker (2012)

Em agosto de 2012, a AWS teve uma falha na região us-east-1 que cascateou para o Netflix. Antes da adoção massiva do Hystrix (sua implementação de Circuit Breaker), serviços de recomendação lentos bloqueavam threads de streaming, derrubando o serviço principal.

**Lição aplicada ao EduVerse:** O Learning Engine é o serviço com maior risco de cascata — exatamente como o serviço de recomendação do Netflix. O Circuit Breaker com fallback para conteúdo popular replica a solução da Netflix.

**Fonte:** Netflix Tech Blog — *Fault Tolerance in a High Volume, Distributed System* (2012)

---

## Tabela Comparativa de Trade-offs

| Padrão | Quando usar | Custo de implementação | Custo operacional | Risco principal |
|---|---|---|---|---|
| **Timeout** | Sempre — nunca fazer chamada sem timeout | Mínimo | Mínimo | Timeout muito curto rejeita requisições válidas |
| **Retry** | Falhas transitórias em operações idempotentes | Baixo | Baixo | Retry em operação não-idempotente = duplicata |
| **Circuit Breaker** | Serviços com alta variação de latência | Médio | Médio (monitorar estados) | Threshold mal calibrado abre CB prematuramente |
| **Bulkhead** | Múltiplos serviços compartilhando pool de recursos | Médio | Baixo | Pool subdimensionado = recurso sempre esgotado |
| **Rate Limiting** | Proteção contra abuso ou pico inesperado | Baixo | Baixo | Limite muito restritivo bloqueia usuários legítimos |

---

## Sequência de Ativação dos Padrões no EduVerse

```
Requisição do aluno para /api/recommendations
        │
        ▼
[Rate Limiting - Kong]
  → Mais de 60 req/min por usuário? → HTTP 429 Too Many Requests
        │ (passou)
        ▼
[Timeout global - Kong]
  → Timeout de 10s iniciado
        │
        ▼
[Circuit Breaker - verificação]
  → CB está ABERTO? → Retorna fallback (popular content cache) imediatamente
        │ (CB FECHADO)
        ▼
[Bulkhead - pool-learning]
  → Pool de 20 threads do Learning Engine disponível?
        │ (thread disponível)
        ▼
[Chamada ao Learning Engine]
  → Responde em < 10s? → Sucesso
  → Não responde em 10s? → Timeout, registra falha no CB
    → CB atinge 50% de falhas? → Abre CB → próximas chamadas vão para fallback
```

---

## Configuração Recomendada para EduVerse (Kong + Resilience4j)

```yaml
# Kong Plugin - Circuit Breaker (via plugin personalizado)
circuit_breaker:
  failure_threshold: 50          # 50% de falhas na janela
  window_size: 10                # janela de 10 requisições
  open_duration: 30              # CB fica aberto por 30s
  half_open_max_requests: 1      # 1 requisição de teste no MEIO-ABERTO

# Kong Plugin - Timeout
upstream_connect_timeout: 3000   # 3s para conectar
upstream_read_timeout: 10000     # 10s para receber resposta
upstream_send_timeout: 3000      # 3s para enviar requisição

# Kong Plugin - Rate Limiting
rate_limiting:
  minute: 60                     # 60 req/min por consumer
  policy: local                  # ou redis para multi-node
```

---

## Métricas a Monitorar (CloudWatch)

| Métrica | Alerta | Ação |
|---|---|---|
| `CircuitBreaker.State` (0=FECHADO, 1=ABERTO) | ABERTO por > 5 min | Investigar Learning Engine |
| `SQS.ApproximateNumberOfMessagesVisible` | > 500 mensagens | Analytics ou Notification Service lento |
| `ECS.CPUUtilization` (Learning Engine) | > 80% por > 2 min | Auto Scaling pode estar atrasado |
| `RDS.ReadLatency` | > 100ms | Otimizar queries ou adicionar read replica |

---

## Referências Complementares

- Netflix Tech Blog. (2012). *Fault Tolerance in a High Volume, Distributed System*.
- Nygard, M. T. (2018). *Release It!* (2ª ed.). Cap. 5: Stability Patterns. Pragmatic Bookshelf.
- Microsoft Azure Architecture Center. (2024). *Retry pattern* e *Circuit Breaker pattern*.
- Richardson, C. (2018). *Microservices Patterns*. Cap. 3: Inter-process communication. Manning.
