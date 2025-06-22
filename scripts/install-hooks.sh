#!/bin/bash
echo "📎 Installing git hooks..."

# Create hooks directory if it doesn't exist
mkdir -p .git/hooks

# Copy pre-commit hook
if [ -f .git-hooks/pre-commit ]; then
    cp .git-hooks/pre-commit .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
    echo "✅ Pre-commit hook installed"
else
    echo "⚠️ Pre-commit hook not found in .git-hooks/"
fi

# Copy other hooks if they exist
for hook in pre-push post-commit; do
    if [ -f .git-hooks/$hook ]; then
        cp .git-hooks/$hook .git/hooks/$hook
        chmod +x .git/hooks/$hook
        echo "✅ $hook hook installed"
    fi
done

echo "✅ Git hooks installation complete"