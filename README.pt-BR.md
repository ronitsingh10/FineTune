<img src="assets/icon.png" width="170" height="170" alt="Ícone do app FineTune" align="left"/>

<h3>FineTune</h3>

Controle o volume de cada app separadamente, amplifique apps silenciosos em até 4×, direcione o áudio para diferentes alto-falantes e ajuste o som com EQ e correção para fones. Sempre à mão na barra de menus. Gratuito e de código aberto.

<a href="https://github.com/ronitsingh10/FineTune/releases/latest/download/FineTune.dmg"><img src="assets/download-badge.svg" alt="Baixar para macOS" height="48"/></a>

<br clear="all"/>

<p align="center">
  <a href="README.md">English</a> · <strong>Português (Brasil)</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="assets/screenshot-main.png" alt="Popup do FineTune com controle de volume por app, roteamento de saída para vários dispositivos, correção AutoEQ e controles de volume por dispositivo" width="700">
</p>
<p align="center">
  <img src="assets/screenshot-eq.png" alt="FineTune com o painel de EQ aberto e a predefinição Clareza vocal selecionada" width="700">
</p>

## Instalação

**Homebrew** (recomendado)

```bash
brew install --cask finetune
```

**Manual** — [Baixe a versão mais recente](https://github.com/ronitsingh10/FineTune/releases/latest)

## Início rápido

1. Instale o FineTune e abra-o na pasta Aplicativos.
2. Quando solicitado, conceda a permissão **Gravação de Áudio da Tela e do Sistema**.
3. Clique no ícone do FineTune na barra de menus. Os apps que estiverem reproduzindo áudio aparecerão automaticamente.

Pronto. Ajuste os controles, direcione o áudio e explore o EQ pela barra de menus.

> **Dica:** para alternar automaticamente para um dispositivo quando ele for conectado, abra o modo de edição (ícone de lápis) e arraste-o acima dos alto-falantes integrados. A preferência é salva.

## Recursos

### 🎚 Controle de volume

- **Volume por app** — Controles de volume e silenciamento individuais para cada aplicativo.
- **Amplificação por app** — Predefinições de ganho de 2×, 3× e 4×.
- **Apps fixados** — Mantenha apps visíveis mesmo quando não estiverem reproduzindo áudio, para configurar volume, EQ e roteamento antecipadamente.
- **Ignorar apps** — Desative o FineTune completamente para apps específicos e restaure o áudio normal do macOS.
- **Volume pela roda de rolagem** — Passe o cursor sobre qualquer controle no pop-up, HUD ou painel de EQ e role para ajustar.

### ⌨️ Teclado

- **Atalhos globais de volume** — Configure **Aumentar volume do app**, **Diminuir volume do app** e **Mudo do app** em Ajustes → Atalhos.
- **Alternar o pop-up de qualquer lugar** — Defina um atalho para abrir ou fechar o pop-up, inclusive em apps de tela cheia.
- **Tamanho de passo configurável** — Escolha **Amplo / Normal / Fino / Extra-fino** em Ajustes → Atalhos → Etapa de volume.
- **Controle completo pelo teclado** — Use setas para navegar e ajustar, **M** para mudo, **Return/Espaço** para ativar, **Tab** para alternar abas e **Esc** para fechar.

### 🔀 Roteamento de áudio

- **Saída para vários dispositivos** — Direcione o áudio para diversos dispositivos simultaneamente.
- **Roteamento por app** — Envie apps para saídas diferentes ou siga o padrão do sistema.
- **Prioridade de dispositivo** — Escolha para qual dispositivo o FineTune alterna quando um novo dispositivo é conectado.
- **Restauração automática** — Ao reconectar um dispositivo, os apps voltam com volume, roteamento e EQ preservados.

### 🎛 EQ e correção

- **EQ de 10 bandas** — 20 predefinições em 5 categorias.
- **Predefinições de EQ do usuário** — Salve, renomeie e gerencie configurações por app.
- **Correção AutoEQ para fones** — Pesquise milhares de perfis ou importe arquivos `ParametricEQ.txt`.
- **Compensação de intensidade** — Correção automática de graves e agudos em volumes baixos, baseada nas curvas ISO 226:2023.

### 🖥 Dispositivos e sistema

- **Controle de dispositivos de entrada** — Monitore e ajuste níveis de microfone.
- **Volume de alertas** — Controle o volume de alertas e notificações do macOS.
- **Mecanismo inteligente de volume** — O FineTune escolhe automaticamente entre volume de hardware, DDC ou software para cada dispositivo e memoriza a escolha.
- **Inspetor de dispositivos** — Consulte taxa de amostragem, transporte, UID, modo exclusivo e substituição de volume por software.
- **Gerenciamento Bluetooth** — Conecte dispositivos pareados diretamente pela barra de menus.
- **Controle de monitores** — Ajuste displays externos por DDC.
- **Teclas de mídia e HUD de volume** — Controle opcional F10–F12 para a saída padrão, com HUD estilo Tahoe ou clássico.
- **Ícone dinâmico na barra de menus** — Escolha entre os estilos Padrão, Alto-falante, Forma de onda e Equalizador.
- **Esquemas de URL** — Automatize volume, mudo e roteamento com scripts.

### 🎨 Aparência

- **Tema claro ou escuro** — Siga o macOS ou mantenha o FineTune sempre em Claro ou Escuro.
- **Densidade do popup** — Escolha **Compacto / Confortável / Espaçoso** com visualização ao vivo.

## Documentação

- **[AutoEQ e correção para fones](guide/autoeq.md)** — Use perfis do projeto [AutoEQ](https://github.com/jaakkopasanen/AutoEq), importe perfis [EqualizerAPO](https://sourceforge.net/projects/equalizerapo/) ou navegue em [autoeq.app](https://www.autoeq.app/).
- **[Esquemas de URL](guide/url-schemes.md)** — Automatize o FineTune pelo Terminal, [Atalhos](https://support.apple.com/guide/shortcuts-mac), [Raycast](https://raycast.com) ou scripts.
- **[Solução de problemas](guide/troubleshooting.md)** — Problemas de permissões, apps ausentes e áudio.

## Como contribuir

- **Dê uma estrela ao repositório** — Ajude outras pessoas a descobrir o FineTune.
- **Reporte bugs** — [Abra uma issue](https://github.com/ronitsingh10/FineTune/issues).
- **Contribua com código** — Consulte [CONTRIBUTING.md](CONTRIBUTING.md).

### Compilar a partir do código-fonte

```bash
git clone https://github.com/ronitsingh10/FineTune.git
cd FineTune
open FineTune.xcodeproj
```

## Requisitos

- macOS 15.0 (Sequoia) ou posterior
- Permissão de captura de áudio (solicitada na primeira execução)

## Suporte

O FineTune é gratuito e de código aberto, para sempre. Se ele facilitou o seu dia, você pode [pagar um café](https://ko-fi.com/ronitsingh10) — mas não se sinta na obrigação. 🙏

## Licença

[GPL v3](LICENSE)
