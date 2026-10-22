# QCY Control 1.4.0 — 20/10/2026

Substitui a interface de equalizador pela adaptação MIT do QCY MeloBuds de Thiago Oliveira, commit 070189af36fe76f58c38606b79a9204a33e70e5c. Grade de seis perfis, curva com animação e área preenchida, escala logarítmica 20 Hz–20 kHz, pontos das dez frequências fixas e ajuste preciso por banda. Não incorpora captura de áudio/visualizador.

A edição Personalizado trava a banda selecionada no início do gesto, limita ganhos a −6..6 inteiros e envia uma vez ao concluir. Perfis aplicam ao selecionar. A persistência local usa a chave já existente equalizer.customGains, preservando o perfil do usuário. Original registra a leitura inicial da sessão, não um padrão de fábrica. Ganhos QCY anteriores ficam em menu separado. Reduzir Movimento do sistema desliga animações.

O transporte, enquadramento, limites, leitura de confirmação e serialização existentes não foram alterados. Frequência e Q variáveis/filtros paramétricos do HT-08 não são enviados ao T13 ANC. O gráfico interpola ganhos por frequência, sem alegar medir resposta acústica ou conhecer o DSP interno.

Licença integral no bundle em Contents/Resources/ThirdPartyLicenses.txt, na árvore de fontes em Resources e em THIRD-PARTY-NOTICES.md. Créditos também na interface em Sobre este equalizador.

ANC e reconexão permanecem com a implementação anterior. A intermitência relatada de ANC na 1.3.0 voltou a funcionar sem diagnóstico da causa; esta versão não alega correção adicional desse episódio. Verificações automatizadas de protocolo não demonstram comportamento físico dos novos controles visuais.
