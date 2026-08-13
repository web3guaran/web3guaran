WEB3GUARANTEE

Open Source Repository: https://github.com/web3guaran/web3guaran

This repository publishes the Solidity source code, deployment addresses, and reproducible compilation tools for 27 user-side contracts on BSC Mainnet. The compiler is fixed at Solidity 0.8.35, with optimizer runs=200 and viaIR=true enabled.


开源仓库：https://github.com/web3guaran/web3guaran

本目录公开 BSC Mainnet 上 27 个用户侧合约的 Solidity 源码、部署地址与可复现编译工具。编译器固定为 Solidity 0.8.35，开启优化器 runs=200 与 viaIR=true。

Quick Verification
npm ci
npm run verify
Compilation artifacts are written to artifacts/ which is ignored by .gitignore. Address verification uses deployments/bsc-mainnet.json as the single source of truth.

快速核验
npm ci
npm run verify
编译产物写入已被 .gitignore 忽略的 artifacts/。地址检查以 deployments/bsc-mainnet.json 为唯一清单。

Published Contracts
#	Contract	BSC Mainnet Address
1	PlatformSettings	0xE25ABc2d4c71A9000eD026194fa4D6C47c80E7FA
2	InviteRegistry	0xa765305D554953Ea32f8b965258164e142E61c5D
3	KeywordAuction	0xF658D89d1b029f3bA934c3Bb7F185c879d68a6e9
4	PlatformFeeSplitter	0xDD3C3980F3948a0729E84ea869AfebD1956395f7
5	ArchiveStore	0x1884A6893A86985fA978EfF5aEb5607737F0B69D
6	ProductFactoryKeywords	0xA040a2b51941c0059623Cd7caFe5E2528a7A19dd
7	CooldownManager	0x69Ae8325a03083B3157cb6852E05B69DFce3B42F
8	MerchantDepositTemplate	0xdf6e9A548dc0c717D6Ac0a526B7d2ca66a8fB38c
9	PhysicalProductTemplate	0x0b7F3Ce77B9123bd1d319aa9912e12D025694CF2
10	VirtualProductTemplate	0x52Cd32de28a749ae9a49443c91a86bbc2FA0586b
11	ServiceProductTemplate	0xf4F714fCEebaE1e89aE0f1FA69Aad0858Bbb3e63
12	WantToBuyTemplate	0x6f65D699C9081E58BBB19d8559d5154abDDf8Ee4
13	C2CSellOrderTemplate	0xef7bb81f085f36E1Bd28f3A9ebF27C608FC86427
14	C2CBuyOrderTemplate	0x68A265DFD5AfDa52e3e9E3A115D98Bde13CD9Df2
15	C2CTradeTemplate	0xfa262CC7AEAD50F2cA297bDC66AF597e55a0942c
16	AuctionTemplate	0x8Ba6E6E379896bA0D645313Ac59100672856A9C9
17	CommunityArbitrationTemplate	0xb32d0c1383b22c13b1938a12481cD13F63E08705
18	DepositFactory	0x55E00711f55959804Dd19dfC789cF1Bf625E9743
19	KeywordWeight	0xE9a7743412a8aA494992620aFAB21E5126410E47
20	ProductFactory	0xD19412629350450A4E98179A4eA9D8fd3bAa7970
21	ProductFactoryReader	0x804dBc01C8AfdDd6924D29662A78bcef79F10e0A
22	ServiceLocationIndex	0x4DB6a634BeE6ba5D638Afc1042127CFeA2A35bBD
23	C2CFactory	0x0072767D2D9ADaA4f75AdAdC5f8ee3EAc622F8fC
24	C2CFactoryReader	0xf3d40DA61D4bFb752B9D97388eb9D3530Ec3369c
25	AuctionFactory	0x5BE0C5484BC7C64d34277162e037A9071edc1819
26	AuctionFactoryReader	0x6C572E0D5bdfe78Daf8A6fd7ab6ead48EEc71b7c
27	CommunityArbitrationFactory	0x94775FBe4e60E125Dca959ca5dD86D301D7531dC
Common dependencies ProductLib.sol and interfaces/Interfaces.sol have no independent deployment addresses.

已公开合约
#	合约	BSC Mainnet 地址
1	PlatformSettings	0xE25ABc2d4c71A9000eD026194fa4D6C47c80E7FA
2	InviteRegistry	0xa765305D554953Ea32f8b965258164e142E61c5D
3	KeywordAuction	0xF658D89d1b029f3bA934c3Bb7F185c879d68a6e9
4	PlatformFeeSplitter	0xDD3C3980F3948a0729E84ea869AfebD1956395f7
5	ArchiveStore	0x1884A6893A86985fA978EfF5aEb5607737F0B69D
6	ProductFactoryKeywords	0xA040a2b51941c0059623Cd7caFe5E2528a7A19dd
7	CooldownManager	0x69Ae8325a03083B3157cb6852E05B69DFce3B42F
8	MerchantDepositTemplate	0xdf6e9A548dc0c717D6Ac0a526B7d2ca66a8fB38c
9	PhysicalProductTemplate	0x0b7F3Ce77B9123bd1d319aa9912e12D025694CF2
10	VirtualProductTemplate	0x52Cd32de28a749ae9a49443c91a86bbc2FA0586b
11	ServiceProductTemplate	0xf4F714fCEebaE1e89aE0f1FA69Aad0858Bbb3e63
12	WantToBuyTemplate	0x6f65D699C9081E58BBB19d8559d5154abDDf8Ee4
13	C2CSellOrderTemplate	0xef7bb81f085f36E1Bd28f3A9ebF27C608FC86427
14	C2CBuyOrderTemplate	0x68A265DFD5AfDa52e3e9E3A115D98Bde13CD9Df2
15	C2CTradeTemplate	0xfa262CC7AEAD50F2cA297bDC66AF597e55a0942c
16	AuctionTemplate	0x8Ba6E6E379896bA0D645313Ac59100672856A9C9
17	CommunityArbitrationTemplate	0xb32d0c1383b22c13b1938a12481cD13F63E08705
18	DepositFactory	0x55E00711f55959804Dd19dfC789cF1Bf625E9743
19	KeywordWeight	0xE9a7743412a8aA494992620aFAB21E5126410E47
20	ProductFactory	0xD19412629350450A4E98179A4eA9D8fd3bAa7970
21	ProductFactoryReader	0x804dBc01C8AfdDd6924D29662A78bcef79F10e0A
22	ServiceLocationIndex	0x4DB6a634BeE6ba5D638Afc1042127CFeA2A35bBD
23	C2CFactory	0x0072767D2D9ADaA4f75AdAdC5f8ee3EAc622F8fC
24	C2CFactoryReader	0xf3d40DA61D4bFb752B9D97388eb9D3530Ec3369c
25	AuctionFactory	0x5BE0C5484BC7C64d34277162e037A9071edc1819
26	AuctionFactoryReader	0x6C572E0D5bdfe78Daf8A6fd7ab6ead48EEc71b7c
27	CommunityArbitrationFactory	0x94775FBe4e60E125Dca959ca5dD86D301D7531dC
公共依赖 ProductLib.sol 与 interfaces/Interfaces.sol 没有独立部署地址。

Platform Advantages
去中心化资产托管，平台永不跑路

-所有用户存款及产品资金均由独立的智能合约地址托管；平台无法掌控用户资金 -每笔交易都会生成一个独立的合约实例，资金隔离且完全匿名

-交易逻辑在链上执行；平台无法挪用、冻结或转移用户资产


平台优势
去中心化资产托管，平台永不跑路

所有用户押金、商品资金均由独立智能合约地址托管，平台方无法控制用户资金
每笔交易独立生成合约实例，资金隔离、完全匿名
无需押金即可发布商品，降低参与门槛
链上执行交易逻辑，平台无法挪用、冻结或转移用户资产

##安全审计报告

此次审计审查了所提供的Solidity智能合约，涵盖产品交易、C2C订单与交易、拍卖、商家保证金、社区仲裁、工厂、档案、索引、关键词、服务地点以及平台费用分配等模块。

###审计结果

总发现数量： 15
严重漏洞： 0
高： 1
中： 8
低： 6
最终验证状态：所有N1至N15的发现均已审查并标记已验证 - 无可利用风险.
研究结果涵盖了存档模板配置、费用分配的原子性、关键词与产品类型的校验、支付代币的生命周期、保证金的会计处理、分页机制、剩余余额的分配、拍卖退款、索引的完整性、交易状态的转换、会计信息的可观察性、存储空间的增长，以及只读操作的正确性。该高危问题涉及一种由所有者触发的归档模板配置错误，可能导致在归档轮转后无法继续创建新项目；报告指出，这需要由所有者手动操作所致，而非非特权攻击者所为。

###审计局限性

报告指出，在此次评审过程中并未开展编译、概念验证测试、模糊测试、形式化验证、部署后字节码比对以及主网实时链上验证等工作。本评估仅针对所提供的源代码范围，读者应结合上述局限性一并理解。

###剩余验证风险

The PDF's deployment-address section lists the same 27 contract names and addresses as deployments/bsc-mainnet.json. The repository therefore matches the report's stated 27-contract inventory at the name-and-address level.

This does not by itself prove that the current BSC Mainnet contracts were deployed from the audited source. The report states that the addresses were reproduced from the supplied source audit report, while live bytecode, compiler output, constructor or initializer parameters, deployment transactions, and live configuration were outside the completed verification. A later source change, compiler-setting change, dependency change, deployment-script change, proxy or initializer difference, or privileged-configuration difference could therefore make the deployed system differ from the reviewed source.

To close this gap, a follow-up verification should be recorded against an immutable source commit and should:

Compile the exact commit with Solidity 0.8.35, optimizer runs=200, viaIR=true, and the locked dependency set.
Compare each of the 27 deployed runtime bytecodes with the resulting artifacts, accounting for documented immutable values and proxy architecture where applicable.
Verify constructor and initializer arguments, deployment transactions, chain ID 56, the BSC Mainnet USDT address, and relevant owner or multisignature configuration on-chain.
Have the auditor confirm in a signed addendum that the verified commit and deployed addresses correspond, or clearly document every mismatch and scope exclusion.
Until that follow-up is completed, this report should be understood as a source-code review of the supplied 27-contract scope, rather than proof of bytecode identity or current live-chain configuration.

Contract Naming and Historical Compatibility
The four independent Shuifang implementation files are not present in this repository and are not deployment targets. The compiler does not hide existing source files by matching the Shuifang name; it loads the available Solidity sources and emits artifacts only for the 27 names in deployments/bsc-mainnet.json. Historical IShuifang* interfaces and the PlatformSettings compatibility field remain only where they are part of shared deployed-source compatibility. They do not constitute a published Shuifang implementation or an active product feature in this repository.

Full report: WEB3GUARANTEE-Audit-Report.pdf

SHA-256: 1c66b42c406e2115dd9bd692d52ac9af221aae12706848c91c77059b72a66890