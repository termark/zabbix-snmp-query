#!/bin/sh
#
# inspect_interface.sh - dump a host's SNMP interface configuration from the
# Zabbix API, so you can see the raw enum values the poller is using.
#
# Usage:
#   ZBXAPI=https://zabbix.example.net/api_jsonrpc.php \
#   ZBX_TOKEN=xxxx ./inspect_interface.sh sw-example-01      # exact match
#   ZBX_TOKEN=xxxx ./inspect_interface.sh -s example         # substring search
#
# Exact lookup uses filter.host, which is case-sensitive and matches the
# TECHNICAL host name only. If it returns an empty result, use -s.
#
# Passphrases are printed. Run it where that is acceptable, and remember the
# API only returns them to users with write access to the host.
#
# SPDX-License-Identifier: MIT
#
set -u

ZBXAPI="${ZBXAPI:-https://localhost/api_jsonrpc.php}"
TOKEN="${ZBX_TOKEN:-}"

if [ -z "$TOKEN" ]; then
    echo "Set ZBX_TOKEN (a Super admin token; interface passphrases are not"
    echo "returned to users without write access to the host)." >&2
    exit 1
fi

MODE=exact
if [ "${1:-}" = "-s" ]; then
    MODE=search
    shift
fi
if [ $# -lt 1 ]; then
    echo "Usage: $0 [-s] <hostname|substring>" >&2
    exit 1
fi
NEEDLE="$1"

export ZBXAPI TOKEN MODE NEEDLE

python3 - <<'PY'
import json, os, ssl, sys, urllib.request

API, TOKEN = os.environ["ZBXAPI"], os.environ["TOKEN"]
MODE, NEEDLE = os.environ["MODE"], os.environ["NEEDLE"]
sslctx = ssl._create_unverified_context()

def call(method, params):
    body = json.dumps({"jsonrpc": "2.0", "method": method,
                       "params": params, "id": 1}).encode()
    req = urllib.request.Request(API, data=body, headers={
        "Content-Type":  "application/json-rpc",
        "Authorization": "Bearer " + TOKEN})
    resp = json.load(urllib.request.urlopen(req, context=sslctx, timeout=15))
    if "error" in resp:
        sys.exit("API error on %s: %s" % (method, resp["error"]))
    return resp["result"]

params = {
    "output": ["hostid", "host", "name", "status"],
    "selectInterfaces": ["type", "main", "useip", "ip", "dns",
                         "port", "details"],
}
if MODE == "search":
    params["search"] = {"host": NEEDLE, "name": NEEDLE}
    params["searchByAny"] = True
else:
    params["filter"] = {"host": [NEEDLE]}

hosts = call("host.get", params)
if not hosts:
    sys.exit("No host matched %r. filter.host is exact and case-sensitive and "
             "matches the technical name only - try -s for a substring search, "
             "or check the token's host-group permissions." % NEEDLE)

AUTH  = {"0": "MD5", "1": "SHA1", "2": "SHA224",
         "3": "SHA256", "4": "SHA384", "5": "SHA512"}
PRIV  = {"0": "DES", "1": "AES128", "2": "AES192",
         "3": "AES256", "4": "AES192C", "5": "AES256C"}
LEVEL = {"0": "noAuthNoPriv", "1": "authNoPriv", "2": "authPriv"}
VER   = {"1": "SNMPv1", "2": "SNMPv2c", "3": "SNMPv3"}

for h in hosts:
    print("=" * 70)
    print("%s  (visible name: %s, hostid %s, %s)"
          % (h["host"], h["name"], h["hostid"],
             "enabled" if str(h.get("status")) == "0" else "disabled"))
    snmp = [i for i in h["interfaces"] if str(i.get("type")) == "2"]
    if not snmp:
        print("  no SNMP interface")
        continue
    for i in snmp:
        d = i.get("details") or {}
        g = lambda k, dv="": str(d.get(k, dv))
        addr = i["ip"] if str(i.get("useip")) == "1" else i.get("dns", "")
        print("  %s:%s%s"
              % (addr, i.get("port", "161"),
                 "  [default]" if str(i.get("main")) == "1" else ""))
        v = g("version", "2")
        print("    version        %s  -> %s" % (v, VER.get(v, "?")))
        if v == "3":
            for key, table in (("securitylevel", LEVEL),
                               ("authprotocol",  AUTH),
                               ("privprotocol",  PRIV)):
                raw = g(key, "0")
                print("    %-14s %s  -> %s"
                      % (key, raw, table.get(raw, "UNKNOWN")))
            for key in ("securityname", "authpassphrase",
                        "privpassphrase", "contextname"):
                val = d.get(key, "")
                note = ""
                if val.startswith("{$"):
                    note = "   (macro - resolved at query time)"
                elif not val:
                    note = "   (EMPTY - secret/Vault macro, or no permission)"
                print("    %-14s %s%s" % (key, val or "-", note))
        else:
            c = d.get("community", "")
            print("    community      %s" % (c or "-"))
        print("    bulk           %s    max_repetitions %s"
              % (g("bulk", "1"), g("max_repetitions", "10")))
PY
