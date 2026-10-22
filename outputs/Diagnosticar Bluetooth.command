#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/QCY Control.app"
REPORT="$PWD/Diagnostico-Bluetooth.txt"
if [[ ! -d "$APP" ]]; then
  echo "Deixe este arquivo ao lado de QCY Control.app na pasta outputs."
  read -r -p "Pressione Enter para sair. "
  exit 1
fi
if [[ -f "$REPORT" ]]; then
  REPORT="$PWD/Diagnostico-Bluetooth-$(date +%Y%m%d-%H%M%S).txt"
fi
echo "Mantenha os fones ligados, perto do Mac, e feche o aplicativo QCY no celular."
echo "Este teste consulta os fones e não altera ANC, modo jogo ou equalizador."
/usr/bin/open -n "$APP" --args --ble-report "$REPORT"
echo "Aguardando o diagnóstico. Permita acesso ao Bluetooth se solicitado."
for ((i=0; i<85; i++)); do
  if [[ -f "$REPORT" ]]; then
    /bin/cat "$REPORT"
    echo ""
    echo "Relatório salvo em: $REPORT"
    read -r -p "Pressione Enter para sair. "
    exit 0
  fi
  sleep 1
done
echo "O relatório ainda não foi criado. Verifique se há uma solicitação de permissão Bluetooth."
read -r -p "Pressione Enter para sair. "
