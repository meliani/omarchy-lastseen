# Security

Please report vulnerabilities privately through GitHub: **Security → Report a vulnerability** on
[meliani/omarchy-lastseen](https://github.com/meliani/omarchy-lastseen/security/advisories/new).
Don't open a public issue for them.

Useful to know when assessing a report:

- Omarchy plugins run unsandboxed inside the user's shell.
- Secrets are read from the desktop keyring (`secret-tool`, service `lastseen`); they never go in files, arguments or the environment.
- Message content is displayed as plain text; links are escaped and only `http(s)` URLs open.
- Media is downloaded only from the user's own Evolution API; profile pictures only from `pps.whatsapp.net`.
