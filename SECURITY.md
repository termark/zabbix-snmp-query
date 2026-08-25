# Security notes

## Command injection is the main risk

Zabbix substitutes `{MANUALINPUT}` into the command text **before** any shell
parses it. Operator input therefore reaches a shell on your Zabbix server. The
**Input validation rule** on the script definition is the primary control:

```
^(get|getnext|walk|bulkwalk|bulkget|table) +[A-Za-z0-9._:+-]+( +debug)?$
```

That character class excludes quotes, semicolons, backticks, `$`, `&`, `|`,
newlines and spaces. The script re-validates internally, but that happens after
substitution — it is the second line of defence, not the first. **Do not deploy
without the rule.**

## The API token

The script needs a **Super admin** token, because Zabbix returns SNMP interface
`securityname`, `authpassphrase` and `privpassphrase` only to users with write
access to the host. That is more privilege than the task deserves; there is no
finer-grained option today.

Consequences:

- A token pasted into the script body is stored in the Zabbix database and is
  readable in plain text by anyone with **Reports → Scripts** access. Use the
  external-script installation instead, with the token in a mode-0600 env file.
- Restrict the script by **user group** and **host group**, and set *Required
  host permissions* to Read.
- Rotate the token on the same schedule as any other privileged credential.

## What the script exposes

Passphrases are passed to `snmpget` as command-line arguments, so they are
briefly visible in `ps` output on the Zabbix server to any local user. This is
inherent to net-snmp's CLI. On a server where untrusted local users have shell
access, this tool is not appropriate.

Debug mode (`... debug` as a third token) prints the resolved security name,
protocols and target, but never the passphrases.

## Reporting

Open a GitHub issue for anything non-sensitive. For a suspected vulnerability,
open a private security advisory on the repository rather than a public issue.
