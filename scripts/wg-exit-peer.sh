#!/usr/bin/env bash
# scripts/wg-exit-peer.sh — mint a guest peer for the wg1 exit VPN: keypair,
# preshared key, the client config (as a QR code), and the two values that
# have to be committed to this repo.
#
# The wg1 tunnel gives a guest the internet from this server's German IP and
# nothing else — it reaches no lab address, by firewall. See
# docs/runbooks/wireguard-exit-peer.md for the whole procedure; this script
# is only its first step, and the runbook is what says how to hand the config
# over and how to revoke it.
#
# Everything happens locally: the peer's private key is generated here and
# goes into exactly one file, outside this repo, which the operator hands to
# the guest and then deletes. The two values that are NOT secret-to-one-side
# — the peer's public key and the preshared key — are printed for pasting
# into ansible/inventory/group_vars/all.yml and the SOPS file respectively.
#
# The wg1 SERVER public key is not in this repo and cannot be: it is derived
# from a private key generated in place on the host that never leaves it
# (ansible/roles/wireguard). Pass it with --server-key or export
# WG_EXIT_SERVER_PUBKEY; the runbook's step 0 is how to read it off a
# converge.
#
# Output split: stdout is the deliverable (the QR code, or the config itself
# under --stdout or with no qrencode), stderr is everything else — the file
# path, the YAML to commit, the sops command. So `--stdout | pbcopy` yields a
# config and nothing else.
#
# Usage:
#   scripts/wg-exit-peer.sh alices-phone
#   scripts/wg-exit-peer.sh alices-phone --server-key 'Ab3...='
#   scripts/wg-exit-peer.sh alices-phone --address 10.10.30.7/32
#   scripts/wg-exit-peer.sh alices-phone --out-dir ~/handover --no-qr
#   scripts/wg-exit-peer.sh alices-phone --stdout | pbcopy
#
# Environment: WG_EXIT_SERVER_PUBKEY (the wg1 server public key), and
# XDG_STATE_HOME (default output lands in $XDG_STATE_HOME/lab/wg-exit,
# falling back to ~/.local/state).

set -euo pipefail

# The header comment IS the usage text — see promql.sh for why this walks the
# comment block instead of using a fixed line range.
usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

die() {
  printf '%s: %s\n' "${0##*/}" "$*" >&2
  exit 1
}

# Not sourcing lab-query-lib.sh for die() alone: that library is Prometheus
# and Loki plumbing, and nothing else in it applies here.
command -v wg > /dev/null 2>&1 ||
  die "wg is required (brew install wireguard-tools / apt install wireguard-tools)"

# `pwd -P`, not `pwd`. This is one half of the repo-containment check further
# down, and a comparison between a physical path and a logical one means
# nothing — see that check for the bypass it let through.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
lab_config="${repo_root}/config/lab.yml"
peers_file="${repo_root}/ansible/inventory/group_vars/all.yml"

# The resolver pushed to the guest. Not a config/lab.yml fact: that file holds
# what crosses IaC layers, and no layer on the server ever sees this value —
# `DNS =` is a client-side directive WireGuard writes into the guest's own
# resolver settings. Why a public resolver rather than a lab one, and why
# leaving it out leaks the guest's browsing to their carrier while the packets
# still exit in Germany: the wireguard_exit_peers comment in group_vars/all.yml.
guest_resolver='1.1.1.1'

# Print every `<field>: <value>` inside the top-level `<key>:` block of a YAML
# file. Deliberately not a YAML parser — this reads two files in this repo
# whose shape is fixed and reviewed, and a hard dependency on yq or python
# would be a bigger cost than the parsing is worth. It stops at the next
# top-level key and skips comments, which is what keeps it from picking up the
# example peer written out in the comment above wireguard_exit_peers.
#
# Both list-item shapes are matched, because they are the same key: the first
# field of an item carries the `- ` dash (`- name: x`) and the rest do not
# (`  address: y`). Matching only the second form is how this silently found
# no names at all.
yaml_block_field() {
  awk -v key="$1" -v field="$2" -v quotes="\"'" '
    # Quoting is insignificant to YAML and significant to the string
    # comparisons the callers below do, so it comes off here. The block this
    # script prints quotes public_key and not address; .yamllint leaves
    # quoted-strings off, so both forms lint clean and both will exist in
    # that file sooner or later. Unstripped, a quoted `address:` never
    # matched the free-address scan, the scan reported the address free, and
    # this script handed out one already in use — surfacing only on the host,
    # after merge, at the peer-uniqueness assert, which names the peer list
    # rather than the script that wrote it.
    #
    # Stripped only when both ends carry the SAME quote character, so a value
    # that merely contains one is left exactly as written.
    function unquote(value,   opening) {
      opening = substr(value, 1, 1)
      if (length(value) > 1 && index(quotes, opening) && substr(value, length(value), 1) == opening)
        value = substr(value, 2, length(value) - 2)
      return value
    }
    $0 ~ "^" key ":" { in_block = 1; next }
    in_block && /^[^[:space:]#]/ { exit }
    in_block && /^[[:space:]]*#/ { next }
    in_block && $1 == field ":" { print unquote($2) }
    in_block && $1 == "-" && $2 == field ":" { print unquote($3) }
  ' "$3"
}

# Read a scalar out of config/lab.yml by its leaf key. Every key looked up
# below is unique in that file, and each carries a trailing `# comment` that
# has to come off.
lab_value() {
  local value
  value="$(sed -n "s|^[[:space:]]*$1:[[:space:]]*\([^[:space:]#]*\).*|\1|p" "$lab_config" | head -1)"
  [[ -n $value ]] || die "could not read \`$1\` from ${lab_config}"
  printf '%s' "$value"
}

server_key="${WG_EXIT_SERVER_PUBKEY:-}"
# Which of the two sources the key came from, so the shape errors below name
# the thing the operator actually typed.
server_key_source='WG_EXIT_SERVER_PUBKEY'
peer_name='' peer_address='' out_dir='' to_stdout=0 no_qr=0 force=0

while (($#)); do
  case $1 in
    --server-key)
      server_key=${2:-}
      server_key_source='--server-key'
      [[ -n $server_key ]] || die "--server-key needs the wg1 server public key (see the runbook's step 0)"
      shift 2
      ;;
    --address)
      peer_address=${2:-}
      [[ -n $peer_address ]] || die "--address needs a value, e.g. --address 10.10.30.7/32"
      shift 2
      ;;
    --out-dir)
      out_dir=${2:-}
      [[ -n $out_dir ]] || die "--out-dir needs a directory"
      shift 2
      ;;
    --stdout)
      to_stdout=1
      shift
      ;;
    --no-qr)
      no_qr=1
      shift
      ;;
    --force)
      force=1
      shift
      ;;
    -h | --help) usage 0 ;;
    --)
      # `break` leaves anything after the name unread, so the one-name rule has
      # to be checked here too — `wg-exit-peer.sh a -- b` otherwise silently
      # took b, which is the opposite of what the message below promises.
      shift
      { [[ -z $peer_name ]] && (($# <= 1)); } || die "only one peer name may be given"
      peer_name=${1:-}
      break
      ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *)
      [[ -z $peer_name ]] || die "only one peer name may be given"
      peer_name=$1
      shift
      ;;
  esac
done

[[ -n $peer_name ]] || usage 1

# The name becomes a filename, a YAML key in wireguard_peer_psks, and the
# `name` roles/wireguard asserts uniqueness on. Restricting it here also means
# --out-dir plus a name of `../..` cannot walk back into the repo.
[[ $peer_name =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] ||
  die "peer name must start alphanumeric and contain only letters, digits, dot, dash, underscore: got '${peer_name}'"

# Trim surrounding whitespace before anything looks at the value. Step 0 of the
# runbook is a copy-paste out of an ssh session, and an operator who sources the
# variable from a file keeps its newline. `wg` itself ignores trailing
# whitespace around a key, so rejecting it here would be stricter than the thing
# that ultimately consumes the key, over a character nobody can see.
[[ $server_key =~ ^[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]] && server_key="${BASH_REMATCH[1]}"

[[ -n $server_key ]] ||
  die "the wg1 server public key is required: --server-key '<key>' or export WG_EXIT_SERVER_PUBKEY (docs/runbooks/wireguard-exit-peer.md step 0)"

# Shape-check the key rather than trusting it. Nothing local consumes this
# value — it is copied verbatim into the guest's [Peer] PublicKey — so a
# truncated or mistyped one is not caught here, or at converge, or anywhere
# else: it surfaces as "no handshake" on a phone in someone else's hands, with
# a config that looks perfectly well-formed. A non-empty check was all that
# stood here.
#
# A WireGuard public key is 32 raw bytes in base64: exactly 44 characters, 43
# of data plus the '=' that pads the final quantum. 32 is not a multiple of 3,
# so that quantum is 2 bytes — 16 bits spread over 18 slots — and its last
# character carries 4 significant bits with the low 2 forced to zero. Only 16
# of the 64 base64 characters are therefore legal in position 43;
# wireguard-tools' own decoder masks those 2 bits and fails when either is set
# (encoding.c's key_from_base64), so a key rejected below is one wireguard-tools
# rejects too — checked against `wg pubkey`, which reaches key_from_base64 by
# the same path `wg setconf` does.
#
# Deliberately NOT done by round-tripping through `wg pubkey`, even though `wg`
# is required above: `wg pubkey` reads its input as a PRIVATE key and applies
# curve25519 clamping to the first and last byte before re-encoding, so handing
# it a public key returns a DIFFERENT key — there is no round trip to check.
# Its parse step alone is exactly the predicate below, so the regex buys the
# same strictness without a subprocess.
server_key_shape="a WireGuard public key is 32 bytes of base64: exactly 44 characters, the first 43 drawn from A-Z a-z 0-9 + / and the 44th a literal '='. Read this tunnel's with: ssh <host> wg show wg1 public-key (docs/runbooks/wireguard-exit-peer.md step 0)"

if ((${#server_key} != 44)); then
  die "${server_key_source} is ${#server_key} characters, not 44 — ${server_key_shape}. Got: '${server_key}'"
elif [[ $server_key != *= ]]; then
  die "${server_key_source} does not end in '=' — ${server_key_shape}. Got: '${server_key}'"
elif [[ ! $server_key =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  die "${server_key_source} has characters outside the base64 alphabet — ${server_key_shape}. Got: '${server_key}'"
elif [[ ! $server_key =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; then
  die "${server_key_source} is 44 base64 characters but is not the encoding of any 32-byte key — its 43rd character carries only 4 significant bits, so it must be one of A E I M Q U Y c g k o s w 0 4 8, and this one is '${server_key:42:1}'. A character altered or dropped near the end of a key is what usually produces this; ${server_key_shape}"
fi

domain="$(lab_value domain)"
# The endpoint label was the literal `vpn` here and a second literal in
# infra/tofu/locals.tf, which is the layer that actually creates the record
# this line depends on. That is the coupling nat_ingress_rules' key-name
# indirection exists to prevent, and this repo has already renamed a tunnel
# endpoint once (the `vpn.lab.` duplicate, retired at the DNS cutover).
# Nothing references this script from CI or from the role asserts, so a
# second rename would have shipped guest configs pointing at NXDOMAIN with
# "no handshake" as the only symptom. Now both sides read
# config/lab.yml's `vpn_subdomain` by key.
vpn_subdomain="$(lab_value vpn_subdomain)"
exit_port="$(lab_value wireguard_exit)"
exit_subnet="$(lab_value wireguard_exit_subnet)"
exit_subnet_v6="$(lab_value wireguard_exit_subnet_v6)"
exit_host_address="$(lab_value wireguard_exit_host_address)"

# The host-number arithmetic below is /24-shaped. Asserting it rather than
# assuming it: widening the exit subnet is a plausible future edit, and this
# script would otherwise keep handing out addresses from the wrong eighth of it.
[[ ${exit_subnet##*/} == 24 ]] ||
  die "network.wireguard_exit_subnet is ${exit_subnet}; this script's address arithmetic assumes a /24"

v4_prefix="${exit_subnet%%/*}"
v4_prefix="${v4_prefix%.*}"
v6_prefix="${exit_subnet_v6%%/*}"

# Names already taken across BOTH peer lists. roles/wireguard fails the
# converge on a duplicate, and wireguard_peer_psks is one flat map with no
# notion of which tunnel a peer is on — so a name reused across the two would
# hand the management peer's preshared key to a guest.
for taken in $(yaml_block_field wireguard_peers name "$peers_file") \
  $(yaml_block_field wireguard_exit_peers name "$peers_file"); do
  [[ $taken != "$peer_name" ]] ||
    die "peer name '${peer_name}' is already used in ${peers_file}"
done

used_addresses="$(yaml_block_field wireguard_exit_peers address "$peers_file")"
# The host's own address is not in that list and is not available either.
used_addresses="${used_addresses}"$'\n'"${exit_host_address%/*}/32"

address_is_free() {
  local candidate
  for candidate in $used_addresses; do
    [[ $candidate != "$1" ]] || return 1
  done
}

if [[ -n $peer_address ]]; then
  # Checked as a whole address, not by prefix glob. The glob this replaces
  # (`== "${v4_prefix}."*"/32"`) accepted 10.10.30.7.5/32 and 10.10.30.999/32,
  # and the `${host_number##*.}` below then read `5` off the first of those —
  # emitting `address: 10.10.30.7.5/32` beside `address_v6: fd00:10:30::5/128`,
  # a pair that does not correspond, around a v4 literal that is not one.
  # roles/wireguard asserts the `/32` shape and uniqueness and nothing else,
  # so both entries pass every assert and the run dies at `wg setconf` when
  # wg-quick@wg1 restarts — mid-converge, after merge. The message below is
  # now the check.
  # The hint names the no-leading-zeros rule because the check enforces it and
  # `010` otherwise reads as an octet between 2 and 254 to the operator being
  # told its octet must be between 2 and 254.
  address_hint="--address takes one host address inside ${exit_subnet}, written <address>/32, whose last octet is between 2 and 254 in plain decimal with no leading zeros: .1 is wg1's own address (network.wireguard_exit_host_address), .0 and .255 are the network and broadcast addresses. Example: ${v4_prefix}.7/32"
  host_number="${peer_address%/32}"
  [[ $peer_address == */32 && $host_number == "${v4_prefix}."* ]] ||
    die "--address '${peer_address}' is not usable. ${address_hint}"
  host_number="${host_number#"${v4_prefix}."}"
  # Anchored, and no leading zeros — `010` is an octet some stacks read as
  # octal and this script would carry into a v6 suffix verbatim. The range
  # check is separate because the pattern alone still admits .0, .1 and .999.
  if ! [[ $host_number =~ ^[1-9][0-9]{0,2}$ ]] || ((host_number < 2 || host_number > 254)); then
    die "--address '${peer_address}' is not usable. ${address_hint}"
  fi
  address_is_free "$peer_address" ||
    die "${peer_address} is not available — it is either claimed by a peer in ${peers_file} or the wg1 host address itself (network.wireguard_exit_host_address in ${lab_config})"
else
  # .1 is the host side of wg1, .255 is broadcast. First free wins; a gap left
  # by a revoked peer is reused, which is correct — revocation is deletion
  # from wireguard_exit_peers, and the address is free the moment it lands.
  for ((host_number = 2; host_number < 255; host_number++)); do
    peer_address="${v4_prefix}.${host_number}/32"
    address_is_free "$peer_address" && break
    peer_address=''
  done
  [[ -n $peer_address ]] ||
    die "no free address left in ${exit_subnet} — every host address is claimed in ${peers_file}"
fi

# The v6 suffix reuses the v4 host number's digits so a pair is recognisable
# at a glance (10.10.30.7 ↔ fd00:10:30::7). It is read as hex, so ::10 is not
# numerically the tenth address — irrelevant, because the only property
# required of it is uniqueness, and distinct decimal strings are distinct hex
# literals. roles/wireguard asserts that uniqueness at converge time.
peer_address_v6="${v6_prefix}${host_number}/128"

umask 077
private_key="$(wg genkey)"
public_key="$(printf '%s\n' "$private_key" | wg pubkey)"
preshared_key="$(wg genpsk)"

render_config() {
  cat << EOF
# ${peer_name} — guest peer on the lab's wg1 exit VPN.
# Generated by scripts/wg-exit-peer.sh. This file holds a private key and a
# preshared key in plaintext: hand it over once, then delete it.
[Interface]
PrivateKey = ${private_key}
Address = ${peer_address}, ${peer_address_v6}
DNS = ${guest_resolver}

[Peer]
# lab — OVH / Proxmox host, wg1
PublicKey = ${server_key}
PresharedKey = ${preshared_key}
Endpoint = ${vpn_subdomain}.${domain}:${exit_port}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
}

conf=''
if ((to_stdout)); then
  render_config
else
  [[ -n $out_dir ]] || out_dir="${XDG_STATE_HOME:-$HOME/.local/state}/lab/wg-exit"
  mkdir -p "$out_dir"
  # Resolved after mkdir, and resolved PHYSICALLY. `cd` is logical by default
  # and keeps in $PWD whatever symlink it walked through, so the plain `pwd`
  # this replaces reported `~/handover` for an `--out-dir` that was a symlink
  # into the working tree: the pattern below did not match, the guard passed,
  # and the file — private key and preshared key, plaintext — landed in the
  # repo, with only .gitignore's `*.conf` between it and a commit. `pwd -P`
  # resolves every component, and repo_root at the top of this script is
  # resolved the same way, because a physical out_dir compared against a
  # logical repo root fails open in the other direction.
  #
  # That `.gitignore` line is a backstop for a copy hand-carried in here, not
  # permission to write one. (A refusal may leave an empty directory behind,
  # which git cannot track.)
  out_dir="$(cd "$out_dir" && pwd -P)"
  case "${out_dir}/" in
    "${repo_root}"/*)
      die "refusing to write a peer config inside the repo (${out_dir}) — pick an --out-dir outside it, or use --stdout"
      ;;
  esac

  conf="${out_dir}/${peer_name}.conf"
  if [[ -e $conf ]] && ((!force)); then
    die "${conf} already exists. Overwriting mints a new keypair, which revokes the old one the moment the repo catches up — if that is what you want, pass --force"
  fi
  render_config > "$conf"
  chmod 600 "$conf"

  if ((no_qr)); then
    :
  elif command -v qrencode > /dev/null 2>&1; then
    # The config is the deliverable; the QR is a convenience for getting it
    # onto a phone without a cable or a cloud round-trip. So qrencode is
    # checked for, never required — same rule as jq in lab-query-lib.sh. The
    # flags are the ones the official iOS app prints on its own scanner
    # screen, not invented here.
    qrencode -t ansiutf8 < "$conf"
  else
    cat "$conf"
    {
      printf '\n%s: qrencode not found — the config above is the whole deliverable.\n' "${0##*/}"
      printf 'For a scannable QR code: brew install qrencode, then re-run with --force,\n'
      printf 'or: qrencode -t ansiutf8 < %s\n' "$conf"
    } >&2
  fi
fi

{
  printf '\n'
  if [[ -n $conf ]]; then
    printf 'Wrote %s (mode 600). Delete it once the guest has scanned it.\n\n' "$conf"
  fi
  cat << EOF
Commit these two in one PR, then merge and converge:

  # ansible/inventory/group_vars/all.yml
  wireguard_exit_peers:
    - name: ${peer_name}
      public_key: "${public_key}"
      address: ${peer_address}
      address_v6: ${peer_address_v6}

  # sops ansible/inventory/group_vars/proxmox_host.sops.yml
  wireguard_peer_psks:
    ${peer_name}: "${preshared_key}"

Nothing works until that converge runs: the key above is what the host has
never seen. Handover, client setup and revocation:
docs/runbooks/wireguard-exit-peer.md
EOF
} >&2
