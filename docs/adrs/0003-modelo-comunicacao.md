# ADR 0003 — Modelo de Comunicação entre Microsserviços

**Status:** Aceito  
**Data:** 2026-06-01  
**Contexto do Projeto:** EduVerse — Plataforma de Aprendizado Adaptativo com IA  
**Fase:** Ciclo 3 — Cloud e Microsserviços

---

## 1. Contexto

Com sete microsserviços independentes (Auth, Content, Learning Engine, Notification, Analytics, API Gateway, Frontend), a pergunta fundamental é: **como esses serviços se comunicam entre si?**

Duas famílias de abordagem existem:

- **Síncrona:** o chamador envia uma requisição e *espera* a resposta antes de continuar (REST, gRPC);
- **Assíncrona:** o chamador publica um evento ou mensagem em uma fila e *não espera* — o consumidor processa quando puder (Kafka, RabbitMQ, Amazon SQS).

No EduVerse, nem todos os fluxos têm os mesmos requisitos. Identificamos dois perfis distintos:

**Perfil A — Operações de leitura com retorno imediato necessário para UX:**
- Aluno faz login → precisa do token JWT *agora*
- Aluno abre um módulo → precisa do conteúdo *agora*
- Aluno recebe recomendações → precisa da lista *agora* (tolerância de até 2s)

**Perfil B — Operações de escrita que podem ser processadas em background:**
- Aluno termina um exercício → seu progresso precisa ser salvo, mas não é crítico que aconteça em milissegundos
- Sistema precisa notificar o aluno sobre nova trilha → notificação pode chegar em segundos, não precisa de resposta síncrona
- Sistema precisa atualizar métricas de analytics → consolidação pode ser eventual

Usar comunicação 100% síncrona para o Perfil B cria acoplamento temporal desnecessário e risco de cascata de falhas (→ ADR 0002).  
Usar comunicação 100% assíncrona para o Perfil A inviabiliza a UX — o aluno não pode esperar uma fila processar para fazer login.

---

## 2. Decisão

**Adotamos um modelo de comunicação híbrido: REST síncrono para operações do Perfil A (leitura e UX crítica) + mensageria assíncrona via Amazon SQS para operações do Perfil B (escrita e processamento em background).**

### Fluxos Síncronos (REST via API Gateway)

| Fluxo | Origem → Destino | Protocolo |
|---|---|---|
| Login / refresh token | Frontend → API Gateway → Auth Service | REST/JSON + HTTPS |
| Listar conteúdo de um módulo | Frontend → API Gateway → Content Service | REST/JSON + HTTPS |
| Buscar recomendações personalizadas | Frontend → API Gateway → Learning Engine | REST/JSON + HTTPS |
| Dashboard do admin (métricas pré-agregadas) | Frontend → API Gateway → Analytics Service | REST/JSON + HTTPS |

**Por que REST e não gRPC?** O gRPC oferece performance superior (Protobuf binário vs. JSON), mas exige que o Frontend suporte HTTP/2 e que o time domine o schema Protobuf. Dado o perfil da equipe (React + Python/Django), REST/JSON reduz a curva de aprendizado sem sacrifício de performance significativo para os volumes atuais (< 10.000 usuários simultâneos).

### Fluxos Assíncronos (Amazon SQS FIFO)

Três filas independentes (Bulkhead de filas — falha em uma não afeta as outras):

| Fila | Produtor | Consumidor | Evento |
|---|---|---|---|
| `eduverse-progress-events.fifo` | API Gateway (ao receber POST de progresso) | Analytics Service | `{ userId, contentId, score, completedAt }` |
| `eduverse-notification-events.fifo` | Learning Engine (ao gerar nova recomendação) | Notification Service | `{ userId, type, message, channel }` |
| `eduverse-analytics-events.fifo` | Content Service (ao publicar novo conteúdo) | Analytics Service | `{ contentId, action, timestamp }` |

**Padrão de resposta para o cliente nos fluxos assíncronos:**
```
POST /api/progress
→ API Gateway publica na fila progress-events
← HTTP 202 Accepted { "message": "Progresso registrado. Será consolidado em instantes." }
```

O aluno recebe resposta imediata (HTTP 202) confirmando que a ação foi recebida. O Analytics Service processa e consolida o dado em background. A consistência é **eventual** — o dashboard do professor pode levar até 5 segundos para refletir o progresso do aluno, o que é aceitável para o caso de uso.

**Idempotência nas filas:** O SQS FIFO usa `MessageDeduplicationId` (hash do conteúdo da mensagem) para garantir que a mesma mensagem não seja processada duas vezes. Isso é crítico porque o produtor pode publicar o mesmo evento duas vezes em caso de retry de rede.

---

## 3. Justificativa Teórica

### 3.1 Por que não comunicação 100% síncrona?

A comunicação síncrona cria **acoplamento temporal**: ambos os serviços precisam estar disponíveis no mesmo instante para que a operação tenha sucesso. Em um sistema com sete serviços, a probabilidade de que *todos* estejam disponíveis simultaneamente diminui com o número de dependências síncronas.

Se o Analytics Service ficar indisponível durante um período de pico:
- Com comunicação 100% síncrona: o aluno não consegue submeter respostas de exercícios (o POST de progresso falha);
- Com comunicação assíncrona: o aluno submete normalmente (HTTP 202), a mensagem fica na fila e o Analytics processa quando voltar ao ar.

Richardson (2018, *Microservices Patterns*) descreve esse cenário como o problema de "availability reduction" — cada dependência síncrona adicional reduz a disponibilidade geral do sistema multiplicativamente.

### 3.2 Por que não comunicação 100% assíncrona?

A comunicação assíncrona introduz **consistência eventual**: o dado não está imediatamente disponível para leitura após a escrita. Para operações de login ou carregamento de conteúdo, isso é inaceitável:

```
Fluxo problemático com async puro:
Aluno faz login → evento publicado na fila
→ Frontend aguarda o token
→ Auth Service consome da fila (leva 200ms)
→ Token gerado e publicado em outra fila
→ Frontend consome o token da fila
→ Total: 400ms+ apenas para login
```

Além da latência, a complexidade de rastreamento aumenta: cada operação precisaria de um **Correlation ID** para que o Frontend soubesse qual resposta é para qual requisição. Para operações de leitura simples, isso é complexidade desnecessária.

### 3.3 O modelo híbrido como solução de trade-off consciente

O princípio guia é o **Teorema CAP** (Brewer, 2000): em sistemas distribuídos, é impossível garantir simultaneamente Consistência, Disponibilidade e Tolerância a Partições. Em momentos de partição de rede, o sistema deve escolher entre Consistência e Disponibilidade.

O EduVerse faz a escolha consciente:
- **Operações de leitura crítica (login, conteúdo):** priorizamos Consistência — o dado deve ser o mais atualizado possível, e aceitamos que o serviço pode retornar erro se o upstream estiver indisponível;
- **Operações de escrita em background (progresso, notificações, analytics):** priorizamos Disponibilidade — o sistema deve aceitar a operação mesmo que o processamento demore, e aceitamos consistência eventual.

Segundo Richardson (2018), esse padrão é chamado de **CQRS light** (Command Query Responsibility Segregation) — comandos (escritas) são desacoplados via mensageria, queries (leituras) são síncronas.

---

## 4. Alternativas Rejeitadas

| Alternativa | Por que rejeitada |
|---|---|
| **100% REST síncrono** | Acoplamento temporal entre todos os serviços. Falha do Analytics derruba o fluxo de submissão de exercícios. Indisponibilidade acidental de um serviço impacta a experiência do aluno |
| **100% assíncrono com Kafka** | Complexidade operacional desproporcional: Kafka requer cluster ZooKeeper/KRaft, retenção de logs, configuração de partições. Para o volume atual do EduVerse, SQS é suficiente e elimina overhead de operação |
| **gRPC para todos os fluxos síncronos** | Performance superior, mas exige HTTP/2 no browser (limitações de streaming bidirecional em browsers) e Protobuf — curva de aprendizado alta para uma equipe focada em Python/React |
| **GraphQL no API Gateway** | Interessante para queries flexíveis, mas adiciona complexidade ao Gateway (schema, resolvers) que contradiz o princípio de mantê-lo como proxy simples (→ ADR 0002) |
| **RabbitMQ no lugar do SQS** | RabbitMQ exige broker autogerenciado (EC2 ou EKS). SQS é serverless e gerenciado pela AWS, alinhado com a estratégia PaaS da ADR 0001 |

---

## 5. Consequências

**Positivas (+):**
- Desacoplamento temporal para operações de escrita: Notification e Analytics podem ficar indisponíveis sem impactar o fluxo principal do aluno;
- Disponibilidade do sistema não depende da disponibilidade de *todos* os serviços simultaneamente;
- Filas SQS FIFO garantem ordenação e deduplicação de mensagens sem configuração adicional;
- Load leveling natural: picos de submissões de exercícios são absorvidos pela fila sem sobrecarregar o Analytics Service.

**Negativas (-):**
- **Consistência eventual para analytics:** o dashboard do professor pode estar temporariamente desatualizado (atraso de até 5s). Requer comunicação clara na UI ("Dados atualizados a cada 5 segundos");
- **Complexidade de debug:** em fluxos assíncronos, rastrear um problema requer Correlation IDs e observabilidade distribuída (CloudWatch + X-Ray). Sem isso, diagnosticar por que uma notificação não chegou é difícil;
- **Dead Letter Queues:** mensagens que falham repetidamente precisam ser redirecionadas para DLQs e monitoradas. Adiciona operação contínua.

---

## 6. Referências

- Richardson, C. (2018). *Microservices Patterns*. Manning Publications.
- Brewer, E. (2000). *Towards Robust Distributed Systems*. PODC Keynote. University of California, Berkeley.
- Fowler, M. (2011). *CQRS*. martinfowler.com. Disponível em: https://martinfowler.com/bliki/CQRS.html
- Amazon Web Services. (2024). *Amazon SQS FIFO Queues*. Disponível em: https://docs.aws.amazon.com/sqs/
- Pressman, R. S.; Maxim, B. R. (2021). *Engenharia de Software: Uma Abordagem Profissional* (8ª ed.). McGraw-Hill.
