#!/usr/bin/env node
/** 地址清单校验工具：面向 127.0.0.1 本地开源目录。 */
const fs = require("node:fs");
const path = require("node:path");
const { getAddress } = require("ethers");

const ROOT = path.resolve(__dirname, "..");
const deploymentPath = path.join(ROOT, "deployments", "bsc-mainnet.json");
const expectedCount = 27;

/** 读取并解析部署清单。 */
function readDeployment() {
  return JSON.parse(fs.readFileSync(deploymentPath, "utf8"));
}

/** 校验网络、外部 USDT 地址和全部用户地址。 */
function checkAddresses() {
  const deployment = readDeployment();
  if (deployment.chainId !== 56 || deployment.network !== "bsc-mainnet") {
    throw new Error("部署网络必须是 BSC Mainnet chainId 56");
  }
  getAddress(deployment.externalContracts.usdt);
  const entries = Object.entries(deployment.contracts || {});
  if (entries.length !== expectedCount) {
    throw new Error(`目标地址数量应为 ${expectedCount}，实际为 ${entries.length}`);
  }
  const seen = new Set();
  for (const [name, address] of entries) {
    const normalized = getAddress(address);
    if (seen.has(normalized)) throw new Error(`地址重复：${name} ${address}`);
    seen.add(normalized);
    const source = path.join(ROOT, "contracts", `${name}.sol`);
    if (!fs.existsSync(source)) throw new Error(`缺少目标源码：${source}`);
  }
  console.log(`地址检查通过：${entries.length} 个目标，USDT ${deployment.externalContracts.usdt}`);
}

/** 执行命令行入口并输出中文诊断。 */
function main() {
  try { checkAddresses(); } catch (error) { console.error(`地址检查失败：${error.message}`); process.exitCode = 1; }
}

main();
