# ant-mobile-ios

Autonomi's iOS demo app — external-signer paid uploads over WalletConnect.
A SwiftUI app that exercises the Autonomi SDK end-to-end: type a message,
tap Upload, get a chunk address back, paste that address into Download to
round-trip the content.

Builds for **iOS Simulator** and **macOS**. Consumes the published
[`ant-swift`](https://github.com/WithAutonomi/ant-swift) SDK by version
(`from: 0.0.3` in `project.yml`) — the release ships the `AntFfi.xcframework`,
so no local SDK build is needed. Bump `from:` to adopt a newer SDK release.

## Prerequisites

- Xcode 15+ with the iOS Simulator SDK installed.
- `xcodegen` to generate the project file:
  `brew install xcodegen`
- Rust toolchain (for the devnet): `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- `anvil` from Foundry (the devnet's embedded EVM blockchain):
  `brew install foundry`

### Starting the local devnet

The demo needs a devnet running on the host. From a checkout of
[`ant-client`](https://github.com/WithAutonomi/ant-client):

```sh
# One-time: move any cached public mainnet/testnet bootstrap peers out
# of the way. Otherwise the local devnet's bootstrap nodes will spin
# forever trying to dial unreachable hosts and never become ready.
# Restore the file after you're done with devnet work.
mv ~/Library/Caches/saorsa/bootstrap/bootstrap_cache.json \
   ~/Library/Caches/saorsa/bootstrap/bootstrap_cache.json.aside

cargo run --release --example start-local-devnet --features devnet
```

Leave it running. It writes the manifest at
`~/Library/Application Support/ant/devnet-manifest.json` (hardcoded
path in `ContentView.swift`).

## Run

```sh
xcodegen                # one-time / after editing project.yml
open AntSwiftDemo.xcodeproj
# then ⌘R against an iPhone simulator or "My Mac"
```

Or all from the command line:

```sh
# macOS
xcodebuild -scheme AntSwiftDemo -destination 'platform=macOS' build
open ./build/Debug/AntSwiftDemo.app

# iOS Simulator
xcodebuild -scheme AntSwiftDemo -destination 'platform=iOS Simulator,name=iPhone 17' build
xcrun simctl install booted ./build/Debug-iphonesimulator/AntSwiftDemo.app
xcrun simctl launch booted com.autonomi.examples.AntSwiftDemo
```

## What it does

- **Upload**: appends a random suffix to the input text (so successive
  taps produce distinct chunks — Autonomi is content-addressed, so
  identical content always lands at the same address), uploads as a
  chunk, displays the resulting address.
- **Download**: paste any chunk address (or tap "Use last") and pull
  the content back as text.

## WalletConnect spike (iOS only)

An exploratory spike (`Sources/AntSwiftDemo/Wallet/`) wiring an external
self-custody wallet via **Reown AppKit** (the successor to Web3Modal — the
same stack the desktop app uses). The app never holds a private key: it
builds the transaction and the user's wallet signs it. This is the
store-policy-safe payment model (see the Linear *Mobile SDK (iOS & Android)*
project), and the mobile mirror of `ant-ui/utils/payment.ts`.

**What the spike proves:** Connect Wallet → the wallet signs a real
`eth_sendTransaction` → we get a tx hash back. The transaction is an ERC-20
`approve` of the Autonomi payment vault — the same first step the desktop
performs before `payForQuotes`. With approve amount `0` it costs only gas and
needs **no token balance**.

**What it is NOT yet:** a full paid upload. That needs the external-signer
prepare/finalize surface added to `ant-ffi` (Linear **V2-391**): prepare
returns the real quotes/amounts, the wallet signs `payForQuotes`, finalize
stores the chunks. `EthCalldata.payForQuotes(_:)` is already implemented here
for that next step.

### Running the spike

1. Get a WalletConnect project id from <https://dashboard.reown.com> and set
   `reownProjectId` in `ContentView.swift`.
2. `xcodegen && open AntSwiftDemo.xcodeproj`, run on an **iPhone** target
   (the connect modal is iOS-only).
3. Tap **Connect Wallet**, approve in a wallet app (MetaMask/Rainbow), then
   **Send test approve tx**. You'll need a little ETH on Arbitrum One for gas;
   for a no-real-funds run, fill in the Arbitrum **Sepolia** token/vault
   addresses in `AutonomiContracts.swift` (from your devnet manifest) and
   target `.arbitrumSepolia`.

### Build status

- ✅ **Compiles** for the iPhone simulator (verified: `BUILD SUCCEEDED`). The
  Reown API in `WalletConnectManager.swift` was corrected against the resolved
  SDK source — `sessionsPublisher` / `sessionResponsePublisher`,
  `AppKit.configure(projectId:metadata:crypto:authRequestParams:)`,
  `AppKit.instance.request(.eth_sendTransaction(...))`, `getAddress()` /
  `getSelectedChain()`. `SpikeCryptoProvider` is a stub (SIWE-only, unused here).
- ⚠️ **Requires the V2-532 fix to build.** AntFfi's published *static*
  xcframework collides with Reown's `yttrium` xcframework on
  `include/module.modulemap`. The build above used a **dynamic-framework**
  AntFfi xcframework (the V2-532 fix). Until ant-sdk ships that, the spike
  won't link against the v0.0.2 release. See Linear V2-532.
- **Not yet run on a device.** The simulator can't run a wallet app, so the
  actual connect→sign→tx-hash round-trip still needs a real iPhone + wallet
  (or QR-pairing a desktop wallet).
- macOS: the spike is `#if os(iOS)` (module `ReownAppKit`; the connect modal +
  a transitive Coinbase dep are iOS-oriented). `platformFilter: iOS` in
  `project.yml` keeps it off the macOS build.

## Caveats

- This is a **devnet** demo. Production wallets, payment flows, and
  bootstrap discovery look different.
- The manifest path is hardcoded to the macOS user's home. For a
  different machine, edit `ContentView.swift` (`manifestPath`).
- The macOS build disables App Sandbox so the app can read the
  manifest from `~/Library/Application Support/ant/` and reach the
  devnet over loopback. Don't ship a real app with these settings.
