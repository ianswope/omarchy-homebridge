#!/bin/bash

# End-to-end exercise of the three bash helpers against a stand-in Homebridge:
#
#   bash test/helpers-test.sh
#
# Model.js can be tested on plain data, but the helpers cannot: what they get
# wrong is what happens between a config file, curl and a server — a token
# cached when it should have been refreshed, a value refused too late, a symlink
# followed. So this starts test/fake-homebridge.py on a loopback port, signs in
# against it for real, and then asserts on both what the helpers printed and
# what the server saw.
#
# Nothing here touches ~/.config/omarchy-homebridge: every config lives in a
# mktemp'd directory that goes away with the run.

set -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(dirname -- "$HERE")"
BIN="$PLUGIN/bin"

export FAKE_HB_USER="omarchy-bar"
export FAKE_HB_PASS="correct horse battery staple"

failures=0
ok()      { printf 'ok - %s\n' "$1"; }
not_ok()  { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
assert()  { if [[ $1 == 0 ]]; then ok "$2"; else not_ok "$2"; fi; }

assert_eq() {
  local actual="$1" expected="$2" name="$3"
  if [[ $actual == "$expected" ]]; then ok "$name"
  else not_ok "$name (got '$actual', wanted '$expected')"; fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ $haystack == *"$needle"* ]]; then ok "$name"
  else not_ok "$name (got '$haystack')"; fi
}

WORK="$(mktemp -d -t omarchy-homebridge-test.XXXXXX)" || exit 1
CONFIG="$WORK/config.json"

cleanup() {
  [[ -n ${SERVER_PID:-} ]] && kill "$SERVER_PID" 2>/dev/null
  rm -rf -- "$WORK"
}
trap cleanup EXIT

for tool in python3 jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'need %s to run this\n' "$tool" >&2; exit 1; }
done

# The server binds before it prints, so a port on stdout means it is listening —
# no polling, and no sleep that is either flaky or slow.
coproc SERVER { exec python3 "$HERE/fake-homebridge.py" 0; }
read -r PORT <&"${SERVER[0]}"
[[ $PORT =~ ^[0-9]+$ ]] || { printf 'the fake server did not report a port\n' >&2; exit 1; }
URL="http://127.0.0.1:$PORT"

status_helper() { bash "$BIN/omarchy-homebridge-status" "$@"; }
set_helper()    { bash "$BIN/omarchy-homebridge-set" "$@"; }
logins()        { curl -s "$URL/_control/stats" | jq -r '.logins'; }
puts()          { curl -s "$URL/_control/stats" | jq -r '.puts'; }

printf '# fake Homebridge on %s\n\n' "$URL"

# ---------------------------------------------------------------- no config yet

out=$(status_helper "$CONFIG")
assert_eq "$(jq -r '.ok' <<<"$out")" "true" 'a fresh install is not an error'
assert_eq "$(jq -r '.configured' <<<"$out")" "false" 'it just reports that nothing is signed in'
assert_eq "$(jq -r '.accessories | length' <<<"$out")" "0" 'with no accessories'
assert_eq "$(jq -r '.configPath' <<<"$out")" "$CONFIG" 'and names the file it looked for'

# ---------------------------------------------------------------- signing in

# The login helper insists on a terminal, so it gets one. Without the pty it
# refuses by design and this whole path would go untested.
if command -v script >/dev/null 2>&1; then
  login_out=$(printf '%s\n%s\n%s\n' "$URL" "$FAKE_HB_USER" "$FAKE_HB_PASS" \
    | script -qec "bash '$BIN/omarchy-homebridge-login' '$CONFIG'" /dev/null 2>&1)
  assert_contains "$login_out" "Signed in to $URL" 'the sign-in verifies against the server before writing'
  assert_contains "$login_out" "It can control 4 accessories" 'and reports what the account can actually control'

  assert_eq "$(stat -c %a -- "$CONFIG" 2>/dev/null)" "600" 'the config it wrote is readable only by its owner'
  assert_eq "$(jq -r '.url' <<<"$(cat "$CONFIG")")" "$URL" 'the url is stored'
  assert_eq "$(jq -r '.username' <<<"$(cat "$CONFIG")")" "$FAKE_HB_USER" 'the username is stored'
  assert_eq "$(jq -r '.password' <<<"$(cat "$CONFIG")")" "$FAKE_HB_PASS" 'the password is stored verbatim, spaces and all'
  assert_eq "$(jq -r 'has("token")' <<<"$(cat "$CONFIG")")" "false" 'and no token is carried over from whatever was there before'

  bad_out=$(printf '%s\n%s\n%s\n' "$URL" "$FAKE_HB_USER" "wrong password" \
    | script -qec "bash '$BIN/omarchy-homebridge-login' '$WORK/never.json'" /dev/null 2>&1)
  assert_contains "$bad_out" "Sign-in failed" 'a rejected credential fails loudly'
  assert  "$([[ -e $WORK/never.json ]] && echo 1 || echo 0)" 'and writes no config at all'
else
  printf '# skipped the sign-in tests: no `script` to give it a pty\n'
  jq -n --arg u "$URL" --arg n "$FAKE_HB_USER" --arg p "$FAKE_HB_PASS" \
    '{url:$u, username:$n, password:$p}' > "$CONFIG"
  chmod 600 "$CONFIG"
fi

# ---------------------------------------------------------------- reading state

logins_before=$(logins)
out=$(status_helper "$CONFIG")
assert_eq "$(jq -r '.ok' <<<"$out")" "true" 'a poll against a real server succeeds'
assert_eq "$(jq -r '.configured' <<<"$out")" "true" 'and knows it is signed in'
assert_eq "$(jq -r '.serverUrl' <<<"$out")" "$URL" 'and says which server it read'

# Fifteen accessories are bridged; eleven of them are worth a row. The four that
# are not are the ones a real bridge is full of: camera stream management, a
# microphone, a stateless doorbell, and a switch whose On cannot be written.
assert_eq "$(jq -r '.accessories | length' <<<"$out")" "11" 'only the accessories worth a row are reported'
assert_eq "$(jq -r '[.accessories[] | keys] | unique | length' <<<"$out")" "1" 'every row carries the same fields'
assert_eq "$(jq -r '.accessories[0] | keys | join(",")' <<<"$out")" \
  "brightness,dimmable,fault,kind,lowBattery,name,on,securityCurrent,securityModes,securityTarget,sensor,sensorValue,tampered,type,uniqueId" \
  'and they are the panel shape, not the raw config-ui-x one'

assert_eq "$(jq -r 'any(.accessories[]; .type == "Camera Rtp Stream Management")' <<<"$out")" "false" 'camera stream management is left out'
assert_eq "$(jq -r 'any(.accessories[]; .type == "Microphone")' <<<"$out")" "false" 'so is a camera microphone'
assert_eq "$(jq -r 'any(.accessories[]; .type == "Doorbell")' <<<"$out")" "false" 'and a doorbell, which fires events rather than holding a reading'
assert_eq "$(jq -r 'any(.accessories[]; .name == "Doorbell")' <<<"$out")" "false" 'an On that cannot be written is not a switch'

# ---------------------------------------------------------------- the switches

assert_eq "$(jq -r '[.accessories[] | select(.kind == "switch")] | length' <<<"$out")" "4" 'four things can be switched'
assert_eq "$(jq -r '.accessories[] | select(.name == "Desk Lamp") | .dimmable' <<<"$out")" "true" 'a writable Brightness makes a light dimmable'
assert_eq "$(jq -r '.accessories[] | select(.name == "Desk Lamp") | .brightness' <<<"$out")" "40" 'and its brightness comes through'
assert_eq "$(jq -r '.accessories[] | select(.name == "Porch Light") | .dimmable' <<<"$out")" "false" 'a Brightness that cannot be written does not'
assert_eq "$(jq -r '.accessories[] | select(.name == "Kettle") | .dimmable' <<<"$out")" "false" 'nor does having no Brightness at all'

# A fan whose plugin reports On as 1 rather than true is on. This is the reading
# that would otherwise show a running fan as stopped.
assert_eq "$(jq -r '.accessories[] | select(.name == "Ceiling Fan") | .on' <<<"$out")" "true" 'an On reported as 1 is read as on'

# ---------------------------------------------------------------- the sensors

assert_eq "$(jq -r '[.accessories[] | select(.kind == "sensor")] | length' <<<"$out")" "6" 'six things are worth reading'
assert_eq "$(jq -r '.accessories[] | select(.name == "Front Door") | .sensor' <<<"$out")" "ContactSensorState" 'a contact sensor is classified by its reading'
assert_eq "$(jq -r '.accessories[] | select(.name == "Front Door") | .sensorValue' <<<"$out")" "0" 'and its value is passed through untranslated'
assert_eq "$(jq -r '.accessories[] | select(.name == "Front Door") | .lowBattery' <<<"$out")" "true" 'a flat battery is carried alongside the reading'
assert_eq "$(jq -r '.accessories[] | select(.name == "Garage") | .lowBattery' <<<"$out")" "false" 'and a healthy one is not'
assert_eq "$(jq -r '.accessories[] | select(.name == "Hallway" and .kind == "sensor") | .sensor' <<<"$out")" "MotionDetected" 'a motion sensor is too'

# A smoke sensor that also reports temperature is a smoke sensor. The allow-list
# is in priority order for exactly this.
assert_eq "$(jq -r '.accessories[] | select(.name == "Kitchen") | .sensor' <<<"$out")" "SmokeDetected" 'a sensor with two readings is named by the more important one'
assert_eq "$(jq -r '.accessories[] | select(.name == "Nursery") | .sensor' <<<"$out")" "CurrentTemperature" 'a thermometer with only one reading keeps it'

# ------------------------------------------------------------- the alarm

assert_eq "$(jq -r '[.accessories[] | select(.kind == "security")] | length' <<<"$out")" "1" 'the security system is its own kind'
assert_eq "$(jq -r '.accessories[] | select(.kind == "security") | .securityCurrent' <<<"$out")" "3" 'its current state is read'
assert_eq "$(jq -r '.accessories[] | select(.kind == "security") | .securityModes | join(",")' <<<"$out")" "0,1,3" \
  'and it is the modes the system declares that are carried, not a hardcoded four'

assert_eq "$(jq -r '.totals.count' <<<"$out")" "11" 'the totals count what was reported'
assert_eq "$(jq -r '.totals.on' <<<"$out")" "2" 'how many switches are on'
assert_eq "$(jq -r '.totals.open' <<<"$out")" "1" 'how many doors are open'
assert_eq "$(jq -r '.totals.lowBattery' <<<"$out")" "1" 'and how many sensors want a battery'

# ---------------------------------------------------------------- token reuse

logins_after_first=$(logins)
assert_eq "$(jq -r 'has("token")' <<<"$(cat "$CONFIG")")" "true" 'a refreshed token is cached back into the config'
assert_eq "$(stat -c %a -- "$CONFIG")" "600" 'and the rewritten config is still 0600'
status_helper "$CONFIG" >/dev/null
assert_eq "$(logins)" "$logins_after_first" 'the next poll reuses the cached token rather than signing in again'
assert "$([[ $logins_after_first -gt $logins_before ]] && echo 0 || echo 1)" 'a poll with no cached token does sign in'

# ---------------------------------------------------------------- changing things

res=$(set_helper "$CONFIG" "ff00ff00ff" On true)
assert_eq "$(jq -r '.ok' <<<"$res")" "true" 'turning an outlet on is accepted'
out=$(status_helper "$CONFIG")
assert_eq "$(jq -r '.accessories[] | select(.name == "Kettle") | .on' <<<"$out")" "true" 'and the next poll sees it on'
assert_eq "$(jq -r '.totals.on' <<<"$out")" "3" 'so the bar count goes up by one'

res=$(set_helper "$CONFIG" "ff00ff00ff" On false)
assert_eq "$(jq -r '.ok' <<<"$res")" "true" 'and turning it back off is too'
assert_eq "$(jq -r '.accessories[] | select(.name == "Kettle") | .on' <<<"$(status_helper "$CONFIG")")" "false" 'which the poll also sees'

res=$(set_helper "$CONFIG" "a1b2c3d4e5" Brightness 55)
assert_eq "$(jq -r '.ok' <<<"$res")" "true" 'a brightness is accepted'
assert_eq "$(jq -r '.accessories[] | select(.name == "Desk Lamp") | .brightness' <<<"$(status_helper "$CONFIG")")" "55" 'and lands on the light'
assert_eq "$(jq -r '.ok' <<<"$(set_helper "$CONFIG" "a1b2c3d4e5" Brightness 0)")" "true" 'zero is a brightness, not a missing argument'
assert_eq "$(jq -r '.ok' <<<"$(set_helper "$CONFIG" "a1b2c3d4e5" Brightness 100)")" "true" 'and so is the top of the range'

# ------------------------------------------------------------ arming the house

# The one action in this plugin that is not a light. What is checked here is
# that the panel's view of a house mid-arming is the server's view of it, not an
# optimistic guess: target moves at once, current follows when the house is
# actually secured, and the two disagree for the whole of the gap between.
sec_state() {
  status_helper "$CONFIG" | jq -r ".accessories[] | select(.kind == \"security\") | .$1"
}

assert_eq "$(sec_state securityCurrent)" "3" 'the house starts disarmed'
res=$(set_helper "$CONFIG" "5ecur17y01" SecuritySystemTargetState 1)
assert_eq "$(jq -r '.ok' <<<"$res")" "true" 'asking for away is accepted'
assert_eq "$(sec_state securityTarget)" "1" 'the target moves at once'
assert_eq "$(sec_state securityCurrent)" "3" 'and the current state does not, because the house is not secured yet'

curl -s -X POST "$URL/_control/settle" >/dev/null
assert_eq "$(sec_state securityCurrent)" "1" 'once it is, the current state catches up'
assert_eq "$(sec_state securityTarget)" "1" 'and the two agree again'

assert_eq "$(jq -r '.ok' <<<"$(set_helper "$CONFIG" "5ecur17y01" SecuritySystemTargetState 3)")" "true" 'disarming is accepted'
curl -s -X POST "$URL/_control/settle" >/dev/null
assert_eq "$(sec_state securityCurrent)" "3" 'and lands'

# A system that declares [0,1,3] has no Night. The panel never offers one, and
# if something else asked for it the server is the backstop.
res=$(set_helper "$CONFIG" "5ecur17y01" SecuritySystemTargetState 2)
assert_eq "$(jq -r '.ok' <<<"$res")" "false" 'a mode the system does not have is refused by the server'
assert_contains "$(jq -r '.error' <<<"$res")" "400" 'and reported as the refusal it is'
assert_eq "$(sec_state securityCurrent)" "3" 'with the house left exactly where it was'

# ---------------------------------------------------------------- what it refuses

puts_before_refusals=$(puts)

res=$(set_helper "$CONFIG" "a1b2c3d4e5" Brightness 101)
assert_contains "$(jq -r '.error' <<<"$res")" "cannot exceed 100" 'a brightness past the range is refused'
res=$(set_helper "$CONFIG" "a1b2c3d4e5" Brightness "-1")
assert_contains "$(jq -r '.error' <<<"$res")" "whole number" 'a negative brightness is refused'
res=$(set_helper "$CONFIG" "a1b2c3d4e5" Brightness "50; id")
assert_contains "$(jq -r '.error' <<<"$res")" "whole number" 'a brightness carrying a command is refused'
res=$(set_helper "$CONFIG" "a1b2c3d4e5" On "yes")
assert_contains "$(jq -r '.error' <<<"$res")" "true or false" 'an On that is not a boolean is refused'
res=$(set_helper "$CONFIG" "a1b2c3d4e5" Name "Kitchen")
assert_contains "$(jq -r '.error' <<<"$res")" "only sets On, Brightness or SecuritySystemTargetState" 'a characteristic outside the allow-list is refused'

# 4 is SECURITY_SYSTEM_ALARM_TRIGGERED — a state a system reports, never a mode
# to ask it for. It is refused here rather than sent to find out.
res=$(set_helper "$CONFIG" "5ecur17y01" SecuritySystemTargetState 4)
assert_contains "$(jq -r '.error' <<<"$res")" "0 (home)" 'a security value outside the four HomeKit modes is refused before it leaves'
res=$(set_helper "$CONFIG" "5ecur17y01" SecuritySystemTargetState "1; reboot")
assert_contains "$(jq -r '.error' <<<"$res")" "0 (home)" 'and so is one carrying a command'
res=$(set_helper "$CONFIG" "5ecur17y01" SecuritySystemTargetState "")
assert_contains "$(jq -r '.error' <<<"$res")" "0 (home)" 'an empty mode is not a disarm'
res=$(set_helper "$CONFIG" "../../etc/passwd" On true)
assert_contains "$(jq -r '.error' <<<"$res")" "unexpected characters" 'an id that would climb out of the endpoint is refused'
res=$(set_helper "$CONFIG" "a1b2c3d4e5?x=1" On true)
assert_contains "$(jq -r '.error' <<<"$res")" "unexpected characters" 'an id that would start a query is refused'

assert_eq "$(puts)" "$puts_before_refusals" 'and none of those refusals reached the server'

# What the server itself refuses still comes back as a sentence, not a crash.
res=$(set_helper "$CONFIG" "p0rch11ght" Brightness 50)
assert_contains "$(jq -r '.error' <<<"$res")" "400" 'a characteristic the server will not write is reported'
res=$(set_helper "$CONFIG" "deadbeef99" On true)
assert_contains "$(jq -r '.error' <<<"$res")" "404" 'an accessory the server no longer knows is reported'

# ---------------------------------------------------------------- a stale token

# config-ui-x restarting rotates its secret, so a token that is nowhere near its
# own expiry stops working. One forced re-login and retry, rather than a panel
# that goes red until the cache times out.
curl -s -X POST "$URL/_control/expire" >/dev/null
logins_before_401=$(logins)
out=$(status_helper "$CONFIG")
assert_eq "$(jq -r '.ok' <<<"$out")" "true" 'a token rejected before its expiry does not fail the poll'
assert_eq "$(jq -r '.accessories | length' <<<"$out")" "11" 'the accessories come back on the retry'
assert "$([[ $(logins) -gt $logins_before_401 ]] && echo 0 || echo 1)" 'because it signed in again to get them'

curl -s -X POST "$URL/_control/expire" >/dev/null
assert_eq "$(jq -r '.ok' <<<"$(set_helper "$CONFIG" "ff00ff00ff" On true)")" "true" 'and a write retries the same way'
set_helper "$CONFIG" "ff00ff00ff" On false >/dev/null

# ---------------------------------------------------------------- bad config

rel_out=$(cd "$WORK" && bash "$BIN/omarchy-homebridge-status" "config.json")
assert_contains "$(jq -r '.error' <<<"$rel_out")" "must be absolute" 'a relative config path is refused rather than resolved'

ln -s "$CONFIG" "$WORK/link.json"
link_out=$(status_helper "$WORK/link.json")
assert_contains "$(jq -r '.error' <<<"$link_out")" "not a regular file" 'a symlinked config is refused, not followed'
assert_eq "$(jq -r '.ok' <<<"$link_out")" "false" 'and that is a fault, not an empty read'

printf '{"url":"%s","username":"x","password":"y","pad":"' "$URL" > "$WORK/big.json"
head -c 70000 /dev/zero | tr '\0' 'x' >> "$WORK/big.json"
printf '"}\n' >> "$WORK/big.json"
big_out=$(status_helper "$WORK/big.json")
assert_contains "$(jq -r '.error' <<<"$big_out")" "larger than" 'a config too large to be one is refused by size'

printf 'this is not json\n' > "$WORK/broken.json"
assert_contains "$(jq -r '.error' <<<"$(status_helper "$WORK/broken.json")")" "not valid JSON" 'a config that is not JSON says so'

jq -n '{url:"ftp://homebridge.local", username:"x", password:"y"}' > "$WORK/ftp.json"
assert_contains "$(jq -r '.error' <<<"$(status_helper "$WORK/ftp.json")")" "http://" 'a url that is not http(s) is refused'

jq -n '{username:"x", password:"y"}' > "$WORK/nourl.json"
assert_contains "$(jq -r '.error' <<<"$(status_helper "$WORK/nourl.json")")" "no \"url\"" 'a config with no url says which file is missing it'

# ---------------------------------------------------------------- server gone

jq -n --arg p "$FAKE_HB_PASS" '{url:"http://127.0.0.1:1", username:"omarchy-bar", password:$p}' > "$WORK/dead.json"
dead_out=$(status_helper "$WORK/dead.json")
assert_eq "$(jq -r '.ok' <<<"$dead_out")" "false" 'an unreachable server is a fault'
assert_eq "$(jq -r '.configured' <<<"$dead_out")" "true" 'but not an unconfigured one'
assert_contains "$(jq -r '.error' <<<"$dead_out")" "127.0.0.1:1" 'and the message names the address that did not answer'
assert_contains "$(jq -r '.error' <<<"$(set_helper "$WORK/dead.json" "ff00ff00ff" On true)")" "127.0.0.1:1" 'a write to an unreachable server fails the same way'

# ------------------------------------------------------- a hostile PATH

# The credential path is pinned to /usr/bin, so a curl or jq planted earlier in
# PATH by anything running as this user never sees the password or the bearer
# token. This plants both and proves the poll still works and the shims were
# never reached -- a PATH-resolved curl would have received the Authorization
# header, which is why this is a test and not a comment.
SHIM="$WORK/shim"
mkdir -p "$SHIM"
for exe in curl jq dd stat mktemp date cat; do
  printf '#!/bin/bash\ntouch -- "%s/.called-%s"\nexit 0\n' "$SHIM" "$exe" > "$SHIM/$exe"
  chmod +x "$SHIM/$exe"
done

shim_out=$(PATH="$SHIM:$PATH" bash "$BIN/omarchy-homebridge-status" "$CONFIG")
assert_eq "$(jq -r '.ok' <<<"$shim_out")" "true" 'a poll survives a hostile PATH'
assert_eq "$(jq -r '.accessories | length' <<<"$shim_out")" "11" 'and returns the real accessories'
assert "$([[ -n $(ls -A "$SHIM"/.called-* 2>/dev/null) ]] && echo 1 || echo 0)" \
  'and no planted binary on the credential path was ever run'

printf '\n'
if (( failures == 0 )); then
  printf 'all passed\n'
else
  printf '%d failed\n' "$failures"
fi
exit $(( failures == 0 ? 0 : 1 ))
