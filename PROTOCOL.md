> Estado atual: a 1.2.8 substitui a escrita EQ com seletor 06 por FF e troca ANC com registro novo de modo, conforme QCY internacional 4.0.7. Os relatos abaixo são históricos; detalhes e limites em INVESTIGACAO-1.2.8.md na pasta outputs.

# Protocolo de controle — versão 1.1.4

Implementação Swift independente, sem bibliotecas externas. Referências de engenharia reversa, não uma API oficial publicada pela QCY:

- [Quicky: documentação do protocolo](https://github.com/hui1601/Quicky/blob/main/docs/protocol.md)
- [Quicky: características GATT](https://github.com/hui1601/Quicky/blob/main/docs/service.md)
- [Quicky: base de produtos](https://github.com/hui1601/Quicky/blob/main/internal/product/products.json)
- [OpenQCY: comandos e seleção de preset](https://github.com/GiorgioRafael/OpenQCY-Desktop/blob/main/Protocol/QcyCommands.cs)

A base de modelos associa T13 ANC ao vendorId 18290, EQ legado de dez bandas com seis predefinições e modo jogo. A referência de GATT foi observada principalmente em outro modelo (HT07). Isso não demonstra que todo comando funcione no T13 ANC 2.4.0. A entrada desse modelo não lista explicitamente os modos ANC; a aplicação exige uma resposta compatível à consulta de modo antes de permitir escrita.

## Identificação e conexão

O usuário inicia uma varredura BLE de até 15 segundos. Sem MAC fixo. O filtro usa fabricante QCY 0x521C e produto 18290, ou nome exato QCY-T13 ANC / QCY-T13 ANC APP quando não há ID de produto. Um ID de outro produto é rejeitado mesmo com nome correspondente. Não aceita T13 ANC2 por aproximação de nome. O usuário seleciona um candidato; não há conexão a periféricos genéricos.

A conexão enumera os serviços primários para diagnóstico; apenas se A001 for encontrado solicita as características conhecidas: comando 1001, notificações 1002, versão 00000007 e EQ 0000000B. A versão precisa ser lida como 2.4.0 antes de qualquer comando de consulta proprietário ou escrita de configuração. Se ambos os lados forem informados, precisam coincidir. Outros firmwares ficam bloqueados.

## Recursos implementados

- ANC legado: consulta 0xFE/0x0C, resposta com exatamente um byte reconhecido (0 = Normal, 1 = ANC, 3 = Transparência). Valor 2 e respostas avançadas são rejeitados; não tenta adaptar comandos de outros modelos.
- Modo jogo: consulta 0xFE/0x09, resposta com um byte (1 = ligado, 2 = desligado). Estado ausente, inválido ou não respondido mantém o controle desabilitado.
- EQ: leitura direta da característica 0000000B, com índice 0–5 em formato legado reconhecido (1 ou 11 bytes). A seleção escreve somente o índice da predefinição. Opções conforme base T13 ANC: Padrão, Pop, Graves, Rock, Suave e Clássico. Sem curva personalizada ou EQ por software.

Cada controle depende da identificação, versão, propriedades GATT e resposta real da função. Apenas presença de serviço não libera botões. Não existe retorno otimista de sucesso: depois de escrever, o app consulta novamente o valor e só confirma quando ele coincide. Divergência, erro ou ausência de confirmação por seis segundos bloqueia novas alterações até reconectar. A API GATT sem resposta de escrita exige confirmação da aplicação; um envio bem-sucedido sozinho não comprova a alteração física. O protocolo não oferece ID de transação; notificações são correlacionadas por comando e valor após a consulta.

Não há comandos de reset, exclusão de pareamento, firmware, calibração ou escrita exploratória. A versão 1.1 não aplica configurações automaticamente ao iniciar/reconectar. A conexão BLE é independente da saída de áudio: não encerra a conexão Bluetooth Classic do macOS. Se o canal de controle estiver ocupado pelo app do celular ou não for anunciado, será necessário fechar o app QCY e tentar novamente. O app não força a divulgação de outro endereço nem desconecta o áudio para isso.

## Verificação e diagnóstico

`--self-test` inclui 21 verificações de protocolo, além das sete verificações originais. Valida fragmentação, pacotes malformados, múltiplos comandos, identificação exata, firmware e valores desconhecidos.

`--ble-report CAMINHO` realiza varredura e, havendo exatamente um candidato, tenta conexão e consultas somente de leitura. Salva relatório após 60 segundos e encerra. Se houver vários candidatos, não escolhe automaticamente. Não chama setters. O relatório omite UUID de periférico, MAC e nomes de outros dispositivos; contém versão, estado, características e respostas dos comandos permitidos. O comando depende de execução na sessão gráfica com permissão Bluetooth.

Também é possível conectar pela interface e usar Ajustes → Copiar diagnóstico dos controles.

## Isolamento da interface — 1.1.1

CBCentralManager, periféricos, características, callbacks, fila de escrita e prazos compartilham uma fila serial própria. O modelo de interface fica no MainActor e recebe snapshots Sendable, sem acessar propriedades GATT. Ações dos botões são enfileiradas sem espera síncrona. Não houve mudança nos valores de comandos nem ampliação de compatibilidade nesta correção.

## Descoberta e diagnóstico — 1.1.2

Após resposta de descoberta bem-sucedida sem A001, marca o candidato como não apto, encerra apenas a conexão BLE e inicia uma segunda busca de até 15 segundos após 0,8 segundo. Candidatos já rejeitados não são tentados novamente nessa busca. Há no máximo uma segunda busca por tentativa iniciada pelo usuário. Se houver exatamente um candidato novo, ele pode ser consultado automaticamente; vários candidatos exigem seleção. Serviços e erros são registrados sem UUID de periférico ou endereço MAC. A alternativa de conexão e desconexão BLE seguida de nova descoberta consta da documentação comunitária Quicky; não está validada neste T13 ANC.

Falhas de descoberta registram domínio e código do erro; não são tratadas como prova de ausência do serviço. Outros serviços encontrados são apenas listados, sem comandos ou tentativa de adaptar protocolos de outros chipsets. O novo fluxo não habilita ANC, jogo ou EQ por suposição. A coleta completa dos serviços é uma operação de diagnóstico somente de leitura.

## A002 — versão 1.1.3

Evidência: relatório do usuário, produto 18290 e somente o serviço primário A002 na conexão observada. A segunda busca concluiu sem novo candidato. Nenhuma fonte encontrada confirmou o protocolo de comandos do A002 neste modelo. Não é tratado como equivalente ao A001.

No A002, o cliente consulta declarações de características e serviços incluídos, limitando a inspeção a oito UUIDs de serviço. Leituras de valor são restritas aos UUIDs 00000007 e 00000008 previamente documentados pela referência QCY e aos UUIDs padrão 2A24 (modelo), 2A26 (firmware) e 2A19 (bateria), somente se legíveis. Não lê 2A25 (número de série), payloads desconhecidos ou descritores de identificação; não ativa notify/indicate e não realiza escritas nesse perfil. Os UUIDs e propriedades são registrados. Valores permitidos são limitados a 64 bytes no relatório.

A validação de comandos exige explicitamente perfil A001 confirmado, além da identidade e firmware. A002, mesmo com características que tenham os mesmos UUIDs ou versão 2.4.0, permanece somente em inspeção. Se A001 estiver incluído, será descoberto e validado por seu próprio serviço. Cinco novos testes verificam a classificação dos UUIDs curtos, expandidos e de bases diferentes.

## Evidência e caminhos adicionais — 1.1.4

Relatório do usuário: serviço A002, nenhum serviço incluído, característica 0001 com propriedade 4 (writeWithoutResponse) e característica 0002 com propriedade 16 (notify). Não há valores legíveis neste serviço. A001 não foi encontrado nas buscas anteriores. O usuário informa que ANC e EQ funcionam no aplicativo oficial para iPhone; isso não revela qual transporte ou protocolo ele utiliza.

Consultados também QCYpods e HyperEars, cujos arquivos de protocolo examinados descrevem o perfil A001. Não foi identificado um mapeamento de comandos confirmado para A002/0001/0002 neste firmware. Os valores de comandos não foram transplantados para A002.

A consulta pública [retrieveConnectedPeripherals](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/retrieveconnectedperipherals(withservices:)) foi adicionada à busca para localizar A001 já conectado ao sistema. Não depende de anúncios ou endereço MAC fixo; candidatos exigem nome exato e revalidação do perfil. A documentação Apple [WWDC19 Core Bluetooth](https://developer.apple.com/videos/play/wwdc2019/901/) distingue descoberta de conexão Classic e BLE; no SDK instalado, registerForConnectionEvents usa CB_CM_API_AVAILABLE com API_UNAVAILABLE(macos). Nenhuma API indisponível ou privada é invocada. Isso não confirma qual caminho é usado pelo app oficial.

A observação opcional de A002 é somente recepção de payloads: não envia bytes à característica 0001. O botão assina 0002 por `setNotifyValue` (operação GATT padrão que configura notificações), espera até 15 segundos e desativa a assinatura. É permitida apenas após descoberta do par com as propriedades relatadas. Mensagens não são interpretadas como evidência de capacidade e não liberam controles. Dados recebidos ficam no relatório local, limitados a 128 bytes por notificação e 60 linhas. Os bytes ainda não decodificados não têm garantia de anonimização; a captura ocorre somente se o usuário escolher observar.

Esse modo de observação e a recuperação de A001 não foram testados fisicamente nesta sessão. Ausência de notificações não significa ausência de suporte: o protocolo pode exigir uma solicitação ou autenticação ainda desconhecida. Não foram inventados pacotes para provocá-las.

## Resultado físico reportado pelo usuário — 19/10/2026

Na versão 1.1.4, a consulta de A001 já conectado retornou zero periféricos. O serviço A002 expôs somente 0001 (writeWithoutResponse) e 0002 (notify), sem serviços incluídos. A assinatura de 0002 foi aceita; em 15 segundos não houve notificações. Não foi obtido payload para deduzir comandos. Não interpretar isso como prova de incompatibilidade dos fones ou como falha de permissão.

O usuário tem iPhone SE de 2020 com iOS 27 e informa que o app QCY oficial controla ANC/EQ. O próximo dado necessário é o protocolo usado por esse cliente, por documentação ou captura das transações. Nenhum novo pacote de configuração foi construído por suposição. A Apple disponibiliza PacketLogger nos Additional Tools for Xcode e perfil/instruções para logs Bluetooth de iOS: https://developer.apple.com/bluetooth/ e https://developer.apple.com/feedback-assistant/profiles-and-logs/?name=bluetooth . O link atual das instruções de iOS exige login Apple Developer; o conteúdo não foi obtido nesta sessão. A compatibilidade da combinação PacketLogger/iOS 27/macOS Sonoma ainda precisa ser verificada. Não houve download ou instalação de ferramentas ou perfis nesta etapa.

## Jieli/RCSP — versão 1.2.0

Evidência nova: análise estática do XAPK QCY Audio 1.2.1 fornecido pelo usuário. Hash do APK base: 36ec5c46716e2c637e3f8f9468b923e0096074c8dbaf24ede9b30530089edcaa. Origem APKPure; assinatura não comparada com distribuição direta do fabricante. Relatório: outputs/ANALISE-APK.md. Não são distribuídos APK, bytecode ou implementações de terceiros com o aplicativo.

QCYDeviceManager.<clinit> associa A002/0001/0002 a UUID_JL_SERVICE/WRITE/NOTIFICATION. QCYDeviceBean.refreshInfoFromAVData lê modelo big endian; isJLDevice classifica 0x4772 como Jieli e isNewJL retorna falso. A002 agora tem uma exceção explícita à inspeção: somente anúncio do fabricante QCY e produto 18290 podem selecionar a implementação RCSP legada. Reconhecimento apenas por nome não libera essa exceção. Outros produtos A002 permanecem em inspeção.

Implementação independente em RCSPProtocol.swift: FE DC BA, flags (bit 7 comando, bit 6 resposta solicitada), opcode, comprimento big endian de dois bytes, corpo e EF. Comandos têm sequência antes dos parâmetros; respostas têm status e sequência. LTV: comprimento inclui tipo, mas não inclui o próprio byte de comprimento. Baseado nos métodos ParseHelper.packSendBasePacket/parsePacketData/parseTargetInfo/parseADVInfo e AttrBean.getData do bytecode examinado. Somente opcodes/atributos especificados abaixo são produzidos; nenhum hello AA é usado.

Inicialização: assina 0002, aguarda confirmação GATT e envia GetTargetInfo (03, máscara FFFFFFFF e plataforma 00), como BtRcspOpImpl.handleDeviceConnectedEvent. Não porta sua sincronização de horário. Firmware vem do atributo 5 (dois bytes, quatro nibbles exibidos literalmente); não é estimado a partir da versão do System Profiler. Atributo 9 em modo atualização bloqueia configurações. Sem versão válida, nenhum controle é liberado. Não exige a string A001 "2.4.0", pois esse transporte codifica a versão de outra maneira.

Depois de resposta correlacionada bem-sucedida: GetADVInfo C1 máscara 00000824 (ANC 11, modo jogo 5, toques 2) e GetSysInfo 07 função FF máscara 00000010 (EQ atributo 4). Informações do dispositivo que podem conter endereços são descartadas, sem logar valores. Logs de alvo incluem apenas tipos e comprimentos. Logs de estados ANC/jogo contêm somente os campos específicos desses controles. Atualização manual, sem polling permanente.

Configurações exigem resposta válida do respectivo recurso. ANC: SetADVInfo C0, atributo 11, preserva os seis bytes de limites/ganho recebidos e altera somente modo (Normal 0, ANC 1, Transparência 2). Suporta apenas a estrutura de oito bytes com length 0 ou 6 e limites coerentes. Jogo legado: SetADVInfo atributo 5, 2 ativado e 1 desativado, conforme JLDeviceImpl.setGameMode. Toques: atributo 2 com tupla lado/gesto/função; só altera gestos efetivamente retornados, usando ConstantFuncID e changeQCY2JL (sem ação 127, demais códigos preservados). Não cria gestos novos.

EQ: caminho legado buildSetEqValueCmd, opcode 08, função FF, LTV atributo 4 com modo e dez ganhos; conserva os ganhos recebidos. Exposição restrita a modos 0–5, com nomes numéricos porque o mapeamento de nomes/curvas do modelo não foi confirmado. Esse caminho existe na biblioteca; a interface principal do APK também tem EQ paramétrico e parâmetros fornecidos por dados do produto. Não se afirma que os seis modos correspondam às curvas do app oficial. Ajuste paramétrico/customizado não implementado. Leitura apenas para estruturas diferentes, sem reinterpretar ganhos ou frequências desconhecidos.

Há uma solicitação RCSP em andamento por vez, sem repetição automática de escrita. SetADV exige status 0 e resultado 0; SetSysInfo exige status 0. ACK de escrita não é sucesso da configuração: nova consulta deve retornar exatamente o estado solicitado. Resposta divergente, negativa ou timeout em configuração bloqueia novas escritas até reconectar. Timeout de consulta opcional deixa aquele recurso indisponível e avança para a próxima consulta. Pacotes são enviados em fragmentos de até 20 bytes, respeitando o limite CoreBluetooth e canSendWriteWithoutResponse. Fila serial independente da interface.

Não há teste físico aprovado desta implementação. Testes offline usam respostas simuladas e vetores de pacote independentes; isso valida a lógica, não o comportamento do firmware real. Nenhuma configuração foi enviada aos fones durante desenvolvimento nesta etapa. A captura do app oficial ainda pode ser necessária se o firmware exigir etapas adicionais não observadas no caminho analisado.


## ANC compacto e nomes de EQ — versão 1.2.1

Diagnóstico real do usuário após 1.2.0: GetTargetInfo retorna firmware RCSP 0.6.0.0; ANC ADV 11 retorna `02 00` (modo 2, comprimento de ganhos zero), e não oito bytes. O bloqueio era um requisito excessivo do nosso parser. NoiseMode.parseData do APK admite dois bytes quando length=0. NoiseMode.toData serializa modo, length e três valores UInt16 mesmo nessa situação; campos de ganho ausentes têm valor inicial zero. A 1.2.1 aceita leitura compacta de dois bytes (length=0) e escreve os oito bytes seguindo esse serializador, preenchendo os campos ausentes com zero. Continua preservando os parâmetros quando a resposta os fornece. Não tenta pacotes alternativos se houver falha. A nova leitura deve confirmar a alteração; aceitação de escrita não basta.

O mesmo relatório confirma ACK + readback do EQ em modos 1, 4 e 5 e do jogo ligado/desligado. Dez gestos foram consultados; não comprova mudança dos gestos. Não houve teste de ANC na 1.2.0 porque o controle permaneceu desabilitado. A seleção de EQ funciona no nível de estado; não é medição acústica.

Nomes do EQ 0–5: Padrão, Pop, Graves, Rock, Suave e Clássico, usando o registro 18290 de work/reference/internal/product/products.json (referência Quicky, documentada acima). Não se presume a nomenclatura genérica de outros dispositivos Jieli. Essa associação de nomes vem do catálogo do mesmo modelo, não de strings lidas dos fones; a correspondência com o aplicativo iOS deste usuário não foi comparada diretamente. Nenhum novo ganho/frequência é inventado ou enviado ao escolher nomes; os bytes de seleção de modo não mudaram.

Mensagens de confirmação agora identificam o recurso alterado (EQ, jogo, ANC ou toques), evitando que uma confirmação de EQ pareça confirmar também ANC. O diagnóstico usa os nomes de perfil e conserva o identificador RCSP do transporte.

Oito novas verificações cobrem o estado real `02 00`, normal/ANC compactos, geração do formato de escrita segundo o APK, truncamentos, modo desconhecido, habilitação de capacidade e leitura de retorno compacta. Sem teste físico de escrita ANC na 1.2.1 até esta entrega.


## Estabilização e recuperação da sessão — versão 1.2.2

Evidência: relatório real da 1.2.1. EQ 4 e 3 foram confirmados, mas a solicitação de EQ 0 retornou EQ 1. Isso acionava fail e bloqueava todas as funções até reconectar. O relatório não prova se a divergência era transitória ou uma escolha recusada pelo firmware. A captura também retornou ANC `41 06 00 00 40 00 27 AE`, cujo código de modo 0x41 não está mapeado. Não é seguro tratá-lo como 1 por máscara arbitrária.

O APK examinado ignora alguns retornos de ANC/EQ recebidos nos primeiros 500 ms após configuração (JLDeviceImpl$readAllOldAttr$1 e JLDeviceImpl$mBtEventCallback$1). Como tratamento da possível latência de aplicação, a 1.2.2 aguarda 500 ms antes de cada leitura de confirmação, sem bloquear a interface, e repete somente a consulta, no máximo três vezes quando há valor divergente. Cada consulta tem nova sequência; não se repete a escrita. A correspondência do opcode/seq e status continua obrigatória. Se três respostas válidas continuarem diferentes, encerra a operação com aviso, mantém o valor retornado e mantém a sessão utilizável. Não afirma sucesso por ACK ou só por manter a conexão.

Atualizar funções agora pode recuperar erros de operação em sessão cuja identidade/versão já foram confirmadas. Limpa capacidades antigas, consulta ADV e EQ e só restaura capacidades respondidas. Não repete a última configuração, não restabelece Bluetooth clássico e não contorna falha de identificação ou modo atualização. Erros sem resposta/estruturais ainda bloqueiam escritas até essa nova consulta explícita ou reconexão.

A validação de estrutura ANC foi separada da interpretação do código. Estruturas de dois/oito bytes válidas podem permitir selecionar os modos padrão 0/1/2 já documentados, mesmo se o modo atual for desconhecido. O código 41 permanece sem interpretação no estado da interface; o serializador troca apenas o código solicitado e preserva limites/ganho válidos, como NoiseMode.setMode/toData do APK. Se o firmware continuar retornando 41 ao pedir ANC 1, não há confirmação falsa: mantém aviso e os demais controles operacionais. Nenhuma associação 41→ANC foi presumida.

Testes novos simulam retorno antigo seguido de valor correto, divergência persistente após três consultas, ausência de reenvio de configuração, nova ação na mesma sessão, atualização após timeout e rejeição da recuperação sem identidade. A transmissão retardada é agendada na fila BLE e o timeout de resposta começa na submissão. A correção ainda precisa ser validada em uso prolongado no hardware real.

## Correção do perfil específico T13 ANC — versão 1.2.3

Novos diagnósticos provam que o valor ANC 41 persiste mesmo após três consultas e escritas dos códigos genéricos 0/1/2. EQ solicitado 0 retorna 1 repetidamente. A hipótese de atraso não resolve esses dois casos. As interpretações anteriores do estado 02 como Transparência e 41 como desconhecido estavam erradas para este modelo.

Fonte primária obtida nesta investigação: API pública de configuração QCY, POST https://api.watch.qcy.com/product/findControlPanels, formulário modelId=18290 e firmwareVersion=2.4.0, cabeçalhos de idioma/região/app conforme o cliente de referência. Resposta code 200, data.firmwareVersions=2.4.0. Cópia integral local em work/apk-analysis/t13-legacy-panels.json; somente fatos relevantes preservados em outputs/PERFIL-T13-ANC.json. Consulta não autenticada de metadados do produto, sem endereço dos fones ou informações do usuário. O endpoint do APK QCY Audio (qcyaudio.qcy.com/public/findControlPanels) retornou data=null para esse modelo; seu catálogo público atual também não contém esse T13 ANC legado. Não se confunde a presença de uma biblioteca genérica com o perfil do modelo.

O layout QCY tipo 11 especifica ancindex 65 para ANC ON, 3 para Transparency e 2 para ANC OFF. Intensidade progress 100, 100 e 0, respectivamente. Assim, 41 hexadecimal é ANC ligado, sem mascarar bits. NoiseMode.toData e o interpolador de JLDeviceImpl.setNoiseMode$performSet do APK determinam a escrita: conserva length/min/max e calcula ganho como min ou max para progress 0/100. Quando não há ganho informado, conserva length zero e os campos ausentes são zero, como o serializador examinado. Leitura reconhece os três códigos oficiais em estruturas compactas ou completas. Essa evidência substitui as hipóteses genéricas das versões anteriores.

O layout QCY tipo 2 fornece seis curvas de dez ganhos, de -6 a +6 dB, nos índices de banda declarados 31,62,125,250,500,1k,2k,4k,8k,16k. Os nomes e curvas estão no perfil JSON. A API não afirma que o índice dessas curvas equivale ao banco genérico RCSP. Esse erro estava na nossa implementação.

Fonte primária Jieli: https://doc.zh-jieli.com/Apps/Android/jielihome/zh-cn/master/development/function/eq_ctrl.html, seções 5.2/5.2.2. Formato legado fixo: modo (1 byte) e dez ganhos. Modo 6 é customizado; 0–5 são Standard/Rock/Pop/Classical/Jazz/Country. Esse enquadramento corresponde ao buildSetEqValueCmd encontrado no APK. A 1.2.3 envia modo 6 com os dez ganhos da curva QCY escolhida, codificados como Int8, em SetSysInfo função FF atributo 4. Não utiliza o formato dinâmico, que não foi observado no dispositivo. Não repete automaticamente a escrita em caso de recusa.

O estado de perfil é identificado pela comparação exata dos dez ganhos com as curvas oficiais, sem depender da numeração genérica. Um perfil não reconhecido é exibido como Perfil atual dos fones e não recebe nome arbitrário. Confirmação verifica a curva completa, não somente modo ou ACK. Presets QCY 0–5 são índices de interface, não códigos de banco transmitidos.

A obtenção de documentação e metadados confirma a base do protocolo, não o teste físico desta implementação. Testes simulados não medem resposta acústica. O app continua sem consultas de rede em execução, comandos de firmware ou configuração automática ao conectar.


## Conexão automática e exportação — versão 1.2.4

Solicitação do usuário: evitar varredura/conexão manual repetida e salvar logs em arquivo. Implementado início automático depois de montar a interface, recuperação de UUID CoreBluetooth salvo somente após infoConfirmed RCSP, validação de serviço e resposta a cada conexão, e busca inicial limitada com conexão somente por produto QCY 18290. Não há MAC fixo. Reconexões após queda inesperada limitadas a três, intervalos de 5/10/15 s. Desconexão explícita cancela a reconexão. Configurações não são repetidas ao reconectar. Falha de estabelecimento tem prazo de 18 s. Chamadas permanecem na fila BLE.

Exportação pelo NSSavePanel escolhe arquivo .txt e gera snapshot atual na fila BLE antes da gravação atômica. Até 2000 linhas com ISO8601 UTC em memória, desde o início da execução. Sem logs permanentes no disco, até a escolha do usuário. Não coleta arquivos privados nem sysdiagnose. UUID lembrado permanece nas preferências locais e não é incluído no relatório. Erro antigo é limpo na desconexão explícita e na conexão seguinte.

Sem teste físico confirmado de reconexão automática ou do diálogo de exportação nesta sessão; compilação, testes de protocolo e isolamento continuam sendo verificados separadamente. O protocolo ANC/EQ não mudou nesta versão: novos logs devem orientar a próxima correção de comportamento real.


## Acionamento automático — 1.2.5

Corrigidas lacunas de conexão: busca manual agora conecta o candidato automaticamente; abrir o painel e observar transição do estado Bluetooth para conectado solicita conexão se não há sessão/busca pendente. Recuperação pelo UUID lembrado ocorre primeiro; após falha, retry usa varredura em vez de insistir no UUID anterior. Pausa explícita por Desconectar permanece até reconexão solicitada pelo usuário. Não há configurações automáticas. Sem validação física do novo acionamento nesta sessão.


## Evidência da 1.2.5 e diagnóstico 1.2.6

Dois relatórios do usuário confirmaram recuperação automática do periférico às 00:17:23Z e conexão às 00:17:26Z, sem varredura. Jogo foi ativado e lido como 02. ANC solicitado Normal 02 retornou persistentemente 41. EQ Padrão enviado em modo customizado 6 com ganhos zero retornou modo 6 e curva não identificada. O histórico omitira os ganhos recebidos, impedindo comparar transformação, valores antigos ou erro de interpretação. Não concluir que a escrita foi aplicada só por status zero.

A 1.2.6 registra os onze bytes do atributo EQ, os dez ganhos como Int8 e o resultado SetADV/SetSysInfo, somente para solicitações correlacionadas existentes. Nenhum novo comando ou formato experimental foi habilitado. Ainda é necessária evidência de tráfego do cliente oficial ou respostas completas para esclarecer as divergências.

## Equalização de áudio do Mac (1.5.0)

O EQ interno dos T13 ANC continua no caminho RCSP comprovado, com dez ganhos de −6 a +6 dB. Para ganho maior sem inventar comandos Bluetooth, o usuário pode ativar uma rota Core Audio local na aba Som. Ela usa um tap privado restrito à saída selecionada, exclui o processo do QCY Control, agrega tap e saída física no mesmo relógio e aplica dez filtros digitais e um limitador diretamente no callback. Ativar exige permissão de gravação de áudio do sistema no macOS. O processamento para ao desativar, trocar de saída ou encerrar o app. Não altera a saída padrão nem modifica firmware.

## Bateria RCSP (1.5.5)

A consulta GetADVInfo inclui o bit 0, documentado pelo SDK Jieli e pelo APK oficial como os níveis esquerdo, direito e estojo. O atributo 0 contém três bytes; cada um reserva o bit 7 para indicação de carregamento e os sete bits inferiores para 0–100%. Valores acima de 100 e registros ausentes ficam sem exibição. A atualização a cada 120 s consulta apenas esse atributo; não configura o dispositivo. O estado separado ainda precisa ser confirmado em hardware pelo usuário.

## Estojo zero (1.5.6)

O valor bruto 00 no terceiro byte do atributo 0 não confirma, por si, bateria vazia. A interface exibe “—” nesse caso e registra os três bytes de bateria no diagnóstico. Um byte 80 continua representando 0% com flag de carregamento, conforme o parser do SDK.
