#!/usr/bin/env bash
# Interaktiver Minimal-Installer fuer mehrere FiveM/txAdmin-Server auf Debian 12.
# Ausfuehren als root: sudo bash setup-fivem-dual.sh
set -Eeuo pipefail

INSTALL_USER="${SUDO_USER:-}"
[[ -n "$INSTALL_USER" ]] || { echo "Bitte als normaler Benutzer mit sudo starten, nicht direkt als root." >&2; exit 1; }
INSTALL_HOME="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"
[[ -n "$INSTALL_HOME" && -d "$INSTALL_HOME" ]] || { echo "Home-Verzeichnis von $INSTALL_USER wurde nicht gefunden." >&2; exit 1; }
RUN_USER="$INSTALL_USER"
RUN_GROUP="$(id -gn "$RUN_USER")"
BASE_DIR="$INSTALL_HOME/fivem"
ARTIFACT_DIR="$BASE_DIR/artifacts"
# Cfx.re veroeffentlicht keine verlaessliche /latest-Datei fuer Linux.
# Diese URL verweist auf den aktuell empfohlenen, konkret veroeffentlichten Linux-Build.
ARTIFACT_URL="https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/38220-93a7f0d8a41d448512f0109ff79fc5080f46ad48/fx.tar.xz"
CREDENTIALS_FILE="$BASE_DIR/install-credentials.txt"

fail() { echo "Fehler: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "Bitte mit sudo ausfuehren: sudo bash $0"
[[ -f /etc/debian_version ]] || fail "Dieses Skript ist fuer Debian vorgesehen."

read -r -p "Wie viele FiveM-Server sollen angelegt werden? " INSTANCE_COUNT
[[ "$INSTANCE_COUNT" =~ ^[1-9][0-9]*$ ]] || fail "Bitte eine ganze Zahl groesser als 0 eingeben."

declare -a NAMES LICENSE_KEYS
for ((i=0; i<INSTANCE_COUNT; i++)); do
  while true; do
    read -r -p "Name fuer Server $((i + 1)) (z. B. public oder development): " name
    name="${name,,}"
    [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "Erlaubt: Kleinbuchstaben, Zahlen, Bindestriche (max. 31)."; continue; }
    [[ " ${NAMES[*]-} " != *" $name "* ]] || { echo "Dieser Name wurde schon verwendet."; continue; }
    NAMES+=("$name")
    break
  done
  read -r -s -p "Cfx.re-Lizenzschluessel fuer '$name' (unsichtbar): " license_key
  echo
  [[ -n "$license_key" ]] || fail "Ein Cfx.re-Lizenzschluessel ist erforderlich."
  LICENSE_KEYS+=("$license_key")
done

echo "Installiere benoetigte Systempakete ..."
export DEBIAN_FRONTEND=noninteractive
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections
echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
apt-get update
apt-get install -y --no-install-recommends apache2 ca-certificates curl git libatomic1 \
  libapache2-mod-php mariadb-client mariadb-server openssl php phpmyadmin tar xz-utils
systemctl enable --now mariadb apache2

# phpMyAdmin ist installiert, aber nur lokal erreichbar.
cat >/etc/apache2/conf-available/fivem-phpmyadmin-local.conf <<'EOF'
<Location /phpmyadmin>
    Require local
</Location>
EOF
a2enconf phpmyadmin fivem-phpmyadmin-local
systemctl reload apache2

install -d -o "$RUN_USER" -g "$RUN_GROUP" -m 0755 "$BASE_DIR" "$ARTIFACT_DIR"

if [[ ! -x "$ARTIFACT_DIR/run.sh" ]]; then
  echo "Lade aktuelles FiveM-Linux-Artifact herunter ..."
  archive="$(mktemp --suffix=.tar.xz)"
  trap 'rm -f "$archive"' EXIT
  curl --fail --location --retry 3 --output "$archive" "$ARTIFACT_URL"
  tar -xJf "$archive" -C "$ARTIFACT_DIR"
  rm -f "$archive"
  trap - EXIT
  chown -R "$RUN_USER:$RUN_GROUP" "$ARTIFACT_DIR"
  chmod 0755 "$ARTIFACT_DIR/run.sh"
fi

umask 077
cat >"$CREDENTIALS_FILE" <<EOF
FiveM-Installationsdaten
Erstellt: $(date -Is)

phpMyAdmin ist nur lokal erreichbar. SSH-Tunnel vom PC:
  ssh -L 8080:127.0.0.1:80 ROOT-ODER-SUDO-BENUTZER@SERVER-IP
Danach im Browser: http://127.0.0.1:8080/phpmyadmin

EOF

for ((i=0; i<INSTANCE_COUNT; i++)); do
  name="${NAMES[$i]}"; license_key="${LICENSE_KEYS[$i]}"
  # Instanz 1 = 40120/30120; Instanz 2 = 40220/30220; usw.
  tx_port=$((40120 + i * 100)); game_port=$((30120 + i * 100))
  instance_dir="$BASE_DIR/$name"; data_dir="$instance_dir/server-data"; txdata_dir="$instance_dir/txData"
  db_name="fivem_${name//-/_}"; db_user="$db_name"; db_password="$(openssl rand -hex 24)"

  install -d -o "$RUN_USER" -g "$RUN_GROUP" -m 0750 "$instance_dir" "$txdata_dir" "$instance_dir/logs"
  # Ausschliesslich offizielle FiveM-Standardressourcen, keine RP-Frameworks.
  if [[ ! -e "$data_dir" ]]; then
    git clone --depth 1 https://github.com/citizenfx/cfx-server-data.git "$data_dir"
    chown -R "$RUN_USER:$RUN_GROUP" "$data_dir"
  else
    install -d -o "$RUN_USER" -g "$RUN_GROUP" -m 0750 "$data_dir/resources"
  fi

  cat >"$data_dir/server.cfg" <<EOF
# $name - automatisch angelegte Minimal-Konfiguration
endpoint_add_tcp "0.0.0.0:$game_port"
endpoint_add_udp "0.0.0.0:$game_port"
sv_licenseKey "$license_key"
sv_hostname "$name"
sets sv_projectName "$name"
sets sv_projectDesc "FiveM Server"
ensure mapmanager
ensure chat
ensure spawnmanager
ensure sessionmanager
ensure hardcap
ensure rconlog
# Eigene Ressourcen spaeter hier eintragen, z. B.: ensure mein_script
EOF
  chown "$RUN_USER:$RUN_GROUP" "$data_dir/server.cfg"; chmod 0640 "$data_dir/server.cfg"

  cat >"$BASE_DIR/start-$name.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$ARTIFACT_DIR"
exec ./run.sh \\
  +set txAdminPort "$tx_port" \\
  +set txDataPath "$txdata_dir" \\
  +set serverProfile "$name"
EOF
  chown "$RUN_USER:$RUN_GROUP" "$BASE_DIR/start-$name.sh"; chmod 0750 "$BASE_DIR/start-$name.sh"

  cat >"/etc/systemd/system/fivem-$name.service" <<EOF
[Unit]
Description=FiveM txAdmin ($name)
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$ARTIFACT_DIR
ExecStart=$BASE_DIR/start-$name.sh
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  mariadb <<EOF
CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '$db_password';
ALTER USER '$db_user'@'localhost' IDENTIFIED BY '$db_password';
GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'localhost';
FLUSH PRIVILEGES;
EOF
  cat >>"$CREDENTIALS_FILE" <<EOF
Server: $name
  txAdmin:  http://SERVER-IP:$tx_port
  Game:     TCP/UDP $game_port
  DB-Name:  $db_name
  DB-User:  $db_user
  DB-Pass:  $db_password
  Ordner:   $instance_dir

EOF
done

chmod 0600 "$CREDENTIALS_FILE"
chown "$RUN_USER:$RUN_GROUP" "$CREDENTIALS_FILE"
systemctl daemon-reload
for name in "${NAMES[@]}"; do systemctl enable --now "fivem-$name.service"; done

cat <<EOF

Fertig. Zugangsdaten: $CREDENTIALS_FILE
Rufe jede txAdmin-Adresse aus dieser Datei auf und schliesse die Ersteinrichtung ab.
Waehle dabei den vorhandenen Serverdaten-Ordner und die vorhandene server.cfg.
Oeffne in deiner Server-Firewall pro Instanz den jeweiligen Game-Port fuer TCP und UDP.
Die txAdmin-Ports nur fuer deine feste IP oder ueber VPN freigeben.
EOF
