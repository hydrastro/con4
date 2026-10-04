#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="1.3"
PROTOCOL_VERSION="5"

: "${HOST:=127.0.0.1}"
: "${PORT:=9411}"
: "${CON4_TOKEN:=}"
: "${CON4_ROWS:=6}"
: "${CON4_COLS:=7}"
: "${CON4_CONNECT:=4}"
: "${CON4_HANDSHAKE_TIMEOUT:=0}"
: "${CON4_MOVE_TIMEOUT:=0}"
: "${CON4_REPLAY_TIMEOUT:=0}"
: "${CON4_NC_LISTEN_STYLE:=auto}"
: "${CON4_SAVE_DIR:=$(pwd)}"
: "${CON4_NO_COLOR:=0}"
: "${CON4_CELL_WIDTH:=3}"
: "${CON4_CELL_HEIGHT:=1}"
: "${CON4_BORDER_STYLE:=single}"
: "${CON4_PIECE_STYLE:=diamond}"
: "${CON4_ADVERTISE:=0}"
: "${CON4_LOBBY_PORT:=9410}"
: "${CON4_LOBBY_TIMEOUT:=5}"
: "${CON4_SCAN_PORTS:=9411}"
: "${CON4_PROBE_TIMEOUT:=2}"
: "${CON4_GAME_NAME:=Con4 game}"
: "${CON4_ADVERTISE_HOST:=}"
: "${CON4_REPLAY_VIEW_DELAY:=0.6}"

ROWS="$CON4_ROWS"
COLS="$CON4_COLS"
CONNECT="$CON4_CONNECT"

EMPTY="."
YELLOW="Y"
RED="R"

STATUS_IDLE="IDLE"
STATUS_WAITING="WAITING_OPPONENT"
STATUS_PLAYING="PLAYING"
STATUS="$STATUS_IDLE"

LOCAL_MODE=0
LOCAL_COLOR=""
HOST_OPTION_SET=0
LOBBY_SOURCE="lan"
LOBBY_SCAN_HOST=""
CURRENT_TURN="$YELLOW"
WINNER="$EMPTY"
YELLOW_SCORE=0
RED_SCORE=0
ROUND_NUMBER=1

TRANSPORT_KIND=""
NET_PID=""
LOBBY_PID=""
NET_IN_FD=""
NET_OUT_FD=""
NC_BIN=""
SOCAT_BIN=""
SEND_NONCE=0
RECV_NONCE_LAST=0

INPUT=""
MSG_TYPE=""
MSG_ARG=""
MSG_NONCE=""
MSG_MAC=""

RED_COLOR=""
YELLOW_COLOR=""
BLUE_COLOR=""
GREEN_COLOR=""
DIM_COLOR=""
NORMAL_COLOR=""
COLOR_BOARD=""
COLOR_YELLOW=""
COLOR_RED=""
COLOR_BAD=""
COLOR_WAIT=""
COLOR_GOOD=""
COLOR_DIM=""

CELL_WIDTH="$CON4_CELL_WIDTH"
CELL_HEIGHT="$CON4_CELL_HEIGHT"
BORDER_STYLE="$CON4_BORDER_STYLE"
PIECE_STYLE="$CON4_PIECE_STYLE"

B_TL=""
B_TM=""
B_TR=""
B_ML=""
B_MM=""
B_MR=""
B_BL=""
B_BM=""
B_BR=""
B_H=""
B_V=""

declare -a BOARD=()
declare -a STACK=()
declare -a HISTORY=()
declare -a LOBBY_NAME=()
declare -a LOBBY_HOST=()
declare -a LOBBY_PORT=()
declare -a LOBBY_RULES=()
declare -a LOBBY_TOKEN_REQUIRED=()
declare -a LOBBY_GAME_PORT=()
declare -a SCAN_PORT_LIST=()
declare -a REPLAY_MOVES=()
declare -a REPLAY_COLORS=()

con4_die() {
  printf '%s\n' "${1:-Error.}" >&2
  exit "${2:-1}"
}

con4_note() {
  printf '%s\n' "$*" >&2
}

con4_is_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

con4_validate_number_range() {
  local value="$1"
  local min="$2"
  local max="$3"
  con4_is_int "$value" || return 1
  ((value >= min && value <= max)) || return 1
}

con4_validate_decimal() {
  [[ "${1:-}" =~ ^([0-9]+)(\.[0-9]+)?$ ]]
}

con4_validate_game_name() {
  local value="$1"
  [[ -n "$value" ]] || return 1
  [[ "${#value}" -le 40 ]] || return 1
  [[ "$value" != *$'\n'* ]] || return 1
  [[ "$value" != *'|'* ]] || return 1
  [[ "$value" != *,* ]] || return 1
}

con4_validate_config() {
  con4_validate_number_range "$ROWS" 4 30 || con4_die "Error: rows must be an integer from 4 to 30."
  con4_validate_number_range "$COLS" 4 30 || con4_die "Error: columns must be an integer from 4 to 30."
  con4_validate_number_range "$CONNECT" 3 10 || con4_die "Error: connect length must be an integer from 3 to 10."
  con4_validate_number_range "$CELL_WIDTH" 1 15 || con4_die "Error: cell width must be an integer from 1 to 15."
  con4_validate_number_range "$CELL_HEIGHT" 1 7 || con4_die "Error: cell height must be an integer from 1 to 7."

  case "$BORDER_STYLE" in
    single|double|rounded|heavy|ascii|none) ;;
    *) con4_die "Error: border style must be single, double, rounded, heavy, ascii, or none." ;;
  esac

  case "$PIECE_STYLE" in
    diamond|circle|letter|ascii) ;;
    *) con4_die "Error: piece style must be diamond, circle, letter, or ascii." ;;
  esac

  if ((CONNECT > ROWS && CONNECT > COLS)); then
    con4_die "Error: connect length must fit in either rows or columns."
  fi
}

con4_validate_host() {
  local host="$1"
  [[ -n "$host" ]] || return 1
  [[ "$host" != -* ]] || return 1
  [[ "$host" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
}

con4_validate_port() {
  local port="$1"
  con4_validate_number_range "$port" 1 65535
}

con4_validate_token() {
  local token="$1"
  [[ "$token" != *$'\n'* ]] || return 1
  [[ "$token" != *'|'* ]] || return 1
}

con4_validate_protocol_arg() {
  local value="$1"
  [[ "$value" != *$'\n'* ]] || return 1
  [[ "$value" != *'|'* ]] || return 1
}

con4_validate_received_message() {
  case "$MSG_TYPE" in
    HELLO)
      [[ "$MSG_ARG" =~ ^[0-9]+$ ]] || return 1
      ;;
    INFO)
      [[ "$MSG_ARG" =~ ^[0-9]+$ ]] || return 1
      ;;
    INFO_REPLY)
      [[ "$MSG_ARG" =~ ^[0-9]+,(0|1),[^,]{1,40},[A-Za-z0-9._:-]+,[0-9]+,[0-9]+,[0-9]+,[0-9]+,(0|1)$ ]] || return 1
      ;;
    READY)
      [[ "$MSG_ARG" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ ]] || return 1
      ;;
    MOVE)
      con4_is_int "$MSG_ARG" || return 1
      ;;
    REMATCH_RESPONSE)
      [[ "$MSG_ARG" == "Y" || "$MSG_ARG" == "N" ]] || return 1
      ;;
    QUIT)
      [[ "$MSG_ARG" =~ ^[A-Za-z0-9_.-]{0,64}$ ]] || return 1
      ;;
    ERROR)
      [[ "$MSG_ARG" =~ ^[A-Za-z0-9_.-]{0,64}$ ]] || return 1
      ;;
    RESIGN)
      [[ -z "$MSG_ARG" ]] || return 1
      ;;
    *)
      return 1
      ;;
  esac
}

con4_opponent_color() {
  local color="$1"
  if [[ "$color" == "$YELLOW" ]]; then
    printf '%s\n' "$RED"
  else
    printf '%s\n' "$YELLOW"
  fi
}

con4_init_colors() {
  if [[ "$CON4_NO_COLOR" == "0" && -t 1 ]] && command -v tput >/dev/null 2>&1; then
    RED_COLOR="$(tput setaf 1 || true)"
    YELLOW_COLOR="$(tput setaf 3 || true)"
    BLUE_COLOR="$(tput setaf 4 || true)"
    GREEN_COLOR="$(tput setaf 2 || true)"
    DIM_COLOR="$(tput dim || true)"
    NORMAL_COLOR="$(tput sgr 0 || true)"
  fi

  COLOR_BOARD="$BLUE_COLOR"
  COLOR_YELLOW="$YELLOW_COLOR"
  COLOR_RED="$RED_COLOR"
  COLOR_BAD="$RED_COLOR"
  COLOR_WAIT="$YELLOW_COLOR"
  COLOR_GOOD="$GREEN_COLOR"
  COLOR_DIM="$DIM_COLOR"
}


con4_disable_colors() {
  RED_COLOR=""
  YELLOW_COLOR=""
  BLUE_COLOR=""
  GREEN_COLOR=""
  DIM_COLOR=""
  NORMAL_COLOR=""
  COLOR_BOARD=""
  COLOR_YELLOW=""
  COLOR_RED=""
  COLOR_BAD=""
  COLOR_WAIT=""
  COLOR_GOOD=""
  COLOR_DIM=""
}

con4_init_border_style() {
  case "$BORDER_STYLE" in
    single)
      B_TL='┌'; B_TM='┬'; B_TR='┐'; B_ML='├'; B_MM='┼'; B_MR='┤'; B_BL='└'; B_BM='┴'; B_BR='┘'; B_H='─'; B_V='│'
      ;;
    double)
      B_TL='╔'; B_TM='╦'; B_TR='╗'; B_ML='╠'; B_MM='╬'; B_MR='╣'; B_BL='╚'; B_BM='╩'; B_BR='╝'; B_H='═'; B_V='║'
      ;;
    rounded)
      B_TL='╭'; B_TM='┬'; B_TR='╮'; B_ML='├'; B_MM='┼'; B_MR='┤'; B_BL='╰'; B_BM='┴'; B_BR='╯'; B_H='─'; B_V='│'
      ;;
    heavy)
      B_TL='┏'; B_TM='┳'; B_TR='┓'; B_ML='┣'; B_MM='╋'; B_MR='┫'; B_BL='┗'; B_BM='┻'; B_BR='┛'; B_H='━'; B_V='┃'
      ;;
    ascii|none)
      B_TL='+'; B_TM='+'; B_TR='+'; B_ML='+'; B_MM='+'; B_MR='+'; B_BL='+'; B_BM='+'; B_BR='+'; B_H='-'; B_V='|'
      ;;
    *)
      con4_die "Error: unsupported border style: $BORDER_STYLE"
      ;;
  esac
}

con4_clear_screen() {
  if [[ -t 1 ]]; then
    printf '\033c'
  fi
}

con4_prompt() {
  local prompt="$1"
  INPUT=""
  IFS= read -r -p "$prompt" INPUT || return 1
}

con4_prompt_yes_no() {
  local prompt="$1"
  local default_answer="${2:-N}"
  local answer=""

  while true; do
    con4_prompt "$prompt" || return 1
    answer="${INPUT:-}"
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      "")
        if [[ "$default_answer" == "Y" ]]; then
          return 0
        fi
        return 1
        ;;
      *) printf 'Please answer y or n.\n' ;;
    esac
  done
}

con4_prompt_network_settings() {
  con4_prompt "Host [$HOST]: " || con4_die "Error: failed to read host."
  HOST="${INPUT:-$HOST}"
  con4_validate_host "$HOST" || con4_die "Error: invalid host. Use an address or hostname, for example 127.0.0.1, 0.0.0.0, or game.local."

  con4_prompt "Port [$PORT] (1-65535): " || con4_die "Error: failed to read port."
  PORT="${INPUT:-$PORT}"
  con4_validate_port "$PORT" || con4_die "Error: invalid port. Use a number from 1 to 65535."

  con4_prompt "Shared game code (optional) [$CON4_TOKEN]: " || con4_die "Error: failed to read game code."
  CON4_TOKEN="${INPUT:-$CON4_TOKEN}"
  con4_validate_token "$CON4_TOKEN" || con4_die "Error: game code cannot contain newlines or '|'."
}

con4_prompt_rules() {
  con4_prompt "Rows [$ROWS] (4-30): " || con4_die "Error: failed to read rows."
  ROWS="${INPUT:-$ROWS}"

  con4_prompt "Columns [$COLS] (4-30): " || con4_die "Error: failed to read columns."
  COLS="${INPUT:-$COLS}"

  con4_prompt "Connect length [$CONNECT] (3-10): " || con4_die "Error: failed to read connect length."
  CONNECT="${INPUT:-$CONNECT}"

  con4_validate_config
}

con4_prompt_display_settings() {
  con4_prompt "Cell width [$CELL_WIDTH] (1-15): " || con4_die "Error: failed to read cell width."
  CELL_WIDTH="${INPUT:-$CELL_WIDTH}"

  con4_prompt "Cell height [$CELL_HEIGHT] (1-7): " || con4_die "Error: failed to read cell height."
  CELL_HEIGHT="${INPUT:-$CELL_HEIGHT}"

  con4_prompt "Border style [$BORDER_STYLE] (single/double/rounded/heavy/ascii/none): " || con4_die "Error: failed to read border style."
  BORDER_STYLE="${INPUT:-$BORDER_STYLE}"

  con4_prompt "Piece style [$PIECE_STYLE] (diamond/circle/letter/ascii): " || con4_die "Error: failed to read piece style."
  PIECE_STYLE="${INPUT:-$PIECE_STYLE}"

  con4_validate_config
}

con4_prompt_advertise_settings() {
  if con4_prompt_yes_no "Advertise this game in the LAN lobby [y/N]? " "N"; then
    CON4_ADVERTISE=1
    con4_prompt "Lobby name [$CON4_GAME_NAME] (1-40 chars, no '|'): " || con4_die "Error: failed to read lobby name."
    CON4_GAME_NAME="${INPUT:-$CON4_GAME_NAME}"
    con4_validate_game_name "$CON4_GAME_NAME" || con4_die "Error: lobby name must be 1-40 characters and cannot contain newlines or '|'."

    con4_prompt "Lobby discovery port [$CON4_LOBBY_PORT] (1-65535): " || con4_die "Error: failed to read lobby port."
    CON4_LOBBY_PORT="${INPUT:-$CON4_LOBBY_PORT}"
    con4_validate_port "$CON4_LOBBY_PORT" || con4_die "Error: lobby port must be a number from 1 to 65535."

    printf 'Lobby discovery uses UDP broadcast and requires socat. It is not a central lobby server.\n'
  else
    CON4_ADVERTISE=0
  fi
}

con4_prompt_create_settings() {
  con4_prompt_network_settings
  con4_prompt_advertise_settings

  if con4_prompt_yes_no "Use standard rules and board style [Y/n]? " "Y"; then
    ROWS=6
    COLS=7
    CONNECT=4
    CELL_WIDTH=3
    CELL_HEIGHT=1
    BORDER_STYLE=single
    PIECE_STYLE=diamond
    con4_validate_config
    return 0
  fi

  printf 'Game rules are shared with the opponent. Board style is local to your terminal.\n'
  con4_prompt_rules
  con4_prompt_display_settings
}

con4_prompt_join_settings() {
  con4_prompt "Server host [$HOST]: " || con4_die "Error: failed to read host."
  HOST="${INPUT:-$HOST}"
  con4_validate_host "$HOST" || con4_die "Error: invalid host. Use an address or hostname, for example 127.0.0.1 or game.local."

  printf 'Rules come from the creator after connecting. Your board style is local only.\n'

  if con4_prompt_yes_no "Show available games on this host first [Y/n]? " "Y"; then
    con4_prompt "Ports to check [$CON4_SCAN_PORTS] (single, comma list, or range like 9411-9420): " || con4_die "Error: failed to read port list."
    CON4_SCAN_PORTS="${INPUT:-$CON4_SCAN_PORTS}"
    LOBBY_SOURCE="server"
    LOBBY_SCAN_HOST="$HOST"
    con4_server_lobby_scan "$HOST" "$CON4_SCAN_PORTS"
    if ((${#LOBBY_NAME[@]} > 0)); then
      if con4_prompt_yes_no "Customize your local board style before joining [y/N]? " "N"; then
        con4_prompt_display_settings
      else
        con4_validate_config
      fi
      con4_lobby_join_prompt
      return 1
    fi
    printf 'No waiting games found on that host/port selection. You can still join manually.\n'
  fi

  con4_prompt "Port [$PORT] (1-65535): " || con4_die "Error: failed to read port."
  PORT="${INPUT:-$PORT}"
  con4_validate_port "$PORT" || con4_die "Error: invalid port. Use a number from 1 to 65535."

  con4_prompt "Shared game code (optional) [$CON4_TOKEN]: " || con4_die "Error: failed to read game code."
  CON4_TOKEN="${INPUT:-$CON4_TOKEN}"
  con4_validate_token "$CON4_TOKEN" || con4_die "Error: game code cannot contain newlines or '|'."

  if con4_prompt_yes_no "Customize your local board style [y/N]? " "N"; then
    con4_prompt_display_settings
  else
    con4_validate_config
  fi
}

con4_prompt_local_settings() {
  if con4_prompt_yes_no "Use standard rules and board style [Y/n]? " "Y"; then
    ROWS=6
    COLS=7
    CONNECT=4
    CELL_WIDTH=3
    CELL_HEIGHT=1
    BORDER_STYLE=single
    PIECE_STYLE=diamond
    con4_validate_config
    return 0
  fi

  con4_prompt_rules
  con4_prompt_display_settings
}

con4_require_command() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || con4_die "Error: required command not found: $name"
}

con4_find_transport() {
  if command -v socat >/dev/null 2>&1; then
    TRANSPORT_KIND="socat"
    SOCAT_BIN="$(command -v socat)"
    return 0
  fi

  if command -v ncat >/dev/null 2>&1; then
    TRANSPORT_KIND="ncat"
    NC_BIN="$(command -v ncat)"
    return 0
  fi

  if command -v nc >/dev/null 2>&1; then
    TRANSPORT_KIND="nc"
    NC_BIN="$(command -v nc)"
    return 0
  fi

  if command -v netcat >/dev/null 2>&1; then
    TRANSPORT_KIND="nc"
    NC_BIN="$(command -v netcat)"
    return 0
  fi

  con4_die "Error: socat, ncat, nc, or netcat is required for network play."
}

con4_close_transport() {
  if [[ -n "${NET_IN_FD:-}" ]]; then
    eval "exec ${NET_IN_FD}>&-" 2>/dev/null || true
  fi
  if [[ -n "${NET_OUT_FD:-}" ]]; then
    eval "exec ${NET_OUT_FD}<&-" 2>/dev/null || true
  fi
  if [[ -n "${NET_PID:-}" ]]; then
    kill "$NET_PID" 2>/dev/null || true
    wait "$NET_PID" 2>/dev/null || true
  fi
  NET_IN_FD=""
  NET_OUT_FD=""
  NET_PID=""
  SEND_NONCE=0
  RECV_NONCE_LAST=0
}

con4_cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM

  con4_close_transport

  if [[ -n "${LOBBY_PID:-}" ]]; then
    kill "$LOBBY_PID" 2>/dev/null || true
    wait "$LOBBY_PID" 2>/dev/null || true
  fi

  exit "$exit_code"
}

con4_hmac() {
  local type="$1"
  local arg="$2"
  local nonce="$3"
  local payload="${PROTOCOL_VERSION}|${type}|${arg}|${nonce}"
  local digest=""

  if [[ -z "$CON4_TOKEN" || "$type" == "INFO" || "$type" == "INFO_REPLY" ]]; then
    printf -- '-\n'
    return 0
  fi

  con4_require_command openssl
  digest="$(printf '%s' "$payload" | openssl dgst -sha256 -hmac "$CON4_TOKEN")"
  digest="${digest##* }"
  [[ -n "$digest" ]] || con4_die "Error: failed to calculate message HMAC."
  printf '%s\n' "$digest"
}

con4_send_msg() {
  local type="$1"
  local arg="${2:-}"
  local nonce=""
  local mac=""

  [[ -n "${NET_IN_FD:-}" ]] || return 1
  con4_validate_protocol_arg "$type" || con4_die "Protocol error: invalid outgoing message type."
  con4_validate_protocol_arg "$arg" || con4_die "Protocol error: invalid outgoing message argument."

  ((SEND_NONCE += 1))
  nonce="$SEND_NONCE"
  mac="$(con4_hmac "$type" "$arg" "$nonce")"

  if ! { printf '%s|%s|%s|%s\n' "$type" "$arg" "$nonce" "$mac" >&"$NET_IN_FD"; } 2>/dev/null; then
    return 1
  fi
}

con4_send_or_die() {
  local type="$1"
  local arg="${2:-}"
  local context="${3:-message}"

  con4_send_msg "$type" "$arg" || con4_die "Connection lost while sending $context."
}

con4_recv_msg() {
  local timeout="${1:-0}"
  local context="${2:-message}"
  local line=""
  local extra=""
  local expected_mac=""

  if [[ -n "$timeout" && "$timeout" != "0" ]]; then
    if ! IFS= read -r -t "$timeout" -u "$NET_OUT_FD" line; then
      con4_die "Connection timed out while waiting for $context."
    fi
  else
    if ! IFS= read -r -u "$NET_OUT_FD" line; then
      con4_die "Connection closed while waiting for $context."
    fi
  fi

  IFS='|' read -r MSG_TYPE MSG_ARG MSG_NONCE MSG_MAC extra <<< "$line"

  [[ -z "${extra:-}" ]] || con4_die "Protocol error: too many fields."
  [[ -n "${MSG_TYPE:-}" ]] || con4_die "Protocol error: empty message type."
  [[ -n "${MSG_NONCE:-}" ]] || con4_die "Protocol error: missing nonce."
  [[ -n "${MSG_MAC:-}" ]] || con4_die "Protocol error: missing HMAC."
  con4_validate_protocol_arg "$MSG_TYPE" || con4_die "Protocol error: invalid message type."
  con4_validate_protocol_arg "$MSG_ARG" || con4_die "Protocol error: invalid message argument."
  con4_is_int "$MSG_NONCE" || con4_die "Protocol error: invalid nonce."
  ((MSG_NONCE > RECV_NONCE_LAST)) || con4_die "Protocol error: replayed or out-of-order message."

  case "$MSG_TYPE" in
    HELLO|INFO|INFO_REPLY|READY|MOVE|REMATCH_RESPONSE|QUIT|ERROR|RESIGN) ;;
    *) con4_die "Protocol error: unsupported message type." ;;
  esac
  con4_validate_received_message || con4_die "Protocol error: invalid message payload."

  expected_mac="$(con4_hmac "$MSG_TYPE" "$MSG_ARG" "$MSG_NONCE")"
  [[ "$MSG_MAC" == "$expected_mac" ]] || con4_die "Protocol error: message authentication failed."
  RECV_NONCE_LAST="$MSG_NONCE"
}

con4_on_interrupt() {
  con4_send_msg "QUIT" "interrupt" 2>/dev/null || true
  printf '\n'
  exit 130
}

con4_start_transport_server() {
  local -a nc_args=()
  local help_text=""

  con4_find_transport

  case "$TRANSPORT_KIND" in
    socat)
      coproc CON4_NET { "$SOCAT_BIN" - "TCP-LISTEN:${PORT},bind=${HOST},reuseaddr"; }
      ;;
    ncat)
      coproc CON4_NET { "$NC_BIN" -l "$HOST" "$PORT"; }
      ;;
    nc)
      case "$CON4_NC_LISTEN_STYLE" in
        auto)
          help_text="$($NC_BIN -h 2>&1 || true)"
          if [[ "$help_text" == *BusyBox* || "$help_text" == *v1.10* ]]; then
            nc_args=(-l -p "$PORT")
            if [[ "$HOST" != "0.0.0.0" && "$HOST" != "::" && "$HOST" != "*" ]]; then
              nc_args+=(-s "$HOST")
            fi
          else
            nc_args=(-l "$PORT")
          fi
          ;;
        port)
          nc_args=(-l "$PORT")
          ;;
        hostport)
          nc_args=(-l "$HOST" "$PORT")
          ;;
        traditional)
          nc_args=(-l -p "$PORT")
          if [[ "$HOST" != "0.0.0.0" && "$HOST" != "::" && "$HOST" != "*" ]]; then
            nc_args+=(-s "$HOST")
          fi
          ;;
        *)
          con4_die "Error: invalid CON4_NC_LISTEN_STYLE. Use auto, port, hostport, or traditional."
          ;;
      esac
      coproc CON4_NET { "$NC_BIN" "${nc_args[@]}"; }
      ;;
    *)
      con4_die "Error: unsupported transport."
      ;;
  esac

  NET_OUT_FD="${CON4_NET[0]}"
  NET_IN_FD="${CON4_NET[1]}"
  NET_PID="$CON4_NET_PID"
}

con4_start_transport_client() {
  con4_find_transport

  case "$TRANSPORT_KIND" in
    socat)
      coproc CON4_NET { "$SOCAT_BIN" - "TCP:${HOST}:${PORT}"; }
      ;;
    ncat|nc)
      coproc CON4_NET { "$NC_BIN" "$HOST" "$PORT"; }
      ;;
    *)
      con4_die "Error: unsupported transport."
      ;;
  esac

  NET_OUT_FD="${CON4_NET[0]}"
  NET_IN_FD="${CON4_NET[1]}"
  NET_PID="$CON4_NET_PID"
}

con4_start_transport_client_probe() {
  local timeout_seconds="${1:-$CON4_PROBE_TIMEOUT}"

  con4_find_transport
  con4_validate_number_range "$timeout_seconds" 1 60 || timeout_seconds=2

  case "$TRANSPORT_KIND" in
    socat)
      coproc CON4_NET { "$SOCAT_BIN" - "TCP:${HOST}:${PORT},connect-timeout=${timeout_seconds}"; }
      ;;
    ncat|nc)
      coproc CON4_NET { "$NC_BIN" -w "$timeout_seconds" "$HOST" "$PORT"; }
      ;;
    *)
      con4_die "Error: unsupported transport."
      ;;
  esac

  NET_OUT_FD="${CON4_NET[0]}"
  NET_IN_FD="${CON4_NET[1]}"
  NET_PID="$CON4_NET_PID"
}

con4_guess_advertise_host() {
  local guessed=""

  if [[ -n "$CON4_ADVERTISE_HOST" ]]; then
    printf '%s\n' "$CON4_ADVERTISE_HOST"
    return 0
  fi

  case "$HOST" in
    127.*|localhost)
      guessed="127.0.0.1"
      ;;
    0.0.0.0|::|\*)
      if command -v hostname >/dev/null 2>&1; then
        guessed="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
      fi
      ;;
    *)
      guessed="$HOST"
      ;;
  esac

  if [[ -z "$guessed" && "$HOST" != "0.0.0.0" && "$HOST" != "::" && "$HOST" != "*" ]]; then
    guessed="$HOST"
  fi

  printf '%s\n' "${guessed:-127.0.0.1}"
}

con4_lobby_message() {
  local advertise_host=""
  local token_required="0"

  advertise_host="$(con4_guess_advertise_host)"
  [[ -n "$CON4_TOKEN" ]] && token_required="1"

  printf 'CON4|1|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$CON4_GAME_NAME" "$advertise_host" "$PORT" "$ROWS" "$COLS" "$CONNECT" "$token_required" "$PROTOCOL_VERSION"
}

con4_start_lobby_beacon() {
  local message=""

  [[ "$CON4_ADVERTISE" == "1" ]] || return 0
  con4_validate_game_name "$CON4_GAME_NAME" || con4_die "Error: lobby game name must be 1-40 characters and cannot contain newlines or '|'."
  con4_validate_port "$CON4_LOBBY_PORT" || con4_die "Error: lobby port must be 1-65535."
  con4_require_command socat

  case "$HOST" in
    127.*|localhost)
      printf 'Warning: advertising a game bound to %s; only this machine can connect. Use --host 0.0.0.0 for LAN play.\n' "$HOST" >&2
      ;;
  esac

  message="$(con4_lobby_message)"
  (
    while true; do
      printf '%s\n' "$message" | socat -u - "UDP-DATAGRAM:255.255.255.255:${CON4_LOBBY_PORT},broadcast" >/dev/null 2>&1 || true
      printf '%s\n' "$message" | socat -u - "UDP-DATAGRAM:127.0.0.1:${CON4_LOBBY_PORT}" >/dev/null 2>&1 || true
      sleep 2
    done
  ) &
  LOBBY_PID="$!"
  printf 'Advertising lobby entry "%s" on UDP port %s.\n' "$CON4_GAME_NAME" "$CON4_LOBBY_PORT"
}

con4_lobby_add_or_update() {
  local name="$1"
  local host="$2"
  local port="$3"
  local rows="$4"
  local cols="$5"
  local connect="$6"
  local token_required="$7"
  local i=""

  con4_validate_game_name "$name" || return 1
  con4_validate_host "$host" || return 1
  con4_validate_port "$port" || return 1
  con4_validate_number_range "$rows" 4 30 || return 1
  con4_validate_number_range "$cols" 4 30 || return 1
  con4_validate_number_range "$connect" 3 10 || return 1
  [[ "$token_required" == "0" || "$token_required" == "1" ]] || return 1

  for ((i = 0; i < ${#LOBBY_HOST[@]}; i++)); do
    if [[ "${LOBBY_HOST[$i]}" == "$host" && "${LOBBY_PORT[$i]}" == "$port" ]]; then
      LOBBY_NAME[$i]="$name"
      LOBBY_RULES[$i]="${rows}x${cols}, connect ${connect}"
      LOBBY_TOKEN_REQUIRED[$i]="$token_required"
      return 0
    fi
  done

  LOBBY_NAME+=("$name")
  LOBBY_HOST+=("$host")
  LOBBY_PORT+=("$port")
  LOBBY_RULES+=("${rows}x${cols}, connect ${connect}")
  LOBBY_TOKEN_REQUIRED+=("$token_required")
}

con4_lobby_parse_line() {
  local line="$1"
  local prefix=""
  local lobby_version=""
  local name=""
  local host=""
  local port=""
  local rows=""
  local cols=""
  local connect=""
  local token_required=""
  local proto=""
  local extra=""

  IFS='|' read -r prefix lobby_version name host port rows cols connect token_required proto extra <<< "$line"
  [[ "$prefix" == "CON4" ]] || return 1
  [[ "$lobby_version" == "1" ]] || return 1
  [[ "$proto" == "$PROTOCOL_VERSION" ]] || return 1
  [[ -z "$extra" ]] || return 1

  con4_lobby_add_or_update "$name" "$host" "$port" "$rows" "$cols" "$connect" "$token_required"
}

con4_scan_ports_reset() {
  SCAN_PORT_LIST=()
}

con4_scan_ports_add() {
  local port="$1"
  local existing=""

  con4_validate_port "$port" || return 1
  for existing in "${SCAN_PORT_LIST[@]}"; do
    [[ "$existing" == "$port" ]] && return 0
  done
  SCAN_PORT_LIST+=("$port")
}

con4_parse_scan_ports() {
  local spec="${1:-$CON4_SCAN_PORTS}"
  local item=""
  local start=""
  local end=""
  local port=""

  con4_scan_ports_reset

  local -a port_parts=()

  IFS=',' read -r -a port_parts <<< "$spec"
  for item in "${port_parts[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n "$item" ]] || continue
    if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      con4_validate_port "$start" || return 1
      con4_validate_port "$end" || return 1
      ((start <= end)) || return 1
      ((end - start <= 200)) || return 1
      for ((port = start; port <= end; port++)); do
        con4_scan_ports_add "$port" || return 1
      done
    else
      con4_scan_ports_add "$item" || return 1
    fi
  done

  ((${#SCAN_PORT_LIST[@]} > 0)) || return 1
}

con4_lobby_parse_info_reply_arg() {
  local value="$1"
  local version=""
  local free=""
  local name=""
  local host=""
  local port=""
  local rows=""
  local cols=""
  local connect=""
  local token_required=""
  local extra=""

  IFS=',' read -r version free name host port rows cols connect token_required extra <<< "$value"
  [[ -z "$extra" ]] || return 1
  [[ "$version" == "$PROTOCOL_VERSION" ]] || return 1
  [[ "$free" == "1" ]] || return 1
  con4_lobby_add_or_update "$name" "$host" "$port" "$rows" "$cols" "$connect" "$token_required"
}

con4_probe_game_port() {
  local scan_host="$1"
  local scan_port="$2"
  local old_host="$HOST"
  local old_port="$PORT"
  local line=""
  local msg_type=""
  local msg_arg=""
  local msg_nonce=""
  local msg_mac=""
  local extra=""

  HOST="$scan_host"
  PORT="$scan_port"
  SEND_NONCE=0
  RECV_NONCE_LAST=0

  con4_start_transport_client_probe "$CON4_PROBE_TIMEOUT" >/dev/null 2>&1 || { HOST="$old_host"; PORT="$old_port"; return 1; }

  if ! { printf 'INFO|%s|1|-\n' "$PROTOCOL_VERSION" >&"$NET_IN_FD"; } 2>/dev/null; then
    con4_close_transport
    HOST="$old_host"
    PORT="$old_port"
    return 1
  fi

  if ! IFS= read -r -t "$CON4_PROBE_TIMEOUT" -u "$NET_OUT_FD" line 2>/dev/null; then
    con4_close_transport
    HOST="$old_host"
    PORT="$old_port"
    return 1
  fi

  con4_close_transport
  HOST="$old_host"
  PORT="$old_port"

  IFS='|' read -r msg_type msg_arg msg_nonce msg_mac extra <<< "$line"
  [[ "$msg_type" == "INFO_REPLY" ]] || return 1
  [[ -z "$extra" ]] || return 1
  [[ "$msg_nonce" =~ ^[0-9]+$ ]] || return 1
  [[ "$msg_mac" == "-" ]] || return 1
  con4_lobby_parse_info_reply_arg "$msg_arg"
}

con4_server_lobby_scan() {
  local scan_host="${1:-$HOST}"
  local scan_ports="${2:-$CON4_SCAN_PORTS}"
  local scan_port=""

  con4_validate_host "$scan_host" || con4_die "Error: invalid server host."
  con4_validate_number_range "$CON4_PROBE_TIMEOUT" 1 60 || con4_die "Error: probe timeout must be from 1 to 60 seconds."
  con4_parse_scan_ports "$scan_ports" || con4_die "Error: ports must be one port, a comma list, or a small range such as 9411-9420."

  LOBBY_NAME=()
  LOBBY_HOST=()
  LOBBY_PORT=()
  LOBBY_RULES=()
  LOBBY_TOKEN_REQUIRED=()

  printf 'Checking %s for Con4 games on port(s): %s\n' "$scan_host" "$scan_ports"
  for scan_port in "${SCAN_PORT_LIST[@]}"; do
    con4_probe_game_port "$scan_host" "$scan_port" || true
  done
}

con4_lobby_scan() {
  local scan_seconds="${1:-$CON4_LOBBY_TIMEOUT}"
  local end=""
  local remaining=""
  local line=""
  local recv_fd=""
  local recv_pid=""

  con4_validate_number_range "$CON4_LOBBY_PORT" 1 65535 || con4_die "Error: lobby port must be 1-65535."
  con4_validate_number_range "$scan_seconds" 1 60 || con4_die "Error: lobby scan timeout must be 1-60 seconds."
  con4_require_command socat

  LOBBY_NAME=()
  LOBBY_HOST=()
  LOBBY_PORT=()
  LOBBY_RULES=()
  LOBBY_TOKEN_REQUIRED=()

  printf 'Looking for advertised games for %s second(s) on UDP port %s...\n' "$scan_seconds" "$CON4_LOBBY_PORT"
  coproc CON4_LOBBY_RECV { socat -u "UDP-RECV:${CON4_LOBBY_PORT},reuseaddr" - 2>/dev/null; }
  recv_fd="${CON4_LOBBY_RECV[0]}"
  recv_pid="$CON4_LOBBY_RECV_PID"
  end=$((SECONDS + scan_seconds))

  while ((SECONDS < end)); do
    remaining=$((end - SECONDS))
    if IFS= read -r -t "$remaining" -u "$recv_fd" line; then
      con4_lobby_parse_line "$line" || true
    fi
  done

  eval "exec ${recv_fd}<&-" 2>/dev/null || true
  kill "$recv_pid" 2>/dev/null || true
  wait "$recv_pid" 2>/dev/null || true
}

con4_lobby_print() {
  local i=""
  local token_note=""

  if ((${#LOBBY_NAME[@]} == 0)); then
    if [[ "$LOBBY_SOURCE" == "server" ]]; then
      printf 'No waiting games found on %s for port(s): %s\n' "$LOBBY_SCAN_HOST" "$CON4_SCAN_PORTS"
      printf 'Tip: check the host, firewall, and port list. The creator does not need --advertise for host queries.\n'
    else
      printf 'No advertised games found.\n'
      printf 'Tip: the creator must start with --advertise, or enable advertising in the menu.\n'
    fi
    return 1
  fi

  printf '\nAvailable games:\n'
  for ((i = 0; i < ${#LOBBY_NAME[@]}; i++)); do
    token_note="open"
    [[ "${LOBBY_TOKEN_REQUIRED[$i]}" == "1" ]] && token_note="code required"
    printf '  %d) %s — %s — %s:%s — %s\n' \
      "$((i + 1))" "${LOBBY_NAME[$i]}" "${LOBBY_RULES[$i]}" "${LOBBY_HOST[$i]}" "${LOBBY_PORT[$i]}" "$token_note"
  done
}

con4_lobby_join_prompt() {
  local choice=""
  local index=""

  con4_lobby_print || return 1

  while true; do
    con4_prompt "Join which game [1-${#LOBBY_NAME[@]}, r=rescan, q=quit]? " || return 1
    choice="$INPUT"
    case "$choice" in
      q|Q|quit|QUIT)
        printf 'Goodbye.\n'
        return 1
        ;;
      r|R|rescan|RESCAN)
        con4_lobby_rescan
        con4_lobby_print || continue
        ;;
      *)
        if con4_validate_number_range "$choice" 1 "${#LOBBY_NAME[@]}"; then
          index=$((choice - 1))
          HOST="${LOBBY_HOST[$index]}"
          PORT="${LOBBY_PORT[$index]}"
          if [[ "${LOBBY_TOKEN_REQUIRED[$index]}" == "1" && -z "$CON4_TOKEN" ]]; then
            con4_prompt "Shared game code: " || con4_die "Error: failed to read game code."
            CON4_TOKEN="$INPUT"
            con4_validate_token "$CON4_TOKEN" || con4_die "Error: game code cannot contain newlines or '|'."
          fi
          printf 'Joining %s at %s:%s.\n' "${LOBBY_NAME[$index]}" "$HOST" "$PORT"
          con4_join_game
          return 0
        fi
        printf 'Please enter a number from 1 to %d, r, or q.\n' "${#LOBBY_NAME[@]}"
        ;;
    esac
  done
}

con4_lobby_rescan() {
  if [[ "$LOBBY_SOURCE" == "server" ]]; then
    con4_server_lobby_scan "$LOBBY_SCAN_HOST" "$CON4_SCAN_PORTS"
  else
    con4_lobby_scan "$CON4_LOBBY_TIMEOUT"
  fi
}

con4_lobby_browse() {
  if [[ "$HOST_OPTION_SET" == "1" ]]; then
    LOBBY_SOURCE="server"
    LOBBY_SCAN_HOST="$HOST"
    con4_server_lobby_scan "$HOST" "$CON4_SCAN_PORTS"
  else
    LOBBY_SOURCE="lan"
    LOBBY_SCAN_HOST=""
    con4_lobby_scan "$CON4_LOBBY_TIMEOUT"
  fi
  con4_lobby_join_prompt
}

con4_hello_arg() {
  printf '%s\n' "$PROTOCOL_VERSION"
}

con4_rules_arg() {
  printf '%s,%s,%s,%s\n' "$PROTOCOL_VERSION" "$ROWS" "$COLS" "$CONNECT"
}

con4_info_arg() {
  local free="1"
  local advertise_host=""
  local token_required="0"

  advertise_host="$(con4_guess_advertise_host)"
  [[ -n "$CON4_TOKEN" ]] && token_required="1"
  [[ "$STATUS" == "$STATUS_PLAYING" ]] && free="0"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$PROTOCOL_VERSION" "$free" "$CON4_GAME_NAME" "$advertise_host" "$PORT" "$ROWS" "$COLS" "$CONNECT" "$token_required"
}

con4_parse_hello_arg() {
  local value="$1"
  [[ "$value" == "$PROTOCOL_VERSION" ]]
}

con4_parse_info_arg() {
  local value="$1"
  [[ "$value" == "$PROTOCOL_VERSION" ]]
}

con4_apply_rules_arg() {
  local value="$1"
  local version=""
  local rows=""
  local cols=""
  local connect=""
  local extra=""

  IFS=',' read -r version rows cols connect extra <<< "$value"
  [[ -z "$extra" ]] || return 1
  [[ "$version" == "$PROTOCOL_VERSION" ]] || return 1
  con4_validate_number_range "$rows" 4 30 || return 1
  con4_validate_number_range "$cols" 4 30 || return 1
  con4_validate_number_range "$connect" 3 10 || return 1

  ROWS="$rows"
  COLS="$cols"
  CONNECT="$connect"
  con4_validate_config
}

con4_wait_for_handshake_as_server() {
  printf 'Waiting for an opponent on %s:%s.\n' "$HOST" "$PORT"
  if [[ -n "$CON4_TOKEN" ]]; then
    printf 'Shared game code is enabled. Traffic is authenticated, not encrypted.\n'
  fi

  while true; do
    con4_start_transport_server
    con4_recv_msg "$CON4_HANDSHAKE_TIMEOUT" "opponent handshake"

    case "$MSG_TYPE" in
      INFO)
        con4_parse_info_arg "$MSG_ARG" || { con4_send_msg "ERROR" "bad_info" || true; con4_close_transport; continue; }
        con4_send_msg "INFO_REPLY" "$(con4_info_arg)" || true
        con4_close_transport
        printf 'Answered one game-list query. Still waiting for an opponent on %s:%s.\n' "$HOST" "$PORT"
        ;;
      HELLO)
        con4_parse_hello_arg "$MSG_ARG" || con4_die "Opponent uses an incompatible protocol version."
        con4_send_or_die "READY" "$(con4_rules_arg)" "server handshake"
        return 0
        ;;
      *)
        con4_send_msg "ERROR" "bad_handshake" || true
        con4_close_transport
        printf 'Ignored one invalid connection. Still waiting for an opponent on %s:%s.\n' "$HOST" "$PORT"
        ;;
    esac
  done
}

con4_wait_for_handshake_as_client() {
  printf 'Connecting to %s:%s.\n' "$HOST" "$PORT"
  con4_send_or_die "HELLO" "$(con4_hello_arg)" "client handshake"
  con4_recv_msg "$CON4_HANDSHAKE_TIMEOUT" "server handshake"
  [[ "$MSG_TYPE" == "READY" ]] || con4_die "Protocol error: expected READY."
  con4_apply_rules_arg "$MSG_ARG" || con4_die "Server uses incompatible rules or protocol."
  printf 'Game found: %sx%s board, connect %s.\n' "$ROWS" "$COLS" "$CONNECT"
}

con4_board_index() {
  local row="$1"
  local col="$2"
  printf '%s\n' $((row * COLS + col))
}

con4_board_get() {
  local row="$1"
  local col="$2"
  local index=""
  index="$(con4_board_index "$row" "$col")"
  printf '%s\n' "${BOARD[$index]:-$EMPTY}"
}

con4_board_set() {
  local row="$1"
  local col="$2"
  local value="$3"
  local index=""
  index="$(con4_board_index "$row" "$col")"
  BOARD[$index]="$value"
}

con4_reset_game() {
  local row=""
  local col=""

  BOARD=()
  STACK=()
  HISTORY=()

  for ((row = 0; row < ROWS; row++)); do
    for ((col = 0; col < COLS; col++)); do
      con4_board_set "$row" "$col" "$EMPTY"
    done
  done

  for ((col = 0; col < COLS; col++)); do
    STACK[$col]=0
  done

  CURRENT_TURN="$YELLOW"
  WINNER="$EMPTY"
  STATUS="$STATUS_PLAYING"
}

con4_color_name() {
  case "$1" in
    "$YELLOW") printf 'yellow' ;;
    "$RED") printf 'red' ;;
    *) printf 'unknown' ;;
  esac
}

con4_repeat() {
  local char="$1"
  local count="$2"
  local i=""

  for ((i = 0; i < count; i++)); do
    printf '%s' "$char"
  done
}

con4_piece_char() {
  local value="$1"

  case "$value:$PIECE_STYLE" in
    "$YELLOW:letter") printf 'Y' ;;
    "$RED:letter") printf 'R' ;;
    "$YELLOW:ascii") printf 'O' ;;
    "$RED:ascii") printf 'X' ;;
    "$YELLOW:circle"|"$RED:circle")
      if [[ -n "$COLOR_YELLOW$COLOR_RED" ]]; then
        printf '●'
      elif [[ "$value" == "$YELLOW" ]]; then
        printf 'Y'
      else
        printf 'R'
      fi
      ;;
    "$YELLOW:diamond"|"$RED:diamond")
      if [[ -n "$COLOR_YELLOW$COLOR_RED" ]]; then
        printf '◆'
      elif [[ "$value" == "$YELLOW" ]]; then
        printf 'Y'
      else
        printf 'R'
      fi
      ;;
    *) printf '' ;;
  esac
}

con4_colorize_piece() {
  local value="$1"
  local piece="$2"

  case "$value" in
    "$YELLOW") printf '%s%s%s' "$COLOR_YELLOW" "$piece" "$NORMAL_COLOR" ;;
    "$RED") printf '%s%s%s' "$COLOR_RED" "$piece" "$NORMAL_COLOR" ;;
    *) printf '%s' "$piece" ;;
  esac
}

con4_print_centered_plain() {
  local text="$1"
  local width="$2"
  local visible_len="${#text}"
  local left=0
  local right=0

  if ((visible_len >= width)); then
    printf '%s' "${text:0:width}"
    return 0
  fi

  left=$(((width - visible_len) / 2))
  right=$((width - visible_len - left))
  con4_repeat ' ' "$left"
  printf '%s' "$text"
  con4_repeat ' ' "$right"
}

con4_render_cell_line() {
  local value="$1"
  local line_number="$2"
  local middle_line=$((CELL_HEIGHT / 2))
  local piece=""
  local left=0
  local right=0

  if [[ "$line_number" -ne "$middle_line" ]]; then
    con4_repeat ' ' "$CELL_WIDTH"
    return 0
  fi

  if [[ "$value" == "$EMPTY" ]]; then
    if [[ "$BORDER_STYLE" == "none" ]]; then
      con4_print_centered_plain '.' "$CELL_WIDTH"
    else
      con4_repeat ' ' "$CELL_WIDTH"
    fi
    return 0
  fi

  piece="$(con4_piece_char "$value")"
  left=$(((CELL_WIDTH - 1) / 2))
  right=$((CELL_WIDTH - 1 - left))

  con4_repeat ' ' "$left"
  con4_colorize_piece "$value" "$piece"
  con4_repeat ' ' "$right"
}

con4_print_grid_border() {
  local left="$1"
  local middle="$2"
  local right="$3"
  local col=""

  printf '%s%s' "$COLOR_BOARD" "$left"
  for ((col = 0; col < COLS; col++)); do
    con4_repeat "$B_H" "$CELL_WIDTH"
    if ((col == COLS - 1)); then
      printf '%s%s\n' "$right" "$NORMAL_COLOR"
    else
      printf '%s' "$middle"
    fi
  done
}

con4_display_column_labels() {
  local col=""

  if [[ "$BORDER_STYLE" == "none" ]]; then
    for ((col = 0; col < COLS; col++)); do
      con4_print_centered_plain "$col" "$CELL_WIDTH"
      if ((col < COLS - 1)); then
        printf ' '
      fi
    done
    printf '\n'
    return 0
  fi

  printf ' '
  for ((col = 0; col < COLS; col++)); do
    con4_print_centered_plain "$col" "$CELL_WIDTH"
    printf ' '
  done
  printf '\n'
}

con4_display_grid() {
  local row=""
  local col=""
  local line_number=""
  local value=""

  con4_init_border_style

  if [[ "$BORDER_STYLE" != "none" ]]; then
    con4_print_grid_border "$B_TL" "$B_TM" "$B_TR"
  fi

  for ((row = ROWS - 1; row >= 0; row--)); do
    for ((line_number = 0; line_number < CELL_HEIGHT; line_number++)); do
      if [[ "$BORDER_STYLE" != "none" ]]; then
        printf '%s%s' "$COLOR_BOARD" "$B_V"
      fi

      for ((col = 0; col < COLS; col++)); do
        value="$(con4_board_get "$row" "$col")"
        con4_render_cell_line "$value" "$line_number"
        if [[ "$BORDER_STYLE" == "none" ]]; then
          if ((col < COLS - 1)); then
            printf ' '
          fi
        else
          printf '%s%s' "$COLOR_BOARD" "$B_V"
        fi
      done
      printf '%s\n' "$NORMAL_COLOR"
    done

    if [[ "$BORDER_STYLE" != "none" && "$row" -gt 0 ]]; then
      con4_print_grid_border "$B_ML" "$B_MM" "$B_MR"
    fi
  done

  if [[ "$BORDER_STYLE" != "none" ]]; then
    con4_print_grid_border "$B_BL" "$B_BM" "$B_BR"
  fi

  con4_display_column_labels
}

con4_history_line() {
  local item=""
  local output=""
  local idx=""
  local color=""
  local move=""

  if ((${#HISTORY[@]} == 0)); then
    printf 'none\n'
    return 0
  fi

  for item in "${HISTORY[@]}"; do
    idx="${item%%:*}"
    color="${item#*:}"
    move="${color#*:}"
    color="${color%%:*}"
    output+="${idx}.$(con4_color_name "$color"):${move} "
  done

  printf '%s\n' "${output% }"
}

con4_display_status() {
  printf 'Status: '
  case "$STATUS" in
    "$STATUS_IDLE")
      printf '%sidle%s.\n' "$COLOR_BAD" "$NORMAL_COLOR"
      ;;
    "$STATUS_WAITING")
      printf '%swaiting opponent%s.\n' "$COLOR_WAIT" "$NORMAL_COLOR"
      ;;
    "$STATUS_PLAYING")
      printf '%splaying%s. Round %d.\n' "$COLOR_GOOD" "$NORMAL_COLOR" "$ROUND_NUMBER"
      printf 'Rules: %sx%s, connect %s.\n' "$ROWS" "$COLS" "$CONNECT"
      printf 'Board: %sx%s cells, %s border, %s pieces.\n' "$CELL_WIDTH" "$CELL_HEIGHT" "$BORDER_STYLE" "$PIECE_STYLE"
      printf 'Score: %sYellow %s%s - %sRed %s%s\n' \
        "$COLOR_YELLOW" "$YELLOW_SCORE" "$NORMAL_COLOR" \
        "$COLOR_RED" "$RED_SCORE" "$NORMAL_COLOR"
      if ((LOCAL_MODE)); then
        printf 'Mode: local hot-seat.\n'
      else
        printf 'You are: %s.\n' "$(con4_color_name "$LOCAL_COLOR")"
      fi
      printf 'Current turn: %s.\n' "$(con4_color_name "$CURRENT_TURN")"
      if ((${#HISTORY[@]} > 0)); then
        printf '%sMoves: %s%s\n' "$COLOR_DIM" "$(con4_history_line)" "$NORMAL_COLOR"
      fi
      ;;
    *)
      printf 'unknown.\n'
      ;;
  esac
}

con4_valid_move() {
  local move="$1"
  con4_is_int "$move" || return 1
  ((move >= 0 && move < COLS)) || return 1
  ((STACK[move] < ROWS)) || return 1
}

con4_record_move() {
  local color="$1"
  local move="$2"
  local number=$(( ${#HISTORY[@]} + 1 ))
  HISTORY+=("${number}:${color}:${move}")
}

con4_insert_move() {
  local move="$1"
  local color="$2"
  local row="${STACK[$move]}"

  con4_board_set "$row" "$move" "$color"
  STACK[$move]=$((STACK[move] + 1))
  con4_record_move "$color" "$move"
}

con4_swap_turn() {
  CURRENT_TURN="$(con4_opponent_color "$CURRENT_TURN")"
}

con4_check_winner_from() {
  local row="$1"
  local col="$2"
  local delta_row="$3"
  local delta_col="$4"
  local color="$5"
  local count=""
  local r=""
  local c=""

  for ((count = 0; count < CONNECT; count++)); do
    r=$((row + count * delta_row))
    c=$((col + count * delta_col))
    ((r >= 0 && r < ROWS && c >= 0 && c < COLS)) || return 1
    [[ "$(con4_board_get "$r" "$c")" == "$color" ]] || return 1
  done

  return 0
}

con4_check_winner() {
  local row=""
  local col=""
  local color=""

  WINNER="$EMPTY"
  for ((row = 0; row < ROWS; row++)); do
    for ((col = 0; col < COLS; col++)); do
      color="$(con4_board_get "$row" "$col")"
      [[ "$color" == "$EMPTY" ]] && continue
      if con4_check_winner_from "$row" "$col" 0 1 "$color" || \
         con4_check_winner_from "$row" "$col" 1 0 "$color" || \
         con4_check_winner_from "$row" "$col" 1 1 "$color" || \
         con4_check_winner_from "$row" "$col" 1 -1 "$color"; then
        WINNER="$color"
        return 0
      fi
    done
  done

  return 1
}

con4_board_full() {
  local col=""
  for ((col = 0; col < COLS; col++)); do
    ((STACK[col] < ROWS)) && return 1
  done
  return 0
}

con4_apply_finished_game_score() {
  if [[ "$WINNER" == "$YELLOW" ]]; then
    YELLOW_SCORE=$((YELLOW_SCORE + 1))
  elif [[ "$WINNER" == "$RED" ]]; then
    RED_SCORE=$((RED_SCORE + 1))
  fi
}

con4_count_direction_with_virtual() {
  local start_row="$1"
  local start_col="$2"
  local delta_row="$3"
  local delta_col="$4"
  local color="$5"
  local virtual_row="$6"
  local virtual_col="$7"
  local r="$start_row"
  local c="$start_col"
  local count=0
  local value=""

  while ((r >= 0 && r < ROWS && c >= 0 && c < COLS)); do
    if ((r == virtual_row && c == virtual_col)); then
      value="$color"
    else
      value="$(con4_board_get "$r" "$c")"
    fi

    [[ "$value" == "$color" ]] || break
    ((count += 1))
    r=$((r + delta_row))
    c=$((c + delta_col))
  done

  printf '%s\n' "$count"
}

con4_would_win() {
  local move="$1"
  local color="$2"
  local row=""
  local total=""

  con4_valid_move "$move" || return 1
  row="${STACK[$move]}"

  total=$(( $(con4_count_direction_with_virtual "$row" "$move" 0 1 "$color" "$row" "$move") + $(con4_count_direction_with_virtual "$row" "$move" 0 -1 "$color" "$row" "$move") - 1 ))
  ((total >= CONNECT)) && return 0

  total=$(( $(con4_count_direction_with_virtual "$row" "$move" 1 0 "$color" "$row" "$move") + $(con4_count_direction_with_virtual "$row" "$move" -1 0 "$color" "$row" "$move") - 1 ))
  ((total >= CONNECT)) && return 0

  total=$(( $(con4_count_direction_with_virtual "$row" "$move" 1 1 "$color" "$row" "$move") + $(con4_count_direction_with_virtual "$row" "$move" -1 -1 "$color" "$row" "$move") - 1 ))
  ((total >= CONNECT)) && return 0

  total=$(( $(con4_count_direction_with_virtual "$row" "$move" 1 -1 "$color" "$row" "$move") + $(con4_count_direction_with_virtual "$row" "$move" -1 1 "$color" "$row" "$move") - 1 ))
  ((total >= CONNECT)) && return 0

  return 1
}

con4_hint() {
  local col=""
  local opponent=""

  for ((col = 0; col < COLS; col++)); do
    if con4_would_win "$col" "$CURRENT_TURN"; then
      printf 'Hint: play column %d to win now.\n' "$col"
      return 0
    fi
  done

  opponent="$(con4_opponent_color "$CURRENT_TURN")"
  for ((col = 0; col < COLS; col++)); do
    if con4_would_win "$col" "$opponent"; then
      printf 'Hint: play column %d to block %s.\n' "$col" "$(con4_color_name "$opponent")"
      return 0
    fi
  done

  for ((col = COLS / 2; col < COLS; col++)); do
    if con4_valid_move "$col"; then
      printf 'Hint: no immediate tactic found; try central column %d.\n' "$col"
      return 0
    fi
  done

  for ((col = 0; col < COLS / 2; col++)); do
    if con4_valid_move "$col"; then
      printf 'Hint: no immediate tactic found; try column %d.\n' "$col"
      return 0
    fi
  done

  printf 'Hint: no legal moves remain.\n'
}

con4_history_text() {
  local item=""
  local idx=""
  local color=""
  local move=""

  printf 'Con4 transcript\n'
  printf 'Version: %s\n' "$SCRIPT_VERSION"
  printf 'Rules: %sx%s, connect %s\n' "$ROWS" "$COLS" "$CONNECT"
  printf 'Score: Yellow %s - Red %s\n' "$YELLOW_SCORE" "$RED_SCORE"
  printf 'Round: %s\n' "$ROUND_NUMBER"
  printf '\nMoves:\n'

  if ((${#HISTORY[@]} == 0)); then
    printf '  none\n'
    return 0
  fi

  for item in "${HISTORY[@]}"; do
    idx="${item%%:*}"
    color="${item#*:}"
    move="${color#*:}"
    color="${color%%:*}"
    printf '  %s. %s -> column %s\n' "$idx" "$(con4_color_name "$color")" "$move"
  done
}

con4_save_history() {
  local filename="${1:-}"
  local stamp=""

  mkdir -p -- "$CON4_SAVE_DIR"
  if [[ -z "$filename" ]]; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    filename="${CON4_SAVE_DIR%/}/con4-${stamp}.txt"
  fi

  con4_history_text > "$filename"
  printf 'Saved transcript to %s\n' "$filename"
}

con4_show_ingame_help() {
  cat <<'EOF_HELP'
During your turn:
  0..N      Drop a coin in that column.
  history   Show move history.
  save      Save this round transcript.
  resign    Resign the current round.
  q, quit   Quit and notify the opponent.
EOF_HELP
}

con4_quit() {
  local message="${1:-Goodbye.}"
  con4_send_msg "QUIT" "normal" 2>/dev/null || true
  printf '%s\n' "$message"
  exit 0
}

con4_make_turn_move() {
  local prompt_color="$1"
  local move=""

  while true; do
    con4_prompt "$(con4_color_name "$prompt_color") move [0-$((COLS - 1)), history, save, resign, q]: " || con4_quit
    move="$INPUT"

    case "$move" in
      q|Q|quit|QUIT)
        con4_quit
        ;;
      help|h|H)
        con4_show_ingame_help
        continue
        ;;
      history)
        con4_history_text
        continue
        ;;
      save)
        con4_save_history
        continue
        ;;
      resign)
        WINNER="$(con4_opponent_color "$prompt_color")"
        if (( ! LOCAL_MODE )); then
          con4_send_or_die "RESIGN" "" "resignation"
        fi
        return 0
        ;;
    esac

    if con4_valid_move "$move"; then
      break
    fi

    printf 'Invalid move. Use a column from 0 to %d that is not full.\n' "$((COLS - 1))"
  done

  con4_insert_move "$move" "$CURRENT_TURN"
  if (( ! LOCAL_MODE )); then
    con4_send_or_die "MOVE" "$move" "move"
  fi
  con4_swap_turn
}

con4_get_remote_move() {
  printf "Waiting for opponent's move.\n"
  con4_recv_msg "$CON4_MOVE_TIMEOUT" "opponent move"

  case "$MSG_TYPE" in
    QUIT)
      printf 'Opponent quit.\n'
      exit 0
      ;;
    RESIGN)
      printf 'Opponent resigned.\n'
      WINNER="$LOCAL_COLOR"
      ;;
    MOVE)
      if ! con4_valid_move "$MSG_ARG"; then
        con4_send_msg "ERROR" "invalid-move" 2>/dev/null || true
        con4_die "Opponent sent an invalid move. Disconnecting."
      fi
      con4_insert_move "$MSG_ARG" "$CURRENT_TURN"
      con4_swap_turn
      ;;
    ERROR)
      con4_die "Opponent reported an error: $MSG_ARG"
      ;;
    *)
      con4_send_msg "ERROR" "unexpected-message" 2>/dev/null || true
      con4_die "Protocol error: expected MOVE, RESIGN, or QUIT."
      ;;
  esac
}

con4_local_rematch() {
  local answer=""

  while true; do
    con4_prompt "Play again [y/N]? " || return 1
    answer="$INPUT"
    case "$answer" in
      y|Y|yes|YES)
        ROUND_NUMBER=$((ROUND_NUMBER + 1))
        con4_reset_game
        return 0
        ;;
      ''|n|N|no|NO|q|Q|quit|QUIT)
        return 1
        ;;
      *)
        printf 'Please answer y or n.\n'
        ;;
    esac
  done
}

con4_network_rematch() {
  local answer=""
  local local_answer="N"
  local remote_answer="N"

  while true; do
    con4_prompt "Play again [y/N or q]? " || local_answer="N"
    answer="${INPUT:-}"
    case "$answer" in
      y|Y|yes|YES)
        local_answer="Y"
        break
        ;;
      ''|n|N|no|NO|q|Q|quit|QUIT)
        local_answer="N"
        break
        ;;
      *)
        printf 'Please answer y or n.\n'
        ;;
    esac
  done

  con4_send_or_die "REMATCH_RESPONSE" "$local_answer" "replay answer"

  if [[ "$local_answer" == "N" ]]; then
    printf 'Goodbye.\n'
    exit 0
  fi

  printf 'Waiting for opponent replay answer.\n'
  con4_recv_msg "$CON4_REPLAY_TIMEOUT" "opponent replay answer"

  case "$MSG_TYPE" in
    REMATCH_RESPONSE)
      remote_answer="$MSG_ARG"
      ;;
    QUIT)
      printf 'Opponent quit.\n'
      exit 0
      ;;
    *)
      con4_die "Protocol error: expected replay answer."
      ;;
  esac

  if [[ "$remote_answer" != "Y" ]]; then
    printf 'Opponent declined replay.\n'
    exit 0
  fi

  ROUND_NUMBER=$((ROUND_NUMBER + 1))
  con4_reset_game
}

con4_finish_round() {
  con4_apply_finished_game_score
  con4_clear_screen
  con4_display_status
  con4_display_grid

  if [[ "$WINNER" == "$EMPTY" ]]; then
    printf 'Draw.\n'
  elif ((LOCAL_MODE)); then
    printf '%s wins.\n' "$(con4_color_name "$WINNER")"
  elif [[ "$WINNER" == "$LOCAL_COLOR" ]]; then
    printf 'You win.\n'
  else
    printf 'Opponent wins.\n'
  fi

  if ((LOCAL_MODE)); then
    con4_local_rematch || con4_quit
  else
    con4_network_rematch
  fi
}

con4_game_loop() {
  STATUS="$STATUS_PLAYING"
  while true; do
    con4_clear_screen
    con4_display_status
    con4_display_grid

    if ((LOCAL_MODE)); then
      con4_make_turn_move "$CURRENT_TURN"
    elif [[ "$CURRENT_TURN" == "$LOCAL_COLOR" ]]; then
      con4_make_turn_move "$LOCAL_COLOR"
    else
      con4_get_remote_move
    fi

    if [[ "$WINNER" != "$EMPTY" ]] || con4_check_winner || con4_board_full; then
      con4_finish_round
    fi
  done
}

con4_create_game() {
  LOCAL_MODE=0
  LOCAL_COLOR="$YELLOW"
  STATUS="$STATUS_WAITING"

  con4_validate_config
  con4_validate_host "$HOST" || con4_die "Error: invalid host."
  con4_validate_port "$PORT" || con4_die "Error: invalid port."
  con4_validate_token "$CON4_TOKEN" || con4_die "Error: game code cannot contain newlines or '|'."
  con4_validate_game_name "$CON4_GAME_NAME" || con4_die "Error: lobby game name must be 1-40 characters and cannot contain newlines or '|'."
  con4_validate_port "$CON4_LOBBY_PORT" || con4_die "Error: lobby port must be 1-65535."

  con4_start_lobby_beacon
  con4_wait_for_handshake_as_server
  con4_reset_game
  con4_game_loop
}

con4_join_game() {
  LOCAL_MODE=0
  LOCAL_COLOR="$RED"
  STATUS="$STATUS_WAITING"

  con4_validate_config
  con4_validate_host "$HOST" || con4_die "Error: invalid host."
  con4_validate_port "$PORT" || con4_die "Error: invalid port."
  con4_validate_token "$CON4_TOKEN" || con4_die "Error: game code cannot contain newlines or '|'."

  con4_start_transport_client
  con4_wait_for_handshake_as_client
  con4_reset_game
  con4_game_loop
}

con4_local_game() {
  LOCAL_MODE=1
  LOCAL_COLOR=""
  STATUS="$STATUS_PLAYING"

  con4_validate_config
  con4_reset_game
  con4_game_loop
}

con4_replay_load() {
  local filename="$1"
  local line=""
  local move_color=""
  local move_col=""
  local rules_re='^Rules:[[:space:]]+([0-9]+)x([0-9]+),[[:space:]]+connect[[:space:]]+([0-9]+)$'
  local move_re='^[[:space:]]*[0-9]+\.[[:space:]]+(yellow|red)[[:space:]]+->[[:space:]]+column[[:space:]]+([0-9]+)$'

  [[ -f "$filename" ]] || con4_die "Error: replay file not found: $filename"

  REPLAY_MOVES=()
  REPLAY_COLORS=()

  while IFS= read -r line; do
    if [[ "$line" =~ $rules_re ]]; then
      ROWS="${BASH_REMATCH[1]}"
      COLS="${BASH_REMATCH[2]}"
      CONNECT="${BASH_REMATCH[3]}"
      con4_validate_config
    elif [[ "$line" =~ $move_re ]]; then
      move_color="${BASH_REMATCH[1]}"
      move_col="${BASH_REMATCH[2]}"
      if [[ "$move_color" == "yellow" ]]; then
        REPLAY_COLORS+=("$YELLOW")
      else
        REPLAY_COLORS+=("$RED")
      fi
      REPLAY_MOVES+=("$move_col")
    fi
  done < "$filename"

  ((${#REPLAY_MOVES[@]} > 0)) || con4_die "Error: no moves found in replay file."
}

con4_replay_view() {
  local filename="$1"
  local i=""
  local move=""
  local color=""

  con4_replay_load "$filename"
  LOCAL_MODE=1
  LOCAL_COLOR=""
  STATUS="$STATUS_PLAYING"
  ROUND_NUMBER=1
  YELLOW_SCORE=0
  RED_SCORE=0
  con4_reset_game

  con4_clear_screen
  printf 'Replay: %s\n' "$filename"
  printf 'Starting position. Press Ctrl-C to stop.\n'
  con4_display_status
  con4_display_grid
  sleep "$CON4_REPLAY_VIEW_DELAY"

  for ((i = 0; i < ${#REPLAY_MOVES[@]}; i++)); do
    move="${REPLAY_MOVES[$i]}"
    color="${REPLAY_COLORS[$i]}"
    if ! con4_valid_move "$move"; then
      con4_die "Error: replay contains illegal move $move at move $((i + 1))."
    fi
    con4_insert_move "$move" "$color"
    CURRENT_TURN="$(con4_opponent_color "$color")"

    con4_clear_screen
    printf 'Replay: %s\n' "$filename"
    printf 'Move %d/%d: %s -> column %s\n' "$((i + 1))" "${#REPLAY_MOVES[@]}" "$(con4_color_name "$color")" "$move"
    con4_display_status
    con4_display_grid
    con4_check_winner || true
    sleep "$CON4_REPLAY_VIEW_DELAY"
  done

  if [[ "$WINNER" != "$EMPTY" ]]; then
    printf '%s wins in the replay.\n' "$(con4_color_name "$WINNER")"
  elif con4_board_full; then
    printf 'Replay ends in a draw.\n'
  else
    printf 'Replay finished before the board was decided.\n'
  fi
}

con4_doctor() {
  local nc_path="not found"
  local ncat_path="not found"
  local socat_path="not found"
  local openssl_path="not found"

  command -v nc >/dev/null 2>&1 && nc_path="$(command -v nc)"
  command -v ncat >/dev/null 2>&1 && ncat_path="$(command -v ncat)"
  command -v socat >/dev/null 2>&1 && socat_path="$(command -v socat)"
  command -v openssl >/dev/null 2>&1 && openssl_path="$(command -v openssl)"

  con4_version
  printf '\nDiagnostics:\n'
  printf '  Bash: %s\n' "$BASH_VERSION"
  printf '  socat: %s\n' "$socat_path"
  printf '  ncat: %s\n' "$ncat_path"
  printf '  nc: %s\n' "$nc_path"
  printf '  openssl: %s\n' "$openssl_path"
  printf '  Host: %s\n' "$HOST"
  printf '  Port: %s\n' "$PORT"
  printf '  Rules: %sx%s, connect %s\n' "$ROWS" "$COLS" "$CONNECT"
  printf '  Board rendering: %sx%s cells, %s border, %s pieces\n' "$CELL_WIDTH" "$CELL_HEIGHT" "$BORDER_STYLE" "$PIECE_STYLE"
  printf '  HMAC token: %s\n' "$([[ -n "$CON4_TOKEN" ]] && printf enabled || printf disabled)"
  printf '  Lobby advertising: %s\n' "$([[ "$CON4_ADVERTISE" == "1" ]] && printf enabled || printf disabled)"
  printf '  Lobby port: %s UDP\n' "$CON4_LOBBY_PORT"
  printf '  Lobby scan timeout: %s seconds\n' "$CON4_LOBBY_TIMEOUT"
  printf '  Host-list ports: %s\n' "$CON4_SCAN_PORTS"
  printf '  Probe timeout: %s seconds per port\n' "$CON4_PROBE_TIMEOUT"
  if [[ "$CON4_HANDSHAKE_TIMEOUT" == "0" ]]; then
    printf '  Handshake timeout: disabled\n'
  else
    printf '  Handshake timeout: %s seconds\n' "$CON4_HANDSHAKE_TIMEOUT"
  fi

  printf '\nRecommendations:\n'
  if [[ "$socat_path" != "not found" ]]; then
    printf '  Good: socat is available and will be used first. It is also required for lobby discovery.\n'
  elif [[ "$ncat_path" != "not found" || "$nc_path" != "not found" ]]; then
    printf '  OK: netcat is available for direct games. Install socat for lobby discovery.\n'
  else
    printf '  Missing: install socat, ncat, nc, or netcat for network play.\n'
  fi

  if [[ -n "$CON4_TOKEN" && "$openssl_path" == "not found" ]]; then
    printf '  Missing: openssl is required when CON4_TOKEN is set.\n'
  fi
  if [[ "$CON4_ADVERTISE" == "1" && "$socat_path" == "not found" ]]; then
    printf '  Missing: socat is required for LAN lobby advertising and browsing.\n'
  fi

  printf '\nExamples:\n'
  printf '  Same-machine server: %s create --host 127.0.0.1 --port %s\n' "$0" "$PORT"
  printf '  Same-machine client: %s join --host 127.0.0.1 --port %s\n' "$0" "$PORT"
  printf '  Host game: %s create --host 0.0.0.0 --port %s --name "Friday game"\n' "$0" "$PORT"
  printf '  List games on a host: %s lobby --host 192.168.1.20 --ports 9411-9420\n' "$0"
  printf '  LAN advertised game: %s create --host 0.0.0.0 --port %s --advertise --name "Friday game"\n' "$0" "$PORT"
  printf '  Browse LAN lobby: %s lobby\n' "$0"
}

con4_assert() {
  local description="$1"
  shift
  if "$@"; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s\n' "$description" >&2
    return 1
  fi
}

con4_self_test() {
  local old_rows="$ROWS"
  local old_cols="$COLS"
  local old_connect="$CONNECT"
  local failures=0

  CON4_NO_COLOR=1
  ROWS=6
  COLS=7
  CONNECT=4
  con4_reset_game

  con4_insert_move 0 "$YELLOW"
  con4_insert_move 1 "$YELLOW"
  con4_insert_move 2 "$YELLOW"
  con4_insert_move 3 "$YELLOW"
  con4_assert "horizontal win" con4_check_winner || failures=$((failures + 1))
  [[ "$WINNER" == "$YELLOW" ]] || failures=$((failures + 1))

  con4_reset_game
  con4_insert_move 0 "$RED"
  con4_insert_move 0 "$RED"
  con4_insert_move 0 "$RED"
  con4_insert_move 0 "$RED"
  con4_assert "vertical win" con4_check_winner || failures=$((failures + 1))
  [[ "$WINNER" == "$RED" ]] || failures=$((failures + 1))

  con4_reset_game
  con4_insert_move 0 "$YELLOW"
  con4_insert_move 1 "$RED"
  con4_insert_move 1 "$YELLOW"
  con4_insert_move 2 "$RED"
  con4_insert_move 2 "$RED"
  con4_insert_move 2 "$YELLOW"
  con4_insert_move 3 "$RED"
  con4_insert_move 3 "$RED"
  con4_insert_move 3 "$RED"
  con4_insert_move 3 "$YELLOW"
  con4_assert "diagonal win" con4_check_winner || failures=$((failures + 1))
  [[ "$WINNER" == "$YELLOW" ]] || failures=$((failures + 1))

  con4_reset_game
  con4_assert "valid empty column" con4_valid_move 0 || failures=$((failures + 1))
  for _ in 1 2 3 4 5 6; do
    con4_insert_move 0 "$YELLOW"
  done
  if con4_valid_move 0; then
    printf 'not ok - full column rejected\n' >&2
    failures=$((failures + 1))
  else
    printf 'ok - full column rejected\n'
  fi

  ROWS="$old_rows"
  COLS="$old_cols"
  CONNECT="$old_connect"

  if ((failures > 0)); then
    con4_die "Self-test failed with ${failures} failure(s)."
  fi
  printf 'All self-tests passed.\n'
}

con4_version() {
  printf 'Con4 version %s\n' "$SCRIPT_VERSION"
}

con4_help() {
  con4_version
  cat <<'EOF_HELP'

Usage:
  con4.sh                         Start interactive menu.
  con4.sh create [options]         Create/listen for a network game.
  con4.sh join [options]           Join a network game directly. Rules are received from the creator.
  con4.sh local [options]          Play local hot-seat mode.
  con4.sh lobby [options]          Browse LAN games, or query one host with --host.
  con4.sh replay FILE [options]    View a saved transcript.
  con4.sh doctor                   Print transport diagnostics.
  con4.sh self-test                Run board-logic tests.

Options:
  --host HOST                      Bind/connect host. Default: 127.0.0.1.
  --port PORT                      TCP port. Default: 9411.
  --token TOKEN                    Optional shared game code for HMAC authentication.
  --advertise                      Advertise created game in the LAN lobby.
                                   Also allowed as shorthand: con4.sh --advertise.
  --name NAME                      Game/lobby name. Default: Con4 game.
  --advertise-host HOST            Host/IP shown in lobby advertisements.
  --lobby-port PORT                UDP discovery port. Default: 9410.
  --lobby-timeout SECONDS          LAN lobby scan time from 1 to 60. Default: 5.
  --ports LIST                     Ports checked by lobby --host. Example: 9411 or 9411-9420.
  --probe-timeout SECONDS          Per-port game-list query timeout. Default: 2.
  --rows N                         Board rows for create/local. Default: 6.
  --cols N                         Board columns for create/local. Default: 7.
  --connect N                      Winning line length for create/local. Default: 4.
  --cell-width N                   Cell width from 1 to 15. Default: 3.
  --cell-height N                  Cell height from 1 to 7. Default: 1.
  --border STYLE                   single, double, rounded, heavy, ascii, or none.
  --piece STYLE                    diamond, circle, letter, or ascii.
  --theme NAME                     compact, classic, big, or ascii.
  --handshake-timeout SECONDS      Default: 0, meaning no timeout.
  --move-timeout SECONDS           Default: 0, meaning no timeout.
  --replay-timeout SECONDS         Default: 0, meaning no timeout.
  --replay-delay SECONDS           Delay between replay moves. Default: 0.6.
  --no-color                       Disable ANSI color.
  -h, --help                       Show this help.
  -v, --version                    Show version.

During your turn:
  0..N       Drop a coin in that column.
  history    Show move history.
  save       Save a transcript.
  resign     Resign the current round.
  q, quit    Quit and notify the opponent.

Environment:
  HOST, PORT, CON4_TOKEN, CON4_ROWS, CON4_COLS, CON4_CONNECT
  CON4_CELL_WIDTH, CON4_CELL_HEIGHT, CON4_BORDER_STYLE, CON4_PIECE_STYLE
  CON4_HANDSHAKE_TIMEOUT, CON4_MOVE_TIMEOUT, CON4_REPLAY_TIMEOUT
  CON4_ADVERTISE, CON4_GAME_NAME, CON4_ADVERTISE_HOST, CON4_LOBBY_PORT
  CON4_LOBBY_TIMEOUT, CON4_SCAN_PORTS, CON4_PROBE_TIMEOUT, CON4_REPLAY_VIEW_DELAY
  CON4_NC_LISTEN_STYLE=auto|port|hostport|traditional
  CON4_SAVE_DIR

Security note:
  Plain TCP is not encrypted. CON4_TOKEN authenticates protocol messages with
  HMAC-SHA256 when openssl is installed, but it does not hide traffic. The
  LAN lobby discovery uses unauthenticated UDP broadcast. Host game listing uses
  a harmless INFO query to waiting game ports. Both are convenience features,
  not security boundaries. For untrusted
  networks, use SSH, VPN, Tailscale, or a TLS tunnel.
EOF_HELP
}

con4_parse_common_options() {
  while (($# > 0)); do
    case "$1" in
      --host)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --host requires a value."
        HOST="$1"
        HOST_OPTION_SET=1
        ;;
      --port)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --port requires a value."
        PORT="$1"
        ;;
      --token)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --token requires a value."
        CON4_TOKEN="$1"
        ;;
      --advertise)
        CON4_ADVERTISE=1
        ;;
      --no-advertise)
        CON4_ADVERTISE=0
        ;;
      --name|--game-name)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --name requires a value."
        CON4_GAME_NAME="$1"
        ;;
      --advertise-host)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --advertise-host requires a value."
        CON4_ADVERTISE_HOST="$1"
        ;;
      --lobby-port)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --lobby-port requires a value."
        CON4_LOBBY_PORT="$1"
        ;;
      --lobby-timeout)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --lobby-timeout requires a value."
        CON4_LOBBY_TIMEOUT="$1"
        ;;
      --ports|--scan-ports)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --ports requires a value."
        CON4_SCAN_PORTS="$1"
        ;;
      --probe-timeout)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --probe-timeout requires a value."
        CON4_PROBE_TIMEOUT="$1"
        ;;
      --rows)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --rows requires a value."
        ROWS="$1"
        ;;
      --cols|--columns)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --cols requires a value."
        COLS="$1"
        ;;
      --connect)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --connect requires a value."
        CONNECT="$1"
        ;;
      --handshake-timeout)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --handshake-timeout requires a value."
        CON4_HANDSHAKE_TIMEOUT="$1"
        ;;
      --move-timeout)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --move-timeout requires a value."
        CON4_MOVE_TIMEOUT="$1"
        ;;
      --replay-timeout)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --replay-timeout requires a value."
        CON4_REPLAY_TIMEOUT="$1"
        ;;
      --replay-delay)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --replay-delay requires a value."
        CON4_REPLAY_VIEW_DELAY="$1"
        ;;
      --cell-width)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --cell-width requires a value."
        CELL_WIDTH="$1"
        ;;
      --cell-height)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --cell-height requires a value."
        CELL_HEIGHT="$1"
        ;;
      --border|--border-style)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --border requires a value."
        BORDER_STYLE="$1"
        ;;
      --piece|--piece-style)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --piece requires a value."
        PIECE_STYLE="$1"
        ;;
      --theme)
        shift
        [[ $# -gt 0 ]] || con4_die "Error: --theme requires a value."
        case "$1" in
          compact) CELL_WIDTH=1; CELL_HEIGHT=1; BORDER_STYLE=ascii; PIECE_STYLE=letter ;;
          classic) CELL_WIDTH=3; CELL_HEIGHT=1; BORDER_STYLE=single; PIECE_STYLE=diamond ;;
          big) CELL_WIDTH=5; CELL_HEIGHT=3; BORDER_STYLE=double; PIECE_STYLE=circle ;;
          ascii) CELL_WIDTH=3; CELL_HEIGHT=1; BORDER_STYLE=ascii; PIECE_STYLE=ascii; CON4_NO_COLOR=1 ;;
          *) con4_die "Error: theme must be compact, classic, big, or ascii." ;;
        esac
        ;;
      --no-color)
        CON4_NO_COLOR=1
        ;;
      -h|--help)
        con4_help
        exit 0
        ;;
      *)
        con4_die "Error: unknown option: $1"
        ;;
    esac
    shift
  done

  con4_validate_config
  con4_validate_host "$HOST" || con4_die "Error: invalid host."
  con4_validate_port "$PORT" || con4_die "Error: invalid port."
  con4_validate_token "$CON4_TOKEN" || con4_die "Error: game code cannot contain newlines or '|'."
  con4_validate_number_range "$CON4_HANDSHAKE_TIMEOUT" 0 86400 || con4_die "Error: invalid handshake timeout."
  con4_validate_number_range "$CON4_MOVE_TIMEOUT" 0 86400 || con4_die "Error: invalid move timeout."
  con4_validate_number_range "$CON4_REPLAY_TIMEOUT" 0 86400 || con4_die "Error: invalid replay timeout."
  con4_validate_number_range "$CON4_LOBBY_PORT" 1 65535 || con4_die "Error: invalid lobby port."
  con4_validate_number_range "$CON4_LOBBY_TIMEOUT" 1 60 || con4_die "Error: lobby timeout must be from 1 to 60 seconds."
  con4_validate_number_range "$CON4_PROBE_TIMEOUT" 1 60 || con4_die "Error: probe timeout must be from 1 to 60 seconds."
  con4_parse_scan_ports "$CON4_SCAN_PORTS" || con4_die "Error: ports must be one port, a comma list, or a small range such as 9411-9420."
  con4_validate_game_name "$CON4_GAME_NAME" || con4_die "Error: lobby game name must be 1-40 characters and cannot contain newlines, '|', or commas."
  if [[ -n "$CON4_ADVERTISE_HOST" ]]; then
    con4_validate_host "$CON4_ADVERTISE_HOST" || con4_die "Error: invalid advertise host."
  fi
  con4_validate_decimal "$CON4_REPLAY_VIEW_DELAY" || con4_die "Error: replay delay must be a non-negative number."

  if [[ "$CON4_NO_COLOR" == "1" ]]; then
    con4_disable_colors
  fi
}

con4_menu() {
  local action=""

  con4_clear_screen
  con4_version
  con4_display_status
  printf 'c=create, b=browse lobby, j=join by host, l=local, d=doctor, h=help, q=quit.\n'

  while [[ -z "$action" ]]; do
    con4_prompt "> " || action="q"
    action="${INPUT:0:1}"
  done

  case "$action" in
    c|C)
      con4_prompt_create_settings
      con4_create_game
      ;;
    b|B)
      con4_lobby_browse
      ;;
    j|J)
      if con4_prompt_join_settings; then
        con4_join_game
      fi
      ;;
    l|L)
      con4_prompt_local_settings
      con4_local_game
      ;;
    d|D)
      con4_doctor
      ;;
    h|H)
      con4_help
      ;;
    q|Q)
      printf 'Goodbye.\n'
      ;;
    *)
      con4_die "Error: invalid option. Press h for help."
      ;;
  esac
}

con4_main() {
  local command="${1:-}"

  trap con4_cleanup EXIT
  trap con4_on_interrupt INT TERM

  con4_init_colors

  case "$command" in
    "")
      con4_menu
      ;;
    create)
      shift
      con4_parse_common_options "$@"
      con4_create_game
      ;;
    join)
      shift
      con4_parse_common_options "$@"
      con4_join_game
      ;;
    local)
      shift
      con4_parse_common_options "$@"
      con4_local_game
      ;;
    lobby|browse)
      shift
      con4_parse_common_options "$@"
      con4_lobby_browse
      ;;
    replay)
      shift
      local replay_file="${1:-}"
      [[ -n "$replay_file" ]] || con4_die "Error: replay requires a transcript file."
      shift
      con4_parse_common_options "$@"
      con4_replay_view "$replay_file"
      ;;
    doctor)
      shift
      con4_parse_common_options "$@"
      con4_doctor
      ;;
    self-test|--self-test)
      shift || true
      con4_parse_common_options "$@"
      con4_self_test
      ;;
    -h|--help|help)
      con4_help
      ;;
    -v|--version|version)
      con4_version
      ;;
    --*)
      # Convenience: allow ./con4.sh --advertise --host 0.0.0.0 as shorthand for create.
      con4_parse_common_options "$@"
      con4_create_game
      ;;
    *)
      con4_die "Error: unknown command: $command. Use --help."
      ;;
  esac
}

con4_main "$@"
