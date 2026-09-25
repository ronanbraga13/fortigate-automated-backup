#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# FortiGate Automated Backup - Preparacao do servidor Ubuntu
# Validado em Ubuntu Server 22.04 LTS no laboratorio.
# ============================================================

TIMEZONE="America/Sao_Paulo"
SFTP_USER="fortibackup"
BACKUP_ROOT="/backup/fortigate"
RETENTION_DAYS=30
RETENTION_CRON="30 4 * * *"
RETENTION_SCRIPT="/usr/local/bin/fortigate-backup-retention.sh"
RETENTION_LOG="/var/log/fortigate-backup-retention.log"

# Estrutura de exemplo do LAB.
# Ajuste GROUP_NAME e DEVICES antes de usar em outro ambiente.
CREATE_LAB_STRUCTURE=true
GROUP_NAME="GRP_LAB"
DEVICES=(
  "MATRIZ:FGT-MATRIZ-01"
  "MINAS:FGT-MINAS-01"
  "RIO:FGT-RIO-01"
)

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[ERRO] %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Execute como root: sudo bash $0"

export DEBIAN_FRONTEND=noninteractive

log "Atualizando repositorios e instalando dependencias..."
apt-get update
apt-get install -y openssh-server tzdata cron tree

log "Validando timezone..."
CURRENT_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
if [[ "${CURRENT_TZ}" != "${TIMEZONE}" ]]; then
  timedatectl set-timezone "${TIMEZONE}"
fi
timedatectl set-ntp true || warn "Nao foi possivel habilitar NTP automaticamente."

log "Garantindo servicos SSH e cron..."
systemctl enable --now ssh
systemctl enable --now cron

log "Criando/validando usuario SFTP ${SFTP_USER}..."
if ! id "${SFTP_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${SFTP_USER}"
  USER_CREATED=true
else
  USER_CREATED=false
fi

log "Aplicando restricoes de SSH ao usuario de backup..."
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-fortibackup.conf"
cat > "${SSHD_DROPIN}" <<EOF
Match User ${SFTP_USER}
    ForceCommand internal-sftp
    PasswordAuthentication yes
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
EOF

sshd -t || die "Configuracao SSH invalida. Revise ${SSHD_DROPIN}."
systemctl reload ssh

log "Criando diretorio base..."
install -d -o "${SFTP_USER}" -g "${SFTP_USER}" -m 0750 "${BACKUP_ROOT}"

if [[ "${CREATE_LAB_STRUCTURE}" == "true" ]]; then
  log "Criando estrutura multi-grupo do LAB..."
  for entry in "${DEVICES[@]}"; do
    site="${entry%%:*}"
    device="${entry#*:}"
    install -d -o "${SFTP_USER}" -g "${SFTP_USER}" -m 0750 \
      "${BACKUP_ROOT}/${GROUP_NAME}/${site}/${device}"
  done
fi

log "Criando script de retencao..."
cat > "${RETENTION_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP_DIR="${BACKUP_ROOT}"
RETENTION_DAYS=${RETENTION_DAYS}

find "\$BACKUP_DIR" \
  -type f \
  -name "*.conf" \
  -mtime +"\$RETENTION_DAYS" \
  -print \
  -delete
EOF
chmod 0750 "${RETENTION_SCRIPT}"

touch "${RETENTION_LOG}"
chmod 0640 "${RETENTION_LOG}"

log "Configurando cron de retencao..."
CRON_LINE="${RETENTION_CRON} ${RETENTION_SCRIPT} >> ${RETENTION_LOG} 2>&1"
TMP_CRON="$(mktemp)"
crontab -l 2>/dev/null | grep -vF "${RETENTION_SCRIPT}" > "${TMP_CRON}" || true
printf '%s\n' "${CRON_LINE}" >> "${TMP_CRON}"
crontab "${TMP_CRON}"
rm -f "${TMP_CRON}"

log "Executando validacoes..."
systemctl is-active --quiet ssh || die "Servico SSH nao esta ativo."
systemctl is-active --quiet cron || die "Servico cron nao esta ativo."

FINAL_TZ="$(timedatectl show -p Timezone --value)"
[[ "${FINAL_TZ}" == "${TIMEZONE}" ]] || die "Timezone atual: ${FINAL_TZ}. Esperado: ${TIMEZONE}."

sshd -t || die "Falha na validacao final do sshd."

TEST_FILE="${BACKUP_ROOT}/.write_test_$$"
if runuser -u "${SFTP_USER}" -- touch "${TEST_FILE}"; then
  rm -f "${TEST_FILE}"
else
  die "Usuario ${SFTP_USER} nao consegue gravar em ${BACKUP_ROOT}."
fi

crontab -l | grep -F "${RETENTION_SCRIPT}" >/dev/null || die "Cron de retencao nao encontrado."

printf '\n'
log "Instalacao/validacao concluida."
printf 'Timezone: %s\n' "$(timedatectl show -p Timezone --value)"
printf 'Hora local: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf 'Backup root: %s\n' "${BACKUP_ROOT}"
printf 'Retencao: %s dias\n' "${RETENTION_DAYS}"
printf 'Cron: %s\n' "${CRON_LINE}"
printf '\n'

if [[ "${USER_CREATED}" == "true" ]]; then
  warn "Usuario ${SFTP_USER} foi criado. Defina uma senha forte antes do teste do FortiGate:"
  printf '  passwd %s\n' "${SFTP_USER}"
fi

warn "Confirme que FortiGate e servidor estao sincronizados em data/hora e fuso horario."
