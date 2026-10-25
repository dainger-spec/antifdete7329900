# Hardware identity

Each profile can have a stable, consistent hardware identity so that repeated launches of the same profile look the same, and different profiles look different.

## What is set

| Parameter | How | Stable per profile |
|-----------|-----|--------------------|
| Hostname | `scutil` inside guest | Yes |
| MAC address | Derived from profile name (Apple OUI) | Yes (suggested) |

Script: `vm/identity.sh <profile-name>`

## What is not set

| Parameter | Why |
|-----------|-----|
| `hw.model` | Firmware-locked on Apple Silicon |
| Serial number | Firmware-locked |
| Board ID | Firmware-locked |
| GPU renderer | Depends on Virtualization.framework; may contain platform strings |

These values come from the host or the hypervisor and cannot be changed from inside the guest on Apple Silicon.

## Consistency with proxy

If a profile uses a proxy in a specific region:

- Set the VM timezone to match that region
- Set the system locale / language to match

This keeps time and language consistent with the network path. The controller does not do this automatically yet.

## Checking the environment

Inside the guest:

```bash
sysctl hw.model
system_profiler SPHardwareDataType
ifconfig | grep ether
```

Compare with a physical Mac if you need a baseline.

## Limits

On Apple Silicon with Virtualization.framework, some hardware parameters are shared with or derived from the host. A profile can have its own hostname and (where supported) MAC, but it cannot fully impersonate different physical hardware. This is a platform limit, not a missing feature.
