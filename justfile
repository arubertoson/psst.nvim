# List available commands.
default:
    @just --list

# Install repository-owned tools and run the quality gate.
setup: tools-install check

# Install pinned development tools.
tools-install:
    @mise install

# Run every check expected to pass before committing.
check: format-check test

# Format every Lua file.
format:
    @mise exec -- stylua .

# Verify formatting without changing files.
format-check:
    @mise exec -- stylua --check .

# Run the complete test suite.
test:
    @nvim --headless --noplugin -u tests/init.lua -c "lua MiniTest.run()"

# Run one test file.
test-file file:
    @nvim --headless --noplugin -u tests/init.lua -c "lua MiniTest.run_file('{{file}}')"
