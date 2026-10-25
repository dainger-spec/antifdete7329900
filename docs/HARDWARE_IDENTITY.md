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
virtual NIC from the VM configuration, and changing it with `ifconfig` inside
macOS is neither persistent nor reliable. Tart keeps it in the VM's
`config.json` (`macAddress`) and offers only `tart set <vm> --random-mac` on
the command line. To use the suggested value, with the VM **stopped**:

```bash
MAC=$(vm/identity.sh --print work | sed -n 's/^MAC=//p' | tr 'A-F' 'a-f')
CFG=~/.tart/vms/safari-profile/config.json        # $TART_HOME/vms/... if set
grep macAddress "$CFG"                            # the key must exist
cp "$CFG" "$CFG.bak"
sed -i '' -E "s/(\"macAddress\" *: *\")[^\"]*/\1$MAC/" "$CFG"
grep macAddress "$CFG"                            # check the new value
```

This edits Tart's own file format, not a documented interface; keep the
backup and recheck after Tart upgrades. Two VMs on the same bridged LAN must
never share a MAC: distinct profile names give distinct MACs (24 bits of
hash), but check `grep macAddress ~/.tart/vms/*/config.json` if you also have
VMs you did not set this way.

## What is not set (and cannot be)

On Apple Silicon a macOS guest's hardware description comes from
Virtualization.framework, not from the guest and not copied from the host:

| Parameter | Value in a guest | Why it can't be changed |
|-----------|------------------|-------------------------|
| `hw.model` | `VirtualMac2,1` | Fixed by the framework's `VZMacHardwareModel` |
| Serial number / board ID | Generated per VM, not a real Mac's | Derived from the VM's `VZMacMachineIdentifier`; no API to set arbitrary values |
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

This keeps time and language consistent with the network path. The controller
does not do this automatically yet.

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
