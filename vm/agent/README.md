# In-VM Agent

Small service that runs inside each macOS VM and controls Safari.

## Responsibilities

- Accept commands from the host controller (HTTP or SSH)
- Launch / focus Safari
- Navigate to a URL
- Return screenshot or page status
- Apply proxy settings if not handled at VM network level

## Status

Not implemented. Prototype uses direct SSH for now:

```bash
ssh admin@<vm-ip> 'open -a Safari https://example.com'
```

## Next steps

- Minimal Python HTTP server (stdlib only) listening on a VM-internal port
- Endpoints: `/navigate`, `/screenshot`, `/status`
- Package as a LaunchAgent so it starts with the VM
