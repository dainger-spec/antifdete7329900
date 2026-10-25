# Hardware identity

Each profile can get a stable hostname and a stable suggested MAC address, so
repeated launches of one profile look the same and different profiles look
different **on the local network**. Neither value is visible to websites:
Safari exposes no hostname or MAC to page JavaScript. What a website sees is
the fingerprint Safari itself reports (see `docs/ISOLATION_AND_LIMITATIONS.md`).

## What is set

| Parameter | How | Stable per profile | Applied automatically |
|-----------|-----|--------------------|-----------------------|
| Hostname (`ComputerName`, `LocalHostName`, `HostName`) | `scutil` inside the guest | Yes | Yes, with `IDENTITY_PROFILE` |
| MAC address | `3C:22:FB` (Apple OUI) + first 3 bytes of SHA-256 of the profile name | Yes | **No** — printed only, set it on the host (below) |

Hostname rule: `Mac-` + the profile name's ASCII letters, digits and hyphens
(at most 20, no leading/trailing hyphen). A name with no ASCII characters
(e.g. `Работа`) gets `Mac-` + 8 hex digits of its hash, so it is still stable
and distinct.

The hostname matters on a **bridged** network: macOS announces
`LocalHostName.local` over Bonjour and sends its name in DHCP. With
`TART_NET=shared` or `softnet` only the host sees it.

## Running it

From the controller (opt-in; without the variable nothing changes):

```bash
IDENTITY_PROFILE=work ./vm/controller/tart-prototype.sh safari-profile https://browserleaks.com
```

Right after SSH comes up the controller runs
`ssh admin@<ip> 'bash -s -- work' < vm/identity.sh`. A failure is reported
(`hardware identity not fully applied`) and the launch continues. The
VMLauncher app does not set `IDENTITY_PROFILE` yet.

By hand:

```bash
ssh admin@<vm-ip> 'bash -s -- work' < vm/identity.sh   # from the host
./identity.sh work                                     # inside the guest
vm/identity.sh --print work                            # just print HOSTNAME=/MAC=, anywhere
```

Requirements and safeguards:

- `scutil --set` needs root. The script uses `sudo -n` (never prompts — over
  `bash -s` stdin is the script itself). The Cirrus Labs images give `admin`
  passwordless sudo; elsewhere run it as root or add a sudoers rule. If any
  name could not be set the script exits 3.
- It refuses to run unless `sysctl kern.hv_vmm_present` is `1` (exit 2), so
  running it on the host Mac by mistake does not rename the host. `--force`
  overrides.

Tests (no Mac needed): `bash vm/test-identity.sh` checks that the MAC is
deterministic and pinned for a known name, and the hostname rules.

## Applying the MAC

The guest cannot pick its MAC: Virtualization.framework assigns it to the
virtual NIC from the VM configuration (Tart keeps it in `config.json`), and
changing it with `ifconfig` inside macOS is neither persistent nor reliable.
Set it on the host with the VM **stopped**:

```bash
tart set safari-profile --random-mac                 # what the app does for each new profile
MAC=$(vm/identity.sh --print work | sed -n 's/^MAC=//p' | tr 'A-F' 'a-f')
tart set safari-profile --mac "$MAC"                 # or this script's stable value
```

Two VMs on the same network must never share a MAC: the controller warns when
another VM has this VM's MAC, and imported profiles get a new one.

## Serial number

Each VM has a `VZMacMachineIdentifier` (Tart's `ecid`), which the guest shows
as its serial number and hardware UUID. **`tart clone` copies it**, so every
clone of one image is the same "Mac" to macOS and Apple's services. The app
runs `tart set <vm> --random-serial --random-mac` right after creating a
profile, before its first boot. For a profile that has already been used, a
new identifier can lock Safari out of passwords kept in the "Local Items"
keychain (bound to the machine), so the app only offers it, with that
warning.

## What the app sets per profile

| | Where |
|---|---|
| Serial number + MAC | `tart set --random-serial --random-mac` at creation (`ProfilePlan.uniqueIdentity`) |
| Hostname `Mac-<profile id>` | `identity.sh`, every launch (`IDENTITY_PROFILE`) — the id, so the profile's name never shows on the network |
| Time zone, language | `identity.sh --timezone … --language …`, from the profile editor |

## What is not set (and cannot be)

On Apple Silicon a macOS guest's hardware description comes from
Virtualization.framework, not from the guest and not copied from the host:

| Parameter | Value in a guest | Why it can't be changed |
|-----------|------------------|-------------------------|
| `hw.model` | `VirtualMac2,1` | Fixed by the framework's `VZMacHardwareModel` |
| Serial number / board ID | From the VM's `VZMacMachineIdentifier`, not a real Mac's | Can be regenerated (`tart set --random-serial`, above) but not set to a chosen value |
| `kern.hv_vmm_present` | `1` | Set by the hypervisor |
| GPU | Apple paravirtualized GPU | The only GPU the framework provides |

So `system_profiler` and `sysctl` inside the guest always show a virtual Mac,
whatever the hostname. Websites cannot read these values directly; the GPU is
the one that can surface through WebGL/WebGPU — check it on
browserleaks.com/webgl from inside the VM.

## Consistency with proxy

If a profile uses a proxy in a specific region:

- Set the VM timezone to match that region
- Set the system locale / language to match

This keeps time and language consistent with the network path. Choose both in
the profile editor (Регион); the app applies them in the guest on every launch
and restarts Safari when they change. It does not guess them from the proxy.

## Checking the environment

Inside the guest:

```bash
scutil --get ComputerName; scutil --get LocalHostName; scutil --get HostName
sysctl hw.model kern.hv_vmm_present
system_profiler SPHardwareDataType
ifconfig en0 | grep ether
```

## Limits

A profile can have its own hostname and (set on the host) its own MAC, but it
cannot impersonate different physical hardware: the guest always identifies as
a Virtualization.framework virtual Mac. This is a platform limit, not a missing
feature.
