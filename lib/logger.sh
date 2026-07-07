#!/usr/bin/env bash

LOG_FILE="/var/log/aws-patch.log"

mkdir -p "$(dirname "$LOG_FILE")"

touch "$LOG_FILE"

if [[ -t 1 ]]
then

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
RESET="\033[0m"

else

RED=""
GREEN=""
YELLOW=""
BLUE=""
CYAN=""
RESET=""

fi

log(){

echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"

}

info(){

echo -e "${BLUE}ℹ${RESET} $1"

log "[INFO] $1"

}

success(){

echo -e "${GREEN}✔${RESET} $1"

log "[ OK ] $1"

}

warn(){

echo -e "${YELLOW}⚠${RESET} $1"

log "[WARN] $1"

}

error(){

echo -e "${RED}✖${RESET} $1"

log "[FAIL] $1"

}

print_banner(){

echo

echo -e "${CYAN}"

echo "=============================================================="

echo "               AWS PATCH UTILITY"

echo "=============================================================="

echo -e "${RESET}"

}

spinner(){

local pid=$1

local spin='|/-\'

while kill -0 "$pid" 2>/dev/null

do

for i in {0..3}

do

printf "\r${CYAN}[%c]${RESET} Working..." "${spin:$i:1}"

sleep .10

done

done

printf "\r"

}

run_cmd(){

local text="$1"

shift

info "$text"

"$@" >>"$LOG_FILE" 2>&1 &

pid=$!

spinner "$pid"

wait "$pid"

if [[ $? == 0 ]]
then

success "$text"

else

error "$text"

exit 1

fi

}