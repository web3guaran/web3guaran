#!/usr/bin/env node
/** 使用 Solidity 0.8.35、optimizer=200、viaIR 编译 27 个公开目标。 */
const fs = require("node:fs");
const path = require("node:path");
const solc = require("solc");

const ROOT = path.resolve(__dirname, "..");
const CONTRACTS = path.join(ROOT, "contracts");
const ARTIFACTS = path.join(ROOT, "artifacts");
const deployment = require(path.join(ROOT, "deployments", "bsc-mainnet.json"));
const targets = deployment.contracts;

/** 收集开源 Solidity 源码；目标 artifact 由部署清单显式决定。 */
function collectSources() {
  const files = fs.readdirSync(CONTRACTS, { withFileTypes: true });
  const sources = {};
  for (const entry of files) {
    if (!entry.isFile() || !entry.name.endsWith(".sol")) continue;
    const relative = entry.name;
    sources[relative] = { content: fs.readFileSync(path.join(CONTRACTS, entry.name), "utf8") };
  }
  const ifacePath = path.join(CONTRACTS, "interfaces", "Interfaces.sol");
  sources["interfaces/Interfaces.sol"] = { content: fs.readFileSync(ifacePath, "utf8") };
  return sources;
}

/** 为 solc 提供只允许读取开源 contracts 目录的导入回调。 */
function resolveImport(importPath) {
  const normalized = importPath.replace(/\\/g, "/");
  const fullPath = path.resolve(CONTRACTS, normalized);
  if (!fullPath.startsWith(`${CONTRACTS}${path.sep}`) || !fs.existsSync(fullPath)) return { error: `未找到导入：${importPath}` };
  return { contents: fs.readFileSync(fullPath, "utf8") };
}

/** 编译并仅输出目标合约 ABI、字节码和元数据，忽略 libraries/interfaces artifacts。 */
function compileContracts() {
  const input = {
    language: "Solidity",
    sources: collectSources(),
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true,
      outputSelection: { "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object", "metadata"] } }
    }
  };
  const output = JSON.parse(solc.compile(JSON.stringify(input), { import: resolveImport }));
  const errors = (output.errors || []).filter((item) => item.severity === "error");
  if (errors.length) { for (const error of errors) console.error(error.formattedMessage); throw new Error(`编译失败：${errors.length} 个错误`); }
  fs.rmSync(ARTIFACTS, { recursive: true, force: true });
  fs.mkdirSync(ARTIFACTS, { recursive: true });
  const targets = deployment.contracts;
  for (const name of Object.keys(targets)) {
    const contract = output.contracts?.[`${name}.sol`]?.[name];
    if (!contract) throw new Error(`编译输出缺少 ${name}，请检查依赖与源码`);
    fs.writeFileSync(path.join(ARTIFACTS, `${name}.json`), `${JSON.stringify({ contractName: name, abi: contract.abi, bytecode: contract.evm.bytecode.object, deployedBytecode: contract.evm.deployedBytecode.object, metadata: contract.metadata }, null, 2)}\n`);
  }
  console.log(`编译通过：solc ${solc.version()}，${Object.keys(targets).length} 个目标，optimizer=200，viaIR=true`);
}

/** 执行命令行入口并输出中文诊断。 */
function main() { try { compileContracts(); } catch (error) { console.error(`编译失败：${error.message}`); process.exitCode = 1; } }
main();
