#!/bin/bash

# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
# 
#   http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

set -e
declare -A defaults
declare -A config_file
declare -A args
declare -A config
declare -A users
declare -A path
declare -A service
declare -A md5
declare -A regex
declare -A image

config_path="/opt/reality"
compose_project='reality'
tgbot_project='tgbot'
BACKTITLE=Reality
MENU="Select an option:"
HEIGHT=30
WIDTH=60
CHOICE_HEIGHT=20

# Every image below comes from the project's own registry or from the official
# Docker Hub library. No third-party re-published images are used anymore.
#   xray-core  -> GHCR, published by XTLS (ghcr.io/xtls/xray-core)
#   sing-box   -> GHCR, published by SagerNet (ghcr.io/sagernet/sing-box)
#   nginx/certbot/haproxy/python -> official Docker Hub images/library
image[xray]="ghcr.io/xtls/xray-core:25.12.8"
image[sing-box]="ghcr.io/sagernet/sing-box:v1.12.23"
image[nginx]="nginx:1.24.0"
image[certbot]="certbot/certbot:v2.6.0"
image[haproxy]="haproxy:2.8.0"
image[python]="python:3.11-alpine"

# Upstream project coordinates. The bot script and the update helper are pulled
# from this repository instead of a third-party fork.
repo_owner='dakerclaw'
repo_name='reality'
repo_branch='main'

# The --backup option hands the encrypted archive to a public paste service.
# It is the only non-project network dependency left; point it elsewhere (or to
# your own endpoint) with BACKUP_UPLOAD_URL=<url> in the environment.
backup_upload_url="${BACKUP_UPLOAD_URL:-https://temp.sh/upload}"

# DNS/private destinations the tunnel must never reach. These ranges are
# inlined instead of downloading a third-party "geoip-private" rule set.
private_ip_cidr='["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.0.0.0/24","192.0.2.0/24","192.168.0.0/16","198.18.0.0/15","198.51.100.0/24","203.0.113.0/24","224.0.0.0/4","240.0.0.0/4","::1/128","fc00::/7","fe80::/10"]'

# One rule data file (the "bypass" list) has no upstream counterpart, so it is
# still fetched from a community repository. Override it to self-host:
#   RULESET_BASE_URL=https://example.com/rules ./reality.sh
ruleset_base_url="${RULESET_BASE_URL:-https://raw.githubusercontent.com/aleskxyz/sing-box-rules/refs/heads/rule-set}"

defaults[transport]=tcp
# The SNI the client sends and the server accepts. In the reality and shadowtls
# modes it must be a real, reachable site - see defaults[camouflage] below.
defaults[domain]=www.fastly.com
# The remote site the camouflage falls back to: probes that do not authenticate
# are relayed to it (Reality dest / shadowtls handshake target), so it is what an
# active probe sees on the proxy port. Supplied at deployment time, optional
# ":port" suffix, port 443 by default. It is kept in sync with the SNI because
# the certificate this site returns has to match the SNI the probe sent.
#
# REALITY's documented minimum for a target site is TLS 1.3 + H2, so qualify a
# candidate before relying on it (both should answer, the second with h2):
#   openssl s_client -connect <host>:443 -servername <host> -tls1_3 </dev/null | grep Protocol
#   openssl s_client -connect <host>:443 -servername <host> -alpn h2 </dev/null | grep ALPN
# The shipped default meets both: TLS 1.3 with X25519, ALPN h2, a leaf whose CN
# is the SNI itself, and a chain that roots in Certainly Root R1, which Mozilla,
# Chrome, Apple and Oracle all carry.
defaults[camouflage]=www.fastly.com
# 8443 is deliberately not a well-known port: the default installation must not
# take 80 or 443 away from whatever else runs on the machine.
defaults[port]=8443
# Host port of the plain-HTTP side. It serves the local website out of
# ./website (nginx), and in the letsencrypt mode it also carries the ACME
# HTTP-01 challenge. "OFF" keeps it unpublished entirely.
defaults[http_port]=8080
defaults[safenet]=OFF
# BBR is a kernel feature, so "enabling" it means loading tcp_bbr/sch_fq and
# writing two sysctls - nothing is installed from a package repository. It is
# switched on by default and falls back to leaving the kernel as it is when the
# running kernel does not offer bbr (older than 4.9, or a container that cannot
# load its host's modules).
defaults[bbr]=ON
defaults[warp]=OFF
defaults[warp_license]=""
defaults[warp_private_key]=""
defaults[warp_token]=""
defaults[warp_id]=""
defaults[warp_client_id]=""
defaults[warp_interface_ipv4]=""
defaults[warp_interface_ipv6]=""
defaults[core]=sing-box
defaults[security]=reality
defaults[server]=$(curl -fsSL --ipv4 -m 5 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -m1 '^ip=' | cut -d '=' -f2 || true)
defaults[tgbot]=OFF
defaults[tgbot_token]=""
defaults[tgbot_admins]=""

config_items=(
  "core"
  "security"
  "service_path"
  "public_key"
  "private_key"
  "short_id"
  "transport"
  "domain"
  "camouflage"
  "server"
  "port"
  "http_port"
  "safenet"
  "bbr"
  "warp"
  "warp_license"
  "warp_private_key"
  "warp_token"
  "warp_id"
  "warp_client_id"
  "warp_interface_ipv4"
  "warp_interface_ipv6"
  "tgbot"
  "tgbot_token"
  "tgbot_admins"
)

# Fast membership lookup for config_items, used when rewriting the config file.
declare -A config_item_lookup
for _config_item in "${config_items[@]}"; do
  config_item_lookup["${_config_item}"]=1
done
unset _config_item

# When RELOAD_DEFERRED is 1, configuration writes only mark the config as dirty
# and the expensive regeneration/restart is postponed to a single flush_reload.
RELOAD_DEFERRED=0
RELOAD_PENDING=0

regex[domain]="^[a-zA-Z0-9]+([-.][a-zA-Z0-9]+)*\.[a-zA-Z]{2,}$"
regex[port]="^[1-9][0-9]*$"
regex[warp_license]="^[a-zA-Z0-9]{8}-[a-zA-Z0-9]{8}-[a-zA-Z0-9]{8}$"
regex[username]="^[a-zA-Z0-9]+$"
regex[ip]="^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$"
regex[tgbot_token]="^[0-9]{8,10}:[a-zA-Z0-9_-]{35}$"
regex[tgbot_admins]="^[a-zA-Z][a-zA-Z0-9_]{4,31}(,[a-zA-Z][a-zA-Z0-9_]{4,31})*$"
regex[domain_port]="^[a-zA-Z0-9]+([-.][a-zA-Z0-9]+)*\.[a-zA-Z]{2,}(:[1-9][0-9]*)?$"
regex[file_path]="^[a-zA-Z0-9_/.-]+$"
regex[url]="^(http|https)://([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}|[0-9]{1,3}(\.[0-9]{1,3}){3})(:[0-9]{1,5})?(/.*)?$"

function show_help {
  echo ""
  echo "Usage: reality.sh [-t|--transport=tcp|http|grpc|ws|tuic|hysteria2|shadowtls] [-d|--domain=<domain>] [--camouflage=<domain[:port]>] [--server=<server>]
  [--regenerate] [--default] [-r|--restart] [--enable-safenet=true|false] [--enable-bbr=true|false] [--port=<port>] [--http-port=<port|off>] [-c|--core=xray|sing-box]
  [--enable-warp=true|false] [--warp-license=<license>] [--security=reality|letsencrypt|selfsigned] [-m|--menu] [--show-server-config]
  [--add-user=<username>] [--lists-users] [--show-user=<username>] [--delete-user=<username>] [--backup] [--restore=<url|file>]
  [--backup-password=<password>] [-u|--uninstall]"
  echo ""
  echo "  -t, --transport <tcp|http|grpc|ws|tuic|hysteria2|shadowtls> Transport protocol (tcp, http, grpc, ws, tuic, hysteria2, shadowtls, default: ${defaults[transport]})"
  echo "  -d, --domain <domain>     Domain to use as SNI (default: ${defaults[domain]})"
  echo "      --camouflage <domain[:port]> Remote site the camouflage falls back to in the reality and shadowtls modes."
  echo "                            Unauthenticated probes are relayed to it, so it must be a real site whose certificate"
  echo "                            matches the SNI; the SNI follows it unless --domain is given explicitly (default: ${defaults[camouflage]})"
  echo "      --server <server>     IP address or domain name of server (Must be a valid domain if using letsencrypt security)"
  echo "      --regenerate          Regenerate public and private keys"
  echo "      --default             Restore default configuration"
  echo "  -r  --restart             Restart services"
  echo "  -u, --uninstall           Uninstall reality"
  echo "      --enable-safenet <true|false> Enable or disable safenet (blocking malware and adult content)"
  echo "      --enable-bbr <true|false> Enable or disable the BBR congestion control (default: ${defaults[bbr]})"
  echo "                            BBR is a kernel feature: this loads tcp_bbr/sch_fq and writes the matching sysctls,"
  echo "                            and is skipped with a warning on kernels that do not offer it (needs 4.9+)"
  echo "      --port <port>         Server port (default: ${defaults[port]}; 80 and 443 are never used unless asked for)"
  echo "      --http-port <port|off> Host port of the local website served by nginx out of ./website, and the ACME challenge"
  echo "                            in the letsencrypt mode (default: ${defaults[http_port]}, \"off\" leaves it unpublished)"
  echo "      --enable-warp <true|false> Enable or disable Cloudflare warp"
  echo "      --warp-license <warp-license> Add Cloudflare warp+ license"
  echo "  -c  --core <sing-box|xray> Select core (xray, sing-box, default: ${defaults[core]})"
  echo "      --security <reality|letsencrypt|selfsigned> Select type of TLS encryption (reality, letsencrypt, selfsigned, default: ${defaults[security]})" 
  echo "  -m  --menu                Show menu"
  echo "      --enable-tgbot <true|false> Enable Telegram bot for user management"
  echo "      --tgbot-token <token> Token of Telegram bot"
  echo "      --tgbot-admins <telegram-username> Usernames of telegram bot admins (Comma separated list of usernames without leading '@')"
  echo "      --show-server-config  Print server configuration"
  echo "      --add-user <username> Add new user"
  echo "      --list-users          List all users"
  echo "      --show-user <username> Shows the config and QR code of the user"
  echo "      --delete-user <username> Delete the user"
  echo "      --backup              Backup users and configuration and upload it to ${backup_upload_url} (override with BACKUP_UPLOAD_URL)"
  echo "      --restore <url|file>  Restore backup from URL or file"
  echo "      --backup-password <password> Create/Restore password protected backup file"
  echo "  -h, --help                Display this help message"
  return 0
}

function parse_args {
  local opts
  opts=$(getopt -o t:d:ruc:mh --long transport:,domain:,camouflage:,server:,regenerate,default,restart,uninstall,enable-safenet:,enable-bbr:,port:,http-port:,warp-license:,enable-warp:,core:,security:,menu,show-server-config,add-user:,list-users,show-user:,delete-user:,backup,restore:,backup-password:,enable-tgbot:,tgbot-token:,tgbot-admins:,help -- "$@")
  if [[ $? -ne 0 ]]; then
    return 1
  fi
  eval set -- "$opts"
  while true; do
    case $1 in
      -t|--transport)
        args[transport]="$2"
        case ${args[transport]} in
          tcp|http|grpc|ws|tuic|hysteria2|shadowtls)
            shift 2
            ;;
          *)
            echo "Invalid transport protocol: ${args[transport]}"
            return 1
            ;;
        esac
        ;;
      -d|--domain)
        args[domain]="$2"
        if ! [[ ${args[domain]} =~ ${regex[domain_port]} ]]; then
          echo "Invalid domain: ${args[domain]}"
          return 1
        fi
        shift 2
        ;;
      --camouflage)
        args[camouflage]="$2"
        if ! [[ ${args[camouflage]} =~ ${regex[domain_port]} ]]; then
          echo "Invalid camouflage site: ${args[camouflage]}"
          return 1
        fi
        if [[ ${args[camouflage]} =~ : ]] && (( ${args[camouflage]#*:} > 65535 )); then
          echo "Camouflage port out of range: ${args[camouflage]#*:}"
          return 1
        fi
        shift 2
        ;;
      --server)
        args[server]="$2"
        if ! [[ ${args[server]} =~ ${regex[domain]} || ${args[server]} =~ ${regex[ip]} ]]; then
          echo "Invalid server: ${args[server]}"
          return 1
        fi
        shift 2
        ;;
      --regenerate)
        args[regenerate]=true
        shift
        ;;
      --default)
        args[default]=true
        shift
        ;;
      -r|--restart)
        args[restart]=true
        shift
        ;;
      -u|--uninstall)
        args[uninstall]=true
        shift
        ;;
      --enable-safenet)
        case "$2" in
          true|false)
            if [[ $2 == true ]]; then args[safenet]=ON; else args[safenet]=OFF; fi
            shift 2
            ;;
          *)
            echo "Invalid safenet option: $2"
            return 1
            ;;
        esac
        ;;
      --enable-bbr)
        case "$2" in
          true|false)
            if [[ $2 == true ]]; then args[bbr]=ON; else args[bbr]=OFF; fi
            shift 2
            ;;
          *)
            echo "Invalid bbr option: $2"
            return 1
            ;;
        esac
        ;;
      --enable-warp)
        case "$2" in
          true|false)
            if [[ $2 == true ]]; then args[warp]=ON; else args[warp]=OFF; fi
            shift 2
            ;;
          *)
            echo "Invalid warp option: $2"
            return 1
            ;;
        esac
        ;;
      --port)
        args[port]="$2"
        if ! [[ ${args[port]} =~ ${regex[port]} ]]; then
          echo "Invalid port number: ${args[port]}"
          return 1
        elif ((args[port] < 1 || args[port] > 65535)); then
          echo "Port number out of range: ${args[port]}"
          return 1
        fi
        if [[ ${args[port]} -eq 80 ]]; then
          echo "Invalid port number: 80 is reserved for the letsencrypt ACME challenge. Use another port (default: ${defaults[port]})."
          return 1
        fi
        if [[ ${args[port]} -eq 443 ]]; then
          echo "Warning: port 443 is a well-known port. The default is ${defaults[port]} exactly so the installation does not take 80 or 443 from other services."
        fi
        shift 2
        ;;
      --http-port)
        case "$2" in
          [Oo][Ff][Ff]|off)
            args[http_port]='OFF'
            ;;
          *)
            args[http_port]="$2"
            if ! [[ ${args[http_port]} =~ ${regex[port]} ]] || ((args[http_port] < 1 || args[http_port] > 65535)); then
              echo "Invalid HTTP port number: ${args[http_port]} (use \"off\" to leave it unpublished)"
              return 1
            fi
            if [[ ${args[http_port]} -eq 443 ]]; then
              echo "Warning: port 443 is a well-known port; the default HTTP port is ${defaults[http_port]}."
            elif [[ ${args[http_port]} -eq 80 ]]; then
              echo "Note: port 80 is only required for letsencrypt (ACME HTTP-01)."
            fi
            ;;
        esac
        shift 2
        ;;
      --warp-license)
        args[warp_license]="$2"
        if ! [[ ${args[warp_license]} =~ ${regex[warp_license]} ]]; then
          echo "Invalid warp license: ${args[warp_license]}"
          return 1
        fi
        shift 2
        ;;
      -c|--core)
        args[core]="$2"
        case ${args[core]} in
          xray|sing-box)
            shift 2
            ;;
          *)
            echo "Invalid core: ${args[core]}"
            return 1
            ;;
        esac
        ;;
      --security)
        args[security]="$2"
        case ${args[security]} in
          reality|letsencrypt|selfsigned)
            shift 2
            ;;
          *)
            echo "Invalid TLS security option: ${args[security]}"
            return 1
            ;;
        esac
        ;;
      -m|--menu)
        args[menu]=true
        shift
        ;;
      --enable-tgbot)
        case "$2" in
          true|false)
            if [[ $2 == true ]]; then args[tgbot]=ON; else args[tgbot]=OFF; fi
            shift 2
            ;;
          *)
            echo "Invalid enable-tgbot option: $2"
            return 1
            ;;
        esac
        ;;
      --tgbot-token)
        args[tgbot_token]="$2"
        if [[ ! ${args[tgbot_token]} =~ ${regex[tgbot_token]} ]]; then
          echo "Invalid Telegram Bot Token: ${args[tgbot_token]}"
          return 1
        fi 
        if ! curl -sSfL -m 3 "https://api.telegram.org/bot${args[tgbot_token]}/getMe" >/dev/null 2>&1; then
          echo "Invalid Telegram Bot Token: Telegram Bot Token is incorrect. Check it again."
          return 1
        fi
        shift 2
        ;;
      --tgbot-admins)
        args[tgbot_admins]="$2"
        if [[ ! ${args[tgbot_admins]} =~ ${regex[tgbot_admins]} || ${args[tgbot_admins]} =~ .+_$ || ${args[tgbot_admins]} =~ .+_,.+ ]]; then
          echo -e "Invalid Telegram Bot Admins Username: ${args[tgbot_admins]}\nThe usernames must separated by ',' without leading '@' character or any extra space."
          return 1
        fi
        shift 2
        ;;
      --show-server-config)
        args[server-config]=true
        shift
        ;;
      --add-user)
        args[add_user]="$2"
        if ! [[ ${args[add_user]} =~ ${regex[username]} ]]; then
          echo -e "Invalid username: ${args[add_user]}\nUsername can only contains A-Z, a-z and 0-9"
          return 1
        fi
        shift 2
        ;;
      --list-users)
        args[list_users]=true
        shift
        ;;
      --show-user)
        args[show_config]="$2"
        if ! [[ ${args[show_config]} =~ ${regex[username]} ]]; then
          echo "Invalid username: ${args[show_config]}"
          return 1
        fi
        shift 2
        ;;
      --delete-user)
        args[delete_user]="$2"
        if ! [[ ${args[delete_user]} =~ ${regex[username]} ]]; then
          echo "Invalid username: ${args[delete_user]}"
          return 1
        fi
        shift 2
        ;;
      --backup)
        args[backup]=true
        shift
        ;;
      --restore)
        args[restore]="$2"
        if [[ ! ${args[restore]} =~ ${regex[file_path]} ]] && [[ ! ${args[restore]} =~ ${regex[url]} ]]; then
          echo "Invalid: Backup file path or URL is not valid."
          return 1
        fi
        shift 2
        ;;
      --backup-password)
        args[backup_password]="$2"
        shift 2
        ;;
      -h|--help)
        args[help]=true
        shift
        break
        ;;
      --)
        shift
        break
        ;;
      *)
        echo "Unknown option: $1"
        return 1
        ;;
    esac
  done

  if [[ ${args[uninstall]} == true ]]; then
    uninstall
  fi

  if [[ -n ${args[warp_license]} ]]; then
    args[warp]=ON
  fi
}

function backup {
  local backup_name
  local backup_password="$1"
  local backup_file_url
  local exit_code
  backup_name="reality-backup-$(date +%Y-%m-%d_%H-%M-%S).zip"
  cd "${config_path}"
  if [ -z "${backup_password}" ]; then
    zip -r "/tmp/${backup_name}" . > /dev/null
  else
    zip -P "${backup_password}" -r "/tmp/${backup_name}" . > /dev/null
  fi
  if ! backup_file_url=$(curl -fsS -m 30 -F "file=@/tmp/${backup_name}" "${backup_upload_url}"); then
    rm -f "/tmp/${backup_name}"
    echo "Error in uploading backup file" >&2
    return 1
  fi
  rm -f "/tmp/${backup_name}"
  echo "${backup_file_url}"
}

function restore {
  local backup_file="$1"
  local backup_password="$2"
  local temp_file
  local unzip_output
  local unzip_exit_code
  local current_state
  temp_file=$(mktemp)
  if [[ ! -r ${backup_file} ]]; then
    # The default uploader (temp.sh) returns a link that has to be POSTed back.
    # Any other endpoint is assumed to be a plain file server, so a failed GET
    # is retried as a POST to keep self-hosted endpoints working.
    if [[ "${backup_file}" =~ ^https?://temp\.sh/ ]]; then
      if ! curl -fSsL -m 30 -X POST "${backup_file}" -o "${temp_file}"; then
        echo "Cannot download or find backup file" >&2
        return 1
      fi
    else
      if ! curl -fSsL -m 30 "${backup_file}" -o "${temp_file}"; then
        if ! curl -fSsL -m 30 -X POST "${backup_file}" -o "${temp_file}"; then
          echo "Cannot download or find backup file" >&2
          return 1
        fi
      fi
    fi
    backup_file="${temp_file}"
  fi
  current_state=$(set +o)
  set +e
  if [[ -z "${backup_password}" ]]; then
    unzip_output=$(unzip -P "" -t "${backup_file}" 2>&1)
  else
    unzip_output=$(unzip -P "${backup_password}" -t "${backup_file}" 2>&1)
  fi
  unzip_exit_code=$?
  eval "$current_state"
  if [[ ${unzip_exit_code} -eq 0 ]]; then
    if ! echo "${unzip_output}" | grep -q 'config'; then
      echo "The provided file is not a reality backup file." >&2
      rm -f "${temp_file}"
      return 1
    fi
  else
    if echo "${unzip_output}" | grep -q 'incorrect password'; then
      echo "The provided password for backup file is incorrect." >&2
    else
      echo "An error occurred during zip file verification: ${unzip_output}" >&2
    fi
    rm -f "${temp_file}"
    return 1
  fi
  rm -rf "${config_path}"
  mkdir -p "${config_path}"
  set +e
  if [[ -z "${backup_password}" ]]; then
    unzip_output=$(unzip -d "${config_path}" "${backup_file}" 2>&1)
  else
    unzip_output=$(unzip -P "${backup_password}" -d "${config_path}" "${backup_file}" 2>&1)
  fi
  unzip_exit_code=$?
  eval "$current_state"
  if [[ ${unzip_exit_code} -ne 0 ]]; then
    echo "Error in backup restore: ${unzip_output}" >&2
    rm -f "${temp_file}"
    return 1
  fi
  rm -f "${temp_file}"
  return
}

function dict_expander {
  local -n dict=$1
  for key in "${!dict[@]}"; do
    echo "${key} ${dict[$key]}"
  done
}

function parse_config_file {
  if [[ ! -r "${path[config]}" ]]; then
    generate_keys
    return 0
  fi
  while IFS= read -r line; do
    if [[ "${line}" =~ ^\s*# ]] || [[ "${line}" =~ ^\s*$ ]]; then
      continue
    fi
    key=$(echo "$line" | cut -d "=" -f 1)
    value=$(echo "$line" | cut -d "=" -f 2-)
    config_file["${key}"]="${value}"
  done < "${path[config]}"
  if [[ -z "${config_file[public_key]}" || \
        -z "${config_file[private_key]}" || \
        -z "${config_file[short_id]}" || \
        -z "${config_file[service_path]}" ]]; then
    generate_keys
  fi
  return 0
}

function parse_users_file {
  mkdir -p "$config_path"
  touch "${path[users]}"
  while read -r line; do
    if [[ "${line}" =~ ^\s*# ]] || [[ "${line}" =~ ^\s*$ ]]; then
      continue
    fi
    IFS="=" read -r key value <<< "${line}"
    users["${key}"]="${value}"
  done < "${path[users]}"
  if [[ -n ${args[add_user]} ]]; then
    if [[ -z "${users["${args[add_user]}"]}" ]]; then
      users["${args[add_user]}"]=$(cat /proc/sys/kernel/random/uuid)
    else
      echo 'User "'"${args[add_user]}"'" already exists.'
    fi
  fi
  if [[ -n ${args[delete_user]} ]]; then
    if [[ -n "${users["${args[delete_user]}"]}" ]]; then
      if [[ ${#users[@]} -eq 1 ]]; then
        echo -e "You cannot delete the only user.\nAt least one user is needed.\nCreate a new user, then delete this one."
        exit 1
      fi
      unset users["${args[delete_user]}"]
    else
      echo "User "${args[delete_user]}" does not exists."
      exit 1
    fi
  fi
  if [[ ${#users[@]} -eq 0 ]]; then
    users[Reality]=$(cat /proc/sys/kernel/random/uuid)
    echo "Reality=${users[Reality]}" >> "${path[users]}"
    return 0
  fi
  return 0
}

function restore_defaults {
  local defaults_items=("${!defaults[@]}")
  local keep=false
  local exclude_list=(
    "warp_license"
    "tgbot_token"
  )
  if [[ -n ${config[warp_id]} && -n ${config[warp_token]} ]]; then
    warp_delete_account "${config[warp_id]}" "${config[warp_token]}"
  fi
  for item in "${defaults_items[@]}"; do
    keep=false
    for i in "${exclude_list[@]}"; do
      if [[ "${i}" == "${item}" ]]; then
        keep=true
        break
      fi
    done
    if [[ ${keep} == true ]]; then
      continue
    fi
    config["${item}"]="${defaults[${item}]}"
  done
}

function build_config {
  local free_80=true
  if [[ ${args[regenerate]} == true ]]; then
    generate_keys
  fi
  for item in "${config_items[@]}"; do
    if [[ -n ${args["${item}"]} ]]; then
      config["${item}"]="${args[${item}]}"
    elif [[ -n ${config_file["${item}"]} ]]; then
      config["${item}"]="${config_file[${item}]}"
    else
      config["${item}"]="${defaults[${item}]}"
    fi
  done
  # The address is auto-detected from cloudflare, but that lookup is time boxed
  # now, so an unreachable network leaves it empty. Fail with a hint instead of
  # generating a client configuration pointing at an empty address.
  if [[ -z ${config[server]} ]]; then
    echo 'Cannot determine the server address automatically. Specify it with "--server <ip-or-domain>".'
    exit 1
  fi
  if [[ ${args[default]} == true ]]; then
    restore_defaults
    return 0
  fi
  if [[ ${config[tgbot]} == 'ON' && -z ${config[tgbot_token]} ]]; then
    echo 'To enable Telegram bot, you have to give the token of bot with --tgbot-token option.'
    exit 1
  fi
  if [[ ${config[tgbot]} == 'ON' && -z ${config[tgbot_admins]} ]]; then
    echo 'To enable Telegram bot, you have to give the list of authorized Telegram admins username with --tgbot-admins option.'
    exit 1
  fi
  if [[ ! ${config[server]} =~ ${regex[domain]} && ${config[security]} == 'letsencrypt' ]]; then
    echo 'You have to assign a domain to server with "--server <domain>" option if you want to use "letsencrypt" as TLS certificate.'
    exit 1
  fi
  if [[ ${config[transport]} == 'ws' && ${config[security]} == 'reality' ]]; then
    echo 'You cannot use "ws" transport with "reality" TLS certificate. Use other transports or change TLS certificate to letsencrypt or selfsigned'
    exit 1
  fi
  if [[ ${config[transport]} == 'tuic' && ${config[security]} == 'reality' ]]; then
    echo 'You cannot use "tuic" transport with "reality" TLS certificate. Use other transports or change TLS certificate to letsencrypt or selfsigned'
    exit 1
  fi
  if [[ ${config[transport]} == 'tuic' && ${config[core]} == 'xray' ]]; then
    echo 'You cannot use "tuic" transport with "xray" core. Use other transports or change core to sing-box'
    exit 1
  fi
  if [[ ${config[transport]} == 'hysteria2' && ${config[security]} == 'reality' ]]; then
    echo 'You cannot use "hysteria2" transport with "reality" TLS certificate. Use other transports or change TLS certificate to letsencrypt or selfsigned'
    exit 1
  fi
  if [[ ${config[transport]} == 'hysteria2' && ${config[core]} == 'xray' ]]; then
    echo 'You cannot use "hysteria2" transport with "xray" core. Use other transports or change core to sing-box'
    exit 1
  fi
  if [[ ${config[transport]} == 'shadowtls' && ${config[core]} == 'xray' ]]; then
    echo 'You cannot use "shadowtls" transport with "xray" core. Use other transports or change core to sing-box'
    exit 1
  fi
  # letsencrypt is the only mode that needs a well-known port, because the ACME
  # HTTP-01 challenge is always served on port 80. It is an explicit opt-in, so
  # the HTTP side is pinned to 80 there; every other mode keeps the 80/443-free
  # defaults and never touches a well-known port.
  if [[ ${config[security]} == 'letsencrypt' ]]; then
    if [[ ${config[http_port]} != '80' ]]; then
      echo 'Note: letsencrypt needs port 80 for the ACME HTTP-01 challenge; it is used as the HTTP port for this mode.'
      config[http_port]=80
    fi
    if port_in_use 80; then
      free_80=false
      for container in $(${docker_cmd} -p ${compose_project} ps -q); do
        if docker port "${container}" | grep -q ':80$'; then
          free_80=true
          break
        fi
      done
    fi
    if [[ ${free_80} != 'true' ]]; then
      echo 'Port 80 must be free if you want to use "letsencrypt" as the security option.'
      exit 1
    fi
  elif [[ ${config[http_port]} == '80' ]]; then
    # Without letsencrypt there is no reason to claim port 80; keep the promise
    # that an installation only binds non-privileged ports.
    echo "Port 80 is only used by the letsencrypt mode; switching the HTTP port back to ${defaults[http_port]}."
    config[http_port]="${defaults[http_port]}"
  fi

  if [[ -n "${args[security]}" && "${args[security]}" == 'reality' && "${config_file[security]}" != 'reality' && "${config_file[transport]}" != 'shadowtls' && -z "${args[domain]}" ]]; then
    config[domain]="${config[camouflage]}"
  fi
  if [[ -n "${args[security]}" && "${args[security]}" != 'reality' && "${config_file[security]}" == 'reality' && "${config_file[transport]}" != 'shadowtls' ]]; then
    config[domain]="${config[server]}"
  fi
  
  if [[ -n "${args[transport]}" && "${args[transport]}" == 'shadowtls' && "${config_file[transport]}" != 'shadowtls' && "${config_file[security]}" != 'reality' && -z "${args[domain]}" ]]; then
    config[domain]="${config[camouflage]}"
  fi
  if [[ -n "${args[transport]}" && "${args[transport]}" != 'shadowtls' && "${config_file[transport]}" == 'shadowtls' && "${config_file[security]}" != 'reality' ]]; then
    config[domain]="${config[server]}"
  fi

  if [[ -n "${args[server]}" && "${config[security]}" != 'reality' && "${config[transport]}" != 'shadowtls' ]]; then
    config[domain]="${config[server]}"
  fi

  # The camouflage target only exists in the reality and shadowtls modes, where
  # anything that does not authenticate gets relayed to it. Supplying just one of
  # --camouflage / --domain keeps the two in sync, because the certificate the
  # camouflage site returns has to match the SNI a probe sends - a mismatch is
  # exactly what an active probe looks for.
  if [[ ${config[security]} == 'reality' || ${config[transport]} == 'shadowtls' ]]; then
    # Upgrading from a version where "domain" served as the camouflage target as
    # well: carry the configured value over instead of silently switching the
    # fallback to the default site (which would break the SNI/certificate match).
    if [[ -z ${config_file[camouflage]} && -z ${args[camouflage]} && -n ${config_file[domain]} ]]; then
      config[camouflage]="${config[domain]}"
    fi
    if [[ -n "${args[camouflage]}" && -z "${args[domain]}" ]]; then
      config[domain]="${config[camouflage]%%:*}"
    elif [[ -n "${args[domain]}" && -z "${args[camouflage]}" ]]; then
      config[camouflage]="${config[domain]}"
    fi
    if [[ ${config[camouflage]%%:*} != ${config[domain]%%:*} ]]; then
      echo "Warning: the SNI (${config[domain]%%:*}) differs from the camouflage site (${config[camouflage]%%:*})."
      echo 'A probe sends the SNI and compares the certificate it gets back against it, so those are expected to be the same domain.'
    fi
  fi

  if [[ -n "${args[warp]}" && "${args[warp]}" == 'OFF' && "${config_file[warp]}" == 'ON' ]]; then
    if [[ -n ${config[warp_id]} && -n ${config[warp_token]} ]]; then
      warp_delete_account "${config[warp_id]}" "${config[warp_token]}"
    fi
  fi
  if { [[ -n "${args[warp]}" && "${args[warp]}" == 'ON' && "${config_file[warp]}" == 'OFF' ]] || \
       [[ "${config[warp]}" == 'ON' && ( -z ${config[warp_private_key]} || \
                                         -z ${config[warp_token]} || \
                                         -z ${config[warp_id]} || \
                                         -z ${config[warp_client_id]} || \
                                         -z ${config[warp_interface_ipv4]} || \
                                         -z ${config[warp_interface_ipv6]} ) ]]; }; then
    config[warp]='OFF'
    warp_create_account || exit 1
    config[warp]='ON'
  fi
  if [[ -n "${args[warp_license]}" && ( -z "${config_file[warp_license]}" || "${args[warp_license]}" != "${config_file[warp_license]}" ) ]]; then
    if ! warp_add_license "${config[warp_id]}" "${config[warp_token]}" "${args[warp_license]}"; then
      config[warp_license]=""
      echo "WARP+ license error! Please check your license and try again."
      exit 1
    fi 
  fi
}

# Configuration writes mark the state dirty instead of always regenerating and
# restarting services. While RELOAD_DEFERRED is 1 (during startup) the reload is
# postponed, so a single flush_reload at the end replaces the repeated reloads.
function mark_config_dirty {
  RELOAD_PENDING=1
  if [[ ${RELOAD_DEFERRED} -ne 1 ]]; then
    check_reload
  fi
}

function flush_reload {
  if [[ ${RELOAD_PENDING} -eq 1 ]]; then
    check_reload
  fi
}

# Rewrite the config file through a temporary file and move it into place, so a
# crash can never leave a truncated config behind. Unknown keys are preserved
# and values are written verbatim (no sed escaping pitfalls).
function update_config_file {
  local item
  local key
  local line
  local temp_file
  local -A handled
  mkdir -p "${config_path}"
  touch "${path[config]}"
  temp_file=$(mktemp "${config_path}/.config.XXXXXX")
  while IFS= read -r line || [[ -n ${line} ]]; do
    if [[ ${line} != *=* ]]; then
      printf '%s\n' "${line}" >> "${temp_file}"
      continue
    fi
    key=${line%%=*}
    if [[ ${key} =~ ^[a-zA-Z0-9_]+$ && -n ${config_item_lookup[${key}]:-} ]]; then
      printf '%s=%s\n' "${key}" "${config[${key}]}" >> "${temp_file}"
      handled["${key}"]=1
    else
      printf '%s\n' "${line}" >> "${temp_file}"
    fi
  done < "${path[config]}"
  for item in "${config_items[@]}"; do
    if [[ -z ${handled[${item}]:-} ]]; then
      printf '%s=%s\n' "${item}" "${config[${item}]}" >> "${temp_file}"
    fi
  done
  mv -f "${temp_file}" "${path[config]}"
  mark_config_dirty
}

function update_users_file {
  local user
  local temp_file
  mkdir -p "${config_path}"
  temp_file=$(mktemp "${config_path}/.users.XXXXXX")
  for user in "${!users[@]}"; do
    printf '%s=%s\n' "${user}" "${users[${user}]}" >> "${temp_file}"
  done
  mv -f "${temp_file}" "${path[users]}"
  mark_config_dirty
}

function generate_keys {
  local key_pair
  key_pair=$(docker run --rm ${image[sing-box]} generate reality-keypair)
  config_file[public_key]=$(echo "${key_pair}" | grep 'PublicKey' | awk '{print $2}')
  config_file[private_key]=$(echo "${key_pair}" | grep 'PrivateKey' | awk '{print $2}')
  config_file[short_id]=$(openssl rand -hex 8)
  config_file[service_path]=$(openssl rand -hex 4)
}

function uninstall {
  if docker compose >/dev/null 2>&1; then
    docker compose --project-directory "${config_path}" down --timeout 2 || true
    docker compose --project-directory "${config_path}" -p ${compose_project} down --timeout 2 || true
    docker compose --project-directory "${config_path}/tgbot" -p ${tgbot_project} down --timeout 2 || true
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose --project-directory "${config_path}" down --timeout 2 || true
    docker-compose --project-directory "${config_path}" -p ${compose_project} down --timeout 2 || true
    docker-compose --project-directory "${config_path}/tgbot" -p ${tgbot_project} down --timeout 2 || true
  fi
  rm -rf "${config_path}"
  echo "Reality uninstalled successfully."
  exit 0
}

function install_packages {
  local package
  local packages=()
  local -a yum_packages=()
  # The tgbot container ships every tool the script needs, so nothing has to be
  # installed there.
  if [[ -n $BOT_TOKEN ]]; then
    return 0
  fi
  # `command -v` is a shell builtin, so this works even on minimal images where
  # `which` itself is missing. Only missing packages are installed instead of
  # reinstalling the whole set on every invocation.
  # xxd is deliberately absent: warp_decode_reserved no longer depends on it.
  # openssl is required for the self-signed certificate and for the WARP key
  # pair (X25519, so OpenSSL 1.1.0+).
  for package in curl openssl qrencode whiptail jq zip unzip; do
    if ! command -v "${package}" >/dev/null 2>&1; then
      packages+=("${package}")
    fi
  done
  if [[ ${#packages[@]} -eq 0 ]]; then
    return 0
  fi
  if command -v apt >/dev/null 2>&1; then
    apt update
    DEBIAN_FRONTEND=noninteractive apt install "${packages[@]}" -y
    return 0
  fi
  if command -v yum >/dev/null 2>&1; then
    for package in "${packages[@]}"; do
      case ${package} in
        whiptail) yum_packages+=(newt) ;;
        *) yum_packages+=("${package}") ;;
      esac
    done
    yum makecache
    yum install epel-release -y || true
    yum install "${yum_packages[@]}" -y
    return 0
  fi
  echo "OS is not supported!"
  return 1
}

function install_docker {
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL -m 30 https://get.docker.com | bash
    if ! command -v docker >/dev/null 2>&1; then
      echo "Docker installation has been failed!" >&2
      return 1
    fi
    systemctl enable --now docker
    docker_cmd="docker compose"
    return 0
  fi
  if docker compose >/dev/null 2>&1; then
    docker_cmd="docker compose"
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    docker_cmd="docker-compose"
    return 0
  fi
  # The compose binary is ~60MB, so the 30s budget of the old version regularly
  # timed out on slower links and left a truncated binary behind.
  if ! curl -fsSL -m 120 "https://github.com/docker/compose/releases/download/v2.28.0/docker-compose-linux-$(uname -m)" -o /usr/local/bin/docker-compose; then
    echo "Docker compose installation has been failed!" >&2
    return 1
  fi
  chmod +x /usr/local/bin/docker-compose
  docker_cmd="docker-compose"
  return 0
}

function generate_docker_compose {
  # The official images are run with an explicit command: the engine binary is
  # addressed directly instead of relying on the image default CMD (the official
  # xray image defaults to "-confdir /usr/local/etc/xray/", which would ignore
  # the mounted configuration).
  local engine_command
  if [[ ${config[core]} == 'xray' ]]; then
    engine_command='["run", "-c", "/etc/xray/config.json"]'
  else
    engine_command='["run", "-c", "/etc/sing-box/config.json"]'
  fi
  cat >"${path[compose]}" <<EOF
version: "3"
networks:
  reality:
    driver: bridge
    enable_ipv6: true
    ipam:
      config:
      - subnet: fc11::1:0/112
services:
  engine:
    image: ${image[${config[core]}]}
    command: ${engine_command}
    $([[ ${config[security]} == 'reality' || ${config[transport]} == 'shadowtls' ]] && echo "ports:" || true)
    $([[ ${config[security]} == 'reality' || ${config[transport]} == 'shadowtls' ]] && echo "- ${config[port]}:8443" || true)
    $([[ ${config[transport]} == 'tuic' || ${config[transport]} == 'hysteria2' ]] && echo "ports:" || true)
    $([[ ${config[transport]} == 'tuic' || ${config[transport]} == 'hysteria2' ]] && echo "- ${config[port]}:8443/udp" || true)
    $([[ ${config[security]} != 'reality' && ${config[transport]} != 'shadowtls' ]] && echo "expose:" || true)
    $([[ ${config[security]} != 'reality' && ${config[transport]} != 'shadowtls' ]] && echo "- 8443" || true)
    restart: always
    environment:
      TZ: Etc/UTC
    volumes:
    - ./${path[engine]#${config_path}/}:/etc/${config[core]}/config.json
    $([[ ${config[security]} != 'reality' ]] && { [[ ${config[transport]} == 'http' ]] || [[ ${config[transport]} == 'tcp' ]] || [[ ${config[transport]} == 'tuic' ]] || [[ ${config[transport]} == 'hysteria2' ]]; } && echo "- ./${path[server_crt]#${config_path}/}:/etc/${config[core]}/server.crt" || true)
    $([[ ${config[security]} != 'reality' ]] && { [[ ${config[transport]} == 'http' ]] || [[ ${config[transport]} == 'tcp' ]] || [[ ${config[transport]} == 'tuic' ]] || [[ ${config[transport]} == 'hysteria2' ]]; } && echo "- ./${path[server_key]#${config_path}/}:/etc/${config[core]}/server.key" || true)
    networks:
    - reality
$(if [[ (${config[security]} != 'reality' && ${config[transport]} != 'shadowtls') || ${config[http_port]} != 'OFF' ]]; then
echo "
  nginx:
    image: ${image[nginx]}
$(if [[ ${config[security]} == 'reality' || ${config[transport]} == 'shadowtls' ]]; then echo "
    ports:
    - ${config[http_port]}:80"; else echo "
    expose:
    - 80"; fi)
    restart: always
    volumes:
    - ./website:/usr/share/nginx/html
    networks:
    - reality"
fi)
$(if [[ ${config[security]} != 'reality' && ${config[transport]} != 'shadowtls' ]]; then
echo "
  haproxy:
    image: ${image[haproxy]}
    ports:
    - ${config[port]}:8443
    $([[ ${config[http_port]} != 'OFF' ]] && echo "- ${config[http_port]}:8080" || true)
    restart: always
    volumes:
    - ./${path[haproxy]#${config_path}/}:/usr/local/etc/haproxy/haproxy.cfg
    - ./${path[server_pem]#${config_path}/}:/usr/local/etc/haproxy/server.pem
    networks:
    - reality"
fi)
$(if [[ ${config[security]} == 'letsencrypt' && ${config[transport]} != 'shadowtls' ]]; then
echo "
  certbot:
    build:
      context: ./certbot
    expose:
    - 80
    restart: always
    volumes:
    - /var/run/docker.sock:/var/run/docker.sock
    - ./certbot/data:/etc/letsencrypt
    - ./$(dirname "${path[server_pem]#${config_path}/}"):/certificate
    - ./${path[certbot_deployhook]#${config_path}/}:/deployhook.sh
    - ./${path[certbot_startup]#${config_path}/}:/startup.sh
    - ./website:/website
    networks:
    - reality
    entrypoint: /bin/sh
    command: /startup.sh"
fi)
EOF
}

function generate_tgbot_compose {
  cat >"${path[tgbot_compose]}" <<EOF
version: "3"
networks:
  tgbot:
    driver: bridge
    enable_ipv6: true
    ipam:
      config:
      - subnet: fc11::2:0/112
services:
  tgbot:
    build: ./
    restart: always
    environment:
      BOT_TOKEN: ${config[tgbot_token]}
      BOT_ADMIN: ${config[tgbot_admins]}
    volumes:
    - /var/run/docker.sock:/var/run/docker.sock
    - ../:${config_path}
    - /etc/docker/:/etc/docker/
    networks:
    - tgbot
EOF
}

# nginx serves the local website out of ./website. The placeholder page is only
# written when nothing is there yet, so a site put in place by the operator is
# never overwritten by an upgrade.
function generate_website {
  mkdir -p "${config_path}/website"
  if [[ -e "${path[website]}" ]]; then
    return 0
  fi
  cat >"${path[website]}" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Welcome</title>
<style>
  body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #f5f6f8; color: #23272f; }
  main { max-width: 640px; margin: 0 auto; padding: 14vh 24px; }
  h1 { margin: 0 0 12px; font-size: 22px; font-weight: 600; }
  p { margin: 0 0 10px; line-height: 1.7; color: #4a515c; }
</style>
</head>
<body>
<main>
<h1>Welcome</h1>
<p>This site is up and running.</p>
<p>Content will appear here shortly.</p>
</main>
</body>
</html>
EOF
}

function generate_haproxy_config {
echo "
global
  ssl-default-bind-options ssl-min-ver TLSv1.2
defaults
  option http-server-close
  timeout connect 5s
  timeout client 50s
  timeout client-fin 1s
  timeout server-fin 1s
  timeout server 50s
  timeout tunnel 50s
  timeout http-keep-alive 1s
  timeout queue 15s
frontend http
  mode http
  bind :::8080 v4v6
$(if [[ ${config[security]} == 'letsencrypt' ]]; then echo "
  use_backend certbot if { path_beg /.well-known/acme-challenge }
  acl letsencrypt-acl path_beg /.well-known/acme-challenge
  redirect scheme https if !letsencrypt-acl
"; fi)
  use_backend default
frontend tls
$(if [[ ${config[transport]} != 'tcp' ]]; then echo "
  bind :::8443 v4v6 ssl crt /usr/local/etc/haproxy/server.pem alpn h2,http/1.1
  mode http
  http-request set-header Host ${config[server]}
$(if [[ ${config[security]} == 'letsencrypt' ]]; then echo "
  use_backend certbot if { path_beg /.well-known/acme-challenge }
"; fi)
$(if [[ ${config[transport]} != 'tuic' && ${config[transport]} != 'hysteria2' ]]; then echo "
  use_backend engine if { path_beg /${config[service_path]} }
"; fi)
  use_backend default
"; else echo "
  bind :::8443 v4v6
  mode tcp
  use_backend engine
"; fi)
$(if [[ ${config[transport]} != 'tuic' && ${config[transport]} != 'hysteria2' ]]; then echo "
backend engine
  retry-on conn-failure empty-response response-timeout
$(if [[ ${config[transport]} != 'tcp' ]]; then echo "
  mode http
"; else echo "
  mode tcp
"; fi)
$(if [[ ${config[transport]} == 'grpc' ]]; then echo "
  server engine engine:8443 check tfo proto h2
"; elif [[ ${config[transport]} == 'http' && ${config[core]} == 'sing-box' ]]; then echo "
  server engine engine:8443 check tfo proto h2 ssl verify none
"; elif [[ ${config[transport]} == 'http' && ${config[core]} != 'sing-box' ]]; then echo "
  server engine engine:8443 check tfo ssl verify none
"; else echo "
  server engine engine:8443 check tfo
"; fi)
"; fi)
$(if [[ ${config[security]} == 'letsencrypt' ]]; then echo "
backend certbot
  mode http
  server certbot certbot:80
"; fi)
backend default
  mode http
  server nginx nginx:80
" | grep -vE '^\s*$' > "${path[haproxy]}"
}

function generate_certbot_script {
  cat >"${path[certbot_startup]}" << EOF
#!/bin/sh
trap exit TERM
fullchain_path=/etc/letsencrypt/live/${config[server]}/fullchain.pem
if [[ -r "\${fullchain_path}" ]]; then
  fullchain_fingerprint=\$(openssl x509 -noout -fingerprint -sha256 -in "\${fullchain_path}" 2>/dev/null |\
awk -F= '{print \$2}' | tr -d : | tr '[:upper:]' '[:lower:]')
  installed_fingerprint=\$(openssl x509 -noout -fingerprint -sha256 -in /certificate/server.pem 2>/dev/null |\
awk -F= '{print \$2}' | tr -d : | tr '[:upper:]' '[:lower:]')
  if [[ \$fullchain_fingerprint != \$installed_fingerprint ]]; then
    /deployhook.sh /certificate ${compose_project} ${config[server]} ${service[server_crt]} $([[ ${config[transport]} != 'tcp' ]] && echo "${service[server_pem]}" || true)
  fi
fi
while true; do
  ls -d /website/* | grep -E '^/website/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\$'|xargs rm -f
  uuid=\$(uuidgen)
  echo "\$uuid" > "/website/\$uuid"
  response=\$(curl -skL --max-time 3 http://${config[server]}/\$uuid)
  if echo "\$response" | grep \$uuid >/dev/null; then
    break
  fi
  echo "Domain ${config[server]} is not pointing to the server"
  sleep 5
done
ls -d /website/* | grep -E '^/website/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\$'|xargs rm -f
while true; do
  certbot certonly -n \\
    --standalone \\
    --key-type ecdsa \\
    --elliptic-curve secp256r1 \\
    --agree-tos \\
    --register-unsafely-without-email \\
    -d ${config[server]} \\
    --deploy-hook "/deployhook.sh /certificate ${compose_project} ${config[server]} ${service[server_crt]} $([[ ${config[transport]} != 'tcp' ]] && echo "${service[server_pem]}" || true)"
  sleep 1h &
  wait \$!
done
EOF
}

function generate_certbot_deployhook {
  cat >"${path[certbot_deployhook]}" << EOF
#!/bin/sh
cert_path=\$1
compose_project=\$2
domain=\$3
renewed_path=/etc/letsencrypt/live/\$domain
cat "\$renewed_path/fullchain.pem" > "\$cert_path/server.crt"
cat "\$renewed_path/privkey.pem" > "\$cert_path/server.key"
cat "\$renewed_path/fullchain.pem" "\$renewed_path/privkey.pem" > "\$cert_path/server.pem"
i=4
while [ \$i -le \$# ]; do
  eval service=\\\${\$i}
  docker compose -p "${compose_project}" restart --timeout 2 "\$service"
  i=\$((i+1))
done
EOF
  chmod +x "${path[certbot_deployhook]}"
}

function generate_certbot_dockerfile {
  cat >"${path[certbot_dockerfile]}" << EOF
FROM ${image[certbot]}
RUN apk add --no-cache docker-cli-compose curl uuidgen
EOF
}

function generate_tgbot_dockerfile {
  cat >"${path[tgbot_dockerfile]}" << EOF
FROM ${image[python]}
WORKDIR ${config_path}/tgbot
RUN apk add --no-cache docker-cli-compose curl bash newt libqrencode-tools sudo openssl jq zip unzip
RUN pip install --no-cache-dir python-telegram-bot==13.5 qrcode[pil]==7.4.2
CMD [ "python", "./tgbot.py" ]
EOF
}

function download_tgbot_script {
  # Pulled from this project's own repository rather than from a personal fork.
  # Downloaded into a temporary file first: a failed or truncated download must
  # never clobber the working copy that a previous run left behind.
  local url="https://raw.githubusercontent.com/${repo_owner}/${repo_name}/${repo_branch}/tgbot.py"
  local temp_file
  temp_file=$(mktemp "${config_path}/tgbot/.tgbot-py.XXXXXX")
  if ! curl -fsSL -m 30 "${url}" -o "${temp_file}"; then
    rm -f "${temp_file}"
    echo "Downloading tgbot.py from ${url} has been failed!" >&2
    return 1
  fi
  if [[ ! -s ${temp_file} ]]; then
    rm -f "${temp_file}"
    echo "The tgbot.py downloaded from ${url} is empty!" >&2
    return 1
  fi
  mv -f "${temp_file}" "${path[tgbot_script]}"
  return 0
}

function install_local_script_copy {
  # Keep a copy of this script inside the configuration directory. Operators are
  # told to manage the server through ${config_path}/reality.sh, and the
  # Telegram bot container mounts that directory and prefers this local copy over
  # downloading anything at runtime - so it has to exist whether or not the bot is
  # enabled. Everything is written to a temporary file and moved into place, so a
  # failed or truncated copy can never replace a working one.
  local url="https://raw.githubusercontent.com/${repo_owner}/${repo_name}/${repo_branch}/reality.sh"
  local target="${config_path}/reality.sh"
  local temp_file="${config_path}/.reality.sh.$$"
  local source_file=${BASH_SOURCE[0]:-}
  # `bash <(curl ...)` and `bash /dev/stdin` leave BASH_SOURCE[0] pointing at a
  # pipe that this very interpreter has already drained, so copying from it would
  # silently produce an empty file. Those paths are recognised by name rather than
  # by `-p`, because the test for a fifo is not portable.
  case ${source_file} in
    /dev/fd/*|/dev/stdin|/proc/*/fd/*) source_file='' ;;
  esac
  mkdir -p "${config_path}"
  if [[ -n ${source_file} && -f ${source_file} && -r ${source_file} && ! -p ${source_file} ]]; then
    # Already running from the installed copy: nothing to do, and rewriting the
    # file this very process is executing from would be pointless.
    if [[ "${source_file}" -ef "${target}" ]]; then
      return 0
    fi
    # A copy that is empty or does not parse is worse than none at all: it would
    # replace a working script with a broken one, so it is validated before use.
    if cp -f "${source_file}" "${temp_file}" 2>/dev/null \
      && [[ -s ${temp_file} ]] && bash -n "${temp_file}" 2>/dev/null; then
      chmod 755 "${temp_file}"
      mv -f "${temp_file}" "${target}"
      return 0
    fi
    rm -f "${temp_file}"
  fi
  if ! curl -fsSL -m 30 "${url}" -o "${temp_file}"; then
    rm -f "${temp_file}"
    echo "Could not place reality.sh in ${config_path}: no usable local copy and ${url} is unreachable." >&2
    return 1
  fi
  if [[ ! -s ${temp_file} ]] || ! bash -n "${temp_file}" 2>/dev/null; then
    rm -f "${temp_file}"
    echo "The reality.sh downloaded from ${url} is empty or truncated!" >&2
    return 1
  fi
  chmod 755 "${temp_file}"
  mv -f "${temp_file}" "${target}"
  return 0
}

function generate_selfsigned_certificate {
  openssl ecparam -name prime256v1 -genkey -out "${path[server_key]}"
  openssl req -new -key "${path[server_key]}" -out /tmp/server.csr -subj "/CN=${config[server]}"
  openssl x509 -req -days 365 -in /tmp/server.csr -signkey "${path[server_key]}" -out "${path[server_crt]}"
  cat "${path[server_key]}" "${path[server_crt]}" > "${path[server_pem]}"
  # The official engine images drop privileges (xray runs as uid 65532), so the
  # mounted material has to stay world readable even under a strict umask.
  chmod 644 "${path[server_key]}" "${path[server_crt]}" "${path[server_pem]}"
  rm -f /tmp/server.csr
}

function generate_engine_config {
  local type="vless"
  local users_object=""
  local reality_object=""
  local tls_object=""
  local warp_object=""
  # The camouflage site is what unauthenticated probes reach; it is a separate
  # deployment input from the SNI, and its optional ":port" suffix defaults to 443.
  local camouflage_host="${config[camouflage]%%:*}"
  local reality_port=443
  local temp_file
  if [[ ${config[transport]} == 'tuic' ]]; then
    type='tuic'
  elif [[ ${config[transport]} == 'hysteria2' ]]; then
    type='hysteria2'
  elif [[ ${config[transport]} == 'shadowtls' ]]; then
    type='shadowtls'
  else
    type='vless'
  fi
  if [[ (${config[security]} == 'reality' || ${config[transport]} == 'shadowtls') && ${config[camouflage]} =~ ":" ]]; then
    reality_port="${config[camouflage]#*:}"
  fi
  if [[ ${config[core]} == 'sing-box' ]]; then
    reality_object='"tls": {
      "enabled": true,
      "server_name": "'"${config[domain]%%:*}"'",
      "alpn": [],
      "reality": {
        "enabled": true,
        "handshake": {
          "server": "'"${camouflage_host}"'",
          "server_port": '"${reality_port}"'
        },
        "private_key": "'"${config[private_key]}"'",
        "short_id": ["'"${config[short_id]}"'"],
        "max_time_difference": "1m"
      }
    }'
    tls_object='"tls": {
      "enabled": true,
      "certificate_path": "/etc/sing-box/server.crt",
      "key_path": "/etc/sing-box/server.key"
    }'
    if [[ ${config[warp]} == 'ON' ]]; then
      warp_object='{
        "type": "wireguard",
        "tag": "warp",
        "system": false,
        "name": "wg0",
        "mtu": 1280,
        "address": [
          "'"${config[warp_interface_ipv4]}"'/32",
          "'"${config[warp_interface_ipv6]}"'/128"
        ],
        "private_key": "'"${config[warp_private_key]}"'",
        "listen_port": 0,
        "peers": [
          {
            "address": "engage.cloudflareclient.com",
            "port": 2408,
            "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
            "allowed_ips": [
              "0.0.0.0/0"
            ],
            "persistent_keepalive_interval": 30,
            "reserved": '"$(warp_decode_reserved "${config[warp_client_id]}")"'
          }
        ]
      }'

    fi
    for user in "${!users[@]}"; do
      if [ -n "$users_object" ]; then
        users_object="${users_object},"$'\n'
      fi
      if [[ ${config[transport]} == 'tuic' ]]; then
        users_object=${users_object}'{"uuid": "'"${users[${user}]}"'", "password": "'"$(echo -n "${user}${users[${user}]}" | sha256sum | cut -d ' ' -f 1 | head -c 16)"'", "name": "'"${user}"'"}'
      elif [[ ${config[transport]} == 'hysteria2' ]]; then
        users_object=${users_object}'{"password": "'"$(echo -n "${user}${users[${user}]}" | sha256sum | cut -d ' ' -f 1 | head -c 16)"'", "name": "'"${user}"'"}'
      elif [[ ${config[transport]} == 'shadowtls' ]]; then
        users_object=${users_object}'{"password": "'"${users[${user}]}"'", "name": "'"${user}"'"}'
      else
        users_object=${users_object}'{"uuid": "'"${users[${user}]}"'", "flow": "'"$([[ ${config[transport]} == 'tcp' ]] && echo 'xtls-rprx-vision' || true)"'", "name": "'"${user}"'"}'
      fi
    done
    cat >"${path[engine]}" <<EOF
{
  "log": {
    "level": "error",
    "timestamp": true
  },
  "dns": {
    "servers": [
    $([[ ${config[safenet]} == ON ]] && echo '{"type": "tcp", "server": "1.1.1.3"}' || echo '{"type": "tcp", "server": "1.1.1.1"}')
    ],
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "${type}",
      "tag": "in",	
      "listen": "::",
      "listen_port": 8443,
      "users": [${users_object}],
      $(if [[ ${config[security]} == 'reality' && ${config[transport]} != 'shadowtls' ]]; then
        echo "${reality_object}"
      elif [[ ${config[transport]} == 'http' || ${config[transport]} == 'tcp' || ${config[transport]} == 'tuic' || ${config[transport]} == 'hysteria2' ]]; then
        echo "${tls_object}"
      elif [[ ${config[transport]} == 'shadowtls' ]]; then
        :
      else
        echo '"tls":{"enabled": false}'
      fi)
      $(if [[ ${config[transport]} == http ]]; then
      echo ',"transport": {"type": "http", "host": ["'"${config[server]}"'"], "path": "/'"${config[service_path]}"'"}'
      fi
      if [[ ${config[transport]} == grpc ]]; then
      echo ',"transport": {"type": "grpc","service_name": "'"${config[service_path]}"'"}'
      fi 
      if [[ ${config[transport]} == ws ]]; then
      echo ',"transport": {"type": "ws", "headers": {"Host": "'"${config[server]}"'"}, "path": "/'"${config[service_path]}"'"}'
      fi
      if [[ ${config[transport]} == tuic ]]; then
      echo ',"congestion_control": "bbr", "auth_timeout": "3s", "zero_rtt_handshake": false, "heartbeat": "10s"'
      fi
      if [[ ${config[transport]} == hysteria2 ]]; then
      echo ',"obfs": {"type": "salamander", "password": "'"${config[service_path]}"'"}, "ignore_client_bandwidth": true, "masquerade": "https://'"${config[server]}:${config[port]}"'"'
      fi
      if [[ ${config[transport]} == shadowtls ]]; then
      echo '"version": 3, "strict_mode": false, "detour": "shadowsocks", "handshake": {"server": "'"${camouflage_host}"'", "server_port": '"${reality_port}"'}'
      fi
      )
    }
    $(if [[ ${config[transport]} == 'shadowtls' ]]; then
    echo ', {
      "type": "shadowsocks",
      "tag": "shadowsocks",
      "listen": "127.0.0.1",
      "listen_port": 8444,
      "method": "chacha20-ietf-poly1305",
      "password": "'"${config[private_key]}"'",
      "users": ['"${users_object}"']
    }'
    fi )
  ],
  $([[ ${config[warp]} == ON ]] && echo '"endpoints": ['"${warp_object}"'],' || true)
  "outbounds": [
    {
      "type": "direct",
      "tag": "internet"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "final": "$([[ ${config[warp]} == ON ]] && echo "warp" || echo "internet")",
    "rule_set": [
      {
        "tag": "block",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs",
        "download_detour": "internet"
      },
      {
        "tag": "nsfw",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-porn.srs",
        "download_detour": "internet"
      },
      {
        "tag": "geosite-private",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-private.srs",
        "download_detour": "internet"
      },
      {
        "tag": "bypass",
        "type": "remote",
        "format": "binary",
        "url": "${ruleset_base_url}/bypass.srs",
        "download_detour": "internet"
      }
    ],
    "rules": [
      {
        "inbound": "in",
        "action": "resolve",
        "strategy": "prefer_ipv4"
      },
      {
        "inbound": "in",
        "action": "sniff",
        "timeout": "300ms"
      },
    $(if [[ ${config[transport]} == 'shadowtls' ]]; then
    echo '{
        "inbound": "shadowsocks",
        "action": "resolve",
        "strategy": "prefer_ipv4"
      },
      {
        "inbound": "shadowsocks",
        "action": "sniff",
        "timeout": "300ms"
      },'
    fi )
      {
        "rule_set": [
          "block",
          "geosite-private"
          $([[ ${config[safenet]} == ON ]] && echo ',"nsfw"' || true)
          $([[ ${config[warp]} == OFF ]] && echo ',"bypass"')
        ],
        "action": "reject"
      },
      {
        "ip_cidr": ${private_ip_cidr},
        "action": "reject"
      },
      {
        "network": "tcp",
        "port": [
          25,
          587,
          465,
          2525
        ],
        "action": "reject"
      }
    ]
  },
  "experimental": {
    "cache_file": {
      "enabled": true
    }
  }
}
EOF
  fi
  if [[ ${config[core]} == 'xray' ]]; then
    reality_object='"security":"reality",
    "realitySettings":{
      "show": false,
      "dest": "'"${camouflage_host}"':'"${reality_port}"'",
      "xver": 0,
      "serverNames": ["'"${config[domain]%%:*}"'"],
      "privateKey": "'"${config[private_key]}"'",
      "maxTimeDiff": 60000,
      "shortIds": ["'"${config[short_id]}"'"]
    }'
    tls_object='"security": "tls",
    "tlsSettings": {
      "certificates": [{
        "oneTimeLoading": true,
        "certificateFile": "/etc/xray/server.crt",
        "keyFile": "/etc/xray/server.key"
      }]
    }'
    if [[ ${config[warp]} == 'ON' ]]; then
      warp_object='{
        "protocol": "wireguard",
        "tag": "warp",
        "settings": {
          "secretKey": "'"${config[warp_private_key]}"'",
          "address": [
            "'"${config[warp_interface_ipv4]}"'/32",
            "'"${config[warp_interface_ipv6]}"'/128"
          ],
          "peers": [
            {
              "endpoint": "engage.cloudflareclient.com:2408",
              "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
            }
          ],
          "mtu": 1280
        }
      },'
    fi
    for user in "${!users[@]}"; do
      if [ -n "$users_object" ]; then
        users_object="${users_object},"$'\n'
      fi
      users_object=${users_object}'{"id": "'"${users[${user}]}"'", "flow": "'"$([[ ${config[transport]} == 'tcp' ]] && echo 'xtls-rprx-vision' || true)"'", "email": "'"${user}"'"}'
    done
    cat >"${path[engine]}" <<EOF
{
  "log": {
    "loglevel": "error"
  },
  "dns": {
    "servers": [$([[ ${config[safenet]} == ON ]] && echo '"tcp+local://1.1.1.3","tcp+local://1.0.0.3"' || echo '"tcp+local://1.1.1.1","tcp+local://1.0.0.1"')]
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 8443,
      "protocol": "vless",
      "tag": "inbound",
      "settings": {
        "clients": [${users_object}],
        "decryption": "none"
      },
      "streamSettings": {
        $([[ ${config[transport]} == 'tcp' ]] && echo '"tcpSettings": {"header": {"type": "none"}},' || true)
        $([[ ${config[transport]} == 'grpc' ]] && echo '"grpcSettings": {"serviceName": "'"${config[service_path]}"'"},' || true)
        $([[ ${config[transport]} == 'ws' ]] && echo '"wsSettings": {"headers": {"Host": "'"${config[server]}"'"}, "path": "/'"${config[service_path]}"'"},' || true)
        $([[ ${config[transport]} == 'http' ]] && echo '"xhttpSettings": {"host":"'"${config[server]}"'", "path": "/'"${config[service_path]}"'"},' || true)
        $([[ ${config[transport]} == 'http' ]] && echo '"network": "xhttp",' || echo '"network": "'"${config[transport]}"'",' )
        $(if [[ ${config[security]} == 'reality' ]]; then
          echo "${reality_object}"
        elif [[ ${config[transport]} == 'http' || ${config[transport]} == 'tcp' ]]; then
          echo "${tls_object}"
        else
          echo '"security":"none"'
        fi)
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "internet"
    },
    $([[ ${config[warp]} == ON ]] && echo "${warp_object}" || true)
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          $([[ ${config[warp]} == OFF ]] && echo '"geoip:cn", "geoip:ir",')
          "0.0.0.0/8",
          "10.0.0.0/8",
          "100.64.0.0/10",
          "127.0.0.0/8",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "::1/128",
          "fc00::/7",
          "fe80::/10",
          "geoip:private"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "port": "25, 587, 465, 2525",
        "network": "tcp",
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "outboundTag": "block",
        "domain": [
          $([[ ${config[safenet]} == ON ]] && echo '"geosite:category-porn",' || true)
          "geosite:category-ads-all",
          "domain:pushnotificationws.com",
          "domain:sunlight-leds.com",
          "domain:icecyber.org"
        ]
      },
      {
        "type": "field",
        "inboundTag": "inbound",
        "outboundTag": "$([[ ${config[warp]} == ON ]] && echo "warp" || echo "internet")"
      }
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 2,
        "connIdle": 120
      }
    }
  }
}
EOF
  fi
  if [[ -r ${config_path}/${config[core]}.patch ]]; then
    if ! jq empty ${config_path}/${config[core]}.patch; then
      echo "${config[core]}.patch is not a valid json file. Fix it or remove it!"
      exit 1
    fi
    temp_file=$(mktemp)
    jq -s add ${path[engine]} ${config_path}/${config[core]}.patch > ${temp_file}
    mv ${temp_file} ${path[engine]}
  fi
}

function generate_config {
  generate_docker_compose
  generate_engine_config
  generate_website
  if [[ ${config[security]} != "reality" && ${config[transport]} != 'shadowtls' ]]; then
    mkdir -p "${config_path}/certificate"
    generate_haproxy_config
    if [[ ! -r "${path[server_pem]}" || ! -r "${path[server_crt]}" || ! -r "${path[server_key]}" ]]; then
      generate_selfsigned_certificate
    fi
  fi
  if [[ ${config[security]} == "letsencrypt" && ${config[transport]} != 'shadowtls' ]]; then
    mkdir -p "${config_path}/certbot"
    generate_certbot_deployhook
    generate_certbot_dockerfile
    generate_certbot_script
  fi
  if [[ ${config[tgbot]} == "ON" ]]; then
    mkdir -p "${config_path}/tgbot"
    generate_tgbot_compose
    generate_tgbot_dockerfile
    # A failed refresh must not abort the whole run: keep the copy from the
    # previous installation and only warn.
    if ! download_tgbot_script; then
      if [[ -s ${path[tgbot_script]} ]]; then
        echo "Warning: could not refresh tgbot.py, keeping the existing copy." >&2
      else
        echo "Warning: could not download tgbot.py, the Telegram bot image cannot be built." >&2
      fi
    fi
  fi
  # Unconditional, and deliberately outside the bot branch above: this copy is the
  # entry point the documentation points operators at, and the bot container mount
  # picks it up as well. Failing to place it is a warning, not an error - the stack
  # is already configured by the time this runs.
  if ! install_local_script_copy; then
    echo "Warning: could not place reality.sh in ${config_path}; save this script to a file and run it again to retry." >&2
  fi
}

function get_ipv6 {
  curl -fsSL -m 3 --ipv6 https://cloudflare.com/cdn-cgi/trace 2> /dev/null | grep ip | cut -d '=' -f2
}

function print_client_configuration {
  local username=$1
  local client_config
  local ipv6
  local client_config_ipv6
  if [[ ${config[transport]} == 'tuic' ]]; then
    client_config="tuic://"
    client_config="${client_config}${users[${username}]}"
    client_config="${client_config}:$(echo -n "${username}${users[${username}]}" | sha256sum | cut -d ' ' -f 1 | head -c 16)"
    client_config="${client_config}@${config[server]}"
    client_config="${client_config}:${config[port]}"
    client_config="${client_config}/?congestion_control=bbr&udp_relay_mode=quic"
    client_config="${client_config}$([[ ${config[security]} == 'selfsigned' ]] && echo "&allow_insecure=1" || true)"
    client_config="${client_config}#${username}"
  elif [[ ${config[transport]} == 'hysteria2' ]]; then
    client_config="hy2://"
    client_config="${client_config}$(echo -n "${username}${users[${username}]}" | sha256sum | cut -d ' ' -f 1 | head -c 16)"
    client_config="${client_config}@${config[server]}"
    client_config="${client_config}:${config[port]}"
    client_config="${client_config}/?obfs=salamander&obfs-password=${config[service_path]}"
    client_config="${client_config}$([[ ${config[security]} == 'selfsigned' ]] && echo "&insecure=1" || true)"
    client_config="${client_config}#${username}"
  elif [[ ${config[transport]} == 'shadowtls' ]]; then
    client_config='{"dns":{"independent_cache":true,"rules":[{"domain":["dns.google"],"server":"dns-direct"}],"servers":[{"address":"https://dns.google/dns-query","address_resolver":"dns-direct","strategy":"ipv4_only","tag":"dns-remote"},{"address":"local","address_resolver":"dns-local","detour":"direct","strategy":"ipv4_only","tag":"dns-direct"},{"address":"local","detour":"direct","tag":"dns-local"},{"address":"rcode://success","tag":"dns-block"}]},"inbounds":[{"listen":"127.0.0.1","listen_port":6450,"override_address":"8.8.8.8","override_port":53,"tag":"dns-in","type":"direct"},{"domain_strategy":"","endpoint_independent_nat":true,"inet4_address":["172.19.0.1/28"],"mtu":9000,"sniff":true,"sniff_override_destination":false,"stack":"mixed","tag":"tun-in","auto_route":true,"type":"tun"},{"domain_strategy":"","listen":"127.0.0.1","listen_port":2080,"sniff":true,"sniff_override_destination":false,"tag":"mixed-in","type":"mixed"}],"log":{"level":"warning"},"outbounds":[{"method":"chacha20-ietf-poly1305","password":"'"${users[${username}]}"'","server":"127.0.0.1","server_port":1080,"type":"shadowsocks","udp_over_tcp":true,"domain_strategy":"","tag":"proxy","detour":"shadowtls"},{"password":"'"${users[${username}]}"'","server":"'"${config[server]}"'","server_port":'"${config[port]}"',"tls":{"enabled":true,"insecure":false,"server_name":"'"${config[domain]%%:*}"'","utls":{"enabled":true,"fingerprint":"chrome"}},"version":3,"type":"shadowtls","domain_strategy":"","tag":"shadowtls"},{"tag":"direct","type":"direct"},{"tag":"bypass","type":"direct"},{"tag":"block","type":"block"},{"tag":"dns-out","type":"dns"}],"route":{"auto_detect_interface":true,"rule_set":[],"rules":[{"outbound":"dns-out","port":[53]},{"inbound":["dns-in"],"outbound":"dns-out"},{"ip_cidr":["224.0.0.0/3","ff00::/8"],"outbound":"block","source_ip_cidr":["224.0.0.0/3","ff00::/8"]}]}}'
  else
    client_config="vless://"
    client_config="${client_config}${users[${username}]}"
    client_config="${client_config}@${config[server]}"
    client_config="${client_config}:${config[port]}"
    client_config="${client_config}?security=$([[ ${config[security]} == 'reality' ]] && echo reality || echo tls)"
    client_config="${client_config}&encryption=none"
    client_config="${client_config}&alpn=$([[ ${config[transport]} == 'ws' ]] && echo 'http/1.1' || echo 'h2,http/1.1')"
    client_config="${client_config}&headerType=none"
    client_config="${client_config}&fp=chrome"
    client_config="${client_config}&type=$([[ ${config[core]} == 'xray' && ${config[transport]} == 'http' ]] && echo 'xhttp' || echo "${config[transport]}")"
    client_config="${client_config}&flow=$([[ ${config[transport]} == 'tcp' ]] && echo 'xtls-rprx-vision' || true)"
    client_config="${client_config}&sni=${config[domain]%%:*}"
    client_config="${client_config}$([[ ${config[transport]} == 'ws' || ${config[transport]} == 'http' ]] && echo "&host=${config[server]}" || true)"
    client_config="${client_config}$([[ ${config[security]} == 'reality' ]] && echo "&pbk=${config[public_key]}" || true)"
    client_config="${client_config}$([[ ${config[security]} == 'reality' ]] && echo "&sid=${config[short_id]}" || true)"
    client_config="${client_config}$([[ ${config[transport]} == 'ws' || ${config[transport]} == 'http' ]] && echo "&path=%2F${config[service_path]}" || true)"
    client_config="${client_config}$([[ ${config[transport]} == 'grpc' ]] && echo '&mode=gun' || true)"
    client_config="${client_config}$([[ ${config[transport]} == 'grpc' ]] && echo "&serviceName=${config[service_path]}" || true)"
    client_config="${client_config}#${username}"
  fi
  echo ""
  echo "=================================================="
  echo "Client configuration:"
  echo ""
  echo "$client_config"
  echo ""
  echo "Or you can scan the QR code:"
  echo ""
  qrencode -t ansiutf8 "${client_config}"
  ipv6=$(get_ipv6)
  if [[ -n $ipv6 ]]; then
    if [[ ${config[transport]} != 'shadowtls' ]]; then
      client_config_ipv6=$(echo "$client_config" | sed "s/@${config[server]//./\\.}:/@[${ipv6}]:/" | sed "s/#${username}/#${username}-ipv6/")
    else
      client_config_ipv6=$(echo "$client_config" | sed "s/\"server\":\"${config[server]//./\\.}\"/\"server\":\"${ipv6}\"/")
    fi
    echo ""
    echo "==================IPv6 Config======================"
    echo "Client configuration:"
    echo ""
    echo "$client_config_ipv6"
    echo ""
    echo "Or you can scan the QR code:"
    echo ""
    qrencode -t ansiutf8 "${client_config_ipv6}"
  fi
}

function migrate_legacy_install {
  # Releases before this one kept everything in /opt/reality-ezpz. The tree is
  # moved rather than copied because it holds the Reality key pair, the short id,
  # the user list and the website; regenerating them would invalidate every
  # client that is already configured.
  #
  # The containers of the old compose project are removed first: their names are
  # derived from the project name (reality-ezpz-engine-1, ...), so the new
  # project would otherwise fail to publish 8443/8080 while the old ones keep
  # holding those ports.
  # The legacy path is a parameter only so the regression suite can point it at a
  # scratch directory instead of the real /opt; the single caller omits it.
  local legacy_config_path="${1:-/opt/reality-ezpz}"
  if [[ ! -e ${legacy_config_path}/config ]]; then
    return 0
  fi
  if [[ -e ${config_path} ]]; then
    echo "Warning: both ${legacy_config_path} and ${config_path} exist. Keeping ${config_path}; remove the old directory manually to silence this warning." >&2
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    if docker compose >/dev/null 2>&1; then
      docker compose --project-directory "${legacy_config_path}" -p 'reality-ezpz' down --remove-orphans --timeout 2 >/dev/null 2>&1 || true
    elif command -v docker-compose >/dev/null 2>&1; then
      docker-compose --project-directory "${legacy_config_path}" -p 'reality-ezpz' down --remove-orphans --timeout 2 >/dev/null 2>&1 || true
    fi
  fi
  if ! mv "${legacy_config_path}" "${config_path}"; then
    echo "Could not move ${legacy_config_path} to ${config_path}. Move it by hand (mv ${legacy_config_path} ${config_path}) and run this script again." >&2
    exit 1
  fi
  # The kernel tuning drop-in was renamed as well. Leaving the old one behind
  # would keep applying its BBR settings even after BBR has been switched off.
  rm -f '/etc/sysctl.d/99-reality-ezpz.conf'
  echo "An installation from an older release was found in ${legacy_config_path}: it has been moved to ${config_path}, and its containers are recreated under the new project name."
  return 0
}

function upgrade {
  local uuid
  local warp_token
  local warp_id
  if [[ -e "${HOME}/reality/config" ]]; then
    ${docker_cmd} --project-directory "${HOME}/reality" down --remove-orphans --timeout 2
    mv -f "${HOME}/reality" ${config_path}
  fi
  uuid=$(grep '^uuid=' "${path[config]}" 2>/dev/null | cut -d= -f2 || true)
  if [[ -n $uuid ]]; then
    sed -i '/^uuid=/d' "${path[users]}"
    echo "Reality=${uuid}" >> "${path[users]}"
  fi
  rm -f "${config_path}/xray.conf"
  rm -f "${config_path}/singbox.conf"
  if ! ${docker_cmd} ls | grep ${compose_project} >/dev/null && [[ -r ${path[compose]} ]]; then
    ${docker_cmd} --project-directory ${config_path} down --remove-orphans --timeout 2
  fi
  if [[ -r ${path[config]} ]]; then
    sed -i 's|transport=h2|transport=http|g' "${path[config]}"
    sed -i 's|core=singbox|core=sing-box|g' "${path[config]}"
    sed -i 's|security=tls-invalid|security=selfsigned|g' "${path[config]}"
    sed -i 's|security=tls-valid|security=letsencrypt|g' "${path[config]}"
    # Boolean settings used to be persisted as true/false in the config file.
    # Normalise them to ON/OFF, otherwise every `== 'ON'` comparison silently
    # evaluates to false after an upgrade.
    sed -i 's|=true$|=ON|; s|=false$|=OFF|' "${path[config]}"
  fi
  for key in "${!path[@]}"; do
    if [[ -d "${path[$key]}" ]]; then
      rm -rf "${path[$key]}"
    fi
  done
  if [[ -d "${config_path}/warp" ]]; then
    ${docker_cmd} --project-directory ${config_path} -p ${compose_project} down --remove-orphans --timeout 2 || true
    warp_token=$(cat ${config_path}/warp/reg.json | jq -r '.api_token')
    warp_id=$(cat ${config_path}/warp/reg.json | jq -r '.registration_id')
    warp_api "DELETE" "/reg/${warp_id}" "" "${warp_token}" >/dev/null 2>&1 || true
    rm -rf "${config_path}/warp"
  fi
}

function main_menu {
  local selection
  while true; do
    selection=$(whiptail --clear --backtitle "$BACKTITLE" --title "Server Management" \
      --menu "$MENU" $HEIGHT $WIDTH $CHOICE_HEIGHT \
      --ok-button "Select" \
      --cancel-button "Exit" \
      "1" "Add New User" \
      "2" "Delete User" \
      "3" "View User" \
      "4" "View Server Config" \
      "5" "Configuration" \
      3>&1 1>&2 2>&3)
    if [[ $? -ne 0 ]]; then
      break
    fi
    case $selection in
      1 )
        add_user_menu
        ;;
      2 )
        delete_user_menu
        ;;
      3 )
        view_user_menu
        ;;
      4 )
        view_config_menu
        ;;
      5 )
        configuration_menu
        ;;
    esac
  done
}

function add_user_menu {
  local username
  local message
  while true; do
    username=$(whiptail \
      --clear \
      --backtitle "$BACKTITLE" \
      --title "Add New User" \
      --inputbox "Enter username:" \
      $HEIGHT $WIDTH \
      3>&1 1>&2 2>&3)
    if [[ $? -ne 0 ]]; then
      break
    fi
    if [[ ! $username =~ ${regex[username]} ]]; then
      message_box "Invalid Username" "Username can only contains A-Z, a-z and 0-9"
      continue
    fi
    if [[ -n ${users[$username]} ]]; then
      message_box "Invalid Username" '"'"${username}"'" already exists.'
      continue
    fi
    users[$username]=$(cat /proc/sys/kernel/random/uuid)
    update_users_file
    whiptail \
      --clear \
      --backtitle "$BACKTITLE" \
      --title "Add New User" \
      --yes-button "View User" \
      --no-button "Return" \
      --yesno 'User "'"${username}"'" has been created.' \
      $HEIGHT $WIDTH \
      3>&1 1>&2 2>&3
    if [[ $? -ne 0 ]]; then
      break
    fi
    view_user_menu "${username}"
  done
}

function delete_user_menu {
  local username
  while true; do
    username=$(list_users_menu "Delete User")
    if [[ $? -ne 0 ]]; then
      return 0
    fi
    if [[ ${#users[@]} -eq 1 ]]; then
      message_box "Delete User" "You cannot delete the only user.\nAt least one user is needed.\nCreate a new user, then delete this one."
      continue
    fi
    whiptail \
      --clear \
      --backtitle "$BACKTITLE" \
      --title "Delete User" \
      --yesno "Are you sure you want to delete $username?" \
      $HEIGHT $WIDTH \
      3>&1 1>&2 2>&3
    if [[ $? -ne 0 ]]; then
      continue
    fi
    unset users["${username}"]
    update_users_file
    message_box "Delete User" 'User "'"${username}"'" has been deleted.'
  done
}

function view_user_menu {
  local username
  local user_config
  while true; do
    if [[ $# -gt 0 ]]; then
      username=$1
    else
      username=$(list_users_menu "View User")
      if [[ $? -ne 0 ]]; then
        return 0
      fi
    fi
    if [[ ${config[transport]} == 'tuic' ]]; then
      user_config=$(echo "
Protocol: tuic
Remarks: ${username}
Address: ${config[server]}
Port: ${config[port]}
UUID: ${users[$username]}
Password: $(echo -n "${username}${users[${username}]}" | sha256sum | cut -d ' ' -f 1 | head -c 16)
UDP Relay Mode: quic
Congestion Control: bbr
      " | tr -s '\n')
    elif [[ ${config[transport]} == 'hysteria2' ]]; then
      user_config=$(echo "
Protocol: hysteria2
Remarks: ${username}
Address: ${config[server]}
Port: ${config[port]}
Password: $(echo -n "${username}${users[${username}]}" | sha256sum | cut -d ' ' -f 1 | head -c 16)
OBFS Type: salamander
OBFS Password: ${config[service_path]}
      " | tr -s '\n')
    elif [[ ${config[transport]} == 'shadowtls' ]]; then
      user_config=$(echo "
=== First item of the chain proxy ===
Protocol: shadowtls
Remarks: ${username}-shadowtls
Address: ${config[server]}
Port: ${config[port]}
Password: ${users[$username]}
Protocol Version: 3
SNI: ${config[domain]%%:*}
Fingerprint: chrome
=== Second item of the chain proxy ===
Protocol: shadowsocks
Remarks: ${username}-shadowsocks
Address: 127.0.0.1
Port: 1080
Password: ${users[$username]}
Encryption Method: chacha20-ietf-poly1305
UDP over TCP: true

      " | tr -s '\n')
    else
      user_config=$(echo "
Protocol: vless
Remarks: ${username}
Address: ${config[server]}
Port: ${config[port]}
ID: ${users[$username]}
Flow: $([[ ${config[transport]} == 'tcp' ]] && echo 'xtls-rprx-vision' || true)
Network: ${config[transport]}
$([[ ${config[transport]} == 'ws' || ${config[transport]} == 'http' ]] && echo "Host Header: ${config[server]}" || true)
$([[ ${config[transport]} == 'ws' || ${config[transport]} == 'http' ]] && echo "Path: /${config[service_path]}" || true)
$([[ ${config[transport]} == 'grpc' ]] && echo 'gRPC mode: gun' || true)
$([[ ${config[transport]} == 'grpc' ]] && echo 'gRPC serviceName: '"${config[service_path]}" || true)
TLS: $([[ ${config[security]} == 'reality' ]] && echo 'reality' || echo 'tls')
SNI: ${config[domain]%%:*}
ALPN: $([[ ${config[transport]} == 'ws' ]] && echo 'http/1.1' || echo 'h2,http/1.1')
Fingerprint: chrome
$([[ ${config[security]} == 'reality' ]] && echo "PublicKey: ${config[public_key]}" || true)
$([[ ${config[security]} == 'reality' ]] && echo "ShortId: ${config[short_id]}" || true)
      " | tr -s '\n')
    fi
    whiptail \
      --clear \
      --backtitle "$BACKTITLE" \
      --title "${username} details" \
      --yes-button "View QR" \
      --no-button "Return" \
      --yesno "${user_config}" \
      $HEIGHT $WIDTH \
      3>&1 1>&2 2>&3
    if [[ $? -eq 0 ]]; then
      clear
      print_client_configuration "${username}"
      echo
      echo "Press Enter to return ..."
      read
      clear
    fi
    if [[ $# -gt 0 ]]; then
      return 0
    fi
  done
}

function list_users_menu {
  local title=$1
  local options
  local selection
  options=$(dict_expander users)
  selection=$(whiptail --clear --noitem --backtitle "$BACKTITLE" --title "$title" \
    --menu "Select the user" $HEIGHT $WIDTH $CHOICE_HEIGHT $options \
    3>&1 1>&2 2>&3)
  if [[ $? -ne 0 ]]; then
    return 1
  fi
  echo "${selection}"
}

function show_server_config {
  local server_config
  server_config="Core: ${config[core]}"
  server_config=$server_config$'\n'"Server Address: ${config[server]}"
  server_config=$server_config$'\n'"Domain SNI: ${config[domain]}"
  server_config=$server_config$'\n'"Camouflage Site: ${config[camouflage]}"
  server_config=$server_config$'\n'"Port: ${config[port]}"
  server_config=$server_config$'\n'"HTTP Port (website): ${config[http_port]}"
  server_config=$server_config$'\n'"Transport: ${config[transport]}"
  server_config=$server_config$'\n'"Security: ${config[security]}"
  server_config=$server_config$'\n'"Safenet: ${config[safenet]}"
  server_config=$server_config$'\n'"BBR: $(bbr_summary)"
  server_config=$server_config$'\n'"WARP: ${config[warp]}"
  server_config=$server_config$'\n'"WARP License: ${config[warp_license]}"
  server_config=$server_config$'\n'"Telegram Bot: ${config[tgbot]}"
  server_config=$server_config$'\n'"Telegram Bot Token: ${config[tgbot_token]}"
  server_config=$server_config$'\n'"Telegram Bot Admins: ${config[tgbot_admins]}"
  echo "${server_config}"
}

function view_config_menu {
  local server_config
  server_config=$(show_server_config)
  message_box "Server Configuration" "${server_config}"
}

function restart_menu {
  whiptail \
    --clear \
    --backtitle "$BACKTITLE" \
    --title "Restart Services" \
    --yesno "Are you sure to restart services?" \
    $HEIGHT $WIDTH \
    3>&1 1>&2 2>&3
  if [[ $? -ne 0 ]]; then
    return
  fi
  restart_docker_compose
  if [[ ${config[tgbot]} == 'ON' ]]; then
    restart_tgbot_compose
  fi
}

function regenerate_menu {
  whiptail \
    --clear \
    --backtitle "$BACKTITLE" \
    --title "Regenrate keys" \
    --yesno "Are you sure to regenerate keys?" \
    $HEIGHT $WIDTH \
    3>&1 1>&2 2>&3
  if [[ $? -ne 0 ]]; then
    return
  fi
  generate_keys
  config[public_key]=${config_file[public_key]}
  config[private_key]=${config_file[private_key]}
  config[short_id]=${config_file[short_id]}
  update_config_file
  message_box "Regenerate keys" "All keys has been regenerated."
}

function restore_defaults_menu {
  whiptail \
    --clear \
    --backtitle "$BACKTITLE" \
    --title "Restore Default Config" \
    --yesno "Are you sure to restore default configuration?" \
    $HEIGHT $WIDTH \
    3>&1 1>&2 2>&3
  if [[ $? -ne 0 ]]; then
    return
  fi
  restore_defaults
  update_config_file
  message_box "Restore Default Config" "All configurations has been restored to their defaults."
}

function configuration_menu {
  local selection
  while true; do
    selection=$(whiptail --clear --backtitle "$BACKTITLE" --title "Configuration" \
      --menu "Select an option:" $HEIGHT $WIDTH $CHOICE_HEIGHT \
      "1" "Core" \
      "2" "Server Address" \
      "3" "Transport" \
      "4" "SNI Domain" \
      "5" "Security" \
      "6" "Port" \
      "7" "HTTP Port (website / ACME)" \
      "8" "Camouflage Site" \
      "9" "Safe Internet" \
      "10" "BBR" \
      "11" "WARP" \
      "12" "Telegram Bot" \
      "13" "Restart Services" \
      "14" "Regenerate Keys" \
      "15" "Restore Defaults" \
      "16" "Create Backup" \
      "17" "Restore Backup" \
      3>&1 1>&2 2>&3)
    if [[ $? -ne 0 ]]; then
      break
    fi
    case $selection in
      1 )
        config_core_menu
        ;;
      2 )
        config_server_menu
        ;;
      3 )
        config_transport_menu
        ;;
      4 )
        config_sni_domain_menu
        ;;
      5 )
        config_security_menu
        ;;
      6 )
        config_port_menu
        ;;
      7 )
        config_http_port_menu
        ;;
      8 )
        config_camouflage_menu
        ;;
      9 )
        config_safenet_menu
        ;;
      10 )
        config_bbr_menu
        ;;
      11 )
        config_warp_menu
        ;;
      12 )
        config_tgbot_menu
        ;;
      13 )
        restart_menu
        ;;
      14 )
        regenerate_menu
        ;;
      15 )
        restore_defaults_menu
        ;;
      16 )
        backup_menu
        ;;
      17 )
        restore_backup_menu
        ;;
    esac
  done
}

function config_core_menu {
  local core
  while true; do
    core=$(whiptail --clear --backtitle "$BACKTITLE" --title "Core" \
      --radiolist --noitem "Select a core engine:" $HEIGHT $WIDTH $CHOICE_HEIGHT \
      "xray" "$([[ "${config[core]}" == 'xray' ]] && echo 'on' || echo 'off')" \
      "sing-box" "$([[ "${config[core]}" == 'sing-box' ]] && echo 'on' || echo 'off')" \
      3>&1 1>&2 2>&3)
    if [[ $? -ne 0 ]]; then
      break
    fi
    if [[ ${core} == 'xray' && ${config[transport]} == 'tuic' ]]; then
      message_box 'Invalid Configuration' 'You cannot use "xray" core with "tuic" transport. Change core to "sing-box" or use other transports'
      continue
    fi
    if [[ ${core} == 'xray' && ${config[transport]} == 'hysteria2' ]]; then
      message_box 'Invalid Configuration' 'You cannot use "xray" core with "hysteria2" transport. Change core to "sing-box" or use other transports'
      continue
    fi
    if [[ ${core} == 'xray' && ${config[transport]} == 'shadowtls' ]]; then
      message_box 'Invalid Configuration' 'You cannot use "xray" core with "shadowtls" transport. Change core to "sing-box" or use other transports'
      continue
    fi
    config[core]=$core
    update_config_file
    break
  done
}

function config_server_menu {
  local server
  while true; do
    server=$(whiptail --clear --backtitle "$BACKTITLE" --title "Server Address" \
      --inputbox "Enter Server IP or Domain:" $HEIGHT $WIDTH "${config["server"]}" \
      3>&1 1>&2 2>&3)
    if [[ $? -ne 0 ]]; then
      break
    fi
    if [[ ! ${server} =~ ${regex[domain]} && ${config[security]} == 'letsencrypt' ]]; then
      message_box 'Invalid Configuration' 'You have to assign a valid domain to server if you want to use "letsencrypt" certificate.'
      continue
    fi
    if [[ -z ${server} ]]; then
      server="${defaults[server]}"
    fi
    config[server]="${server}"
    if [[ ${config[security]} != 'reality' && ${config[transport]} != 'shadowtls' ]]; then
      config[domain]="${server}"
    fi
    update_config_file
    break
  done
}

function config_transport_menu {
  local transport
  while true; do
    transport=$(whiptail --clear --backtitle "$BACKTITLE" --title "Transport" \
      --radiolist --noitem "Select a transport protocol:" $HEIGHT $WIDTH $CHOICE_HEIGHT \
      "tcp" "$([[ "${config[transport]}" == 'tcp' ]] && echo 'on' || echo 'off')" \
      "http" "$([[ "${config[transport]}" == 'http' ]] && echo 'on' || echo 'off')" \
      "grpc" "$([[ "${config[transport]}" == 'grpc' ]] && echo 'on' || echo 'off')" \
      "ws" "$([[ "${config[transport]}" == 'ws' ]] && echo 'on' || echo 'off')" \
      "tuic" "$([[ "${config[transport]}" == 'tuic' ]] && echo 'on' || echo 'off')" \
      "hysteria2" "$([[ "${config[transport]}" == 'hysteria2' ]] && echo 'on' || echo 'off')" \
      "shadowtls" "$([[ "${config[transport]}" == 'shadowtls' ]] && echo 'on' || echo 'off')" \
      3>&1 1>&2 2>&3)
    if [[ $? -ne 0 ]]; then
      break
    fi
    if [[ ${transport} == 'ws' && ${config[security]} == 'reality' ]]; then
      message_box 'Invalid Configuration' 'You cannot use "ws" transport with "reality" TLS certificate. Use other transports or change TLS certificate to "letsencrypt" or "selfsigned"'
      continue
    fi
    if [[ ${transport} == 'tuic' && ${config[security]} == 'reality' ]]; then
      message_box 'Invalid Configuration' 'You cannot use "tuic" transport with "reality" TLS certificate. Use other transports or change TLS certificate to "letsencrypt" or "selfsigned"'
      continue
    fi
    if [[ ${transport} == 'tuic' && ${config[core]} == 'xray' ]]; then
      message_box 'Invalid Configuration' 'You cannot use "tuic" transport with "xray" core. Use other transports or change core to "sing-box"'
      continue
    fi
    if [[ ${transport} == 'hysteria2' && ${config[security]} == 'reality' ]]; then
      message_box 'Invalid Configuration' 'You cannot use "hysteria2" transport with "reality" TLS certificate. Use other transports or change TLS certificate to "letsencrypt" or "selfsigned"'
      continue
    fi
    if [[ ${transport} == 'hysteria2' && ${config[core]} == 'xray' ]]; then
      message_box 'Invalid Configuration' 'You cannot use "hysteria2" transport with "xray" core. Use other transports or change core to "sing-box"'
      continue
    fi
    if [[ ${transport} == 'shadowtls' && ${config[core]} == 'xray' ]]; then
      message_box 'Invalid Configuration' 'You cannot use "shadowtls" transport with "xray" core. Use other transports or change core to "sing-box"'
      continue
    fi
    if [[ ${config[transport]} != 'shadowtls' && ${transport} == 'shadowtls' && ${config[security]} != 'reality' ]]; then
      config[domain]="${defaults[domain]}"
    fi
    config[transport]=$transport
    update_config_file
    break
  done
}

function config_camouflage_menu {
  local camouflage
  while true; do
    camouflage=$(whiptail --clear --backtitle "$BACKTITLE" --title "Camouflage Site" \
      --inputbox "Remote site that unauthenticated probes are relayed to (reality / shadowtls).\nIt must be a real site whose certificate matches the SNI, so the SNI follows it unless it is set separately.\nOptional \":port\" suffix, port 443 by default.\n\nDefault: ${defaults[camouflage]}" \
      $HEIGHT $WIDTH "${config[camouflage]}" \
      3>&1 1>&2 2>&3)
    if [[ $? -ne 0 ]]; then
      break
    fi
    if [[ ! $camouflage =~ ${regex[domain_port]} ]]; then
      message_box "Invalid Domain" '"'"${camouflage}"'" is not a valid domain.'
      continue
    fi
    if [[ $camouflage =~ : ]] && (( ${camouflage#*:} > 65535 )); then
      message_box "Invalid Port" 'The camouflage port must be between 1 and 65535.'
      continue
    fi
    config[camouflage]=$camouflage
    if [[ ${config[security]} == 'reality' || ${config[transport]} == 'shadowtls' ]]; then
      config[domain]="${camouflage%%:*}"
    fi
    update_config_file
    break
  done
}

function config_sni_domain_menu {
  local sni_domain
  while true; do
    sni_domain=$(whiptail --clear --backtitle "$BACKTITLE" --title "SNI Domain" \
      --inputbox "Enter SNI domain:" $HEIGHT $WIDTH "${config[domain]}" \
      3>&1 1>&2 2>&3)
    if [[ $? -ne 0 ]]; then
      break
    fi
    if [[ ! $sni_domain =~ ${regex[domain_port]} ]]; then
      message_box "Invalid Domain" '"'"${sni_domain}"'" in not a valid domain.'
      continue
    fi
    config[domain]=$sni_domain
    update_config_file
    break
  done
}

function config_security_menu {
  local security
  local free_80=true
  while true; do
    security=$(whiptail --clear --backtitle "$BACKTITLE" --title "Security Type" \
      --radiolist --noitem "Select a security type:" $HEIGHT $WIDTH $CHOICE_HEIGHT \
      "reality" "$([[ "${config[security]}" == 'reality' ]] && echo 'on' || echo 'off')" \
      "letsencrypt" "$([[ "${config[security]}" == 'letsencrypt' ]] && echo 'on' || echo 'off')" \
      "selfsigned" "$([[ "${config[security]}" == 'selfsigned' ]] && echo 'on' || echo 'off')" \
      3>&1 1>&2 2>&3)
    if [[ $? -ne 0 ]]; then
      break
    fi
    if [[ ! ${config[server]} =~ ${regex[domain]} && ${security} == 'letsencrypt' ]]; then
      message_box 'Invalid Configuration' 'You have to assign a valid domain to server if you want to use "letsencrypt" as security type'
      continue
    fi
    if [[ ${config[transport]} == 'ws' && ${security} == 'reality' ]]; then
      message_box 'Invalid Configuration' 'You cannot use "reality" TLS certificate with "ws" transport protocol. Change TLS certificate to "letsencrypt" or "selfsigned" or use other transport protocols'
      continue
    fi
    if [[ ${config[transport]} == 'tuic' && ${security} == 'reality' ]]; then
      message_box 'Invalid Configuration' 'You cannot use "reality" TLS certificate with "tuic" transport. Change TLS certificate to "letsencrypt" or "selfsigned" or use other transports'
      continue
    fi
    if [[ ${config[transport]} == 'hysteria2' && ${security} == 'reality' ]]; then
      message_box 'Invalid Configuration' 'You cannot use "reality" TLS certificate with "hysteria2" transport. Change TLS certificate to "letsencrypt" or "selfsigned" or use other transports'
      continue
    fi
    if [[ ${security} == 'letsencrypt' ]]; then
      if port_in_use 80; then
        free_80=false
        for container in $(${docker_cmd} -p ${compose_project} ps -q); do
          if docker port "${container}" | grep -q ':80$'; then
            free_80=true
            break
          fi
        done
      fi
      if [[ ${free_80} != 'true' ]]; then
        message_box 'Port 80 must be free if you want to use "letsencrypt" as the security option.'
        continue
      fi
    fi
    if [[ ${security} != 'reality' && ${config[transport]} != 'shadowtls' ]]; then
      config[domain]="${config[server]}"
    fi
    if [[ ${config[security]} != 'reality' && ${security} == 'reality' && ${config[transport]} != 'shadowtls' ]]; then
      config[domain]="${defaults[domain]}"
    fi
    config[security]="${security}"
    update_config_file
    break
  done
}

function config_port_menu {
  local port
  while true; do
    port=$(whiptail --clear --backtitle "$BACKTITLE" --title "Port" \
      --inputbox "Enter port number:" $HEIGHT $WIDTH "${config[port]}" \
      3>&1 1>&2 2>&3)
    if [[ $? -ne 0 ]]; then
      break
    fi
    if [[ ! $port =~ ${regex[port]} ]]; then
      message_box "Invalid Port" "Port must be an integer"
      continue
    fi
    if ((port < 1 || port > 65535)); then
      message_box "Invalid Port" "Port must be between 1 to 65535"
      continue
    fi
    if [[ ${port} -eq 80 ]]; then
      message_box "Invalid Port" "Port 80 is reserved for the letsencrypt ACME challenge. Use another port (default: ${defaults[port]})."
      continue
    fi
    if [[ ${port} -eq 443 ]]; then
      if ! whiptail --clear --backtitle "$BACKTITLE" --title "Well-known Port" \
        --yesno "Port 443 is a well-known port. The default (${defaults[port]}) is used so that the installation does not take 443 away from another service.\n\nUse 443 anyway?" 12 62; then
        continue
      fi
    fi
    config[port]=$port
    update_config_file
    break
  done
}

function config_http_port_menu {
  local http_port
  while true; do
    http_port=$(whiptail --clear --backtitle "$BACKTITLE" --title "HTTP Port" \
      --inputbox "Host port of the local website served by nginx out of ./website.\nIn the letsencrypt mode it also carries the ACME HTTP-01 challenge (always port 80).\n\nEnter \"off\" to leave it unpublished. Default: ${defaults[http_port]}" \
      $HEIGHT $WIDTH "${config[http_port]}" \
      3>&1 1>&2 2>&3)
    if [[ $? -ne 0 ]]; then
      break
    fi
    if [[ ${http_port,,} == 'off' ]]; then
      config[http_port]='OFF'
    elif [[ ! ${http_port} =~ ${regex[port]} ]] || ((http_port < 1 || http_port > 65535)); then
      message_box "Invalid Port" "Port must be an integer between 1 and 65535, or \"off\""
      continue
    elif [[ ${http_port} -eq 80 ]]; then
      message_box "Port 80" "Port 80 is only bound by the letsencrypt mode. Pick another port (default: ${defaults[http_port]}) or switch the security mode to letsencrypt."
      continue
    elif [[ ${http_port} -eq 443 ]]; then
      message_box "Port 443" "Port 443 is a well-known port and must not be claimed by an unencrypted HTTP listener."
      continue
    else
      config[http_port]=${http_port}
    fi
    update_config_file
    break
  done
}

function config_safenet_menu {
  local safenet
  safenet=$(whiptail --clear --backtitle "$BACKTITLE" --title "Safe Internet" \
    --radiolist --noitem "Enable blocking malware and adult content" $HEIGHT $WIDTH $CHOICE_HEIGHT \
    "Enable" "$([[ "${config[safenet]}" == 'ON' ]] && echo 'on' || echo 'off')" \
    "Disable" "$([[ "${config[safenet]}" == 'OFF' ]] && echo 'on' || echo 'off')" \
    3>&1 1>&2 2>&3)
  if [[ $? -ne 0 ]]; then
    return
  fi
  config[safenet]=$([[ $safenet == 'Enable' ]] && echo ON || echo OFF)
  update_config_file
}

function config_bbr_menu {
  local bbr
  bbr=$(whiptail --clear --backtitle "$BACKTITLE" --title "BBR" \
    --radiolist --noitem "Enable the BBR congestion control algorithm" $HEIGHT $WIDTH $CHOICE_HEIGHT \
    "Enable" "$([[ "${config[bbr]}" == 'ON' ]] && echo 'on' || echo 'off')" \
    "Disable" "$([[ "${config[bbr]}" == 'OFF' ]] && echo 'on' || echo 'off')" \
    3>&1 1>&2 2>&3)
  if [[ $? -ne 0 ]]; then
    return
  fi
  config[bbr]=$([[ $bbr == 'Enable' ]] && echo ON || echo OFF)
  update_config_file
  # Unlike the other toggles this one is not carried by a container config, so
  # the kernel is updated here instead of waiting for the next invocation.
  tune_kernel
  message_box "BBR" "BBR: $(bbr_summary)"
}

function config_warp_menu {
  local warp
  local warp_license
  local error
  local temp_file
  local exit_code
  local old_warp=${config[warp]}
  local old_warp_license=${config[warp_license]}
  while true; do
    warp=$(whiptail --clear --backtitle "$BACKTITLE" --title "WARP" \
      --radiolist --noitem "Enable WARP:" $HEIGHT $WIDTH $CHOICE_HEIGHT \
      "Enable" "$([[ "${config[warp]}" == 'ON' ]] && echo 'on' || echo 'off')" \
      "Disable" "$([[ "${config[warp]}" == 'OFF' ]] && echo 'on' || echo 'off')" \
      3>&1 1>&2 2>&3)
    if [[ $? -ne 0 ]]; then
      break
    fi
    if [[ $warp == 'Disable' ]]; then
      config[warp]=OFF
      if [[ -n ${config[warp_id]} && -n ${config[warp_token]} ]]; then
        warp_delete_account "${config[warp_id]}" "${config[warp_token]}"
      fi
      return
    fi
    if [[ -z ${config[warp_private_key]} || \
          -z ${config[warp_token]} || \
          -z ${config[warp_id]} || \
          -z ${config[warp_client_id]} || \
          -z ${config[warp_interface_ipv4]} || \
          -z ${config[warp_interface_ipv6]} ]]; then
      temp_file=$(mktemp)
      warp_create_account > "${temp_file}"
      exit_code=$?
      error=$(< "${temp_file}")
      rm -f "${temp_file}"
      if [[ ${exit_code} -ne 0 ]]; then
        message_box "WARP account creation error" "${error}"
        continue
      fi
    fi
    config[warp]=ON
    while true; do
      warp_license=$(whiptail --clear --backtitle "$BACKTITLE" --title "WARP+ License" \
        --inputbox "Enter WARP+ License:\nLeave blank if you only want to use free WARP account" $HEIGHT $WIDTH "${config[warp_license]}" \
        3>&1 1>&2 2>&3)
      if [[ $? -ne 0 ]]; then
        break
      fi
      if [[ -n "${warp_license}" && ! $warp_license =~ ${regex[warp_license]} ]]; then
        message_box "Invalid Input" "Invalid WARP+ License"
        continue
      fi
      if [[ -n "${warp_license}" ]]; then
        temp_file=$(mktemp)
        warp_add_license "${config[warp_id]}" "${config[warp_token]}" "${warp_license}" > "${temp_file}"
        exit_code=$?
        error=$(< "${temp_file}")
        rm -f "${temp_file}"
        if [[ ${exit_code} -ne 0 ]]; then
          message_box "WARP license error" "${error}"
          continue
        fi
      fi
      update_config_file
      return
    done
  done
  config[warp]=$old_warp
  config[warp_license]=$old_warp_license
}

function config_tgbot_menu {
  local tgbot
  local tgbot_token
  local tgbot_admins
  local old_tgbot=${config[tgbot]}
  local old_tgbot_token=${config[tgbot_token]}
  local old_tgbot_admins=${config[tgbot_admins]}
  while true; do
    tgbot=$(whiptail --clear --backtitle "$BACKTITLE" --title "Enable Telegram Bot" \
      --radiolist --noitem "Enable Telegram Bot:" $HEIGHT $WIDTH $CHOICE_HEIGHT \
      "Enable" "$([[ "${config[tgbot]}" == 'ON' ]] && echo 'on' || echo 'off')" \
      "Disable" "$([[ "${config[tgbot]}" == 'OFF' ]] && echo 'on' || echo 'off')" \
      3>&1 1>&2 2>&3)
    if [[ $? -ne 0 ]]; then
      break
    fi
    if [[ $tgbot == 'Disable' ]]; then
      config[tgbot]=OFF
      update_config_file
      return
    fi
    config[tgbot]=ON
    while true; do
      tgbot_token=$(whiptail --clear --backtitle "$BACKTITLE" --title "Telegram Bot Token" \
        --inputbox "Enter Telegram Bot Token:" $HEIGHT $WIDTH "${config[tgbot_token]}" \
        3>&1 1>&2 2>&3)
      if [[ $? -ne 0 ]]; then
        break
      fi
      if [[ ! $tgbot_token =~ ${regex[tgbot_token]} ]]; then
        message_box "Invalid Input" "Invalid Telegram Bot Token"
        continue
      fi 
      if ! curl -sSfL -m 3 "https://api.telegram.org/bot${tgbot_token}/getMe" >/dev/null 2>&1; then
        message_box "Invalid Input" "Telegram Bot Token is incorrect. Check it again."
        continue
      fi
      config[tgbot_token]=$tgbot_token
      while true; do
        tgbot_admins=$(whiptail --clear --backtitle "$BACKTITLE" --title "Telegram Bot Admins" \
          --inputbox "Enter Telegram Bot Admins (Seperate multiple admins by comma ',' without leading '@'):" $HEIGHT $WIDTH "${config[tgbot_admins]}" \
          3>&1 1>&2 2>&3)
        if [[ $? -ne 0 ]]; then
          break
        fi
        if [[ ! $tgbot_admins =~ ${regex[tgbot_admins]} || $tgbot_admins =~ .+_$ || $tgbot_admins =~ .+_,.+ ]]; then
          message_box "Invalid Input" "Invalid Username\nThe usernames must separated by ',' without leading '@' character or any extra space."
          continue
        fi
        config[tgbot_admins]=$tgbot_admins
        update_config_file
        return
      done
    done
  done
  config[tgbot]=$old_tgbot
  config[tgbot_token]=$old_tgbot_token
  config[tgbot_admins]=$old_tgbot_admins
}

function backup_menu {
  local backup_password
  local result
  backup_password=$(whiptail \
    --clear \
    --backtitle "$BACKTITLE" \
    --title "Backup" \
    --inputbox "Choose a password for the backup file.\nLeave blank if you do not wish to set a password for the backup file." \
    $HEIGHT $WIDTH \
    3>&1 1>&2 2>&3)
  if [[ $? -ne 0 ]]; then
    return
  fi
  if result=$(backup "${backup_password}" 2>&1); then
    clear
    echo "Backup has been create and uploaded successfully."
    echo "You can download the backup file from here:"
    echo ""
    echo "${result}"
    echo ""
    echo "The URL is valid for 3 days."
    echo
    echo "Press Enter to return ..."
    read
    clear
  else
    message_box "Backup Failed" "${result}"
  fi
}

function restore_backup_menu {
  local backup_file
  local backup_password
  local result
  while true; do
    backup_file=$(whiptail \
      --clear \
      --backtitle "$BACKTITLE" \
      --title "Restore Backup" \
      --inputbox "Enter backup file path or URL" \
      $HEIGHT $WIDTH \
      3>&1 1>&2 2>&3)
    if [[ $? -ne 0 ]]; then
      break
    fi
    if [[ ! $backup_file =~ ${regex[file_path]} ]] && [[ ! $backup_file =~ ${regex[url]} ]]; then
      message_box "Invalid Backup path of URL" "Backup file path or URL is not valid."
      continue
    fi
    backup_password=$(whiptail \
      --clear \
      --backtitle "$BACKTITLE" \
      --title "Restore Backup" \
      --inputbox "Enter backup file password.\nLeave blank if there is no password." \
      $HEIGHT $WIDTH \
      3>&1 1>&2 2>&3)
    if [[ $? -ne 0 ]]; then
      continue
    fi
    if result=$(restore "${backup_file}" "${backup_password}" 2>&1); then
      parse_config_file
      parse_users_file
      build_config
      update_config_file
      update_users_file
      message_box "Backup Restore Successful" "Backup has been restored successfully."
      args[restart]=true
      break
    else
      message_box "Backup Restore Failed" "${result}"
    fi
  done
}

function restart_docker_compose {
  ${docker_cmd} --project-directory "${config_path}" -p ${compose_project} down --remove-orphans --timeout 2 || true
  ${docker_cmd} --project-directory "${config_path}" -p ${compose_project} up --build -d --remove-orphans
}

function restart_tgbot_compose {
  ${docker_cmd} --project-directory "${config_path}/tgbot" -p ${tgbot_project} down --remove-orphans --timeout 2 || true
  ${docker_cmd} --project-directory "${config_path}/tgbot" -p ${tgbot_project} up --build -d --remove-orphans
}

function restart_container {
  if [[ -z "$(${docker_cmd} ls | grep "${path[compose]}" | grep running || true)" ]]; then
    restart_docker_compose
    return
  fi
  if ${docker_cmd} --project-directory ${config_path} -p ${compose_project} ps --services "$1" | grep "$1"; then
    ${docker_cmd} --project-directory ${config_path} -p ${compose_project} restart --timeout 2 "$1"
  fi
}

function warp_api {
  local verb=$1
  local resource=$2
  local data=$3
  local token=$4
  local team_token=$5
  local endpoint=https://api.cloudflareclient.com/v0a1922
  local temp_file
  local error
  local header
  local response_body
  local response_code
  local -a curl_args
  local -a headers=(
    "User-Agent: okhttp/3.12.1"
    "CF-Client-Version: a-6.3-1922"
    "Content-Type: application/json"
  )
  temp_file=$(mktemp)
  if [[ -n ${token} ]]; then
    headers+=("Authorization: Bearer ${token}")
  fi
  if [[ -n ${team_token} ]]; then
    headers+=("Cf-Access-Jwt-Assertion: ${team_token}")
  fi
  curl_args=(-sLX "${verb}" -m 15 -w '%{http_code}' -o "${temp_file}" "${endpoint}${resource}")
  for header in "${headers[@]}"; do
    curl_args+=(-H "${header}")
  done
  if [[ -n ${data} ]]; then
    curl_args+=(-d "${data}")
  fi
  response_code=$(curl "${curl_args[@]}" 2>/dev/null || true)
  response_body=$(cat "${temp_file}" 2>/dev/null || true)
  rm -f "${temp_file}"
  if [[ ! ${response_code} =~ ^[1-9][0-9]*$ ]]; then
    return 1
  fi
  if ((response_code > 399)); then
    error=$(echo "${response_body}" | jq -r '.errors[0].message' 2> /dev/null || true)
    if [[ ${error} != 'null' ]]; then
      echo "${error}"
    fi
    return 2
  fi
  echo "${response_body}"
}

# Generate a WireGuard (Curve25519) key pair with the system openssl and print
# "<private key> <public key>" as raw base64, which is the format both the
# Cloudflare registration API and the WireGuard/ sing-box configuration expect.
function warp_generate_keypair {
  local key_file
  local private_key
  local public_key
  key_file=$(mktemp)
  if ! openssl genpkey -algorithm X25519 -out "${key_file}" >/dev/null 2>&1; then
    rm -f "${key_file}"
    return 1
  fi
  # The DER encoding of an X25519 key ends with the raw 32 byte key.
  private_key=$(openssl pkey -in "${key_file}" -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n' || true)
  public_key=$(openssl pkey -in "${key_file}" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n' || true)
  rm -f "${key_file}"
  if [[ -z ${private_key} || -z ${public_key} ]]; then
    return 1
  fi
  echo "${private_key} ${public_key}"
}

# Register a free WARP device directly against the Cloudflare client API.
# This replaces the third-party wgcf image that was used before: the key pair is
# generated locally and the single registration call returns the device token,
# the client id and the interface addresses.
function warp_create_account {
  local response
  local key_pair
  local private_key
  local public_key
  local payload
  local tos
  if ! key_pair=$(warp_generate_keypair); then
    echo "WARP account creation has been failed! (cannot generate a WireGuard key pair with openssl)"
    return 1
  fi
  private_key=${key_pair%% *}
  public_key=${key_pair##* }
  tos=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  payload=$(printf '{"key":"%s","install_id":"","fcm_token":"","tos":"%s","model":"PC","serial_number":"","locale":"en_US"}' "${public_key}" "${tos}")
  # The assignment must be guarded: under `set -e` a failing command
  # substitution would abort the script before the error could be reported.
  if ! response=$(warp_api "POST" "/reg" "${payload}" ""); then
    if [[ -n ${response} ]]; then
      echo "${response}"
    fi
    echo "WARP account creation has been failed!"
    return 1
  fi
  config[warp_private_key]=${private_key}
  config[warp_token]=$(echo "${response}" | jq -r '.token // empty' 2>/dev/null || true)
  config[warp_id]=$(echo "${response}" | jq -r '.id // empty' 2>/dev/null || true)
  config[warp_client_id]=$(echo "${response}" | jq -r '.config.client_id // empty' 2>/dev/null || true)
  config[warp_interface_ipv4]=$(echo "${response}" | jq -r '.config.interface.addresses.v4 // empty' 2>/dev/null || true)
  config[warp_interface_ipv6]=$(echo "${response}" | jq -r '.config.interface.addresses.v6 // empty' 2>/dev/null || true)
  if [[ -z ${config[warp_token]} || -z ${config[warp_id]} || -z ${config[warp_client_id]} ]]; then
    echo "WARP account creation has been failed!"
    return 1
  fi
  if [[ -z ${config[warp_interface_ipv4]} || -z ${config[warp_interface_ipv6]} ]]; then
    echo "WARP account creation returned no interface address!"
    return 1
  fi
  update_config_file
}

function warp_add_license {
  local id=$1
  local token=$2
  local license=$3
  local data
  local response
  data='{"license": "'"${license}"'"}'
  if ! response=$(warp_api "PUT" "/reg/${id}/account" "${data}" "${token}"); then
    if [[ -n ${response} ]]; then
      echo "${response}"
    fi
    return 1
  fi
  config[warp_license]=${license}
  update_config_file
}

function warp_delete_account {
  local id=$1
  local token=$2
  warp_api "DELETE" "/reg/${id}" "" "${token}" >/dev/null 2>&1 || true
  config[warp_private_key]=""
  config[warp_token]=""
  config[warp_id]=""
  config[warp_client_id]=""
  config[warp_interface_ipv4]=""
  config[warp_interface_ipv6]=""
  update_config_file
}

# Decode the first three bytes of the WARP client id into a JSON array.
# Uses only base64/od, so it also works inside the minimal tgbot container where
# xxd is not installed (the previous xxd based version silently broke there).
function warp_decode_reserved {
  local client_id=$1
  local bytes
  local byte
  local reserved=""
  bytes=$(printf '%s' "${client_id}" | base64 -d 2>/dev/null | od -An -tu1 -N3 2>/dev/null || true)
  for byte in ${bytes}; do
    reserved="${reserved:+${reserved}, }${byte}"
  done
  echo "[${reserved}]"
}

# Check whether a TCP port is already in use. lsof is not installed by default on
# every supported distro, and without a fallback the letsencrypt port 80 check
# silently passed (and the certificate request then failed later on).
function port_in_use {
  local port=$1
  if command -v lsof >/dev/null 2>&1; then
    lsof -i :"${port}" >/dev/null 2>&1 && return 0
    return 1
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 0
    return 1
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 0
    return 1
  fi
  return 1
}

function check_reload {
  local -A restart
  RELOAD_PENDING=0
  generate_config
  for key in "${!path[@]}"; do
    if [[ "${md5["$key"]}" != $(get_md5 "${path[$key]}") ]]; then
      restart["${service["$key"]}"]='true'
      md5["$key"]=$(get_md5 "${path[$key]}")
    fi
  done
  if [[ "${restart[tgbot]}" == 'true' && "${config[tgbot]}" == 'ON' ]]; then
    restart_tgbot_compose
  fi
  if [[ "${config[tgbot]}" == 'OFF' ]]; then
    ${docker_cmd} --project-directory ${config_path}/tgbot -p ${tgbot_project} down --remove-orphans --timeout 2 >/dev/null 2>&1 || true
  fi
  if [[ "${restart[compose]}" == 'true' ]]; then
    restart_docker_compose
    return
  fi
  for key in "${!restart[@]}"; do
    if [[ $key != 'none' && $key != 'tgbot' ]]; then
      restart_container "${key}"
    fi
  done
}

function message_box {
  local title=$1
  local message=$2
  whiptail \
    --clear \
    --backtitle "$BACKTITLE" \
    --title "$title" \
    --msgbox "$message" \
    $HEIGHT $WIDTH \
    3>&1 1>&2 2>&3
}

function get_md5 {
  local file_path
  file_path=$1
  md5sum "${file_path}" 2>/dev/null | cut -f1 -d' ' || true
}

function generate_file_list {
  path[config]="${config_path}/config"
  path[users]="${config_path}/users"
  path[compose]="${config_path}/docker-compose.yml"
  path[engine]="${config_path}/engine.conf"
  path[haproxy]="${config_path}/haproxy.cfg"
  path[website]="${config_path}/website/index.html"
  path[certbot_deployhook]="${config_path}/certbot/deployhook.sh"
  path[certbot_dockerfile]="${config_path}/certbot/Dockerfile"
  path[certbot_startup]="${config_path}/certbot/startup.sh"
  path[server_pem]="${config_path}/certificate/server.pem"
  path[server_key]="${config_path}/certificate/server.key"
  path[server_crt]="${config_path}/certificate/server.crt"
  path[tgbot_script]="${config_path}/tgbot/tgbot.py"
  path[tgbot_dockerfile]="${config_path}/tgbot/Dockerfile"
  path[tgbot_compose]="${config_path}/tgbot/docker-compose.yml"

  service[config]='none'
  service[users]='none'
  service[compose]='compose'
  service[engine]='engine'
  service[haproxy]='haproxy'
  service[website]='nginx'
  service[certbot_deployhook]='certbot'
  service[certbot_dockerfile]='compose'
  service[certbot_startup]='certbot'
  service[server_pem]='haproxy'
  service[server_key]='engine'
  service[server_crt]='engine'
  service[tgbot_script]='tgbot'
  service[tgbot_dockerfile]='compose'
  service[tgbot_compose]='tgbot'

  for key in "${!path[@]}"; do
    md5["$key"]=$(get_md5 "${path[$key]}")
  done
}

# The current kernel state, read back from /proc instead of assumed. Both helpers
# are tolerant so they can also run where /proc/sys is not mounted.
function current_congestion_control {
  cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true
}

function current_qdisc {
  cat /proc/sys/net/core/default_qdisc 2>/dev/null || true
}

function bbr_supported {
  local available
  available=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)
  [[ ${available} == *bbr* ]]
}

# One place decides how the BBR state is described, so the installer output, the
# TUI and --show-server-config can never disagree.
function bbr_summary {
  local kernel_cc
  local kernel_qdisc
  if [[ ${config[bbr]} != 'ON' ]]; then
    echo "${config[bbr]}"
    return 0
  fi
  kernel_cc=$(current_congestion_control); kernel_cc="${kernel_cc:-unknown}"
  kernel_qdisc=$(current_qdisc); kernel_qdisc="${kernel_qdisc:-unknown}"
  echo "${config[bbr]} (kernel: ${kernel_cc}, qdisc: ${kernel_qdisc})"
}

function load_bbr_modules {
  # Writing net.ipv4.tcp_congestion_control only auto-loads the module on some
  # kernels and net.core.default_qdisc never does, so both are loaded explicitly.
  # Inside a container that cannot see its host's /lib/modules this fails, which
  # is why the outcome is not treated as an error here - bbr_supported decides.
  modprobe tcp_bbr >/dev/null 2>&1 || true
  modprobe sch_fq >/dev/null 2>&1 || true
}

function tune_kernel {
  # The path is a parameter only so the regression suite can write to a scratch
  # file instead of the real /etc; every caller in this script omits it.
  local sysctl_file="${1:-/etc/sysctl.d/99-reality.conf}"
  local bbr_block
  local line key value
  local failed=()
  if [[ ${config[bbr]} == 'OFF' ]]; then
    bbr_block='# BBR is turned off'
  else
    load_bbr_modules
    if bbr_supported; then
      bbr_block=$'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr'
    else
      bbr_block='# BBR was requested but this kernel does not offer it'
      echo 'Warning: this kernel does not offer the bbr congestion control algorithm (it ships with Linux 4.9 and newer, and a container cannot load modules from a host it cannot see). Continuing without BBR; every other tunable below is still applied.'
    fi
  fi
  # nf_conntrack_max below is meaningless until the module is there, and on a
  # minimal system that is what used to make one key fail silently.
  modprobe nf_conntrack >/dev/null 2>&1 || true
  cat >"${sysctl_file}" <<EOF
fs.file-max = 200000
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 600
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mem = 25600 51200 102400
net.ipv4.tcp_rmem = 4096 65536 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
${bbr_block}
net.netfilter.nf_conntrack_max=1000000
EOF
  # Every key is written on its own instead of relying on `sysctl -p`, whose
  # errors used to be thrown away: a kernel that rejected one line could leave
  # BBR unapplied while the installer reported success. Failures are collected
  # and reported rather than hidden.
  while IFS= read -r line; do
    [[ ${line} == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key// /}"
    value="${value#"${value%%[![:space:]]*}"}"
    if ! sysctl -qw "${key}=${value}" >/dev/null 2>&1; then
      failed+=("${key}")
    fi
  done <"${sysctl_file}"
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "Warning: these kernel settings are not available on this system and were skipped: ${failed[*]}"
  fi
  if [[ ${config[bbr]} == 'OFF' ]]; then
    # Revert only what this script would have set, so a congestion control the
    # user picked themselves is never overwritten.
    if [[ "$(current_congestion_control)" == 'bbr' ]]; then
      sysctl -qw net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    fi
    if [[ "$(current_qdisc)" == 'fq' ]]; then
      sysctl -qw net.core.default_qdisc=pfifo_fast >/dev/null 2>&1 || true
    fi
    echo "BBR is disabled (congestion control: $(current_congestion_control), qdisc: $(current_qdisc))."
    return 0
  fi
  if [[ "$(current_congestion_control)" == 'bbr' ]]; then
    echo "BBR is enabled (congestion control: $(current_congestion_control), qdisc: $(current_qdisc))."
  else
    echo "Warning: BBR was requested but is not active; the kernel reports \"$(current_congestion_control)\" as the congestion control."
  fi
}

function configure_docker {
  local docker_config="/etc/docker/daemon.json"
  local config_modified=false
  local temp_file
  temp_file=$(mktemp)
  if [[ ! -f "${docker_config}" ]] || [[ ! -s "${docker_config}" ]]; then
    echo '{"experimental": true, "ip6tables": true}' | jq . > "${docker_config}"
    config_modified=true
  else
    if ! jq . "${docker_config}" &> /dev/null; then
      echo '{"experimental": true, "ip6tables": true}' | jq . > "${docker_config}"
      config_modified=true
    else
      if jq 'if .experimental != true or .ip6tables != true then .experimental = true | .ip6tables = true else . end' "${docker_config}" | jq . > "${temp_file}"; then
        if ! cmp --silent "${docker_config}" "${temp_file}"; then
          mv "${temp_file}" "${docker_config}"
          config_modified=true
        fi
      fi
    fi
  fi
  rm -f "${temp_file}"
  if [[ "${config_modified}" = true ]] || ! systemctl is-active --quiet docker; then
    sudo systemctl restart docker || true
  fi
}

if ! parse_args "$@"; then
  show_help
  exit 1
fi
if [[ ${args[help]} == true ]]; then
  show_help
  exit 0
fi
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi
# Deliberately early: --backup and --restore read the configuration directory
# directly, so a server still using the old layout has to be migrated before any
# of them runs.
migrate_legacy_install
if [[ ${args[backup]} == true ]]; then
  if [[ -n ${args[backup_password]} ]]; then
    backup_url=$(backup "${args[backup_password]}")
  else
    backup_url=$(backup)
  fi
  if [[ $? -eq 0 ]]; then
    echo "Backup created successfully. You can download the backup file from this address:"
    echo "${backup_url}"
    echo "The URL is valid for 3 days."
    exit 0
  fi
fi
if [[ -n ${args[restore]} ]]; then
  if [[ -n ${args[backup_password]} ]]; then
    restore "${args[restore]}" "${args[backup_password]}"
  else
    restore "${args[restore]}"
  fi
  if [[ $? -eq 0 ]]; then
    args[restart]=true
    echo "Backup has been restored successfully."
  fi
  echo "Press Enter to continue ..."
  read
  clear
fi
generate_file_list
install_packages
install_docker
configure_docker
upgrade
# Config writes during bootstrap only mark the state dirty; the single
# flush_reload below replaces the repeated regeneration + container restarts
# that used to happen on every intermediate write.
RELOAD_DEFERRED=1
parse_config_file
parse_users_file
build_config
update_config_file
update_users_file
RELOAD_DEFERRED=0
tune_kernel
flush_reload

if [[ ${args[menu]} == 'true' ]]; then
  set +e
  main_menu
  set -e
fi
if [[ ${args[restart]} == 'true' ]]; then
  restart_docker_compose
  if [[ ${config[tgbot]} == 'ON' ]]; then
    restart_tgbot_compose
  fi
fi
if [[ -z "$(${docker_cmd} ls | grep "${path[compose]}" | grep running || true)" ]]; then
  restart_docker_compose
fi
if [[ -z "$(${docker_cmd} ls | grep "${path[tgbot_compose]}" | grep running || true)" && ${config[tgbot]} == 'ON' ]]; then
  restart_tgbot_compose
fi
if [[ ${args[server-config]} == true ]]; then
  show_server_config
  exit 0
fi
if [[ -n ${args[list_users]} ]]; then
  for user in "${!users[@]}"; do
    echo "${user}"
  done
  exit 0
fi
if [[ ${#users[@]} -eq 1 ]]; then
  username="${!users[@]}"
fi
if [[ -n ${args[show_config]} ]]; then
  username="${args[show_config]}"
  if [[ -z "${users["${username}"]}" ]]; then
    echo 'User "'"$username"'" does not exists.'
    exit 1
  fi
fi
if [[ -n ${args[add_user]} ]]; then
  username="${args[add_user]}"
fi
if [[ -n $username ]]; then
  print_client_configuration "${username}"
fi
echo "Command has been executed successfully!"
exit 0
