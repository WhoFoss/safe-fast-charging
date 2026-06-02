#!/system/bin/sh

MODDIR=${0%/*}

# ============================================================
# CONFIGURAÇÃO
# ============================================================
LOG=/data/local/tmp/safe_charging.log
TEMP_LIMIT=40          # °C — acima disso, reduz corrente
TEMP_RESUME=37         # °C — abaixo disso, restaura corrente
CURRENT_NORMAL=4000000   # µA — corrente máxima normal (4A)
CURRENT_THROTTLE=2000000 # µA — corrente reduzida (2A) quando quente
POLL_INTERVAL=30       # segundos entre cada leitura de temperatura

# Nós sysfs
NODE_FAST_CHARGE=/sys/kernel/fast_charge/force_fast_charge
NODE_MAX_CURRENT=/sys/class/power_supply/battery/constant_charge_current_max
NODE_INPUT_LIMITED=/sys/class/power_supply/battery/input_current_limited
NODE_STEP_CHARGING=/sys/class/power_supply/battery/step_charging_enabled
NODE_JEITA=/sys/class/power_supply/battery/sw_jeita_enabled
NODE_CHG_ENABLED=/sys/class/power_supply/battery/battery_charging_enabled
NODE_PD_ACTIVE=/sys/class/power_supply/battery/subsystem/usb/pd_active
NODE_RESTRICT=/sys/class/qcom-battery/restrict_chg
NODE_FSYNC=/sys/module/sync/parameters/fsync_enabled
NODE_POWER_EFF=/sys/module/workqueue/parameters/power_efficient

# Nós IIO do PMIC PM7250B (qpnp-smb5) — confirmados no sapphire
IIO_BASE=/sys/devices/platform/soc/1c40000.qcom,spmi/spmi-0/0-02/1c40000.qcom,spmi:qcom,pm7250b@2:qcom,qpnp-smb5/iio:device6
IIO_PD_ACTIVE=${IIO_BASE}/in_index_usb_pd_active_input
IIO_APSD_RERUN=${IIO_BASE}/in_activity_usb_apsd_rerun_input

# Zonas térmicas confirmadas no sapphire (SM6225)
# zone34 = battery       (~31°C em repouso)
# zone20 = charge-therm-usr  (sensor físico próximo ao carregador)
# zone23 = pm7250b-tz    (PMIC do carregador — fallback)
NODE_TEMP_BATTERY=/sys/class/thermal/thermal_zone34/temp
NODE_TEMP_CHARGER=/sys/class/thermal/thermal_zone20/temp
NODE_TEMP_PMIC=/sys/class/thermal/thermal_zone23/temp

# ============================================================
# FUNÇÕES UTILITÁRIAS
# ============================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

# Escreve em um nó sysfs somente se ele existir e for gravável
write_node() {
    local node="$1"
    local value="$2"
    if [ -e "$node" ]; then
        chmod 0777 "$node" 2>/dev/null
        if echo "$value" > "$node" 2>/dev/null; then
            log "[OK] $node = $value"
        else
            log "[WARN] Falha ao escrever $node = $value"
        fi
        chmod 0444 "$node" 2>/dev/null
    else
        log "[SKIP] $node não existe"
    fi
}

# Lê temperatura de um nó sysfs específico
# Retorna °C (inteiro) ou -1 em caso de falha
read_zone() {
    local zone="$1"
    [ -f "$zone" ] || { echo -1; return; }
    local raw
    raw=$(cat "$zone" 2>/dev/null)
    # Valida que é numérico
    case "$raw" in
        ''|*[!0-9-]*) echo -1; return ;;
    esac
    # Valores negativos absurdos (zone30/31 = -40000) → inválido
    [ "$raw" -lt 0 ] && { echo -1; return; }
    # Qualcomm reporta em milli°C quando > 1000
    if [ "$raw" -gt 1000 ]; then
        echo $((raw / 1000))
    else
        echo "$raw"
    fi
}

# Retorna a maior temperatura entre bateria e carregador
# Usar o máximo é mais conservador: throttle se qualquer um estiver quente
read_temp() {
    local t_bat t_chg t_pmic best

    t_bat=$(read_zone "$NODE_TEMP_BATTERY")
    t_chg=$(read_zone "$NODE_TEMP_CHARGER")
    t_pmic=$(read_zone "$NODE_TEMP_PMIC")

    # Escolhe o maior valor válido
    best=-1
    for t in "$t_bat" "$t_chg" "$t_pmic"; do
        [ "$t" -eq -1 ] && continue
        [ "$t" -gt "$best" ] && best=$t
    done

    echo "$best"
}

# ============================================================
# INICIALIZAÇÃO (executa uma vez no boot)
# ============================================================

log "========================================"
log "Módulo Carregamento Seguro — iniciando"
log "========================================"

# Fast charge (kernel franco — pode não existir)
write_node "$NODE_FAST_CHARGE" 1

# Corrente máxima normal
write_node "$NODE_MAX_CURRENT" "$CURRENT_NORMAL"

# Remove throttle artificial de input
write_node "$NODE_INPUT_LIMITED" 0

# Step charging — MANTIDO (longevidade da bateria)
write_node "$NODE_STEP_CHARGING" 1

# JEITA — MANTIDO (proteção térmica do kernel)
write_node "$NODE_JEITA" 1

# Garante que o carregamento está habilitado
write_node "$NODE_CHG_ENABLED" 1

# PD desabilitado (sapphire usa QC/AFC, não USB-PD nativo)
write_node "$NODE_PD_ACTIVE" 0

# Remove restrição de carga qcom (pode não existir)
write_node "$NODE_RESTRICT" 0

# FSYNC habilitado (proteção de dados)
if [ -f "$NODE_FSYNC" ]; then
    echo Y > "$NODE_FSYNC" 2>/dev/null && log "[OK] fsync habilitado"
fi

# Power efficient workqueue (economia de bateria)
if [ -f "$NODE_POWER_EFF" ]; then
    chmod 755 "$NODE_POWER_EFF" 2>/dev/null
    echo Y > "$NODE_POWER_EFF" 2>/dev/null && log "[OK] power_efficient workqueue habilitado"
    chmod 664 "$NODE_POWER_EFF" 2>/dev/null
fi

log "Inicialização concluída. Iniciando monitor térmico."
log "Limite: ${TEMP_LIMIT}°C | Retomada: ${TEMP_RESUME}°C"
log "Corrente normal: ${CURRENT_NORMAL} µA | Throttle: ${CURRENT_THROTTLE} µA"

# ============================================================
# CORREÇÃO HVDCP — desativa PD e força APSD rerun
# O LineageOS negocia USB-PD por padrão, conflitando com HVDCP
# e limitando o input para 100mA. Desativar PD via IIO e forçar
# redetecção do carregador restaura HVDCP2 (~2.9A de input).
# Delay de 30s para garantir que o USB stack já inicializou.
# ============================================================

(
    sleep 30
    if [ -e "$IIO_PD_ACTIVE" ] && [ -e "$IIO_APSD_RERUN" ]; then
        echo 0 > "$IIO_PD_ACTIVE" 2>/dev/null
        sleep 1
        echo 1 > "$IIO_APSD_RERUN" 2>/dev/null
        log "[HVDCP] PD desativado via IIO + APSD rerun executado"
    else
        log "[HVDCP] Nós IIO não encontrados — fix não aplicado"
    fi
) &

# ============================================================
# LOOP DE MONITORAMENTO TÉRMICO
# ============================================================

THROTTLED=0

while true; do
    sleep "$POLL_INTERVAL"

    # Só age se o nó de corrente existir
    [ -e "$NODE_MAX_CURRENT" ] || continue

    TEMP=$(read_temp)
    T_BAT=$(read_zone "$NODE_TEMP_BATTERY")
    T_CHG=$(read_zone "$NODE_TEMP_CHARGER")

    # Temperatura ilegível — ignora este ciclo
    [ "$TEMP" -eq -1 ] && continue

    if [ "$THROTTLED" -eq 0 ] && [ "$TEMP" -ge "$TEMP_LIMIT" ]; then
        # Temperatura alta — reduz corrente
        chmod 0777 "$NODE_MAX_CURRENT" 2>/dev/null
        echo "$CURRENT_THROTTLE" > "$NODE_MAX_CURRENT" 2>/dev/null
        chmod 0444 "$NODE_MAX_CURRENT" 2>/dev/null
        THROTTLED=1
        log "[THERMAL] ${TEMP}°C >= ${TEMP_LIMIT}°C → throttle ativado (${CURRENT_THROTTLE} µA) [bat=${T_BAT}°C chg=${T_CHG}°C]"

    elif [ "$THROTTLED" -eq 1 ] && [ "$TEMP" -le "$TEMP_RESUME" ]; then
        # Temperatura ok — restaura corrente
        chmod 0777 "$NODE_MAX_CURRENT" 2>/dev/null
        echo "$CURRENT_NORMAL" > "$NODE_MAX_CURRENT" 2>/dev/null
        chmod 0444 "$NODE_MAX_CURRENT" 2>/dev/null
        THROTTLED=0
        log "[THERMAL] ${TEMP}°C <= ${TEMP_RESUME}°C → corrente restaurada (${CURRENT_NORMAL} µA) [bat=${T_BAT}°C chg=${T_CHG}°C]"
    fi

done
