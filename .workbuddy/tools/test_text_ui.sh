#!/usr/bin/env bash
# Exercises the text interface helpers on their own. The script is cut at the
# parse_args call so that sourcing it has no side effects, in the style the rest
# of the regression suite uses.
set +e
cd "$(dirname "$0")/../.." || exit 1
LIB=.workbuddy/tmp/lib-textui.sh
cut=$(grep -n '^if ! parse_args' reality.sh | cut -d: -f1)
head -n $((cut - 1)) reality.sh > "$LIB" || exit 1
# shellcheck disable=SC1090
source "$LIB"
# Sourcing pulls in the `set -e` at the top of the script, and every helper
# here is expected to return 1 on a cancelled prompt, so it has to go again
# before the first assertion.
set +e

pass=0
fail=0
check() {
  if [[ $2 == "$3" ]]; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n       expected: %q\n       actual:   %q\n' "$1" "$3" "$2"
  fi
}

echo "--- ui_menu ---"
out=$(printf '2\n' | ui_menu "T" "P" "1" "one" "2" "two" 2>/dev/null); rc=$?
check "picks the second key" "${out}|${rc}" "2|0"

out=$(printf '10\n' | ui_menu "T" "P" \
  "1" "a" "2" "b" "3" "c" "4" "d" "5" "e" \
  "6" "f" "7" "g" "8" "h" "9" "i" "10" "j" 2>/dev/null); rc=$?
check "handles a two-digit choice" "${out}|${rc}" "10|0"

out=$(printf 'q\n' | ui_menu "T" "P" "1" "one" 2>/dev/null); rc=$?
check "q steps back" "${out}|${rc}" "|1"

out=$(printf '\n' | ui_menu "T" "P" "1" "one" 2>/dev/null); rc=$?
check "an empty line steps back" "${out}|${rc}" "|1"

out=$(ui_menu "T" "P" "1" "one" </dev/null 2>/dev/null); rc=$?
check "Ctrl-D steps back" "${out}|${rc}" "|1"

out=$(printf '9\n2\n' | ui_menu "T" "P" "1" "one" "2" "two" 2>/dev/null); rc=$?
check "repeats after an out-of-range choice" "${out}|${rc}" "2|0"

out=$(printf 'z\n1\n' | ui_menu "T" "P" "1" "one" 2>/dev/null); rc=$?
check "repeats after a non-numeric choice" "${out}|${rc}" "1|0"

# The list must never leak into the captured value, or every caller that reads
# a username would get the whole screen instead.
out=$(printf '1\n' | ui_menu "TITLE_SENTINEL" "PROMPT_SENTINEL" "1" "one" 2>/dev/null)
check "stdout carries only the answer" "${out}" "1"

err=$(printf '9\n1\n' | ui_menu "T" "P" "1" "one" 2>&1 >/dev/null)
case ${err} in
  *"Not understood"*) check "explains a rejected choice" yes yes ;;
  *) check "explains a rejected choice" no yes ;;
esac

echo "--- ui_radiolist ---"
out=$(printf '2\n' | ui_radiolist "T" "P" "b" "a" "A" "b" "B" 2>/dev/null); rc=$?
check "picks a non-numeric key" "${out}|${rc}" "b|0"

err=$(printf '1\n' | ui_radiolist "T" "P" "b" "a" "A" "b" "B" 2>&1 >/dev/null)
case ${err} in
  *"B  (current)"*) check "marks the current entry" yes yes ;;
  *) check "marks the current entry" no yes ;;
esac

err=$(printf '2\n' | ui_radiolist "T" "P" "b" "a" "A" "b" "B" 2>&1 >/dev/null)
case ${err} in
  *"A  (current)"*) check "marks only the current entry" no yes ;;
  *) check "marks only the current entry" yes yes ;;
esac

out=$(printf 'q\n' | ui_radiolist "T" "P" "b" "a" "A" "b" "B" 2>/dev/null); rc=$?
check "q steps back" "${out}|${rc}" "|1"

echo "--- ui_input ---"
out=$(printf '\n' | ui_input "T" "P" "keepme" 2>/dev/null); rc=$?
check "an empty line keeps the current value" "${out}|${rc}" "keepme|0"

out=$(printf '\n' | ui_input "T" "P" 2>/dev/null); rc=$?
check "an empty line steps back without a current value" "${out}|${rc}" "|1"

out=$(ui_input "T" "P" "keepme" </dev/null 2>/dev/null); rc=$?
check "Ctrl-D steps back" "${out}|${rc}" "|1"

out=$(printf 'newval\r\n' | ui_input "T" "P" "old" 2>/dev/null)
check "strips the CR some terminals send" "${out}" "newval"

out=$(printf '  a b  \n' | ui_input "T" "P" 2>/dev/null)
check "keeps surrounding spaces" "${out}" "  a b  "

out=$(printf '' | ui_input "T" "P" "x" 2>/dev/null); rc=$?
check "then Ctrl-D steps back" "${out}|${rc}" "|1"

echo "--- ui_yesno ---"
printf 'y\n' | ui_yesno "T" "P" >/dev/null 2>&1; check "y is yes" "$?" "0"
printf 'Y\n' | ui_yesno "T" "P" >/dev/null 2>&1; check "Y is yes" "$?" "0"
printf 'yes\n' | ui_yesno "T" "P" >/dev/null 2>&1; check "yes is yes" "$?" "0"
printf 'n\n' | ui_yesno "T" "P" >/dev/null 2>&1; check "n is no" "$?" "1"
printf 'q\n' | ui_yesno "T" "P" >/dev/null 2>&1; check "q is no" "$?" "1"
printf 'anything\n' | ui_yesno "T" "P" >/dev/null 2>&1; check "an unknown answer is no" "$?" "1"
printf '\n' | ui_yesno "T" "P" n >/dev/null 2>&1; check "Enter takes a no default" "$?" "1"
printf '\n' | ui_yesno "T" "P" y >/dev/null 2>&1; check "Enter takes a yes default" "$?" "0"
ui_yesno "T" "P" </dev/null >/dev/null 2>&1; check "Ctrl-D is no" "$?" "1"

echo "--- message_box ---"
err=$(message_box "TITLE_SENTINEL" "BODY_SENTINEL" </dev/null 2>&1)
case ${err} in
  *TITLE_SENTINEL*BODY_SENTINEL*) check "prints the title and the body" yes yes ;;
  *) check "prints the title and the body" no yes ;;
esac
out=$(message_box "T" "B" </dev/null 2>/dev/null)
check "writes nothing to stdout" "${out}" ""

echo "--- list_users_menu ---"
declare -A users=([carol]=u3 [alice]=u1 [bob]=u2)
out=$(printf '2\n' | list_users_menu "View User" 2>/dev/null); rc=$?
check "lists users in a stable, sorted order" "${out}|${rc}" "bob|0"
out=$(printf '3\n' | list_users_menu "View User" 2>/dev/null)
check "the third entry is the third name" "${out}" "carol"
out=$(printf 'q\n' | list_users_menu "View User" 2>/dev/null); rc=$?
check "q steps back" "${out}|${rc}" "|1"

echo "--- main_menu dispatch ---"
add_user_menu() { echo "ROUTE:add_user"; }
delete_user_menu() { echo "ROUTE:delete_user"; }
view_user_menu() { echo "ROUTE:view_user"; }
view_config_menu() { echo "ROUTE:view_config"; }
configuration_menu() { echo "ROUTE:configuration"; }
out=$(printf '5\nq\n' | main_menu 2>/dev/null)
check "main_menu routes a choice" "${out}" "ROUTE:configuration"
out=$(printf '1\nq\n' | main_menu 2>/dev/null)
check "main_menu routes the first entry" "${out}" "ROUTE:add_user"
out=$(printf 'q\n' | main_menu 2>/dev/null); rc=$?
check "q exits the main menu" "${out}|${rc}" "|0"
out=$(printf '9\n3\nq\n' | main_menu 2>/dev/null)
check "an invalid choice is not routed" "${out}" "ROUTE:view_user"

echo "--- configuration_menu dispatch ---"
# Every entry has to keep the number the old whiptail list used, because the
# numbers are the only thing an operator goes by now. Re-sourcing the library
# restores the real configuration_menu, which the stub above replaced.
# shellcheck disable=SC1090
source "$LIB"
set +e
config_core_menu() { echo "ROUTE:1-core"; }
config_server_menu() { echo "ROUTE:2-server"; }
config_transport_menu() { echo "ROUTE:3-transport"; }
config_sni_domain_menu() { echo "ROUTE:4-sni"; }
config_security_menu() { echo "ROUTE:5-security"; }
config_port_menu() { echo "ROUTE:6-port"; }
config_http_port_menu() { echo "ROUTE:7-http_port"; }
config_camouflage_menu() { echo "ROUTE:8-camouflage"; }
config_safenet_menu() { echo "ROUTE:9-safenet"; }
config_bbr_menu() { echo "ROUTE:10-bbr"; }
config_warp_menu() { echo "ROUTE:11-warp"; }
config_tgbot_menu() { echo "ROUTE:12-tgbot"; }
restart_menu() { echo "ROUTE:13-restart"; }
regenerate_menu() { echo "ROUTE:14-regenerate"; }
restore_defaults_menu() { echo "ROUTE:15-defaults"; }
backup_menu() { echo "ROUTE:16-backup"; }
restore_backup_menu() { echo "ROUTE:17-restore"; }

entry=0
for expected in 1-core 2-server 3-transport 4-sni 5-security 6-port 7-http_port \
  8-camouflage 9-safenet 10-bbr 11-warp 12-tgbot 13-restart 14-regenerate \
  15-defaults 16-backup 17-restore; do
  entry=$((entry + 1))
  out=$(printf '%s\nq\n' "${entry}" | configuration_menu 2>/dev/null)
  check "entry ${entry} routes to ${expected}" "${out}" "ROUTE:${expected}"
done

echo
printf 'passed: %s   failed: %s\n' "${pass}" "${fail}"
[[ ${fail} -eq 0 ]]
