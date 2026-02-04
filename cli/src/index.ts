#!/usr/bin/env node

import { Command } from 'commander';
import { RookProtocol } from '@rook-protocol/sdk';
import chalk from 'chalk';
import ora from 'ora';
import { loadConfig, formatUSDC, formatScore, formatTable } from './utils';

const program = new Command();

program
  .name('rook')
  .description('♜ Rook Protocol CLI — Trustless USDC Escrow for AI Agents')
  .version('1.1.0');

// ═══════════════════════════════════════════════════════════════
// CREATE ESCROW
// ═══════════════════════════════════════════════════════════════

program
  .command('create')
  .description('Create a new escrow')
  .requiredOption('-a, --amount <number>', 'USDC amount')
  .requiredOption('-r, --recipient <address>', 'Seller address or @handle')
  .requiredOption('-j, --job <string>', 'Job description')
  .option('-t, --threshold <number>', 'Trust threshold (0-100)', '65')
  .option('--require-challenge', 'Require identity challenge before release')
  .action(async (options) => {
    const spinner = ora('Creating escrow...').start();
    
    try {
      const config = loadConfig();
      const rook = new RookProtocol(config);
      
      const result = await rook.createEscrow({
        amount: parseFloat(options.amount),
        recipient: options.recipient,
        job: options.job,
        threshold: parseInt(options.threshold),
        requireChallenge: options.requireChallenge
      });
      
      spinner.succeed('Escrow created!');
      
      console.log('\n' + chalk.cyan('Escrow Details:'));
      console.log(formatTable({
        'ID': result.id,
        'Buyer': result.buyer,
        'Seller': result.seller,
        'Amount': formatUSDC(result.amount),
        'Threshold': `${result.threshold}%`,
        'Status': chalk.green(result.status),
        'TX Hash': result.txHash
      }));
      
    } catch (error: any) {
      spinner.fail('Failed to create escrow');
      console.error(chalk.red(error.message));
      process.exit(1);
    }
  });

// ═══════════════════════════════════════════════════════════════
// VERIFY AGENT
// ═══════════════════════════════════════════════════════════════

program
  .command('verify')
  .description('Check an agent\'s trust score')
  .requiredOption('-a, --agent <address>', 'Agent address or @handle')
  .option('--deep', 'Include detailed behavioral analysis')
  .action(async (options) => {
    const spinner = ora('Verifying agent...').start();
    
    try {
      const config = loadConfig();
      const rook = new RookProtocol(config);
      
      const result = await rook.verify(options.agent);
      
      spinner.succeed('Verification complete!');
      
      const scoreColor = result.trust_score >= 0.65 ? chalk.green : 
                         result.trust_score >= 0.50 ? chalk.yellow : 
                         chalk.red;
      
      console.log('\n' + chalk.cyan('Trust Score:'), scoreColor(formatScore(result.trust_score)));
      console.log(chalk.cyan('Risk Level:'), result.risk_level);
      console.log(chalk.cyan('Recommendation:'), result.recommendation);
      
      console.log('\n' + chalk.cyan('Score Breakdown:'));
      console.log(formatTable({
        'ERC-8004 Identity': formatScore(result.breakdown.erc8004_identity),
        'Reputation Signals': formatScore(result.breakdown.reputation_signals),
        'Sybil Resistance': formatScore(result.breakdown.sybil_resistance),
        'Escrow History': formatScore(result.breakdown.escrow_history),
        'Challenge Bonus': formatScore(result.breakdown.challenge_bonus)
      }));
      
    } catch (error: any) {
      spinner.fail('Verification failed');
      console.error(chalk.red(error.message));
      process.exit(1);
    }
  });

// ═══════════════════════════════════════════════════════════════
// CHALLENGE
// ═══════════════════════════════════════════════════════════════

program
  .command('challenge')
  .description('Initiate identity challenge (stake 5 USDC)')
  .requiredOption('-e, --escrow <id>', 'Escrow ID')
  .option('-s, --stake <number>', 'Stake amount in USDC', '5')
  .option('-r, --reason <string>', 'Challenge reason')
  .action(async (options) => {
    const spinner = ora('Initiating challenge...').start();
    
    try {
      const config = loadConfig();
      const rook = new RookProtocol(config);
      
      const result = await rook.challenge({
        escrowId: options.escrow,
        stake: parseFloat(options.stake),
        reason: options.reason
      });
      
      spinner.succeed('Challenge initiated!');
      
      console.log('\n' + chalk.cyan('Challenge Details:'));
      console.log(formatTable({
        'Escrow ID': result.escrowId,
        'Challenger': result.challenger,
        'Stake': formatUSDC(result.stake),
        'Deadline Block': result.deadline.toString(),
        'Reason': result.reason || '-',
        'TX Hash': result.txHash
      }));
      
      console.log(chalk.yellow('\n⏳ Seller must respond within ~2 minutes'));
      
    } catch (error: any) {
      spinner.fail('Challenge failed');
      console.error(chalk.red(error.message));
      process.exit(1);
    }
  });

// ═══════════════════════════════════════════════════════════════
// PROVE (Respond to Challenge)
// ═══════════════════════════════════════════════════════════════

program
  .command('prove')
  .description('Respond to identity challenge')
  .requiredOption('-e, --escrow <id>', 'Escrow ID')
  .requiredOption('-m, --method <type>', 'Proof method: wallet_signature | behavioral | tee_attestation')
  .action(async (options) => {
    const spinner = ora('Generating proof...').start();
    
    try {
      const config = loadConfig();
      const rook = new RookProtocol(config);
      
      const signature = await rook.prove(options.escrow, options.method);
      
      spinner.succeed('Proof submitted!');
      
      console.log('\n' + chalk.green('✓ Identity verified'));
      console.log(chalk.dim('Signature:'), signature.slice(0, 42) + '...');
      
    } catch (error: any) {
      spinner.fail('Proof failed');
      console.error(chalk.red(error.message));
      process.exit(1);
    }
  });

// ═══════════════════════════════════════════════════════════════
// RELEASE
// ═══════════════════════════════════════════════════════════════

program
  .command('release')
  .description('Manually release escrow funds')
  .requiredOption('-e, --escrow <id>', 'Escrow ID')
  .action(async (options) => {
    const spinner = ora('Releasing escrow...').start();
    
    try {
      const config = loadConfig();
      const rook = new RookProtocol(config);
      
      const txHash = await rook.release(options.escrow);
      
      spinner.succeed('Escrow released!');
      console.log(chalk.dim('TX Hash:'), txHash);
      
    } catch (error: any) {
      spinner.fail('Release failed');
      console.error(chalk.red(error.message));
      process.exit(1);
    }
  });

// ═══════════════════════════════════════════════════════════════
// DISPUTE
// ═══════════════════════════════════════════════════════════════

program
  .command('dispute')
  .description('Escalate to Kleros arbitration')
  .requiredOption('-e, --escrow <id>', 'Escrow ID')
  .requiredOption('--evidence <ipfs>', 'IPFS hash of evidence')
  .option('--claim <string>', 'Dispute claim description')
  .action(async (options) => {
    const spinner = ora('Filing dispute...').start();
    
    try {
      const config = loadConfig();
      const rook = new RookProtocol(config);
      
      const txHash = await rook.dispute(options.escrow, options.evidence);
      
      spinner.succeed('Dispute filed!');
      console.log(chalk.dim('TX Hash:'), txHash);
      console.log(chalk.yellow('\n⚖️ Escrow funds locked pending Kleros arbitration'));
      
    } catch (error: any) {
      spinner.fail('Dispute failed');
      console.error(chalk.red(error.message));
      process.exit(1);
    }
  });

// ═══════════════════════════════════════════════════════════════
// STATUS
// ═══════════════════════════════════════════════════════════════

program
  .command('status')
  .description('Check escrow status')
  .requiredOption('-e, --escrow <id>', 'Escrow ID')
  .action(async (options) => {
    const spinner = ora('Fetching escrow...').start();
    
    try {
      const config = loadConfig();
      const rook = new RookProtocol(config);
      
      const escrow = await rook.getEscrow(options.escrow);
      
      spinner.succeed('Escrow found!');
      
      const statusColor = escrow.status === 'Released' ? chalk.green :
                          escrow.status === 'Active' ? chalk.blue :
                          escrow.status === 'Disputed' ? chalk.yellow :
                          chalk.red;
      
      console.log('\n' + chalk.cyan('Escrow Status:'));
      console.log(formatTable({
        'ID': escrow.id,
        'Buyer': escrow.buyer,
        'Seller': escrow.seller,
        'Amount': formatUSDC(escrow.amount),
        'Threshold': `${escrow.threshold}%`,
        'Status': statusColor(escrow.status),
        'Created': escrow.createdAt ? new Date(escrow.createdAt * 1000).toISOString() : '-',
        'Expires': escrow.expiresAt ? new Date(escrow.expiresAt * 1000).toISOString() : '-'
      }));
      
    } catch (error: any) {
      spinner.fail('Status check failed');
      console.error(chalk.red(error.message));
      process.exit(1);
    }
  });

// Parse arguments
program.parse();
