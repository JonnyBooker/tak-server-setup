#!/bin/bash
set -e
[ -f ./.env ] && source ./.env

# Optional: the address clients/browsers will actually use to reach this server
# (public IP, private IP, or DNS name). TAK Server auto-detects its own Docker
# bridge IP (e.g. 172.x.x.x) on first boot and bakes it into CoreConfig.xml's
# <urladd> and <federation-server webBaseUrl>. Defaults to "localhost", which
# only works when clients run on this same machine.
# e.g.:
#   ./setup.sh      (defaults to localhost)
#   ./setup.sh 203.0.113.10
#   ./setup.sh takserver.example.com
SERVER_ADDRESS="${1:-localhost}"

#check which $DOCKER_COMPOSE command to use
if command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
elif command -v docker &> /dev/null && docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
else
    echo "Error: Neither 'docker-compose' nor 'docker compose' command is available."
    exit 1
fi

# Counts occurrences of `pattern` across the tak container's logs. Used to detect a
# *fresh* occurrence after a restart, since old log files are never truncated and a
# plain grep -q would match a stale line from before the restart.
count_log_matches() {
  local pattern="$1"
  $DOCKER_COMPOSE exec -T tak bash -c "grep -hcE '$pattern' /opt/tak/logs/*.log 2>/dev/null | awk '{sum+=\$1} END {print sum+0}'"
}

# Restarts the tak container and waits until each microservice in $2 (space-separated)
# logs a NEW "Started TAK Server <name> Microservice." line past the pre-restart count.
restart_tak_and_wait() {
  local services="$1"
  local before_counts="" svc idx before_n after i ok

  idx=0
  for svc in $services; do
    idx=$((idx + 1))
    n=$(count_log_matches "Started TAK Server $svc Microservice")
    before_counts="$before_counts $n"
  done

  $DOCKER_COMPOSE restart tak

  idx=0
  for svc in $services; do
    idx=$((idx + 1))
    before_n=$(echo "$before_counts" | awk -v i="$idx" '{print $i}')
    echo "Waiting for tak $svc microservice to restart..."
    ok=0
    for i in $(seq 1 60); do
      after=$(count_log_matches "Started TAK Server $svc Microservice")
      if [ "$after" -gt "$before_n" ]; then
        echo "tak $svc microservice ready."
        ok=1
        break
      fi
      sleep 5
    done
    if [ "$ok" -ne 1 ]; then
      echo "Timed out waiting for tak $svc microservice to restart" >&2
      return 1
    fi
  done
}

wait_for_container_shell() {
  echo "Waiting for tak container shell..."
  for i in $(seq 1 30); do
    if $DOCKER_COMPOSE exec -T tak true >/dev/null 2>&1; then
      echo "tak container shell ready."
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for tak container shell" >&2
  return 1
}

wait_for_postgres() {
  echo "Waiting for postgres to accept connections..."
  for i in $(seq 1 60); do
    if $DOCKER_COMPOSE exec -T -u postgres db psql -U postgres -c 'select 1' >/dev/null 2>&1; then
      echo "postgres ready."
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for postgres" >&2
  return 1
}

# CoreConfig.xml doesn't ship with the TAK Server release - only CoreConfig.example.xml
# does. The tak container's own "config" microservice generates CoreConfig.xml from
# that example on its first startup. Without this wait, the password sed below can run
# before that generation finishes.
wait_for_core_config() {
  echo "Waiting for CoreConfig.xml to be generated..."
  for i in $(seq 1 60); do
    if $DOCKER_COMPOSE exec -T tak bash -c "test -f /opt/tak/CoreConfig.xml"; then
      echo "CoreConfig.xml ready."
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for CoreConfig.xml to be generated" >&2
  return 1
}

generate_password() {
  local length=${1:-15}
  local upper='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  local lower='abcdefghijklmnopqrstuvwxyz'
  local digit='0123456789'
  local special='!@#$%^&*()_+=;:,.<>?'
  local all="${upper}${lower}${digit}${special}"

  local password=""
  local i char has_special

  while true; do
      password=$(LC_ALL=C tr -dc "$all" < /dev/urandom | head -c "$length")

      [[ ${#password} -eq $length ]] || continue
      [[ "$password" =~ [A-Z] ]] || continue
      [[ "$password" =~ [a-z] ]] || continue
      [[ "$password" =~ [0-9] ]] || continue

      has_special=0
      for (( i=0; i<${#special}; i++ )); do
          char="${special:i:1}"
          if [[ "$password" == *"$char"* ]]; then
              has_special=1
              break
          fi
      done
      [[ $has_special -eq 1 ]] || continue

      break
  done

  echo "$password"
}

# reset state as needed
echo "This will reset the tak server to a clean state. If you have any existing data, it will be lost."
read -p "Are you sure you want to continue? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborting setup."
  exit 0
fi

echo "Stopping and removing containers..."
docker compose down

echo "Removing docker files and tak files..."
docker run --rm -v "$(pwd):/workspace" -w /workspace busybox rm -rf .runtime_do_not_edit certs

echo "Copying docker files and tak files from .tak-download..."
cp -r ./.tak-download/ ./.runtime_do_not_edit/

# start the stack
$DOCKER_COMPOSE up -d --build
wait_for_postgres
wait_for_core_config

# use the password set in the environment variable if provided, otherwise generate a random one
MARTI_PASSWORD="${DB_USER_PASSWORD:-$(generate_password 15)}"
ADMIN_PASSWORD="${ADMIN_USER_PASSWORD:-$(generate_password 15)}"

# set martiuser password in tak/CoreConfig.xml
$DOCKER_COMPOSE exec tak bash -c "sed -i 's/password=\"\"/password=\"$MARTI_PASSWORD\"/g' /opt/tak/CoreConfig.xml"

# update cert-metadata.sh with configured values. Fallback to US if variable not set.
$DOCKER_COMPOSE exec tak bash -c "sed -i -e 's/COUNTRY=US/COUNTRY=${COUNTRY:-US}/' /opt/tak/certs/cert-metadata.sh"
$DOCKER_COMPOSE exec tak bash -c "sed -i -e 's/ORGANIZATIONAL_UNIT=US/ORGANIZATIONAL_UNIT=${ORGANIZATIONAL_UNIT:-TAK}/' /opt/tak/certs/cert-metadata.sh"

# restart the db container so it (re)creates martiuser using the new password from CoreConfig.xml and cert-metadata.sh.
# The tak container will then pick up the new password on its next restart.
$DOCKER_COMPOSE restart db
wait_for_postgres

# restart the tak container to apply the new DB password. Cert generation below only
# needs the container's shell, not the Java app (which won't fully start until
# takserver.jks exists), so just wait for exec to work rather than for a microservice.
$DOCKER_COMPOSE restart tak
wait_for_container_shell

# create certs
$DOCKER_COMPOSE exec tak bash -c "cd /opt/tak/certs && ./makeRootCa.sh --ca-name CRFtakserver"
$DOCKER_COMPOSE exec tak bash -c "cd /opt/tak/certs && ./makeCert.sh server takserver"
$DOCKER_COMPOSE exec tak bash -c "cd /opt/tak/certs && ./makeCert.sh client admin"

# restart the tak container so it picks up takserver.jks (JWT signing key depends on it)
restart_tak_and_wait "api messaging"

# config
$DOCKER_COMPOSE exec tak bash -c "cd /opt/tak/ && java -jar /opt/tak/utils/UserManager.jar usermod -A -p $ADMIN_PASSWORD admin"
$DOCKER_COMPOSE exec tak bash -c "cd /opt/tak/ && java -jar utils/UserManager.jar certmod -A certs/files/admin.pem"
$DOCKER_COMPOSE exec tak bash -c "java -jar /opt/tak/db-utils/SchemaManager.jar upgrade"

# point the auto-detected urladd/federation URLs at the address clients will actually
# use, instead of the Docker-internal bridge IP TAK Server picked on first boot
if [ "$SERVER_ADDRESS" = "localhost" ]; then
  echo "SERVER_ADDRESS not set (usage: ./setup.sh <host-or-ip>) - leaving urladd/webBaseUrl as localhost."
else
  echo "Setting urladd/webBaseUrl host to $SERVER_ADDRESS..."
  $DOCKER_COMPOSE exec tak bash -c "sed -i -E 's#(<urladd host=\"http://)[^:\"]+(:)#\1$SERVER_ADDRESS\2#' /opt/tak/CoreConfig.xml"
  $DOCKER_COMPOSE exec tak bash -c "sed -i -E 's#(webBaseUrl=\"https://)[^:\"]+(:)#\1$SERVER_ADDRESS\2#' /opt/tak/CoreConfig.xml"
  restart_tak_and_wait "api messaging"
fi

echo ""
echo "################################"
echo ""
echo "SETUP COMPLETE"
echo ""
echo "  - Server address: $SERVER_ADDRESS"
echo ""
echo "  - Admin user name: admin"
echo "  - Admin user password: $ADMIN_PASSWORD"
echo ""
echo "  - DB user name: martiuser"
echo "  - DB user password: $MARTI_PASSWORD"
echo ""
echo "  - Default certificate password for import: atakatak"
echo ""
echo "CERTIFICATES"
echo ""
echo "  - Get the server and admin certs: sh ./get-certs.sh"
echo "  - Create a client cert: sh ./create-client-cert.sh <client-name>"
echo ""
echo "MANAGE"
echo "  - Manage the stack with 'docker compose' commands, e.g. 'docker compose ps', 'docker compose logs', 'docker compose down'"
echo ""
echo "################################"
