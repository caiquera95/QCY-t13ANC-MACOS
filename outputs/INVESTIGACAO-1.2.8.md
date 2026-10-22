# QCY Control 1.2.8 — comparação com QCY internacional

## Arquivos analisados

- QCY 4.1.0, pacote `com.qcymall.earphonesetup`, build 677, SHA-256 `1bf0b0ed15fcea5017f93932e9ab31cf8ca9e71ebe87a5689a1a849f4bb7b607`. Endereço HTTP de APK publicado em comentário do HTML da página oficial https://qr.watch.qcy.com/qcy/: http://img.qcymall.com/qcy_4.1.0_676_release.apk. O nome do arquivo e o build do manifesto diferem. A tentativa HTTPS falhou por incompatibilidade de certificado; não se desativou a validação TLS. A integridade de transporte/autoria do arquivo HTTP não foi comprovada criptograficamente. Esta edição usa StubApp/jiagu e só expõe quatro classes Java de carregamento na análise estática.
- QCY internacional 4.0.7, pacote `com.qcymall.googleearphonesetup`, build 717, SHA-256 `32cc1bc15d18494d1283c08bb096b8b398a43b65b44ad9b949dda85d8fb19afb`. Obtido pelo link de download da página https://apkpure.net/qcy/com.qcymall.googleearphonesetup/download (repositório terceiro), https://d.apkpure.net/b/APK/com.qcymall.googleearphonesetup?version=latest. Manifesto conferido e seis DEX analisados. Pacote corresponde ao publicado na Google Play; isso sozinho não autentica o APK nem comprova equivalência ao iOS.

Nenhum APK foi instalado ou executado. Nenhuma biblioteca extraída foi carregada. Ferramentas locais apenas leram ZIP, manifesto e instruções DEX. Não houve comunicação com os fones nesta análise.

## Duas diferenças encontradas e implementadas

### ANC: troca de modo é diferente de ajuste de intensidade

`ItemViewANCPercent$1.onItemClick` chama `setAncLevel(percent, true)`. `ItemViewANCPercent.setAncLevel` encaminha esse booleano a `QCYConnectManager.setNoiseLevelPercent`. No ramo JL com booleano true, cria `new NoiseMode`, define SOMENTE o modo e chama `setCurrentNoiseMode`. Portanto comprimento, mínimo, máximo e ganho atual ficam zero. O ramo false reutiliza a faixa e calcula o ganho para alterar intensidade.

O código Swift antes reaproveitava comprimento 06 e faixa retornada pelos fones mesmo para trocar de modo. A 1.2.8 usa o registro novo de modo, serializado em oito bytes conforme `NoiseMode.toData`:

- Normal: `02 00 00 00 00 00 00 00`
- ANC: `41 00 00 00 00 00 00 00`
- Transparência: `03 00 00 00 00 00 00 00`

Enquadramento permanece SetADV C0, LTV tipo 11. Os códigos específicos do modelo continuam provenientes do painel público do produto 18290. A faixa retornada continua validada para leitura; a UI não oferece controle de intensidade. Não há handshake novo ou comandos especulativos.

### EQ: seletor de escrita personalizada é FF

`QCYConnectManager$1.doInBackground` monta modo + ganhos e chama `JLDeviceImpl.setEQ`. Este método diferencia modo -1 (byte FF) dos demais: no ramo FF passa os ganhos recebidos a `EqInfo`; nos demais substitui todos os ganhos por 7F antes de `configEqInfo`. A 1.2.7 enviava 06 + ganhos, confundindo banco retornado pelo dispositivo com seletor de escrita personalizada.

A 1.2.8 envia função pública FF, LTV atributo 4, seletor FF e dez ganhos da curva escolhida. Exemplo Padrão: `FF 0C 04 FF 00 00 00 00 00 00 00 00 00 00`. O retorno pode identificar modo 06 ou FF; exige correspondência dos dez ganhos para confirmar. Não aceita apenas ACK como sucesso. Eventos durante ajustes continuam registrados sem substituir a consulta.

## Reproduzir a investigação

Scripts `work/apk-analysis/analyze-qcy4.py` e `analyze-qcy-global.py`; resultados em `work/apk-analysis/qcy4` e `qcy-global`. Classes principais em `qcy-global/disassembly/com/qcymall/earphonesetup/manager/{QCYConnectManager,JLDeviceImpl}.txt`, classe `QCYConnectManager$1.txt`, `v2ui/view/ItemViewANCPercent{,$1}.txt` e `com/jieli/jl_bt_rcsp/data/model/device/NoiseMode.txt`.

## Limites

São correções respaldadas pelo código do QCY internacional, mas ainda precisam de teste no T13 ANC físico. Não afirmar resolução definitiva com base nos testes simulados. O relatório 1.2.7 do usuário confirmou conexão automática e persistência do estado anterior tanto na notificação EQ quanto na leitura; não mostrou aplicação dos ajustes. A nova versão altera as duas diferenças descritas, sem mudar firmware, pareamento, áudio do Mac ou modo jogo.
