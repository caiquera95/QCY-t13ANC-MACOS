# Investigação do APK — 19/10/2026

Análise estática local do APK fornecido, sem instalação, execução Android ou envio de comandos aos fones. O APK QCY Audio 1.2.1 não foi demonstrado equivalente à versão iOS que funciona no aparelho do usuário.

## Resultado verificável

O caminho legado JL usa `JLDeviceImpl.setNoiseMode` → `setNoiseMode$performSet` → `BtRcspOpImpl.setCurrentNoiseMode` → `modifyAdvInfo(11, NoiseMode.toData())`. A estrutura inclui modo, comprimento e três ganhos UInt16. O setter usa a faixa retornada pelo dispositivo e uma porcentagem. O formato implementado já corresponde a esse caminho; não apareceu evidência de um hello AA 01 00 que deva ser acrescentado.

O equalizador segue `JLDeviceImpl.setGainEQ` → `configEqInfo` → `CommandBuilder.buildSetEqValueCmd`: função pública FF, atributo 4, modo e dez bytes de ganho. Isso confirma o empacotamento, mas não comprova que o banco 6 seja aplicado por este firmware em todas as situações, nem valida sozinho os nomes/curvas específicos obtidos do catálogo separado.

Uma diferença concreta foi encontrada: `BtRcspOpImpl.handleCommand` trata opcode 9 como UpdateSysInfo e encaminha função e atributos a `RcspDataHandler.parseAttrMessage`. Para função FF e atributo 4, `parsePublicData` dispara `onEqChange`. Nosso cliente descartava todos esses eventos. Os logs físicos anteriores mostram que opcode 9 efetivamente chegou depois de ajustes de EQ.

## Alteração 1.2.7

O cliente agora registra os atributos e os onze bytes de EQ desses eventos válidos. Quando ocioso e identificado, atualiza o estado de EQ por essa leitura espontânea. Durante uma operação, registra o evento para comparação, preserva a solicitação em andamento e exige a consulta de confirmação. Não envia resposta, comando de configuração ou autenticação em consequência do evento. Mensagens desconhecidas e funções alheias não alteram o estado. Não implementa reinicialização, OTA, ajuste de horário ou restauração de fábrica.

Isso corrige uma lacuna de sincronização e de diagnóstico. Não demonstra a resolução do ANC ou da aplicação de EQ. O ANC continua sem causa conclusiva: os registros recebidos mostram SetADV aceito e leituras devolvendo 41 (ANC) após pedir Normal. Não há evidência de queda do canal nesse trecho. Modo jogo foi confirmado por leitura na mesma sessão.

## Evidências locais reproduzíveis

- `work/apk-analysis/trace-controls.py` e `control-callers.txt`: chamadas relacionadas aos setters encontradas nos DEX.
- `work/apk-analysis/disassembly/com/qcymall/qcydevicelibrary/jldevice/JLDeviceImpl.txt`: setters e seleção do caminho legado.
- `work/apk-analysis/disassembly/com/jieli/jl_bt_rcsp/impl/BtRcspOpImpl.txt`: handleCommand, configuração de EQ e ANC.
- `work/apk-analysis/disassembly/com/jieli/jl_bt_rcsp/data/cmdHandler/SysInfoCmdHandler.txt`: formato de UpdateSysInfo.
- `work/apk-analysis/disassembly/com/jieli/jl_bt_rcsp/tool/RcspDataHandler.txt`: encaminhamento de atributos públicos e onEqChange.
- `work/apk-analysis/disassembly/com/jieli/jl_bt_rcsp/util/CommandBuilder.txt`: construção das escritas.

A assinatura do APK não foi comparada a uma distribuição direta do fabricante. Conteúdo analisado não equivale a uma API oficialmente documentada.
