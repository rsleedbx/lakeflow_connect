# Contributing to VaporDB

Thank you for your interest in contributing to VaporDB! This document provides guidelines for contributing to this Databricks Labs project.

## Development Setup

1. **Clone the repository**:
   ```bash
   git clone https://github.com/rsleedbx/lakeflow_connect.git
   cd lakeflow_connect
   ```

2. **Set up development environment**:
   ```bash
   python -m venv .venv
   source .venv/bin/activate  # On Windows: .venv\Scripts\activate
   pip install -e .
   ```

3. **Install development dependencies**:
   ```bash
   pip install databricks-labs-blueprint
   ```

## Project Structure

This project follows the [Databricks Labs Blueprint](https://github.com/databrickslabs/blueprint) structure:

```
src/databricks/labs/vapordb/
├── __init__.py          # Package initialization
├── __main__.py          # CLI entrypoint
├── core.py              # Core VaporDB functionality
├── cli/                 # CLI modules
└── providers/           # Cloud provider implementations
```

## Making Changes

1. **Create a feature branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** following the existing code style

3. **Test your changes**:
   ```bash
   # Test CLI functionality
   databricks labs install vapordb
   databricks labs vapordb --help
   ```

4. **Commit your changes**:
   ```bash
   git add .
   git commit -m "feat: your feature description"
   ```

5. **Push and create a pull request**:
   ```bash
   git push origin feature/your-feature-name
   ```

## Code Style

- Follow PEP 8 Python style guidelines
- Use type hints where appropriate
- Add docstrings to public functions and classes
- Keep functions focused and modular

## Testing

- Test CLI commands manually
- Verify cloud provider integrations work correctly
- Test with different database types and configurations

## Documentation

- Update README.md if adding new features
- Add docstrings to new functions
- Update CLI help text as needed

## Questions?

If you have questions about contributing, please open an issue or reach out to the maintainers.









