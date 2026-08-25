# How-to: ad-hoc SNMP queries from the Zabbix frontend

Full setup and troubleshooting for `zbx_snmp_query.sh`. For what it does and
why, see the [README](../README.md).

Verified on Zabbix 7.0.x / Ubuntu, against Cisco NX-OS (SNMPv3 authPriv) and
Huawei YunShan (SNMPv2c).

---

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| `EnableGlobalScripts=1` in `zabbix_server.conf` | **New installations from Zabbix 7.0 ship with this set to `0`.** Manual scripts — including the built-in Ping and Traceroute — will not run until it is `1` and the server is restarted |
| `snmp` package on the Zabbix server | `apt install snmp` — provides `snmpget`, `snmpwalk`, `snmpbulkwalk` |
| `python3` on the Zabbix server | Stdlib only; no `requests`, no `pyzabbix` |
| API token, **Super admin** | Interface `details` (security name, passphrases) are returned only to users with *write* access to the host |
| API reachable from the server | Defaults to `https://localhost/api_jsonrpc.php`; TLS verification is disabled for that loopback call. Override with the `ZBXAPI` environment variable |
| AES-192/256 support (optional) | Only if devices use them: `net-snmp-config --configure-options \| grep -o blumenthal` |

Queries originate on the Zabbix **server**, not on a proxy. Devices monitored
through a proxy must also be reachable from the server, and their SNMP ACLs
must permit it.

---

## 2. The two things that make this non-obvious

Both cost real time to find. Neither is documented where you would look first.

### 2.1 The interface enums are zero-based

This is the whole reason a first attempt can fail on SNMPv3 with
`Authentication failure (incorrect password, community or key)` while SNMPv2c
works fine — v2c needs no protocol mapping, so it hides the bug.

| Field | 0 | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|---|
| `authprotocol` | MD5 | SHA1 | SHA224 | SHA256 | SHA384 | SHA512 |
| `privprotocol` | DES | AES128 | AES192 | AES256 | AES192C | AES256C |
| `securitylevel` | noAuthNoPriv | authNoPriv | authPriv | — | — | — |
| `version` | — | SNMPv1 | SNMPv2c | SNMPv3 | — | — |

`version` is the odd one out: it is **one-based**. Everything else counts from
zero.

net-snmp's spellings: `MD5`, `SHA`, `SHA-224`, `SHA-256`, `SHA-384`, `SHA-512`
for auth; `DES`, `AES`, `AES-192`, `AES-256`, `AES-192-C`, `AES-256-C` for
privacy. Plain `SHA` means SHA1 and plain `AES` means AES128 — there is no
`SHA1` or `AES128` spelling.

A wrong auth protocol produces the same error text as a wrong passphrase.
Don't trust the message to tell you which.

### 2.2 Zabbix runs script bodies under `/bin/sh`, not bash

The shebang in a script body is ignored. On Debian/Ubuntu `/bin/sh` is dash, so
any bashism fails at parse time with something like
`sh: 35: Syntax error: redirection unexpected`.

| Bashism | POSIX replacement |
|---|---|
| `cmd <<<"$var"` | `printf '%s\n' "$var" \| cmd` |
| `[[ "$x" =~ re ]]` | `case "$x" in pattern) ... esac`, or `grep -qE` |
| `arr=(a b c)` | `set -- a b c` and `"$@"` |
| `local var` | plain assignment |
| `${x^^}`, `$'...'` | `tr`, or avoid |

Validate before pasting anything into the frontend:

```bash
dash -n zbx_snmp_query.sh
```

---

## 3. Installation

### 3.1 Recommended: external script

Keeps the API token out of the Zabbix database. Anyone with
*Reports → Scripts* read access can otherwise read a Super admin token in
plain text.

```bash
sudo install -o root -g zabbix -m 0750 \
     zbx_snmp_query.sh /usr/lib/zabbix/externalscripts/zbx_snmp_query.sh

printf 'TOKEN=your-api-token\n' | sudo tee /etc/zabbix/snmp_query.env >/dev/null
sudo chown root:zabbix /etc/zabbix/snmp_query.env
sudo chmod 640 /etc/zabbix/snmp_query.env
```

The script sources `/etc/zabbix/snmp_query.env` if it is readable. Override the
path with `ZBX_SNMP_ENVFILE`. It takes the host name and input as positional
arguments, so the frontend script body is one line:

```sh
/usr/lib/zabbix/externalscripts/zbx_snmp_query.sh '{HOST.HOST}' '{MANUALINPUT}'
```

`0640 root:zabbix` lets the server process read the file while keeping it away
from everyone else. Confirm before relying on it:

```bash
sudo -u zabbix cat /etc/zabbix/snmp_query.env
```

If your `zabbix_server` runs as a different user, adjust the group to match.

### 3.2 Quick path: paste the body into the frontend

The script detects that no arguments were passed and falls back to the
`{HOST.HOST}` / `{MANUALINPUT}` macros, so the same file works pasted in.
Set `TOKEN=` near the top. This stores the token in the database — fine for a
lab, avoid in production.

---

## 4. Script configuration

**Alerts → Scripts → Create script**

| Setting | Value |
|---|---|
| Name | `SNMP Query` |
| Scope | Manual host action |
| Menu path | `Diagnostics` (optional; nests it in a submenu) |
| Type | Script |
| Execute on | Zabbix server |
| Commands | the one-line call from §3.1, or the full body |
| Host group | limit to the groups this should be offered on |
| User group | limit to the operators who should have it |
| Required host permissions | Read |
| Timeout | 30s |

**Advanced → Enable user input:** yes

| Setting | Value |
|---|---|
| Input prompt | `Enter query type and OID (e.g. get 1.3.6.1.2.1.1.1.0)` |
| Default input string | `get 1.3.6.1.2.1.1.1.0` |
| Input validation rule | `^(get\|getnext\|walk\|bulkwalk\|bulkget\|table) +[A-Za-z0-9._:+-]+( +debug)?$` |

Optionally tick *Enable confirmation* and set the confirmation text to
`Run SNMP query on {HOST.HOST}?`, so operators see which host they are about
to query before it runs.

The `( +debug)?` group permits the optional third token. A narrower rule such as
`^(get|walk) [0-9][0-9.]+$` will reject `debug` and the other verbs — a common
first-run surprise.

See [SECURITY.md](../SECURITY.md) for why the rule matters.

---

## 5. Usage

Monitoring → Hosts → click the host → the script appears in the menu.

| Input | Result |
|---|---|
| `get 1.3.6.1.2.1.1.1.0` | sysDescr |
| `get 1.3.6.1.2.1.1.5.0` | sysName |
| `get 1.3.6.1.2.1.1.3.0` | sysUpTime |
| `walk 1.3.6.1.2.1.2.2.1.2` | ifDescr |
| `bulkwalk 1.3.6.1.2.1.31.1.1.1.1` | ifName |
| `get 1.3.6.1.2.1.1.1.0 debug` | resolved parameters, then the query |

Numeric OIDs always work. Symbolic forms pass validation but resolve only if
MIBs are installed (`apt install snmp-mibs-downloader`, then comment out
`mibs :` in `/etc/snmp/snmp.conf`).

Debug output looks like:

```
DEBUG: v3 target=192.0.2.10:161 level=authPriv user=snmpuser auth=MD5 priv=AES context=-
```

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Global script execution on Zabbix server is disabled by server configuration` | `EnableGlobalScripts=0` — the default in `zabbix_server.conf` for installs created on 7.0 or later | Set it to `1` and restart the server. `EnableRemoteCommands` and agent `AllowKey` are unrelated: those govern *Execute on: Zabbix agent/proxy*, and this script runs on the server |
| `Authentication failure (incorrect password, community or key)` | Wrong auth protocol or passphrase — most often the zero-based enum mapping | Compare `authprotocol` against §2.1; `tools/inspect_interface.sh` decodes it |
| `Unknown user name` | `securityname` wrong, or the user is not configured on the device | Check the device's SNMPv3 user config |
| `Timeout: No Response from <ip>` | Device ACL, firewall, or wrong address | Confirm the device permits the Zabbix **server**, not just the proxy |
| `sh: NN: Syntax error: redirection unexpected` | A bashism; Zabbix uses dash | §2.2; validate with `dash -n` |
| `Incorrect API "globalmacro"` | No such API object | Global macros are `usermacro.get` with `"globalmacro": true` |
| `Host '<name>' not found` | `filter.host` is exact, case-sensitive, and matches the *technical* name only | Use `tools/inspect_interface.sh -s <substring>`, or check the token's host-group permissions |
| `... references {$MACRO}, which resolves to nothing` | Credential stored as a Secret text or Vault macro | The API never returns those values. Store as a plain-text macro, or supply credentials another way |
| `Invalid input: does not match the provided pattern` | The frontend validation rule is narrower than what you typed | §4 |
| `SNMPv3 auth passphrase is empty` | Token lacks write access to the host | Use a Super admin token |
| `Support for AES-192 not available` | net-snmp built without Blumenthal AES | Rebuild, or standardise on AES128 |

### Inspecting an interface

```bash
ZBXAPI=https://zabbix.example.net/api_jsonrpc.php \
ZBX_TOKEN=xxxx ./tools/inspect_interface.sh sw-example-01
```

Or by hand:

```bash
curl -sk -X POST https://localhost/api_jsonrpc.php \
  -H "Content-Type: application/json-rpc" \
  -H "Authorization: Bearer $ZBX_TOKEN" \
  -d '{"jsonrpc":"2.0","method":"host.get","params":{
        "filter":{"host":["sw-example-01"]},
        "output":["host"],
        "selectInterfaces":["type","main","useip","ip","dns","port","details"]},
      "id":1}' \
  | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["result"][0]["interfaces"], indent=2))'
```

### Reproducing on the CLI

Always confirm the data path outside Zabbix before changing the script:

```bash
snmpget -v3 -l authPriv -u USER -a MD5 -A 'AUTHPASS' -x AES -X 'PRIVPASS' \
  192.0.2.10:161 1.3.6.1.2.1.1.1.0
```

If the CLI can't get the value, neither can Zabbix — fix access first.

---

## 7. How it works

1. **Parse and validate** the two or three tokens from `{MANUALINPUT}`.
2. **One `host.get` call** returning interfaces, host macros and inherited
   macros together, plus a soft-failed `usermacro.get` for globals.
3. **Resolve macros** with precedence global < template-inherited < host, so an
   interface field holding `{$SNMPV3_AUTHPASS}` expands to its value. Secret
   text and Vault macros come back empty and produce an explicit error rather
   than a confusing SNMP failure.
4. **Pick the SNMP interface**, preferring `main: 1`, and build the target from
   the interface's own `ip`/`dns` and `port` — not `{HOST.CONN}`, which can
   point at a different interface and always assumes 161.
5. **Map the enums** and assemble arguments per `securitylevel`: noAuthNoPriv
   gets neither `-a` nor `-x`; authNoPriv gets `-a`/`-A` only; authPriv gets
   both. A non-empty `contextname` adds `-n`.
6. **Emit `set -- <args>`** with every value `shlex.quote`d, so passphrases
   containing `$`, spaces or quotes survive the shell. `set --` is the POSIX
   substitute for a bash array.
7. **Execute** `snmp$TYPE "$@" "$OID"`.

Error paths print `echo <message>; exit 1` to **stdout** so the surrounding
`eval` executes them. Writing to stderr would let the script continue with
stale positional parameters — worth remembering in any `eval "$(...)"` pattern.

---

## 8. Interface enum reference

Useful for scripting against `host.get` → `interfaces[].details` generally,
not just for this tool:

```
version         1=SNMPv1  2=SNMPv2c  3=SNMPv3          (one-based)
bulk            0=no  1=yes
community       string or {$MACRO}                      (v1/v2c only)
securityname    string or {$MACRO}                      (v3 only)
securitylevel   0=noAuthNoPriv  1=authNoPriv  2=authPriv
authprotocol    0=MD5  1=SHA1  2=SHA224  3=SHA256  4=SHA384  5=SHA512
privprotocol    0=DES  1=AES128  2=AES192  3=AES256  4=AES192C  5=AES256C
authpassphrase  string or {$MACRO}
privpassphrase  string or {$MACRO}
contextname     string or {$MACRO}
max_repetitions integer, default 10
```

Interface `type`: 1=Agent, 2=SNMP, 3=IPMI, 4=JMX.

---

## 9. Operational notes

- **Scope the script** by host group and user group so it only appears where it
  belongs.
- **Log executions.** Manual script runs appear in the Zabbix audit log, but a
  `logger -t zbx-snmp-query "$HOSTNAME_ZBX: $INPUT"` line puts the same record
  into syslog, where a log pipeline will pick it up.
- **Review MD5/DES usage.** RFC 7630 deprecates both; SHA-256 + AES128 is the
  usual current floor. The script handles all twelve combinations, so a
  migration needs no change here — but `authprotocol: 0` showing up widely is
  worth raising in a configuration-compliance review.
