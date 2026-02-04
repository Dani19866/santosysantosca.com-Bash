
# Guía técnica del script de aprovisionamiento

Este documento describe en detalle el funcionamiento, requisitos, pasos y consideraciones del script [setup_server.sh](setup_server.sh). Está orientado a ingeniería y DevOps para la preparación de una VM en la nube, con foco en seguridad, base de datos, servicios web y despliegue.

## 1) Descripción breve

El script automatiza la configuración inicial de un servidor Debian/Ubuntu para:

- Seguridad básica (UFW, hardening de Apache, ModSecurity + OWASP CRS).
- PostgreSQL 18 con tuning y configuración de WAL.
- Apache2 como servidor web y proxy inverso.
- Despliegue de frontend (Astro) y backend (FastAPI + Hypercorn).
- SSL con Certbot (Let's Encrypt).
- Programación de tareas con systemd timer.

Es interactivo: cada paso requiere confirmación explícita y puede detenerse si el usuario no acepta.

## 2) Requisitos previos

- Sistema operativo: Debian/Ubuntu (probado con apt). No diseñado para distros sin apt.
- Acceso sudo con privilegios administrativos.
- Conectividad a Internet.
- DNS y dominios apuntados correctamente (para SSL y virtual hosts).
- Token de GitHub con acceso a repos privados.
- Para producción, systemd debe estar disponible (no WSL).

## 3) Consideraciones importantes

- Interactivo: el script usa `confirmar` y no continúa sin aprobación.
- Seguridad: el firewall se activa temprano y abre puertos 22, 80 y 443.
- Credenciales sensibles: el token de GitHub y contraseñas se solicitan en consola.
- Algunas operaciones se comportan distinto en WSL/containers (sin systemd).
- El script agrega configuración al final de ciertos archivos (no limpia valores previos).

## 4) Paso a paso (resumen ejecutivo)

1. Actualiza repositorios apt.
2. Instala y configura UFW (SSH/80/443).
3. Instala PostgreSQL 18, inicia servicio y valida conexión.
4. Crea directorios para tablespaces.
5. Configura WAL + tuning de PostgreSQL.
6. Clona BD privada e importa estructura y datos.
7. Instala Apache2 y valida puerto 80.
8. Crea directorios web con permisos restrictivos.
9. Despliega frontend (Astro).
10. Descarga backend y genera variables .env.
11. Crea venv e instala dependencias Python.
12. Aplica hardening de Apache + módulos.
13. Instala y configura ModSecurity + OWASP CRS.
14. Crea servicio systemd para Hypercorn y configura proxy en Apache.
15. Configura SSL con Certbot.
16. Configura timer systemd para ejecución periódica de función SQL.

## 5) Paso a paso técnico (detallado)

### Paso 1: Actualización de repositorios
- Ejecuta `apt-get update -y`.
- Objetivo: asegurar repositorios actualizados antes de instalar paquetes.

### Paso 2: Firewall UFW
- Instala `ufw`.
- Default deny incoming, allow outgoing.
- Abre 22 (SSH), 80 (HTTP), 443 (HTTPS).
- Habilita UFW y valida con `systemctl status ufw`.

### Paso 3: PostgreSQL 18
- Instala `postgresql-common`.
- Agrega el repositorio oficial (pgdg).
- Instala `postgresql-18`.
- Arranque resiliente: intenta systemd y luego SysV init.
- Espera al socket `/var/run/postgresql/.s.PGSQL.5432`.
- Valida conexión con `psql -c "SELECT version();"`.

### Paso 4: Tablespaces
- Crea `/data/tbs_data` y `/index/tbs_index`.
- Ajusta propietario a `postgres:postgres` y permisos 700.
- Verifica con `ls -ld`.

### Paso 5: WAL + tuning PostgreSQL
- Crea `/archives/wal` con permisos 700 y dueño `postgres`.
- Detecta `postgresql.conf` con `SHOW config_file;`.
- Hace backup con timestamp.
- Inyecta parámetros de rendimiento y WAL al final del archivo.
- Reinicia el servicio y valida con `SELECT 1;`.

### Paso 6: Importación de BD
- Solicita token de GitHub.
- Clona repo privado con SQL.
- Ejecuta `db.sql` y luego `real_data.sql`.
- Limpia archivos temporales.
- Reinicia PostgreSQL y valida versión.

### Paso 7: Apache2
- Instala `apache2`.
- En systemd: `enable` y `start`.
- En WSL/SysVinit: `update-rc.d` y `service`.
- Verifica que el puerto 80 está escuchando con `ss` o `netstat`.

### Paso 8: Directorios web
- Crea `/var/www/santosysantosca`, `/var/www/api`, `/var/www/panel`.
- Propietario `www-data` y permisos 700.

### Paso 9: Frontend (Astro)
- Clona repo frontend en `/var/www/santosysantosca` usando token.
- Limpia el directorio previamente con permisos de `www-data`.

### Paso 10: Backend + .env
- Si el token no existe, lo solicita de nuevo.
- Clona repo backend en `/var/www/api`.
- Solicita variables de entorno y genera `.env`.
- Protege `.env` con permisos 600.

### Paso 11: Venv + dependencias
- Instala `python3-venv` y `python3-pip`.
- Crea venv con usuario `www-data`.
- Instala dependencias desde `requirements.txt`.
- Ofrece instalar `libpq-dev` si falla `psycopg2`.

### Paso 12: Hardening de Apache
- Instala `libapache2-mod-security2`.
- Habilita módulos: http2, ssl, headers, cache, cache_disk, ratelimit, security2, brotli, unique_id.
- Agrega configuración de rendimiento en apache2.conf.
- Sobrescribe security.conf con políticas estrictas (TLS, headers, CSP).

### Paso 13: ModSecurity + OWASP CRS
- Instala dependencias y PPA de Apache.
- Activa `SecRuleEngine On`.
- Descarga CRS v4.22.0, detecta carpeta y enlaza reglas.
- Ejecuta `apache2ctl -t` y reinicia.

### Paso 14: Servicio systemd + Proxy inverso
- Crea `santos_api.service` con Hypercorn en 127.0.0.1:8000.
- Ajusta permisos 750 en `/var/www/api`.
- Habilita y arranca el servicio, valida estado.
- Crea `api.conf` con `ProxyPass` y `ProxyPassReverse`.
- Deshabilita el sitio 000-default.
- Reinicia Apache.

### Paso 15: SSL con Certbot
- Instala Certbot para Apache.
- Solicita certificados para dominios principales y subdominios.
- Ejecuta dry-run de renovación.

### Paso 16: Timer systemd (scheduler)
- Solicita contraseña para `scheduler_user`.
- Crea servicio `santos_scheduler.service` que ejecuta una función SQL.
- Crea timer `santos_scheduler.timer` cada 3 minutos.
- Habilita y arranca el timer.

## 6) Detalles técnicos clave

- Control de errores: `set -e` y `set -o pipefail`.
- Rollback básico en `on_error` para firewall y PostgreSQL.
- Confirmación por paso: `confirmar`.
- Tokens y passwords se piden sin eco para reducir exposición.
- Configuración de PostgreSQL se agrega al final del archivo (última definición tiene prioridad).
- El backend se ejecuta como `www-data` para minimizar privilegios.
- Proxy inverso expone la API sin puerto explícito.

## 7) Servicios y archivos modificados

### Servicios
- UFW
- PostgreSQL 18
- Apache2
- Hypercorn (systemd service)
- Timer systemd (scheduler)

### Archivos importantes
- `/etc/postgresql/*/main/postgresql.conf` (tuning)
- `/etc/apache2/apache2.conf` (rendimiento)
- `/etc/apache2/conf-available/security.conf` (hardening)
- `/etc/apache2/mods-enabled/security2.conf` (CRS)
- `/etc/apache2/sites-available/api.conf` (proxy inverso)
- `/etc/systemd/system/santos_api.service`
- `/etc/systemd/system/santos_scheduler.service`
- `/etc/systemd/system/santos_scheduler.timer`
- `/var/www/api/.env`

## 8) Puertos utilizados

- 22: SSH
- 80: HTTP
- 443: HTTPS
- 5432: PostgreSQL (solo local)
- 8000: Hypercorn (bind a localhost)

## 9) Recomendaciones y mejoras sugeridas

- Validar dominios y DNS antes de Certbot.
- Usar secrets manager en lugar de tokens/contraseñas en consola.
- Separar entornos (dev/stage/prod) con variables gestionadas.
- Revisar tuning de PostgreSQL según RAM/CPU reales.
- Implementar backups automatizados y rotación de WAL.
- Añadir `fail2ban` y reglas específicas de UFW.
- Mantener CRS actualizado y ajustar reglas por falsos positivos.

## 10) Troubleshooting rápido

- PostgreSQL no arranca: revisar socket `/var/run/postgresql/.s.PGSQL.5432` y logs.
- Apache sin puerto 80: revisar `ss -tuln` y conflictos con otros servicios.
- Certbot falla en WSL: esperado; ejecutar solo en VM con DNS real.
- Servicio API no inicia: revisar `journalctl -u santos_api.service`.
- Timer no ejecuta: `systemctl list-timers` y `journalctl -u santos_scheduler.service`.

## 11) Seguridad operativa

- Rotar tokens de GitHub tras el despliegue.
- Restringir acceso SSH por IP o usar bastion.
- Habilitar actualizaciones automáticas de seguridad.
- Auditar permisos en `/var/www` y archivos de configuración.

## 12) Notas finales

- El script es interactivo y está diseñado para ser ejecutado por un operador humano.
- Se recomienda ejecutarlo paso a paso con supervisión, especialmente en producción.
- Ajusta los dominios en Apache y Certbot si cambian los FQDN.
﻿# README — setup_server.sh

Guía técnica para ingenieros y DevOps encargados del aprovisionamiento en la nube y el despliegue inicial de una VM. Este documento explica el flujo completo del script Bash setup_server.sh, detalla requisitos, decisiones técnicas y puntos críticos a considerar en producción.
