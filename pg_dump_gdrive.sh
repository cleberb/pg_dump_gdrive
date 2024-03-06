#!/usr/bin/env bash

###############################################################################################################
# Informações do sistema
###############################################################################################################

DESCRIPTION="Backup PostgreSQL Gdrive"
DEVELOPER="Cleberson Batista"
VERSION="1.2"
COMPANY="Cleberson Batista"
COMPANY_SITE="https://www.linkedin.com/in/cleberson-batista/"

###############################################################################################################
# Opções de configuração do Bash
###############################################################################################################

# Bash vai se lembrar e voltar o mais alto exitcode em uma cadeia de pipes.
# Desta forma, como exemplo, pode-se pegar o erro no caso do mysqldump falhar em `mysqldump | gzip`
set -o pipefail

# Esta opção permite que os comandos executado após pipeline (|) sejam executados na shell atual e não em um subshell.
# Esta propriedade possibilita a edição de variáveis da shell atual.
shopt -s lastpipe

# Variável responsável por listar diretórios de executáveis do sistema
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

# Define linguagem padrão para utilização nos comandos utilizados pelo script
# Se for Debian
if [ -e /etc/debian_version ]; then
  export LANG="C.UTF-8" 2> /dev/null
  export LC_ALL="C.UTF-8" 2> /dev/null
else
  export LANG="en_US.UTF-8" 2> /dev/null
  export LC_ALL="en_US.UTF-8" 2> /dev/null
fi

# Definir umask restritivo para o script
umask=007

# Nome do script
SCRIPT_NAME="$(basename "$0")"

# Diretório raiz do script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Caminho absoluto do script
SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_NAME"

# Definir início de execução de script
START_TIME=$(date +%s);

# Variável utilizada no registro de info do sistema
LOG_TIME=$(date +%Y%m%d%H%M%S -d @$START_TIME)

# Variável utilizada em mensagens para usuário
SHOW_TIME=$(date +%Y-%m-%d\ %H:%M:%S -d @$START_TIME)

###############################################################################################################
# Variáveis de configurações
###############################################################################################################

# Define variável STATUS
STATUS="OK"

# Hostname
HOSTNAME=$(hostname)

# Endereços IP's
IP_LIST=$(ip -oneline -details link show | grep -Ev 'state DOWN|ifb[0-9]+|bridge|loopback|link/none|link/ipip' | awk '{print $2}' | sed 's/:\|\ //g' | xargs -n 1 ip -4 -br a s | awk '{print $1": "$3}' | sort | pr --across --omit-pagination --join-lines --columns=3)

# Identificação/Label do backup
BACKUP_LABEL=''

# Diretório local de processamento do backup
BACKUP_DIR=''

# Tipo de formato de saída do processamento do pg_dump para bases individuais
# Valores válidos: "[plain|directory]"
BACKUP_DUMP_TYPE='plain'

# Retenção de backups
# Diários
BACKUP_RETENTION_DAILY=6
# Semanais
BACKUP_RETENTION_WEEKLY=4
# Mensais
BACKUP_RETENTION_MONTHLY=11
# Anuais
BACKUP_RETENTION_YEARLY=5

# Nível de info do rclone
# Opções:
#   - DEBUG
#   - INFO
#   - NOTICE
#   - ERROR
RCLONE_LOG_LEVEL="INFO"

# E-mail de origem
MAIL_SOURCE="root@localhost"

# E-mail de destinatário
MAIL_TARGET="root@localhost"

# Comando para dar um flush na fila e enviar mensagens que estão agarradas no serviço de e-mail
CMD_FLUSH_MAIL_QUEUE="$(command -v postqueue &> /dev/null && echo 'postqueue -f')"

# Valor em porcentagem de uso de núcleos de processadores pelo pg_dump
# IMPORTANTE: Não acrescentar string "%", apenas valores inteiros.
PERCENT_CORES_PGDUMP=80

# Valor em porcentagem de uso de núcleos de processadores pelo compactador PIGZ
# IMPORTANTE: Não acrescentar string "%", apenas valores inteiros.
PERCENT_CORES_PIGZ=80

# Binário do sudo
SUDO=$(command -v sudo)

# Binário do rclone
RCLONE=$(command -v rclone)

# Ferramenta de compactação pigz
PIGZ=$(command -v pigz)

# Cliente de envio de email
SENDEMAIL=$(command -v sendemail || command -v sendEmail)

# Ferramentas de backup do PostgreSQL
PG_DUMP=$(command -v pg_dump)
PG_DUMPALL=$(command -v pg_dumpall)

###############################################################################################################
# Funções de controle
###############################################################################################################

function _exit(){

  # Sinal utilizado para sair do script
  local signal=$1

  # Status do último comando executado
  local status=$2

  case $signal in
    SIGINT)
      # SIGINT: Interromper processo ao pressionar Ctrl-C no teclado.
      error "--> ALERT: Processo recebeu sinal SIGINT(Ctrl-C) e será interrompido."
    ;;
    SIGQUIT)
      # SIGQUIT: Finalizar processo ao pressionar Ctrl-\ no teclado.
      error "--> ALERT: Processo recebeu sinal SIGQUIT(Ctrl-\\) e será finalizado."
    ;;
    SIGTERM)
      # SIGTERM: Finalizar processo através dos comandos "kill" ou "killall".
      error "--> ALERT: Processo recebeu sinal SIGTERM e será finalizado."
    ;;
    SIGHUP)
      # SIGHUP: Desligar ou sair de um processo em execução em primeiro plano de um terminal
      error "--> ALERT: Processo recebeu sinal SIGHUP e será finalizado."
    ;;
  esac

  # Remover configuração do rclone
  [ -e "$RCLONE" ] && [ "$RCLONE_REMOTE_NAME" ] && $RCLONE -q config delete $RCLONE_REMOTE_NAME &> /dev/null

  # Excluir arquivo de log do rclone
  [ -e "$RCLONE_LOG" ] && rm -f $RCLONE_LOG

  # Excluir arquivo de log de globals objects
  [ -e "$GLOBALS_LOG" ] && rm -f $GLOBALS_LOG

  # Excluir arquivo de log do dump
  [ -e "$DUMP_LOG" ] && rm -f $DUMP_LOG

  # Excluir arquivo de log do tar
  [ -e "$TAR_LOG" ] && rm -f $TAR_LOG

  # Excluir arquivo de log do pigz
  [ -e "$PIGZ_LOG" ] && rm -f $PIGZ_LOG

  # Calcula e emite duração do processo de backup
  info "$(runtime)"

  # Emite rodapé informativo
  info "$(footer)"

  # Envio de e-mail informativo
  mail $STATUS

  # Define ação padrão para o sinal EXIT. Caso contrário repetirá as ações desta função ao
  # executar o comando exit abaixo.
  trap - EXIT

  # Sair do script
  [ "$status" != "" ] && exit $status || exit

}

# Função responsável por sair do script sem chamar tratamentos especiais
function die(){

  # Define ação padrão para o sinal EXIT. Caso contrário repetirá as ações do TRAP ao
  # executar o comando exit abaixo.
  trap - EXIT

  exit $1

}

function usage() {
  error "Usage: $SCRIPT_NAME [ -c | --config <Path file configuration> ]
                             [ -d | --download <Regex file name> ]"
  die 2
}

function set_valid_config(){

  if ! [ -e "$SUDO" ]; then
    error "ALERT: A ferramenta sudo não está instalada."
    die 1
  fi

  if ! [ -e "$SENDEMAIL" ]; then
    error "ALERT: A ferramenta sendEmail não está instalada."
    die 1
  fi

  if ! [ -e "$PIGZ" ]; then
    error "ALERT: A ferramenta pigz não está instalada."
    die 1
  fi

  if ! [ -e "$RCLONE" ]; then
    error "ALERT: A ferramenta rclone não está instalada."
    die 1
  fi

  if ! [ "$RCLONE_TOKEN" ]; then
    error "ALERT: Token de conexão do Rclone não informado. Verifique o parâmetro \"RCLONE_TOKEN\"."
    die 1
  fi

  if ! [ "$BACKUP_LABEL" ]; then
    error "ALERT: Identificação/Label do backup não informado. Verifique o parâmetro \"BACKUP_LABEL\"."
    die 1
  fi

  if ! [ "$BACKUP_DIR" ]; then
    error "ALERT: Diretório de processamanto do backup não informado. Verifique o parâmetro \"BACKUP_DIR\"."
    die 1
  fi

  # Remover "/" do final do caminho, caso esteja definido
  BACKUP_DIR=${BACKUP_DIR%\/}

  # Nome da conexão remota utilizada pelo rclone
  # OBS: Nome aleatório para não entrar em conflito com eventuais configurações já existentes
  RCLONE_REMOTE_NAME="GDRIVEBKPPG${RANDOM}"

  # Configurações do rclone para o google drive
  # Mais detalhes em:
  #   - https://rclone.org/docs/#config-file
  #   - https://rclone.org/drive/
  declare -g -x RCLONE_CONFIG_${RCLONE_REMOTE_NAME^^}_TYPE='drive'
  declare -g -x RCLONE_CONFIG_${RCLONE_REMOTE_NAME^^}_SCOPE='drive'
  declare -g -x RCLONE_CONFIG_${RCLONE_REMOTE_NAME^^}_TOKEN=$RCLONE_TOKEN
  declare -g -x RCLONE_CONFIG_${RCLONE_REMOTE_NAME^^}_ROOT_FOLDER_ID=$RCLONE_ROOT_FOLDER_ID
  declare -g -x RCLONE_CONFIG_${RCLONE_REMOTE_NAME^^}_TEAM_DRIVE=$RCLONE_TEAM_DRIVE

  # Calcular porcentagem de processadores utilizados pelo PIGZ
  NUM_CORES_PIGZ=$(( $(nproc) * PERCENT_CORES_PIGZ / 100))

  # Calcular porcentagem de processadores utilizados pelo PD_DUMP
  NUM_CORES_PGDUMP=$(( $(nproc) * PERCENT_CORES_PGDUMP / 100))

  # Arquivo de info do globals objects
  GLOBALS_LOG="/tmp/backup_pg_gdrive_${BACKUP_LABEL}_globals_${LOG_TIME}.log"

  # Arquivo de info do pg_dump
  DUMP_LOG="/tmp/backup_pg_gdrive_${BACKUP_LABEL}_pgdump_${LOG_TIME}.log"

  # Arquivo de log do tar
  TAR_LOG="/tmp/backup_pg_gdrive_${BACKUP_LABEL}_tar_${LOG_TIME}.log"

  # Arquivo de log do pigz
  PIGZ_LOG="/tmp/backup_pg_gdrive_${BACKUP_LABEL}_pigz_${LOG_TIME}.log"

  # Arquivo de log do rclone
  RCLONE_LOG="/tmp/backup_pg_gdrive_${BACKUP_LABEL}_rclone_${LOG_TIME}.log"
}

# Função de repetição de string
function repeat_str(){
  local string=$1
  local number=$2

  (( number++ ))

  seq -s "$string" $number | sed 's/[0-9]//g'
}

# Registrar mensagens informativas
function info(){

  local string="$*\n"

  LOG_MESSAGE+="${string}"

  echo -ne "$string" | tee >(sed '/^$/d' | logger --priority daemon.info --tag ${SCRIPT_PATH}[$$])

}

# Registrar mensagens de erros
function error(){

  local string="$*\n"

  LOG_MESSAGE+="${string}"

  STATUS="ERROR"

  echo -ne "$string" | tee >(sed '/^$/d' | logger --priority daemon.err --tag ${SCRIPT_PATH}[$$]) >&2

}

function mail(){
  local status=$1

  local log_mail=$($SENDEMAIL -f $MAIL_SOURCE \
    -t $MAIL_TARGET \
    -u "${status}: $DESCRIPTION: $HOSTNAME ($SHOW_TIME)" \
    -o reply-to=$MAIL_SOURCE \
    -o message-charset=utf-8 \
    -m "$(echo -e "$LOG_MESSAGE" | sed '1s/^-/\n-/g')" 2>&1)

  info "$log_mail"

  # Dar um flush na fila e enviar mensagens que estão pendentes no serviço de e-mail
  [ "$CMD_FLUSH_MAIL_QUEUE" ] && $CMD_FLUSH_MAIL_QUEUE > /dev/null 2>&1
}

# Uptime system
function uptime_print(){

  local uptime=$(</proc/uptime)
  local uptime=${uptime%%.*}

  local STRING_TIME=""

  local days=$(( uptime/60/60/24 ))
  local hours=$(( uptime/60/60%24 ))
  local minutes=$(( uptime/60%60 ))
  local seconds=$(( uptime%60 ))

  [ $days != 0 ] && STRING_TIME+="$days dia(s)"
  [ $hours != 0 ] && STRING_TIME+=", $hours hora(s)"
  [ $minutes != 0 ] && STRING_TIME+=", $minutes min."
  [ $seconds != 0 ] && STRING_TIME+=", $seconds seg."

  STRING_TIME=$( sed -e 's/^, //g' -e 's/\(.*\),/\1 e/' <<< "$STRING_TIME" )

  echo -n "$STRING_TIME"

}

# Cabeçalho informativo
function header(){
  echo -e "\n+$( repeat_str '-' 100 )"
  echo -e "| $DESCRIPTION"
  echo -e "+$( repeat_str '-' 100 )"

  [ $BACKUP_RETENTION_DAILY != 0 ] && STRING_RETENTION+="$BACKUP_RETENTION_DAILY diario(s)"
  [ $BACKUP_RETENTION_WEEKLY != 0 ] && STRING_RETENTION+=", $BACKUP_RETENTION_WEEKLY semanal(s)"
  [ $BACKUP_RETENTION_MONTHLY != 0 ] && STRING_RETENTION+=", $BACKUP_RETENTION_MONTHLY mensal(s)"
  [ $BACKUP_RETENTION_YEARLY != 0 ] && STRING_RETENTION+=", $BACKUP_RETENTION_YEARLY anual(s)"

  STRING_RETENTION=$(sed -e 's/^, //g' -e 's/\(.*\),/\1 e/' <<< "$STRING_RETENTION")

  column -s'£' -t < <(
    echo -e "| Identificação do backup:£${BACKUP_LABEL:--}"
    echo -e "| Hostname:£$HOSTNAME"
    echo -e "| Endereço(s) IP(s):£$(echo -e "$IP_LIST" | sed -e '1!s/^/| £/g')"
    echo -e "| Uptime do sistema:£$(uptime_print)"
    echo -e "| Diretório de processamento:£$BACKUP_DIR"
    echo -e "| Diretório de backup GDRIVE:£$RCLONE_ROOT_FOLDER_ID"
    echo -e "| Tipo de dump:£$BACKUP_DUMP_TYPE"
    echo -e "| Retenção:£$STRING_RETENTION"
    echo -e "| Percentual de CPU's (PIGZ):£$PERCENT_CORES_PIGZ %"
    [ "$BACKUP_DUMP_TYPE" == "directory" ] && echo -e "| Percentual de CPU's (DUMP):£$PERCENT_CORES_PGDUMP %"
    echo -e "| Início do processo:£$SHOW_TIME"
  )

  echo -e "+$( repeat_str '-' 100 )"
}

# Rodapé informativo
function footer(){

  echo -e "\n+$( repeat_str '-' 100 )"
  echo -e "| INFORMAÇÕES DO SISTEMA\n|"

  column -s'£' -t < <(
    echo -e "| DESCRIÇÃO:£$DESCRIPTION"
    echo -e "| DESENVOLVEDOR:£$DEVELOPER"
    echo -e "| VERSÃO:£$VERSION"
  )

  echo -e "+$( repeat_str '-' 100 )\n"
  echo -e "© ${COMPANY^^} $(date +%Y)"
  echo -e "${COMPANY_SITE}\n"

}

# Calcula e emite duração do processamento do script
function runtime(){

  local status=$STATUS

  local END_TIME=$(date +%s)

  local TOT_TIME=$(( END_TIME - START_TIME ))

  local STRING_TIME=""

  if [ "$TOT_TIME" != "0" ]; then

    local days=$(( TOT_TIME/60/60/24 ))
    local hours=$(( TOT_TIME/60/60%24 ))
    local minutes=$(( TOT_TIME/60%60 ))
    local seconds=$(( TOT_TIME%60 ))

    [ $days != 0 ] && STRING_TIME+="$days dia(s)"
    [ $hours != 0 ] && STRING_TIME+=", $hours hora(s)"
    [ $minutes != 0 ] && STRING_TIME+=", $minutes min."
    [ $seconds != 0 ] && STRING_TIME+=", $seconds seg."

    STRING_TIME=$( echo $STRING_TIME | sed -e 's/^, //g' -e 's/\(.*\),/\1 e/' )

  else

    STRING_TIME="0 seg."

  fi

  echo -e "\n\n+$( repeat_str '-' 100 )"
  echo -e "| Processamento finalizado.\n|"

  column -s'£' -t < <(
    echo -e "| Status:£${status}\n|"
    echo -e "| Fim do processo:£$(date +%Y-%m-%d\ %H:%M:%S -d @${END_TIME})"
    echo -e "| Duração do processo:£$STRING_TIME"
  )

  echo -e "+$( repeat_str '-' 100 )"

}

function backup_exec(){

  local backup_routine="daily"

  if [[ "$(date '+%d')" == "01" ]]; then
    if [[ "$(date '+%m')" == "01" ]]; then
      (( BACKUP_RETENTION_YEARLY <= 0 )) && die 0
      backup_routine="yearly"
    else
      (( BACKUP_RETENTION_MONTHLY <= 0 )) && die 0
      backup_routine="monthy"
    fi
  else
    if [[ "$(date '+%w')" == "0" ]]; then
      (( BACKUP_RETENTION_WEEKLY <= 0 )) && die 0
      backup_routine="weekly"
    else
      (( BACKUP_RETENTION_DAILY <= 0 )) && die 0
    fi
  fi

  # Emite cabeçalho
  info "$(header)"

  if ! [ -e "$BACKUP_DIR" ]; then
    info "\n--> Criando diretório de processamento de backup em \"$BACKUP_DIR\"."
    install -o root -g postgres -m 770 -d "$BACKUP_DIR"
  fi

  if [ "$(cd /tmp; $SUDO -i -u postgres find "$BACKUP_DIR" -writable 2> /dev/null)" == "" ]; then
    info "\n--> Adequando permissões do diretório de processamento de backup \"$BACKUP_DIR\". O usuário \"postgres\" deve ter acesso de escrita."
    install -o root -g postgres -m 770 -d "$BACKUP_DIR"

    if [ "$(cd /tmp; $SUDO -i -u postgres find "$BACKUP_DIR" -writable 2> /dev/null)" == "" ]; then
      error "\n--> ERROR: O diretório de processamento de backup \"$BACKUP_DIR\" não possue permissão de escrita pelo usuário \"postgres\"."
      error "           Contate o administrador do sistema, ou altere o caminho do parâmetro de configuração \"BACKUP_DIR\"."

      die 1
    fi
  fi

  info "\n--> Processando backup de arquivos de configuração."

  # Obter caminho do arquivo de configuração "postgresql.conf"
  local config_file=""
  config_file=$($SUDO -i -u postgres psql --tuples-only --pset=format=unaligned --command='show config_file' 2>&1)

  if [ "$?" != "0" ]; then
    error "    --> ERROR: falha ao obter caminho arquivo de configuração \"postgresql.conf\":\n$(sed 's/^/'"$(repeat_str ' ' 15)"'/g' <<< "$config_file")"

    exit 1
  fi

  # Obter caminho do arquivo de configuração "pg_hba.conf"
  local hba_file=""
  hba_file=$($SUDO -i -u postgres psql --tuples-only --pset=format=unaligned --command='show hba_file' 2>&1)

  if [ "$?" != "0" ]; then
    error "    --> ERROR: falha ao obter caminho arquivo de configuração \"pg_hba.conf\":\n$(sed 's/^/'"$(repeat_str ' ' 15)"'/g' <<< "$hba_file")"

    exit 1
  fi

  local configs_file="${BACKUP_DIR}/backup_${BACKUP_LABEL}_configs_${LOG_TIME}.tar.gz"

  # Compactar o arquivos de configuração
  tar -czf $configs_file -P $config_file $hba_file 2> ${TAR_LOG}

  if [ "$?" != "0" ]; then
    error "    --> ERROR: falha(s) ao compactar arquivos de configuração:\n$(sed 's/^/'"$(repeat_str ' ' 15)"'/g' "${TAR_LOG}")"

    info "    --> WARNING: Excluindo arquivo de backup \"${configs_file}\" com erro."
    rm -f "${configs_file}"

    exit 1
  fi

  # Adequar permissão do arquivo de backup
  chown root:postgres "${configs_file}"
  chmod 660 "${configs_file}"

  info "\n--> Processando backup de Objetos Globais."
  local globals_file="${BACKUP_DIR}/backup_${BACKUP_LABEL}_globals_${LOG_TIME}.sql.gz"

  $SUDO -i -u postgres $PG_DUMPALL --clean --if-exists --globals-only 2> ${GLOBALS_LOG} | $PIGZ --processes ${NUM_CORES_PIGZ} --stdout > "${globals_file}"

  if [ "$(cat ${GLOBALS_LOG})" != "" ]; then
    error "    --> ERROR: falhas registradas pelo pg_dumpall:\n$(sed 's/^/'"$(repeat_str ' ' 15)"'/g' ${GLOBALS_LOG})"

    info "    --> WARNING: Excluindo arquivos de backup \"${globals_file}\" com erro."
    rm -f "${globals_file}"

    exit 1
  fi

  # Adequar permissão do arquivo de backup
  chown root:postgres "${globals_file}"
  chmod 660 "${globals_file}"

  local databases=""
  databases=$($SUDO -i -u postgres psql --tuples-only --pset=format=unaligned --command="SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres';" 2>&1)

  if [ "$?" != "0" ]; then
    error "    --> ERROR: falha ao listar bancos de dados:\n$(sed 's/^/'"$(repeat_str ' ' 15)"'/g' <<< "$databases")"

    exit 1
  fi

  for base in $databases; do
    # OBS: Ignorar bandos de dados específico
    #[[ $base =~ 'template(0|1)' ]] && continue

    info "\n--> Processando backup de base de dados \"$base\"."

    if [ "$BACKUP_DUMP_TYPE" == "directory" ]; then

      # Local temporário para processamento de backup, com nome aleatório para não entrar em conflito com outro processo de backup
      local dump_dir="${BACKUP_DIR}/${base}${RANDOM}"

      if ! [ -e "${dump_dir}" ]; then
        info "\n--> Criando diretório temporário de backup \"${dump_dir}\"."
        install -o root -g postgres -m 770 -d "${dump_dir}"
      fi

      $SUDO -i -u postgres $PG_DUMP --compress=0 --jobs=${NUM_CORES_PGDUMP} --format=directory --dbname=${base} --file=${dump_dir} 2> ${DUMP_LOG}

      if [ "$?" != "0" ]; then
        error "    --> ERROR: falhas registradas pelo pg_dump:\n$(sed 's/^/'"$(repeat_str ' ' 15)"'/g' ${DUMP_LOG})"

        info "    --> WARNING: Excluindo diretório temporário de backup \"${dump_dir}\" com erro."
        rm -rf "${dump_dir}"

        exit 1
      fi

      # Arquivo de backup compactado a ser criado
      local dump_file="${BACKUP_DIR}/backup_${BACKUP_LABEL}_${base}_${LOG_TIME}.sql.tar.gz"

      # Compactar o diretório de backup
      tar -cf - ${dump_dir} 2> ${TAR_LOG} | $PIGZ --processes ${NUM_CORES_PIGZ} --stdout > "${dump_file}" 2> ${PIGZ_LOG}

      if [ "$?" != "0" ]; then
        error "    --> ERROR: falhas registradas ao compactar diretório de backup:\n$(sed 's/^/'"$(repeat_str ' ' 15)"'/g' ${TAR_LOG} ${PIGZ_LOG})"

        info "    --> WARNING: Excluindo diretório de backup \"${dump_dir}\" com erro."
        rm -rf "${dump_dir}"

        info "    --> WARNING: Excluindo arquivo de backup \"${dump_file}\" com erro."
        rm -f "${dump_file}"

        exit 1
      fi

      # Excluindo diretório de backup processado com sucesso
      rm -rf "${dump_dir}"

    else

      # Arquivo de backup compactado a ser criado
      local dump_file="${BACKUP_DIR}/backup_${BACKUP_LABEL}_${base}_${LOG_TIME}.dump.gz"

      # Compactar o diretório de backup
      $SUDO -i -u postgres $PG_DUMP --format=custom --compress=0 --dbname=${base} 2> ${DUMP_LOG} | $PIGZ --processes ${NUM_CORES_PIGZ} --stdout > "${dump_file}" 2> ${PIGZ_LOG}

      if [ "$?" != "0" ]; then
        error "    --> ERROR: falhas registradas ao processar backup:\n$(sed 's/^/'"$(repeat_str ' ' 15)"'/g' ${DUMP_LOG} ${PIGZ_LOG})"

        info "    --> WARNING: Excluindo arquivo de backup \"${dump_file}\" com erro."
        rm -f "${dump_file}"

        exit 1
      fi

    fi

    # Adequar permissão do arquivo de backup
    chown root:postgres "${dump_file}"
    chmod 660 "${dump_file}"

  done

  info "\n--> Excluindo arquivos de backups locais antigos."
  find ${BACKUP_DIR} -type f \( -name "backup_${BACKUP_LABEL}_*" -and ! -name "*_${LOG_TIME}*" \) -exec rm -f {} \;

  info "\n--> Enviando backups para o Gdrive."
  $RCLONE copy "${BACKUP_DIR}" "$RCLONE_REMOTE_NAME":${backup_routine}/ --include "*.gz" --drive-upload-cutoff 1000T --log-level $RCLONE_LOG_LEVEL --log-file $RCLONE_LOG --stats-unit=bits

  if [ "$?" != "0" ] ; then
    error "    --> ERROR: falha no envio de backups para o Gdrive:\n$(sed 's/^/'"$(repeat_str ' ' 15)"'/g' $RCLONE_LOG)"

    exit 1
  else
    info "$(
            (
              grep -E '^Transferred:.*, 100%,.*, ETA 0s' $RCLONE_LOG | tail -n 1
              grep -E '^Checks:.*, 100%$' $RCLONE_LOG | tail -n 1
              grep -E '^Transferred:.*, 100%$' $RCLONE_LOG | tail -n 1
              grep -E '^Elapsed time:' $RCLONE_LOG | tail -n 1
            ) | sed 's/^/    /g'
          )"
  fi

  info "\n\n--> Deletando backups antigos do Gdrive:"

  local retention=0

  case $backup_routine in
    daily)
      retention=$BACKUP_RETENTION_DAILY
    ;;
    weekly)
      retention=$BACKUP_RETENTION_WEEKLY
    ;;
    monthly)
      retention=$BACKUP_RETENTION_MONTHLY
    ;;
    yearly)
      retention=$BACKUP_RETENTION_YEARLY
    ;;
  esac

  # Limpar arquivo de info do rclone
  echo '' > $RCLONE_LOG

  local files=""
  files=$($RCLONE lsf --format "tp" --files-only "$RCLONE_REMOTE_NAME":${backup_routine}/ --log-level $RCLONE_LOG_LEVEL --log-file $RCLONE_LOG | sort -r | awk -F';' '{print $2}')

  if [ "$?" != "0" ] ; then
    error "    --> ERROR: falha ao listar arquivos do Gdrive:\n$(sed 's/^/'"$(repeat_str ' ' 15)"'/g' $RCLONE_LOG)"

    exit 1
  fi

  # Backups globals
  local files_to_delete="$(grep "backup_${BACKUP_LABEL}_globals_" <<< "$files" | sed '1,'${retention}'d')"$'\n'

  # Backups configs
  local files_to_delete+="$(grep "backup_${BACKUP_LABEL}_configs_" <<< "$files" | sed '1,'${retention}'d')"$'\n'

  # Backups de bases de dados individuais
  # OBS: Incluir $'\n' no final para ter quebra de linha
  for base in $databases; do
    files_to_delete+="$(grep "backup_${BACKUP_LABEL}_${base}_" <<< "$files" | sed '1,'${retention}'d')"$'\n'
  done

  # Remover possíveis linhas em branco
  files_to_delete="$(sed '/^$/d' <<< "$files_to_delete")"

  if [ "$files_to_delete" ]; then
    local file=""
    while read -r file; do
      # Limpar arquivo de info do rclone
      echo '' > $RCLONE_LOG

      local result=""
      result=$($RCLONE delete "$RCLONE_REMOTE_NAME":"${backup_routine}/${file}" --log-level $RCLONE_LOG_LEVEL --log-file $RCLONE_LOG)

      if [ "$?" == "0" ] ; then
        info "    --> Deletado arquivo \"${backup_routine}/${file}\"."
      else
        error "    --> ERROR: falha ao deletar arquivo \"${backup_routine}/${file}\":\n$(sed 's/^/'"$(repeat_str ' ' 15)"'/g' $RCLONE_LOG)"
      fi

    done <<< "$files_to_delete"
  fi

}

function backup_download(){
  # Emite cabeçalho
  info "$(header)"

  if ! [ -e "$BACKUP_DIR" ]; then
    info "\n--> Criando diretório de processamento de backup em \"$BACKUP_DIR\"."
    install -o root -g postgres -m 770 -d "$BACKUP_DIR"
  fi

  if [ "$(cd /tmp; $SUDO -i -u postgres find "$BACKUP_DIR" -writable 2> /dev/null)" == "" ]; then
    info "\n--> Adequando permissões do diretório de processamento de backup \"$BACKUP_DIR\". O usuário \"postgres\" deve ter acesso de escrita."
    install -o root -g postgres -m 770 -d "$BACKUP_DIR"

    if [ "$(cd /tmp; $SUDO -i -u postgres find "$BACKUP_DIR" -writable 2> /dev/null)" == "" ]; then
      error "\n--> ERROR: O diretório de processamento de backup \"$BACKUP_DIR\" não possue permissão de escrita pelo usuário \"postgres\"."
      error "           Contate o administrador do sistema, ou altere o caminho do parâmetro de configuração \"BACKUP_DIR\"."

      die 1
    fi
  fi

  info "\n--> Download de backups do Gdrive em "${BACKUP_DIR}/"."
  local files=""
  files=$($RCLONE lsf --recursive --format "tp" --files-only "$RCLONE_REMOTE_NAME": --include "${DOWNLOAD}" --log-level $RCLONE_LOG_LEVEL --log-file $RCLONE_LOG | sort -r | awk -F';' '{print $2}')

  if [ "$?" != "0" ] ; then
    error "    --> ERROR: falha ao listar arquivos do Gdrive:\n$(sed 's/^/'"$(repeat_str ' ' 15)"'/g' $RCLONE_LOG)"

    exit 1
  fi

  if [ "$files" ]; then
    local file=""
    while read -r file; do
      # Limpar arquivo de info do rclone
      echo '' > $RCLONE_LOG

      info "    - $file"

      local transfers=$(( $(nproc) / 2 ))
      [ $transfers -lt 4 ] && transfers=4

      $RCLONE copy "$RCLONE_REMOTE_NAME":"${file}" "${BACKUP_DIR}/" --transfers=$transfers --drive-chunk-size=128M --log-level $RCLONE_LOG_LEVEL --log-file $RCLONE_LOG --stats-unit=bits

      if [ "$?" != "0" ] ; then
        error "      --> ERROR: falha no download de backups do Gdrive:\n$(sed 's/^/'"$(repeat_str ' ' 15)"'/g' $RCLONE_LOG)"

        exit 1
      else
        info "$(
                (
                  grep -E '^Transferred:.*, 100%,.*, ETA 0s' $RCLONE_LOG | tail -n 1
                  grep -E '^Checks:.*, 100%$' $RCLONE_LOG | tail -n 1
                  grep -E '^Transferred:.*, 100%$' $RCLONE_LOG | tail -n 1
                  grep -E '^Elapsed time:' $RCLONE_LOG | tail -n 1
                ) | sed 's/^/        /g'
              )"
      fi

    done <<< "$files"
  else
    error "    --> ERROR: Nenhum arquivo localizado para realizar download."
  fi

}

###############################################################################################################
# Main Script
###############################################################################################################

# Tratamento de sinais enviados ao processo do script
# SIGINT: Interromper processo ao precionar Ctrl-C no teclado.
trap '_exit SIGINT' SIGINT
# SIGQUIT: Finalizar processo ao precionar Ctrl-\ no teclado.
trap '_exit SIGQUIT' SIGQUIT
# SIGTERM: Finalizar processo através dos comandos "kill" ou "killall".
trap '_exit SIGTERM' SIGTERM
# SIGHUP: Desligar ou sair de um processo em execução em primeiro plano de um terminal
trap '_exit SIGHUP' SIGHUP
# EXIT: é um pseudo-sinal lançado pelo bash quando o script é finalizado com uma chamada direta a exit
#       ou o fim do script é alcançado. Outra situação em que esse sinal é gerado, acontece quando um
#       programa é executado incorretamente caso a opção errexit (set -e) esteja ativada.
trap '_exit EXIT $?' EXIT

while [ "$1" ]; do
  case "$1" in
    -c|--config)
      CONFIG="$2"
      shift 2
      if ! [ "$CONFIG" ]; then
        error "--> ERROR: O arquivo de configuração não informado!"
        usage
      elif ! [ -e "$CONFIG" ] || ! [ -r "$CONFIG" ]; then
        error "--> ERROR: O arquivo de configuração \"$CONFIG\" não pode ser lido ou não existe!"
        usage
      fi
    ;;
    -d|--download)
      DOWNLOAD="$2"
      shift 2
      if ! [ "$DOWNLOAD" ]; then
        error "--> ERROR: Arquivo(s) de backup não informado!"
        usage
      fi
    ;;
    *)
      usage
    ;;
  esac
done

# Carregar configurações personalizadas
source "$CONFIG"
if [ "$?" != "0" ]; then
  error "--> ERROR: O arquivo de configuração \"$CONFIG\" não foi carregado corretamente, verifique os erros! Contatar o administrador do sistema!"
  die 1
fi

# Setar configurações básicas e validar configurações e ferramentas de dependência do script
set_valid_config

if [ "$DOWNLOAD" ]; then
  # Executar download de arquivo(s) de backup
  backup_download
else
  # Executar o processo de backup
  backup_exec
fi

exit 0
