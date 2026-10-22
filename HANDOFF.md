# Continuidade do QCY Control

Leia `AGENTS.md` antes de qualquer mudança. Este documento resume fatos úteis para uma nova conversa ou conta; os arquivos locais são a fonte principal.

## Objetivo e ambiente

Aplicativo nativo da barra de menus para QCY T13 ANC, macOS Sonoma 14 em Mac Intel, Swift 6.0.3 com Command Line Tools. O usuário prefere mudanças estritamente pontuais e quer preservar ANC, EQ, conexão automática, áudio, bateria e visual já implementados. Projeto independente, sem servidor, sem telemetria e sem modificação de firmware.

## Estado entregue

- Versão atual: **1.5.6, build 27**. Bundle: `outputs/QCY Control.app`; instalação manual: `outputs/QCY-Control-1.5.6.zip`.
- `build.sh` compila `Sources/*.swift`, monta o bundle, define `LSUIElement` e assina ad hoc. Não presuma que `swift build` produz o `.app`.
- `Sources/MenuBarController.swift` gerencia o ícone da barra de menus e popover; `Sources/Views.swift` contém as abas e o cabeçalho; `Sources/QCYControlManager.swift` mantém o canal BLE/RCSP; `Sources/RCSPProtocol.swift` codifica, decodifica e confirma as operações; `Sources/BluetoothManager.swift` lê o estado Bluetooth exposto pelo macOS; `Sources/AudioManager.swift` e `Sources/SoftwareEQManager.swift` tratam do áudio do Mac.
- ANC/Normal/Transparência, modo jogo, toques e EQ interno dependem de respostas reais do protocolo Jieli/RCSP. O usuário relatou ANC e EQ funcionando em uma versão anterior; houve intermitências históricas. Não declare que qualquer versão nova funcionou fisicamente sem teste do usuário.
- A interface de EQ dos fones tem dez bandas fixas de −6 a +6 dB. A seção separada de EQ do Mac, opcional, processa o áudio com dez bandas de −12 a +12 dB e ganho geral até +6 dB. Não confunda as duas rotas.
- A versão 1.5.5 passou a consultar bateria esquerda/direita/estojo pelo atributo RCSP ADV 0. Na 1.5.6, byte `00` do estojo sem sinal de carga aparece como `—`, por ser ambíguo. O diagnóstico registra os bytes brutos; a leitura específica do hardware do usuário ainda precisa ser conferida.
- O estado conectado colore o ícone da barra de menus de verde usando a paleta nativa do SF Symbol. Desconectado usa a cor adaptativa do sistema. As três abas têm área clicável em todo o botão.

## Evidência e limites

`PROTOCOL.md` explica o transporte RCSP, as restrições dos comandos e a origem dos dados. `outputs/PERFIL-T13-ANC.json` guarda o perfil de produto; `outputs/ANALISE-APK.md` e `outputs/INVESTIGACAO-1.2.8.md` registram a investigação. As fontes de engenharia reversa maiores em `work/` são material de pesquisa, não arquivos necessários para compilar. Os diagnósticos do usuário e a resposta real dos fones prevalecem sobre hipóteses.

O bundle 1.5.6 compilou para x86_64/macOS 14, passou em 117 verificações offline, `codesign --verify --strict` e `plutil -lint`. Isso não prova bateria/ANC/EQ em tempo real; solicite diagnóstico ou confirmação do usuário quando a mudança depender do hardware.

## Como continuar em outra conta

Abra esta pasta como projeto local no Codex da outra conta (ou copie o pacote `outputs/QCY-Control-projeto-1.5.6.zip` para outro Mac e extraia). Inicie uma nova conversa com: “Continue o QCY Control. Leia AGENTS.md e HANDOFF.md; faça somente a alteração que eu pedir, preserve as funções atuais e compile/teste antes de entregar.” O histórico desta conversa não é transferido automaticamente. Um link de compartilhamento do chat pode servir como contexto de leitura, mas não substitui os arquivos locais.
