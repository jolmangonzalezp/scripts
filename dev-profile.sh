#!/usr/bin/env bash

# 1. Selección de Lenguaje/Framework (Informativo para el sistema)
lang=$(echo -e " Java /  Spring\n PHP /  Laravel\n TS /  Vue3\nNinguno" | wofi --dmenu --prompt "Selecciona el Lenguaje/Framework:" --width 400)

# 2. Selección de Base de Datos
db=$(echo -e " MariaDB\n PostgreSQL\n MongoDB\n MariaDB +  PostgreSQL\n MariaDB +  MongoDB\n PostgreSQL +  MongoDB\n MariaDB +  PostgreSQL +  MongoDB\nNinguna" | wofi --dmenu --prompt "Selecciona la Base de Datos:" --width 600)

# 3. Selección de Contenedorizador
container=$(echo -e " Docker\nNinguno" | wofi --dmenu --prompt "¿Usar contenedorizador?" --width 400)

cleanup=$(echo -e "Sí, limpiar logs\nNo, mantener logs" | wofi --dmenu --prompt "¿Limpiar logs de bases de datos antes de iniciar?" --width 400)

# --- Lógica de Limpieza ---
if [[ "$cleanup" == "Sí, limpiar logs" ]]; then
    notify-send "🧹 Limpiando Logs" "Preparando un entorno limpio..."
    
    # Limpiar el Journal de systemd (solo logs de las DBs para ser específicos)
    pkexec journalctl --vacuum-time=1s > /dev/null 2>&1
    
    # Truncar logs específicos si existen (evita que crezcan en Btrfs)
    [ -f /var/log/mysql/error.log ] && pkexec truncate -s 0 /var/log/mysql/error.log
    [ -f /var/log/postgresql/postgresql.log ] && pkexec truncate -s 0 /var/log/postgresql/postgresql.log
    [ -f /var/log/mongodb/mongodb.log ] && pkexec truncate -s 0 /var/log/mongodb/mongodb.log
fi

# --- Lógica de Activación ---
# Activar Base de Datos
case $db in
    " MariaDB") notify-send "Iniciando $db" && pkexec systemctl start mariadb ;;
    " PostgreSQL") notify-send "Iniciando $db" && pkexec systemctl start postgresql ;;
    " MongoDB") notify-send "Iniciando $db" && pkexec systemctl start mongodb ;;
    " MariaDB +  PostgreSQL") notify-send "Iniciando $db" && pkexec systemctl start mariadb postgresql ;;
    " MariaDB +  MongoDB") notify-send "Iniciando $db" && pkexec systemctl start postgresql mongo ;;
    " PostgreSQL +  MongoDB") notify-send "Iniciando $db" && pkexec systemctl start postgresql mongo ;;
    " MariaDB +  PostgreSQL +  MongoDB") notify-send "Iniciando $db" && pkexec systemctl start mariadb postgresql mongo ;;
esac

# Activar Contenedorizador
case $container in
    " Docker") pkexec systemctl start docker ;;
esac

# Notificación Final
notify-send "🛠️ Entorno Configurado" "Stack: $lang\nDB: $db\nContainer: $container"