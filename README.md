# ant-mobile-ios

Autonomi's iOS reference app — **external-signer paid uploads over
WalletConnect**. A SwiftUI app that exercises the Autonomi SDK end-to-end: pick a
file, preview the storage cost, pay from the user's own wallet (the app never
holds a key), upload, and round-trip it back via Download.

It's the canonical worked example for the flow documented in
[`ant-sdk/docs/mobile-external-signer.md`](https://github.com/WithAutonomi/ant-sdk/blob/main/docs/mobile-external-signer.md).

Builds for **iOS Simulator** and **macOS**. Consumes the published
[`ant-swift`](https://github.com/WithAutonomi/ant-swift) SDK by version
(`from: 0.0.7` in `project.yml`) — the release ships the `AntFfi.xcframework`, so
no local SDK build is needed. Bump `from:` to adopt a newer SDK release.

## What it does

Four tabs (`AppShell.swift`):

- **Uploads** — pick a file; the app shows a fast sampled cost preview
  (`estimateFileCost`) while it prepares the real quote (`prepareFileUpload`),
  then a confirm sheet. On approve it runs the external-signer paid flow
  (`paymentTransactions` → sign each tx via the connected wallet →
  `waitForReceipt` → `finalizeUpload`/`finalizeUploadMerkle` with live progress),
  handling **both** the wave and merkle payment shapes.
- **Downloads** — paste a data-map address (or "Use last") to stream the content
  back to a file (`downloadPublicToFile`, with progress).
- **Wallet** — connect a self-custody wallet via **Reown AppKit** (WalletConnect);
  shows the connected address, chain, and ANT/ETH balances.
- **Settings** — a **Developer** section to point the app at a devnet (see below).

All ABI encoding, receipt polling, and the merkle-winner lookup live in the SDK —
the app builds no calldata itself.

## Prerequisites

- Xcode 15+ with the iOS Simulator SDK.
- `xcodegen` (`brew install xcodegen`) to generate the project.
- A devnet to connect to (below).
- For the paid flow: a WalletConnect wallet (e.g. MetaMask) and a funded wallet
  on the target chain (Arbitrum Sepolia for a test devnet).

## Connecting to a devnet

The app connects from a **devnet manifest** (bootstrap peers + EVM config). Two
ways to supply it:

1. **LAN / Sepolia devnet (physical device or sim)** — set **Settings →
   Developer → devnet host** to the host serving the manifest API, e.g.
   `192.168.0.62:8088`. The app fetches
   `http://<host>/api/devnet-manifest.json` over HTTP. This is how cross-device
   LAN testing works with the released SDK (needs `ant-swift` ≥ 0.0.7).
2. **Local simulator (zero-config)** — leave the devnet host blank. The
   simulator shares the host filesystem, so the app reads the manifest the
   desktop/CLI writes to `~/Library/Application Support/ant/devnet-manifest.json`
   (resolved via the simulator's `SIMULATOR_HOST_HOME`, so it works for any
   user). Start a local devnet from an [`ant-client`](https://github.com/WithAutonomi/ant-client)
   checkout:

   ```sh
   # One-time: move cached mainnet/testnet bootstrap peers aside, or the local
   # devnet's bootstrap nodes spin forever. Restore afterwards.
   mv ~/Library/Caches/saorsa/bootstrap/bootstrap_cache.json \
      ~/Library/Caches/saorsa/bootstrap/bootstrap_cache.json.aside
   cargo run --release --example start-local-devnet --features devnet
   ```

## Build & run

```sh
xcodegen                # one-time / after editing project.yml
open AntSwiftDemo.xcodeproj
# ⌘R against an iPhone simulator or "My Mac"
```

From the command line — **note the published xcframework is arm64-only**, so
target a *concrete* arm64 simulator, not `generic/platform=iOS Simulator`
(which pulls x86_64 and fails to link):

```sh
xcodebuild -scheme AntSwiftDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## WalletConnect setup

Get a project id from <https://dashboard.reown.com> and set `reownProjectId` in
`AppShell.swift`. Reown project ids are public client identifiers (safe to ship).
Connect the wallet from the **Wallet** tab (the connect modal is iOS-only; on the
simulator, QR-pair a wallet on another device). For a test devnet, fund the
wallet on **Arbitrum Sepolia** (chain 421614).

## Caveats

- This is a **devnet** reference app. Production bootstrap discovery and network
  config look different — the devnet-manifest connect path is test-only.
- The macOS build disables App Sandbox so it can read the shared manifest and
  reach a loopback devnet. Don't ship a real app with these settings.
- iOS Sepolia contract addresses in `AutonomiContracts.swift` are placeholders
  (payment `to` comes from the SDK's `paymentTransactions`, but the balance
  display needs real addresses) — see Linear **V2-608**.
