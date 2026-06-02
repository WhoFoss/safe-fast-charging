##########################################################################################
#
# Script de Instalação do Módulo Magisk / KernelSU
#
##########################################################################################

##########################################################################################
# Flags de Configuração
##########################################################################################

SKIPMOUNT=false
PROPFILE=true
POSTFSDATA=true
LATESTARTSERVICE=true

##########################################################################################
# Lista de Substituição
##########################################################################################

REPLACE="
"

##########################################################################################
# Funções de Instalação
##########################################################################################

print_modname() {
  ui_print "***************************************"
  ui_print "  Carregamento Rápido Seguro  v1.1    "
  ui_print "  Redmi Note 13 4G (sapphire)         "
  ui_print "***************************************"
  ui_print " "
  ui_print "RECURSOS:"
  ui_print "  - Carregamento a 4000mA (4A)"
  ui_print "  - Otimizado para carregador de 33W"
  ui_print "  - Monitor térmico em tempo real"
  ui_print "  - Throttle para 2A acima de 40°C"
  ui_print "  - Proteções JEITA e step charging ativas"
  ui_print "  - thermald-devices completo (14 entradas)"
  ui_print " "
  ui_print "PROTEÇÃO TÉRMICA:"
  ui_print "  - Sensores: battery + charge-therm + PMIC"
  ui_print "  - Throttle: >= 40°C → 2A"
  ui_print "  - Retomada: <= 37°C → 4A"
  ui_print " "
  ui_print "NOTAS IMPORTANTES:"
  ui_print "  - Use o carregador original de 33W"
  ui_print "  - Log em /data/local/tmp/safe_charging.log"
  ui_print "  - Desinstale se houver superaquecimento"
  ui_print " "
  sleep 2
  check_temp
  ui_print " "
  sleep 1
}

on_install() {
  ui_print "========================================"
  ui_print "Instalando módulo..."
  ui_print " "

  ui_print "Extraindo arquivos do módulo..."
  unzip -o "$ZIPFILE" -d $TMPDIR >&2

  # Copia pasta system (thermald-devices.conf)
  if [ -d "$TMPDIR/system" ]; then
    ui_print "Copiando arquivos do sistema..."
    cp -rf "$TMPDIR/system" "$MODPATH/"
    ui_print "[OK] thermald-devices.conf instalado"
  fi

  # Copia service.sh
  ui_print "Configurando scripts de inicialização..."
  if [ -f "$TMPDIR/common/service.sh" ]; then
    cp -f "$TMPDIR/common/service.sh" "$MODPATH/service.sh"
    chmod 0755 "$MODPATH/service.sh"
    ui_print "[OK] service.sh copiado"
  else
    abort "[ERRO] service.sh não encontrado em common/"
  fi

  # Copia action.sh se existir
  if [ -f "$TMPDIR/common/action.sh" ]; then
    cp -f "$TMPDIR/common/action.sh" "$MODPATH/action.sh"
    chmod 0755 "$MODPATH/action.sh"
    ui_print "[OK] action.sh copiado"
  fi

  # Copia post-fs-data.sh se existir
  if [ -f "$TMPDIR/common/post-fs-data.sh" ]; then
    cp -f "$TMPDIR/common/post-fs-data.sh" "$MODPATH/post-fs-data.sh"
    chmod 0755 "$MODPATH/post-fs-data.sh"
    ui_print "[OK] post-fs-data.sh copiado"
  fi

  # Verifica instalação
  if [ -f "$MODPATH/service.sh" ]; then
    ui_print "[OK] Todos os arquivos instalados com sucesso"
  else
    abort "[ERRO] Falha na instalação - service.sh não encontrado"
  fi

  ui_print " "
  ui_print "Verificando compatibilidade..."

  if [ -f "/sys/class/power_supply/battery/constant_charge_current_max" ]; then
    ui_print "[OK] Nó de corrente disponível"
  else
    ui_print "[AVISO] constant_charge_current_max não encontrado"
  fi

  if [ -f "/sys/class/thermal/thermal_zone34/temp" ]; then
    ui_print "[OK] Sensor de bateria (zone34) disponível"
  else
    ui_print "[AVISO] Sensor de bateria não encontrado"
  fi

  ui_print " "
  ui_print "========================================"
}

set_permissions() {
  ui_print "Configurando permissões..."

  set_perm_recursive $MODPATH 0 0 0755 0644

  for script in service.sh action.sh post-fs-data.sh; do
    if [ -f "$MODPATH/$script" ]; then
      set_perm "$MODPATH/$script" 0 0 0755
      ui_print "[OK] $script → 0755"
    fi
  done

  ui_print " "
}

on_post_install() {
  ui_print "========================================"
  ui_print "INSTALAÇÃO CONCLUÍDA!"
  ui_print " "
  ui_print "PRÓXIMOS PASSOS:"
  ui_print "  1. Reinicie seu aparelho"
  ui_print "  2. Conecte o carregador original de 33W"
  ui_print "  3. Verifique o log se necessário:"
  ui_print "     /data/local/tmp/safe_charging.log"
  ui_print " "
  ui_print "RESULTADOS ESPERADOS:"
  ui_print "  - Corrente de carga: 4A"
  ui_print "  - Throttle automático acima de 40°C"
  ui_print "  - Temperatura normal: <40°C"
  ui_print " "
  ui_print "SE OCORREREM PROBLEMAS:"
  ui_print "  - Superaquecimento (>45°C)"
  ui_print "  - Carregamento para inesperadamente"
  ui_print "  - Bateria descarrega mais rápido"
  ui_print "  >> Desinstale o módulo imediatamente"
  ui_print " "
  ui_print "DESINSTALAR:"
  ui_print "  KernelSU / Magisk > Módulos"
  ui_print "  > Remover este módulo > Reiniciar"
  ui_print " "
  ui_print "========================================"
  ui_print " "
  ui_print "Aproveite o carregamento rápido seguro!"
  ui_print " "
}

##########################################################################################
# Funções Personalizadas
##########################################################################################

# Lê temperatura da bateria (zone34 = battery, confirmado no sapphire)
check_temp() {
  local zone_bat=/sys/class/thermal/thermal_zone34/temp
  local zone_chg=/sys/class/thermal/thermal_zone20/temp

  if [ -f "$zone_bat" ]; then
    local raw=$(cat "$zone_bat")
    local temp_c=$((raw / 1000))
    ui_print "Temperatura bateria: ${temp_c}°C"
  fi

  if [ -f "$zone_chg" ]; then
    local raw=$(cat "$zone_chg")
    local temp_c=$((raw / 1000))
    ui_print "Temperatura carregador: ${temp_c}°C"
  fi
}
