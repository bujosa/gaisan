# Gaisan

Menu bar for macOS. It shows an API-price estimate of local agent logs, not a bill. The ticker is **today** plus the amount, and it updates when the local usage cache changes. Click it for Today / 7d / 30d / All, source mix, cache savings, and top models.

It reads the local usage cache at `~/.t3/userdata/usage-scan-cache-v5.json` and prices rows the same way that cache was written: uncached input, cache reads, cache writes, output, plus a provider-reported cost when the row already has one. If those logs are missing, the status item stays hidden. This is a separate app from Uso, which shows remaining plan quota.

Requires macOS 14 or later.

```sh
swift test
./scripts/install.sh
```

`swift run Gaisan --print` prints today's / 7-day / all-time totals without opening the menu bar.
