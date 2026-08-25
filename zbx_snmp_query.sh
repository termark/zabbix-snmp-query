#!/bin/sh
#
# zbx_snmp_query.sh - ad-hoc SNMP queries from the Zabbix frontend, using the
# credentials Zabbix already holds on the host's SNMP interface.
#
# Supports SNMPv1, v2c and v3 (all three security levels), resolving user
# macros and honouring the interface's own address, port and context name.
#
# Works two ways:
#   1. External script (recommended - keeps the API token out of the database):
#        /usr/lib/zabbix/externalscripts/zbx_snmp_query.sh '{HOST.HOST}' '{MANUALINPUT}'
#   2. Pasted directly into the script body in the Zabbix frontend, in which
#      case Zabbix substitutes the two macros below before execution.
#
# NOTE: Zabbix ignores the shebang and runs script bodies with /bin/sh, which
# is dash on Debian/Ubuntu. This file is deliberately POSIX-only: no
# here-strings (<<<), no [[ ]], no arrays, no "local". Verify with:
#   dash -n zbx_snmp_query.sh
#
# See docs/HOWTO.md for full setup, the validation rule, and troubleshooting.
#
# SPDX-License-Identifier: MIT
#
set -u

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
ZBXAPI="${ZBXAPI:-https://localhost/api_jsonrpc.php}"

# Token source, in order of preference:
#   1. an env file, mode 0600, root-owned            <- recommended
#   2. the TOKEN environment variable
#   3. the fallback below                            <- only for a pasted body
ENVFILE="${ZBX_SNMP_ENVFILE:-/etc/zabbix/snmp_query.env}"
if [ -r "$ENVFILE" ]; then
    # shellcheck source=/dev/null
    . "$ENVFILE"
fi
TOKEN="${TOKEN:-REPLACE_WITH_YOUR_API_TOKEN}"

export ZBXAPI TOKEN

# ----------------------------------------------------------------------------
# Input: positional arguments if given, otherwise Zabbix macros
# ----------------------------------------------------------------------------
if [ $# -ge 2 ]; then
    HOSTNAME_ZBX="$1"
    INPUT="$2"
else
    HOSTNAME_ZBX="{HOST.HOST}"
    INPUT="{MANUALINPUT}"
fi
export HOSTNAME_ZBX

# ----------------------------------------------------------------------------
# Parse and validate input.
#
# This is defence in depth only. The PRIMARY control is the script's
# "Input validation rule" in the Zabbix UI, because Zabbix substitutes
# {MANUALINPUT} into the command text before any shell parses it:
#   ^(get|getnext|walk|bulkwalk|bulkget|table) +[A-Za-z0-9._:+-]+( +debug)?$
# ----------------------------------------------------------------------------
TYPE=$(printf '%s\n' "$INPUT" | awk '{print $1}')
OID=$(printf  '%s\n' "$INPUT" | awk '{print $2}')
MODE=$(printf '%s\n' "$INPUT" | awk '{print $3}')   # optional: "debug"

case "$TYPE" in
  get|getnext|walk|bulkwalk|bulkget|table) ;;
  *) echo "Invalid operation '$TYPE' (use: get, getnext, walk, bulkwalk, bulkget, table)"
     exit 1 ;;
esac

case "$OID" in
  "" )                  echo "No OID supplied";    exit 1 ;;
  *[!A-Za-z0-9._:+-]* ) echo "Invalid OID '$OID'"; exit 1 ;;
esac

export DEBUG_MODE="$MODE"

# ----------------------------------------------------------------------------
# Resolve SNMP parameters from the Zabbix API in a single pass.
# Emits a shell-quoted "set -- ..." line, or "echo <error>; exit 1".
# ----------------------------------------------------------------------------
eval "$(python3 - <<'PY'
import json, os, re, shlex, ssl, sys, urllib.request

API   = os.environ["ZBXAPI"]
TOKEN = os.environ["TOKEN"]
HOST  = os.environ["HOSTNAME_ZBX"]
DEBUG = os.environ.get("DEBUG_MODE", "") == "debug"

def fail(msg):
    # Must go to STDOUT so the surrounding eval executes it. Writing to
    # stderr would let the caller continue with stale positional parameters.
    print("echo %s; exit 1" % shlex.quote(msg))
    sys.exit(0)

sslctx = ssl._create_unverified_context()

def call(method, params, soft=False):
    body = json.dumps({"jsonrpc": "2.0", "method": method,
                       "params": params, "id": 1}).encode()
    req = urllib.request.Request(API, data=body, headers={
        "Content-Type":  "application/json-rpc",
        "Authorization": "Bearer " + TOKEN})
    try:
        resp = json.load(urllib.request.urlopen(req, context=sslctx, timeout=10))
    except Exception as e:
        if soft:
            return []
        fail("Zabbix API call %s failed: %s" % (method, e))
    if "error" in resp:
        if soft:
            return []
        fail("Zabbix API error on %s: %s" % (method, resp["error"]))
    return resp["result"]

# --- host, interfaces and the full macro chain in one request ---------------
hosts = call("host.get", {
    "filter":                {"host": [HOST]},
    "output":                ["hostid", "host"],
    "selectInterfaces":      ["type", "main", "useip", "ip", "dns",
                              "port", "details"],
    "selectMacros":          "extend",
    "selectInheritedMacros": "extend",
})
if not hosts:
    fail("Host '%s' not found, or the token has no permission on it." % HOST)
h = hosts[0]

# Precedence: global < template-inherited < host-level.
# Global macros come from usermacro.get with globalmacro=true; there is no
# "globalmacro" API object. Soft-failed, since selectInheritedMacros usually
# already covers globals.
macros = {}
for m in call("usermacro.get", {"output": "extend", "globalmacro": True},
              soft=True):
    macros[m["macro"]] = m.get("value") or ""
for m in h.get("inheritedMacros", []):
    macros[m["macro"]] = m.get("value") or ""
for m in h.get("macros", []):
    macros[m["macro"]] = m.get("value") or ""

MACRO_RE = re.compile(r"^\{\$[^}]+\}$")

def rez(value, field):
    """Expand a {$MACRO} reference one level; pass literals through."""
    v = (value or "").strip()
    if not v or not MACRO_RE.match(v):
        return v
    if macros.get(v):
        return macros[v]
    # {$MACRO:"context"} falls back to the context-less definition
    base = re.sub(r'^\{\$([A-Z0-9._]+):.*\}$', r'{$\1}', v)
    if macros.get(base):
        return macros[base]
    fail("Interface field '%s' references %s, which resolves to nothing. "
         "Secret text and Vault macros are never returned by the API - the "
         "credentials must be plain-text macros or literals for this script "
         "to read them." % (field, v))

# --- pick the SNMP interface, preferring the default one -------------------
det = None
iface = None
for i in h["interfaces"]:
    if str(i.get("type")) == "2" and i.get("details"):
        det, iface = i["details"], i
        if str(i.get("main")) == "1":
            break
if det is None:
    fail("Host '%s' has no SNMP interface." % HOST)

# --- target: honour the interface's own address and port -------------------
addr = iface["ip"] if str(iface.get("useip")) == "1" else iface.get("dns", "")
port = str(iface.get("port") or "161")
if not addr:
    fail("SNMP interface on '%s' has no usable address." % HOST)
target = "%s:%s" % (addr, port)

# --- ZERO-BASED Zabbix enums -> net-snmp names -----------------------------
# authprotocol:  0=MD5 1=SHA1 2=SHA224 3=SHA256 4=SHA384 5=SHA512
# privprotocol:  0=DES 1=AES128 2=AES192 3=AES256 4=AES192C 5=AES256C
# securitylevel: 0=noAuthNoPriv 1=authNoPriv 2=authPriv
# (version is the odd one out: 1=SNMPv1 2=SNMPv2c 3=SNMPv3)
AUTH  = {"0": "MD5",     "1": "SHA",       "2": "SHA-224",
         "3": "SHA-256", "4": "SHA-384",   "5": "SHA-512"}
PRIV  = {"0": "DES",     "1": "AES",       "2": "AES-192",
         "3": "AES-256", "4": "AES-192-C", "5": "AES-256-C"}
LEVEL = {"0": "noAuthNoPriv", "1": "authNoPriv", "2": "authPriv"}

g = lambda k, d="": str(det.get(k, d))
version = g("version", "2")

args = ["-t", "5", "-r", "1"]             # keep the frontend from hanging

if version == "3":
    level     = LEVEL.get(g("securitylevel", "0"))
    authproto = AUTH.get(g("authprotocol", "0"))
    privproto = PRIV.get(g("privprotocol", "0"))
    if level is None:
        fail("Unknown securitylevel '%s' on the SNMP interface." % g("securitylevel"))
    if authproto is None:
        fail("Unknown authprotocol '%s' on the SNMP interface." % g("authprotocol"))
    if privproto is None:
        fail("Unknown privprotocol '%s' on the SNMP interface." % g("privprotocol"))

    secname = rez(det.get("securityname"), "securityname")
    if not secname:
        fail("SNMPv3 security name is empty on the SNMP interface.")
    args += ["-v3", "-l", level, "-u", secname]

    if level in ("authNoPriv", "authPriv"):
        authpass = rez(det.get("authpassphrase"), "authpassphrase")
        if not authpass:
            fail("SNMPv3 auth passphrase is empty (level is %s)." % level)
        args += ["-a", authproto, "-A", authpass]

    if level == "authPriv":
        privpass = rez(det.get("privpassphrase"), "privpassphrase")
        if not privpass:
            fail("SNMPv3 priv passphrase is empty (level is authPriv).")
        args += ["-x", privproto, "-X", privpass]

    ctxname = rez(det.get("contextname"), "contextname")
    if ctxname:
        args += ["-n", ctxname]

    dbg = ("v3 target=%s level=%s user=%s auth=%s priv=%s context=%s"
           % (target, level, secname, authproto, privproto, ctxname or "-"))
else:
    community = rez(det.get("community"), "community")
    if not community:
        fail("SNMP community is empty on the SNMP interface.")
    args += ["-v1" if version == "1" else "-v2c", "-c", community]
    dbg = "v%s target=%s community=<redacted>" % (version, target)

args.append(target)

if DEBUG:
    print("echo %s" % shlex.quote("DEBUG: " + dbg))
# shlex.quote everything, so passphrases containing $, spaces or quotes
# survive the shell. "set --" is the POSIX substitute for a bash array.
print("set -- " + " ".join(shlex.quote(a) for a in args))
PY
)"

# ----------------------------------------------------------------------------
# Execute
# ----------------------------------------------------------------------------
snmp"$TYPE" "$@" "$OID" 2>&1
