export enum ErrorCodes {
  NO_SIGNER = 'NO_SIGNER',
  INVALID_NETWORK = 'INVALID_NETWORK',
  INVALID_AGENT = 'INVALID_AGENT',
  INVALID_METHOD = 'INVALID_METHOD',
  INVALID_AMOUNT = 'INVALID_AMOUNT',
  INSUFFICIENT_BALANCE = 'INSUFFICIENT_BALANCE',
  ESCROW_NOT_FOUND = 'ESCROW_NOT_FOUND',
  ESCROW_NOT_ACTIVE = 'ESCROW_NOT_ACTIVE',
  UNAUTHORIZED = 'UNAUTHORIZED',
  CHALLENGE_EXISTS = 'CHALLENGE_EXISTS',
  CHALLENGE_NOT_FOUND = 'CHALLENGE_NOT_FOUND',
  CHALLENGE_EXPIRED = 'CHALLENGE_EXPIRED',
  BELOW_THRESHOLD = 'BELOW_THRESHOLD',
  TRANSFER_FAILED = 'TRANSFER_FAILED',
  NOT_IMPLEMENTED = 'NOT_IMPLEMENTED',
  ORACLE_ERROR = 'ORACLE_ERROR',
  NETWORK_ERROR = 'NETWORK_ERROR',
  UNKNOWN = 'UNKNOWN'
}

export class RookError extends Error {
  public code: ErrorCodes;
  public details?: Record<string, any>;

  constructor(code: ErrorCodes, message?: string, details?: Record<string, any>) {
    super(message || getDefaultMessage(code));
    this.code = code;
    this.details = details;
    this.name = 'RookError';
  }
}

function getDefaultMessage(code: ErrorCodes): string {
  const messages: Record<ErrorCodes, string> = {
    [ErrorCodes.NO_SIGNER]: 'No signer available. Provide a private key in config.',
    [ErrorCodes.INVALID_NETWORK]: 'Invalid network specified. Use "base-sepolia" or "base".',
    [ErrorCodes.INVALID_AGENT]: 'Invalid agent identifier. Use address, @handle, or ENS.',
    [ErrorCodes.INVALID_METHOD]: 'Invalid proof method. Use "wallet_signature" or "behavioral".',
    [ErrorCodes.INVALID_AMOUNT]: 'Invalid amount specified.',
    [ErrorCodes.INSUFFICIENT_BALANCE]: 'Insufficient USDC balance.',
    [ErrorCodes.ESCROW_NOT_FOUND]: 'Escrow not found.',
    [ErrorCodes.ESCROW_NOT_ACTIVE]: 'Escrow is not active.',
    [ErrorCodes.UNAUTHORIZED]: 'Not authorized to perform this action.',
    [ErrorCodes.CHALLENGE_EXISTS]: 'A challenge already exists for this escrow.',
    [ErrorCodes.CHALLENGE_NOT_FOUND]: 'Challenge not found.',
    [ErrorCodes.CHALLENGE_EXPIRED]: 'Challenge has expired.',
    [ErrorCodes.BELOW_THRESHOLD]: 'Trust score below threshold for release.',
    [ErrorCodes.TRANSFER_FAILED]: 'Token transfer failed.',
    [ErrorCodes.NOT_IMPLEMENTED]: 'This feature is not yet implemented.',
    [ErrorCodes.ORACLE_ERROR]: 'Oracle error occurred.',
    [ErrorCodes.NETWORK_ERROR]: 'Network connection error.',
    [ErrorCodes.UNKNOWN]: 'An unknown error occurred.'
  };
  
  return messages[code] || 'Unknown error';
}
