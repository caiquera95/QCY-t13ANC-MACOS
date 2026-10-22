# QCY Control 1.5.6

Aplicativo nativo de barra de menus para QCY T13 ANC no macOS Sonoma 14, Intel. Swift 6, AppKit/SwiftUI, CoreAudio e CoreBluetooth. Sem servidor, conta ou telemetria.

## Abrir ou instalar

1. Encerre a versão anterior em Ajustes → Encerrar QCY Control.
2. Abra `outputs/QCY Control.app` com dois cliques.
3. Para instalar, arraste o aplicativo para Aplicativos e substitua a cópia antiga depois de encerrá-la.
4. Mantenha o app QCY do celular fechado se ele estiver ocupando o canal de controle. Autorize Bluetooth quando o macOS solicitar.

A pasta `outputs` está dentro da pasta deste projeto. `QCY-Control-1.5.6.zip` contém o aplicativo para instalação manual. Bundle assinado ad hoc, sem notarização. Não desativa a segurança do Mac.

## Conexão automática

Áudio Bluetooth e controles BLE são canais separados. O aplicativo abre o canal de controle automaticamente. Após reconhecer o fone, salva o identificador CoreBluetooth, sem MAC fixo. Ao iniciar com os fones na caixa, mantém a solicitação de conexão ao dispositivo conhecido no CoreBluetooth, para que o sistema a conclua quando ele voltar. Não exige busca ou clique em Conectar a cada uso, nem faz varredura permanente.

O aplicativo observa a lista de saídas CoreAudio mesmo com o painel fechado. Quando os QCY reaparecem, atualiza o estado Bluetooth e solicita os controles. Quedas inesperadas agendam reconexão; o dispositivo conhecido volta ao modo de espera. Bluetooth desligado/reiniciando recupera a solicitação ao retornar. Uma primeira descoberta ainda pode precisar de busca BLE limitada se não houver dispositivo salvo. Opções manuais e diagnóstico ficam em Opções e diagnóstico. Pausar conexão automática interrompe a tentativa; uma nova chegada dos fones na lista de áudio reativa o comportamento automático.

A identificação de áudio no cabeçalho usa dados do sistema, podendo levar alguns segundos para atualizar. Conexão automática não configura ANC, jogo, toques ou equalizador.

## Equalizador adaptado do QCY MeloBuds

Interface adaptada do projeto https://github.com/uxtigos/qcy-mac (Thiago Oliveira, MIT): grade de predefinições, gráfico em escala logarítmica, curva animada, área preenchida e seleção de pontos. Consulte THIRD-PARTY-NOTICES.md e a cópia da licença dentro do aplicativo.

Perfis: **Original**, **Neutro**, **Graves**, **Vocal**, **Agudos** e **Personalizado**. Original guarda a primeira curva lida nesta sessão; não significa restaurar o padrão de fábrica. Neutro zera os dez ganhos. Os perfis sonoros adaptam as curvas do projeto aos ganhos inteiros do T13 ANC. Os seis perfis QCY anteriores permanecem no menu **Perfis QCY**.

Selecione um perfil para enviá-lo. Em Personalizado, arraste uma bolinha: a alteração é enviada uma vez ao soltar, não durante o movimento. O ícone de ajustes revela seleção de banda e controle de ganho acessível por teclado/VoiceOver. O perfil pessoal é guardado automaticamente no Mac ao concluir a edição; selecionar Personalizado o recupera. **Redefinir** envia uma curva plana. Após o envio, a confirmação exige leitura correspondente dos dez ganhos. Se a tentativa falhar, o rascunho fica disponível para Aplicar ajuste; o app não repete automaticamente a escrita.

No T13 ANC as dez frequências permanecem fixas: 31, 62, 125, 250, 500 Hz, 1, 2, 4, 8 e 16 kHz. Faixa de edição −6 a +6 dB, passos de 1 dB. Frequência/Q variáveis, adicionar/remover filtros e ±12 dB do HT-08 não são expostos porque não foram comprovados neste hardware. A linha interpola os ganhos, sem fingir medir ou calcular uma resposta acústica conhecida.

O transporte RCSP FF validado foi preservado. O equalizador interno dos fones é independente da seção opcional de processamento de áudio do Mac descrita abaixo. Conexão e ANC não foram alterados por esta adaptação.

## Outras funções

ANC, Normal, Transparência, modo jogo e mapeamento dos gestos retornados pelo dispositivo. Volume e saída são do macOS. As baterias esquerda, direita e do estojo aparecem quando informadas pelo canal RCSP; valores ausentes ou ambíguos aparecem como `—`. Sem leitura RCSP, o app pode mostrar a bateria geral exposta pelo macOS. Aparência clara/escura acompanha o sistema ou a preferência do app. Para iniciar com o Mac, adicione o aplicativo em Ajustes do Sistema → Geral → Itens de Início.

## Diagnóstico e validação

Em Opções e diagnóstico ou Ajustes, use Salvar diagnóstico… ou Copiar diagnóstico. O relatório registra comandos/respostas e estados sem despejar identificadores privados das respostas de identificação.

O usuário confirmou funcionamento de ANC e EQ na 1.2.8. A 1.5.6 preserva essas escritas e substitui a interface de EQ pela adaptação do QCY MeloBuds e mantém espera automática do dispositivo conhecido. Testes locais não substituem testar saída da caixa, reconexão e ganhos manuais nos fones reais. Veja `outputs/VALIDACAO.md` e `outputs/ALTERACOES-1.5.6.md`.

## Compilar

Execute `./build.sh` no Terminal dentro da pasta do projeto. Usa Command Line Tools, Swift 6, destino Intel macOS 14. Monta Info.plist e LSUIElement, compila e assina o bundle completo. Não requer Xcode completo ou bibliotecas externas.

Aplicativo independente, sem vínculo com a QCY. Não modifica firmware, pareamento ou segurança do Mac.

## Amplificação de áudio do Mac

Na aba Som, em **EQUALIZAÇÃO DO MAC**, selecione QCY-T13 ANC como saída e ative **Processar áudio do Mac**. Na primeira vez o macOS pode pedir permissão para gravar o áudio do sistema. O processamento acontece somente enquanto o botão estiver ativo e o aplicativo aberto. Há dez bandas de −12 a +12 dB, ganho geral de 0 a +6 dB e limitador de picos. Os ajustes são aplicados ao áudio que o Mac envia aos fones; não alteram a faixa de ±6 dB do EQ interno dos fones. A saída padrão não é trocada. Desligar o botão ou encerrar o aplicativo remove a rota temporária.

O ganho adicional pode comprimir picos quando o áudio já está alto. Ajuste a gosto ouvindo conteúdo conhecido. O processamento não é enviado por rede nem salvo em arquivo. A rota foi verificada com áudio real e encerramento completo; o resultado sonoro ainda deve ser avaliado pelo usuário em músicas reais.
