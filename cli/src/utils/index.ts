import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import { RookConfig } from '@rook-protocol/sdk';

const CONFIG_DIR = path.join(os.homedir(), '.rook');
const CONFIG_FILE = path.join(CONFIG_DIR, 'config.json');

export interface CliConfig extends RookConfig {
  defaultNetwork?: string;
}

export function loadConfig(): CliConfig {
  // First try environment variables
  const envConfig: CliConfig = {
    network: (process.env.ROOK_NETWORK as any) || 'base-sepolia',
    rpcUrl: process.env.ROOK_RPC_URL,
    privateKey: process.env.PRIVATE_KEY
  };

  // Then try config file
  if (fs.existsSync(CONFIG_FILE)) {
    try {
      const fileConfig = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
      return { ...fileConfig, ...envConfig };
    } catch (e) {
      // Ignore invalid config file
    }
  }

  if (!envConfig.privateKey) {
    throw new Error(
      'No private key found. Set PRIVATE_KEY environment variable or run `rook config`.'
    );
  }

  return envConfig;
}

export function saveConfig(config: CliConfig): void {
  if (!fs.existsSync(CONFIG_DIR)) {
    fs.mkdirSync(CONFIG_DIR, { recursive: true });
  }
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));
}

export function formatUSDC(amount: number | string): string {
  const num = typeof amount === 'string' ? parseFloat(amount) : amount;
  return `$${num.toFixed(2)} USDC`;
}

export function formatScore(score: number): string {
  return `${(score * 100).toFixed(0)}%`;
}

export function formatTable(obj: Record<string, string>): string {
  const maxKeyLength = Math.max(...Object.keys(obj).map(k => k.length));
  return Object.entries(obj)
    .map(([key, value]) => `  ${key.padEnd(maxKeyLength)}  ${value}`)
    .join('\n');
}

export function truncate(str: string, maxLength: number): string {
  if (str.length <= maxLength) return str;
  return str.slice(0, maxLength - 3) + '...';
}
