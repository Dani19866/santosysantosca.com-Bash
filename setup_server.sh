#!/bin/bash

# --- COLORES ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- CONFIGURACIÓN DE SEGURIDAD ---
set -e
set -o pipefail
STEP="Inicio"

# --- FUNCIONES DE LOGGING ---
function info {
    echo -e "${GREEN}[+] $1${NC}"
}

function warn {
    echo -e "${YELLOW}[!] $1${NC}"
}

function error_log {
    echo -e "${RED}[!] $1${NC}"
}

# --- FUNCIÓN DE ROLLBACK / LIMPIEZA ---
function on_error {
    echo -e "\n${RED}------------------------------------------------${NC}"
    error_log "ERROR CRÍTICO en el paso: $STEP"
    warn "El script ha fallado. Ejecutando limpieza..."

    # 1. Rollback Firewall
    if [[ "$STEP" == *"Firewall"* ]]; then
        warn "Revirtiendo cambios en Firewall..."
        sudo ufw disable || true
    fi

    # 2. Rollback PostgreSQL
    if [[ "$STEP" == *"PostgreSQL"* ]]; then
        warn "Deteniendo y limpiando PostgreSQL..."
        sudo service postgresql stop || true
        # No desinstalamos para no ser destructivos con datos, pero paramos el servicio
    fi

    echo -e "${RED}🛑 Script detenido inesperadamente.${NC}"
    exit 1
}

trap on_error ERR

# --- FUNCIÓN DE CONFIRMACIÓN ---
function confirmar {
    local paso_descripcion="$1"
    
    echo -e "\n${BLUE}------------------------------------------------${NC}"
    echo -e "${BLUE}🔵 PRÓXIMO PASO:${NC} $paso_descripcion"
    read -p "   ¿Deseas ejecutar este paso? (y/n): " -n 1 -r
    echo "" 

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warn "Paso cancelado por el usuario. Deteniendo script."
        exit 0 
    fi
    
    STEP="$paso_descripcion"
    info "Procediendo con: $paso_descripcion"
}

# ==========================================
# INICIO DE LA INSTALACIÓN
# ==========================================

echo -e "🚀 ${GREEN}Iniciando asistente de configuración del servidor...${NC}"

# ------------------------------------------
# --- PASO 1: ACTUALIZACIÓN DE REPOSITORIOS  ---
# ------------------------------------------

confirmar "Actualizar los repositorios del sistema"
sudo apt-get update -y

# ------------------------------------------
# --- PASO 2: FIREWALL (UFW) ---
# ------------------------------------------

confirmar "Instalar y configurar Firewall (UFW: SSH, 80, 443)"

info "Instalando ufw..."
sudo apt install ufw -y

info "Configurando reglas por defecto..."
sudo ufw default deny incoming
sudo ufw default allow outgoing

info "Abriendo puertos..."
sudo ufw allow ssh
sudo ufw allow 80,443/tcp

info "Habilitando el firewall..."
sudo ufw --force enable

info "Verificando servicio UFW..."
sudo systemctl status ufw --no-pager || warn "Systemd no disponible, pero UFW está activo."

# ------------------------------------------
# --- PASO 3: POSTGRESQL ---
# ------------------------------------------
confirmar "Instalar PostgreSQL 18, iniciar servicio y validar conexión"

info "Instalando postgresql-common..."
sudo apt install -y postgresql-common

info "Configurando repositorio oficial de PostgreSQL..."
if [ -f /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh ]; then
    sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
else
    warn "Script de repo PostgreSQL no encontrado, intentando continuar..."
fi

info "Actualizando lista de paquetes tras añadir repo..."
sudo apt-get update -y

info "Instalando motor PostgreSQL 18..."
sudo apt install -y postgresql-18

# --- CORRECCIÓN DEL ERROR DE CONEXIÓN ---
info "Iniciando servicio PostgreSQL manualmente (Fix para Docker/WSL)..."

# Intentamos iniciar usando 'service' (SysVinit) si systemd falla
if ! sudo systemctl start postgresql 2>/dev/null; then
    warn "Systemd falló, intentando arranque directo..."
    sudo service postgresql start || sudo /etc/init.d/postgresql start
fi

info "Esperando a que la base de datos esté lista..."
# Loop de espera hasta que el archivo socket exista (máximo 10 segundos)
TIMEOUT=10
while [ ! -S /var/run/postgresql/.s.PGSQL.5432 ] && [ $TIMEOUT -gt 0 ]; do
    echo -n "."
    sleep 1
    ((TIMEOUT--))
done
echo "" # Salto de línea

if [ ! -S /var/run/postgresql/.s.PGSQL.5432 ]; then
    error_log "El socket de PostgreSQL no apareció. El servicio no arrancó correctamente."
    exit 1
fi

info "Verificando conexión..."
# Probamos ejecutar un comando simple en psql para asegurar que responde
sudo -u postgres psql -c "SELECT version();"

echo -e "\n${GREEN}✨ Todas las tareas completadas exitosamente.${NC}"

# ------------------------------------------
# --- PASO 4: CONFIGURACIÓN DE DIRECTORIOS TABLESPACES ---
# ------------------------------------------

confirmar "Crear y configurar directorios para Tablespaces (/data e /index)"

info "Creando estructura de directorios..."
sudo mkdir -p /data/tbs_data
sudo mkdir -p /index/tbs_index

info "Verificando existencia del usuario 'postgres'..."
if id "postgres" &>/dev/null; then
    info "Asignando propietario (postgres:postgres) y permisos (700)..."
    sudo chown postgres:postgres /data/tbs_data
    sudo chown postgres:postgres /index/tbs_index
    
    sudo chmod 700 /data/tbs_data
    sudo chmod 700 /index/tbs_index
    
    info "Permisos aplicados correctamente."
else
    error_log "El usuario 'postgres' no existe. No se pueden asignar permisos."
    warn "Verifica si el paso de instalación de PostgreSQL se completó correctamente."
    exit 1
fi

info "Verificando directorios creados..."
ls -ld /data/tbs_data /index/tbs_index

# ------------------------------------------
# --- PASO 5: CONFIGURACIÓN DE WAL Y TUNING DE POSTGRESQL ---
# ------------------------------------------

confirmar "Configurar directorios WAL, aplicar Tuning de Hardware y reiniciar servicio"

# 1. Crear directorios para WAL
info "Creando directorios para WAL Archives..."
sudo mkdir -p /archives/wal

info "Asignando permisos a /archives..."
if id "postgres" &>/dev/null; then
    sudo chown -R postgres:postgres /archives
    sudo chmod 700 /archives
    sudo chmod 700 /archives/wal
else
    error_log "Usuario postgres no encontrado. Fallo crítico."
    exit 1
fi

# 2. Localizar archivo de configuración
info "Detectando ubicación del archivo postgresql.conf..."
# Ejecutamos una consulta a la BD para que nos diga dónde está su config
PG_CONF=$(sudo -u postgres psql -t -P format=unaligned -c 'SHOW config_file;')

if [[ -z "$PG_CONF" || ! -f "$PG_CONF" ]]; then
    error_log "No se pudo localizar el archivo de configuración. ¿Está PostgreSQL corriendo?"
    exit 1
fi

info "Archivo de configuración encontrado en: $PG_CONF"

# 3. Backup de configuración
info "Creando respaldo de la configuración original..."
sudo cp "$PG_CONF" "$PG_CONF.bak_$(date +%F_%H-%M-%S)"

# 4. Inyectar configuración
info "Aplicando configuración de Hardware y WAL..."

# Usamos 'cat <<EOF' para agregar el bloque de texto al final del archivo
# Nota: PostgreSQL toma el último valor leído si hay duplicados, por lo que esto sobrescribe los defaults.
sudo bash -c "cat >> $PG_CONF" << 'EOF'

# ----------------------------------------
# OPTIMIZACIÓN AUTOMÁTICA (SCRIPT)
# ----------------------------------------

# Hardware del servidor
max_connections = 300
shared_buffers = 1GB
effective_cache_size = 3GB
maintenance_work_mem = 256MB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200
work_mem = 3404kB
huge_pages = off
min_wal_size = 2GB
max_wal_size = 8GB

# WAL Archiving
archive_mode = on
archive_command = 'cp %p /archives/wal/%f'

# ----------------------------------------
EOF

info "Configuración inyectada correctamente."

# 5. Reiniciar servicio
info "Reiniciando servicio PostgreSQL para aplicar cambios..."
if ! sudo systemctl restart postgresql; then
    warn "Fallo al reiniciar con systemctl. Intentando con service..."
    sudo service postgresql restart
fi

# 6. Validar que levantó
info "Validando estado del servicio..."
sleep 5 # Damos unos segundos para que arranque
if sudo -u postgres psql -c "SELECT 1;" &>/dev/null; then
    info "PostgreSQL se reinició y está aceptando conexiones con la nueva configuración."
else
    error_log "PostgreSQL no responde tras el reinicio. Revisa el archivo $PG_CONF."
    # Opcional: Restaurar backup si falla
    warn "Para restaurar el backup ejecuta: sudo cp $PG_CONF.bak... $PG_CONF"
    exit 1
fi

# ------------------------------------------
# --- PASO 6: IMPORTACIÓN DE LA BASE DE DATOS Y DATOS INICIALES ---
# ------------------------------------------

confirmar "Clonar repo privado, importar estructura (db.sql) y datos (real_data.sql)"

# 1. Instalar Git si no existe
if ! command -v git &> /dev/null; then
    info "Instalando git..."
    sudo apt install git -y
fi

# 2. Solicitar credenciales de forma segura
echo -e "${YELLOW}🔒 Este repositorio es PRIVADO.${NC}"
echo -e "Necesitas un GitHub Personal Access Token (Classic o Fine-grained)."
echo -e "Si no tienes uno, genéralo en: https://github.com/settings/tokens"

echo -n "Introduce tu GitHub Token (no se verá al escribir): "
read -s GITHUB_TOKEN
echo "" # Salto de línea estético

if [ -z "$GITHUB_TOKEN" ]; then
    error_log "No se ingresó un token. No se puede descargar la base de datos."
    exit 1
fi

REPO_URL="https://$GITHUB_TOKEN@github.com/Dani19866/santosysantosca-BD.git"
TEMP_DIR="/tmp/db_installer_$(date +%s)"

# 3. Clonar el repositorio
info "Clonando repositorio en directorio temporal..."
if git clone -q "$REPO_URL" "$TEMP_DIR"; then
    info "Repositorio descargado correctamente."
else
    error_log "Fallo al clonar. Verifica tu TOKEN o permisos en el repositorio."
    exit 1
fi

# 4. Ejecutar db.sql (Estructura)
SQL_STRUCTURE="$TEMP_DIR/db.sql"
SQL_DATA="$TEMP_DIR/real_data.sql"

if [ -f "$SQL_STRUCTURE" ]; then
    info "1/2 Archivo de estructura 'db.sql' encontrado. Importando..."
    
    # --- SOLICITUD DE CONTRASEÑAS PARA ROLES DE BD ---
    info "Se detectó configuración de usuarios en db.sql. Solicitando contraseñas..."
    
    echo -e "${YELLOW}🔐 CONFIGURACIÓN DE USUARIOS DE BASE DE DATOS${NC}"
    echo "Introduce contraseñas para los siguientes roles:"
    echo ""
    
    # admin_user
    echo -n "Contraseña para 'admin_user' (no será visible): "
    read -s PASS_ADMIN
    echo ""
    
    # operator_user
    echo -n "Contraseña para 'operator_user' (no será visible): "
    read -s PASS_OPERATOR
    echo ""
    
    # reader_user
    echo -n "Contraseña para 'reader_user' (no será visible): "
    read -s PASS_READER
    echo ""
    
    # scheduler_user
    echo -n "Contraseña para 'scheduler_user' (no será visible): "
    read -s PASS_SCHEDULER
    echo ""
    
    # --- VALIDACIÓN BÁSICA ---
    if [ -z "$PASS_ADMIN" ] || [ -z "$PASS_OPERATOR" ] || [ -z "$PASS_READER" ] || [ -z "$PASS_SCHEDULER" ]; then
        error_log "Una o más contraseñas están vacías. No se puede continuar."
        exit 1
    fi
    
    # --- CREAR ARCHIVO SQL TEMPORAL CON CONTRASEÑAS SUSTITUIDAS ---
    SQL_STRUCTURE_TEMP="$TEMP_DIR/db_temp.sql"
    info "Generando archivo SQL con contraseñas sustituidas..."
    
    # Leer el archivo original y reemplazar los placeholders
    cat "$SQL_STRUCTURE" | \
        sed "s|<CONTRASEÑA>|'${PASS_ADMIN}'|g; 0,/'${PASS_ADMIN}'/s/'${PASS_ADMIN}'/$(echo "${PASS_ADMIN}" | sed 's/[\/&]/\\&/g')/; 0~3s/'${PASS_ADMIN}'/$(echo "${PASS_OPERATOR}" | sed 's/[\/&]/\\&/g')/; 0~4s/'${PASS_ADMIN}'/$(echo "${PASS_READER}" | sed 's/[\/&]/\\&/g')/; 0~5s/'${PASS_ADMIN}'/$(echo "${PASS_SCHEDULER}" | sed 's/[\/&]/\\&/g')/" > "$SQL_STRUCTURE_TEMP" || {
        # Método alternativo más robusto si sed falla
        awk -v a="${PASS_ADMIN}" -v o="${PASS_OPERATOR}" -v r="${PASS_READER}" -v s="${PASS_SCHEDULER}" '
            NR == 1 { count = 0 }
            {
                if (/<CONTRASEÑA>/ && count == 0) {
                    gsub(/<CONTRASEÑA>/, "'"'"'" a "'"'"'")
                    count++
                } else if (/<CONTRASEÑA>/ && count == 1) {
                    gsub(/<CONTRASEÑA>/, "'"'"'" o "'"'"'")
                    count++
                } else if (/<CONTRASEÑA>/ && count == 2) {
                    gsub(/<CONTRASEÑA>/, "'"'"'" r "'"'"'")
                    count++
                } else if (/<CONTRASEÑA>/ && count == 3) {
                    gsub(/<CONTRASEÑA>/, "'"'"'" s "'"'"'")
                    count++
                }
                print
            }
        ' "$SQL_STRUCTURE" > "$SQL_STRUCTURE_TEMP"
    }
    
    info "Archivo SQL temporal generado: $SQL_STRUCTURE_TEMP"
    
    # --- EJECUTAR EL ARCHIVO SQL MODIFICADO ---
    if sudo -u postgres psql -f "$SQL_STRUCTURE_TEMP"; then
        info "Estructura de Base de Datos importada exitosamente."
        
        # 5. Ejecutar real_data.sql (Datos) - SOLO si la estructura pasó (o si existe)
        if [ -f "$SQL_DATA" ]; then
            info "2/2 Archivo de datos 'real_data.sql' encontrado. Insertando datos..."
            
            if sudo -u postgres psql -f "$SQL_DATA"; then
                info "Datos iniciales cargados exitosamente."
            else
                error_log "Hubo errores al insertar los datos de 'real_data.sql'."
                read -p "Hubo errores en la carga de datos. ¿Deseas continuar? (y/n): " -n 1 -r
                echo ""
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    exit 1
                fi
            fi
        else
            warn "El archivo 'real_data.sql' no existe en el repositorio. La BD está vacía de datos."
        fi
        
    else
        error_log "Hubo errores durante la creación de la estructura (db.sql)."
        read -p "Hubo errores críticos en el SQL. ¿Deseas continuar de todas formas? (y/n): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
else
    error_log "No se encontró el archivo 'db.sql' dentro del repositorio."
    warn "Contenido descargado:"
    ls -l "$TEMP_DIR"
    exit 1
fi

info "Eliminando archivos temporales..."
rm -rf "$TEMP_DIR"

info "Reiniciando PostgreSQL para asegurar persistencia..."

if pidof systemd >/dev/null; then
    sudo systemctl restart postgresql
else
    warn "Entorno sin Systemd detectado (WSL/Docker). Usando método 'service'..."
    if ! sudo service postgresql restart; then
         sudo /etc/init.d/postgresql restart
    fi
fi

info "Verificando estado final..."
sudo -u postgres psql -c "SELECT version();" || error_log "No se pudo conectar a PostgreSQL."

# ------------------------------------------
# --- PASO 7: INSTALACIÓN DE APACHE2 ---
# ------------------------------------------

confirmar "Instalar Servidor Web Apache2 y habilitar servicio"

info "Instalando paquete apache2..."
if sudo apt install apache2 -y; then
    info "Apache2 instalado correctamente."
else
    error_log "Error al instalar Apache2."
    exit 1
fi

info "Configurando arranque y estado del servicio..."

# Lógica híbrida para Systemd (Server) vs SysVinit (WSL)
if pidof systemd >/dev/null; then
    # Entorno Servidor estándar
    info "Detectado Systemd. Habilitando servicio al arranque..."
    sudo systemctl enable apache2
    
    info "Iniciando servicio..."
    sudo systemctl start apache2
    
    info "Estado del servicio:"
    sudo systemctl status apache2 --no-pager
else
    # Entorno WSL / Docker
    warn "Entorno sin Systemd (WSL). Usando SysVinit..."
    
    # Equivalente a 'enable' para sistemas antiguos/WSL
    sudo update-rc.d apache2 defaults || warn "No se pudo agregar al inicio automático (update-rc.d)."
    
    info "Iniciando servicio manualmente..."
    sudo service apache2 start || sudo /etc/init.d/apache2 start
    
    # Verificación manual de estado
    if service apache2 status > /dev/null; then
        info "Apache2 está corriendo."
    else
        warn "El comando 'service apache2 status' no retornó éxito, verificando procesos..."
    fi
fi

# Validación final de funcionamiento
info "Validando que Apache esté escuchando en el puerto 80..."

# Esperamos un momento a que levante
sleep 2

if ss -tuln | grep -q ":80 "; then
    info "✅ Puerto 80 detectado en escucha."
elif netstat -tuln | grep -q ":80 "; then
    # Fallback por si 'ss' no está instalado o difiere
    info "✅ Puerto 80 detectado en escucha."
else
    error_log "Apache no parece estar escuchando en el puerto 80."
    warn "Revisa si hay otro servicio ocupando el puerto o si Apache falló al arrancar."
    # Preguntamos si quiere continuar a pesar del error
    read -p "Apache no responde. ¿Deseas detener el script? (y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# ------------------------------------------
# --- PASO 8: CONFIGURACIÓN DE DIRECTORIOS WEB ---
# ------------------------------------------

confirmar "Crear directorios web (/var/www/...) y asignar permisos restrictivos"

# Lista de directorios a crear
WEB_DIRS=(
    "/var/www/santosysantosca"
    "/var/www/api"
    "/var/www/panel"
)

info "Verificando existencia del usuario 'www-data'..."
if ! id "www-data" &>/dev/null; then
    error_log "El usuario 'www-data' no existe. Asegúrate de que Apache se instaló correctamente."
    exit 1
fi

info "Iniciando configuración de directorios..."

for DIR in "${WEB_DIRS[@]}"; do
    # 1. Crear el directorio
    if [ ! -d "$DIR" ]; then
        info "Creando directorio: $DIR"
        sudo mkdir -p "$DIR"
    else
        info "El directorio ya existe: $DIR (Se actualizarán permisos)"
    fi

    # 2. Asignar propietario recursivo
    if sudo chown -R www-data:www-data "$DIR"; then
        echo -n "   -> Propietario asignado (www-data). "
    else
        error_log "Fallo al asignar propietario en $DIR"
        exit 1
    fi

    # 3. Asignar permisos recursivos (700)
    # Nota: 700 significa que SOLO el usuario www-data puede leer/escribir/ejecutar.
    # Ni el grupo ni otros usuarios podrán entrar (seguridad alta).
    if sudo chmod -R 700 "$DIR"; then
        echo "Permisos (700) aplicados."
    else
        error_log "Fallo al asignar permisos en $DIR"
        exit 1
    fi
done

info "Validación de permisos finales:"
ls -ld "${WEB_DIRS[@]}"

info "Estructura de directorios web configurada correctamente."

# ------------------------------------------
# --- PASO 9: DESPLIEGUE DE FRONTEND Y BACKEND ---
# ------------------------------------------
confirmar "Descargar Frontend (Astro) y configurar Backend (FastAPI + Venv)"

# 9.1 FRONTEND (ASTRO - ESTÁTICO)
DIR_FRONT="/var/www/santosysantosca"
REPO_FRONT="https://$GITHUB_TOKEN@github.com/Dani19866/santosysantosca.com.git"

info "--- Desplegando Frontend ---"

# Limpiamos directorio por si acaso (para git clone)
# Usamos sudo -u www-data porque el directorio tiene permisos 700 para él
info "Limpiando directorio destino: $DIR_FRONT"
sudo -u www-data rm -rf "${DIR_FRONT:?}/"* "${DIR_FRONT:?}/".* 2>/dev/null || true

info "Clonando repositorio Frontend..."
if sudo -u www-data git clone -q "$REPO_FRONT" "$DIR_FRONT"; then
    info "Frontend descargado correctamente."
else
    error_log "Fallo al clonar Frontend. Verifica si el repo existe o el token."
    exit 1
fi

# ------------------------------------------
# --- PASO 10: DESCARGA DE BACKEND Y CONFIGURACIÓN DE VARIABLES ---
# ------------------------------------------
confirmar "Descargar Backend y configurar variables de entorno (.env)"

# 1. VERIFICACIÓN DE CREDENCIALES (NUEVO BLOQUE DE SEGURIDAD)
# Si por alguna razón la variable GITHUB_TOKEN se perdió, la pedimos de nuevo
if [ -z "$GITHUB_TOKEN" ]; then
    warn "La variable GITHUB_TOKEN no está definida en este momento."
    echo -e "Es necesario el Token para descargar el repositorio privado."
    echo -n "Por favor, introduce tu GitHub Token nuevamente: "
    read -s GITHUB_TOKEN
    echo ""
    
    if [ -z "$GITHUB_TOKEN" ]; then
        error_log "No se ingresó ningún token. Cancelando operación."
        exit 1
    fi
fi

DIR_API="/var/www/api"
# Construimos la URL asegurándonos de que el token esté limpio
REPO_API="https://${GITHUB_TOKEN}@github.com/Dani19866/santosysantosca.com-API.git"

# 2. DESCARGA DEL CÓDIGO
info "Limpiando directorio destino: $DIR_API"
sudo -u www-data rm -rf "${DIR_API:?}/"* "${DIR_API:?}/".* 2>/dev/null || true

info "Clonando repositorio Backend..."

# Usamos una subshell ( ) o redirección para evitar que el token quede en el historial de bash si falla
if sudo -u www-data git clone -q "$REPO_API" "$DIR_API"; then
    info "✅ Backend descargado correctamente."
else
    # Si falla, borramos el directorio para no dejar basura y mostramos ayuda
    sudo -u www-data rm -rf "$DIR_API"
    error_log "Fallo al clonar Backend."
    warn "Posibles causas:"
    echo "  - El Token introducido es incorrecto o ha expirado."
    echo "  - El usuario del token no tiene permisos sobre el repositorio 'santosysantosca.com-API'."
    echo "  - La URL del repositorio está mal escrita."
    exit 1
fi

# 3. SOLICITUD DE VARIABLES DE ENTORNO
info "--- Configuración de Variables de Entorno (.env) ---"
echo "Presiona ENTER para aceptar el valor por defecto mostrado en [corchetes]."

# --- BASE DE DATOS ---
read -p "HOST de PostgreSQL [localhost]: " IN_HOST
HOST=${IN_HOST:-localhost}

read -p "PORT de PostgreSQL [5432]: " IN_PORT
PORT=${IN_PORT:-5432}

read -p "USERNAME de PostgreSQL [postgres]: " IN_USER
USERNAME=${IN_USER:-postgres}

echo -n "PASSWORD de PostgreSQL: "
read -s IN_PASS
echo "" 
PASSWORD=$IN_PASS

read -p "DATABASE Nombre [santosysantosca]: " IN_DB
DATABASE=${IN_DB:-santosysantosca}

# --- CONFIGURACIÓN API ---
read -p "PRODUCTION (True/False) [True]: " IN_PROD
PRODUCTION=${IN_PROD:-True}

read -p "USER_CREATION_API (True/False) [False]: " IN_USER_CREATE
USER_CREATION_API=${IN_USER_CREATE:-False}

# --- SEGURIDAD ---
SUGGESTED_KEY=$(openssl rand -hex 32)
echo "Sugerencia para SECRET_KEY: $SUGGESTED_KEY"
read -p "SECRET_KEY [Usar sugerida]: " IN_KEY
SECRET_KEY=${IN_KEY:-$SUGGESTED_KEY}

read -p "ALGORITHM [HS256]: " IN_ALGO
ALGORITHM=${IN_ALGO:-HS256}

read -p "TOKEN_EXPIRE_MINUTES [1440]: " IN_EXPIRE
TOKEN_EXPIRE_MINUTES=${IN_EXPIRE:-1440}

# --- RATE LIMITER ---
read -p "RATE_LIMIT (solicitudes) [100]: " IN_LIMIT
RATE_LIMIT=${IN_LIMIT:-100}

read -p "PERIOD (segundos) [60]: " IN_PERIOD
PERIOD=${IN_PERIOD:-60}

read -p "CLEAN_INTERVAL (segundos) [3600]: " IN_CLEAN
CLEAN_INTERVAL=${IN_CLEAN:-3600}

# 4. GENERACIÓN DEL ARCHIVO
ENV_FILE="$DIR_API/.env"
info "Escribiendo archivo $ENV_FILE..."

sudo -u www-data bash -c "cat > '$ENV_FILE'" <<EOF
HOST=$HOST
PORT=$PORT
USERNAME=$USERNAME
PASSWORD=$PASSWORD
DATABASE=$DATABASE
PRODUCTION=$PRODUCTION
USER_CREATION_API=$USER_CREATION_API
SECRET_KEY=$SECRET_KEY
ALGORITHM=$ALGORITHM
TOKEN_EXPIRE_MINUTES=$TOKEN_EXPIRE_MINUTES
RATE_LIMIT=$RATE_LIMIT
PERIOD=$PERIOD
CLEAN_INTERVAL=$CLEAN_INTERVAL
EOF

sudo chmod 600 "$ENV_FILE"

info "✅ Archivo .env creado y protegido correctamente."

# ------------------------------------------
# --- PASO 11: INSTALACIÓN DE DEPENDENCIAS PYTHON ---
# ------------------------------------------

confirmar "Crear entorno virtual e instalar dependencias (requirements.txt)"

DIR_API="/var/www/api"

# 1. Instalación de paquetes del sistema necesarios
info "Verificando herramientas de Python del sistema..."
# Instalamos python3-venv y pip si no están
sudo apt-get install -y python3-venv python3-pip

# 2. Creación del Entorno Virtual
info "Creando entorno virtual (venv) en $DIR_API..."

# Verificamos si ya existe para no sobrescribir a lo bruto, o lo recreamos si se desea
if [ -d "$DIR_API/venv" ]; then
    warn "Ya existe una carpeta 'venv'. Se intentarán instalar dependencias sobre ella."
else
    # IMPORTANTE: Ejecutamos como www-data. 
    # Si lo haces como root, la app web luego no tendrá permisos para leer sus propias librerías.
    if sudo -u www-data python3 -m venv "$DIR_API/venv"; then
        info "Entorno virtual creado exitosamente."
    else
        error_log "Fallo al crear el entorno virtual. Verifica permisos de $DIR_API."
        exit 1
    fi
fi

# 3. Instalación de Dependencias
REQUIREMENTS="$DIR_API/requirements.txt"
PIP_BIN="$DIR_API/venv/bin/pip"

if [ -f "$REQUIREMENTS" ]; then
    info "Archivo requirements.txt encontrado."
    info "Instalando dependencias... (Esto puede tardar unos minutos)"

    # Actualizamos pip primero (buena práctica)
    sudo -u www-data "$PIP_BIN" install --upgrade pip

    # Instalamos las librerías
    # Usamos la ruta absoluta a pip dentro del venv ($PIP_BIN)
    if sudo -u www-data "$PIP_BIN" install -r "$REQUIREMENTS"; then
        info "Todas las dependencias se instalaron correctamente."
    else
        error_log "Hubo un error al instalar las dependencias."
        warn "Revisa si falta alguna librería del sistema (ej: libpq-dev para psycopg2)."
        
        read -p "¿Deseas intentar instalar 'libpq-dev' (driver postgres) y reintentar? (y/n): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo apt-get install -y libpq-dev build-essential
            info "Reintentando instalación de dependencias..."
            sudo -u www-data "$PIP_BIN" install -r "$REQUIREMENTS" || exit 1
        else
            exit 1
        fi
    fi
else
    error_log "No se encontró el archivo $REQUIREMENTS."
    warn "Asegúrate de que el repositorio se descargó correctamente en el paso anterior."
    exit 1
fi

# 4. Validación Final
info "Verificando paquetes instalados..."
sudo -u www-data "$PIP_BIN" list

# ------------------------------------------
# --- PASO 12: HARDENING Y CONFIGURACIÓN BASE DE APACHE ---
# ------------------------------------------

confirmar "Instalar módulos de seguridad y configurar hardening (apache2.conf y security.conf)"

info "Instalando librería ModSecurity..."
sudo apt install libapache2-mod-security2 -y

info "Habilitando módulos requeridos..."
# Se habilitan todos los módulos solicitados
MODULES="http2 ssl headers cache cache_disk ratelimit security2 brotli unique_id"
sudo a2enmod $MODULES

info "Reiniciando Apache para cargar módulos..."
# Reinicio compatible con WSL/Systemd
if pidof systemd >/dev/null; then
    sudo systemctl restart apache2
else
    sudo service apache2 restart
fi

# 1. Configuración de apache2.conf
CONF_MAIN="/etc/apache2/apache2.conf"
info "Aplicando configuración de rendimiento en $CONF_MAIN..."

# Hacemos un backup
sudo cp $CONF_MAIN "$CONF_MAIN.bak"

# Agregamos las directivas al final del archivo
sudo bash -c "cat >> $CONF_MAIN" <<EOF

# --- CONFIGURACIÓN DE DESPLIEGUE ---
# Activamos las conexiones persistentes
KeepAlive On
# Limitar el número de solicitudes
MaxKeepAliveRequests 500
# Tiempo de espera
KeepAliveTimeout 5
EOF

# 2. Configuración de security.conf
CONF_SEC="/etc/apache2/conf-available/security.conf"
info "Sobrescribiendo $CONF_SEC con políticas estrictas..."

sudo cp $CONF_SEC "$CONF_SEC.bak"

sudo bash -c "cat > $CONF_SEC" <<EOF
# --- HARDENING SECURITY.CONF ---
ServerTokens Prod
ServerSignature Off
TraceEnable Off
Options None
LimitRequestBody 10485760
Timeout 25

# Configuración SSL
SSLProtocol -all +TLSv1.2 +TLSv1.3
SSLOpenSSLConfCmd Curves X25519:prime256v1:secp384r1
SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305
SSLHonorCipherOrder Off
SSLSessionTickets Off

<IfModule mod_headers.c>
    Header always set X-Xss-Protection "1; mode=block"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    Header always set X-Content-Type-Options "nosniff"
    # Ajustamos CSP para permitir carga de scripts locales y HTTPS
    Header always set Content-Security-Policy "default-src https: 'unsafe-inline'; connect-src 'self'; frame-src 'self';"
</IfModule>
EOF

info "Configuración base aplicada."

# ------------------------------------------
# --- PASO 13: CONFIGURACIÓN AVANZADA DE MODSECURITY (OWASP CRS) ---
# ------------------------------------------

confirmar "Instalar y configurar OWASP Core Rule Set (ModSecurity) desde URL específica"

# 1. Dependencias y Repositorios
info "Instalando dependencias y repositorio PPA..."
sudo apt install gnupg2 software-properties-common curl wget git unzip -y
sudo add-apt-repository ppa:ondrej/apache2 -y
sudo apt update -y
sudo apt install apache2 libapache2-mod-security2 -y

# 2. Configuración inicial de ModSecurity
info "Configurando ModSecurity..."
sudo a2enmod security2

if [ -f "/etc/modsecurity/modsecurity.conf-recommended" ]; then
    sudo mv /etc/modsecurity/modsecurity.conf-recommended /etc/modsecurity/modsecurity.conf
fi

info "Activando SecRuleEngine..."
sudo sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/modsecurity/modsecurity.conf

# 3. Descarga e Instalación de OWASP CRS (Versión Solicitada)
# Usamos exactamente la URL que pediste
URL_CRS="https://codeload.github.com/coreruleset/coreruleset/tar.gz/refs/tags/v4.22.0"
DIR_CRS_BASE="/etc/apache2/modsecurity-crs"

info "Descargando OWASP CRS desde: $URL_CRS"

# Limpiamos destino previo
sudo rm -rf "$DIR_CRS_BASE"
sudo mkdir -p "$DIR_CRS_BASE"

# Descargamos
if wget -O /tmp/crs.tar.gz "$URL_CRS"; then
    info "Descarga exitosa. Descomprimiendo..."
    sudo tar xvf /tmp/crs.tar.gz -C "$DIR_CRS_BASE"
else
    error_log "Fallo al descargar la versión especificada en la URL."
    warn "Verifica si la versión v4.22.0 existe en el repositorio oficial."
    exit 1
fi

# IMPORTANTE: Detección dinámica de carpeta
# Como descargamos un tar.gz, no sabemos si la carpeta se llamará 'coreruleset-3.3.0' o 'coreruleset-4.22.0'
# Buscamos la carpeta que se acaba de crear dentro de /etc/apache2/modsecurity-crs/
CRS_PATH=$(sudo find "$DIR_CRS_BASE" -maxdepth 1 -type d -name "coreruleset-*" | head -n 1)

if [ -d "$CRS_PATH" ]; then
    info "Carpeta de reglas detectada en: $CRS_PATH"
    
    # Renombramos el archivo de configuración de ejemplo
    sudo mv "$CRS_PATH/crs-setup.conf.example" "$CRS_PATH/crs-setup.conf"
    
    # 4. Vinculación con Apache (security2.conf)
    FILE_SEC2="/etc/apache2/mods-enabled/security2.conf"
    info "Actualizando $FILE_SEC2..."

    sudo bash -c "cat > $FILE_SEC2" <<EOF
<IfModule security2_module>
    SecDataDir /var/cache/modsecurity
    IncludeOptional /etc/modsecurity/*.conf
    
    # OWASP CRS Configuration
    IncludeOptional $CRS_PATH/crs-setup.conf
    IncludeOptional $CRS_PATH/rules/*.conf
</IfModule>
EOF
else
    error_log "No se pudo detectar la carpeta descomprimida del CRS."
    exit 1
fi

# 5. Ajustes del Kernel
info "Aplicando protección TCP Syncookies..."
sudo sysctl -w "net.ipv4.tcp_syncookies=1"

# 6. Verificación Final
info "Verificando configuración de Apache..."
if sudo apache2ctl -t; then
    info "Sintaxis Correcta. Reiniciando servicio..."
    sudo systemctl restart apache2
    info "✅ ModSecurity (OWASP CRS) configurado correctamente."
else
    error_log "Error de sintaxis en Apache."
    exit 1
fi

# ------------------------------------------
# PASO 14: CONFIGURACIÓN Y ARRANQUE DEL SERVICIO SYSTEMD
# ------------------------------------------

confirmar "Configuración y Arranque del Servicio Systemd (Hypercorn)"

# Variables locales para este paso
SERVICE_NAME="santos_api.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
APP_DIR="/var/www/api"

info "Generando archivo de servicio en: $SERVICE_PATH"

# Usamos 'sudo bash -c' para tener permisos de escritura en /etc/systemd/system
sudo bash -c "cat <<EOF > $SERVICE_PATH
[Unit]
Description=FastAPI application (Hypercorn)
After=network.target

[Service]
# 1. SEGURIDAD: Usamos un usuario sin privilegios
User=www-data
Group=www-data

# 2. DIRECTORIO: Mantenemos el padre para que funcionen los imports
WorkingDirectory=/var/www
EnvironmentFile=$APP_DIR/.env

# 3. EJECUCIÓN: 
# - Bind a 127.0.0.1 (Localhost) para seguridad
# - Workers 4 y Keep-alive 5
ExecStart=$APP_DIR/venv/bin/hypercorn api.main:app --bind 127.0.0.1:8000 --workers 4 --keep-alive 5

# Reinicio automático si falla
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

info "Ajustando permisos y seguridad de carpetas..."

# 1. Asegurar __init__.py para modo paquete
if [ ! -f "$APP_DIR/__init__.py" ]; then
    sudo touch "$APP_DIR/__init__.py"
    info "Archivo __init__.py creado."
fi

# 2. Asignar propiedad a www-data (usuario que ejecuta el servicio)
sudo chown -R www-data:www-data "$APP_DIR"

# 3. Permisos estrictos: Dueño(7), Grupo(5), Otros(0)
sudo chmod -R 750 "$APP_DIR"

info "Permisos aplicados correctamente (750)."

info "Activando servicio en Systemd..."

# Recargar configuración de systemd
sudo systemctl daemon-reload

# Habilitar servicio al inicio
sudo systemctl enable $SERVICE_NAME

# Reiniciar servicio para aplicar cambios
sudo systemctl restart $SERVICE_NAME

# --- VERIFICACIÓN DE ESTADO ---
info "Verificando estado del servicio..."
sleep 2 # Esperamos un momento para dar tiempo a que arranque o falle

if sudo systemctl is-active --quiet $SERVICE_NAME; then
    info "🚀 ÉXITO: El servicio $SERVICE_NAME está corriendo (Active)."
else
    error_log "❌ FALLO: El servicio no pudo arrancar."
    warn "Mostrando las últimas 10 líneas del log para depuración:"
    sudo journalctl -u $SERVICE_NAME -n 10 --no-pager
    
    # Esto provocará la salida y activará la función on_error
    exit 1
fi

confirmar "Configuración del Proxy Inverso en Apache (api.conf)"

API_CONF="/etc/apache2/sites-available/api.conf"

info "1. Habilitando módulos de proxy..."
sudo a2enmod proxy proxy_http

info "2. Creando configuración del VirtualHost..."
sudo bash -c "cat <<EOF > $API_CONF
<VirtualHost *:80>
    ServerAdmin deoliveiradaniel200@gmail.com
    ServerName api.santosysantosca.com
    ServerAlias api.santosysantosca.com

    # --- PROXY INVERSO ---
    # Preservamos el Host original para que FastAPI sepa el dominio real
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:8000/
    ProxyPassReverse / http://127.0.0.1:8000/

    ErrorLog \${APACHE_LOG_DIR}/api-error.log
    CustomLog \${APACHE_LOG_DIR}/api-access.log combined
</VirtualHost>
EOF"

info "3. Gestionando sitios de Apache..."

# Desactivamos el sitio por defecto para evitar conflictos
if [ -f /etc/apache2/sites-enabled/000-default.conf ]; then
    warn "Desactivando el sitio por defecto '000-default'..."
    sudo a2dissite 000-default.conf
fi

# Habilitamos nuestro sitio
sudo a2ensite api.conf

info "4. Verificando y Recargando Apache..."

if sudo apache2ctl -t; then
    info "✅ Sintaxis Correcta."
    sudo systemctl restart apache2
    info "🚀 Apache reiniciado." 
    echo -e "${GREEN}AHORA PRUEBA TU DOMINIO:${NC} http://api.santosysantosca.com"
    echo "Ya no deberías necesitar agregar :8000 al final."
else
    error_log "❌ ERROR DE SINTAXIS EN APACHE."
    exit 1
fi

# ==============================================================================
# PASO 14: INSTALACIÓN DE CERTIFICADOS SSL (CERTBOT / LET'S ENCRYPT)
# ==============================================================================

confirmar "Instalación de SSL (HTTPS) con Certbot"

info "1. Instalando dependencias de Certbot..."
# -y acepta automáticamente
sudo apt install certbot python3-certbot-apache -y

info "2. Solicitando certificados SSL..."
warn "IMPORTANTE: Si estás en WSL/Local, este paso fallará (es normal)."
warn "En Producción (AWS), Certbot te pedirá un email. Atento a la consola."

# Ejecutamos Certbot para TODOS los dominios (incluyendo el .com raíz)
# Usamos '|| true' para que el fallo en local no detenga el script.
sudo certbot --apache \
    -d santosysantosca.com \
    -d santosysantosca.ve \
    -d panel.santosysantosca.com \
    -d api.santosysantosca.com || warn "⚠️ Certbot no pudo validar (Esperado en Local/WSL)."

info "3. Verificando simulacro de renovación (Dry Run)..."
sudo certbot renew --dry-run || warn "Falló el test de renovación (Esperado en Local)."

info "4. Verificando tareas programadas (Crontab)..."
sudo crontab -l || info "No se listaron crontabs."


# ==============================================================================
# PASO 15: PROGRAMADOR DE TAREAS (EJECUCIÓN DE FUNCIÓN SQL)
# ==============================================================================

confirmar "Configuración del Programador de Tareas (scheduler_user)"

# --- CONFIGURACIÓN ---
INTERVALO_EJECUCION="3min"
DB_USER="scheduler_user"
DB_NAME="santosysantosca"
SERVICE_NAME="santos_scheduler.service"
TIMER_NAME="santos_scheduler.timer"

info "1. Configurando credenciales..."

# Solicitamos la contraseña al usuario (input oculto)
echo -e "${YELLOW}⚠️  ATENCIÓN:${NC}"
echo -n "Introduce la contraseña para el usuario de BD '$DB_USER': "
read -s DB_PASS
echo "" # Salto de línea

# Verificación básica
if [ -z "$DB_PASS" ]; then
    error_log "La contraseña no puede estar vacía. Abortando paso."
    exit 1
fi

info "2. Creando servicio de ejecución (Systemd)..."

# Inyectamos la variable $DB_PASS directamente en el archivo del servicio
sudo bash -c "cat <<EOF > /etc/systemd/system/$SERVICE_NAME
[Unit]
Description=Ejecuta process_sensor_batches() como $DB_USER
After=postgresql.service network.target

[Service]
Type=oneshot
User=www-data
Group=www-data

# Aquí queda guardada la contraseña que acabas de escribir
Environment=PGPASSWORD=$DB_PASS

# Ejecución forzando localhost (-h 127.0.0.1) para usar la contraseña
ExecStart=/usr/bin/psql -h 127.0.0.1 -U $DB_USER -d $DB_NAME -c \"SELECT santosysantosca.process_sensor_batches();\"

[Install]
WantedBy=multi-user.target
EOF"

info "3. Configurando el temporizador ($INTERVALO_EJECUCION)..."

sudo bash -c "cat <<EOF > /etc/systemd/system/$TIMER_NAME
[Unit]
Description=Ejecuta el Scheduler cada $INTERVALO_EJECUCION

[Timer]
OnBootSec=1min
OnUnitActiveSec=$INTERVALO_EJECUCION
Unit=$SERVICE_NAME

[Install]
WantedBy=timers.target
EOF"

info "4. Activando el programador..."

sudo systemctl daemon-reload
sudo systemctl enable $TIMER_NAME
sudo systemctl start $TIMER_NAME

if sudo systemctl is-active --quiet $TIMER_NAME; then
    info "⏱️  PROGRAMADOR ACTIVO: Se ejecutará cada $INTERVALO_EJECUCION."
else
    error_log "❌ Error al iniciar el temporizador."
    exit 1
fi

# ==============================================================================
# FIN DEL SCRIPT
# ==============================================================================

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}✅ ¡DESPLIEGUE FINALIZADO EXITOSAMENTE! 🚀${NC}"
echo -e "${GREEN}====================================================${NC}"
info "${GREEN}Resumen de accesos:"
echo " - ${GREEN}Principal:       http://santosysantosca.com"
echo " - ${GREEN}API (Backend):   http://api.santosysantosca.com"
echo " - ${GREEN}Panel:           http://panel.santosysantosca.com"
echo ""
echo "${GREEN}Comandos útiles:"
echo "${GREEN} > Ver logs API:    sudo journalctl -u santos_api -f"
echo "${GREEN} > Ver logs Timer:  sudo journalctl -u $SERVICE_NAME"