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
  .action(async (options) => {
    const spinner = ora('Creating escrow...').start();
    
    try {
      const config = loadConfig();
      const rook = new RookProtocol(config);
      
      const result = await rook.createEscrow({
        amount: parseFloat(options.amount),
        recipient: options.recipient,
        job: options.job,
        threshold: parseInt(options.threshold)
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
  .option('-r, --reason <string>', 'Challenge reason')
  .action(async (options) => {
    const spinner = ora('Initiating challenge...').start();
    
    try {
      const config = loadConfig();
      const rook = new RookProtocol(config);
      
      // NOTE: Stake is fixed at 5 USDC by contract
      const result = await rook.challenge({
        escrowId: options.escrow,
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
// RESPOND (Seller response to challenge)
// ═══════════════════════════════════════════════════════════════

program
  .command('respond')
  .description('Respond to identity challenge (seller only)')
  .requiredOption('-e, --escrow <id>', 'Escrow ID')
  .requiredOption('-d, --data <string>', 'Response data (will be hashed)')
  .action(async (options) => {
    const spinner = ora('Submitting response...').start();
    
    try {
      const config = loadConfig();
      const rook = new RookProtocol(config);
      
      const txHash = await rook.respondChallenge(options.escrow, options.data);
      
      spinner.succeed('Response submitted!');
      console.log(chalk.dim('TX Hash:'), txHash);
      console.log(chalk.green('\n✓ Challenge response recorded'));
      
    } catch (error: any) {
      spinner.fail('Response failed');
      console.error(chalk.red(error.message));
      process.exit(1);
    }
  });

// ═══════════════════════════════════════════════════════════════
// CLAIM TIMEOUT
// ═══════════════════════════════════════════════════════════════

program
  .command('claim-timeout')
  .description('Claim challenge timeout (if seller did not respond)')
  .requiredOption('-e, --escrow <id>', 'Escrow ID')
  .action(async (options) => {
    const spinner = ora('Claiming timeout...').start();
    
    try {
      const config = loadConfig();
      const rook = new RookProtocol(config);
      
      const txHash = await rook.claimTimeout(options.escrow);
      
      spinner.succeed('Timeout claimed!');
      console.log(chalk.dim('TX Hash:'), txHash);
      console.log(chalk.yellow('\n⚠️  Challenge failed - stake returned, buyer refunded'));
      
    } catch (error: any) {
      spinner.fail('Claim failed');
      console.error(chalk.red(error.message));
      process.exit(1);
    }
  });

// ═══════════════════════════════════════════════════════════════
// RELEASE
// ═══════════════════════════════════════════════════════════════

program
  .command('release')
  .description('Release escrow funds (oracle only)')
  .requiredOption('-e, --escrow <id>', 'Escrow ID')
  .action(async (options) => {
    const spinner = ora('Releasing escrow...').start();
    
    try {
      const config = loadConfig();
      const rook = new RookProtocol(config);
      
      // Check if operator
      const isOp = await rook.isOperator();
      if (!isOp) {
        spinner.fail('Not an oracle operator');
        console.log(chalk.yellow('Use "consent-release" for mutual consent release after timeout'));
        process.exit(1);
      }
      
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
// CONSENT RELEASE
// ═══════════════════════════════════════════════════════════════

program
  .command('consent-release')
  .description('Release escrow with mutual consent (after 1 day timeout)')
  .requiredOption('-e, --escrow <id>', 'Escrow ID')
  .action(async (options) => {
    const spinner = ora('Releasing with consent...').start();
    
    try {
      const config = loadConfig();
      const rook = new RookProtocol(config);
      
      const txHash = await rook.releaseWithConsent(options.escrow);
      
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
  .description('Escalate to dispute')
  .requiredOption('-e, --escrow <id>', 'Escrow ID')
  .requiredOption('--evidence <string>', 'Evidence (IPFS hash or text)')
  .action(async (options) => {
    const spinner = ora('Filing dispute...').start();
    
    try {
      const config = loadConfig();
      const rook = new RookProtocol(config);
      
      const txHash = await rook.dispute(options.escrow, options.evidence);
      
      spinner.succeed('Dispute filed!');
      console.log(chalk.dim('TX Hash:'), txHash);
      console.log(chalk.yellow('\n⚖️  Escrow funds locked pending resolution'));
      console.log(chalk.gray('Contact contract owner to resolve dispute'));
      
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
      const challenge = await rook['escrowContract'].getChallenge(options.escrow);
      
      spinner.succeed('Escrow found!');
      
      const statusColor = escrow.status === 'Released' ? chalk.green :
                          escrow.status === 'Active' ? chalk.blue :
                          escrow.status === 'Disputed' ? chalk.yellow :
                          escrow.status === 'Challenged' ? chalk.magenta :
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
      
      // Show challenge info if active
      if (escrow.status === 'Challenged' && challenge.status !== 0) {
        const currentBlock = await rook.getBlockNumber();
        const blocksRemaining = Math.max(0, Number(challenge.deadline) - currentBlock);
        
        console.log('\n' + chalk.cyan('Challenge Status:'));
        console.log(formatTable({
          'Challenger': challenge.challenger,
          'Stake': formatUSDC(Number(challenge.stake) / 1e6),
          'Deadline Block': challenge.deadline.toString(),
          'Blocks Remaining': blocksRemaining.toString(),
          'Responded': challenge.responseHash !== '0x0000000000000000000000000000000000000000000000000000000000000000' ? 'Yes' : 'No'
        }));
      }
      
    } catch (error: any) {
      spinner.fail('Status check failed');
      console.error(chalk.red(error.message));
      process.exit(1);
    }
  });

// Parse arguments
program.parse();
