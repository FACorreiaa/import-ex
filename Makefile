.PHONY: help compile clean test deps format check import import-krenauer import-fast run run-immediate shell

# Default target
help:
	@echo "Financex - RealData Import Service"
	@echo ""
	@echo "Available targets:"
	@echo "  make compile          - Compile the project"
	@echo "  make clean            - Clean build artifacts"
	@echo "  make deps             - Fetch and compile dependencies"
	@echo "  make test             - Run tests"
	@echo "  make format           - Format code with mix format"
	@echo "  make check            - Run code quality checks (format, compile)"
	@echo "  make import           - Run import for all clients"
	@echo "  make import-krenauer  - Run import for krenauer client"
	@echo "  make import-fast      - Run import with fast retry settings (for testing)"
	@echo "  make run              - Run application in scheduled mode (daemon)"
	@echo "  make run-immediate    - Run application in immediate mode (one-off)"
	@echo "  make shell            - Start interactive shell (iex -S mix)"
	@echo ""

# Compilation targets
compile:
	@echo "Compiling project..."
	mix compile

clean:
	@echo "Cleaning build artifacts..."
	mix clean

deps:
	@echo "Fetching dependencies..."
	mix deps.get
	@echo "Compiling dependencies..."
	mix deps.compile

# Testing
test:
	@echo "Running tests..."
	mix test

# Code quality
format:
	@echo "Formatting code..."
	mix format

check: format
	@echo "Running code quality checks..."
	mix compile --warnings-as-errors

# Import commands
import:
	@echo "Running import for all clients..."
	mix financex.import

import-krenauer:
	@echo "Running import for krenauer client..."
	mix financex.import krenauer

import-fast:
	@echo "Running import with fast retry settings (for testing)..."
	mix financex.import --max-retries 3 --timeout 300000

# Application runtime
run:
	@echo "Starting Financex in scheduled mode..."
	@echo "Press Ctrl+C to stop"
	mix run --no-halt

run-immediate:
	@echo "Starting Financex in immediate mode (one-off run)..."
	RUN_IMMEDIATELY=1 mix run --no-halt

shell:
	@echo "Starting interactive shell..."
	iex -S mix
