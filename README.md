# Backup PostgreSQL no Google Drive

 Script de backup lógico do PostgreSQL, responsável processar de forma ágil (via `pigz`), transferir e controlar a retenção dos arquivos (via `rclone`) em reposítorios do Google Drive, monitorar todo o processo e gerar alertas informativos por e-mail.

1. Lógica do script no processamento e prioridade:

   * Backup anual no dia 01 de Janeiro.
   * Backup mensal no dia 01 dia dos demais meses.
   * Backup semanal todo domingo.
   * Backup diário.

2. Tempo de retenção dos backups:

   * Localmente, apenas o último backup processado.
   * No Google Drive, com definições personalizadas de configurações. Padrão: (6 diários, 4 semanais, 11 mensais, 5 anuais).

3. Arquivos de backup que serão gerados:

   * Arquivos de configuração `postgresql.conf` e `pg_hba.conf`.
   * Objetos Globais (roles e tablespaces).
   * Bancos de dados individuais, para facilitar a restauração específica de uma base.

## Configurações iniciais

### Configurar Google Drive

1. Crie uma conta no google:

   https://accounts.google.com/signup

2. Acesse o Google Drive e crie um diretório para armazenamento dos backups:

   https://drive.google.com/drive/my-drive

3. Obter o ID do diretório

   Acesse o diretório criado acima via browser e obtenha o ID do mesmo, basta copiar o hash de identificação que aparece na barra de endereço:

   > **Note**
   > Guarde essa informação para configurar o script de backup posteriormente.

   ![Root Folder ID](assets/img/gdrive_root_folder_id.jpg?raw=true "Root Folder ID")

### Obter configurações do `rclone`

1. Instale o `rclone` na sua máquina administrativa:

   > **Note**
   > Mais detalhes do **rclone**: https://rclone.org/install/

   ```console
   # sudo apt-get install curl
   # curl https://rclone.org/install.sh | sudo bash
   ```

2. Configurar o `rclone`:

   > **Note**
   > Mais detalhes de configuração do Google Drive: https://rclone.org/drive/

   2.1. Aplique o comando abaixo no terminal:

      ```console
      # rclone config \
               create TEMPDRIVE drive \
               config_is_local=true \
               client_id="" \
               client_secret="" \
               scope="drive" \
               root_folder_id="" \
               service_account_file="" \
               config_fs_advanced=false \
               config_change_team_drive=false \
               --all
      ```

   2.2. Irá abrir o browser automaticamente, para que seja autorizado o acesso da aplicação `rclone` ao Google Drive:

      ![Google Drive Authorization](assets/img/gdrive_authorization.jpg?raw=true "Google Drive Authorization")

      Retorne ao console, será apresentado a configuração do `rclone` e o parâmetro mais importante, o **token** de autenticação.

      Copie e armazene todo conteúdo do parâmetro **token** em um lugar seguro, pois este será utilizado posteriormente para configurar o script de backup:

      ```console
      --------------------
      [TEMPDRIVE]
      type = drive
      service_account_file =
      client_id =
      client_secret =
      scope = drive
      root_folder_id =
      token = {"access_token":"ya29....................hHQQ0163","token_type":"Bearer","refresh_token":"1//0h7WL4K0..................Eq2r3U4mS6Stw", "expiry":"2022-06-23T12:25:51.985155422-03:00"}
      team_drive =
      --------------------
      ```

   2.3. Com o **token** armazenado em um lugar seguro, pode-se excluir a configuração criada acima:

      ```console
      # rclone config delete TEMPDRIVE
      ```

## Configurações do servidor PostgreSQL

### Dependências

> **Note**
> Mais detalhes do **rclone**: https://rclone.org/install/

#### Debian

```console
# apt install sudo git sendemail pigz
```

Instalar versão mais recente do `rclone`:

```console
# wget https://downloads.rclone.org/v1.58.1/rclone-v1.58.1-linux-amd64.deb
# dpkg -i rclone-v1.58.1-linux-amd64.deb
# rm -rf rclone-v1.58.1-linux-amd64.deb
```

#### CentOS v8 / OracleLinux v8

```console
# dnf install sudo git sendemail pigz rclone
```

### Configurações

Realizar o clone do projeto para o diretório **/etc**:

```console
# git -C /etc clone --depth 1 https://github.com/cleberb/pg_dump_gdrive.git
```

Adequar as permissões do diretório e arquivos:

```console
# chown -R root:root /etc/pg_dump_gdrive
# chmod 750 /etc/pg_dump_gdrive
# chmod 750 /etc/pg_dump_gdrive/pg_dump_gdrive.sh
```

Copiar arquivo de configuração base:

> **Note**
> Pode-se utilizar qualquer nome. Recomenda ser algo identifique o servidor ou base de dados.

```console
# cp -a /etc/pg_dump_gdrive/{template.conf,<FILE>.conf}
```

> **Note**
> O script subentende que o sistema já possui um servidor de email configurado no endereço local, listado em **```localhost:25```**.

Abaixo os valores padrões de **template.conf**, os comentários são autoexplicativos. Altere com os valores ambiente de produção, com atenção para os parâmetros **RCLONE_TOKEN** e **RCLONE_ROOT_FOLDER_ID**:

```bash
# Nome da empresa
COMPANY="Cleberson Batista"

# Site da empresa
COMPANY_SITE="https://www.linkedin.com/in/cleberson-batista/"

# E-mail de origem
MAIL_SOURCE="email@empresa.com.br"

# E-mail de destino
# Multiplos e-mails, separado por espaço
MAIL_TARGET="email@empresa.com.br email2@empresa.com.br"

# Identificação/Label do backup
BACKUP_LABEL='dbteste'

# Diretório local de processamento do backup
BACKUP_DIR='/mnt/pgbackup'

# Tipo de formato de saída do processamento do pg_dump para bases individuais
# Valores válidos: "[plain|directory]"
BACKUP_DUMP_TYPE='plain'

# Configurações do rclone para o google drive
# Mais detalhes em:
#   - https://rclone.org/docs/#config-file
#   - https://rclone.org/drive/
RCLONE_TOKEN='{"access_token":"ya29.A0ARrd........XbIm-QRM3j4Dbcvzd............nV8","token_type":"Bearer","refresh_token":"1//0hNxVKkh-........................ISqVT8","expiry":"2022-04-13T18:27:35.548394904-03:00"}'
RCLONE_ROOT_FOLDER_ID='1DKE.................K5NrnO0'
RCLONE_TEAM_DRIVE=''

# Retenção de backups
# Diários
BACKUP_RETENTION_DAILY=6
# Semanais
BACKUP_RETENTION_WEEKLY=4
# Mensais
BACKUP_RETENTION_MONTHLY=11
# Anuais
BACKUP_RETENTION_YEARLY=5

# Valor em porcetagem de uso de núcleos de processadores pelo pg_dump
# IMPORTANTE: Não acrescentar string "%", apenas valores inteiros.
PERCENT_CORES_PGDUMP=80

# Valor em porcetagem de uso de núcleos de processadores pelo compactador PIGZ
# IMPORTANTE: Não acrescentar string "%", apenas valores inteiros.
PERCENT_CORES_PIGZ=80
```

### Agendamento de Backup

O script de backup deverá ser executado todos os dias, ajuste o **horário** e caminho do **arquivo de configuração** personalizado que será utilizado.

```console
# cat << 'EOF' > /etc/cron.d/pg_dump_gdrive
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
#MAILTO=email@empresa.com.br
HOME=/

# Rotina de backup PostgreSQL
00 00 * * * root /etc/pg_dump_gdrive/pg_dump_gdrive.sh --config /etc/pg_dump_gdrive/<FILE>.conf > /dev/null
EOF
```

### Restauração completa de um backup

1. Logar no servidor via ssh

2. Caso seja um novo servidor, configure o script `pg_dump_gdrive`

3. Agendamento de backup

   > **Warning**
   > Caso a base a ser restaurada seja muito grande, o agendamento de backup no crontab deve ser desativado, para que não seja processado backup durante a restauração.

   ```console
   # mv /etc/cron.d/pg_dump_gdrive{,.disabled}
   ```

4. Identificar arquivos a serem restaurados

   Acessar o Google Drive via browser e ver os nomes completos ou a string de data que representa os arquivos que deseja realizar download para restaurar

   ```console
   # pg_dump_gdrive --config file.conf --download daily/*20220621162701*
   ```

5. Acessar o diretório de processamento de backups definido para o script `pg_dump_gdrive`

   ```console
   # cd <diretory>
   ```

6. Restaurar os arquivos de configuração `postgresql.conf` e `pg_hba.conf`

   ```console
   # tar xzvf backup_<LABEL>_configs_<DATE>.tar.gz
   ```

   Transfira os arquivos para os devidos locais de configuração.

   > **Warning**
   > Caso tenha alterado os locais, certifique que todas as definições do caminho de arquivos `postgresql.conf` estejam com as definições adequadas.

   ```console
   # mv .../postgresql.conf <Diretório atual da configuração>
   # mv .../pg_hba.conf <Diretório atual da configuração>
   ```

   Garantir permissões adequadas:

   ```console
   # chown postgres:postgres .../postgresql.conf .../pg_hba.conf
   # chmod 600 .../postgresql.conf .../pg_hba.conf
   ```

   Reiniciar o Postgresql:

   ```console
   # systemctl restart postgresql
   ```

7. Restaurar `globals`

   Descompactar o arquivos de backup:

   ```console
   # pigz -dk backup_<LABEL>_globals_<DATE>.sql.gz
   ```

   Verificar a existência de `TABLESPACES`:

   ```console
   # grep '^CREATE TABLESPACE ' backup_<LABEL>_globals_<DATE>.sql

   CREATE TABLESPACE tablespace teste OWNER postgres LOCATION '/pg/data';
   ```

   No **exemplo** acima é possível identificar o caminho do TABLESPACE `/pg/data`. Certifique que este caminho esteja criado e devidamente permissionado:

   ```console
   # mkdir -p -m 750 /pg/data
   # chown postgres:postgres /pg/data
   ```

   Caso queira ignorar definições de `TABLESPACES`, comente as definições do backup:

   ```console
   # sed -i 's/^\(\(DROP\|CREATE\) TABLESPACE\)/\-\- \1/g' backup_<LABEL>_globals_<DATE>.sql
   ```

   Processar o restore:

   > **Note**
   > Remover do arquivo de dump o `DROP ROLE` e `CREATE ROLE` do usuário `postgres` para que não seja apresentado mensagem de erro informando que role já existe.

   ```console
   # grep -Ev '^(DROP|CREATE) ROLE( IF EXISTS)* postgres;' backup_<LABEL>_globals_<DATE>.sql | sudo -u postgres psql --no-psqlrc --echo-errors
   ```

8. Restaurar demais bases

   Descompactar o arquivos de backup:

   ```console
   # pigz -dk backup_<LABEL>_<BASE>_<DATE>.dump.gz
   ```

   Caso queira ignorar definições de `TABLESPACES`, defina a variável abaixo com opções extras do comando `pg_restore`, que será chamado posteriormente:

   ```console
   # OPTIONS_PGRESTORE='--no-tablespaces'
   ```

   Caso queira ignorar definições de privilégio e de proprietário **(Normalmente aplicado com restauração exclusiva da base, sem as `roles`)**, defina a variável abaixo com opções extras do comando `pg_restore`, que será chamado posteriormente::

   ```console
   # OPTIONS_PGRESTORE+=' --no-owner --no-privileges'
   ```

   Defina uma variável com caminho de log e inicie o processamento do restore em background:

   > **Note**
   > A opção `--dbname=postgres`, especificado no comando `pg_restore` abaixo, serve apenas para conectar inicialmente, posteriormente com a opção `--create`, o  irá criar e acessar a base do backup.
   > Mais detalhes do `pg_restore`: https://www.postgresql.org/docs/current/app-pgrestore.html

   ```console
   # LOG="/tmp/PGRESTORE-<BASE>.log"
   # sudo -i -u postgres pg_restore --format=custom --create --clean --if-exists --exit-on-error ${OPTIONS_PGRESTORE} --dbname=postgres /tmp/teste.dump backup_<LABEL>_<BASE>_<DATE>.dump &> $LOG &
   ```

   Para monitorar o processo (`ps_restore`) utilize alguma ferramenta de monitoramento de processos:

   ```console
   # htop -p $(pidof -d, pg_restore)
   ```

   Com o fim do processo, o arquivo de log deve está vazio, caso contrário, indicará falha e interrupção do processo:

   ```console
   # cat $LOG
   ```

9. Excluir os arquivos descompactados

   Exclua os arquivos de backup descompactados, para que o armazenamento de backup não seja ocupado e prejudique futuros processamentos:

   ```console
   # rm -f backup_*.{sql,dump}
   ```

10. Agendamento de backup

   > **Warning**
   > Caso tenha desativado o agendamento do backup no crontab, deve-se ativá-lo novamente.

   ```console
   # mv /etc/cron.d/pg_dump_gdrive{.disabled,}
   ```

## Documentação de referência

* https://www.postgresql.org/docs/current/app-pgdump.html
* https://www.postgresql.org/docs/current/app-pg-dumpall.html
* https://www.postgresql.org/docs/current/app-pgrestore.html
* https://www.postgresql.org/docs/14/manage-ag-templatedbs.html
* https://serverfault.com/questions/1081642/postgresql-13-speed-up-pg-dump-to-5-minutes-instead-of-70-minutes
* https://www.opsdash.com/blog/postgresql-backup-restore.html
* https://rclone.org/docs/#config-file
* https://rclone.org/drive/
* https://stackoverflow.com/a/57659755
* https://stackoverflow.com/a/16095742
* https://stackoverflow.com/a/9468796