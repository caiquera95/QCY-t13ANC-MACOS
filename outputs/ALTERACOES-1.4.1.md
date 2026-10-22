# QCY Control 1.4.1

A interface recebeu cabeçalho em vinho, abas compactas, cartões de controle de ruído e curva de equalização em vermelho, inspirados nas capturas enviadas. Foram preservados os dez pontos fixos e a faixa real de −6 a +6 dB dos T13 ANC. A confirmação de cada ajuste continua por leitura RCSP; nenhuma rota de áudio virtual foi adicionada.

O eqMac processa o áudio de todo o macOS em uma rota virtual e oferece EQ básico e EQ avançado de dez bandas; os recursos Pro recentes ficam em um fork privado. Essa abordagem pode equalizar os fones enquanto recebem áudio do Mac, mas exige um componente de captura/encaminhamento contínuo, fora do escopo leve e sem servidor do QCY Control. O gráfico atual representa os ganhos enviados ao hardware dos fones.

Referência: https://github.com/bitgapp/eqMac (README, seção Features/Technology). A interface foi criada em SwiftUI, sem copiar código ou elementos gráficos do eqMac. A adaptação MIT do projeto qcy-mac continua documentada em THIRD-PARTY-NOTICES.md.

Validação: Swift 6 / Intel / macOS 14, pacote assinado ad hoc, testes offline e renderização nativa claro/escuro. Funcionalidade física da nova interface ainda requer teste nos fones do usuário.
