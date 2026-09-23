# Jev opcional para roteamento no DSH

Este plugin Cordis usa uma pergunta `choice` da API TypeSafe para escolher uma
combinação **já permitida** de provedor, modelo e esforço. O DSH continua
executando o LLM e suas ferramentas. O plugin não registra ferramentas, não
decide permissões e não usa o Jev como modelo de chat.

## Ativação

O padrão é desligado. São necessários `enabled: true` no overlay do perfil,
uma `autoRoute` explícita e `TYPESAFE_API_KEY` do próprio usuário no ambiente
do processo `dsh`.
O app público deve obter a chave do Keychain do usuário e passá-la apenas ao
processo filho; jamais embuti-la no bundle ou gravá-la em YAML.

Exemplo de camada para `dsh --profile web --patch /caminho/jev.patch.yml`:

```yaml
- insert:
    - id: jev-route-selector
      name: '/caminho/absoluto/Integrations/Jev/router.mjs'
      config:
        enabled: true
        minConfidence: 0.65
        timeoutMs: 2500
        autoRoute:
          provider: meu-provedor
          model: meu-modelo-rapido
          reasoningEffort: low
        routes:
          - provider: meu-provedor
            model: meu-modelo-rapido
            efforts: [low, medium]
          - provider: meu-provedor
            model: meu-modelo-profundo
            efforts: [high, xhigh]
```

Configure apenas IDs de provedores/modelos/esforços que o DSH desse usuário
aceita. `autoRoute` deve corresponder exatamente à rota base usada quando o
seletor estiver em Auto; outra rota passa direto, sem chamada ao Jev. Como a
API do evento não distingue uma seleção manual idêntica à rota base, o app
precisa sincronizar o seletor Auto com essa convenção antes de ativar o plugin.
A camada não instala nem autentica provedores. Com Jev desligado, sem chave,
sem `autoRoute`, com menos de duas combinações, erro de rede, resposta inválida ou
confiança abaixo do limite, o resultado de `agent/request` permanece o do DSH.
O Jev também pode escolher `keep_current` quando nenhuma rota da lista for adequada.

Quando ativo, o plugin envia até 2.048 caracteres do último texto aceito na
etapa ao serviço TypeSafe. É uma transferência explícita a um serviço externo;
o app deve informar isso antes de ativar. O plugin não grava esse texto,
respostas nem a chave em logs. As combinações são declaradas em configuração,
e uma resposta fora da lista é ignorada.

`agent/request` só controla a configuração da chamada ao LLM. Aprovação,
sandbox e permissões permanecem nos mecanismos determinísticos do DSH. Como
outros listeners de `agent/request` podem escolher modelo também, valide a
ordem do overlay no perfil final e confira o `request/header` persistido em um
teste E2E. O overlay não é instalado em perfis reais por estes arquivos.

## Verificação local

```sh
node --test Integrations/Jev/router.test.mjs
node Integrations/Jev/loader-smoke.mjs
```

O primeiro comando simula o evento Cordis e uma resposta Jev sintética para
comprovar rota/esforço e fallback. O segundo inicia um perfil Web isolado com
overlay e chave sintética, confirma que o servidor sobe e o encerra. Ele não
envia prompt nem comprova uma inferência completa pela Web UI. Um E2E de
produto ainda precisa abrir uma sessão sintética e verificar `request/header`
após a escolha, sem usar credenciais do proprietário.
