#!/usr/bin/env python3
"""Measurement branch only: scripts/certificate_leak_check.py's second run, with every WebKit
behavior on (--sdk-everything, which leaks on macOS 27), to see that run tell a leak."""
import sys

import aia_variants
import certificate_leak_check

original = aia_variants.run_variant
aia_variants.run_variant = lambda index, app, extra, out, title: original(index, app, ["--sdk-everything"], out, title)
sys.exit(certificate_leak_check.main())
