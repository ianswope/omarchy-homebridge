# Shared config reading, credential handling and token refresh for the three
# Homebridge helpers (login, status, set).
#
# Sourced, not run. It is the single place that agrees on: how many bytes of
# the config file are reasonable, how to read them safely, and how a short-lived
# Homebridge session token is obtained and refreshed. The status poll and the
# set action both call hb_ensure_token so there is one login path, not two.
#
# The config file holds a url, a username, a password and a cached token. It is
# ordinary local state, but it is state anything running as this user can
# replace, and it is read on a timer (status) and immediately before changing a
# device (set). So it is read once, through one primitive, and only the bytes
# that came back are parsed — never the path again.

# Absolute paths, so a PATH another process prepended to cannot substitute the
# curl that carries the password and the bearer token. Every binary on the
# credential path is pinned, not only the one the secret is handed to: a shadow
# `jq` writes the login body, and a shadow `dd` reads the config it came from.
HB_CURL=/usr/bin/curl
HB_JQ=/usr/bin/jq
HB_DD=/usr/bin/dd
HB_STAT=/usr/bin/stat
HB_MKTEMP=/usr/bin/mktemp
HB_DATE=/usr/bin/date
HB_CAT=/usr/bin/cat

# A url, a username, a password, a JWT and an expiry. A file past this is not
# this file.
CONFIG_MAX_BYTES=65536
# One block past the ceiling, so reaching it is itself the refusal: a file is
# oversized exactly when it still had more to give.
CONFIG_READ_BLOCKS=$(( (CONFIG_MAX_BYTES + 4096) / 4096 + 1 ))

# Homebridge session tokens are short-lived. We refresh a minute early so a poll
# never races the server's own expiry.
TOKEN_SAFETY_MARGIN=60
# If the login reply omits expires_in, assume a conservative hour rather than
# trusting the token forever.
TOKEN_DEFAULT_TTL=3600
# And never hold a token longer than this even if the server claims more, so a
# stale credential cannot sit cached for a day.
TOKEN_MAX_TTL=28800

# plex.tv taught this: a value that reaches a curl --config document must not be
# able to close the quoted string or begin a new directive — curl honours an
# injected `output = /home/you/.bashrc` as readily as the lines written here.
# Only the url and the token ever reach a --config document; the username and
# password travel as a JSON body in a file, so they are exempt and may contain
# anything a password legitimately contains.
is_safe_config_value() {
  local value="$1"
  [[ -n $value ]] || return 1
  [[ $value != *'"'* ]] || return 1
  [[ $value != *'\'* ]] || return 1
  [[ $value =~ ^[[:print:]]+$ ]] || return 1
  return 0
}

is_number() {
  [[ $1 =~ ^[0-9]+$ ]]
}

is_http_url() {
  [[ $1 == http://* || $1 == https://* ]] && is_safe_config_value "$1"
}

# A Homebridge JWT is base64url segments joined by dots. Anything else must not
# reach the Authorization header.
is_jwt() {
  [[ $1 =~ ^[A-Za-z0-9_.-]+$ ]]
}

# An accessory uniqueId is spliced into a URL path, so it is checked against the
# shape config-ui-x issues (a hex-ish hash) rather than trusted. A space, a
# slash or a ? would be reaching a different endpoint entirely.
is_unique_id() {
  [[ $1 =~ ^[A-Za-z0-9]+$ ]]
}

# Read the config and print its bytes. Nothing else in these helpers opens that
# path, so every parse downstream is a parse of what this function returned.
#
#   0  bytes on stdout
#   1  nothing there
#   2  there, but not a regular file this will read
#   3  larger than the ceiling
#
# dd does what bash cannot express: iflag=nofollow opens with O_NOFOLLOW so a
# symlink is refused by the kernel at open rather than followed to whatever it
# points at (test -f follows it and answers yes); iflag=nonblock opens with
# O_NONBLOCK so a FIFO returns instead of pinning a poll; and a block count
# bounds the read so the size is a property of what was read, not of a stat a
# swap could have invalidated.
read_config_json() {
  local path="$1" bytes
  [[ -L $path ]] && return 2
  [[ -e $path ]] || return 1
  [[ -f $path ]] || return 2
  bytes=$("$HB_DD" if="$path" iflag=nofollow,nonblock bs=4096 count="$CONFIG_READ_BLOCKS" status=none 2>/dev/null) || return 2
  (( ${#bytes} > CONFIG_MAX_BYTES )) && return 3
  printf '%s' "$bytes"
  return 0
}

config_read_error() {
  case "$1" in
    2) printf '%s is not a regular file this will read' "$2" ;;
    3) printf '%s is larger than %s KB' "$2" "$(( CONFIG_MAX_BYTES / 1024 ))" ;;
    *) printf 'no config at %s' "$2" ;;
  esac
}

# Two bounds on every reply, because neither is enough alone. --max-filesize
# refuses a body whose declared Content-Length is too large before any of it
# arrives; a chunked reply declares nothing, so it can overrun that entirely and
# the only honest number is the size on disk afterwards. The body lands in a
# file rather than $( ), because a command substitution has nowhere to put a
# refusal.
#
# -q is first, so ~/.curlrc is not read. Without it a line in that file --
# writable by anything running as this user -- can add a second `url =` to the
# request, and the Authorization header (or the login body) goes there too. A
# credential on the wire is what makes -q a requirement rather than a taste.
#
# 0 with the body in $1, 3 when the far end sent more than $2 bytes, 1 for
# everything else — unreachable, timed out, refused.
fetch_bounded() {
  local dest="$1" max="$2"; shift 2
  : > "$dest" || return 1
  "$HB_CURL" -q "$@" --max-filesize "$max" --output "$dest"
  local status=$?
  # 63 is curl's own max-filesize refusal, a different fault from unreachable.
  (( status == 63 )) && return 3
  (( status == 0 )) || return 1
  local size
  size=$("$HB_STAT" -c %s -- "$dest" 2>/dev/null || echo 0)
  (( size > max )) && return 3
  return 0
}

# ---------------------------------------------------------------- login

# Exchange a username and password for a session token. Prints the raw login
# JSON ({access_token, token_type, expires_in}) on success, nothing on failure,
# and returns non-zero with a human reason on stderr.
#
# The credentials go in a JSON body written by jq to a 0600 temp file and handed
# to curl as `data = @file`, never on the command line: curl's argv is visible
# in /proc to every user on this machine, and this is a login. The url and
# content-type reach curl through the same --config document; the password never
# appears in it.
#
# $1 login-max-bytes  $2 url  $3 username  $4 password  $5 deadline
hb_login() {
  local max="$1" url="$2" user="$3" pass="$4" deadline="${5:-10}"
  is_http_url "$url" || { printf 'url is not a usable http(s) address\n' >&2; return 1; }
  [[ -n $user && -n $pass ]] || { printf 'username and password are both required\n' >&2; return 1; }
  url="${url%/}"

  local body reply
  body=$("$HB_MKTEMP" -t omarchy-homebridge-login.XXXXXX) || { printf 'cannot create a temporary file\n' >&2; return 1; }
  reply=$("$HB_MKTEMP" -t omarchy-homebridge-reply.XXXXXX) || { rm -f -- "$body"; printf 'cannot create a temporary file\n' >&2; return 1; }
  # Note the subshell-free cleanup: this function is sourced into helpers that
  # set their own EXIT traps, so it removes its own temporaries by hand.
  chmod 600 -- "$body" "$reply" 2>/dev/null

  # jq builds the body, so a password with quotes, backslashes or braces is
  # escaped into valid JSON rather than breaking it.
  if ! "$HB_JQ" -n --arg u "$user" --arg p "$pass" '{username:$u, password:$p}' > "$body"; then
    rm -f -- "$body" "$reply"; printf 'could not encode the login request\n' >&2; return 1
  fi

  # url, content-type and the body file all reach curl via stdin config; the
  # password is only ever inside the file named by `data`. Success is decided by
  # whether the reply carries an access_token, so no http_code is captured — and
  # nothing is redirected to a predictable $$-named path.
  printf 'url = "%s/api/auth/login"\nrequest = "POST"\nheader = "Content-Type: application/json"\ndata = "@%s"\nmax-time = "%s"\nsilent\nshow-error\n' \
    "$url" "$body" "$deadline" | fetch_bounded "$reply" "$max" --config - >/dev/null 2>&1
  local fetch_rc=$?
  rm -f -- "$body"

  if (( fetch_rc == 3 )); then rm -f -- "$reply"; printf 'the login reply was too large to be a token\n' >&2; return 1; fi
  if (( fetch_rc != 0 )); then rm -f -- "$reply"; printf 'could not reach %s\n' "$url" >&2; return 1; fi

  # fetch_bounded overwrote the body with the response; the trailing http_code
  # came back on the (now consumed) pipe. Re-check the status by parsing.
  local token
  token=$("$HB_JQ" -r '.access_token // empty' -- "$reply" 2>/dev/null)
  if [[ -z $token ]]; then
    rm -f -- "$reply"
    printf 'Homebridge rejected the credentials\n' >&2
    return 1
  fi
  "$HB_CAT" -- "$reply"
  rm -f -- "$reply"
  return 0
}

# Merge a fresh token and its computed expiry into the config, atomically. The
# name comes from mktemp (O_EXCL, 0600), not from $$: a $$-derived name is one
# anything running as this user can pre-create as a symlink, and a redirect
# follows it without complaint.
#
# $1 config-path  $2 config-json (current bytes)  $3 token  $4 expires-epoch
hb_persist_token() {
  local path="$1" current="$2" token="$3" expires="$4" tmp
  tmp=$("$HB_MKTEMP" -- "$(dirname -- "$path")/.write.XXXXXX") || return 1
  chmod 600 -- "$tmp" 2>/dev/null
  if [[ -n $current ]] && "$HB_JQ" -e . <<<"$current" >/dev/null 2>&1; then
    "$HB_JQ" --arg t "$token" --argjson e "$expires" '. + {token:$t, token_expires:$e}' <<<"$current" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  else
    rm -f -- "$tmp"; return 1
  fi
  mv -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# Ensure a usable token for the server in $CONFIG_JSON, refreshing through a
# login when the cached one is missing or within its safety margin of expiry.
# Prints the token on stdout. On refresh it persists the new token to the config
# so the next poll reuses it rather than logging in again.
#
# $1 login-max-bytes  $2 config-path  $3 config-json  $4 deadline
# Sets HB_TOKEN on success; returns non-zero with a reason on stderr.
hb_ensure_token() {
  local max="$1" path="$2" json="$3" deadline="${4:-10}"
  local url user pass token expires now
  url=$("$HB_JQ" -r '.url // ""' <<<"$json")
  user=$("$HB_JQ" -r '.username // ""' <<<"$json")
  pass=$("$HB_JQ" -r '.password // ""' <<<"$json")
  token=$("$HB_JQ" -r '.token // ""' <<<"$json")
  expires=$("$HB_JQ" -r '.token_expires // 0' <<<"$json")
  is_number "$expires" || expires=0
  now=$("$HB_DATE" +%s)

  if [[ -n $token ]] && is_jwt "$token" && (( expires > now + TOKEN_SAFETY_MARGIN )); then
    HB_TOKEN="$token"; return 0
  fi

  local login_json new_token ttl new_expires
  login_json=$(hb_login "$max" "$url" "$user" "$pass" "$deadline") || return 1
  new_token=$("$HB_JQ" -r '.access_token // empty' <<<"$login_json" 2>/dev/null)
  ttl=$("$HB_JQ" -r '.expires_in // empty' <<<"$login_json" 2>/dev/null)
  is_jwt "$new_token" || { printf 'the token Homebridge returned has unexpected characters\n' >&2; return 1; }
  is_number "$ttl" || ttl=$TOKEN_DEFAULT_TTL
  (( ttl > TOKEN_MAX_TTL )) && ttl=$TOKEN_MAX_TTL
  (( ttl < 60 )) && ttl=60
  new_expires=$(( now + ttl - TOKEN_SAFETY_MARGIN ))

  # A failed persist is not fatal: the token is still good for this call, we
  # just log in again next time rather than caching it.
  hb_persist_token "$path" "$json" "$new_token" "$new_expires" 2>/dev/null || true
  HB_TOKEN="$new_token"
  return 0
}
