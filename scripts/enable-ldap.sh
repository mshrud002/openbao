#!/usr/bin/env bash
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-}"
LDAP_URL="${LDAP_URL:-}"
BIND_DN="${BIND_DN:-}"
BIND_PASSWORD="${BIND_PASSWORD:-}"
USER_DN="${USER_DN:-}"
GROUP_DN="${GROUP_DN:-}"
USER_ATTR="${USER_ATTR:-cn}"
GROUP_ATTR="${GROUP_ATTR:-cn}"
GROUP_FILTER="${GROUP_FILTER:-(|(memberUid={{.Username}})(member={{.UserDN}})(uniqueMember={{.UserDN}}))}"

if [[ -z "$BAO_ADDR" || -z "$LDAP_URL" ]]; then echo "BAO_ADDR and LDAP_URL required"; exit 1; fi
export BAO_ADDR

bao auth list 2>/dev/null | grep -q "^ldap/" || bao auth enable ldap

bao write auth/ldap/config \
  url="${LDAP_URL}" \
  binddn="${BIND_DN}" \
  bindpass="${BIND_PASSWORD}" \
  userdn="${USER_DN}" \
  groupdn="${GROUP_DN}" \
  userattr="${USER_ATTR}" \
  groupattr="${GROUP_ATTR}" \
  groupfilter="${GROUP_FILTER}"

echo "LDAP auth configured"
