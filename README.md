# FortiGate Automated Backup

Automação de backup de configurações FortiGate utilizando SFTP, com agendamento, retenção de arquivos e validação de restauração.

## Objetivo

Este projeto implementa um servidor central de backup para múltiplos clientes, localidades e FortiGates.

Fluxo:

```text
FortiGate
   |
   | SFTP / TCP 22
   v
Servidor Ubuntu
   |
   +-- /backup/fortigate/CLIENTE/LOCALIDADE/FIREWALL/
       +-- FGT-NOME_YYYY-MM-DD.conf
```

O envio é iniciado pelo próprio FortiGate usando `execute backup config sftp` dentro de um Automation Stitch agendado. O projeto não depende do Oxidized.

## Ambiente validado no LAB

- Ubuntu Server 22.04 LTS
- OpenSSH Server / SFTP
- FortiOS 7.2.8
- Backup diário
- Retenção padrão: 30 dias
- Timezone do servidor: `America/Sao_Paulo`
- Estrutura multi-cliente e multi-site

> Outros releases do FortiOS devem ser conferidos na documentação da versão correspondente. Sintaxe, variáveis e comportamento de Automation Stitch podem variar entre versões.

## Instalação do servidor

Baixe o instalador:

```bash
cd /tmp

curl -O https://raw.githubusercontent.com/ronanbraga13/fortigate-automated-backup/main/scripts/01-install-backup-server.sh

ls -lh 01-install-backup-server.sh

chmod +x 01-install-backup-server.sh
```

Antes de executar, revise as variáveis:

```bash
vim 01-install-backup-server.sh
```

Execute:

```bash
sudo ./01-install-backup-server.sh
```

O script:

- instala OpenSSH Server, cron, tzdata, tree e iptables;
- valida/corrige o timezone para `America/Sao_Paulo`;
- habilita sincronização NTP;
- cria/valida o usuário `fortibackup`;
- restringe esse usuário ao subsistema SFTP, sem shell interativo, TTY ou TCP forwarding;
- cria `/backup/fortigate`;
- cria a estrutura de exemplo do LAB;
- configura retenção de 30 dias;
- agenda a retenção diariamente às 04:30;
- testa escrita no diretório de backup;
- valida SSH, cron e timezone;
- possui opção de allowlist TCP/22 via iptables.

Se o usuário `fortibackup` for criado pelo script, defina uma senha forte:

```bash
sudo passwd fortibackup
```

Nunca publique a senha SFTP no GitHub.

## Estrutura de diretórios

Padrão adotado:

```text
CLIENTE / LOCALIDADE / FIREWALL / BACKUP
```

Exemplo:

```text
/backup/fortigate
└── CLIENTE_LAB
    ├── MATRIZ
    │   └── FGT-MATRIZ-01
    │       └── FGT-MATRIZ-01_2026-09-25.conf
    ├── MINAS
    │   └── FGT-MINAS-01
    └── RIO
        └── FGT-RIO-01
            └── FGT-RIO-01_2026-09-25.conf
```

Visualização:

```bash
tree /backup/fortigate
```

## Data, hora e NTP

FortiGate e servidor de backup devem estar sincronizados em data/hora. Para ambientes no Brasil, este LAB utiliza o horário de Brasília no Ubuntu:

```text
America/Sao_Paulo
```

Validação no Ubuntu:

```bash
date
timedatectl
```

Esperado:

```text
Time zone: America/Sao_Paulo (-03, -0300)
System clock synchronized: yes
NTP service: active
```

No FortiGate:

```bash
get system status
show system global | grep timezone
```

A sincronização é importante porque o nome diário usa a data obtida pelo FortiGate e o filesystem do servidor registra seu próprio timestamp.

## Configuração do FortiGate

### Teste manual

Exemplo:

```bash
execute backup config sftp /backup/fortigate/CLIENTE_LAB/RIO/FGT-RIO-01/FGT-RIO-01.conf <IP_SFTP> fortibackup <SFTP_PASSWORD>
```

Valide no Ubuntu:

```bash
ls -lh /backup/fortigate/CLIENTE_LAB/RIO/FGT-RIO-01/
```

### Automation Stitch diário

Exemplo para RIO:

```bash
config system automation-trigger
    edit "TRG_BACKUP_FGT_RIO"
        set trigger-type scheduled
        set trigger-frequency daily
        set trigger-hour 03
        set trigger-minute 10
    next
end

config system automation-action
    edit "ACT_BACKUP_FGT_RIO"
        set action-type cli-script
        set script "execute backup config sftp /backup/fortigate/CLIENTE_LAB/RIO/FGT-RIO-01/FGT-RIO-01_%%date%%.conf <IP_SFTP> fortibackup <SFTP_PASSWORD>"
        set accprofile "super_admin"
    next
end

config system automation-stitch
    edit "ST_BACKUP_FGT_RIO"
        set status enable
        set trigger "TRG_BACKUP_FGT_RIO"
        config actions
            edit 1
                set action "ACT_BACKUP_FGT_RIO"
                set required enable
            next
        end
    next
end
```

Teste do Stitch:

```bash
diagnose automation test ST_BACKUP_FGT_RIO
```

Neste LAB foi adotado um backup por dia, usando `%%date%%` no nome. Isso evita sobrescrita entre dias e simplifica a retenção.

## Retenção

O servidor mantém, por padrão, backups dos últimos 30 dias.

Script criado pelo instalador:

```text
/usr/local/bin/fortigate-backup-retention.sh
```

Cron:

```text
30 4 * * * /usr/local/bin/fortigate-backup-retention.sh >> /var/log/fortigate-backup-retention.log 2>&1
```

Para conferir:

```bash
sudo crontab -l
```

O período pode ser alterado pela variável `RETENTION_DAYS`.

## Segurança

### Restrição do usuário SFTP

O instalador aplica um bloco específico do OpenSSH ao usuário `fortibackup`:

- `ForceCommand internal-sftp`
- sem shell interativo;
- sem TTY;
- sem TCP forwarding;
- sem X11 forwarding.

Isso reduz a exposição da conta destinada exclusivamente aos backups.

### iptables no Ubuntu

É recomendado permitir TCP/22 somente dos IPs dos FortiGates autorizados e das redes/IPs de administração.

O instalador contém:

```bash
APPLY_IPTABLES=false
ALLOWED_SSH_IPS=(
  # "IP_DO_FORTIGATE"
  # "REDE_DE_ADMINISTRACAO/CIDR"
)
```

Por segurança, o script **não ativa a regra automaticamente** enquanto a allowlist não for revisada.

Antes de usar `APPLY_IPTABLES=true`, inclua também o IP/rede de onde o servidor é administrado. SFTP e SSH utilizam TCP/22; uma allowlist incompleta pode bloquear seu próprio acesso administrativo.

Exemplo conceitual:

```text
ALLOW TCP/22 from FortiGate A
ALLOW TCP/22 from FortiGate B
ALLOW TCP/22 from rede de administração
DROP  TCP/22 from demais origens
```

### Windows Firewall

Se o SFTP estiver hospedado em Windows/OpenSSH, aplique o mesmo princípio: regra de entrada TCP/22 limitada aos FortiGates e à rede administrativa.

Exemplo PowerShell:

```powershell
New-NetFirewallRule -DisplayName "SFTP - FortiGate" `
  -Direction Inbound `
  -Protocol TCP `
  -LocalPort 22 `
  -RemoteAddress <IP_DO_FORTIGATE> `
  -Action Allow
```

Crie também a regra necessária para a rede/IP de administração antes de remover ou desabilitar regras amplas de SSH.

## Compatibilidade FortiOS

Este projeto foi efetivamente validado em laboratório no **FortiOS 7.2.8**.

Pontos a observar em outros releases:

- disponibilidade e sintaxe de `execute backup config sftp`;
- estrutura do Automation Stitch;
- Scheduled Trigger;
- variáveis disponíveis em actions;
- comportamento das variáveis `%%date%%` e `%%log.*%%`;
- ambientes Multi-VDOM;
- restauração entre modelos/releases diferentes.

Não assumir compatibilidade apenas pela semelhança da sintaxe. Consulte a documentação da versão exata antes de implantar em produção.

## Restauração

O arquivo gerado por `execute backup config` é um backup de configuração destinado à restauração. A Fortinet diferencia esse método da simples saída de `show` / `show full-configuration`, que é voltada a inspeção e troubleshooting.

Antes de restaurar em produção:

1. valide modelo e versão do FortiOS;
2. mantenha uma cópia adicional do backup atual;
3. execute o procedimento em janela de mudança;
4. teste o processo em laboratório sempre que possível.

## Referências Fortinet consultadas

- Fortinet Community — **How to take backup from CLI using secure FTP (SFTP) protocol**  
  https://community.fortinet.com/fortigate-3/technical-tip-how-to-take-backup-from-cli-using-secure-ftp-sftp-protocol-93751

- Fortinet Community — **How to send automated backups of the configuration from a FortiGate with an automation stitch, using TFTP/FTP or SFTP Server and a recommendation for configuring a Linux machine**  
  https://community.fortinet.com/fortigate-3/technical-tip-how-to-send-automated-backups-of-the-configuration-from-a-fortigate-with-an-automation-stitch-using-tftp-ftp-or-sftp-server-and-a-recommendation-for-configuring-a-linux-machine-99783

- Fortinet Document Library — **FortiOS 7.2: Schedule trigger**  
  https://docs.fortinet.com/document/fortigate/7.2.12/administration-guide/453129/schedule-trigger

- Fortinet Document Library — **FortiOS 7.2: Variables in actions**  
  https://docs.fortinet.com/document/fortigate/7.2.11/administration-guide/427797/variables-in-actions

- Fortinet Document Library — **FortiOS 7.2.8: config system automation-stitch**  
  https://docs.fortinet.com/document/fortigate/7.2.8/cli-reference/878454488/config-system-automation-stitch

- Fortinet Community — **Configuration differences through GUI or Security Fabric Automation and Show command**  
  https://community.fortinet.com/fortigate-3/technical-tip-configuration-differences-through-gui-or-security-fabric-automation-and-show-command-207000

- Fortinet Community — **Troubleshooting SFTP configuration backup issues for FortiGate**  
  https://community.fortinet.com/fortigate-3/troubleshooting-tip-sftp-configuration-backup-issues-for-fortigate-160883

## Avisos

- Não armazene senhas reais, IPs sensíveis ou configurações de clientes neste repositório público.
- Use placeholders nos exemplos.
- Restrinja o acesso ao servidor SFTP.
- Monitore espaço em disco e sucesso dos backups.
- Valide periodicamente se os arquivos podem ser restaurados.
