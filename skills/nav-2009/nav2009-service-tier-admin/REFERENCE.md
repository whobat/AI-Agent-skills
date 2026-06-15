# nav2009-service-tier-admin — Reference

Detailed reference for `scripts/Get-NavServiceTier.ps1`. For the agent-facing workflow see
[SKILL.md](SKILL.md).

## Requirements

- **PowerShell 7+** (`pwsh`). The repo installer auto-installs it.
- **Local admin** on the target machine to enumerate services and read CustomSettings.config.
- **WinRM / CIM** on the target for `-ComputerName` remote runs. Verify with
  `Test-WSMan <target>` before using `-ComputerName`.
- No additional PowerShell modules required — uses `Get-CimInstance` (built-in) and
  `[xml]` (built-in .NET XML parser).

## Parameters

| Parameter | Type | Default | Notes |
|-----------|------|---------|-------|
| `-ComputerName` | string | `$env:COMPUTERNAME` | Target machine. Local by default. |
| `-Instance` | string | — | Filter to one instance name (part after `$` in the service name). Required when `-Restart` is specified. |
| `-IncludeFullConfig` | switch | off | Include every key from CustomSettings.config, not just the curated set. Useful for debugging or auditing. |
| `-Restart` | switch | off | Restart the matched instance. **Requires `-Instance`.** Stops then starts the service; honors `-RestartTimeoutSec`. |
| `-RestartTimeoutSec` | int | 60 | Seconds to wait for the service to reach `Running` after start. |
| `-OutFile` | string | — | Full JSON to file; stdout becomes a compact summary. |

The script is **read-only by default**. `-Restart` is the only action that changes system state.

## CustomSettings.config keys

Located at (R2 multi-instance):
`C:\Program Files\Microsoft Dynamics NAV\60\Service\Instances\<InstanceName>\CustomSettings.config`

Single-instance NAV 2009 SP1:
`C:\Program Files\Microsoft Dynamics NAV\60\Service\CustomSettings.config`

The file is XML with `<appSettings>` → `<add key="..." value="..."/>` elements.

| Key | Meaning | Surfaced in output |
|-----|---------|-------------------|
| `DatabaseServer` | SQL Server host name | Yes — `settings.DatabaseServer` |
| `DatabaseInstance` | SQL named instance (blank = default) | Yes |
| `DatabaseName` | NAV database name | Yes — `settings.DatabaseName` |
| `ServerInstance` | NST instance name (matches the service `$<name>` suffix) | Yes |
| `ClientServicesPort` | Port for RTC (Windows client) connections. Default **7046**. | Yes — `ports.client` |
| `SOAPServicesPort` | Port for SOAP / web services. Default **7047**. | Yes — `ports.soap` |
| `ManagementServicesPort` | Port for NAV Server admin tool (NSMMT). Default **7045**. | Yes — `ports.management` |
| `ClientServicesCredentialType` | Auth type for RTC: `Windows`, `NavUserPassword`, `Username`, `AccessControlService` | Yes |
| `SOAPServicesEnabled` | `true` / `false` — whether SOAP endpoint is active | Yes |
| `ServicesCertificateThumbprint` | Certificate thumbprint for credential types that need TLS | Yes (blank if Windows auth) |
| `NASServicesStartupCodeunit` | Codeunit to run at NAS startup. **450 = Job Queue**. | Yes — `nas.codeunit` |
| `NASServicesStartupMethod` | Method/function within the codeunit. Typically `JOBQUEUE`. | Yes — `nas.method` |
| `NASServicesStartupArgument` | Argument passed to the startup method. | Yes — `nas.argument` |
| All other keys | Company, service timeouts, max connections, etc. | Only with `-IncludeFullConfig` |

**Note:** Changes to CustomSettings.config do NOT take effect until the service is restarted.

## NAS / Job Queue

The **NAS (NAV Application Server)** is the same Windows service (`Microsoft.Dynamics.Nav.Server.exe`)
configured to run unattended background work. It is identified by the presence of
`NASServicesStartupCodeunit` in CustomSettings.config.

| Startup codeunit | Purpose |
|-----------------|---------|
| **450** | Job Queue — standard scheduled/recurring task runner in NAV 2009 R2 |
| Other values | Custom batch jobs or integrations installed by a partner/developer |

`nas.enabled` in the output is `true` when `NASServicesStartupCodeunit` has a non-empty value.
A NAS instance that is `enabled = true` but `status != Running` means the Job Queue is not
processing — this is typically urgent and should be flagged immediately.

The same physical service can act as both an RTC server and a NAS if both client services and
NAS settings are configured, though this is unusual in production.

## Output schema

```json
{
  "status":       "ok | partial | error",
  "generated_at": "2026-06-10T09:00:00.0000000Z",
  "computer":     "NAVSRV01",
  "instances": [
    {
      "serviceName":  "MicrosoftDynamicsNavServer$NAVPROD",
      "instanceName": "NAVPROD",
      "status":       "Running | Stopped | ...",
      "startMode":    "Auto | Manual | Disabled",
      "account":      "DOMAIN\\svc-nav",
      "exePath":      "C:\\...\\Microsoft.Dynamics.Nav.Server.exe",
      "configPath":   "C:\\...\\CustomSettings.config",
      "settings": {
        "DatabaseServer":                "SQLSRV01",
        "DatabaseInstance":              "",
        "DatabaseName":                  "Navision_PROD",
        "ServerInstance":                "NAVPROD",
        "ClientServicesPort":            "7046",
        "SOAPServicesPort":              "7047",
        "ManagementServicesPort":        "7045",
        "ClientServicesCredentialType":  "Windows",
        "SOAPServicesEnabled":           "true",
        "ServicesCertificateThumbprint": ""
      },
      "nas": {
        "codeunit": "450",
        "method":   "JOBQUEUE",
        "argument": "",
        "enabled":  true
      },
      "ports": {
        "client":     7046,
        "soap":       7047,
        "management": 7045
      },
      "error": null
    }
  ],
  "restart": {
    "requested": "2026-06-10T09:05:00.0000000Z",
    "instance":  "NAVPROD",
    "before":    "Running",
    "after":     "Running",
    "ok":        true
  }
}
```

`restart` is only present when `-Restart` was passed. `status` is `partial` when any instance
has a non-null `error` field; `error` when the enumeration itself failed.

With `-OutFile`, stdout carries a compact summary:

```json
{
  "status":    "ok",
  "out_file":  "C:\\ops\\nav-tiers.json",
  "instances": [
    { "instanceName": "NAVPROD", "status": "Running" }
  ]
}
```

## Restart order & gotchas

1. **Confirm with the user** before restarting — all connected RTC clients will be disconnected.
2. The script uses `Stop-Service -Force` then `Start-Service` on the matched service name.
   It waits up to `-RestartTimeoutSec` for the service to reach `Running` status.
3. If SOAP web services run as a **separate** dependent service (unusual in NAV 2009 but possible
   in custom deployments), stop it first, restart the main NST, then start the dependent service.
   The script only manages the one service matched by name; dependent services must be handled
   manually if present.
4. The **service account** must have:
   - "Log on as a service" right (`SeServiceLogonRight`)
   - Read/write access to the NAV database in SQL Server
   - For Kerberos/Windows auth from RTC clients: a correct **SPN** registered for the service
     account (`setspn -A MsDynamicsNav/HOST:PORT DOMAIN\svc-nav`). A missing SPN causes
     "You cannot use Kerberos authentication" errors on the client even though the service starts.
5. After restarting, verify `restart.ok = true` and `restart.after = Running`. If `ok = false`,
   check Windows Application and System Event Logs on the target for service-start failures
   (common causes: SQL Server unreachable, certificate not found, port already in use).

## Gotchas

**CustomSettings.config edits are silently ignored until the service restarts.**
Trap: an administrator edits a key (e.g. changes `DatabaseName` or a port), saves the file, and
tests connectivity — the change has no effect. Why: the NST reads CustomSettings.config once at
startup and caches every value in memory; the running process never re-reads the file. Correct
check: after any config edit, compare the value you wrote with what the script reports in
`settings.*` — if they differ, the service has not been restarted yet. Use `-Restart` (with user
confirmation) to apply the change.

**Multiple NST instances on one box each own a separate CustomSettings.config — editing the wrong
file is invisible.**
Trap: a box runs two instances (`DynamicsNAV` and `NAVTEST`). An admin opens the first
CustomSettings.config that Explorer finds, edits it, restarts one service — the intended instance
is unaffected. Why: R2 multi-instance layout places each instance's config under
`...\Service\Instances\<InstanceName>\CustomSettings.config`; the binaries in `...\Service\` are
shared but each instance's config directory is independent. Correct check: read `configPath` from
the script's JSON for the specific instance before editing; confirm the instance name in the file's
path matches the target instance.

**A wrong or missing SQL login for the service account surfaces as a service start failure, not a
NAV client error.**
Trap: the service account (`account` field in the output) is changed, or the SQL Server login is
dropped/roles are removed, and the tier fails to start. The Windows Service Control Manager logs
"The service did not respond to the start or control request in a timely fashion" — no NAV-level
error is shown because the NST never reaches the point of accepting connections. Why: the NST
validates the SQL connection synchronously during startup; if the login is missing or the account
lacks `db_owner` (or the NAV-required fixed roles) on the target database, the process exits
before binding any ports. Correct check: confirm the service account has a SQL Server login, that
the login is mapped to the database named in `settings.DatabaseName`, and that it holds the
necessary database roles — then retry the start and watch the Application Event Log on SRV01 for
`Microsoft.Dynamics.Nav.Server` source entries.

**Running NAS / Job Queue on more than one NST instance against the same database causes jobs to
execute twice.**
Trap: a second NST instance is stood up for load testing or failover with `nas.enabled = true` and
`NASServicesStartupCodeunit = 450`, pointing at the same NAV database. Both instances pick up
the same Job Queue entries and run them concurrently. Why: NAV 2009 Job Queue locking is advisory
— each NAS instance polls the Job Queue table independently and can claim the same entry if the
first lock is not visible in time. There is no built-in singleton guard across instances. Correct
check: in a multi-instance inventory, confirm that at most one instance per database has
`nas.enabled = true`; if more than one does, disable `NASServicesStartupCodeunit` in
CustomSettings.config for all but the designated NAS instance and restart those services.

**A non-Windows credential type requires a certificate in the service account's certificate store;
a missing or inaccessible cert silently prevents the service from starting.**
Trap: `ClientServicesCredentialType` is set to `NavUserPassword` or `AccessControlService` and
`ServicesCertificateThumbprint` is populated, but the service fails to start after a host rebuild
or service-account change. The config file looks correct. Why: the NST loads the certificate by
thumbprint from the `LocalMachine\My` store (or the service account's personal store, depending on
deployment) at startup; if the certificate was not imported on the new host, or the service account
does not have private-key read permission on it, the process cannot bind the TLS endpoint and
exits. Correct check: on SRV01, open `certlm.msc` → Personal → Certificates and confirm the
thumbprint in `settings.ServicesCertificateThumbprint` is present; right-click → All Tasks →
Manage Private Keys and verify the service account (`account` field) has at least Read permission.
If the cert is missing, re-import it from the original PFX before restarting.
