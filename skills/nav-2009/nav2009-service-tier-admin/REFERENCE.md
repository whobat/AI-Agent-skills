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
