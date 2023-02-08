#!/bin/bash

: "${HOST:=localhost}"
: "${PORT:=9411}"

RED_COLOR=$(tput setaf 1)
YELLOW_COLOR=$(tput setaf 3)
BLUE_COLOR=$(tput setaf 4)
GREEN_COLOR=$(tput setaf 2)
NORMAL_COLOR=$(tput sgr 0)

: "${COLOR1:=$BLUE_COLOR}"
: "${COLOR2:=$YELLOW_COLOR}"
: "${COLOR3:=$RED_COLOR}"
: "${COLOR4:=$RED_COLOR}"
: "${COLOR5:=$YELLOW_COLOR}"
: "${COLOR6:=$GREEN_COLOR}"

# Advanced settings
: "${FIFO_IN:=/tmp/in.$RANDOM}"
: "${FIFO_OUT:=/tmp/out.$RANDOM}"

SCRIPT_VERSION="0.5"
STATUS_IDLE="IDLE"
STATUS_PLAYING="PLAYING"
STATUS_WAITING_OPPONENT="WAITING_OPPONENT"
STATUS="$STATUS_IDLE"
CLIENT_MACHINE="CLIENT"
SERVER_MACHINE="SERVER"
CURRENT_MACHINE=""
RECONNECT_COMMAND="RECONNECT"
HELLO_COMMAND="YO"
RED="RED"
YELLOW="YELLOW"
EMPTY="EMPTY"
CURRENT_TURN="$YELLOW"
GRID_ROWS=6
GRID_COLUMNS=7
YELLOW_SCORE=0
RED_SCORE=0

declare -A DATA
declare -A STACK_SIZES

function con4_clear_screen() {
    printf "\033c"
}

function con4_display_status() {
    output="Status: "
    case "$STATUS" in
        "$STATUS_IDLE")
            output+="${COLOR4}idle${NORMAL_COLOR}."
            ;;
        "$STATUS_PLAYING")
            output+="${COLOR6}playing${NORMAL_COLOR}."
            output+=$'\n'"Score: ${COLOR2}${YELLOW_SCORE}${NORMAL_COLOR} - "
            output+="${COLOR3}${RED_SCORE}${NORMAL_COLOR}"
            output+=$'\n'"Current turn: "
            if [[ "$CURRENT_TURN" == "$YELLOW" ]]; then
                output+="${COLOR2}yellow (YOU)${NORMAL_COLOR}."
            else
                output+="${COLOR3}red (OPPONENT)${NORMAL_COLOR}."
            fi
            ;;
        "$STATUS_WAITING_OPPONENT")
            output+="${COLOR5}waiting opponent${NORMAL_COLOR}."
            ;;
        *)
            output+="${COLOR4}idle${NORMAL_COLOR}."
            ;;
    esac
    echo "$output"
}

function con4_display_grid() {
    local top_left top_middle top_right middle_left middle_middle middle_right \
    bottom_left bottom_middle bottom_right horizontal_separator                \
    vertical_separator coin output value
    top_left="${COLOR1}┌"
    top_middle="${COLOR1}┬"
    top_right="${COLOR1}┐"
    middle_left="${COLOR1}├"
    middle_middle="${COLOR1}┼"
    middle_right="${COLOR1}┤"
    bottom_left="${COLOR1}└"
    bottom_middle="${COLOR1}┴"
    bottom_right="${COLOR1}┘"
    horizontal_separator="${COLOR1}───"
    vertical_separator="${COLOR1}│"
    coin=" ◆ "
    empty_output="   "
    output=""
    for column in $(seq 0 "$GRID_COLUMNS"); do
        if [[ column -eq 0 ]]; then
            output+="$top_left"
            output+="$horizontal_separator"
        elif [[ column -lt "$GRID_COLUMNS" ]]; then
            output+="$top_middle"
            output+="$horizontal_separator"
        else
            output+="$top_right"
        fi
    done
    output+=$'\n'
    for row in $(seq 0 "$((GRID_ROWS - 1))"); do
        for column in $(seq 0 "$((GRID_COLUMNS - 1))"); do
            output+="$vertical_separator"
            opposite_row=$(("$GRID_ROWS" - "$row" - 1))
            value="${DATA[$opposite_row,$column]}"
            if [[ "$value" == "$RED" ]]; then
                output+="${COLOR3}${coin}"
            elif [[ "$value" == "$YELLOW" ]]; then
                output+="${COLOR2}${coin}"
            else
                output+="$empty_output"
            fi
        done
        output+="$vertical_separator"$'\n'
        if [[ row -ne "$((GRID_ROWS - 1))" ]]; then
            for column in $(seq 0 "$GRID_COLUMNS"); do
                if [[ column -eq 0 ]]; then
                    output+="$middle_left"
                    output+="$horizontal_separator"
                elif [[ column -lt "$GRID_COLUMNS" ]]; then
                    output+="$middle_middle"
                    output+="$horizontal_separator"
                else
                    output+="$middle_right"
                fi
            done
            output+=$'\n'
        fi
    done
    for column in $(seq 0 "$GRID_COLUMNS"); do
        if [[ column -eq 0 ]]; then
            output+="$bottom_left"
            output+="$horizontal_separator"
        elif [[ column -lt "$GRID_COLUMNS" ]]; then
            output+="$bottom_middle"
            output+="$horizontal_separator"
        else
            output+="$bottom_right"
        fi
    done
    output+=$'\n'"$NORMAL_COLOR"
    for column in $(seq 0 "$((GRID_COLUMNS - 1))"); do
        output+="  $column "
    done
    echo "$output"
}

function con4_check_win(){
    local current
    columns_3=$(("$GRID_COLUMNS" - 3))
    rows_3=$(("$GRID_ROWS" - 3))
    for(( i=0; i<"$GRID_ROWS"; i++ )); do
        for(( j=0; j<"$columns_3"; j++ )); do
            current="${DATA[$i,$j]}"
            if [[ "$current" != "$EMPTY" ]]; then
                jndex1=$(("$j" + 1))
                jndex2=$(("$j" + 2))
                jndex3=$(("$j" + 3))
                if [[ \
                    "$current" == "${DATA[$i,$jndex1]}" &&                     \
                    "$current" == "${DATA[$i,$jndex2]}" &&                     \
                    "$current" == "${DATA[$i,$jndex3]}"                        \
                ]]; then
                    con4_set_win "$current"
                    return 1
                fi
            fi
        done
    done
    for(( i=0; i<"$GRID_COLUMNS"; i++ )); do
        for(( j=0; j<"$rows_3"; j++ )); do
            current="${DATA[$j,$i]}"
            if [[ "$current" != "$EMPTY" ]]; then
                jndex1=$(("$j" + 1))
                jndex2=$(( "$j" + 2))
                jndex3=$(( "$j" + 3))
                if [[ \
                    "$current" == "${DATA[$jndex1,$i]}" &&                     \
                    "$current" == "${DATA[$jndex2,$i]}" &&                     \
                    "$current" == "${DATA[$jndex3,$i]}"                        \
                ]]; then
                    con4_set_win "$current"
                    return 1
                fi
            fi
        done
    done
    for(( i=0; i<"$rows_3"; i++ )); do
        for(( j=0; j<"$columns_3"; j++ )); do
            current="${DATA[$i,$j]}"
            if [[ "$current" != "$EMPTY" ]]; then
                index1=$(("$i" + 1))
                index2=$(("$i" + 2))
                index3=$(("$i" + 3))
                jndex1=$(("$j" + 1))
                jndex2=$(("$j" + 2))
                jndex3=$(("$j" + 3))
                if [[
                    "$current" == "${DATA[$index1,$jndex1]}" &&                \
                    "$current" == "${DATA[$index2,$jndex2]}" &&                \
                    "$current" == "${DATA[$index3,$jndex3]}"                   \
                ]]; then
                    con4_set_win "$current"
                    return 1
                fi
            fi
        done
    done
    for(( i=3; i<"$GRID_ROWS"; i++ )); do
        for(( j=3; j<"$GRID_COLUMNS"; j++ )); do
            current="${DATA[$i,$j]}"
            if [[ "$current" != "$EMPTY" ]]; then
                index1=$((i - 1))
                index2=$((i - 2))
                index3=$((i - 3))
                jndex1=$((j - 1))
                jndex2=$((j - 2))
                jndex3=$((j - 3))
                if [[
                    "$current" == "${DATA[$index1,$jndex1]}" &&                \
                    "$current" == "${DATA[$index2,$jndex2]}" &&                \
                    "$current" == "${DATA[$index3,$jndex3]}"                   \
                ]]; then
                    con4_set_win "$current"
                    return 1
                fi
            fi
        done
    done
    return 0
}

function con4_set_win(){
    STATUS="$STATUS_IDLE"
    if [[ "$1" == "$YELLOW" ]]; then
        YELLOW_SCORE=$((YELLOW_SCORE + 1))
    else
        RED_SCORE=$((RED_SCORE + 1))
    fi
}

# $1 move
function con4_validate_move(){
    if [[ ! "$1" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    if [[ ! "$1" -lt "$GRID_COLUMNS" ]]; then
        return 0
    fi
    if [[ ! "${STACK_SIZES[$1]}" -lt "$GRID_ROWS" ]]; then
        return 0
    fi
    return 1
}

# $1 move
# $2 color
function con4_insert_move() {
    if [[ $# -lt 1 ]]; then
        echo "An error occurred."
        exit
    fi
    height="${STACK_SIZES[$1]}"
    STACK_SIZES["$1"]=$((STACK_SIZES["$1"]+1))
    DATA["$height","$1"]="$2"
}

function con4_encode_game_data() {
    :
}

function con4_decode_game_data() {
    :
}

function con4_send_game_data() {
    :
}

function con4_get_opponent_move() {
    echo "Waiting opponent's move."
    if read -r move < "$FIFO_OUT"; then
        if [[                                                                  \
            "$move" == "$RECONNECT_COMMAND" &&                                 \
            "$CURRENT_MACHINE" == "$SERVER_MACHINE"                            \
        ]]; then
            : # TODO
        fi
        con4_validate_move "$move"
        if [[ "$?" -eq 0 ]]; then
            echo "Opponent sent an invalid move."
            echo "Disconnecting."
            # TODO
            exit 1
        fi
    fi
    con4_insert_move "$move" "$CURRENT_TURN"
    con4_swap_current_turn
    while read -r -t 0; do read -r; done
}

function con4_send_hello_message() {
    echo "$HELLO_COMMAND" >> "$FIFO_IN"
}

function con4_swap_current_turn() {
    if [[ "$CURRENT_TURN" == "$YELLOW" ]]; then
        CURRENT_TURN="$RED"
    else
        CURRENT_TURN="$YELLOW"
    fi
}

function con4_make_move() {
    while : ; do
        con4_get_input "Your move: "
        move="$INPUT"
        con4_validate_move "$move"
        if [[ "$?" -eq 1 ]]; then
            break
        fi
        echo "Invalid move."
    done
    con4_insert_move "$move" "$CURRENT_TURN"
    con4_swap_current_turn
    echo "$move" | tee "$FIFO_IN"
}

function con4_reset_game() {
    for (( i=0; i<"$GRID_ROWS"; i++ )); do
        for (( j=0; j<"$GRID_COLUMNS"; j++ )); do
            DATA["$i","$j"]="$EMPTY"
        done
    done
    for (( i=0; i<"$GRID_COLUMNS"; i++ )); do
        STACK_SIZES["$i"]=0
    done
}

function con4_ask_continue() {
    local  prompt
    prompt="Play again [Y/n?] "
    con4_get_input "$prompt"
    case "$INPUT" in
        [Yy])
            con4_reset_game
            ;;
        [Nn])
            exit
            ;;
        *)
            con4_reset_game
            ;;
    esac
}

function con4_game_loop() {
    STATUS="$STATUS_PLAYING"
    while true; do
        con4_clear_screen
        con4_display_status
        con4_display_grid
        con4_check_win
        if [[ "$STATUS" == "$STATUS_IDLE" ]]; then
            echo "Game over."
            con4_ask_continue
            STATUS="$STATUS_PLAYING"
        fi

        if [[ "$CURRENT_TURN" == "$YELLOW" ]]; then
            con4_make_move
        else
            con4_get_opponent_move
        fi
    done
}

function con4_wait_authentication() {
    STATUS="$STATUS_WAITING_OPPONENT"
    echo "Waiting for an opponent."
    while : ; do
        read -r hello_message < "$FIFO_OUT"
        if [[ "$hello_message" != "$HELLO_COMMAND" ]]; then
            echo "Opponent authentication error."
        else
            break
        fi
    done
}

function con4_create_game() {
    CURRENT_MACHINE="$SERVER_MACHINE"
    con4_init_game
    tail -f "$FIFO_IN" | netcat -l "$HOST" "$PORT" | tee "$FIFO_OUT" >         \
    /dev/null &
    con4_wait_authentication
    con4_game_loop
}

function con4_join_game() {
    CURRENT_MACHINE="$CLIENT_MACHINE"
    con4_init_game
    tail -f "$FIFO_IN" | netcat "$HOST" "$PORT" | tee "$FIFO_OUT" > /dev/null &
    con4_send_hello_message
    con4_swap_current_turn
    con4_game_loop
}

function con4_init_game() {
    mkfifo "$FIFO_IN"
    mkfifo "$FIFO_OUT"
    con4_get_input "Host [$HOST]: "
    if [[ -n "$INPUT" ]]; then
        HOST="$INPUT"
    fi
    con4_get_input "Port [$PORT]: "
    if [[ -n "$INPUT" ]]; then
        PORT="$INPUT"
    fi
    con4_reset_game
}

#
# Get Input
#
# $1 [ Prompt ]
# $2 [ Hide character ]
#
function con4_get_input() {
    local prompt
    INPUT=""
    prompt="${1:-Input: }"
    while IFS= read -p "${prompt}" -r -s -n 1 char ; do
        if [[ ${char} == $'\0' ]] ; then
            break
        elif [[ ${char} == $'\177' ]] ; then
            if [[ -z "${INPUT}" ]] ; then
                prompt=""
            else
                prompt=$'\b \b'
                INPUT="${INPUT%?}"
            fi
        else
            if [[ $# -gt 1 ]]; then
                prompt="$2"
            else
                prompt="${char}"
            fi
            INPUT+="${char}"
        fi
    done
    printf "%s" $'\n'
}

function con4_version() {
    echo "Con4 version $SCRIPT_VERSION"
}

function con4_help() {
    cat <<EOF
Options:
  c	Create a new game.
  h	Shows this help.
  j	Join a game.
  q	Quit.  
EOF
}

function con4_quit() {
    rm -rf "$FIFO_IN" "$FIFO_OUT"
    echo $'\n'
    pkill -P $$
    exit
}

function con4_main() {
    con4_clear_screen
    con4_version
    con4_display_status
    while [[ -z "${action}" ]] ; do
        read -r -n 1 -p "> " action
        printf "\\n"
    done
    case "$action" in
        "c")
            con4_create_game
            ;;
        "j")
            con4_join_game
            ;;
        "h")
            con4_help
            ;;
        "q")
            con4_quit
            ;;
        *)
            echo "Error: invalid option. Press h for help."
            exit 1
    esac
    exit 0
}

trap con4_quit SIGINT
con4_main "$@"
