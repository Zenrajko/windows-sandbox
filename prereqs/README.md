# Prerequisites

The sandbox has networking disabled, so download any required prerequisites and drop them in this folder.
The `Setup*.ps1` scripts can be configured to load what they need to test their specific scenarios.

## Useful dependencies

| File pattern | What it is | Download |
|---|---|---|
| `dotnet-hosting-*-win.exe` | ASP.NET Core Hosting Bundle (8.x or newer) | <https://dotnet.microsoft.com/download/dotnet/8.0> → "Hosting Bundle" |
| `rewrite_amd64*.msi` | IIS URL Rewrite 2.1 (x64) | <https://www.iis.net/downloads/microsoft/url-rewrite> |
| `GoogleChrome*.msi` | Chrome Enterprise x64 MSI (e.g. for PDF generation at runtime) | |
