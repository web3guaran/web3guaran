# Contract Structure

This repository publishes 27 deployed user-facing contract targets. `ProductLib.sol` is a shared library, while `interfaces/Interfaces.sol` contains shared interfaces, enums, and structs. Both participate in compilation as dependencies and have no independent deployment address.

## Components

- `PlatformSettings`: Platform owner, fee destinations, and core configuration.
- `*Template`: Implementations for product, order, auction, arbitration, and deposit instances.
- `*Factory`: Creates instances of the corresponding business templates.
- `*Reader`: Read-only aggregate queries; does not custody assets.
- `ProductFactoryKeywords`, `KeywordAuction`, and `KeywordWeight`: Keyword-related functionality.
- `DepositFactory`, `MerchantDepositTemplate`, and `CooldownManager`: Deposit and cooldown functionality.
- `ArchiveStore`, `ServiceLocationIndex`, and `InviteRegistry`: Archive, service-location, and invitation-registration functionality.
- `PlatformFeeSplitter`: Platform fee distribution.

## Addresses and Build

The deployment manifest is available at [`deployments/bsc-mainnet.json`](../deployments/bsc-mainnet.json). The build script reads the 27 target names from that manifest, compiles the available Solidity source with Solidity 0.8.35, optimizer runs 200, and `viaIR`, and produces artifacts only for those 27 deployed targets. It does not use a filename-based `Shuifang` exclusion rule. The repository contains historical Shuifang interface and compatibility references required by shared deployed-source compatibility; the four independent Shuifang implementations are not present in this open-source copy and have no published deployment entry.

## Permissions Notice

Publishing the source code does not mean that the system is fully decentralized. Owner and platform permissions may affect key configuration, fees, and operational workflows. Users should independently verify on-chain permissions and multisignature settings.
