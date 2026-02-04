#!/bin/bash

# Rook Protocol Environment Setup Script

set -e

echo "♜ Rook Protocol Environment Setup"
echo "================================="
echo ""

# Check for required tools
echo "Checking dependencies..."

if ! command -v node &> /dev/null; then
    echo "❌ Node.js not found. Please install Node.js >= 18"
    exit 1
fi

if ! command -v npm &> /dev/null; then
    echo "❌ npm not found. Please install npm"
    exit 1
fi

if ! command -v forge &> /dev/null; then
    echo "⚠️ Foundry not found. Install from https://getfoundry.sh"
fi

echo "✅ Dependencies OK"
echo ""

# Install npm dependencies
echo "Installing npm dependencies..."
npm install
echo "✅ npm dependencies installed"
echo ""

# Setup .env file
if [ ! -f .env ]; then
    echo "Creating .env file..."
    cp .env.example .env
    echo "✅ Created .env from .env.example"
    echo "⚠️ Please edit .env and add your private key and API keys"
else
    echo "✅ .env already exists"
fi

echo ""
echo "================================="
echo "Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Edit .env and add your configuration"
echo "  2. Run 'npm run contract:build' to build contracts"
echo "  3. Run 'npm test' to run tests"
echo ""
