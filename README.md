# con4

A small Connect Four game for the terminal.

It can run as a local two-player game, or as a direct TCP game between two machines. It does not have accounts, chat, matchmaking, or a central lobby server. One player starts a game, another player joins it.

The goal is to keep it simple enough to read, hack on, and run from a shell.

## Requirements

For local play:

- Bash 4 or newer

For network play, install at least one of:

- `socat` recommended
- `nc`, `ncat`, or `netcat`

Optional features:

- `openssl` if you use `--token`
- `socat` for LAN broadcast lobby discovery

## Quick start

Local game in one terminal:

```sh
./con4.sh local
```

Host a game on the same machine:

```sh
./con4.sh create --host 127.0.0.1 --port 9411
```

Join from another terminal:

```sh
./con4.sh join --host 127.0.0.1 --port 9411
```

Host on a LAN:

```sh
./con4.sh create --host 0.0.0.0 --port 9411
```

Then the other player joins using your LAN IP:

```sh
./con4.sh join --host 192.168.1.50 --port 9411
```

For LAN games, `127.0.0.1` only works from the same machine. Use `0.0.0.0` when hosting, and your actual LAN IP when joining.

## Finding games

There are two ways to find a game.

### Ask one host what games are waiting

This is usually the nicest flow when you know which machine is hosting.

Start one or more games on the host, usually on different ports:

```sh
./con4.sh create --host 0.0.0.0 --port 9411 --name "Friday game"
./con4.sh create --host 0.0.0.0 --port 9412 --name "Kitchen table"
```

From another machine, ask that host for open games:

```sh
./con4.sh lobby --host 192.168.1.50 --ports 9411-9420
```

The script checks those ports, shows the games that answer, and lets you pick one.

This is not a separate lobby server. A waiting game can answer a harmless `INFO` request, then it goes back to waiting for a real player.

### Browse LAN advertisements

You can also advertise over UDP broadcast:

```sh
./con4.sh create --host 0.0.0.0 --port 9411 --advertise --name "Friday game"
```

or, as a shortcut:

```sh
./con4.sh --advertise --host 0.0.0.0 --port 9411 --name "Friday game"
```

Then another player on the same LAN can run:

```sh
./con4.sh lobby
```

UDP broadcast is convenient, but not every network allows it. Some routers, guest Wi-Fi networks, VPNs, and firewalls block it. If the broadcast lobby finds nothing, use the host query form instead:

```sh
./con4.sh lobby --host 192.168.1.50 --ports 9411-9420
```

## Shared game code

You can protect the game protocol with a shared code:

```sh
./con4.sh create --host 0.0.0.0 --port 9411 --token "some long secret"
```

Join with the same code:

```sh
./con4.sh join --host 192.168.1.50 --port 9411 --token "some long secret"
```

This authenticates game messages with HMAC-SHA256. It helps stop someone who does not know the code from injecting moves or fake quit messages.

It does not encrypt the connection. Anyone who can watch the traffic can still see that you are playing, and may be able to infer the moves. For untrusted networks, use SSH, a VPN, Tailscale, or another real encrypted tunnel.

## Waiting and timeouts

By default, the game waits indefinitely for the opponent. That is intentional: if you get tired of waiting, press `Ctrl-C`.

You can still set limits if you want:

```sh
./con4.sh create --handshake-timeout 600
./con4.sh join --move-timeout 300
./con4.sh join --replay-timeout 300
```

`0` means no timeout.

## Board styles

The board is local to your terminal. Both players can use different styles without affecting the game.

Themes:

```sh
./con4.sh local --theme compact
./con4.sh local --theme classic
./con4.sh local --theme big
./con4.sh local --theme ascii
```

Manual style options:

```sh
./con4.sh local --cell-width 5 --cell-height 3 --border double --piece circle
```

Valid borders:

- `single`
- `double`
- `rounded`
- `heavy`
- `ascii`
- `none`

Valid pieces:

- `diamond`
- `circle`
- `letter`
- `ascii`

## Custom rules

Classic Connect Four is 6 rows, 7 columns, connect 4.

You can change that:

```sh
./con4.sh local --rows 8 --cols 9 --connect 5
```

Network game:

```sh
./con4.sh create --host 0.0.0.0 --rows 8 --cols 9 --connect 5
```

The joiner does not need to enter the rules. The creator sends them during the handshake.

## Commands during a game

During your turn:

```text
0..N      drop a piece in that column
history   show the move list
save      save a transcript
resign    resign the round
q, quit   quit and notify the other player
```

There is no undo. That is deliberate.

## Saving and replaying a game

During a game, type:

```text
save
```

This writes a small transcript file in the current directory, unless `CON4_SAVE_DIR` is set.

Replay it later:

```sh
./con4.sh replay con4-20261004-183000.txt
```

Change the replay speed:

```sh
./con4.sh replay con4-20261004-183000.txt --replay-delay 0.2
./con4.sh replay con4-20261004-183000.txt --replay-delay 1
```

The replay viewer is intentionally basic. It reads the saved move list and redraws the board step by step.

## Diagnostics

If networking is weird, run:

```sh
./con4.sh doctor
```

It prints which transport tools are installed and gives example commands for your current settings.

## Security model

This is a game script, not a hardened internet service.

It tries to be careful about the boring stuff:

- it validates protocol messages
- it does not shell-evaluate data from the other player
- it authenticates messages when `--token` is used
- it exits cleanly when the other player quits or disconnects

It does not provide:

- encryption
- accounts
- identity
- moderation
- a central lobby server
- protection against someone deliberately wasting your time

For normal play with a friend on a trusted LAN, it should be fine. For anything hostile or public, tunnel it through something designed for that job.
