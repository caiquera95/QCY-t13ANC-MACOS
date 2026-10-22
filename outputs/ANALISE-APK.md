# Análise estática do XAPK fornecido

Revisão 1.2.7: confirmado o caminho UpdateSysInfo opcode 9 → parseAttrMessage → onEqChange, antes descartado no cliente Swift. Implementada leitura de eventos válidos quando ocioso e registro durante operações, sem escrita automática. Isso não comprova resolução de ANC/EQ. Detalhes e evidências em INVESTIGACAO-1.2.7.md.

Atualização posterior: o transporte identificado foi implementado na versão 1.2.0. Consulte PROTOCOLO.md e VALIDACAO.md nesta pasta para o estado atual; os limites abaixo descrevem a etapa de análise anterior à implementação.

Arquivo: QCY+Audio_1.2.1_APKPure.xapk. Nenhum aplicativo Android foi instalado ou executado. Não houve comunicação com os fones.

O manifesto do contêiner identifica QCY Audio 1.2.1 (121), pacote com.qcy.audio.google. O APK base tem SHA-256 36ec5c46716e2c637e3f8f9468b923e0096074c8dbaf24ede9b30530089edcaa. O nome do pacote e as bibliotecas são evidências do conteúdo; não foi validada a assinatura contra uma cópia obtida diretamente do fabricante. Este app Android não é automaticamente equivalente ao app iOS enviado antes.

## Descobertas verificadas no bytecode DEX

1. QCYDeviceManager.<clinit> associa UUID_JL_SERVICE a A002, UUID_JL_WRITE a 00000001 e UUID_JL_NOTIFICATION a 00000002, todos na base 0000xxxx-0000-1000-8000-00805f9b34fb. Associa separadamente UUID_QCY_SERVICE a A001.
2. QCYDeviceManager$mBleCallback$1.onConnectionChanged escolhe JLDeviceImpl para dispositivos classificados como JL e QCYDeviceImpl para a outra família.
3. QCYDeviceBean.refreshInfoFromAVData lê modelID dos dois primeiros bytes do manufacturer payload (depois do identificador da empresa), em big endian. isJLDevice testa (modelID & 0xF0) == 0x70 ou modelID == 0x0200. isNewJL testa (modelID & 0x8070) == 0x8070.
4. O produto 18290 (0x4772) registrado no diagnóstico do usuário satisfaz isJLDevice e não satisfaz isNewJL. Isso é uma inferência baseada no identificador reportado, sem teste físico desta implementação.
5. JLDeviceImpl estende com.jieli.jl_bt_rcsp.impl.BtRcspOpImpl. Trata-se de uma implementação RCSP, com consultas, respostas e números de sequência; não de simples substituição de UUID no perfil A001.
6. ParseHelper.packSendBasePacket constrói moldura FE DC BA, flags, opcode, comprimento de 2 bytes, parâmetros e terminador EF. Flags incluem tipo de pacote e solicitação de resposta. Parâmetros incluem sequência e, em respostas, status. A forma exata depende da classe do comando.
7. BtRcspOpImpl.handleDeviceConnectedEvent consulta informações com buildGetDeviceInfoCmd(-1), opcode 3/GetTargetInfoCmd, quando ainda não há DeviceInfo. O método também atualiza horário; essa alteração não é necessária para nossa investigação e não deve ser portada automaticamente.
8. No caminho JL antigo, JLDeviceImpl.setGameMode utiliza modifyAdvInfo(5, payload), com valor 2 para ativar e 1 para desativar. No novo JL usa comando customizado 9, comprimento 1, valor 1/2. Os valores não são intercambiáveis sem selecionar o perfil correto.
9. JLDeviceImpl.setNoiseMode consulta getCurrentNoiseMode quando necessário e depois usa setCurrentNoiseMode com estrutura NoiseMode e ganho. Não corresponde a uma escrita direta AA 02 01 xx.
10. JLDeviceImpl.readEQGainInfo e setters de EQ, além de setButtonFunc, estão presentes. Encontrar métodos genéricos não comprova suporte a todos eles no T13 ANC nem determina sozinho as frequências, limites ou capacidades disponíveis.
11. QCYDeviceImpl$Companion.getSendData, do perfil A001, adiciona FF e comprimento antes do corpo. É outro enquadramento, diferente do RCSP de A002.

## Consequências para QCY Control

Existe agora evidência concreta para investigar A002 como transporte Jieli/RCSP no dispositivo identificado. A versão 1.1.4 ainda mantém A002 em inspeção, portanto não implementa esse transporte. As buscas por outro A001 não resolvem essa diferença de protocolo.

A hipótese anterior AA 01 00 para hello e AA/opcode/length/value para controles não foi confirmada pelos caminhos rastreados neste arquivo. Não enviar esses bytes como tentativa de autenticação.

A próxima implementação precisa separar o transporte RCSP, reconstituir pacotes fragmentados, correlacionar sequência/status e consultar identidade/capacidades antes de habilitar configurações. Deve começar por consulta de informações, com prazo limitado, sem sincronizar horário, resetar, atualizar firmware ou escrever configurações. Os comandos de mudança só podem ser habilitados depois de respostas compatíveis do fone real.

## Limites

Esta entrega é uma análise estática, não uma correção funcional já validada. Nenhuma nova versão .app foi produzida nesta etapa. Não foi comprovado no hardware que o T13 ANC firmware 2.4.0 aceita o RCSP examinado, nem concluído o levantamento de inicialização/autenticação ou de todos os comandos e respostas. A correspondência de UUIDs e a classificação do modelo são evidência forte para a investigação, mas não substituem teste.

Reprodução local: work/apk-analysis/dump.py e dump-jl.py inspecionam DEX com Androguard; resultados locais em work/apk-analysis/disassembly. Não redistribuir o APK ou o código desassemblado junto ao aplicativo. Não foi instalado Java, Android Studio ou servidor. Dependências de análise ficaram no ambiente virtual isolado work/apk-analysis/venv.
