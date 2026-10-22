# Instruções de manutenção — QCY Control

Este arquivo acompanha o projeto para que outra conta ou conversa Codex continue o trabalho com as mesmas prioridades. A solicitação explícita e atual do usuário sempre prevalece.

## Prioridade central

- Faça somente a alteração pontual pedida pelo usuário. Preserve aparência, fluxos e funções já operacionais. Não aproveite uma tarefa para redesenhar telas, refatorar módulos, trocar dependências ou mudar comandos Bluetooth.
- Antes de editar, leia `HANDOFF.md`, `README.md` e as partes relevantes de `PROTOCOL.md`. Inspecione os arquivos diretamente afetados e verifique o estado atual do bundle.
- Mantenha AppKit/SwiftUI/CoreBluetooth/CoreAudio, Swift 6, Intel x86_64 e macOS 14. Não introduza Electron, WebView, servidor permanente ou ferramentas pesadas sem pedido explícito.
- Não envie comandos proprietários especulativos, não altere firmware/pareamento nem trate ACK GATT como confirmação de estado. Preserve os limites e as confirmações de leitura descritos em `PROTOCOL.md`.
- Não invente dados de bateria, ANC, EQ ou conexão. Um valor ausente ou ambíguo deve permanecer não confirmado. Separe o volume/áudio do Mac dos ajustes internos dos fones.

## Trabalho e validação

1. Entenda o comportamento atual e o pedido específico. Registre uma hipótese curta quando houver defeito.
2. Edite o menor conjunto de arquivos necessário. Não substitua implementações que o usuário já confirmou como funcionais sem evidência de regressão e motivo claro.
3. Para mudanças de código, rode `./build.sh`, `outputs/QCY Control.app/Contents/MacOS/QCYControl --self-test`, `--responsiveness-test`, `plutil -lint` no Info.plist e `codesign --verify --strict` no `.app`. Teste visualmente ou no hardware quando houver acesso; diferencie claramente testes offline de confirmação nos fones reais.
4. Atualize versão/build e pacote de instalação quando entregar um novo aplicativo. Mantenha README e notas da versão coerentes. Não altere versões antigas já distribuídas.
5. Relate o que mudou, a evidência de validação e qualquer limite ainda não confirmado. Forneça o caminho exato do `.app` e do ZIP.

Se uma falha exigir mudar o protocolo, primeiro consulte os diagnósticos do usuário e o material de engenharia reversa deste projeto. Não tente sequências alternativas nos fones por adivinhação.
