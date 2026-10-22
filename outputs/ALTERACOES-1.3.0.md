# QCY Control 1.3.0 — 20/10/2026

## Conexão

A 1.2.8 já tinha tentativa automática, mas seu prazo de 18 segundos encerrava a solicitação enquanto os fones permaneciam na caixa. As tentativas limitadas de busca podiam acabar antes de o dispositivo voltar. A lista manual também continuava oferecendo Conectar durante uma solicitação já pendente.

Agora o periférico previamente confirmado é solicitado por retrievePeripherals e connect, mantendo a conexão pendente no CoreBluetooth sem prazo durante ausência. Após didConnect, um prazo separado protege a descoberta de serviços/notificações. A primeira descoberta desconhecida continua limitada. Reconexões priorizam o identificador salvo. Nenhum comando de configuração é repetido.

AppDelegate observa a lista de saídas CoreAudio e o estado Bluetooth publicado, independentemente do popover. A chegada dos QCY reinicia a tentativa quando necessário. Não há novo polling frequente; a consulta system_profiler de 60 s continua e é antecipada por mudanças de áudio e abertura do painel. Opções técnicas ficam recolhidas e a tela explica a espera automática.

## EQ manual

Draft local, dez ganhos inteiros de −6 a +6, seis predefinições, curva arrastável e controle acessível por banda. Envio explícito único com função FF, atributo 4, seletor FF. O backend valida quantidade e limites antes da conversão Int8. Só confirma após ler os dez ganhos e o modo 06/FF. Divergências não derrubam a sessão. Resposta sem curva encerra com erro em vez de deixar a operação presa.

Um perfil pessoal é salvo localmente em equalizer.customGains; não é aplicado automaticamente ao reconectar. O gráfico indica prévia local e retorna à curva lida após a operação. Retornos fora da faixa de edição são sinalizados.

## Evidência e limites

ANC e predefinições foram confirmados pelo usuário na 1.2.8. Não houve escrita automatizada de ajustes nos fones durante desenvolvimento da 1.3.0. Os novos testes verificam limites, bytes assinados, ACK sem confirmação, leitura correspondente, divergência e resposta sem curva. Reconexão após retirar da caixa e ajuste manual físico ainda precisam de confirmação do usuário. Renderização nativa é conferida separadamente; não equivale a teste de hardware.
