# QCY Control 1.5.0

A aba Som agora tem **EQUALIZAÇÃO DO MAC**, separada do equalizador interno dos T13 ANC. Ao ativar, o QCY Control abre uma rota temporária Core Audio com tap privado da saída QCY e um agregado cujo relógio é a própria saída. O callback recebe o áudio do Mac, aplica dez filtros digitais ajustáveis de −12 a +12 dB, ganho geral até +6 dB e limitador de picos, e escreve os quadros na saída. A rota não troca a saída padrão, não cria arquivo de áudio e não usa rede. Ao desligar ou encerrar, destrói o tap e o agregado. Se a saída mudar, o processamento é desligado.

As curvas dos fones permanecem em −6 a +6 dB e são enviadas pelo RCSP com confirmação de leitura como antes. ANC, jogo, toques, conexão Bluetooth e demais telas não receberam alterações de protocolo ou comportamento.

**Verificação:** macOS 14.8.7 Intel, saída QCY-T13 ANC em 44,1 kHz, PCM estéreo Float32. Um teste de rota com ganho neutro processou 37.888 quadros; outro, com tom de 62 Hz e reforço temporário, processou 128.000 quadros e limitou o pico de saída a 0,99. A saída padrão permaneceu QCY-T13 ANC. A medição isolada de graves é coberta pelos testes DSP; outros sons ativos podem influenciar os picos da rota. Os testes offline medem reforço de 62 Hz, ganho geral de +6 dB e limite de picos. A permissão de gravação de áudio do sistema é solicitada ao ativar. A percepção de volume e graves em músicas reais ainda precisa de avaliação do usuário. Saídas com formato incompatível são recusadas sem troca automática de dispositivo.

Base da API: documentação Apple de [Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps). A implementação de transporte e DSP foi escrita para este aplicativo; o código do eqMac não foi copiado.
